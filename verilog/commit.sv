// -----------------------------------------------------------------------------
// commit.sv — 按序提交窗口选择（组合）
//
// 从 ROB 头部开始，逐 lane 检查：
//   valid && done && (非控制指令 || 分支已解析)
// 只有前缀连续满足的 lane 才提交；遇到第一条不满足的 lane 立即停止。
// 非法/异常指令可以提交（用于 P1 提交时停机），但它之后的 lane 不再提交。
//
// 该模块只做窗口选择，不修改 ROB 状态；ROB 根据 commit_valid 出队。
// -----------------------------------------------------------------------------

module commit #(
  parameter integer W = `CPU_ISSUE_WIDTH
) (
  input  logic [W-1:0] valid,
  input  logic [W-1:0] done,
  input  logic [W-1:0] is_control,   // branch / jal / jalr
  input  logic [W-1:0] resolved,     // 收到 br_update
  input  logic [W-1:0] exception,    // illegal 或异常
  output logic [W-1:0] commit_valid,
  output logic         halt          // 本拍提交了异常/非法指令
);

  integer i;
  logic   stop;

  always_comb begin
    commit_valid = '0;
    halt         = 1'b0;
    stop         = 1'b0;

    for (i = 0; i < W; i = i + 1) begin
      if (!stop && valid[i] && done[i] &&
          (!is_control[i] || resolved[i])) begin
        commit_valid[i] = 1'b1;
        if (exception[i]) begin
          halt = 1'b1;
          stop = 1'b1;      // 异常指令之后的 lane 不提交
        end
      end else begin
        stop = 1'b1;
      end
    end
  end

endmodule
