// -----------------------------------------------------------------------------
// lsq.sv — load/store queue v1
//
// 表项按 rename 分配的 lsq_id 索引（CPU_LSQ_DEPTH 项）。职责：
//   - dispatch 时按 lsq_id 占用表项，满/复用冲突时反压；
//   - issue 时填入地址/写数据/写掩码；
//   - commit：load 立即释放；store 标记 committed，等待写内存完成；
//   - store drain：按分配顺序选最老的已提交 store 写内存，完成后释放；
//   - load 排序：查询更老 store 的地址是否已知、是否同字地址且尚未写出。
//
// P1 采用保守策略：load 只需等更老 store 地址已知；若同字地址，则等它
// 真正写完成。不同字地址的 store 不阻塞 load。
// -----------------------------------------------------------------------------

module lsq #(
  parameter integer W = `CPU_ISSUE_WIDTH,
  parameter integer D = `CPU_LSQ_DEPTH
) (
  input  logic clk,
  input  logic reset,

  // dispatch allocation
  input  logic [W-1:0]                 alloc_valid,
  input  logic [W*`CPU_LSQ_IDX_W-1:0]  alloc_id,
  input  logic [W*`CPU_ROB_TAG_W-1:0]  alloc_rob,
  input  logic [W-1:0]                 alloc_is_store,
  output logic                         alloc_ready,

  // issue fill
  input  logic                         fill_valid,
  input  logic [`CPU_LSQ_IDX_W-1:0]    fill_id,
  input  logic [31:0]                  fill_addr,
  input  logic [31:0]                  fill_wdata,
  input  logic [3:0]                   fill_wstrb,
  input  logic                         fill_is_store,

  // commit
  input  logic [W-1:0]                 commit_valid,
  input  logic [W-1:0]                 commit_is_store,
  input  logic [W-1:0]                 commit_is_load,
  input  logic [W*`CPU_LSQ_IDX_W-1:0]  commit_id,

  // squash
  input  logic                         squash_valid,
  input  logic [`CPU_ROB_TAG_W-1:0]    squash_rob_idx,

  // store drain
  output logic                         drain_valid,
  output logic [`CPU_LSQ_IDX_W-1:0]    drain_id,
  output logic [31:0]                  drain_addr,
  output logic [31:0]                  drain_wdata,
  output logic [3:0]                   drain_wstrb,
  input  logic                         drain_done,

  // load ordering query
  input  logic                         query_valid,
  input  logic [`CPU_LSQ_IDX_W-1:0]    query_id,
  input  logic [31:0]                  query_addr,
  output logic                         query_blocked,

  output logic [7:0]                   count
);

  localparam integer LW = `CPU_LSQ_IDX_W;
  localparam integer RW = `CPU_ROB_TAG_W;

  logic [D-1:0]    valid;
  logic [D-1:0]    is_store;
  logic [D*RW-1:0] rob;
  logic [D*16-1:0] seq;
  logic [D-1:0]    addr_known;
  logic [D*32-1:0] addr;
  logic [D*32-1:0] wdata;
  logic [D*4-1:0]  wstrb;
  logic [D-1:0]    committed;
  logic [15:0]     seq_counter;
  logic [7:0]      n_alloc;

  integer i, lane;
  logic [`CPU_LSQ_IDX_W-1:0] id;

  // ---- allocation ---------------------------------------------------------
  logic [D-1:0] free_by_commit;
  logic [D-1:0] free_mask;
  logic [D-1:0] alloc_used;
  logic         alloc_ok;
  logic         commit_hit;

  always_comb begin
    free_by_commit = '0;
    for (i = 0; i < D; i = i + 1) begin
      commit_hit = 1'b0;
      for (lane = 0; lane < W; lane = lane + 1) begin
        if (commit_valid[lane] && commit_is_load[lane] &&
            (commit_id[lane*LW +: LW] == i[LW-1:0]))
          commit_hit = 1'b1;
      end
      free_by_commit[i] = commit_hit;
    end
  end

  always_comb begin
    free_mask = '0;
    for (i = 0; i < D; i = i + 1)
      free_mask[i] = !valid[i] || free_by_commit[i] ||
                     (drain_done && drain_valid &&
                      (drain_id == i[LW-1:0]));

    alloc_ok = 1'b1;
    alloc_used = '0;
    id = '0;
    for (lane = 0; lane < W; lane = lane + 1) begin
      if (alloc_valid[lane]) begin
        id = alloc_id[lane*LW +: LW];
        if (!free_mask[id] || alloc_used[id])
          alloc_ok = 1'b0;
        alloc_used[id] = 1'b1;
      end
    end
    alloc_ready = alloc_ok;
  end

  // ---- squash -------------------------------------------------------------
  logic [D-1:0] squash_mask;
  logic [RW-1:0] rob_diff;

  always_comb begin
    squash_mask = '0;
    rob_diff = '0;
    for (i = 0; i < D; i = i + 1) begin
      if (valid[i] && !committed[i]) begin
        rob_diff = (rob[i*RW +: RW] - squash_rob_idx) & ((1 << RW) - 1);
        if (squash_valid && (rob_diff != '0) &&
            (rob_diff < (`CPU_ROB_DEPTH/2)))
          squash_mask[i] = 1'b1;
      end
    end
  end

  // ---- store drain selection ---------------------------------------------
  logic [15:0] best_seq;
  logic [`CPU_LSQ_IDX_W-1:0] best_id;
  logic        found;

  always_comb begin
    drain_valid = 1'b0;
    drain_id    = '0;
    drain_addr  = 32'b0;
    drain_wdata = 32'b0;
    drain_wstrb = 4'b0;
    best_seq    = 16'hffff;
    best_id     = '0;
    found       = 1'b0;
    for (i = 0; i < D; i = i + 1) begin
      if (valid[i] && is_store[i] && committed[i]) begin
        if (!found || (seq[i*16 +: 16] < best_seq)) begin
          found       = 1'b1;
          best_seq    = seq[i*16 +: 16];
          best_id     = i[LW-1:0];
        end
      end
    end
    if (found) begin
      drain_valid = 1'b1;
      drain_id    = best_id;
      drain_addr  = addr[best_id*32 +: 32];
      drain_wdata = wdata[best_id*32 +: 32];
      drain_wstrb = wstrb[best_id*4 +: 4];
    end
  end

  // ---- load ordering query ------------------------------------------------
  logic [15:0] load_seq;

  always_comb begin
    query_blocked = 1'b0;
    load_seq = seq[query_id*16 +: 16];
    if (query_valid) begin
      for (i = 0; i < D; i = i + 1) begin
        if (valid[i] && is_store[i] && (seq[i*16 +: 16] < load_seq)) begin
          if (!addr_known[i])
            query_blocked = 1'b1;
          else if ((addr[i*32 +: 32] & ~32'h3) == (query_addr & ~32'h3))
            query_blocked = 1'b1;
        end
      end
    end
  end

  // ---- count --------------------------------------------------------------
  always_comb begin
    count = '0;
    n_alloc = '0;
    for (i = 0; i < D; i = i + 1)
      if (valid[i]) count = count + 1'b1;
    for (lane = 0; lane < W; lane = lane + 1)
      if (alloc_valid[lane]) n_alloc = n_alloc + 1'b1;
  end

  // ---- sequential ---------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      valid       <= '0;
      addr_known  <= '0;
      committed   <= '0;
      seq_counter <= '0;
    end else begin
      // squash
      for (i = 0; i < D; i = i + 1) begin
        if (squash_mask[i]) begin
          valid[i]      <= 1'b0;
          addr_known[i] <= 1'b0;
          committed[i]  <= 1'b0;
        end
      end

      // fill on issue
      if (fill_valid) begin
        addr[fill_id*32 +: 32]      <= fill_addr;
        wdata[fill_id*32 +: 32]     <= fill_wdata;
        wstrb[fill_id*4 +: 4]       <= fill_wstrb;
        is_store[fill_id]           <= fill_is_store;
        addr_known[fill_id]         <= 1'b1;
      end

      // commit release / mark
      for (lane = 0; lane < W; lane = lane + 1) begin
        if (commit_valid[lane]) begin
          if (commit_is_load[lane]) begin
            valid[commit_id[lane*LW +: LW]]      <= 1'b0;
            addr_known[commit_id[lane*LW +: LW]] <= 1'b0;
            committed[commit_id[lane*LW +: LW]]  <= 1'b0;
          end else if (commit_is_store[lane]) begin
            committed[commit_id[lane*LW +: LW]] <= 1'b1;
          end
        end
      end

      // store write completion
      if (drain_done && drain_valid) begin
        valid[drain_id]      <= 1'b0;
        addr_known[drain_id] <= 1'b0;
        committed[drain_id]  <= 1'b0;
      end

      // allocation (last, so a freed id can be reused immediately)
      if (alloc_ready) begin
        for (lane = 0; lane < W; lane = lane + 1) begin
          if (alloc_valid[lane]) begin
            valid[alloc_id[lane*LW +: LW]]      <= 1'b1;
            is_store[alloc_id[lane*LW +: LW]]   <= alloc_is_store[lane];
            rob[alloc_id[lane*LW +: LW]*RW +: RW] <= alloc_rob[lane*RW +: RW];
            seq[alloc_id[lane*LW +: LW]*16 +: 16] <= seq_counter + lane;
            addr_known[alloc_id[lane*LW +: LW]] <= 1'b0;
            committed[alloc_id[lane*LW +: LW]]  <= 1'b0;
          end
        end
        seq_counter <= seq_counter + n_alloc;
      end
    end
  end

endmodule
