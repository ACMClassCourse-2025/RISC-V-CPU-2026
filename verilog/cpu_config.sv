// -----------------------------------------------------------------------------
// cpu_config.sv — 全局参数配置（由 tools/config_gen.py 生成，请勿手改）
//
// 生成命令：
//   tools/config_gen.py --issue-width 1 --rob 32 --prf 64 --rs 8 --cdb-num 1 --lsq 8 --icache-index-bits 10 --icache-ways 1 --icache-line-bytes 4 --dcache-index-bits 10 --dcache-ways 1 --dcache-line-bytes 4 --btb-index-bits 6 --bht-index-bits 8
//
// 换参数 = 重新生成 + 重编译，不改任何 RTL。每个宏都有 `ifndef 保护，
// 因此也可以用 Verilator/Yosys 的 -D 选项临时覆盖单个参数。
// 参数含义与验收档位见 docs/plan/division.md §0.3。
// -----------------------------------------------------------------------------

// ---- 核心微架构参数 ---------------------------------------------------------
`ifndef CPU_ISSUE_WIDTH
  `define CPU_ISSUE_WIDTH 1
`endif
`ifndef CPU_ROB_DEPTH
  `define CPU_ROB_DEPTH 32
`endif
`ifndef CPU_PRF_SIZE
  `define CPU_PRF_SIZE 64
`endif
`ifndef CPU_RS_DEPTH
  `define CPU_RS_DEPTH 8
`endif
`ifndef CPU_CDB_NUM
  `define CPU_CDB_NUM 1
`endif
`ifndef CPU_LSQ_DEPTH
  `define CPU_LSQ_DEPTH 8
`endif

// ---- Cache 参数（行数 = 2^index_bits）---------------------------------------
`ifndef CPU_ICACHE_INDEX_BITS
  `define CPU_ICACHE_INDEX_BITS 10
`endif
`ifndef CPU_ICACHE_WAYS
  `define CPU_ICACHE_WAYS 1
`endif
`ifndef CPU_ICACHE_LINE_BYTES
  `define CPU_ICACHE_LINE_BYTES 4
`endif
`ifndef CPU_DCACHE_INDEX_BITS
  `define CPU_DCACHE_INDEX_BITS 10
`endif
`ifndef CPU_DCACHE_WAYS
  `define CPU_DCACHE_WAYS 1
`endif
`ifndef CPU_DCACHE_LINE_BYTES
  `define CPU_DCACHE_LINE_BYTES 4
`endif

// ---- 分支预测参数（BTB / BHT 项数 = 2^index_bits）---------------------------
`ifndef CPU_BTB_INDEX_BITS
  `define CPU_BTB_INDEX_BITS 6
`endif
`ifndef CPU_BHT_INDEX_BITS
  `define CPU_BHT_INDEX_BITS 8
`endif

// ---- 派生位宽（由上面的参数推导，保持一致）----------------------------------
`ifndef CPU_ROB_TAG_W
  `define CPU_ROB_TAG_W $clog2(`CPU_ROB_DEPTH)
`endif
`ifndef CPU_PRF_IDX_W
  `define CPU_PRF_IDX_W $clog2(`CPU_PRF_SIZE)
`endif
`ifndef CPU_RS_IDX_W
  `define CPU_RS_IDX_W $clog2(`CPU_RS_DEPTH)
`endif
`ifndef CPU_LSQ_IDX_W
  `define CPU_LSQ_IDX_W $clog2(`CPU_LSQ_DEPTH)
`endif
