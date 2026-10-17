// -----------------------------------------------------------------------------
// pc_unit.sv — 程序计数器（PC）与重定向
//
// 每个时钟沿按以下优先级更新 PC：
//   1. reset：PC 回到程序入口 0x0000_0000（高有效、同步复位）；
//   2. redirect_valid：PC 切换到 redirect_pc（分支/跳转恢复，最高运行优先级）；
//   3. stall：保持当前 PC（下游未接收，冻结取指）；
//   4. advance：PC += 4（下游接收一条指令）。
// redirect 在有效当拍的时钟沿被接受，下一拍 PC 输出已经是新值。
//
// 该模块只保存 PC，不关心取指是否命中；重定向由前端在收到 br_update 并与
// ROB 中保存的预测比较后产生。PC 按 32 位自然回绕（0xFFFF_FFFC + 4 = 0）。
// -----------------------------------------------------------------------------

module pc_unit (
  input  logic        clk,
  input  logic        reset,
  input  logic        advance,        // 下游接收，pc <= pc + 4
  input  logic        stall,          // 保持当前 PC
  input  logic        redirect_valid, // 重定向有效
  input  logic [31:0] redirect_pc,    // 重定向目标
  output logic [31:0] pc
);

  always_ff @(posedge clk) begin
    if (reset) begin
      pc <= 32'b0;                    // 程序入口固定为 0x0000_0000
    end else if (redirect_valid) begin
      pc <= redirect_pc;              // redirect > stall > advance
    end else if (stall) begin
      pc <= pc;                       // 冻结
    end else if (advance) begin
      pc <= pc + 32'd4;               // 32 位加法自然回绕
    end
  end

endmodule
