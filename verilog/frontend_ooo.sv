// -----------------------------------------------------------------------------
// frontend_ooo.sv — 取指 / 译码 / 分支预测前端（P1，W=1 取指）
//
// 组成：
//   pc_unit + icache_pipe + decoder + bpu
//   + 1 项 decoded-uop 输出缓冲（吸收 rename 反压）
//
// 数据流：
//   pc_unit -> icache_pipe -> decoder -> decoded uop buffer -> rename
//   bpu 在 fetch 响应 PC 上做组合预测，预测信息随 uop 一起送给 rename/ROB。
//
// 控制：
//   - backend_ready=0 时冻结取指与输出；
//   - ROB 的 redirect_valid/redirect_pc 冲刷 I-Cache 并切 PC；
//   - br_update 每拍更新 BPU（upd_is_uncond 由 ROB 根据对应表项给出）。
//
// 当前只使用 lane 0 输出；W>1 时为 P2 双宽取指预留接口，lane 1..W-1 保持无效。
// -----------------------------------------------------------------------------

module frontend_ooo #(
  parameter integer W = `CPU_ISSUE_WIDTH
) (
  input  logic        clk,
  input  logic        reset,

  // 后端反压
  input  logic        backend_ready,

  // 来自 ROB 的重定向
  input  logic        redirect_valid,
  input  logic [31:0] redirect_pc,

  // 来自后端的通用寄存器重命名/预测更新信息
  input  logic        br_update_valid,
  input  logic [31:0] br_update_pc,
  input  logic        br_update_taken,
  input  logic [31:0] br_update_target,
  input  logic        br_update_is_jalr,
  input  logic        br_update_uncond,
  input  logic [`CPU_PRF_IDX_W-1:0] br_update_tag,

  // decoded uop 输出（送 rename）
  output logic [W-1:0]                 dec_valid,
  output logic [W*`CPU_DECODE_W-1:0]   dec_uop,
  output logic [W-1:0]                 dec_pred_taken,
  output logic [W*32-1:0]              dec_pred_target,
  input  logic                         rename_ready,

  output logic [31:0]                 pc_out,

  // I-Cache 回填
  output logic        refill_valid,
  output logic [31:0] refill_addr,
  input  logic        refill_resp_valid,
  input  logic [31:0] refill_rdata
);

  localparam integer PW = `CPU_PRF_IDX_W;

  // ---- PC ----------------------------------------------------------------
  logic [31:0] pc;
  logic        pc_advance;
  logic        fetch_ready;

  pc_unit u_pc (
    .clk            (clk),
    .reset          (reset),
    .advance        (pc_advance),
    .stall          (1'b0),
    .redirect_valid (redirect_valid),
    .redirect_pc    (redirect_pc),
    .pc             (pc)
  );

  assign pc_out = pc;

  // ---- 输出缓冲 ----------------------------------------------------------
  logic                        buf_valid;
  logic [`CPU_DECODE_W-1:0]    buf_uop;
  logic                        buf_pred_taken;
  logic [31:0]                 buf_pred_target;

  logic        fetch_valid;
  logic        resp_valid;
  logic [31:0] resp_pc;
  logic [31:0] resp_inst;
  logic        resp_ready;

  // 缓冲空或本拍被 rename 消费时，可以接收新响应/继续取指。
  logic buf_can_accept;
  assign buf_can_accept = !buf_valid || rename_ready;

  assign fetch_valid = backend_ready && !redirect_valid && buf_can_accept && !reset;
  assign pc_advance  = fetch_valid && fetch_ready;

  icache_pipe #(
    .INDEX_BITS (`CPU_ICACHE_INDEX_BITS)
  ) u_icache (
    .clk               (clk),
    .reset             (reset),
    .flush             (redirect_valid),
    .fetch_valid       (fetch_valid),
    .fetch_pc          (pc),
    .fetch_ready       (fetch_ready),
    .fetch_resp_valid  (resp_valid),
    .fetch_resp_pc     (resp_pc),
    .fetch_inst        (resp_inst),
    .fetch_resp_ready  (resp_ready),
    .refill_valid      (refill_valid),
    .refill_addr       (refill_addr),
    .refill_resp_valid (refill_resp_valid),
    .refill_rdata      (refill_rdata)
  );

  assign resp_ready = backend_ready && !redirect_valid && buf_can_accept;

  // ---- 译码 --------------------------------------------------------------
  logic [4:0]  dec_rs1, dec_rs2, dec_rd;
  logic        dec_reg_we;
  logic [1:0]  dec_wb_sel;
  logic [4:0]  dec_alu_op;
  logic [1:0]  dec_a_sel;
  logic        dec_b_sel;
  logic [31:0] dec_imm;
  logic        dec_is_branch, dec_is_jal, dec_is_jalr;
  logic        dec_is_load, dec_is_store;
  logic [1:0]  dec_mem_size;
  logic        dec_mem_unsigned;
  logic        dec_illegal;

  decoder u_decoder (
    .instr        (resp_inst),
    .rs1          (dec_rs1),
    .rs2          (dec_rs2),
    .rd           (dec_rd),
    .reg_we       (dec_reg_we),
    .wb_sel       (dec_wb_sel),
    .alu_op       (dec_alu_op),
    .a_sel        (dec_a_sel),
    .b_sel        (dec_b_sel),
    .imm          (dec_imm),
    .is_branch    (dec_is_branch),
    .is_jal       (dec_is_jal),
    .is_jalr      (dec_is_jalr),
    .is_load      (dec_is_load),
    .is_store     (dec_is_store),
    .mem_size     (dec_mem_size),
    .mem_unsigned (dec_mem_unsigned),
    .illegal      (dec_illegal)
  );

  // ---- BPU ---------------------------------------------------------------
  logic        bpu_taken;
  logic [31:0] bpu_target;

  bpu u_bpu (
    .clk             (clk),
    .reset           (reset),
    .fetch_pc        (resp_pc),
    .predict_taken   (bpu_taken),
    .predict_target  (bpu_target),
    .upd_valid       (br_update_valid),
    .upd_pc          (br_update_pc),
    .upd_taken       (br_update_taken),
    .upd_target      (br_update_target),
    .upd_is_uncond   (br_update_uncond)
  );

  // ---- 输出 --------------------------------------------------------------
  always_comb begin
    dec_valid       = '0;
    dec_uop         = '0;
    dec_pred_taken  = '0;
    dec_pred_target = '0;

    dec_valid[0] = buf_valid && !redirect_valid;

    dec_uop[`CPU_DISPATCH_PC_OFF +: 32]            = buf_uop[`CPU_DISPATCH_PC_OFF +: 32];
    dec_uop[`CPU_DISPATCH_INST_OFF +: 32]          = buf_uop[`CPU_DISPATCH_INST_OFF +: 32];
    dec_uop[`CPU_DISPATCH_IMM_OFF +: 32]           = buf_uop[`CPU_DISPATCH_IMM_OFF +: 32];
    dec_uop[`CPU_DISPATCH_RD_OFF +: 5]             = buf_uop[`CPU_DISPATCH_RD_OFF +: 5];
    dec_uop[`CPU_DISPATCH_REG_WE_OFF]              = buf_uop[`CPU_DISPATCH_REG_WE_OFF];
    dec_uop[`CPU_DISPATCH_ALU_OP_OFF +: 5]         = buf_uop[`CPU_DISPATCH_ALU_OP_OFF +: 5];
    dec_uop[`CPU_DISPATCH_A_SEL_OFF +: 2]          = buf_uop[`CPU_DISPATCH_A_SEL_OFF +: 2];
    dec_uop[`CPU_DISPATCH_B_SEL_OFF]               = buf_uop[`CPU_DISPATCH_B_SEL_OFF];
    dec_uop[`CPU_DISPATCH_WB_SEL_OFF +: 2]         = buf_uop[`CPU_DISPATCH_WB_SEL_OFF +: 2];
    dec_uop[`CPU_DISPATCH_IS_BRANCH_OFF]           = buf_uop[`CPU_DISPATCH_IS_BRANCH_OFF];
    dec_uop[`CPU_DISPATCH_IS_JAL_OFF]              = buf_uop[`CPU_DISPATCH_IS_JAL_OFF];
    dec_uop[`CPU_DISPATCH_IS_JALR_OFF]             = buf_uop[`CPU_DISPATCH_IS_JALR_OFF];
    dec_uop[`CPU_DISPATCH_IS_LOAD_OFF]             = buf_uop[`CPU_DISPATCH_IS_LOAD_OFF];
    dec_uop[`CPU_DISPATCH_IS_STORE_OFF]            = buf_uop[`CPU_DISPATCH_IS_STORE_OFF];
    dec_uop[`CPU_DISPATCH_ILLEGAL_OFF]             = buf_uop[`CPU_DISPATCH_ILLEGAL_OFF];
    dec_uop[`CPU_DISPATCH_MEM_SIZE_OFF +: 2]       = buf_uop[`CPU_DISPATCH_MEM_SIZE_OFF +: 2];
    dec_uop[`CPU_DISPATCH_MEM_UNSIGNED_OFF]        = buf_uop[`CPU_DISPATCH_MEM_UNSIGNED_OFF];
    dec_uop[`CPU_DECODE_RS1_OFF +: 5]              = buf_uop[`CPU_DECODE_RS1_OFF +: 5];
    dec_uop[`CPU_DECODE_RS2_OFF +: 5]              = buf_uop[`CPU_DECODE_RS2_OFF +: 5];

    dec_pred_taken[0]  = buf_pred_taken;
    dec_pred_target[0 +: 32] = buf_pred_target;
  end

  // ---- 时序 --------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset || redirect_valid) begin
      buf_valid <= 1'b0;
    end else begin
      if (resp_valid && resp_ready) begin
        buf_valid         <= 1'b1;
        buf_uop[`CPU_DISPATCH_PC_OFF +: 32]      <= resp_pc;
        buf_uop[`CPU_DISPATCH_INST_OFF +: 32]    <= resp_inst;
        buf_uop[`CPU_DISPATCH_IMM_OFF +: 32]     <= dec_imm;
        buf_uop[`CPU_DISPATCH_RD_OFF +: 5]       <= dec_rd;
        buf_uop[`CPU_DISPATCH_REG_WE_OFF]        <= dec_reg_we;
        buf_uop[`CPU_DISPATCH_ALU_OP_OFF +: 5]   <= dec_alu_op;
        buf_uop[`CPU_DISPATCH_A_SEL_OFF +: 2]    <= dec_a_sel;
        buf_uop[`CPU_DISPATCH_B_SEL_OFF]         <= dec_b_sel;
        buf_uop[`CPU_DISPATCH_WB_SEL_OFF +: 2]   <= dec_wb_sel;
        buf_uop[`CPU_DISPATCH_IS_BRANCH_OFF]     <= dec_is_branch;
        buf_uop[`CPU_DISPATCH_IS_JAL_OFF]        <= dec_is_jal;
        buf_uop[`CPU_DISPATCH_IS_JALR_OFF]       <= dec_is_jalr;
        buf_uop[`CPU_DISPATCH_IS_LOAD_OFF]       <= dec_is_load;
        buf_uop[`CPU_DISPATCH_IS_STORE_OFF]      <= dec_is_store;
        buf_uop[`CPU_DISPATCH_ILLEGAL_OFF]       <= dec_illegal;
        buf_uop[`CPU_DISPATCH_MEM_SIZE_OFF +: 2] <= dec_mem_size;
        buf_uop[`CPU_DISPATCH_MEM_UNSIGNED_OFF]  <= dec_mem_unsigned;
        buf_uop[`CPU_DECODE_RS1_OFF +: 5]        <= dec_rs1;
        buf_uop[`CPU_DECODE_RS2_OFF +: 5]        <= dec_rs2;
        buf_pred_taken                            <= bpu_taken;
        buf_pred_target                           <= bpu_target;
      end else if (buf_valid && rename_ready) begin
        buf_valid <= 1'b0;
      end
    end
  end

endmodule
