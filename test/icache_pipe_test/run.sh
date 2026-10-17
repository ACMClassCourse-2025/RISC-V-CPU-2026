#!/bin/sh
# -----------------------------------------------------------------------------
# run.sh — 编译并运行 icache_pipe 的 Verilator 单元测试
#
#   sh test/icache_pipe_test/run.sh [--quick] [--seed N] [--cycles N]
#
# 环境变量：
#   VERILATOR        指定 verilator
#   ICACHE_INDEX_BITS 测试用索引位宽（默认 4，即 16 行，便于覆盖别名）
# -----------------------------------------------------------------------------
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
index_bits=${ICACHE_INDEX_BITS:-4}

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
    exit 2
fi

out="$here/build"
marker="$out/.index_bits"
if [ ! -f "$marker" ] || [ "$(cat "$marker" 2>/dev/null || true)" != "$index_bits" ]; then
    rm -rf "$out"
fi
mkdir -p "$out"
printf '%s\n' "$index_bits" > "$marker"

"$VERILATOR" --cc --exe --build --assert -Wall -Wno-fatal \
    --top-module icache_pipe -Mdir "$out" \
    -GINDEX_BITS="$index_bits" \
    "$root/verilog/cpu_config.sv" "$root/verilog/icache_pipe.sv" \
    "$root/scripts/ram/sram_fakeram.sv" "$here/icache_pipe_tb.cpp" \
    -CFLAGS "-std=c++17 -DTB_INDEX_BITS=$index_bits" \
    -o "$out/tb"

exec "$out/tb" "$@"
