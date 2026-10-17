// -----------------------------------------------------------------------------
// bpu.sv — 分支预测单元原型（BTB + 2-bit BHT）
//
// 结构：
//   - BTB：直接映射，表项 {valid, tag, target, is_uncond}；
//     项数 2^BTB_INDEX_BITS，索引取 pc[BTB_INDEX_BITS+1:2]（字地址）；
//   - BHT：2-bit 饱和计数器，项数 2^BHT_INDEX_BITS，
//     索引取 pc[BHT_INDEX_BITS+1:2]；复位为 2'b01（弱不跳转）。
//
// 预测（组合）：
//   - BTB 未命中：predict_taken=0、predict_target=0；
//   - 命中无条件跳转（JAL/JALR）：predict_taken=1；
//   - 命中条件分支：BHT 最高位为 1 时 predict_taken=1；
//   - 命中时 predict_target 给出 BTB 中保存的目标。
//
// 更新（来自前端收到的 br_update）：
//   - 每条解析完成的分支/跳转更新一次；
//   - 无条件跳转：分配/覆盖 BTB 项，BHT 置为强跳转；
//   - 条件分支跳转：分配/覆盖 BTB 项，BHT 加一饱和；
//   - 条件分支不跳转：BHT 减一饱和；若 BTB 中同 tag 项存在则保留，
//     不分配新项（避免从不跳转的分支污染 BTB）。
//
// 同拍读写冲突：若更新索引与当前 fetch_pc 的索引相同，预测逻辑用更新后的
// 值做旁路，保证同一拍内可见新方向/新目标。
//
// 说明：br_update 总线本身只带 is_jalr，不足以区分 JAL 与条件分支；前端在
// 收到 br_update 时可从对应 uop 的译码信息得到 is_uncond，随更新口送入。
// -----------------------------------------------------------------------------

