// -----------------------------------------------------------------------------
// backend_ooo.sv — 乱序执行后端薄封装（P1）
//
// 组成：
//   issue_queue -> PRF 读 -> ALU / divider / LSU
//   cdb 仲裁 -> ROB/rename + PRF 写 + IQ 唤醒
//   lsu（内含 lsq）-> data_mem
//
// P1 发射宽度固定 1（IW=1），但 dispatch 仍按 W 路整体吸收；W=2 时先证明
// 前端双 slot dispatch 能被后端正确接收，执行端口后续 P2 再扩宽。
// -----------------------------------------------------------------------------

module backend_ooo #(
  parameter integer W = `CPU_ISSUE_WIDTH
) (
  input  logic clk,
  input  logic reset,

  // core_ooo 冻结接口
  input  logic [`CPU_DISPATCH_BUS_W-1:0] dispatch,
  input  logic [`CPU_COMMIT_BUS_W-1:0]   commit,
  input  logic [`CPU_SQUASH_W-1:0]       squash,
  output logic [`CPU_CDB_BUS_W-1:0]      cdb,
  output logic [`CPU_COMPLETE_BUS_W-1:0] complete,
  output logic [`CPU_BR_UPDATE_W-1:0]    br_update,
  output logic                           backend_ready,

  // data_mem（接 mem_subsystem）
  output logic        data_req_valid,
  output logic        data_req_we,
  output logic [31:0] data_req_addr,
  output logic [31:0] data_req_wdata,
  output logic [3:0]  data_req_wstrb,
  input  logic        data_resp_valid,
  input  logic [31:0] data_resp_rdata
);

  localparam integer PW = `CPU_PRF_IDX_W;
  localparam integer RW = `CPU_ROB_TAG_W;
  localparam integer LW = `CPU_LSQ_IDX_W;
  localparam integer DW = `CPU_DISPATCH_W;
  localparam integer CW = `CPU_CDB_W;
  localparam integer MW = `CPU_COMPLETE_W;
  localparam integer R  = `CPU_CDB_NUM;

  // ---------------------------------------------------------------------------
  // dispatch / commit / squash 解包
  // ---------------------------------------------------------------------------
  logic [W-1:0]        disp_valid;
  logic [W-1:0]        disp_is_load, disp_is_store;
  logic [W*LW-1:0]     disp_lsq;
  logic [W*RW-1:0]     disp_rob;

  integer i;
  always_comb begin
    for (i = 0; i < W; i = i + 1) begin
      disp_valid[i]    = dispatch[i*DW + `CPU_DISPATCH_VALID_OFF];
      disp_is_load[i]  = dispatch[i*DW + `CPU_DISPATCH_IS_LOAD_OFF];
      disp_is_store[i] = dispatch[i*DW + `CPU_DISPATCH_IS_STORE_OFF];
      disp_lsq[i*LW +: LW] = dispatch[i*DW + `CPU_DISPATCH_LSQ_ID_OFF +: LW];
      disp_rob[i*RW +: RW] = dispatch[i*DW + `CPU_DISPATCH_ROB_IDX_OFF +: RW];
    end
  end

  logic [W-1:0]    cm_valid, cm_is_store, cm_is_load;
  logic [W*LW-1:0] cm_lsq;

  always_comb begin
    for (i = 0; i < W; i = i + 1) begin
      cm_valid[i]    = commit[i*`CPU_COMMIT_W + `CPU_COMMIT_VALID_OFF];
      cm_is_store[i] = commit[i*`CPU_COMMIT_W + `CPU_COMMIT_IS_STORE_OFF];
      cm_is_load[i]  = commit[i*`CPU_COMMIT_W + `CPU_COMMIT_IS_LOAD_OFF];
      cm_lsq[i*LW +: LW] = commit[i*`CPU_COMMIT_W + `CPU_COMMIT_LSQ_ID_OFF +: LW];
    end
  end

  logic        sq_valid;
  logic [RW-1:0] sq_rob;
  assign sq_valid = squash[`CPU_SQUASH_VALID_OFF];
  assign sq_rob   = squash[`CPU_SQUASH_ROB_IDX_OFF +: RW];

  // CDB -> IQ 唤醒（提前声明：IQ 例化使用）
  logic [R-1:0]    cdb_wake_valid;
  logic [R*PW-1:0] cdb_wake_tag;

  // ---------------------------------------------------------------------------
  // Issue Queue
  // ---------------------------------------------------------------------------
  logic        iq_in_ready;
  logic        iq_out_valid;
  logic [DW-1:0] issue_uop;
  logic        issue_ready;
  logic [7:0]  iq_count, iq_free;

  issue_queue #(.W(W), .IW(1)) u_iq (
    .clk            (clk),
    .reset          (reset),
    .in_valid       (disp_valid),
    .in_uop         (dispatch),
    .in_ready       (iq_in_ready),
    .wake_valid     (cdb_wake_valid),
    .wake_tag       (cdb_wake_tag),
    .squash_valid   (sq_valid),
    .squash_rob_idx (sq_rob),
    .out_valid      (iq_out_valid),
    .out_uop        (issue_uop),
    .out_ready      (issue_ready),
    .count          (iq_count),
    .free_count     (iq_free)
  );

  // ---------------------------------------------------------------------------
  // issue uop 字段
  // ---------------------------------------------------------------------------
  logic [31:0]   i_pc, i_inst, i_imm;
  logic [PW-1:0] i_dest, i_src1_tag, i_src2_tag;
  logic [4:0]    i_alu_op;
  logic [1:0]    i_a_sel, i_wb_sel;
  logic          i_b_sel, i_reg_we, i_illegal;
  logic          i_is_branch, i_is_jal, i_is_jalr;
  logic          i_is_load, i_is_store;

  assign i_pc          = issue_uop[`CPU_DISPATCH_PC_OFF +: 32];
  assign i_inst        = issue_uop[`CPU_DISPATCH_INST_OFF +: 32];
  assign i_imm         = issue_uop[`CPU_DISPATCH_IMM_OFF +: 32];
  assign i_dest        = issue_uop[`CPU_DISPATCH_DEST_TAG_OFF +: PW];
  assign i_src1_tag    = issue_uop[`CPU_DISPATCH_SRC1_TAG_OFF +: PW];
  assign i_src2_tag    = issue_uop[`CPU_DISPATCH_SRC2_TAG_OFF +: PW];
  assign i_alu_op      = issue_uop[`CPU_DISPATCH_ALU_OP_OFF +: 5];
  assign i_a_sel       = issue_uop[`CPU_DISPATCH_A_SEL_OFF +: 2];
  assign i_b_sel       = issue_uop[`CPU_DISPATCH_B_SEL_OFF];
  assign i_wb_sel      = issue_uop[`CPU_DISPATCH_WB_SEL_OFF +: 2];
  assign i_reg_we      = issue_uop[`CPU_DISPATCH_REG_WE_OFF];
  assign i_illegal     = issue_uop[`CPU_DISPATCH_ILLEGAL_OFF];
  assign i_is_branch   = issue_uop[`CPU_DISPATCH_IS_BRANCH_OFF];
  assign i_is_jal      = issue_uop[`CPU_DISPATCH_IS_JAL_OFF];
  assign i_is_jalr     = issue_uop[`CPU_DISPATCH_IS_JALR_OFF];
  assign i_is_load     = issue_uop[`CPU_DISPATCH_IS_LOAD_OFF];
  assign i_is_store    = issue_uop[`CPU_DISPATCH_IS_STORE_OFF];

  logic i_is_mem, i_is_div, i_is_branch_any;
  assign i_is_mem        = i_is_load | i_is_store;
  assign i_is_div        = (i_alu_op == `ALU_DIV) || (i_alu_op == `ALU_DIVU) ||
                           (i_alu_op == `ALU_REM) || (i_alu_op == `ALU_REMU);
  assign i_is_branch_any = i_is_branch | i_is_jal | i_is_jalr;

  // ---------------------------------------------------------------------------
  // PRF
  // ---------------------------------------------------------------------------
  logic [2*W*PW-1:0] prf_raddr;
  logic [2*W*32-1:0] prf_rdata;
  logic [R-1:0]      prf_we;
  logic [R*PW-1:0]   prf_waddr;
  logic [R*32-1:0]   prf_wdata;

  always_comb begin
    prf_raddr = '0;
    prf_raddr[0 +: PW]  = i_src1_tag;
    prf_raddr[PW +: PW] = i_src2_tag;
  end

  logic [31:0] issue_src1, issue_src2;
  assign issue_src1 = prf_rdata[0 +: 32];
  assign issue_src2 = prf_rdata[32 +: 32];

  always_comb begin
    for (i = 0; i < R; i = i + 1) begin
      prf_we[i] = cdb[i*CW + `CPU_CDB_VALID_OFF];
      prf_waddr[i*PW +: PW] = cdb[i*CW + `CPU_CDB_TAG_OFF +: PW];
      prf_wdata[i*32 +: 32] = cdb[i*CW + `CPU_CDB_VALUE_OFF +: 32];
    end
  end

  prf #(.W(W), .R(R)) u_prf (
    .clk   (clk),
    .reset (reset),
    .raddr (prf_raddr),
    .rdata (prf_rdata),
    .we    (prf_we),
    .waddr (prf_waddr),
    .wdata (prf_wdata)
  );

  // ---------------------------------------------------------------------------
  // ALU
  // ---------------------------------------------------------------------------
  logic [31:0] alu_a, alu_b, alu_y;
  logic [31:0] i_pc_plus4;
  assign i_pc_plus4 = i_pc + 32'd4;

  always_comb begin
    alu_a = (i_a_sel == `A_REG)  ? issue_src1 :
            (i_a_sel == `A_PC)   ? i_pc :
                                   32'b0;
    alu_b = i_b_sel ? i_imm : issue_src2;
  end

  alu u_alu (
    .a  (alu_a),
    .b  (alu_b),
    .op (i_alu_op),
    .y  (alu_y)
  );

  logic [31:0] wb_value;
  assign wb_value = (i_wb_sel == `WB_PC4) ? i_pc_plus4 : alu_y;

  // ---------------------------------------------------------------------------
  // 分支解析
  // ---------------------------------------------------------------------------
  logic        br_taken;
  logic [31:0] br_target;

  always_comb begin
    br_taken  = 1'b0;
    br_target = i_pc + i_imm;
    if (i_is_jal) begin
      br_taken  = 1'b1;
      br_target = i_pc + i_imm;
    end else if (i_is_jalr) begin
      br_taken  = 1'b1;
      br_target = (issue_src1 + i_imm) & ~32'h1;
    end else if (i_is_branch) begin
      unique case (i_inst[14:12])
        3'b000: br_taken = (issue_src1 == issue_src2);
        3'b001: br_taken = (issue_src1 != issue_src2);
        3'b100: br_taken = ($signed(issue_src1) < $signed(issue_src2));
        3'b101: br_taken = ($signed(issue_src1) >= $signed(issue_src2));
        3'b110: br_taken = (issue_src1 < issue_src2);
        3'b111: br_taken = (issue_src1 >= issue_src2);
        default: br_taken = 1'b0;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // 执行结果缓冲（P1 单发射）
  // ---------------------------------------------------------------------------
  logic        alu_valid_q;
  logic [PW-1:0] alu_tag_q;
  logic [31:0] alu_value_q;
  logic        alu_exc_q;

  logic        div_valid_q;
  logic [PW-1:0] div_tag_q;
  logic [31:0] div_value_q;
  logic        div_exc_q;

  logic        br_valid_q;
  logic [31:0] br_pc_q, br_target_q;
  logic        br_taken_q, br_jalr_q;
  logic [PW-1:0] br_tag_q;

  logic        be_complete_valid_q;
  logic [PW-1:0] be_complete_tag_q;
  logic        be_complete_exc_q;

  // 需要 ALU 产生 CDB 值的 uop
  logic needs_alu_result;
  assign needs_alu_result = !i_is_mem && !i_is_div && i_reg_we && !i_illegal;

  logic alu_issue_ready;
  assign alu_issue_ready = !needs_alu_result ||
                           !alu_valid_q || cdb_src_ready[0];

  // divider
  logic        div_start, div_busy, div_done;
  logic        div_is_signed;
  logic [31:0] div_quot, div_rem;
  logic [4:0]  div_op_q;
  logic [PW-1:0] div_tag_pending;
  logic        div_exc_pending;

  assign div_is_signed = (i_alu_op == `ALU_DIV) || (i_alu_op == `ALU_REM);

  logic div_issue_ready;
  assign div_issue_ready = !div_busy && !div_done && !div_valid_q;

  divider u_div (
    .clk       (clk),
    .reset     (reset),
    .start     (div_start),
    .is_signed (div_is_signed),
    .a         (issue_src1),
    .b         (issue_src2),
    .busy      (div_busy),
    .done      (div_done),
    .quotient  (div_quot),
    .remainder (div_rem)
  );

  // LSU
  logic        lsu_issue_ready;
  logic        lsu_load_valid;
  logic [PW-1:0] lsu_load_tag;
  logic [31:0] lsu_load_value;
  logic        lsu_load_exc;
  logic        lsu_store_valid;
  logic [PW-1:0] lsu_store_tag;
  logic        lsu_store_exc;
  logic        lsu_alloc_ready;
  logic        lsu_busy;

  lsu #(.W(W)) u_lsu (
    .clk                  (clk),
    .reset                (reset),
    .alloc_valid          (disp_valid & (disp_is_load | disp_is_store)),
    .alloc_id             (disp_lsq),
    .alloc_rob            (disp_rob),
    .alloc_is_store       (disp_is_store),
    .alloc_ready          (lsu_alloc_ready),
    .issue_valid          (iq_out_valid && issue_ready && i_is_mem),
    .issue_uop            (issue_uop),
    .issue_src1           (issue_src1),
    .issue_src2           (issue_src2),
    .issue_ready          (lsu_issue_ready),
    .commit_valid         (cm_valid),
    .commit_is_store      (cm_is_store),
    .commit_is_load       (cm_is_load),
    .commit_id            (cm_lsq),
    .squash_valid         (sq_valid),
    .squash_rob_idx       (sq_rob),
    .load_result_valid    (lsu_load_valid),
    .load_result_tag      (lsu_load_tag),
    .load_result_value    (lsu_load_value),
    .load_result_exception(lsu_load_exc),
    .load_result_ready    (cdb_src_ready[W]),
    .store_complete_valid (lsu_store_valid),
    .store_complete_tag   (lsu_store_tag),
    .store_complete_exception (lsu_store_exc),
    .data_req_valid       (data_req_valid),
    .data_req_we          (data_req_we),
    .data_req_addr        (data_req_addr),
    .data_req_wdata       (data_req_wdata),
    .data_req_wstrb       (data_req_wstrb),
    .data_resp_valid      (data_resp_valid),
    .data_resp_rdata      (data_resp_rdata),
    .busy                 (lsu_busy)
  );

  // ---------------------------------------------------------------------------
  // issue 路由
  // ---------------------------------------------------------------------------
  assign issue_ready = i_is_mem ? lsu_issue_ready :
                       i_is_div ? div_issue_ready :
                                  alu_issue_ready;

  logic alu_issue, div_issue;
  assign alu_issue = iq_out_valid && issue_ready && !i_is_mem && !i_is_div;
  assign div_issue = iq_out_valid && issue_ready && i_is_div;

  assign div_start = div_issue;

  // ---------------------------------------------------------------------------
  // CDB
  // ---------------------------------------------------------------------------
  localparam integer N = W + 2;
  logic [N-1:0]                   cdb_src_valid;
  logic [N*PW-1:0]                cdb_src_tag;
  logic [N*32-1:0]                cdb_src_value;
  logic [N-1:0]                   cdb_src_exc;
  logic [N-1:0]                   cdb_src_ready;
  logic [`CPU_CDB_BUS_W-1:0]      cdb_out;

  always_comb begin
    cdb_src_valid = '0;
    cdb_src_tag   = '0;
    cdb_src_value = '0;
    cdb_src_exc   = '0;

    cdb_src_valid[0] = alu_valid_q;
    cdb_src_tag[0 +: PW] = alu_tag_q;
    cdb_src_value[0 +: 32] = alu_value_q;
    cdb_src_exc[0] = alu_exc_q;

    cdb_src_valid[W] = lsu_load_valid;
    cdb_src_tag[W*PW +: PW] = lsu_load_tag;
    cdb_src_value[W*32 +: 32] = lsu_load_value;
    cdb_src_exc[W] = lsu_load_exc;

    cdb_src_valid[W+1] = div_valid_q;
    cdb_src_tag[(W+1)*PW +: PW] = div_tag_q;
    cdb_src_value[(W+1)*32 +: 32] = div_value_q;
    cdb_src_exc[W+1] = div_exc_q;
  end

  cdb #(.W(W), .R(R)) u_cdb (
    .clk           (clk),
    .reset         (reset),
    .src_valid     (cdb_src_valid),
    .src_tag       (cdb_src_tag),
    .src_value     (cdb_src_value),
    .src_exception (cdb_src_exc),
    .src_ready     (cdb_src_ready),
    .cdb_out       (cdb_out)
  );

  assign cdb = cdb_out;

  // CDB -> IQ 唤醒
  always_comb begin
    for (i = 0; i < R; i = i + 1) begin
      cdb_wake_valid[i] = cdb_out[i*CW + `CPU_CDB_VALID_OFF];
      cdb_wake_tag[i*PW +: PW] = cdb_out[i*CW + `CPU_CDB_TAG_OFF +: PW];
    end
  end

  // ---------------------------------------------------------------------------
  // 结果缓冲时序
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      alu_valid_q  <= 1'b0;
      div_valid_q  <= 1'b0;
      br_valid_q   <= 1'b0;
      be_complete_valid_q <= 1'b0;
      div_tag_pending <= '0;
      div_op_q <= '0;
      div_exc_pending <= 1'b0;
    end else begin
      // ALU 结果
      if (alu_valid_q && cdb_src_ready[0])
        alu_valid_q <= 1'b0;
      if (alu_issue && needs_alu_result) begin
        alu_valid_q  <= 1'b1;
        alu_tag_q    <= i_dest;
        alu_value_q  <= wb_value;
        alu_exc_q    <= 1'b0;
      end

      // divider 结果
      if (div_valid_q && cdb_src_ready[W+1])
        div_valid_q <= 1'b0;
      if (div_issue) begin
        div_tag_pending <= i_dest;
        div_op_q        <= i_alu_op;
        div_exc_pending <= i_illegal;
      end
      if (div_done) begin
        div_valid_q <= 1'b1;
        div_tag_q   <= div_tag_pending;
        div_value_q <= ((div_op_q == `ALU_DIV) || (div_op_q == `ALU_DIVU))
                       ? div_quot : div_rem;
        div_exc_q   <= div_exc_pending;
      end

      // 分支更新 / 无值完成
      br_valid_q <= 1'b0;
      be_complete_valid_q <= 1'b0;
      if (alu_issue && i_is_branch_any) begin
        br_valid_q  <= 1'b1;
        br_pc_q     <= i_pc;
        br_taken_q  <= br_taken;
        br_target_q <= br_target;
        br_jalr_q   <= i_is_jalr;
        br_tag_q    <= i_dest;
      end
      if (alu_issue && (i_illegal || (!i_reg_we && !i_is_mem))) begin
        be_complete_valid_q <= 1'b1;
        be_complete_tag_q   <= i_dest;
        be_complete_exc_q   <= i_illegal;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // complete / br_update 打包
  // ---------------------------------------------------------------------------
  always_comb begin
    complete = '0;
    if (lsu_store_valid) begin
      complete[`CPU_COMPLETE_VALID_OFF] = 1'b1;
      complete[`CPU_COMPLETE_TAG_OFF +: PW] = lsu_store_tag;
      complete[`CPU_COMPLETE_EXCEPTION_OFF] = lsu_store_exc;
    end else if (be_complete_valid_q) begin
      complete[`CPU_COMPLETE_VALID_OFF] = 1'b1;
      complete[`CPU_COMPLETE_TAG_OFF +: PW] = be_complete_tag_q;
      complete[`CPU_COMPLETE_EXCEPTION_OFF] = be_complete_exc_q;
    end
  end

  always_comb begin
    br_update = '0;
    if (br_valid_q) begin
      br_update[`CPU_BR_VALID_OFF] = 1'b1;
      br_update[`CPU_BR_PC_OFF +: 32] = br_pc_q;
      br_update[`CPU_BR_TAKEN_OFF] = br_taken_q;
      br_update[`CPU_BR_TARGET_OFF +: 32] = br_target_q;
      br_update[`CPU_BR_IS_JALR_OFF] = br_jalr_q;
      br_update[`CPU_BR_TAG_OFF +: PW] = br_tag_q;
    end
  end

  // ---------------------------------------------------------------------------
  // backend_ready
  // ---------------------------------------------------------------------------
  assign backend_ready = iq_in_ready && lsu_alloc_ready;

endmodule
