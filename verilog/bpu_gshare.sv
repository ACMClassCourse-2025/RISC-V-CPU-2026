// -----------------------------------------------------------------------------
// bpu_gshare.sv — P2 预研：BTB + gshare 方向预测器
//
// 与 bpu.sv 的 2-bit BHT 区别：
//   - BHT 索引 = PC 字索引 XOR 全局历史寄存器 GHR；
//   - GHR 每次 br_update 左移并写入实际方向；
//   - BTB/分配/同拍旁路策略与 bpu.sv 保持一致。
//
// 说明：br_update 总线当前不带预测时的 GHR 快照，原型用更新当拍的 GHR
// 索引 BHT；P2 正式接入时可在 ROB 表项中保存 GHR 快照后改为精确更新。
// RAS 需要 is_call/is_return 字段，待接口扩展后再加。
// -----------------------------------------------------------------------------

module bpu_gshare #(
  parameter integer BTB_INDEX_BITS = `CPU_BTB_INDEX_BITS,
  parameter integer BHT_INDEX_BITS = `CPU_BHT_INDEX_BITS,
  parameter integer GHIST_BITS     = 8
) (
  input  logic        clk,
  input  logic        reset,

  input  logic [31:0] fetch_pc,
  output logic        predict_taken,
  output logic [31:0] predict_target,

  input  logic        upd_valid,
  input  logic [31:0] upd_pc,
  input  logic        upd_taken,
  input  logic [31:0] upd_target,
  input  logic        upd_is_uncond
);

  localparam integer BTB_DEPTH    = 1 << BTB_INDEX_BITS;
  localparam integer BHT_DEPTH    = 1 << BHT_INDEX_BITS;
  localparam integer BTB_TAG_BITS = 32 - BTB_INDEX_BITS - 2;
  localparam integer GHW = (GHIST_BITS < BHT_INDEX_BITS) ? GHIST_BITS : BHT_INDEX_BITS;

  // BTB
  logic [BTB_DEPTH-1:0]    btb_valid;
  logic [BTB_TAG_BITS-1:0] btb_tag    [0:BTB_DEPTH-1];
  logic [31:0]             btb_target [0:BTB_DEPTH-1];
  logic                    btb_uncond [0:BTB_DEPTH-1];

  // gshare 方向表 + GHR
  logic [1:0]  bht [0:BHT_DEPTH-1];
  logic [BHT_DEPTH-1:0] bht_valid;
  logic [GHIST_BITS-1:0] ghr;
  logic [BHT_INDEX_BITS-1:0] ghr_xor;

  always_comb begin
    ghr_xor = '0;
    ghr_xor[GHW-1:0] = ghr[GHW-1:0];
  end

  logic [BTB_INDEX_BITS-1:0] fetch_btb_index, upd_btb_index;
  logic [BTB_TAG_BITS-1:0]   fetch_tag, upd_tag;
  logic [BHT_INDEX_BITS-1:0] fetch_bht_index, upd_bht_index;

  assign fetch_btb_index = fetch_pc[BTB_INDEX_BITS+1:2];
  assign fetch_tag       = fetch_pc[31:BTB_INDEX_BITS+2];
  assign upd_btb_index   = upd_pc[BTB_INDEX_BITS+1:2];
  assign upd_tag         = upd_pc[31:BTB_INDEX_BITS+2];

  assign fetch_bht_index = fetch_pc[BHT_INDEX_BITS+1:2] ^ ghr_xor;
  assign upd_bht_index   = upd_pc[BHT_INDEX_BITS+1:2] ^ ghr_xor;

  logic upd_btb_hit;
  assign upd_btb_hit = btb_valid[upd_btb_index] &&
                       (btb_tag[upd_btb_index] == upd_tag);

  // BHT 次态
  logic [1:0] bht_cur, bht_next;
  logic [GHIST_BITS-1:0] ghr_next;

  always_comb begin
    bht_cur  = bht_valid[upd_bht_index] ? bht[upd_bht_index] : 2'b01;
    bht_next = bht_cur;
    if (upd_valid) begin
      if (upd_is_uncond) bht_next = 2'b11;
      else if (upd_taken) begin
        if (bht_cur != 2'b11) bht_next = bht_cur + 2'b01;
      end else begin
        if (bht_cur != 2'b00) bht_next = bht_cur - 2'b01;
      end
    end
    ghr_next = {ghr[GHIST_BITS-2:0], upd_taken};
  end

  // 预测（含同拍更新旁路）
  logic        btb_valid_sel;
  logic [BTB_TAG_BITS-1:0] btb_tag_sel;
  logic [31:0] btb_target_sel;
  logic        btb_uncond_sel;
  logic [1:0]  bht_sel;
  logic        btb_hit;

  always_comb begin
    btb_valid_sel  = btb_valid[fetch_btb_index];
    btb_tag_sel    = btb_tag[fetch_btb_index];
    btb_target_sel = btb_target[fetch_btb_index];
    btb_uncond_sel = btb_uncond[fetch_btb_index];
    bht_sel        = bht_valid[fetch_bht_index] ? bht[fetch_bht_index] : 2'b01;

    if (upd_valid && (upd_btb_index == fetch_btb_index)) begin
      if (upd_is_uncond) begin
        btb_valid_sel  = 1'b1;
        btb_tag_sel    = upd_tag;
        btb_target_sel = upd_target;
        btb_uncond_sel = 1'b1;
      end else if (upd_taken) begin
        btb_valid_sel  = 1'b1;
        btb_tag_sel    = upd_tag;
        btb_target_sel = upd_target;
        btb_uncond_sel = 1'b0;
      end else if (btb_tag_sel == upd_tag) begin
        btb_uncond_sel = 1'b0;
      end
    end

    if (upd_valid && (upd_bht_index == fetch_bht_index)) begin
      if (upd_is_uncond) bht_sel = 2'b11;
      else if (upd_taken) bht_sel = upd_btb_hit ? bht_next : 2'b10;
      else if (upd_btb_hit) bht_sel = bht_next;
    end

    btb_hit = btb_valid_sel && (btb_tag_sel == fetch_tag);
  end

  assign predict_taken  = btb_hit && (btb_uncond_sel || bht_sel[1]);
  assign predict_target = btb_hit ? btb_target_sel : 32'b0;

  // 更新
  always_ff @(posedge clk) begin
    if (reset) begin
      btb_valid <= '0;
      bht_valid <= '0;
      ghr       <= '0;
    end else if (upd_valid) begin
      ghr <= ghr_next;
      if (upd_is_uncond) begin
        btb_valid[upd_btb_index]  <= 1'b1;
        btb_tag[upd_btb_index]    <= upd_tag;
        btb_target[upd_btb_index] <= upd_target;
        btb_uncond[upd_btb_index] <= 1'b1;
        bht[upd_bht_index]        <= 2'b11;
        bht_valid[upd_bht_index]  <= 1'b1;
      end else if (upd_taken) begin
        btb_valid[upd_btb_index]  <= 1'b1;
        btb_tag[upd_btb_index]    <= upd_tag;
        btb_target[upd_btb_index] <= upd_target;
        btb_uncond[upd_btb_index] <= 1'b0;
        bht[upd_bht_index]        <= upd_btb_hit ? bht_next : 2'b10;
        bht_valid[upd_bht_index]  <= 1'b1;
      end else if (upd_btb_hit) begin
        btb_uncond[upd_btb_index] <= 1'b0;
        bht[upd_bht_index]        <= bht_next;
        bht_valid[upd_bht_index]  <= 1'b1;
      end
    end
  end

endmodule
