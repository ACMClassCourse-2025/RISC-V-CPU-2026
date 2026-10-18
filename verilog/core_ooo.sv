// -----------------------------------------------------------------------------
// core_ooo.sv — 前端/提交线薄封装（frontend + rename + ROB）
//
// 对外只暴露冻结接口：
//   dispatch[W]  -> 乙的后端
//   commit[W]    <- 来自 ROB
//   squash       -> 乙的后端
//   cdb[R]/complete[W]/br_update <- 来自乙的后端
//   if_refill    -> mem_subsystem
//
// 本模块不包含后端执行单元，也不直接例化 mem_subsystem；它是 P1 逐边替换
// 时“真前端 + stub 后端”的边界。基线 core.sv/student_top 不受影响。
// -----------------------------------------------------------------------------

module core_ooo #(
  parameter integer W = `CPU_ISSUE_WIDTH
) (
  input  logic        clk,
  input  logic        reset,
  input  logic        backend_ready,

  // 来自后端
  input  logic [`CPU_CDB_BUS_W-1:0]     cdb,
  input  logic [`CPU_COMPLETE_BUS_W-1:0] complete,
  input  logic [`CPU_BR_UPDATE_W-1:0]   br_update,

  // 送往/来自后端
  output logic [`CPU_DISPATCH_BUS_W-1:0] dispatch,
  output logic [`CPU_COMMIT_BUS_W-1:0]   commit,
  output logic [`CPU_SQUASH_W-1:0]       squash,
  output logic                           halt,

  // I-Cache 回填（接 mem_subsystem）
  output logic        refill_valid,
  output logic [31:0] refill_addr,
  input  logic        refill_resp_valid,
  input  logic [31:0] refill_rdata
);

  localparam integer PW = `CPU_PRF_IDX_W;
  localparam integer RW = `CPU_ROB_TAG_W;
  localparam integer LW = `CPU_LSQ_IDX_W;
  localparam integer CW = `CPU_CDB_W;
  localparam integer MW = `CPU_COMPLETE_W;

  // frontend <-> rename
  logic [W-1:0]               dec_valid;
  logic [W*`CPU_DECODE_W-1:0] dec_uop;
  logic [W-1:0]               dec_pred_taken;
  logic [W*32-1:0]            dec_pred_target;
  logic                       rename_ready;

  // rename <-> ROB
  logic [W-1:0]               ren_valid;
  logic [W*`CPU_RENAME_W-1:0] ren_uop;
  logic [W*PW-1:0]            ren_old_tag;
  logic                       ren_ready;
  logic [W-1:0]               ren_fire;

  // wake
  logic [W-1:0]               wake_valid;
  logic [W*PW-1:0]            wake_tag;

  // ROB 反馈
  logic [W-1:0]               rec_valid, cm_valid, cm_reg_we, cm_free_valid;
  logic [`CPU_PRF_SIZE-1:0]   rec_free, rec_busy;
  logic [LW-1:0]              rec_lsq;
  logic [32*PW-1:0]           rec_rat;
  logic [W*5-1:0]             cm_rd;
  logic [W*PW-1:0]            cm_dest, cm_free;

  // ROB 输出
  logic [W-1:0]               rob_cm_valid, rob_cm_store, rob_cm_load;
  logic [W*PW-1:0]            rob_cm_tag;
  logic [W*LW-1:0]            rob_cm_lsq;
  logic [W*32-1:0]            rob_cm_pc, rob_cm_inst;
  logic                       rob_halt, rob_redirect_valid;
  logic [31:0]                rob_redirect_pc;
  logic                       rob_sq_valid;
  logic [RW-1:0]              rob_sq_idx;
  logic                       rob_br_uncond;

  logic                       rob_in_ready;
  logic [W*RW-1:0]            alloc_rob_idx;

  // cdb/complete 解包
  logic                       cdb0_valid;
  logic [PW-1:0]              cdb0_tag;
  logic                       cdb0_exc;
  logic [W-1:0]               comp_valid;
  logic [W*PW-1:0]            comp_tag;
  logic [W-1:0]               comp_exc;

  assign cdb0_valid = cdb[`CPU_CDB_VALID_OFF];
  assign cdb0_tag   = cdb[`CPU_CDB_TAG_OFF +: PW];
  assign cdb0_exc   = cdb[`CPU_CDB_EXCEPTION_OFF];

  integer i;
  always_comb begin
    comp_valid = '0;
    comp_tag   = '0;
    comp_exc   = '0;
    for (i = 0; i < W; i = i + 1) begin
      comp_valid[i] = complete[i*MW + `CPU_COMPLETE_VALID_OFF];
      comp_tag[i*PW +: PW] = complete[i*MW + `CPU_COMPLETE_TAG_OFF +: PW];
      comp_exc[i] = complete[i*MW + `CPU_COMPLETE_EXCEPTION_OFF];
    end
  end

  // 唤醒：cdb lane0 优先，complete 其余 lane
  integer iw;
  always_comb begin
    wake_valid = '0;
    wake_tag   = '0;
    if (cdb0_valid) begin
      wake_valid[0] = 1'b1;
      wake_tag[0 +: PW] = cdb0_tag;
    end
    for (iw = 0; iw < W; iw = iw + 1) begin
      if (comp_valid[iw] && !(cdb0_valid && iw == 0)) begin
        wake_valid[iw] = 1'b1;
        wake_tag[iw*PW +: PW] = comp_tag[iw*PW +: PW];
      end
    end
  end

  // br_update 解包
  logic        br_valid, br_taken, br_jalr;
  logic [31:0] br_pc, br_target;
  logic [PW-1:0] br_tag;

  assign br_valid  = br_update[`CPU_BR_VALID_OFF];
  assign br_pc     = br_update[`CPU_BR_PC_OFF +: 32];
  assign br_taken  = br_update[`CPU_BR_TAKEN_OFF];
  assign br_target = br_update[`CPU_BR_TARGET_OFF +: 32];
  assign br_jalr   = br_update[`CPU_BR_IS_JALR_OFF];
  assign br_tag    = br_update[`CPU_BR_TAG_OFF +: PW];

  // ---- frontend -----------------------------------------------------------
  frontend_ooo #(.W(W)) u_front (
    .clk               (clk),
    .reset             (reset),
    .backend_ready     (backend_ready && rob_in_ready),
    .redirect_valid    (rob_redirect_valid),
    .redirect_pc       (rob_redirect_pc),
    .br_update_valid   (br_valid),
    .br_update_pc      (br_pc),
    .br_update_taken   (br_taken),
    .br_update_target  (br_target),
    .br_update_is_jalr (br_jalr),
    .br_update_uncond  (rob_br_uncond),
    .br_update_tag     (br_tag),
    .dec_valid         (dec_valid),
    .dec_uop           (dec_uop),
    .dec_pred_taken    (dec_pred_taken),
    .dec_pred_target   (dec_pred_target),
    .rename_ready      (rename_ready),
    .pc_out            (),
    .refill_valid      (refill_valid),
    .refill_addr       (refill_addr),
    .refill_resp_valid (refill_resp_valid),
    .refill_rdata      (refill_rdata)
  );

  // ---- rename -------------------------------------------------------------
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
    .recover_lsq_ptr   (rec_lsq),
    .recover_rat       (rec_rat)
  );

  // ---- ROB ----------------------------------------------------------------
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
    .cdb_valid          (cdb0_valid),
    .cdb_tag            (cdb0_tag),
    .cdb_exception      (cdb0_exc),
    .complete_valid     (comp_valid),
    .complete_tag       (comp_tag),
    .complete_exception (comp_exc),
    .br_update_valid    (br_valid),
    .br_update_pc       (br_pc),
    .br_update_taken    (br_taken),
    .br_update_target   (br_target),
    .br_update_is_jalr  (br_jalr),
    .br_update_tag      (br_tag),
    .commit_valid       (rob_cm_valid),
    .commit_tag         (rob_cm_tag),
    .commit_is_store    (rob_cm_store),
    .commit_is_load     (rob_cm_load),
    .commit_lsq_id      (rob_cm_lsq),
    .commit_pc          (rob_cm_pc),
    .commit_inst        (rob_cm_inst),
    .commit_halt        (rob_halt),
    .commit_reg_we      (cm_reg_we),
    .commit_rd          (cm_rd),
    .commit_dest_tag    (cm_dest),
    .commit_free_valid  (cm_free_valid),
    .commit_free_tag    (cm_free),
    .recover_valid      (rec_valid),
    .recover_free_mask  (rec_free),
    .recover_busy_mask  (rec_busy),
    .recover_lsq_ptr    (rec_lsq),
    .recover_rat        (rec_rat),
    .redirect_valid     (rob_redirect_valid),
    .redirect_pc        (rob_redirect_pc),
    .squash_valid       (rob_sq_valid),
    .squash_rob_idx     (rob_sq_idx),
    .br_update_uncond   (rob_br_uncond)
  );

  assign ren_ready = rob_in_ready && backend_ready;
  assign ren_fire  = ren_valid & {W{ren_ready}};
  assign cm_valid  = rob_cm_valid;

  // ---- dispatch / commit / squash 打包 ------------------------------------
  integer id;
  always_comb begin
    dispatch = '0;
    for (id = 0; id < W; id = id + 1) begin
      // rename 输出布局 = dispatch 去掉 rob_idx
      dispatch[id*`CPU_DISPATCH_W +: `CPU_RENAME_W] =
          ren_uop[id*`CPU_RENAME_W +: `CPU_RENAME_W];
      dispatch[id*`CPU_DISPATCH_W + `CPU_DISPATCH_VALID_OFF] = ren_fire[id];
      dispatch[id*`CPU_DISPATCH_W + `CPU_DISPATCH_ROB_IDX_OFF +: RW] =
          alloc_rob_idx[id*RW +: RW];
    end
  end

  integer ic;
  always_comb begin
    commit = '0;
    for (ic = 0; ic < W; ic = ic + 1) begin
      commit[ic*`CPU_COMMIT_W + `CPU_COMMIT_VALID_OFF] = rob_cm_valid[ic];
      commit[ic*`CPU_COMMIT_W + `CPU_COMMIT_TAG_OFF +: PW] =
          rob_cm_tag[ic*PW +: PW];
      commit[ic*`CPU_COMMIT_W + `CPU_COMMIT_IS_STORE_OFF] = rob_cm_store[ic];
      commit[ic*`CPU_COMMIT_W + `CPU_COMMIT_IS_LOAD_OFF] = rob_cm_load[ic];
      commit[ic*`CPU_COMMIT_W + `CPU_COMMIT_LSQ_ID_OFF +: LW] =
          rob_cm_lsq[ic*LW +: LW];
    end
  end

  assign squash[`CPU_SQUASH_VALID_OFF] = rob_sq_valid;
  assign squash[`CPU_SQUASH_ROB_IDX_OFF +: RW] = rob_sq_idx;
  assign halt = rob_halt;

endmodule
