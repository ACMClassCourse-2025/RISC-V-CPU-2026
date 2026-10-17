// -----------------------------------------------------------------------------
// frontend_subsystem.sv — 前端子系统联测顶层（只用于 test/frontend_test）
//
// frontend_ooo -> rename -> rob -> stub_exec
//   stub_exec 返回 cdb/complete/br_update；
//   rob 返回 commit、redirect、recover；
//   refill 口暴露给 C++ TB 的指令内存模型。
// -----------------------------------------------------------------------------

module frontend_subsystem #(
  parameter integer W = `CPU_ISSUE_WIDTH
) (
  input  logic        clk,
  input  logic        reset,

  input  logic        force_stall,
  input  logic        force_taken,
  input  logic [31:0] force_target,

  output logic        refill_valid,
  output logic [31:0] refill_addr,
  input  logic        refill_resp_valid,
  input  logic [31:0] refill_rdata,

  output logic [W-1:0]                 commit_valid,
  output logic [W*`CPU_PRF_IDX_W-1:0]  commit_tag,
  output logic [W*`CPU_LSQ_IDX_W-1:0]  commit_lsq_id,
  output logic [W-1:0]                 commit_is_store,
  output logic [W-1:0]                 commit_is_load,
  output logic [W*32-1:0]              commit_pc,
  output logic [W*32-1:0]              commit_inst,
  output logic                         commit_halt,

  output logic        redirect_valid,
  output logic [31:0] redirect_pc,
  output logic [31:0] frontend_pc,
  output logic        backend_ready,
  output logic        rob_ready
);

  localparam integer PW = `CPU_PRF_IDX_W;
  localparam integer RW = `CPU_ROB_TAG_W;
  localparam integer LW = `CPU_LSQ_IDX_W;

  // frontend <-> rename
  logic [W-1:0]               dec_valid;
  logic [W*`CPU_DECODE_W-1:0] dec_uop;
  logic [W-1:0]               dec_pred_taken;
  logic [W*32-1:0]            dec_pred_target;
  logic                       rename_ready;

  // rename <-> rob
  logic [W-1:0]               ren_valid;
  logic [W*`CPU_RENAME_W-1:0] ren_uop;
  logic [W*PW-1:0]            ren_old_tag;
  logic                       ren_ready;
  logic [W-1:0]               ren_fire;

  // rob <-> stub
  logic                       be_ready;
  logic                       rob_in_ready;
  logic [W*RW-1:0]            alloc_rob_idx;

  // wake
  logic [W-1:0]               wake_valid;
  logic [W*PW-1:0]            wake_tag;

  // stub -> rob
  logic                       s_cdb_valid;
  logic [PW-1:0]              s_cdb_tag;
  logic                       s_cdb_exc;
  logic [W-1:0]               s_comp_valid;
  logic [W*PW-1:0]            s_comp_tag;
  logic [W-1:0]               s_comp_exc;

  logic                       s_br_valid;
  logic [31:0]                s_br_pc, s_br_target;
  logic                       s_br_taken, s_br_jalr;
  logic [PW-1:0]              s_br_tag;
  logic                       s_br_uncond;

  // rob -> rename
  logic                       rec_valid;
  logic [`CPU_PRF_SIZE-1:0]   rec_free, rec_busy;
  logic [LW-1:0]              rec_lsq;
  logic [W-1:0]               cm_valid, cm_reg_we, cm_free_valid;
  logic [W*5-1:0]             cm_rd;
  logic [W*PW-1:0]            cm_dest, cm_free;

  // rob -> stub squash
  logic                       sq_valid;
  logic [RW-1:0]              sq_idx;

  frontend_ooo #(.W(W)) u_front (
    .clk               (clk),
    .reset             (reset),
    .backend_ready     (be_ready && rob_in_ready),
    .redirect_valid    (redirect_valid),
    .redirect_pc       (redirect_pc),
    .br_update_valid   (s_br_valid),
    .br_update_pc      (s_br_pc),
    .br_update_taken   (s_br_taken),
    .br_update_target  (s_br_target),
    .br_update_is_jalr (s_br_jalr),
    .br_update_uncond  (s_br_uncond),
    .br_update_tag     (s_br_tag),
    .dec_valid         (dec_valid),
    .dec_uop           (dec_uop),
    .dec_pred_taken    (dec_pred_taken),
    .dec_pred_target   (dec_pred_target),
    .rename_ready      (rename_ready),
    .pc_out            (frontend_pc),
    .refill_valid      (refill_valid),
    .refill_addr       (refill_addr),
    .refill_resp_valid (refill_resp_valid),
    .refill_rdata      (refill_rdata)
  );

  rename #(.W(W)) u_rename (
    .clk               (clk),
    .reset             (reset),
    .in_valid          (dec_valid),
    .in_uop            (dec_uop),
    .in_ready          (rename_ready),
    .out_valid         (ren_valid),
    .out_uop           (ren_uop),
    .out_old_tag       (ren_old_tag),
    .out_ready         (ren_ready),
    .commit_valid      (cm_valid),
    .commit_rd         (cm_rd),
    .commit_dest_tag   (cm_dest),
    .commit_reg_we     (cm_reg_we),
    .commit_free_valid (cm_free_valid),
    .commit_free_tag   (cm_free),
    .wake_valid        (wake_valid),
    .wake_tag          (wake_tag),
    .recover_valid     (rec_valid),
    .recover_free_mask (rec_free),
    .recover_busy_mask (rec_busy),
    .recover_lsq_ptr   (rec_lsq)
  );

  rob #(.W(W)) u_rob (
    .clk                (clk),
    .reset              (reset),
    .in_valid           (ren_fire),
    .in_uop             (ren_uop),
    .in_old_tag         (ren_old_tag),
    .in_pred_taken      (dec_pred_taken),
    .in_pred_target     (dec_pred_target),
    .in_ready           (rob_in_ready),
    .alloc_rob_idx      (alloc_rob_idx),
    .cdb_valid          (s_cdb_valid),
    .cdb_tag            (s_cdb_tag),
    .cdb_exception      (s_cdb_exc),
    .complete_valid     (s_comp_valid),
    .complete_tag       (s_comp_tag),
    .complete_exception (s_comp_exc),
    .br_update_valid    (s_br_valid),
    .br_update_pc       (s_br_pc),
    .br_update_taken    (s_br_taken),
    .br_update_target   (s_br_target),
    .br_update_is_jalr  (s_br_jalr),
    .br_update_tag      (s_br_tag),
    .commit_valid       (commit_valid),
    .commit_tag         (commit_tag),
    .commit_is_store    (commit_is_store),
    .commit_is_load     (commit_is_load),
    .commit_lsq_id      (commit_lsq_id),
    .commit_pc          (commit_pc),
    .commit_inst        (commit_inst),
    .commit_halt        (commit_halt),
    .commit_reg_we      (cm_reg_we),
    .commit_rd          (cm_rd),
    .commit_dest_tag    (cm_dest),
    .commit_free_valid  (cm_free_valid),
    .commit_free_tag    (cm_free),
    .recover_valid      (rec_valid),
    .recover_free_mask  (rec_free),
    .recover_busy_mask  (rec_busy),
    .recover_lsq_ptr    (rec_lsq),
    .redirect_valid     (redirect_valid),
    .redirect_pc        (redirect_pc),
    .squash_valid       (sq_valid),
    .squash_rob_idx     (sq_idx),
    .br_update_uncond   (s_br_uncond)
  );

  stub_exec #(.W(W)) u_stub (
    .clk                (clk),
    .reset              (reset),
    .force_stall        (force_stall),
    .force_taken        (force_taken),
    .force_target       (force_target),
    .dispatch_valid     (ren_fire),
    .dispatch_tag       (disp_tag),
    .dispatch_rob_idx   (alloc_rob_idx),
    .dispatch_pc        (disp_pc),
    .dispatch_is_branch (disp_branch),
    .dispatch_is_jal    (disp_jal),
    .dispatch_is_jalr   (disp_jalr),
    .dispatch_reg_we    (disp_regwe),
    .squash_valid       (sq_valid),
    .squash_rob_idx     (sq_idx),
    .backend_ready      (be_ready),
    .cdb_valid          (s_cdb_valid),
    .cdb_tag            (s_cdb_tag),
    .cdb_exception      (s_cdb_exc),
    .complete_valid     (s_comp_valid),
    .complete_tag       (s_comp_tag),
    .complete_exception (s_comp_exc),
    .br_update_valid    (s_br_valid),
    .br_update_pc       (s_br_pc),
    .br_update_taken    (s_br_taken),
    .br_update_target   (s_br_target),
    .br_update_is_jalr  (s_br_jalr),
    .br_update_tag      (s_br_tag)
  );

  assign ren_ready = rob_in_ready && be_ready;
  assign ren_fire  = ren_valid & {W{ren_ready}};
  assign backend_ready = be_ready;
  assign rob_ready = rob_in_ready;

  // stub dispatch 字段提取（rename 输出没有 rob_idx，单独从 ROB 取）
  logic [W*PW-1:0] disp_tag;
  logic [W*32-1:0] disp_pc;
  logic [W-1:0]    disp_branch, disp_jal, disp_jalr, disp_regwe;
  integer i_disp;
  always_comb begin
    disp_tag    = '0;
    disp_pc     = '0;
    disp_branch = '0;
    disp_jal    = '0;
    disp_jalr   = '0;
    disp_regwe  = '0;
    for (i_disp = 0; i_disp < W; i_disp = i_disp + 1) begin
      disp_tag[i_disp*PW +: PW] =
          ren_uop[i_disp*`CPU_RENAME_W + `CPU_DISPATCH_DEST_TAG_OFF +: PW];
      disp_pc[i_disp*32 +: 32] =
          ren_uop[i_disp*`CPU_RENAME_W + `CPU_DISPATCH_PC_OFF +: 32];
      disp_branch[i_disp] =
          ren_uop[i_disp*`CPU_RENAME_W + `CPU_DISPATCH_IS_BRANCH_OFF];
      disp_jal[i_disp] =
          ren_uop[i_disp*`CPU_RENAME_W + `CPU_DISPATCH_IS_JAL_OFF];
      disp_jalr[i_disp] =
          ren_uop[i_disp*`CPU_RENAME_W + `CPU_DISPATCH_IS_JALR_OFF];
      disp_regwe[i_disp] =
          ren_uop[i_disp*`CPU_RENAME_W + `CPU_DISPATCH_REG_WE_OFF];
    end
  end

  // wake：cdb 优先 lane0，其余 complete lane
  integer i_wake;
  always_comb begin
    wake_valid = '0;
    wake_tag   = '0;
    if (s_cdb_valid) begin
      wake_valid[0] = 1'b1;
      wake_tag[0 +: PW] = s_cdb_tag;
    end
    for (i_wake = 0; i_wake < W; i_wake = i_wake + 1) begin
      if (s_comp_valid[i_wake] && !(s_cdb_valid && i_wake == 0)) begin
        wake_valid[i_wake] = 1'b1;
        wake_tag[i_wake*PW +: PW] = s_comp_tag[i_wake*PW +: PW];
      end
    end
  end

endmodule
