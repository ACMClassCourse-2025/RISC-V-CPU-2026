// -----------------------------------------------------------------------------
// icache_pipe.sv — P1 流水线指令 Cache（直接映射，行宽 1 字）
//
// 与基线 icache.sv 的区别：
//   - 两级流水：每拍可接收一个新 PC，命中时每拍输出一条指令；
//   - 明确的 fetch_valid/fetch_ready 与 fetch_resp_valid/fetch_resp_ready 握手；
//   - 缺失时保存一个 pending PC，回填响应先进入 1 项输出缓冲，保持顺序；
//   - 支持 flush：清除在途 lookup；若正在等回填，则进入 DRAIN，
//     等旧响应返回后丢弃，避免把旧数据写进 Cache 或送给前端；
//   - SRAM 只在 NORMAL 状态读，回填时写；读写不冲突。
//
// 结构：
//   s1：请求寄存器，驱动 tag/data SRAM 读地址；
//   s2：一个周期后寄存 s1 的 PC/tag 与 SRAM 读出的 tag/data/valid；
//       命中时组合输出；缺失时进入 REFILL。
//   buf：回填响应缓冲（1 项），保证输出顺序并吸收 fetch_resp_ready 反压。
//
// 行宽固定 4B（P1 契约）；P2 扩展多字行时在 REFILL 中按字写入即可。
// -----------------------------------------------------------------------------

