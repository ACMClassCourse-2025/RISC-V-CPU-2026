#!/usr/bin/env python3
"""按命令行参数生成 verilog/cpu_config.sv。

用法示例：
    tools/config_gen.py                                   # 生成默认配置
    tools/config_gen.py --issue-width 2 --rob 64 --prf 96 --rs 16
    tools/config_gen.py --stdout                          # 打印不写文件
    tools/config_gen.py --check                           # 校验当前文件与参数一致

约定：换参数 = 重新生成 + 重编译，不允许手改 RTL 里的参数。
生成的每个宏都有 `ifndef 保护，也可用 -DCPU_ISSUE_WIDTH=2 等继续覆盖。
"""
import argparse
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUT = ROOT / "verilog" / "cpu_config.sv"

# 默认值（bring-up 配置）。改这里之前先和队友对齐 division.md §0.3。
DEFAULTS = {
    "issue_width": 1,
    "rob": 32,
    "prf": 64,
    "rs": 8,
    "cdb_num": 1,
    "lsq": 8,
    "icache_index_bits": 10,
    "icache_ways": 1,
    "icache_line_bytes": 4,
    "dcache_index_bits": 10,
    "dcache_ways": 1,
    "dcache_line_bytes": 4,
    "btb_index_bits": 6,
    "bht_index_bits": 8,
}


def is_power_of_two(value):
    return value > 0 and (value & (value - 1)) == 0


def validate(args):
    errors = []
    if not 1 <= args.issue_width <= 4:
        errors.append("--issue-width must be 1..4")
    if not 1 <= args.cdb_num <= 4:
        errors.append("--cdb-num must be 1..4")
    # PRF 允许非 2 的幂（验收档位含 96）；索引位宽由 $clog2 推导，
    # 实现侧只需保证分配的物理寄存器号 < CPU_PRF_SIZE。
    if not 4 <= args.prf <= 4096:
        errors.append("--prf must be 4..4096 (any integer, e.g. 64/96/128)")
    for name, lo, hi in (("rob", 4, 4096), ("rs", 4, 4096), ("lsq", 4, 64)):
        value = getattr(args, name)
        if not (lo <= value <= hi) or not is_power_of_two(value):
            errors.append(f"--{name} must be a power of two in {lo}..{hi}")
    for name in ("icache_index_bits", "dcache_index_bits"):
        if not 2 <= getattr(args, name) <= 16:
            errors.append(f"--{name.replace('_', '-')} must be 2..16")
    for name in ("btb_index_bits", "bht_index_bits"):
        if not 2 <= getattr(args, name) <= 16:
            errors.append(f"--{name.replace('_', '-')} must be 2..16")
    for name in ("icache_ways", "dcache_ways"):
        if getattr(args, name) not in (1, 2, 4):
            errors.append(f"--{name.replace('_', '-')} must be 1, 2 or 4")
    for name in ("icache_line_bytes", "dcache_line_bytes"):
        if getattr(args, name) not in (4, 8, 16, 32, 64):
            errors.append(f"--{name.replace('_', '-')} must be 4..64 (power of two)")
    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)


