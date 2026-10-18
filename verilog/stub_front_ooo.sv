// -----------------------------------------------------------------------------
// stub_front_ooo.sv — 乙侧脚本化前端（只用于单测，不进 filelist）
//
// 行为：
//   - TB 通过 push_valid/push_uop 推入一个 W-lane dispatch 组；
//   - 队列非空且 backend_ready=1 时，把队头组整体送给 backend，并弹出；
//   - commit/squash 由 TB 脚本直接驱动（本 stub 不自动提交）；
//   - cdb/complete/br_update 由 TB 在顶层观察，本模块不消费。
//
// 端口时序与真实前端一致：dispatch lane 的 valid 位由 push_uop 携带；
// backend_ready=0 时保持队头不变。DEPTH 为组数（不是 lane 数）。
// -----------------------------------------------------------------------------

module stub_front_ooo #(
  parameter integer W     = `CPU_ISSUE_WIDTH,
  parameter integer DEPTH = 8
) (
  input  logic clk,
  input  logic reset,

  // script push
  input  logic                          push_valid,
  input  logic [W*`CPU_DISPATCH_W-1:0]  push_uop,
  output logic                          push_ready,

  // script commit / squash
  input  logic [W*`CPU_COMMIT_W-1:0]    commit_in,
  input  logic [`CPU_SQUASH_W-1:0]      squash_in,
  output logic [W*`CPU_COMMIT_W-1:0]    commit_out,
  output logic [`CPU_SQUASH_W-1:0]      squash_out,

  // to backend
  output logic [W*`CPU_DISPATCH_W-1:0]  dispatch,
  input  logic                          backend_ready,

  output logic [7:0]                    count
);

  localparam integer GW = W * `CPU_DISPATCH_W;
  localparam integer CNTW = $clog2(DEPTH + 1);

  logic [DEPTH-1:0]       valid;
  logic [DEPTH*GW-1:0]    uop;
  logic [CNTW-1:0]        head, tail, cnt;

  assign push_ready = (cnt < DEPTH);
  assign count      = cnt[7:0];

  // 队头组合输出；空队列时输出全 0（valid 位也为 0）。
  always_comb begin
    dispatch = '0;
    if (cnt != 0)
      dispatch = uop[head*GW +: GW];
  end

  assign commit_out = commit_in;
  assign squash_out = squash_in;

  always_ff @(posedge clk) begin
    if (reset) begin
      valid <= '0;
      head  <= '0;
      tail  <= '0;
      cnt   <= '0;
    end else begin
      // pop：backend 吸收队头组
      if (backend_ready && (cnt != 0)) begin
        valid[head] <= 1'b0;
        head        <= (head == DEPTH-1) ? '0 : head + 1'b1;
        cnt         <= cnt - 1'b1;
      end

      // push：写队尾（同拍 pop+push 允许）
      if (push_valid && (cnt < DEPTH)) begin
        uop[tail*GW +: GW] <= push_uop;
        valid[tail]        <= 1'b1;
        tail               <= (tail == DEPTH-1) ? '0 : tail + 1'b1;
        if (!(backend_ready && (cnt != 0)))
          cnt <= cnt + 1'b1;
      end
    end
  end

endmodule