module bpu #(
  parameter integer BTB_INDEX_BITS = `CPU_BTB_INDEX_BITS,
  parameter integer BHT_INDEX_BITS = `CPU_BHT_INDEX_BITS
) (
  input  logic        clk,
  input  logic        reset,

  // 预测口（组合）
  input  logic [31:0] fetch_pc,
  output logic        predict_taken,
  output logic [31:0] predict_target,

  // 更新口（来自 br_update；is_uncond 由前端从 uop 译码信息补充）
  input  logic        upd_valid,
  input  logic [31:0] upd_pc,
  input  logic        upd_taken,
  input  logic [31:0] upd_target,
  input  logic        upd_is_uncond
);

  localparam integer BTB_DEPTH    = 1 << BTB_INDEX_BITS;
  localparam integer BHT_DEPTH    = 1 << BHT_INDEX_BITS;
  localparam integer BTB_TAG_BITS = 32 - BTB_INDEX_BITS - 2;

  // BTB 表项
  logic [BTB_DEPTH-1:0]       btb_valid;
  logic [BTB_TAG_BITS-1:0]    btb_tag     [0:BTB_DEPTH-1];
  logic [31:0]                btb_target  [0:BTB_DEPTH-1];
  logic                       btb_uncond  [0:BTB_DEPTH-1];

  // 2-bit 方向计数器
  logic [1:0]                 bht [0:BHT_DEPTH-1];

  // ---- 索引与 tag ----------------------------------------------------------
  logic [BTB_INDEX_BITS-1:0]  fetch_btb_index;
  logic [BTB_TAG_BITS-1:0]    fetch_tag;
  logic [BHT_INDEX_BITS-1:0]  fetch_bht_index;

  logic [BTB_INDEX_BITS-1:0]  upd_btb_index;
  logic [BTB_TAG_BITS-1:0]    upd_tag;
  logic [BHT_INDEX_BITS-1:0]  upd_bht_index;

  assign fetch_btb_index = fetch_pc[BTB_INDEX_BITS+1:2];
  assign fetch_tag       = fetch_pc[31:BTB_INDEX_BITS+2];
  assign fetch_bht_index = fetch_pc[BHT_INDEX_BITS+1:2];

  assign upd_btb_index   = upd_pc[BTB_INDEX_BITS+1:2];
  assign upd_tag         = upd_pc[31:BTB_INDEX_BITS+2];
  assign upd_bht_index   = upd_pc[BHT_INDEX_BITS+1:2];

  logic upd_btb_hit;
  assign upd_btb_hit = btb_valid[upd_btb_index] &&
                       (btb_tag[upd_btb_index] == upd_tag);

  // ---- BHT 次态（组合） ----------------------------------------------------
  logic [1:0] bht_cur;
  logic [1:0] bht_next;

  always_comb begin
    bht_cur  = bht[upd_bht_index];
    bht_next = bht_cur;
    if (upd_valid) begin
      if (upd_is_uncond) begin
        bht_next = 2'b11;
      end else if (upd_taken) begin
        if (bht_cur != 2'b11) bht_next = bht_cur + 2'b01;
      end else begin
        if (bht_cur != 2'b00) bht_next = bht_cur - 2'b01;
      end
    end
  end

  // ---- 预测（组合，含同拍更新旁路） ---------------------------------------
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
    bht_sel        = bht[fetch_bht_index];

    if (upd_valid && (upd_btb_index == fetch_btb_index)) begin
      if (upd_is_uncond) begin
        // 无条件跳转：本拍分配/覆盖新项
        btb_valid_sel  = 1'b1;
        btb_tag_sel    = upd_tag;
        btb_target_sel = upd_target;
        btb_uncond_sel = 1'b1;
      end else if (upd_taken) begin
        // 条件分支跳转：本拍分配/覆盖新项
        btb_valid_sel  = 1'b1;
        btb_tag_sel    = upd_tag;
        btb_target_sel = upd_target;
        btb_uncond_sel = 1'b0;
      end else if (btb_tag_sel == upd_tag) begin
        // 条件分支不跳转且已有同 tag 项：只清无条件标志
        btb_uncond_sel = 1'b0;
      end
    end

    if (upd_valid && (upd_bht_index == fetch_bht_index)) begin
      if (upd_is_uncond) begin
        bht_sel = 2'b11;
      end else if (upd_taken) begin
        bht_sel = upd_btb_hit ? bht_next : 2'b10;
      end else if (upd_btb_hit) begin
        bht_sel = bht_next;
      end
    end

    btb_hit = btb_valid_sel && (btb_tag_sel == fetch_tag);
  end

  assign predict_taken  = btb_hit && (btb_uncond_sel || bht_sel[1]);
  assign predict_target = btb_hit ? btb_target_sel : 32'b0;

  // ---- 更新 ----------------------------------------------------------------
  // 说明：BTB 的 tag/target/uncond 与 BHT 数据阵列不做复位，只复位 valid。
  // valid=0 时这些内容不会被预测使用；首次分配表项时会把 BHT 显式初始化为
  // 强/弱跳转，因此不会把未初始化数据带到有效表项上。
  always_ff @(posedge clk) begin
    if (reset) begin
      btb_valid <= '0;
    end else if (upd_valid) begin
      if (upd_is_uncond) begin
        // 无条件跳转：分配表项，方向恒为强跳转
        btb_valid[upd_btb_index]  <= 1'b1;
        btb_tag[upd_btb_index]    <= upd_tag;
        btb_target[upd_btb_index] <= upd_target;
        btb_uncond[upd_btb_index] <= 1'b1;
        bht[upd_bht_index]        <= 2'b11;
      end else if (upd_taken) begin
        // 条件分支跳转：分配表项；已有同 tag 项时饱和加一，否则初始化为
        // 弱跳转（第一次观察到 taken 后下次预测 taken）。
        btb_valid[upd_btb_index]  <= 1'b1;
        btb_tag[upd_btb_index]    <= upd_tag;
        btb_target[upd_btb_index] <= upd_target;
        btb_uncond[upd_btb_index] <= 1'b0;
        bht[upd_bht_index]        <= upd_btb_hit ? bht_next : 2'b10;
      end else if (upd_btb_hit) begin
        // 条件分支不跳转：仅更新已有同 tag 项的计数器，不分配新项
        btb_uncond[upd_btb_index] <= 1'b0;
        bht[upd_bht_index]        <= bht_next;
      end
    end
  end

endmodule
