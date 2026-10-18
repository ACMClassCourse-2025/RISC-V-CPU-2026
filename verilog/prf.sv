// -----------------------------------------------------------------------------
// prf.sv — 参数化物理寄存器堆
//
// 读口：2*W 个组合读口（每个发射 lane 的 src1/src2）。
// 写口：R 个 CDB 写口，与 cdb 广播同拍写入。
//
// 约定：
//   - 物理寄存器 0 恒为 0：读 0 返回 0，写 0 被忽略；
//   - 其他表项在复位时清 0，便于 bring-up/单测；rename 的 busy 语义保证
//     不会读取尚未写过的已分配 tag；
//   - 同拍多写口不检查冲突（CDB 仲裁保证 tag 唯一）。
// -----------------------------------------------------------------------------

module prf #(
  parameter integer W = `CPU_ISSUE_WIDTH,
  parameter integer R = `CPU_CDB_NUM
) (
  input  logic clk,
  input  logic reset,

  // 读口：lane p 的地址位于 [p*PW +: PW]
  input  logic [2*W*`CPU_PRF_IDX_W-1:0] raddr,
  output logic [2*W*32-1:0]             rdata,

  // 写口：CDB lane r
  input  logic [R-1:0]                    we,
  input  logic [R*`CPU_PRF_IDX_W-1:0]     waddr,
  input  logic [R*32-1:0]                 wdata
);

  localparam integer PW = `CPU_PRF_IDX_W;
  localparam integer PRF = `CPU_PRF_SIZE;

  logic [31:0] regs [0:PRF-1];

  integer p;
  always_comb begin
    for (p = 0; p < 2*W; p = p + 1) begin
      if (raddr[p*PW +: PW] == '0)
        rdata[p*32 +: 32] = 32'b0;
      else
        rdata[p*32 +: 32] = regs[raddr[p*PW +: PW]];
    end
  end

  integer r, k;
  always_ff @(posedge clk) begin
    if (reset) begin
      for (k = 0; k < PRF; k = k + 1)
        regs[k] <= 32'b0;
    end else begin
      for (r = 0; r < R; r = r + 1) begin
        if (we[r] && (waddr[r*PW +: PW] != '0))
          regs[waddr[r*PW +: PW]] <= wdata[r*32 +: 32];
      end
    end
  end

endmodule
