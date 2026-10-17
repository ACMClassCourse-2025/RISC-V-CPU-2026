#!/bin/sh
# -----------------------------------------------------------------------------
# run.sh — 编译并运行 bpu 的 Verilator 单元测试
#
#   sh test/bpu_test/run.sh [--quick] [--seed N] [--cycles N]
#
# 环境变量：
#   VERILATOR           指定 verilator 可执行文件
#   BPU_BTB_INDEX_BITS  BTB 索引位宽（默认 6，即 64 项）
#   BPU_BHT_INDEX_BITS  BHT 索引位宽（默认 8，即 256 项）
# -----------------------------------------------------------------------------
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
btb=${BPU_BTB_INDEX_BITS:-6}
bht=${BPU_BHT_INDEX_BITS:-8}

if [ -z "${VERILATOR:-}" ] && [ -n "${CPU2026_APPDIR:-}" ] && [ -x "$CPU2026_APPDIR/bin/verilator" ]; then
    VERILATOR="$CPU2026_APPDIR/bin/verilator"
fi
if [ -z "${VERILATOR:-}" ] && command -v verilator >/dev/null 2>&1; then
    VERILATOR=$(command -v verilator)
fi
if [ -z "${VERILATOR:-}" ]; then
    image="$root/cpu2026-tools-x86_64.AppImage"
    if [ -x "$image" ]; then
        exec env APPIMAGE_EXTRACT_AND_RUN=1 "$image" exec sh "$0" "$@"
    fi
    echo "error: verilator not found ($VERILATOR)" >&2
    echo "hint: export VERILATOR=/path/to/verilator $0 $*" >&2
    exit 2
fi

out="$here/build"
marker="$out/.bpu_bits"
want="$btb/$bht"
if [ ! -f "$marker" ] || [ "$(cat "$marker" 2>/dev/null || true)" != "$want" ]; then
    rm -rf "$out"
fi
mkdir -p "$out"
printf '%s\n' "$want" > "$marker"

"$VERILATOR" --cc --exe --build --assert -Wall -Wno-fatal \
    --top-module bpu -Mdir "$out" \
    -GBTB_INDEX_BITS="$btb" -GBHT_INDEX_BITS="$bht" \
    "$root/verilog/cpu_config.sv" "$root/verilog/bpu.sv" "$here/bpu_tb.cpp" \
    -CFLAGS "-std=c++17 -DTB_BTB_INDEX_BITS=$btb -DTB_BHT_INDEX_BITS=$bht" \
    -o "$out/tb"

exec "$out/tb" "$@"