module icache_pipe #(
  parameter integer INDEX_BITS = `CPU_ICACHE_INDEX_BITS
) (
  input  logic        clk,
  input  logic        reset,
  input  logic        flush,          // 重定向/冲刷，单拍有效，最高优先级

  // 前端取指请求
  input  logic        fetch_valid,
  input  logic [31:0] fetch_pc,
  output logic        fetch_ready,

  // 前端取指响应
  output logic        fetch_resp_valid,
  output logic [31:0] fetch_resp_pc,
  output logic [31:0] fetch_inst,
  input  logic        fetch_resp_ready,

  // 回填请求（占用 mem_subsystem 的 if_refill 客户口）
  output logic        refill_valid,
  output logic [31:0] refill_addr,
  input  logic        refill_resp_valid,
  input  logic [31:0] refill_rdata
);

  localparam integer DEPTH    = 1 << INDEX_BITS;
  localparam integer TAG_BITS = 32 - INDEX_BITS - 2;

  typedef enum logic [1:0] {
    ST_NORMAL,
    ST_REFILL,
    ST_DRAIN
  } state_t;

  state_t state;

  // s1：发起 SRAM 读
  logic                  s1_valid;
  logic [31:0]           s1_pc;
  logic [INDEX_BITS-1:0] s1_index;
  logic [TAG_BITS-1:0]   s1_tag;

  // s2：保存 s1 的元数据与 SRAM 读结果
  logic                  s2_valid;
  logic [31:0]           s2_pc;
  logic [TAG_BITS-1:0]   s2_tag;
  logic [TAG_BITS-1:0]   s2_tag_ram;
  logic [31:0]           s2_data;
  logic                  s2_line_valid;

  // 回填响应输出缓冲
  logic                  buf_valid;
  logic [31:0]           buf_pc;
  logic [31:0]           buf_inst;

  // 缺失时暂存 s1 中唯一的年轻 PC，回填后重试
  logic                  pending_valid;
  logic [31:0]           pending_pc;

  // 正在处理的回填
  logic [31:0]           refill_pc;
  logic [INDEX_BITS-1:0] refill_index;
  logic [TAG_BITS-1:0]   refill_tag;

  // SRAM 端口
  logic                  data_en, data_we;
  logic [INDEX_BITS-1:0] data_addr;
  logic [31:0]           data_wdata;
  logic [31:0]           data_rdata;

  logic                  tag_en, tag_we;
  logic [INDEX_BITS-1:0] tag_addr;
  logic [TAG_BITS-1:0]   tag_wdata;
  logic [TAG_BITS-1:0]   tag_rdata;

  logic [DEPTH-1:0]      valid;

  sram_fakeram #(
    .DEPTH (DEPTH),
    .WIDTH (32)
  ) data_ram (
    .clk   (clk),
    .en    (data_en),
    .we    (data_we),
    .wmask (1'b1),
    .addr  (data_addr),
    .wdata (data_wdata),
    .rdata (data_rdata)
  );

  sram_fakeram #(
    .DEPTH (DEPTH),
    .WIDTH (TAG_BITS)
  ) tag_ram (
    .clk   (clk),
    .en    (tag_en),
    .we    (tag_we),
    .wmask (1'b1),
    .addr  (tag_addr),
    .wdata (tag_wdata),
    .rdata (tag_rdata)
  );

  // ---- 索引与命中 ----------------------------------------------------------
  logic [INDEX_BITS-1:0] fetch_index;
  logic [TAG_BITS-1:0]   fetch_tag;

  assign fetch_index = fetch_pc[INDEX_BITS+1:2];
  assign fetch_tag   = fetch_pc[31:INDEX_BITS+2];

  logic s2_hit;
  assign s2_hit = s2_valid && s2_line_valid && (s2_tag_ram == s2_tag);

  // ---- 握手与流水控制 ------------------------------------------------------
  logic accept_fetch;
  logic s2_accept;
  logic s2_consume;
  logic load_pending;
  logic read_en;
  logic [INDEX_BITS-1:0] read_index;

  // s2 可以被新指令覆盖：空，或当前命中且被接收。
  assign s2_accept  = (state == ST_NORMAL) &&
                      (!s2_valid || (s2_hit && fetch_resp_ready));
  assign s2_consume = s2_valid && s2_hit && fetch_resp_ready;
  assign load_pending = (state == ST_NORMAL) && buf_valid && fetch_resp_ready &&
                        pending_valid;

  assign fetch_ready = (state == ST_NORMAL) && !flush && !buf_valid &&
                       !pending_valid && s2_accept;

  assign accept_fetch = (state == ST_NORMAL) && !flush && fetch_valid && fetch_ready;

  // 本拍给 SRAM 的读地址：优先新接收的 PC；否则保持 s1 以便 s2 反压时重读。
  assign read_en    = (state == ST_NORMAL) && !flush &&
                      (accept_fetch || load_pending ||
                       (s1_valid && !s2_accept));
  assign read_index = accept_fetch ? fetch_index :
                      (load_pending ? pending_pc[INDEX_BITS+1:2] : s1_index);

  // ---- SRAM 读写 ------------------------------------------------------------
  always_comb begin
    data_en    = 1'b0;
    data_we    = 1'b0;
    data_addr  = read_index;
    data_wdata = 32'b0;
    tag_en     = 1'b0;
    tag_we     = 1'b0;
    tag_addr   = read_index;
    tag_wdata  = refill_tag;

    if (read_en) begin
      data_en = 1'b1;
      tag_en  = 1'b1;
    end

    if (!flush && (state == ST_REFILL) && refill_resp_valid) begin
      data_en    = 1'b1;
      data_we    = 1'b1;
      data_addr  = refill_index;
      data_wdata = refill_rdata;
      tag_en     = 1'b1;
      tag_we     = 1'b1;
      tag_addr   = refill_index;
      tag_wdata  = refill_tag;
    end
  end

  // ---- 输出 ----------------------------------------------------------------
  assign fetch_resp_valid = !flush &&
                            (buf_valid || ((state == ST_NORMAL) && s2_valid && s2_hit));
  assign fetch_resp_pc    = buf_valid ? buf_pc : s2_pc;
  assign fetch_inst       = buf_valid ? buf_inst : s2_data;

  assign refill_valid = (state == ST_REFILL) || (state == ST_DRAIN);
  assign refill_addr  = {refill_tag, refill_index, 2'b00};

  // ---- 时序 ----------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      state         <= ST_NORMAL;
      s1_valid      <= 1'b0;
      s2_valid      <= 1'b0;
      buf_valid     <= 1'b0;
      pending_valid <= 1'b0;
      valid         <= '0;
      s1_pc         <= 32'b0;
      s1_index      <= '0;
      s1_tag        <= '0;
      s2_pc         <= 32'b0;
      s2_tag        <= '0;
      s2_tag_ram    <= '0;
      s2_data       <= 32'b0;
      s2_line_valid <= 1'b0;
      buf_pc        <= 32'b0;
      buf_inst      <= 32'b0;
      pending_pc    <= 32'b0;
      refill_pc     <= 32'b0;
      refill_index  <= '0;
      refill_tag    <= '0;
    end else if (flush) begin
      s1_valid      <= 1'b0;
      s2_valid      <= 1'b0;
      buf_valid     <= 1'b0;
      pending_valid <= 1'b0;

      // 正在等回填时不能直接丢请求：进入 DRAIN 等旧响应返回后丢弃。
      if (state == ST_REFILL) begin
        state <= refill_resp_valid ? ST_NORMAL : ST_DRAIN;
      end else if (state == ST_DRAIN) begin
        state <= refill_resp_valid ? ST_NORMAL : ST_DRAIN;
      end
    end else begin
      unique case (state)
        ST_NORMAL: begin
          // ---- s2 更新：miss 优先，其次接收 s1，最后消费 ----
          if (s2_valid && !s2_hit) begin
            // 缺失：记录回填信息，清空 s2；s1 中唯一的年轻 PC 存入 pending。
            state         <= ST_REFILL;
            refill_pc     <= s2_pc;
            refill_index  <= s2_pc[INDEX_BITS+1:2];
            refill_tag    <= s2_pc[31:INDEX_BITS+2];
            s2_valid      <= 1'b0;
            pending_valid <= s1_valid;
            if (s1_valid) pending_pc <= s1_pc;
            s1_valid      <= 1'b0;
          end else if (s2_accept && s1_valid) begin
            // s1 -> s2；同时把 s1 的 SRAM 读结果打一拍
            s2_valid      <= 1'b1;
            s2_pc         <= s1_pc;
            s2_tag        <= s1_tag;
            s2_tag_ram    <= tag_rdata;
            s2_data       <= data_rdata;
            s2_line_valid <= valid[s1_index];
            if (!accept_fetch) s1_valid <= 1'b0;
          end else if (s2_consume) begin
            s2_valid <= 1'b0;
          end

          // ---- s1 更新：新请求优先，其次 pending ----
          if (accept_fetch) begin
            s1_valid <= 1'b1;
            s1_pc    <= fetch_pc;
            s1_index <= fetch_index;
            s1_tag   <= fetch_tag;
          end else if (load_pending) begin
            s1_valid      <= 1'b1;
            s1_pc         <= pending_pc;
            s1_index      <= pending_pc[INDEX_BITS+1:2];
            s1_tag        <= pending_pc[31:INDEX_BITS+2];
            pending_valid <= 1'b0;
          end

          // ---- 回填缓冲消费 ----
          if (buf_valid && fetch_resp_ready) begin
            buf_valid <= 1'b0;
          end
        end

        ST_REFILL: begin
          if (refill_resp_valid) begin
            valid[refill_index] <= 1'b1;
            buf_valid           <= 1'b1;
            buf_pc              <= refill_pc;
            buf_inst            <= refill_rdata;
            state               <= ST_NORMAL;
          end
        end

        ST_DRAIN: begin
          if (refill_resp_valid) begin
            state <= ST_NORMAL;
          end
        end

        default: state <= ST_NORMAL;
      endcase
    end
  end

endmodule
