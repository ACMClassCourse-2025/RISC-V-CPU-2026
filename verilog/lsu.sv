// -----------------------------------------------------------------------------
// lsu.sv — load/store 执行单元 v1
//
// 职责：
//   - 接收 IQ 发射的一条 load/store uop，计算地址、写掩码；
//   - store：填入 LSQ，发 complete（不写内存，等 commit 后由 LSQ drain）；
//   - load：等更老 store 地址已知/同地址 store 写完后，发 data_mem 读；
//     响应按 mem_size/mem_unsigned 格式化，经 CDB 写回；
//   - 与 mem_subsystem 的 data_mem 单未完成事务握手；
//   - squash 丢弃年轻 load；已发出的读响应到达后静默丢弃。
//
// P1 串行化 load：同一时刻最多一个 load 在等待/读内存/结果待广播。
// -----------------------------------------------------------------------------

module lsu #(
  parameter integer W = `CPU_ISSUE_WIDTH
) (
  input  logic clk,
  input  logic reset,

  // dispatch allocation (from backend, driven by dispatch lanes)
  input  logic [W-1:0]                 alloc_valid,
  input  logic [W*`CPU_LSQ_IDX_W-1:0]  alloc_id,
  input  logic [W*`CPU_ROB_TAG_W-1:0]  alloc_rob,
  input  logic [W-1:0]                 alloc_is_store,
  output logic                         alloc_ready,

  // issue from IQ (single lane)
  input  logic                         issue_valid,
  input  logic [`CPU_DISPATCH_W-1:0]   issue_uop,
  input  logic [31:0]                  issue_src1,
  input  logic [31:0]                  issue_src2,
  output logic                         issue_ready,

  // commit
  input  logic [W-1:0]                 commit_valid,
  input  logic [W-1:0]                 commit_is_store,
  input  logic [W-1:0]                 commit_is_load,
  input  logic [W*`CPU_LSQ_IDX_W-1:0]  commit_id,

  // squash
  input  logic                         squash_valid,
  input  logic [`CPU_ROB_TAG_W-1:0]    squash_rob_idx,

  // load result (goes to CDB)
  output logic                         load_result_valid,
  output logic [`CPU_PRF_IDX_W-1:0]    load_result_tag,
  output logic [31:0]                  load_result_value,
  output logic                         load_result_exception,
  input  logic                         load_result_ready,

  // store complete (goes to complete bus)
  output logic                         store_complete_valid,
  output logic [`CPU_PRF_IDX_W-1:0]    store_complete_tag,
  output logic                         store_complete_exception,

  // data memory
  output logic                         data_req_valid,
  output logic                         data_req_we,
  output logic [31:0]                  data_req_addr,
  output logic [31:0]                  data_req_wdata,
  output logic [3:0]                   data_req_wstrb,
  input  logic                         data_resp_valid,
  input  logic [31:0]                  data_resp_rdata,

  output logic                         busy
);

  localparam integer PW = `CPU_PRF_IDX_W;
  localparam integer LW = `CPU_LSQ_IDX_W;
  localparam integer RW = `CPU_ROB_TAG_W;
  localparam integer DW = `CPU_DISPATCH_W;

  // ---- issue uop 解包 ------------------------------------------------------
  logic [31:0] issue_pc, issue_imm, issue_inst;
  logic [PW-1:0] issue_dest;
  logic [LW-1:0] issue_lsq;
  logic [RW-1:0] issue_rob;
  logic [1:0]  issue_mem_size;
  logic        issue_mem_unsigned;
  logic        issue_is_load, issue_is_store, issue_illegal;
  logic [31:0] issue_addr;

  assign issue_pc           = issue_uop[`CPU_DISPATCH_PC_OFF +: 32];
  assign issue_inst         = issue_uop[`CPU_DISPATCH_INST_OFF +: 32];
  assign issue_imm          = issue_uop[`CPU_DISPATCH_IMM_OFF +: 32];
  assign issue_dest         = issue_uop[`CPU_DISPATCH_DEST_TAG_OFF +: PW];
  assign issue_lsq          = issue_uop[`CPU_DISPATCH_LSQ_ID_OFF +: LW];
  assign issue_rob          = issue_uop[`CPU_DISPATCH_ROB_IDX_OFF +: RW];
  assign issue_mem_size     = issue_uop[`CPU_DISPATCH_MEM_SIZE_OFF +: 2];
  assign issue_mem_unsigned = issue_uop[`CPU_DISPATCH_MEM_UNSIGNED_OFF];
  assign issue_is_load      = issue_uop[`CPU_DISPATCH_IS_LOAD_OFF];
  assign issue_is_store     = issue_uop[`CPU_DISPATCH_IS_STORE_OFF];
  assign issue_illegal      = issue_uop[`CPU_DISPATCH_ILLEGAL_OFF];
  assign issue_addr         = issue_src1 + issue_imm;

  // ---- 写掩码 / 写数据 ----------------------------------------------------
  function automatic [3:0] make_wstrb(input logic [1:0] size,
                                      input logic [1:0] off);
    begin
      case (size)
        `SZ_BYTE: make_wstrb = 4'b0001 << off;
        `SZ_HALF: make_wstrb = off[1] ? 4'b1100 : 4'b0011;
        default:  make_wstrb = 4'b1111;
      endcase
    end
  endfunction

  logic [3:0]  issue_wstrb;
  logic [31:0] issue_wdata;

  assign issue_wstrb = make_wstrb(issue_mem_size, issue_addr[1:0]);
  assign issue_wdata = (issue_mem_size == `SZ_WORD) ? issue_src2 :
                       (issue_src2 << (8 * issue_addr[1:0]));

  // ---- load 数据格式化 ----------------------------------------------------
  function automatic [31:0] format_load(input logic [31:0] word,
                                        input logic [1:0] size,
                                        input logic [1:0] off,
                                        input logic unsigned_load);
    logic [31:0] shifted;
    begin
      shifted = word >> (8 * off);
      case (size)
        `SZ_BYTE: format_load = unsigned_load ? {24'b0, shifted[7:0]} :
                                                {{24{shifted[7]}}, shifted[7:0]};
        `SZ_HALF: format_load = unsigned_load ? {16'b0, shifted[15:0]} :
                                                {{16{shifted[15]}}, shifted[15:0]};
        default:  format_load = word;
      endcase
    end
  endfunction

  // ---- load 状态 ----------------------------------------------------------
  logic        load_active;
  logic        load_waiting;
  logic        load_inflight;
  logic        load_squashed;
  logic        load_illegal;
  logic [LW-1:0] load_id;
  logic [RW-1:0] load_rob;
  logic [PW-1:0] load_tag;
  logic [31:0]   load_addr;
  logic [1:0]    load_size;
  logic          load_unsigned;

  logic          query_valid;
  logic          query_blocked;

  assign query_valid = load_active && load_waiting;

  // 年轻判定：与 ROB/issue_queue 相同的模 ROB_DEPTH 距离约定。
  function automatic logic is_younger(input logic [RW-1:0] entry_rob,
                                      input logic [RW-1:0] squash_rob);
    logic [RW-1:0] diff;
    begin
      diff = (entry_rob - squash_rob) & ((1 << RW) - 1);
      is_younger = (diff != '0) && (diff < (`CPU_ROB_DEPTH/2));
    end
  endfunction

  logic load_squash_now;
  assign load_squash_now = squash_valid && load_active &&
                           is_younger(load_rob, squash_rob_idx);

  // ---- data_mem 状态 ------------------------------------------------------
  logic        mem_busy;
  logic        mem_owner_store;
  logic [31:0] mem_addr, mem_wdata;
  logic [3:0]  mem_wstrb;

  logic        store_drain_valid;
  logic [LW-1:0] store_drain_id;
  logic [31:0] store_drain_addr, store_drain_wdata;
  logic [3:0]  store_drain_wstrb;
  logic        drain_done;

  assign drain_done = mem_busy && mem_owner_store && data_resp_valid;

  assign busy = load_active || mem_busy || store_drain_valid;

  // ---- issue 握手 ---------------------------------------------------------
  logic load_issue, store_issue;

  assign load_issue  = issue_valid && issue_ready && issue_is_load;
  assign store_issue = issue_valid && issue_ready && issue_is_store;

  always_comb begin
    issue_ready = 1'b1;
    if (issue_is_load)
      issue_ready = !load_active && !load_result_valid;
  end

  // ---- LSQ 接口 -----------------------------------------------------------
  logic        fill_valid;
  logic [LW-1:0] fill_id;
  logic [31:0] fill_addr, fill_wdata;
  logic [3:0]  fill_wstrb;
  logic        fill_is_store;
  logic [7:0]  lsq_count;

  assign fill_valid    = load_issue || store_issue;
  assign fill_id       = issue_lsq;
  assign fill_addr     = issue_addr;
  assign fill_wdata    = issue_wdata;
  // Illegal stores must not modify memory: fill a zero write mask.
  assign fill_wstrb    = issue_illegal ? 4'b0 : issue_wstrb;
  assign fill_is_store = issue_is_store;

  lsq #(.W(W)) u_lsq (
    .clk             (clk),
    .reset           (reset),
    .alloc_valid     (alloc_valid),
    .alloc_id        (alloc_id),
    .alloc_rob       (alloc_rob),
    .alloc_is_store  (alloc_is_store),
    .alloc_ready     (alloc_ready),
    .fill_valid      (fill_valid),
    .fill_id         (fill_id),
    .fill_addr       (fill_addr),
    .fill_wdata      (fill_wdata),
    .fill_wstrb      (fill_wstrb),
    .fill_is_store   (fill_is_store),
    .commit_valid    (commit_valid),
    .commit_is_store (commit_is_store),
    .commit_is_load  (commit_is_load),
    .commit_id       (commit_id),
    .squash_valid    (squash_valid),
    .squash_rob_idx  (squash_rob_idx),
    .drain_valid     (store_drain_valid),
    .drain_id        (store_drain_id),
    .drain_addr      (store_drain_addr),
    .drain_wdata     (store_drain_wdata),
    .drain_wstrb     (store_drain_wstrb),
    .drain_done      (drain_done),
    .query_valid     (query_valid),
    .query_id        (load_id),
    .query_addr      (load_addr),
    .query_blocked   (query_blocked),
    .count           (lsq_count)
  );

  // ---- data_mem 握手 ------------------------------------------------------
  assign data_req_valid = mem_busy;
  assign data_req_we    = mem_owner_store;
  assign data_req_addr  = mem_addr;
  assign data_req_wdata = mem_wdata;
  assign data_req_wstrb = mem_wstrb;

  // ---- 结果寄存器 ---------------------------------------------------------
  logic                         load_result_valid_q;
  logic [PW-1:0]                load_result_tag_q;
  logic [31:0]                  load_result_value_q;
  logic                         load_result_exception_q;
  logic                         store_complete_valid_q;
  logic [PW-1:0]                store_complete_tag_q;
  logic [RW-1:0]                store_complete_rob_q;
  logic                         store_complete_exception_q;

  assign load_result_valid     = load_result_valid_q;
  assign load_result_tag       = load_result_tag_q;
  assign load_result_value     = load_result_value_q;
  assign load_result_exception = load_result_exception_q;
  assign store_complete_valid  = store_complete_valid_q;
  assign store_complete_tag    = store_complete_tag_q;
  assign store_complete_exception = store_complete_exception_q;

  // ---- 时序 ---------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      load_active            <= 1'b0;
      load_waiting           <= 1'b0;
      load_inflight          <= 1'b0;
      load_squashed          <= 1'b0;
      load_illegal           <= 1'b0;
      mem_busy               <= 1'b0;
      mem_owner_store        <= 1'b0;
      load_result_valid_q    <= 1'b0;
      store_complete_valid_q <= 1'b0;
    end else begin
      // 结果握手：CDB 吸收后清除；默认先清，再用本拍新响应覆盖。
      if (load_result_valid_q && load_result_ready)
        load_result_valid_q <= 1'b0;
      store_complete_valid_q <= 1'b0;

      // squash：等待中的 load 直接取消；已在内存管线中的等响应后丢弃。
      // store 的 complete 脉冲若属于年轻路径也必须撤销。
      if (squash_valid && store_complete_valid_q &&
          is_younger(store_complete_rob_q, squash_rob_idx))
        store_complete_valid_q <= 1'b0;
      if (load_squash_now) begin
        if (load_waiting && !load_inflight) begin
          load_active   <= 1'b0;
          load_waiting  <= 1'b0;
        end else if (load_inflight) begin
          load_squashed <= 1'b1;
        end
      end else if (load_active && load_waiting && !query_blocked) begin
        // 更老 store 约束满足，下一拍发起读请求。
        load_waiting  <= 1'b0;
        load_inflight <= 1'b1;
      end

      // 发射 load / store
      if (load_issue) begin
        if (issue_illegal) begin
          // 非法 load 不访问内存，直接产生异常结果；LSQ 表项仍保留到
          // commit 时按 load 释放。
          load_result_valid_q     <= 1'b1;
          load_result_tag_q       <= issue_dest;
          load_result_value_q     <= 32'b0;
          load_result_exception_q <= 1'b1;
        end else begin
          load_active   <= 1'b1;
          load_waiting  <= 1'b1;
          load_inflight <= 1'b0;
          load_squashed <= 1'b0;
          load_illegal  <= 1'b0;
          load_id       <= issue_lsq;
          load_rob      <= issue_rob;
          load_tag      <= issue_dest;
          load_addr     <= issue_addr;
          load_size     <= issue_mem_size;
          load_unsigned <= issue_mem_unsigned;
        end
      end

      if (store_issue) begin
        store_complete_valid_q     <= 1'b1;
        store_complete_tag_q       <= issue_dest;
        store_complete_rob_q       <= issue_rob;
        store_complete_exception_q <= issue_illegal;
      end

      // data_mem 请求启动：store drain 优先，其次 load。
      if (!mem_busy) begin
        if (store_drain_valid) begin
          mem_busy        <= 1'b1;
          mem_owner_store <= 1'b1;
          mem_addr        <= store_drain_addr;
          mem_wdata       <= store_drain_wdata;
          mem_wstrb       <= store_drain_wstrb;
        end else if (load_active && load_inflight && !load_squashed &&
                     !load_squash_now) begin
          mem_busy        <= 1'b1;
          mem_owner_store <= 1'b0;
          mem_addr        <= load_addr;
          mem_wdata       <= 32'b0;
          mem_wstrb       <= 4'b0;
        end
      end

      // data_mem 响应
      if (mem_busy && data_resp_valid) begin
        mem_busy <= 1'b0;
        if (!mem_owner_store) begin
          if (!load_squashed && !load_squash_now) begin
            load_result_valid_q     <= 1'b1;
            load_result_tag_q       <= load_tag;
            load_result_value_q     <= format_load(data_resp_rdata, load_size,
                                                   load_addr[1:0], load_unsigned);
            load_result_exception_q <= 1'b0;
          end
          load_active   <= 1'b0;
          load_waiting  <= 1'b0;
          load_inflight <= 1'b0;
          load_squashed <= 1'b0;
        end
      end
    end
  end

endmodule
