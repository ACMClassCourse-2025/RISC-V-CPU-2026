// -----------------------------------------------------------------------------
// stub_exec.sv — 甲侧脚本化执行后端（只用于单测，不进 filelist）
//
// 行为：
//   - 接收 rename 送来的 dispatch（tag/rob_idx/pc/控制位/reg_we）；
//   - 按 tag 派生不同延迟，乱序返回 cdb（有值）或 complete（无值）；
//   - 分支返回 br_update，方向/目标由 force_taken/force_target 脚本控制；
//   - backend_ready 在 force_stall 或 pending 表满时拉低；
//   - squash 只做保守处理：丢弃 rob_idx 比 squash_idx 年轻且距离小于
//     DEPTH/2 的表项（测试用；真实后端由乙实现）。
//
// 该模块故意不实现真实执行语义，只负责制造完成顺序、反压和分支事件。
// -----------------------------------------------------------------------------

module stub_exec #(
  parameter integer W       = `CPU_ISSUE_WIDTH,
  parameter integer PENDING = 32
) (
  input  logic        clk,
  input  logic        reset,

  input  logic        force_stall,
  input  logic        force_taken,
  input  logic [31:0] force_target,

  input  logic [W-1:0]                 dispatch_valid,
  input  logic [W*`CPU_PRF_IDX_W-1:0]  dispatch_tag,
  input  logic [W*`CPU_ROB_TAG_W-1:0]  dispatch_rob_idx,
  input  logic [W*32-1:0]              dispatch_pc,
  input  logic [W-1:0]                 dispatch_is_branch,
  input  logic [W-1:0]                 dispatch_is_jal,
  input  logic [W-1:0]                 dispatch_is_jalr,
  input  logic [W-1:0]                 dispatch_reg_we,

  input  logic                         squash_valid,
  input  logic [`CPU_ROB_TAG_W-1:0]    squash_rob_idx,

  output logic        backend_ready,

  output logic        cdb_valid,
  output logic [`CPU_PRF_IDX_W-1:0] cdb_tag,
  output logic        cdb_exception,

  output logic [W-1:0]                 complete_valid,
  output logic [W*`CPU_PRF_IDX_W-1:0]  complete_tag,
  output logic [W-1:0]                 complete_exception,

  output logic        br_update_valid,
  output logic [31:0] br_update_pc,
  output logic        br_update_taken,
  output logic [31:0] br_update_target,
  output logic        br_update_is_jalr,
  output logic [`CPU_PRF_IDX_W-1:0] br_update_tag
);

  localparam integer PW = `CPU_PRF_IDX_W;
  localparam integer RW = `CPU_ROB_TAG_W;
  localparam integer DEPTH_MASK = `CPU_ROB_DEPTH - 1;

  logic [PENDING-1:0] p_valid;
  logic [PW-1:0]      p_tag      [0:PENDING-1];
  logic [RW-1:0]      p_rob      [0:PENDING-1];
  logic [31:0]        p_pc       [0:PENDING-1];
  logic               p_branch   [0:PENDING-1];
  logic               p_jalr     [0:PENDING-1];
  logic               p_reg_we   [0:PENDING-1];
  logic [2:0]         p_delay    [0:PENDING-1];

  // ---- 容量 ----------------------------------------------------------------
  integer i_free, i_cnt;
  logic [7:0] n_valid, n_free;
  always_comb begin
    n_valid = '0;
    for (i_cnt = 0; i_cnt < W; i_cnt = i_cnt + 1)
      if (dispatch_valid[i_cnt]) n_valid = n_valid + 1'b1;
    n_free = '0;
    for (i_free = 0; i_free < PENDING; i_free = i_free + 1)
      if (!p_valid[i_free]) n_free = n_free + 1'b1;
  end

  assign backend_ready = !force_stall && (n_free >= W);

  // ---- 选择一个可发射的 pending 表项 --------------------------------------
  integer i_emit;
  logic        emit_found;
  logic [7:0]  emit_idx;
  logic        emit_branch, emit_cdb, emit_comp;

  always_comb begin
    emit_found  = 1'b0;
    emit_idx    = '0;
    emit_branch = 1'b0;
    emit_cdb    = 1'b0;
    emit_comp   = 1'b0;

    // 优先分支（br_update 每拍最多一条），其次 cdb，最后 complete
    for (i_emit = 0; i_emit < PENDING; i_emit = i_emit + 1) begin
      if (!emit_found && p_valid[i_emit] && (p_delay[i_emit] == 3'd0) &&
          p_branch[i_emit]) begin
        emit_found  = 1'b1;
        emit_idx    = i_emit[7:0];
        emit_branch = 1'b1;
      end
    end
    for (i_emit = 0; i_emit < PENDING; i_emit = i_emit + 1) begin
      if (!emit_found && p_valid[i_emit] && (p_delay[i_emit] == 3'd0) &&
          !p_branch[i_emit] && p_reg_we[i_emit]) begin
        emit_found = 1'b1;
        emit_idx   = i_emit[7:0];
        emit_cdb   = 1'b1;
      end
    end
    for (i_emit = 0; i_emit < PENDING; i_emit = i_emit + 1) begin
      if (!emit_found && p_valid[i_emit] && (p_delay[i_emit] == 3'd0) &&
          !p_branch[i_emit] && !p_reg_we[i_emit]) begin
        emit_found = 1'b1;
        emit_idx   = i_emit[7:0];
        emit_comp  = 1'b1;
      end
    end
  end

  assign cdb_valid      = emit_cdb;
  assign cdb_tag        = p_tag[emit_idx];
  assign cdb_exception  = 1'b0;

  always_comb begin
    complete_valid     = '0;
    complete_valid[0]  = emit_comp | emit_branch;
    complete_tag       = '0;
    complete_tag[0 +: PW] = p_tag[emit_idx];
    complete_exception = '0;
  end

  assign br_update_valid    = emit_branch;
  assign br_update_pc       = p_pc[emit_idx];
  assign br_update_taken    = emit_branch ? force_taken : 1'b0;
  assign br_update_target   = force_target;
  assign br_update_is_jalr  = p_jalr[emit_idx];
  assign br_update_tag      = p_tag[emit_idx];

  // ---- 时序 ----------------------------------------------------------------
  integer i_ff, i_ff2, slot;
  logic [7:0] slot_count;

  always_ff @(posedge clk) begin
    if (reset) begin
      p_valid <= '0;
    end else begin
      // 延迟递减
      for (i_ff = 0; i_ff < PENDING; i_ff = i_ff + 1)
        if (p_valid[i_ff] && (p_delay[i_ff] != 3'd0))
          p_delay[i_ff] <= p_delay[i_ff] - 3'd1;

      // 发射/完成
      if (emit_found)
        p_valid[emit_idx] <= 1'b0;

      // squash：保守丢弃年轻表项
      if (squash_valid) begin
        for (i_ff2 = 0; i_ff2 < PENDING; i_ff2 = i_ff2 + 1) begin
          if (p_valid[i_ff2] &&
              (((p_rob[i_ff2] - squash_rob_idx) & (DEPTH_MASK)) != 0) &&
              (((p_rob[i_ff2] - squash_rob_idx) & (DEPTH_MASK)) < (PENDING / 2)))
            p_valid[i_ff2] <= 1'b0;
        end
      end

      // 分配：从低位找空槽，按 lane 顺序
      slot = 0;
      for (i_ff = 0; i_ff < W; i_ff = i_ff + 1) begin
        if (dispatch_valid[i_ff]) begin
          while (slot < PENDING && p_valid[slot]) slot = slot + 1;
          if (slot < PENDING) begin
            p_valid[slot]  <= 1'b1;
            p_tag[slot]    <= dispatch_tag[i_ff*PW +: PW];
            p_rob[slot]    <= dispatch_rob_idx[i_ff*RW +: RW];
            p_pc[slot]     <= dispatch_pc[i_ff*32 +: 32];
            p_branch[slot] <= dispatch_is_branch[i_ff] |
                              dispatch_is_jal[i_ff] |
                              dispatch_is_jalr[i_ff];
            p_jalr[slot]   <= dispatch_is_jalr[i_ff];
            p_reg_we[slot] <= dispatch_reg_we[i_ff];
            p_delay[slot]  <= (dispatch_tag[i_ff*PW +: PW] % 4) + 1;
            slot = slot + 1;
          end
        end
      end
    end
  end

endmodule
