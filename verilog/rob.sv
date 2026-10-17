// -----------------------------------------------------------------------------
// rob.sv — 重排序缓冲 / 按序提交 / 精确恢复
//
// 分配：接收 rename 的 uop，按程序序分配 rob_idx（循环缓冲索引）。
// 完成：cdb / complete 按 dest_tag 定位表项，置 done/exception。
// 提交：头部前缀连续的 done 表项按序提交；分支必须收到 br_update 后才能提交。
// 恢复：br_update 与表项中保存的预测比较，不一致时：
//   - 冲刷比该分支年轻的表项；
//   - 输出 redirect_valid/redirect_pc、squash_valid/squash_rob_idx；
//   - 给 rename 输出 recover_free_mask/recover_busy_mask/recover_lsq_ptr。
//
// ROB 内部维护一份 commit RAT，仅用于恢复时计算空闲物理寄存器掩码；真正的
// 架构 RAT 由 rename 维护。
// -----------------------------------------------------------------------------

module rob #(
  parameter integer W     = `CPU_ISSUE_WIDTH,
  parameter integer DEPTH = `CPU_ROB_DEPTH
) (
  input  logic        clk,
  input  logic        reset,

  // 分配口（来自 rename）
  input  logic [W-1:0]                 in_valid,
  input  logic [W*`CPU_RENAME_W-1:0]   in_uop,
  input  logic [W*`CPU_PRF_IDX_W-1:0]  in_old_tag,
  input  logic [W-1:0]                 in_pred_taken,
  input  logic [W*32-1:0]              in_pred_target,
  output logic                         in_ready,
  output logic [W*`CPU_ROB_TAG_W-1:0]  alloc_rob_idx,

  // 完成口
  input  logic                         cdb_valid,
  input  logic [`CPU_PRF_IDX_W-1:0]    cdb_tag,
  input  logic                         cdb_exception,
  input  logic [W-1:0]                 complete_valid,
  input  logic [W*`CPU_PRF_IDX_W-1:0]  complete_tag,
  input  logic [W-1:0]                 complete_exception,

  // 分支解析
  input  logic                         br_update_valid,
  input  logic [31:0]                  br_update_pc,
  input  logic                         br_update_taken,
  input  logic [31:0]                  br_update_target,
  input  logic                         br_update_is_jalr,
  input  logic [`CPU_PRF_IDX_W-1:0]    br_update_tag,

  // 提交总线
  output logic [W-1:0]                 commit_valid,
  output logic [W*`CPU_PRF_IDX_W-1:0]  commit_tag,
  output logic [W-1:0]                 commit_is_store,
  output logic [W-1:0]                 commit_is_load,
  output logic [W*`CPU_LSQ_IDX_W-1:0]  commit_lsq_id,
  output logic [W*32-1:0]              commit_pc,
  output logic [W*32-1:0]              commit_inst,
  output logic                         commit_halt,

  // 给 rename 的提交反馈
  output logic [W-1:0]                 commit_reg_we,
  output logic [W*5-1:0]               commit_rd,
  output logic [W*`CPU_PRF_IDX_W-1:0]  commit_dest_tag,
  output logic [W-1:0]                 commit_free_valid,
  output logic [W*`CPU_PRF_IDX_W-1:0]  commit_free_tag,

  // 恢复（给 rename）
  output logic                         recover_valid,
  output logic [`CPU_PRF_SIZE-1:0]     recover_free_mask,
  output logic [`CPU_PRF_SIZE-1:0]     recover_busy_mask,
  output logic [`CPU_LSQ_IDX_W-1:0]    recover_lsq_ptr,

  // 重定向 / squash
  output logic                         redirect_valid,
  output logic [31:0]                  redirect_pc,
  output logic                         squash_valid,
  output logic [`CPU_ROB_TAG_W-1:0]    squash_rob_idx,
  output logic                         br_update_uncond
);

  localparam integer PW       = `CPU_PRF_IDX_W;
  localparam integer LW       = `CPU_LSQ_IDX_W;
  localparam integer RW       = `CPU_ROB_TAG_W;
  localparam integer MASK     = DEPTH - 1;
  localparam integer CNTW     = $clog2(DEPTH + 1);
  localparam [LW-1:0] LSQ_LAST = `CPU_LSQ_DEPTH - 1;

  // 表项存储（valid 才有效；其余字段不复位）
  logic [DEPTH-1:0]      entry_valid;
  logic [31:0]           entry_pc        [0:DEPTH-1];
  logic [31:0]           entry_inst      [0:DEPTH-1];
  logic [4:0]            entry_rd        [0:DEPTH-1];
  logic                  entry_reg_we    [0:DEPTH-1];
  logic [PW-1:0]         entry_dest_tag  [0:DEPTH-1];
  logic [PW-1:0]         entry_old_tag   [0:DEPTH-1];
  logic                  entry_is_store  [0:DEPTH-1];
  logic                  entry_is_load   [0:DEPTH-1];
  logic [LW-1:0]         entry_lsq_id    [0:DEPTH-1];
  logic                  entry_control   [0:DEPTH-1];
  logic                  entry_uncond    [0:DEPTH-1];
  logic                  entry_pred_taken[0:DEPTH-1];
  logic [31:0]           entry_pred_tgt  [0:DEPTH-1];
  logic                  entry_done      [0:DEPTH-1];
  logic                  entry_exception [0:DEPTH-1];
  logic                  entry_illegal   [0:DEPTH-1];
  logic                  entry_resolved  [0:DEPTH-1];

  logic [RW-1:0]         head;
  logic [CNTW-1:0]       count;

  // commit RAT（仅用于恢复掩码）
  logic [31:0][PW-1:0]   crat;

  // ---- 分配计数 ------------------------------------------------------------
  logic [CNTW-1:0] n_valid;
  integer i_alloc;
  always_comb begin
    n_valid = '0;
    for (i_alloc = 0; i_alloc < W; i_alloc = i_alloc + 1)
      if (in_valid[i_alloc]) n_valid = n_valid + 1'b1;
  end

  integer i_ar;
  always_comb begin
    alloc_rob_idx = '0;
    for (i_ar = 0; i_ar < W; i_ar = i_ar + 1)
      if (in_valid[i_ar])
        alloc_rob_idx[i_ar*RW +: RW] = (head + count + i_ar) & MASK;
  end

  // ---- 头部提交窗口 --------------------------------------------------------
  logic [W-1:0] head_valid, head_done, head_control, head_resolved, head_exception;
  integer i_head, i_head_idx;
  always_comb begin
    for (i_head = 0; i_head < W; i_head = i_head + 1) begin
      i_head_idx = (head + i_head) & MASK;
      head_valid[i_head]     = entry_valid[i_head_idx];
      head_done[i_head]      = entry_done[i_head_idx];
      head_control[i_head]   = entry_control[i_head_idx];
      head_resolved[i_head]  = entry_resolved[i_head_idx];
      head_exception[i_head] = entry_exception[i_head_idx] | entry_illegal[i_head_idx];
    end
  end

  // ---- 分支解析 / 误预测 ---------------------------------------------------
  logic [RW-1:0] br_idx;
  logic          br_found;
  logic          br_mispredict;
  integer        br_age_i;
  integer        i_br, i_br_idx;

  always_comb begin
    br_idx        = '0;
    br_found      = 1'b0;
    br_mispredict = 1'b0;
    br_age_i      = 0;

    for (i_br = 0; i_br < DEPTH; i_br = i_br + 1) begin
      i_br_idx = (head + i_br) & MASK;
      if (entry_valid[i_br_idx] && entry_control[i_br_idx] &&
          (entry_dest_tag[i_br_idx] == br_update_tag)) begin
        br_found = 1'b1;
        br_idx   = i_br_idx;
        br_age_i = i_br;
      end
    end

    if (br_update_valid && br_found) begin
      if (br_update_taken != entry_pred_taken[br_idx]) begin
        br_mispredict = 1'b1;
      end else if (br_update_taken &&
                   (br_update_target != entry_pred_tgt[br_idx])) begin
        br_mispredict = 1'b1;
      end
    end
  end

  logic flush_young;
  assign flush_young = br_update_valid && br_found && br_mispredict;
  assign br_update_uncond = br_update_valid && br_found && entry_uncond[br_idx];

  // ---- 提交选择 ------------------------------------------------------------
  logic [W-1:0] commit_valid_int;
  logic         commit_halt_int;

  commit #(.W(W)) u_commit (
    .valid        (head_valid),
    .done         (head_done),
    .is_control   (head_control),
    .resolved     (head_resolved),
    .exception    (head_exception),
    .commit_valid (commit_valid_int),
    .halt         (commit_halt_int)
  );

  assign commit_valid = commit_valid_int & {W{!flush_young}};
  assign commit_halt  = commit_halt_int && !flush_young;

  // ---- 提交总线 / rename 反馈 ---------------------------------------------
  integer i_commit, i_commit_idx;
  always_comb begin
    commit_tag        = '0;
    commit_is_store   = '0;
    commit_is_load    = '0;
    commit_lsq_id     = '0;
    commit_pc         = '0;
    commit_inst       = '0;
    commit_reg_we     = '0;
    commit_rd         = '0;
    commit_dest_tag   = '0;
    commit_free_valid = '0;
    commit_free_tag   = '0;

    for (i_commit = 0; i_commit < W; i_commit = i_commit + 1) begin
      i_commit_idx = (head + i_commit) & MASK;
      if (commit_valid[i_commit]) begin
        commit_tag[i_commit*PW +: PW]        = entry_dest_tag[i_commit_idx];
        commit_is_store[i_commit]            = entry_is_store[i_commit_idx];
        commit_is_load[i_commit]             = entry_is_load[i_commit_idx];
        commit_lsq_id[i_commit*LW +: LW]     = entry_lsq_id[i_commit_idx];
        commit_pc[i_commit*32 +: 32]         = entry_pc[i_commit_idx];
        commit_inst[i_commit*32 +: 32]       = entry_inst[i_commit_idx];
        commit_reg_we[i_commit]              = entry_reg_we[i_commit_idx];
        commit_rd[i_commit*5 +: 5]           = entry_rd[i_commit_idx];
        commit_dest_tag[i_commit*PW +: PW]   = entry_dest_tag[i_commit_idx];
        if (entry_reg_we[i_commit_idx]) begin
          commit_free_tag[i_commit*PW +: PW] = entry_old_tag[i_commit_idx];
          commit_free_valid[i_commit]        = (entry_old_tag[i_commit_idx] != '0);
        end else begin
          commit_free_tag[i_commit*PW +: PW] = entry_dest_tag[i_commit_idx];
          commit_free_valid[i_commit]        = (entry_dest_tag[i_commit_idx] != '0);
        end
      end
    end
  end

  // ---- 空闲/忙碌掩码（恢复用） --------------------------------------------
  logic [`CPU_PRF_SIZE-1:0] free_mask_c;
  logic [`CPU_PRF_SIZE-1:0] busy_mask_c;
  logic [LW-1:0]            lsq_ptr_c;
  integer i_mask, i_reg, i_mask_idx;

  always_comb begin
    free_mask_c    = '1;
    free_mask_c[0] = 1'b0;
    busy_mask_c    = '0;
    lsq_ptr_c      = '0;

    // committed RAT 占用的 tag 不能释放
    for (i_reg = 0; i_reg < 32; i_reg = i_reg + 1)
      if (crat[i_reg] != '0) free_mask_c[crat[i_reg]] = 1'b0;

    // 存活表项（branch 及更老）的 dest tag 不能释放；未完成的还是 busy
    for (i_mask = 0; i_mask < DEPTH; i_mask = i_mask + 1) begin
      i_mask_idx = (head + i_mask) & MASK;
      if (entry_valid[i_mask_idx] && (i_mask <= br_age_i)) begin
        if (entry_dest_tag[i_mask_idx] != '0)
          free_mask_c[entry_dest_tag[i_mask_idx]] = 1'b0;
        if (!entry_done[i_mask_idx] && entry_dest_tag[i_mask_idx] != '0)
          busy_mask_c[entry_dest_tag[i_mask_idx]] = 1'b1;
        if (entry_is_store[i_mask_idx] || entry_is_load[i_mask_idx])
          lsq_ptr_c = (entry_lsq_id[i_mask_idx] == LSQ_LAST) ? '0 :
                      (entry_lsq_id[i_mask_idx] + 1'b1);
      end
    end
  end

  // ---- 空间/握手 -----------------------------------------------------------
  logic [CNTW-1:0] n_commit;
  integer i_commit_cnt;
  always_comb begin
    n_commit = '0;
    for (i_commit_cnt = 0; i_commit_cnt < W; i_commit_cnt = i_commit_cnt + 1)
      if (commit_valid[i_commit_cnt]) n_commit = n_commit + 1'b1;
  end

  assign in_ready = !flush_young && !recover_valid && !redirect_valid &&
                    ((count + W) <= DEPTH);

  // ---- 完成搜索（组合） ----------------------------------------------------
  logic          cdb_hit;
  logic [RW-1:0] cdb_idx;
  logic [W-1:0]  comp_hit;
  logic [RW-1:0] comp_idx [0:W-1];
  integer i_cmp, i_clane, i_cmp_idx;

  always_comb begin
    cdb_hit = 1'b0;
    cdb_idx = '0;
    for (i_cmp = 0; i_cmp < DEPTH; i_cmp = i_cmp + 1) begin
      i_cmp_idx = (head + i_cmp) & MASK;
      if (entry_valid[i_cmp_idx] && (entry_dest_tag[i_cmp_idx] == cdb_tag)) begin
        cdb_hit = 1'b1;
        cdb_idx = i_cmp_idx;
      end
    end

    for (i_clane = 0; i_clane < W; i_clane = i_clane + 1) begin
      comp_hit[i_clane] = 1'b0;
      comp_idx[i_clane] = '0;
      if (complete_valid[i_clane]) begin
        for (i_cmp = 0; i_cmp < DEPTH; i_cmp = i_cmp + 1) begin
          i_cmp_idx = (head + i_cmp) & MASK;
          if (entry_valid[i_cmp_idx] &&
              (entry_dest_tag[i_cmp_idx] == complete_tag[i_clane*PW +: PW])) begin
            comp_hit[i_clane] = 1'b1;
            comp_idx[i_clane] = i_cmp_idx;
          end
        end
      end
    end
  end

  // ---- 时序 ----------------------------------------------------------------
  integer i_ff, i_flush, i_alloc2, i_alloc_idx, i_ff_clane;

  always_ff @(posedge clk) begin
    if (reset) begin
      entry_valid       <= '0;
      head              <= '0;
      count             <= '0;
      crat              <= '0;
      recover_valid     <= 1'b0;
      recover_free_mask <= '0;
      recover_busy_mask <= '0;
      recover_lsq_ptr   <= '0;
      redirect_valid    <= 1'b0;
      redirect_pc       <= 32'b0;
      squash_valid      <= 1'b0;
      squash_rob_idx    <= '0;
    end else begin
      recover_valid  <= 1'b0;
      redirect_valid <= 1'b0;
      squash_valid   <= 1'b0;

      // 完成广播
      if (cdb_valid && cdb_hit) begin
        entry_done[cdb_idx] <= 1'b1;
        if (cdb_exception) entry_exception[cdb_idx] <= 1'b1;
      end
      for (i_ff_clane = 0; i_ff_clane < W; i_ff_clane = i_ff_clane + 1) begin
        if (complete_valid[i_ff_clane] && comp_hit[i_ff_clane]) begin
          entry_done[comp_idx[i_ff_clane]] <= 1'b1;
          if (complete_exception[i_ff_clane])
            entry_exception[comp_idx[i_ff_clane]] <= 1'b1;
        end
      end

      // 分支解析
      if (br_update_valid && br_found) begin
        entry_resolved[br_idx] <= 1'b1;
      end

      if (flush_young) begin
        // 冲刷比分支更年轻的表项；分支及更老的保留
        for (i_flush = 0; i_flush < DEPTH; i_flush = i_flush + 1) begin
          if (i_flush > br_age_i)
            entry_valid[(head + i_flush) & MASK] <= 1'b0;
        end
        count             <= br_age_i + 1;
        recover_valid     <= 1'b1;
        recover_free_mask <= free_mask_c;
        recover_busy_mask <= busy_mask_c;
        recover_lsq_ptr   <= lsq_ptr_c;
        redirect_valid    <= 1'b1;
        redirect_pc       <= br_update_taken ? br_update_target :
                             (entry_pc[br_idx] + 32'd4);
        squash_valid      <= 1'b1;
        squash_rob_idx    <= br_idx;
      end else begin
        // 提交出队 + commit RAT
        if (|commit_valid) begin
          for (i_ff = 0; i_ff < W; i_ff = i_ff + 1) begin
            i_alloc_idx = (head + i_ff) & MASK;
            if (commit_valid[i_ff]) begin
              entry_valid[i_alloc_idx] <= 1'b0;
              if (commit_reg_we[i_ff])
                crat[commit_rd[i_ff*5 +: 5]] <= commit_dest_tag[i_ff*PW +: PW];
            end
          end
          head  <= (head + n_commit) & MASK;
        end

        // 分配新表项
        if (in_ready) begin
          for (i_alloc2 = 0; i_alloc2 < W; i_alloc2 = i_alloc2 + 1) begin
            i_alloc_idx = (head + count + i_alloc2) & MASK;
            if (in_valid[i_alloc2]) begin
              entry_valid[i_alloc_idx]   <= 1'b1;
              entry_pc[i_alloc_idx]      <= in_uop[i_alloc2*`CPU_RENAME_W + `CPU_DISPATCH_PC_OFF +: 32];
              entry_inst[i_alloc_idx]    <= in_uop[i_alloc2*`CPU_RENAME_W + `CPU_DISPATCH_INST_OFF +: 32];
              entry_rd[i_alloc_idx]      <= in_uop[i_alloc2*`CPU_RENAME_W + `CPU_DISPATCH_RD_OFF +: 5];
              entry_reg_we[i_alloc_idx]  <= in_uop[i_alloc2*`CPU_RENAME_W + `CPU_DISPATCH_REG_WE_OFF];
              entry_dest_tag[i_alloc_idx]<= in_uop[i_alloc2*`CPU_RENAME_W + `CPU_DISPATCH_DEST_TAG_OFF +: PW];
              entry_old_tag[i_alloc_idx] <= in_old_tag[i_alloc2*PW +: PW];
              entry_is_store[i_alloc_idx]<= in_uop[i_alloc2*`CPU_RENAME_W + `CPU_DISPATCH_IS_STORE_OFF];
              entry_is_load[i_alloc_idx] <= in_uop[i_alloc2*`CPU_RENAME_W + `CPU_DISPATCH_IS_LOAD_OFF];
              entry_lsq_id[i_alloc_idx]  <= in_uop[i_alloc2*`CPU_RENAME_W + `CPU_DISPATCH_LSQ_ID_OFF +: LW];
              entry_control[i_alloc_idx] <= in_uop[i_alloc2*`CPU_RENAME_W + `CPU_DISPATCH_IS_BRANCH_OFF] |
                                            in_uop[i_alloc2*`CPU_RENAME_W + `CPU_DISPATCH_IS_JAL_OFF] |
                                            in_uop[i_alloc2*`CPU_RENAME_W + `CPU_DISPATCH_IS_JALR_OFF];
              entry_uncond[i_alloc_idx]  <= in_uop[i_alloc2*`CPU_RENAME_W + `CPU_DISPATCH_IS_JAL_OFF] |
                                            in_uop[i_alloc2*`CPU_RENAME_W + `CPU_DISPATCH_IS_JALR_OFF];
              entry_pred_taken[i_alloc_idx] <= in_pred_taken[i_alloc2];
              entry_pred_tgt[i_alloc_idx]   <= in_pred_target[i_alloc2*32 +: 32];
              entry_done[i_alloc_idx]       <= 1'b0;
              entry_exception[i_alloc_idx]  <= 1'b0;
              entry_illegal[i_alloc_idx]    <= in_uop[i_alloc2*`CPU_RENAME_W + `CPU_DISPATCH_ILLEGAL_OFF];
              entry_resolved[i_alloc_idx]   <= 1'b0;
            end
          end
        end

        if (|commit_valid || in_ready) begin
          if (in_ready)
            count <= count - n_commit + n_valid;
          else
            count <= count - n_commit;
        end
      end
    end
  end

endmodule
