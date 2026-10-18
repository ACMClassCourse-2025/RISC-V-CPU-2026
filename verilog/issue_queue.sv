// -----------------------------------------------------------------------------
// issue_queue.sv — 统一发射队列（P1）
//
// 结构：
//   - W 路 dispatch 写入；D 项表项，按 age 选择最老的 ready uop；
//   - 源操作数就绪位在 dispatch 同拍用本拍 CDB 做旁路比较（关键，避免漏唤醒）；
//   - CDB 广播清 busy；squash 按 rob_idx 丢弃更年轻的表项；
//   - 输出 IW 路发射（P1 用 IW=1；dispatch 宽度仍可以是 W=2）。
//
// 表项字段只保存发射所需信息：完整 dispatch uop、两个源 tag/ready、age、rob_idx。
// 结果写回、PRF 读、执行单元由 backend_ooo 负责。
// -----------------------------------------------------------------------------

module issue_queue #(
  parameter integer W  = `CPU_ISSUE_WIDTH,
  parameter integer D  = `CPU_RS_DEPTH,
  parameter integer IW = 1
) (
  input  logic clk,
  input  logic reset,

  // dispatch
  input  logic [W-1:0]                       in_valid,
  input  logic [W*`CPU_DISPATCH_W-1:0]       in_uop,
  output logic                               in_ready,

  // CDB wake (R lanes)
  input  logic [`CPU_CDB_NUM-1:0]            wake_valid,
  input  logic [`CPU_CDB_NUM*`CPU_PRF_IDX_W-1:0] wake_tag,

  // squash
  input  logic                               squash_valid,
  input  logic [`CPU_ROB_TAG_W-1:0]          squash_rob_idx,

  // issue
  output logic [IW-1:0]                      out_valid,
  output logic [IW*`CPU_DISPATCH_W-1:0]      out_uop,
  input  logic                               out_ready,

  // status
  output logic [7:0]                         count,
  output logic [7:0]                         free_count
);

  localparam integer PW  = `CPU_PRF_IDX_W;
  localparam integer RW  = `CPU_ROB_TAG_W;
  localparam integer DW  = `CPU_DISPATCH_W;
  localparam integer R   = `CPU_CDB_NUM;

  logic [D-1:0]       valid;
  logic [D*DW-1:0]    uop;
  logic [D*PW-1:0]    src1_tag;
  logic [D*PW-1:0]    src2_tag;
  logic [D-1:0]       src1_ready;
  logic [D-1:0]       src2_ready;
  logic [D*16-1:0]    seq;
  logic [D*RW-1:0]    rob_idx;


  // ---- dispatch 字段解包 --------------------------------------------------
  logic [PW-1:0]      in_src1_tag [0:W-1];
  logic [PW-1:0]      in_src2_tag [0:W-1];
  logic               in_src1_rdy [0:W-1];
  logic               in_src2_rdy [0:W-1];
  logic [RW-1:0]      in_rob      [0:W-1];
  integer             i, lane;

  always_comb begin
    for (i = 0; i < W; i = i + 1) begin
      in_src1_tag[i] = in_uop[i*DW + `CPU_DISPATCH_SRC1_TAG_OFF +: PW];
      in_src2_tag[i] = in_uop[i*DW + `CPU_DISPATCH_SRC2_TAG_OFF +: PW];
      in_src1_rdy[i] = in_uop[i*DW + `CPU_DISPATCH_SRC1_READY_OFF];
      in_src2_rdy[i] = in_uop[i*DW + `CPU_DISPATCH_SRC2_READY_OFF];
      in_rob[i]      = in_uop[i*DW + `CPU_DISPATCH_ROB_IDX_OFF +: RW];
    end
  end

  // ---- 计数 / squash ------------------------------------------------------
  logic [7:0] n_in;
  logic [D-1:0] squash_mask;
  logic [7:0] n_squash;
  logic [7:0] free_after;
  logic [RW-1:0] rob_diff;

  always_comb begin
    n_in = '0;
    for (i = 0; i < W; i = i + 1)
      if (in_valid[i]) n_in = n_in + 1'b1;
  end

  always_comb begin
    squash_mask = '0;
    n_squash = '0;
    rob_diff = '0;
    for (i = 0; i < D; i = i + 1) begin
      if (valid[i]) begin
        rob_diff = (rob_idx[i*RW +: RW] - squash_rob_idx) & ((1 << RW) - 1);
        if (squash_valid && (rob_diff != '0) && (rob_diff < (`CPU_ROB_DEPTH/2)))
          squash_mask[i] = 1'b1;
      end
    end
    for (i = 0; i < D; i = i + 1)
      if (squash_mask[i]) n_squash = n_squash + 1'b1;
  end

  always_comb begin
    count = '0;
    free_count = '0;
    for (i = 0; i < D; i = i + 1) begin
      if (valid[i]) count = count + 1'b1;
      else          free_count = free_count + 1'b1;
    end
  end

  assign free_after = free_count + n_squash;

  assign in_ready = (free_after >= n_in);

  // ---- 分配槽位（squash 槽可复用）----------------------------------------
  logic [D-1:0] alloc_used;
  logic [7:0]   alloc_slot [0:W-1];
  logic [7:0]   slot_found;

  always_comb begin
    alloc_used = '0;
    for (lane = 0; lane < W; lane = lane + 1) begin
      alloc_slot[lane] = '0;
      slot_found = 1'b0;
      for (i = 0; i < D; i = i + 1) begin
        if (!slot_found && !alloc_used[i] &&
            (!valid[i] || squash_mask[i])) begin
          alloc_slot[lane] = i[7:0];
          alloc_used[i] = 1'b1;
          slot_found = 1'b1;
        end
      end
    end
  end

  // ---- 发射选择：最老的 ready 表项 ---------------------------------------
  logic [D-1:0] cand;
  logic [D-1:0] chosen;
  logic [IW-1:0] sel_valid;
  logic [7:0]   sel_idx [0:IW-1];
  logic [15:0]  best_seq;
  logic [7:0]   best_idx;
  logic         found;

  always_comb begin
    cand = '0;
    for (i = 0; i < D; i = i + 1)
      cand[i] = valid[i] && !squash_mask[i] && src1_ready[i] && src2_ready[i];

    chosen = '0;
    for (lane = 0; lane < IW; lane = lane + 1) begin
      sel_valid[lane] = 1'b0;
      sel_idx[lane] = '0;
      best_seq = 16'hffff;
      best_idx = '0;
      found = 1'b0;
      for (i = 0; i < D; i = i + 1) begin
        if (cand[i] && !chosen[i] && (!found || (seq[i*16 +: 16] < best_seq))) begin
          found = 1'b1;
          best_seq = seq[i*16 +: 16];
          best_idx = i[7:0];
        end
      end
      if (found) begin
        sel_valid[lane] = 1'b1;
        sel_idx[lane] = best_idx;
        chosen[best_idx] = 1'b1;
      end
    end
  end

  always_comb begin
    out_valid = sel_valid;
    out_uop = '0;
    for (lane = 0; lane < IW; lane = lane + 1) begin
      if (sel_valid[lane])
        out_uop[lane*DW +: DW] = uop[sel_idx[lane]*DW +: DW];
    end
  end

  // ---- 同拍 CDB 旁路匹配 --------------------------------------------------
  function automatic logic tag_hit(input logic [PW-1:0] tag);
    integer w;
    begin
      tag_hit = 1'b0;
      for (w = 0; w < R; w = w + 1)
        if (wake_valid[w] && (wake_tag[w*PW +: PW] == tag))
          tag_hit = 1'b1;
    end
  endfunction

  // ---- 时序 ----------------------------------------------------------------
  logic [15:0] seq_counter;

  always_ff @(posedge clk) begin
    if (reset) begin
      valid      <= '0;
      src1_ready <= '0;
      src2_ready <= '0;
      seq_counter <= '0;
    end else begin
      // 1) squash：清更年轻的表项
      for (i = 0; i < D; i = i + 1) begin
        if (squash_mask[i]) begin
          valid[i]      <= 1'b0;
          src1_ready[i] <= 1'b0;
          src2_ready[i] <= 1'b0;
        end
      end

      // 2) CDB 唤醒：只清 busy 位，不丢表项
      for (i = 0; i < D; i = i + 1) begin
        if (valid[i] && !squash_mask[i]) begin
          if (!src1_ready[i] && tag_hit(src1_tag[i*PW +: PW]))
            src1_ready[i] <= 1'b1;
          if (!src2_ready[i] && tag_hit(src2_tag[i*PW +: PW]))
            src2_ready[i] <= 1'b1;
        end
      end

      // 3) 发射：吸收后释放表项
      if (out_ready) begin
        for (lane = 0; lane < IW; lane = lane + 1)
          if (sel_valid[lane]) valid[sel_idx[lane]] <= 1'b0;
      end

      // 4) dispatch 写入（最后执行，允许复用 squash 槽）
      for (lane = 0; lane < W; lane = lane + 1) begin
        if (in_valid[lane] && in_ready) begin
          uop[alloc_slot[lane]*DW +: DW] <= in_uop[lane*DW +: DW];
          src1_tag[alloc_slot[lane]*PW +: PW] <= in_src1_tag[lane];
          src2_tag[alloc_slot[lane]*PW +: PW] <= in_src2_tag[lane];
          // 同拍 CDB 旁路：dispatch 写入时新 tag 已在本拍广播则直接 ready。
          src1_ready[alloc_slot[lane]] <= in_src1_rdy[lane] |
                                          tag_hit(in_src1_tag[lane]);
          src2_ready[alloc_slot[lane]] <= in_src2_rdy[lane] |
                                          tag_hit(in_src2_tag[lane]);
          rob_idx[alloc_slot[lane]*RW +: RW] <= in_rob[lane];
          seq[alloc_slot[lane]*16 +: 16] <= seq_counter + lane;
          valid[alloc_slot[lane]] <= 1'b1;
        end
      end
      if (in_ready)
        seq_counter <= seq_counter + {8'b0, n_in};
    end
  end

endmodule
