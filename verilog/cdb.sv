// -----------------------------------------------------------------------------
// cdb.sv — 公共数据总线仲裁器
//
// 源：W 个 ALU lane + 1 个 load + 1 个 divider = W+2 个结果源。
// 输出：R 条 CDB lane（默认 1）。
//
// 协议：
//   - 源保持 valid/tag/value 直到 src_ready=1（同一拍即被 CDB 吸收）；
//   - 每拍每条 CDB lane 最多选一个源，同一源不会在同一拍被选两次；
//   - 轮转优先级避免固定低编号源饿死高编号源；
//   - 未获胜的源必须由调用方保持，下一拍重试。
// -----------------------------------------------------------------------------

module cdb #(
  parameter integer W = `CPU_ISSUE_WIDTH,
  parameter integer R = `CPU_CDB_NUM
) (
  input  logic clk,
  input  logic reset,

  input  logic [W+1:0]                   src_valid,
  input  logic [(W+2)*`CPU_PRF_IDX_W-1:0] src_tag,
  input  logic [(W+2)*32-1:0]            src_value,
  input  logic [W+1:0]                   src_exception,
  output logic [W+1:0]                   src_ready,

  output logic [R*`CPU_CDB_W-1:0]        cdb_out
);

  localparam integer N  = W + 2;
  localparam integer PW = `CPU_PRF_IDX_W;
  localparam integer CW = `CPU_CDB_W;

  logic [3:0]     last;
  logic [N-1:0]   chosen;
  integer         r, k, idx;
  logic           found;

  always_comb begin
    cdb_out   = '0;
    src_ready = '0;
    chosen    = '0;

    for (r = 0; r < R; r = r + 1) begin
      found = 1'b0;
      for (k = 0; k < N; k = k + 1) begin
        idx = (last + r + k + 1) % N;
        if (!found && !chosen[idx] && src_valid[idx]) begin
          found             = 1'b1;
          chosen[idx]       = 1'b1;
          src_ready[idx]    = 1'b1;
          cdb_out[r*CW + `CPU_CDB_VALID_OFF] = 1'b1;
          cdb_out[r*CW + `CPU_CDB_TAG_OFF +: PW] = src_tag[idx*PW +: PW];
          cdb_out[r*CW + `CPU_CDB_VALUE_OFF +: 32] = src_value[idx*32 +: 32];
          cdb_out[r*CW + `CPU_CDB_EXCEPTION_OFF] = src_exception[idx];
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (reset)
      last <= 4'b0;
    else if (|src_valid)
      last <= (last == N-1) ? 4'b0 : last + 4'b1;
  end

endmodule
