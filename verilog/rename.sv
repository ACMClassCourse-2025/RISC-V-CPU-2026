// -----------------------------------------------------------------------------
// rename.sv — 寄存器重命名（RAT + commit RAT + 空闲物理寄存器表）
//
// 结构：
//   - rat/crat：32 项映射表，保存 rd -> 物理寄存器号；
//   - free_vec：每个物理寄存器 1 位，1=可分配；preg 0 永不分配；
//   - busy：每个物理寄存器 1 位，1=结果尚未写回；
//   - lsq_ptr：load/store 的 lsq_id 循环计数器（rename 分配）。
//
// 复位约定：所有架构寄存器映射到物理寄存器 0（PRF[0] 恒 0），因此初始值
// 全为 0 且 ready；free_vec 初始为除 0 外全 1。这样不要求 PRF 有复位值。
//
// 每条有效 uop 都分配唯一 dest_tag（包括 reg_we=0），用于完成/回收标识。
// 提交时：
//   - reg_we=1：更新 commit RAT（rd -> dest_tag），释放 ROB 给出的 free_tag
//     （通常是 old_preg；若该 uop 不写架构寄存器，ROB 释放 dest_tag）；
//   - 释放的 tag 回到 free_vec，并清 busy。
//
// 恢复（recover_valid）：ROB 负责计算恢复后的 free/busy 掩码与 lsq_ptr，
// rename 在同一拍整体装载，并把 rat 恢复为 crat。
//
// 宽度 W = CPU_ISSUE_WIDTH；lane i 位于扁平总线 [i*W +: W]，有效 lane 前缀。
// -----------------------------------------------------------------------------