def render(args):
    cmd = " ".join(
        [
            "tools/config_gen.py",
            f"--issue-width {args.issue_width}",
            f"--rob {args.rob}",
            f"--prf {args.prf}",
            f"--rs {args.rs}",
            f"--cdb-num {args.cdb_num}",
            f"--lsq {args.lsq}",
            f"--icache-index-bits {args.icache_index_bits}",
            f"--icache-ways {args.icache_ways}",
            f"--icache-line-bytes {args.icache_line_bytes}",
            f"--dcache-index-bits {args.dcache_index_bits}",
            f"--dcache-ways {args.dcache_ways}",
            f"--dcache-line-bytes {args.dcache_line_bytes}",
            f"--btb-index-bits {args.btb_index_bits}",
            f"--bht-index-bits {args.bht_index_bits}",
        ]
    )
    return f"""// -----------------------------------------------------------------------------
// cpu_config.sv — 全局参数配置（由 tools/config_gen.py 生成，请勿手改）
//
// 生成命令：
//   {cmd}
//
// 换参数 = 重新生成 + 重编译，不改任何 RTL。每个宏都有 `ifndef 保护，
// 因此也可以用 Verilator/Yosys 的 -D 选项临时覆盖单个参数。
// 参数含义与验收档位见 docs/plan/division.md §0.3。
// -----------------------------------------------------------------------------

// ---- 核心微架构参数 ---------------------------------------------------------
`ifndef CPU_ISSUE_WIDTH
  `define CPU_ISSUE_WIDTH {args.issue_width}
`endif
`ifndef CPU_ROB_DEPTH
  `define CPU_ROB_DEPTH {args.rob}
`endif
`ifndef CPU_PRF_SIZE
  `define CPU_PRF_SIZE {args.prf}
`endif
`ifndef CPU_RS_DEPTH
  `define CPU_RS_DEPTH {args.rs}
`endif
`ifndef CPU_CDB_NUM
  `define CPU_CDB_NUM {args.cdb_num}
`endif
`ifndef CPU_LSQ_DEPTH
  `define CPU_LSQ_DEPTH {args.lsq}
`endif

// ---- Cache 参数（行数 = 2^index_bits）---------------------------------------
`ifndef CPU_ICACHE_INDEX_BITS
  `define CPU_ICACHE_INDEX_BITS {args.icache_index_bits}
`endif
`ifndef CPU_ICACHE_WAYS
  `define CPU_ICACHE_WAYS {args.icache_ways}
`endif
`ifndef CPU_ICACHE_LINE_BYTES
  `define CPU_ICACHE_LINE_BYTES {args.icache_line_bytes}
`endif
`ifndef CPU_DCACHE_INDEX_BITS
  `define CPU_DCACHE_INDEX_BITS {args.dcache_index_bits}
`endif
`ifndef CPU_DCACHE_WAYS
  `define CPU_DCACHE_WAYS {args.dcache_ways}
`endif
`ifndef CPU_DCACHE_LINE_BYTES
  `define CPU_DCACHE_LINE_BYTES {args.dcache_line_bytes}
`endif

// ---- 分支预测参数（BTB / BHT 项数 = 2^index_bits）---------------------------
`ifndef CPU_BTB_INDEX_BITS
  `define CPU_BTB_INDEX_BITS {args.btb_index_bits}
`endif
`ifndef CPU_BHT_INDEX_BITS
  `define CPU_BHT_INDEX_BITS {args.bht_index_bits}
`endif

// ---- 派生位宽（由上面的参数推导，保持一致）----------------------------------
`ifndef CPU_ROB_TAG_W
  `define CPU_ROB_TAG_W $clog2(CPU_ROB_DEPTH)
`endif
`ifndef CPU_PRF_IDX_W
  `define CPU_PRF_IDX_W $clog2(CPU_PRF_SIZE)
`endif
`ifndef CPU_RS_IDX_W
  `define CPU_RS_IDX_W $clog2(CPU_RS_DEPTH)
`endif
`ifndef CPU_LSQ_IDX_W
  `define CPU_LSQ_IDX_W $clog2(CPU_LSQ_DEPTH)
`endif
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--issue-width", type=int, default=DEFAULTS["issue_width"])
    parser.add_argument("--rob", type=int, default=DEFAULTS["rob"])
    parser.add_argument("--prf", type=int, default=DEFAULTS["prf"])
    parser.add_argument("--rs", type=int, default=DEFAULTS["rs"])
    parser.add_argument("--cdb-num", type=int, default=DEFAULTS["cdb_num"])
    parser.add_argument("--lsq", type=int, default=DEFAULTS["lsq"])
    parser.add_argument("--icache-index-bits", type=int, default=DEFAULTS["icache_index_bits"])
    parser.add_argument("--icache-ways", type=int, default=DEFAULTS["icache_ways"])
    parser.add_argument("--icache-line-bytes", type=int, default=DEFAULTS["icache_line_bytes"])
    parser.add_argument("--dcache-index-bits", type=int, default=DEFAULTS["dcache_index_bits"])
    parser.add_argument("--dcache-ways", type=int, default=DEFAULTS["dcache_ways"])
    parser.add_argument("--dcache-line-bytes", type=int, default=DEFAULTS["dcache_line_bytes"])
    parser.add_argument("--btb-index-bits", type=int, default=DEFAULTS["btb_index_bits"])
    parser.add_argument("--bht-index-bits", type=int, default=DEFAULTS["bht_index_bits"])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT,
                        help=f"output file (default: {DEFAULT_OUT})")
    parser.add_argument("--stdout", action="store_true", help="print instead of writing")
    parser.add_argument("--check", action="store_true",
                        help="exit 1 if the output file differs from the rendered config")
    args = parser.parse_args()

    validate(args)
    text = render(args)
    out = args.out.expanduser().resolve()

    if args.stdout:
        sys.stdout.write(text)
        return 0

    if args.check:
        current = out.read_text() if out.is_file() else ""
        if current == text:
            print(f"cpu_config: {out} is up to date")
            return 0
        print(f"cpu_config: {out} is STALE; rerun tools/config_gen.py", file=sys.stderr)
        return 1

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text)
    print(f"cpu_config: wrote {out}")
    print(f"  issue_width={args.issue_width} rob={args.rob} prf={args.prf} "
          f"rs={args.rs} cdb={args.cdb_num} lsq={args.lsq}")
    print(f"  icache={args.icache_index_bits}b/{args.icache_ways}w/{args.icache_line_bytes}B "
          f"dcache={args.dcache_index_bits}b/{args.dcache_ways}w/{args.dcache_line_bytes}B "
          f"btb={args.btb_index_bits}b bht={args.bht_index_bits}b")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
