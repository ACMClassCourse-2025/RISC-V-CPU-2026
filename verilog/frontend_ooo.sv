// -----------------------------------------------------------------------------
// frontend_ooo.sv — 取指 / 译码 / 分支预测前端
//
// 组成：
//   pc_unit + icache_pipe + decoder + bpu
//   + W 项 decoded-uop 输出缓冲（吸收 rename 反压）
//
// P1 W=1：每拍取一条、填满 1 个 slot 后送出。
// P2 预研 W=2：I-Cache 仍每拍取一条，但用 2 个 slot 成组送给 rename/ROB，
// 用于验证双 lane 重命名/提交；还没有实现双宽 I-Cache 取指。
//
// 控制：
//   - backend_ready=0 时冻结取指与输出；
//   - ROB 的 redirect_valid/redirect_pc 冲刷 I-Cache、清空 slot、切 PC；
//   - br_update 每拍更新 BPU（upd_is_uncond 由 ROB 根据对应表项给出）。
// -----------------------------------------------------------------------------

module frontend_ooo #(
  parameter integer W = `CPU_ISSUE_WIDTH
) (
  input  logic        clk,
  input  logic        reset,

  input  logic        backend_ready,

  input  logic        redirect_valid,
  input  logic [31:0] redirect_pc,

  input  logic        br_update_valid,
  input  logic [31:0] br_update_pc,
  input  logic        br_update_taken,
  input  logic [31:0] br_update_target,
  input  logic        br_update_is_jalr,
  input  logic        br_update_uncond,
  input  logic [`CPU_PRF_IDX_W-1:0] br_update_tag,

  output logic [W-1:0]                 dec_valid,
  output logic [W*`CPU_DECODE_W-1:0]   dec_uop,
  output logic [W-1:0]                 dec_pred_taken,
  output logic [W*32-1:0]              dec_pred_target,
  input  logic                         rename_ready,

  output logic [31:0]                 pc_out,

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

  // ---- decoded-uop slot 缓冲 ---------------------------------------------
  logic [W-1:0]                 slot_valid;
  logic [`CPU_DECODE_W-1:0]     slot_uop   [0:W-1];
  logic                         slot_pred_taken  [0:W-1];
  logic [31:0]                  slot_pred_target [0:W-1];
  logic [2:0]                   fill_ptr;
  logic                         all_full;

  logic        fetch_valid;
  logic        resp_valid;
  logic [31:0] resp_pc;
  logic [31:0] resp_inst;
  logic        resp_ready;

  assign all_full = (fill_ptr == W);
  assign fetch_valid = backend_ready && !redirect_valid && (fill_ptr < W) && !reset;
  assign pc_advance  = fetch_valid && fetch_ready;
  assign resp_ready  = backend_ready && !redirect_valid && (fill_ptr < W);

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
  integer i_out;
  always_comb begin
    dec_valid       = '0;
    dec_uop         = '0;
    dec_pred_taken  = '0;
    dec_pred_target = '0;

    for (i_out = 0; i_out < W; i_out = i_out + 1) begin
      dec_valid[i_out] = all_full;
      dec_uop[i_out*`CPU_DECODE_W + `CPU_DISPATCH_PC_OFF +: 32] =
          slot_uop[i_out][`CPU_DISPATCH_PC_OFF +: 32];
      dec_uop[i_out*`CPU_DECODE_W + `CPU_DISPATCH_INST_OFF +: 32] =
          slot_uop[i_out][`CPU_DISPATCH_INST_OFF +: 32];
      dec_uop[i_out*`CPU_DECODE_W + `CPU_DISPATCH_IMM_OFF +: 32] =
          slot_uop[i_out][`CPU_DISPATCH_IMM_OFF +: 32];
      dec_uop[i_out*`CPU_DECODE_W + `CPU_DISPATCH_RD_OFF +: 5] =
          slot_uop[i_out][`CPU_DISPATCH_RD_OFF +: 5];
      dec_uop[i_out*`CPU_DECODE_W + `CPU_DISPATCH_REG_WE_OFF] =
          slot_uop[i_out][`CPU_DISPATCH_REG_WE_OFF];
      dec_uop[i_out*`CPU_DECODE_W + `CPU_DISPATCH_ALU_OP_OFF +: 5] =
          slot_uop[i_out][`CPU_DISPATCH_ALU_OP_OFF +: 5];
      dec_uop[i_out*`CPU_DECODE_W + `CPU_DISPATCH_A_SEL_OFF +: 2] =
          slot_uop[i_out][`CPU_DISPATCH_A_SEL_OFF +: 2];
      dec_uop[i_out*`CPU_DECODE_W + `CPU_DISPATCH_B_SEL_OFF] =
          slot_uop[i_out][`CPU_DISPATCH_B_SEL_OFF];
      dec_uop[i_out*`CPU_DECODE_W + `CPU_DISPATCH_WB_SEL_OFF +: 2] =
          slot_uop[i_out][`CPU_DISPATCH_WB_SEL_OFF +: 2];
      dec_uop[i_out*`CPU_DECODE_W + `CPU_DISPATCH_IS_BRANCH_OFF] =
          slot_uop[i_out][`CPU_DISPATCH_IS_BRANCH_OFF];
      dec_uop[i_out*`CPU_DECODE_W + `CPU_DISPATCH_IS_JAL_OFF] =
          slot_uop[i_out][`CPU_DISPATCH_IS_JAL_OFF];
      dec_uop[i_out*`CPU_DECODE_W + `CPU_DISPATCH_IS_JALR_OFF] =
          slot_uop[i_out][`CPU_DISPATCH_IS_JALR_OFF];
      dec_uop[i_out*`CPU_DECODE_W + `CPU_DISPATCH_IS_LOAD_OFF] =
          slot_uop[i_out][`CPU_DISPATCH_IS_LOAD_OFF];
      dec_uop[i_out*`CPU_DECODE_W + `CPU_DISPATCH_IS_STORE_OFF] =
          slot_uop[i_out][`CPU_DISPATCH_IS_STORE_OFF];
      dec_uop[i_out*`CPU_DECODE_W + `CPU_DISPATCH_ILLEGAL_OFF] =
          slot_uop[i_out][`CPU_DISPATCH_ILLEGAL_OFF];
      dec_uop[i_out*`CPU_DECODE_W + `CPU_DISPATCH_MEM_SIZE_OFF +: 2] =
          slot_uop[i_out][`CPU_DISPATCH_MEM_SIZE_OFF +: 2];
      dec_uop[i_out*`CPU_DECODE_W + `CPU_DISPATCH_MEM_UNSIGNED_OFF] =
          slot_uop[i_out][`CPU_DISPATCH_MEM_UNSIGNED_OFF];
      dec_uop[i_out*`CPU_DECODE_W + `CPU_DECODE_RS1_OFF +: 5] =
          slot_uop[i_out][`CPU_DECODE_RS1_OFF +: 5];
      dec_uop[i_out*`CPU_DECODE_W + `CPU_DECODE_RS2_OFF +: 5] =
          slot_uop[i_out][`CPU_DECODE_RS2_OFF +: 5];
      dec_pred_taken[i_out] = slot_pred_taken[i_out];
      dec_pred_target[i_out*32 +: 32] = slot_pred_target[i_out];
    end
  end

  // ---- slot 写入/释放 ----------------------------------------------------
  integer i_slot;
  always_ff @(posedge clk) begin
    if (reset || redirect_valid) begin
      slot_valid <= '0;
      fill_ptr   <= '0;
    end else begin
      if (resp_valid && resp_ready) begin
        for (i_slot = 0; i_slot < W; i_slot = i_slot + 1) begin
          if (i_slot == fill_ptr) begin
            slot_valid[i_slot] <= 1'b1;
            slot_uop[i_slot][`CPU_DISPATCH_PC_OFF +: 32]      <= resp_pc;
            slot_uop[i_slot][`CPU_DISPATCH_INST_OFF +: 32]    <= resp_inst;
            slot_uop[i_slot][`CPU_DISPATCH_IMM_OFF +: 32]     <= dec_imm;
            slot_uop[i_slot][`CPU_DISPATCH_RD_OFF +: 5]       <= dec_rd;
            slot_uop[i_slot][`CPU_DISPATCH_REG_WE_OFF]        <= dec_reg_we;
            slot_uop[i_slot][`CPU_DISPATCH_ALU_OP_OFF +: 5]   <= dec_alu_op;
            slot_uop[i_slot][`CPU_DISPATCH_A_SEL_OFF +: 2]    <= dec_a_sel;
            slot_uop[i_slot][`CPU_DISPATCH_B_SEL_OFF]         <= dec_b_sel;
            slot_uop[i_slot][`CPU_DISPATCH_WB_SEL_OFF +: 2]   <= dec_wb_sel;
            slot_uop[i_slot][`CPU_DISPATCH_IS_BRANCH_OFF]     <= dec_is_branch;
            slot_uop[i_slot][`CPU_DISPATCH_IS_JAL_OFF]        <= dec_is_jal;
            slot_uop[i_slot][`CPU_DISPATCH_IS_JALR_OFF]       <= dec_is_jalr;
            slot_uop[i_slot][`CPU_DISPATCH_IS_LOAD_OFF]       <= dec_is_load;
            slot_uop[i_slot][`CPU_DISPATCH_IS_STORE_OFF]      <= dec_is_store;
            slot_uop[i_slot][`CPU_DISPATCH_ILLEGAL_OFF]       <= dec_illegal;
            slot_uop[i_slot][`CPU_DISPATCH_MEM_SIZE_OFF +: 2] <= dec_mem_size;
            slot_uop[i_slot][`CPU_DISPATCH_MEM_UNSIGNED_OFF]  <= dec_mem_unsigned;
            slot_uop[i_slot][`CPU_DECODE_RS1_OFF +: 5]        <= dec_rs1;
            slot_uop[i_slot][`CPU_DECODE_RS2_OFF +: 5]        <= dec_rs2;
            slot_pred_taken[i_slot]  <= bpu_taken;
            slot_pred_target[i_slot] <= bpu_target;
          end
        end
        fill_ptr <= fill_ptr + 1'b1;
      end

      if (all_full && rename_ready) begin
        slot_valid <= '0;
        fill_ptr   <= '0;
      end
    end
  end

endmodule