module rename #(
  parameter integer W = `CPU_ISSUE_WIDTH
) (
  input  logic        clk,
  input  logic        reset,

  // decoded uop 输入（dispatch 低 122 位布局）
  input  logic [W-1:0]                 in_valid,
  input  logic [W*`CPU_DECODE_W-1:0]   in_uop,
  output logic                         in_ready,

  // renamed uop 输出（dispatch 去掉 rob_idx 的布局）
  output logic [W-1:0]                 out_valid,
  output logic [W*`CPU_RENAME_W-1:0]   out_uop,
  output logic [W*`CPU_PRF_IDX_W-1:0]  out_old_tag,
  input  logic                         out_ready,

  // 提交（来自 ROB/commit）
  input  logic [W-1:0]                 commit_valid,
  input  logic [W*5-1:0]               commit_rd,
  input  logic [W*`CPU_PRF_IDX_W-1:0]  commit_dest_tag,
  input  logic [W-1:0]                 commit_reg_we,
  input  logic [W-1:0]                 commit_free_valid,
  input  logic [W*`CPU_PRF_IDX_W-1:0]  commit_free_tag,

  // 写回/完成唤醒（CDB + complete 汇总，最多 W 条）
  input  logic [W-1:0]                 wake_valid,
  input  logic [W*`CPU_PRF_IDX_W-1:0]  wake_tag,

  // 恢复（squash 到某分支时由 ROB 给出）
  input  logic                         recover_valid,
  input  logic [`CPU_PRF_SIZE-1:0]     recover_free_mask,
  input  logic [`CPU_PRF_SIZE-1:0]     recover_busy_mask,
  input  logic [`CPU_LSQ_IDX_W-1:0]    recover_lsq_ptr,
  input  logic [32*`CPU_PRF_IDX_W-1:0] recover_rat
);

  localparam integer PRF = `CPU_PRF_SIZE;
  localparam integer PW  = `CPU_PRF_IDX_W;
  localparam integer LW  = `CPU_LSQ_IDX_W;
  localparam integer FCW = $clog2(PRF + 1);
  localparam [LW-1:0] LSQ_LAST = `CPU_LSQ_DEPTH - 1;

  integer i_uop, i_cnt, i_alloc, i_wake, i_src, j_src;
  integer i_out, i_rec, i_ff;
  logic [PRF-1:0] alloc_tmp;
  logic [LW-1:0]  lsq_tmp;

  // 32 项 RAT / commit RAT
  logic [31:0][PW-1:0] rat;
  logic [31:0][PW-1:0] crat;

  logic [PRF-1:0] free_vec;
  logic [PRF-1:0] busy;
  logic [FCW-1:0] free_count;
  logic [LW-1:0]  lsq_ptr;

  // ---- 输入/输出 lane 的便利数组 ------------------------------------------
  logic [31:0] u_pc     [0:W-1];
  logic [31:0] u_inst   [0:W-1];
  logic [31:0] u_imm    [0:W-1];
  logic [4:0]  u_rd     [0:W-1];
  logic        u_reg_we [0:W-1];
  logic [4:0]  u_alu_op [0:W-1];
  logic [1:0]  u_a_sel  [0:W-1];
  logic        u_b_sel  [0:W-1];
  logic [1:0]  u_wb_sel [0:W-1];
  logic        u_is_branch [0:W-1];
  logic        u_is_jal    [0:W-1];
  logic        u_is_jalr   [0:W-1];
  logic        u_is_load   [0:W-1];
  logic        u_is_store  [0:W-1];
  logic        u_illegal   [0:W-1];
  logic [1:0]  u_mem_size  [0:W-1];
  logic        u_mem_unsigned [0:W-1];
  logic [4:0]  u_rs1    [0:W-1];
  logic [4:0]  u_rs2    [0:W-1];

  always_comb begin
    for (i_uop = 0; i_uop < W; i_uop = i_uop + 1) begin
      u_pc[i_uop]           = in_uop[i_uop*`CPU_DECODE_W + `CPU_DISPATCH_PC_OFF +: 32];
      u_inst[i_uop]         = in_uop[i_uop*`CPU_DECODE_W + `CPU_DISPATCH_INST_OFF +: 32];
      u_imm[i_uop]          = in_uop[i_uop*`CPU_DECODE_W + `CPU_DISPATCH_IMM_OFF +: 32];
      u_rd[i_uop]           = in_uop[i_uop*`CPU_DECODE_W + `CPU_DISPATCH_RD_OFF +: 5];
      u_reg_we[i_uop]       = in_uop[i_uop*`CPU_DECODE_W + `CPU_DISPATCH_REG_WE_OFF];
      u_alu_op[i_uop]       = in_uop[i_uop*`CPU_DECODE_W + `CPU_DISPATCH_ALU_OP_OFF +: 5];
      u_a_sel[i_uop]        = in_uop[i_uop*`CPU_DECODE_W + `CPU_DISPATCH_A_SEL_OFF +: 2];
      u_b_sel[i_uop]        = in_uop[i_uop*`CPU_DECODE_W + `CPU_DISPATCH_B_SEL_OFF];
      u_wb_sel[i_uop]       = in_uop[i_uop*`CPU_DECODE_W + `CPU_DISPATCH_WB_SEL_OFF +: 2];
      u_is_branch[i_uop]    = in_uop[i_uop*`CPU_DECODE_W + `CPU_DISPATCH_IS_BRANCH_OFF];
      u_is_jal[i_uop]       = in_uop[i_uop*`CPU_DECODE_W + `CPU_DISPATCH_IS_JAL_OFF];
      u_is_jalr[i_uop]      = in_uop[i_uop*`CPU_DECODE_W + `CPU_DISPATCH_IS_JALR_OFF];
      u_is_load[i_uop]      = in_uop[i_uop*`CPU_DECODE_W + `CPU_DISPATCH_IS_LOAD_OFF];
      u_is_store[i_uop]     = in_uop[i_uop*`CPU_DECODE_W + `CPU_DISPATCH_IS_STORE_OFF];
      u_illegal[i_uop]      = in_uop[i_uop*`CPU_DECODE_W + `CPU_DISPATCH_ILLEGAL_OFF];
      u_mem_size[i_uop]     = in_uop[i_uop*`CPU_DECODE_W + `CPU_DISPATCH_MEM_SIZE_OFF +: 2];
      u_mem_unsigned[i_uop] = in_uop[i_uop*`CPU_DECODE_W + `CPU_DISPATCH_MEM_UNSIGNED_OFF];
      u_rs1[i_uop]          = in_uop[i_uop*`CPU_DECODE_W + `CPU_DECODE_RS1_OFF +: 5];
      u_rs2[i_uop]          = in_uop[i_uop*`CPU_DECODE_W + `CPU_DECODE_RS2_OFF +: 5];
    end
  end

  // ---- 有效/释放计数 -------------------------------------------------------
  logic [FCW-1:0] n_valid;
  logic [FCW-1:0] n_free;

  always_comb begin
    n_valid = '0;
    for (i_cnt = 0; i_cnt < W; i_cnt = i_cnt + 1)
      if (in_valid[i_cnt]) n_valid = n_valid + 1'b1;
    n_free = '0;
    for (i_cnt = 0; i_cnt < W; i_cnt = i_cnt + 1)
      if (commit_valid[i_cnt] && commit_free_valid[i_cnt]) n_free = n_free + 1'b1;
  end

  // ---- 空闲寄存器分配（优先低编号） ---------------------------------------
  logic [PW-1:0] alloc_tag [0:W-1];
  logic          alloc_ok  [0:W-1];

  function automatic [PW-1:0] lowest_free(input logic [PRF-1:0] mask);
    integer k;
    logic found;
    begin
      lowest_free = '0;
      found       = 1'b0;
      for (k = 0; k < PRF; k = k + 1) begin
        if (mask[k] && !found) begin
          lowest_free = k[PW-1:0];
          found       = 1'b1;
        end
      end
    end
  endfunction

  always_comb begin
    alloc_tmp = free_vec;
    for (i_alloc = 0; i_alloc < W; i_alloc = i_alloc + 1) begin
      alloc_tag[i_alloc] = '0;
      alloc_ok[i_alloc]  = 1'b0;
      if (in_valid[i_alloc] && (alloc_tmp != '0)) begin
        alloc_tag[i_alloc] = lowest_free(alloc_tmp);
        alloc_ok[i_alloc]  = 1'b1;
        alloc_tmp[alloc_tag[i_alloc]] = 1'b0;
      end
    end
  end

  // ---- 唤醒掩码与有效 busy ------------------------------------------------
  logic [PRF-1:0] wake_mask;
  logic [PRF-1:0] busy_eff;

  always_comb begin
    wake_mask = '0;
    for (i_wake = 0; i_wake < W; i_wake = i_wake + 1)
      if (wake_valid[i_wake]) wake_mask[wake_tag[i_wake*PW +: PW]] = 1'b1;
    busy_eff = busy & ~wake_mask;
  end

  // ---- 源操作数映射/就绪 + 组内依赖 + 旧映射 ------------------------------
  logic [PW-1:0] src1_tag [0:W-1];
  logic [PW-1:0] src2_tag [0:W-1];
  logic          src1_rdy [0:W-1];
  logic          src2_rdy [0:W-1];
  logic [PW-1:0] old_tag  [0:W-1];
  logic [PW-1:0] dest_tag [0:W-1];
  logic [LW-1:0] lsq_id   [0:W-1];
  logic [LW-1:0] lsq_next;

  always_comb begin
    lsq_tmp = lsq_ptr;

    for (i_src = 0; i_src < W; i_src = i_src + 1) begin
      dest_tag[i_src] = alloc_ok[i_src] ? alloc_tag[i_src] : '0;

      // 默认从 RAT 读；x0 固定 tag 0、ready=1。
      if (u_rs1[i_src] == 5'd0) begin
        src1_tag[i_src] = '0;
        src1_rdy[i_src] = 1'b1;
      end else begin
        src1_tag[i_src] = rat[u_rs1[i_src]];
        src1_rdy[i_src] = ~busy_eff[src1_tag[i_src]];
      end
      if (u_rs2[i_src] == 5'd0) begin
        src2_tag[i_src] = '0;
        src2_rdy[i_src] = 1'b1;
      end else begin
        src2_tag[i_src] = rat[u_rs2[i_src]];
        src2_rdy[i_src] = ~busy_eff[src2_tag[i_src]];
      end

      old_tag[i_src] = u_reg_we[i_src] ? rat[u_rd[i_src]] : '0;

      // 组内前序 lane 写同一 rd：源 tag 指向新 dest，ready=0；
      // 旧映射也指向该前序 lane 的 dest。
      for (j_src = 0; j_src < W; j_src = j_src + 1) begin
        if ((j_src < i_src) && in_valid[j_src] && u_reg_we[j_src] &&
            (u_rd[j_src] == u_rs1[i_src])) begin
          src1_tag[i_src] = dest_tag[j_src];
          src1_rdy[i_src] = 1'b0;
        end
        if ((j_src < i_src) && in_valid[j_src] && u_reg_we[j_src] &&
            (u_rd[j_src] == u_rs2[i_src])) begin
          src2_tag[i_src] = dest_tag[j_src];
          src2_rdy[i_src] = 1'b0;
        end
        if ((j_src < i_src) && in_valid[j_src] && u_reg_we[j_src] &&
            (u_rd[j_src] == u_rd[i_src])) begin
          old_tag[i_src] = dest_tag[j_src];
        end
      end

      // lsq_id 只对有效的 load/store 递增
      if (in_valid[i_src] && (u_is_load[i_src] || u_is_store[i_src])) begin
        lsq_id[i_src] = lsq_tmp;
        lsq_tmp   = (lsq_tmp == LSQ_LAST) ? '0 : lsq_tmp + 1'b1;
      end else begin
        lsq_id[i_src] = '0;
      end
    end

    lsq_next = lsq_tmp;
  end

  // ---- 握手 ----------------------------------------------------------------
  assign in_ready = !recover_valid && out_ready && (free_count >= n_valid);

  always_comb begin
    out_valid = '0;
    for (i_out = 0; i_out < W; i_out = i_out + 1) begin
      out_valid[i_out] = in_valid[i_out];   // valid 保持，ready 决定是否接收
      out_uop[i_out*`CPU_RENAME_W + `CPU_DISPATCH_VALID_OFF] = out_valid[i_out];
      out_uop[i_out*`CPU_RENAME_W + `CPU_DISPATCH_PC_OFF +: 32] = u_pc[i_out];
      out_uop[i_out*`CPU_RENAME_W + `CPU_DISPATCH_INST_OFF +: 32] = u_inst[i_out];
      out_uop[i_out*`CPU_RENAME_W + `CPU_DISPATCH_IMM_OFF +: 32] = u_imm[i_out];
      out_uop[i_out*`CPU_RENAME_W + `CPU_DISPATCH_RD_OFF +: 5] = u_rd[i_out];
      out_uop[i_out*`CPU_RENAME_W + `CPU_DISPATCH_REG_WE_OFF] = u_reg_we[i_out];
      out_uop[i_out*`CPU_RENAME_W + `CPU_DISPATCH_ALU_OP_OFF +: 5] = u_alu_op[i_out];
      out_uop[i_out*`CPU_RENAME_W + `CPU_DISPATCH_A_SEL_OFF +: 2] = u_a_sel[i_out];
      out_uop[i_out*`CPU_RENAME_W + `CPU_DISPATCH_B_SEL_OFF] = u_b_sel[i_out];
      out_uop[i_out*`CPU_RENAME_W + `CPU_DISPATCH_WB_SEL_OFF +: 2] = u_wb_sel[i_out];
      out_uop[i_out*`CPU_RENAME_W + `CPU_DISPATCH_IS_BRANCH_OFF] = u_is_branch[i_out];
      out_uop[i_out*`CPU_RENAME_W + `CPU_DISPATCH_IS_JAL_OFF] = u_is_jal[i_out];
      out_uop[i_out*`CPU_RENAME_W + `CPU_DISPATCH_IS_JALR_OFF] = u_is_jalr[i_out];
      out_uop[i_out*`CPU_RENAME_W + `CPU_DISPATCH_IS_LOAD_OFF] = u_is_load[i_out];
      out_uop[i_out*`CPU_RENAME_W + `CPU_DISPATCH_IS_STORE_OFF] = u_is_store[i_out];
      out_uop[i_out*`CPU_RENAME_W + `CPU_DISPATCH_ILLEGAL_OFF] = u_illegal[i_out];
      out_uop[i_out*`CPU_RENAME_W + `CPU_DISPATCH_MEM_SIZE_OFF +: 2] = u_mem_size[i_out];
      out_uop[i_out*`CPU_RENAME_W + `CPU_DISPATCH_MEM_UNSIGNED_OFF] = u_mem_unsigned[i_out];
      out_uop[i_out*`CPU_RENAME_W + `CPU_DISPATCH_DEST_TAG_OFF +: PW] = dest_tag[i_out];
      out_uop[i_out*`CPU_RENAME_W + `CPU_DISPATCH_SRC1_TAG_OFF +: PW] = src1_tag[i_out];
      out_uop[i_out*`CPU_RENAME_W + `CPU_DISPATCH_SRC1_READY_OFF] = src1_rdy[i_out];
      out_uop[i_out*`CPU_RENAME_W + `CPU_DISPATCH_SRC2_TAG_OFF +: PW] = src2_tag[i_out];
      out_uop[i_out*`CPU_RENAME_W + `CPU_DISPATCH_SRC2_READY_OFF] = src2_rdy[i_out];
      out_uop[i_out*`CPU_RENAME_W + `CPU_DISPATCH_LSQ_ID_OFF +: LW] = lsq_id[i_out];
      out_old_tag[i_out*PW +: PW] = old_tag[i_out];
    end
  end

  // ---- 恢复计数 ------------------------------------------------------------
  logic [FCW-1:0] recover_count;
  always_comb begin
    recover_count = '0;
    for (i_rec = 1; i_rec < PRF; i_rec = i_rec + 1)
      if (recover_free_mask[i_rec]) recover_count = recover_count + 1'b1;
  end

  // ---- 时序 ----------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      rat        <= '0;
      crat       <= '0;
      free_vec   <= '1;
      free_vec[0] <= 1'b0;
      busy       <= '0;
      free_count <= FCW'(PRF - 1);
      lsq_ptr    <= '0;
    end else if (recover_valid) begin
      for (i_ff = 0; i_ff < 32; i_ff = i_ff + 1)
        rat[i_ff] <= recover_rat[i_ff*PW +: PW];
      free_vec   <= recover_free_mask & ~{{(PRF-1){1'b0}}, 1'b1};
      busy       <= recover_busy_mask & ~{{(PRF-1){1'b0}}, 1'b1};
      free_count <= recover_count;
      lsq_ptr    <= recover_lsq_ptr;
    end else begin
      // 唤醒清 busy
      for (i_ff = 0; i_ff < W; i_ff = i_ff + 1)
        if (wake_valid[i_ff]) busy[wake_tag[i_ff*PW +: PW]] <= 1'b0;

      // 提交：释放 tag、更新 commit RAT
      for (i_ff = 0; i_ff < W; i_ff = i_ff + 1) begin
        if (commit_valid[i_ff] && commit_free_valid[i_ff]) begin
          free_vec[commit_free_tag[i_ff*PW +: PW]] <= 1'b1;
          busy[commit_free_tag[i_ff*PW +: PW]] <= 1'b0;
        end
        if (commit_valid[i_ff] && commit_reg_we[i_ff])
          crat[commit_rd[i_ff*5 +: 5]] <= commit_dest_tag[i_ff*PW +: PW];
      end

      // 接收：分配 tag、更新 RAT/busy/free/lsq
      if (in_ready) begin
        for (i_ff = 0; i_ff < W; i_ff = i_ff + 1) begin
          if (in_valid[i_ff]) begin
            free_vec[alloc_tag[i_ff]] <= 1'b0;
            busy[alloc_tag[i_ff]]     <= 1'b1;
            if (u_reg_we[i_ff])
              rat[u_rd[i_ff]] <= alloc_tag[i_ff];
          end
        end
        lsq_ptr    <= lsq_next;
        free_count <= free_count - n_valid + n_free;
      end else begin
        free_count <= free_count + n_free;
      end
    end
  end

endmodule
