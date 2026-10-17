#!/bin/sh
# -----------------------------------------------------------------------------
# run.sh — 编译并运行 ROB + commit 的 Verilator 单元测试
#
#   sh test/rob_test/run.sh [--quick] [--seed N] [--cycles N]
#
# 环境变量：
#   VERILATOR   指定 verilator
#   ROB_W       发射宽度（默认 1；可设 2）
# -----------------------------------------------------------------------------
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
w=${ROB_W:-1}

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
marker="$out/.rob_w"
if [ ! -f "$marker" ] || [ "$(cat "$marker" 2>/dev/null || true)" != "$w" ]; then
    rm -rf "$out"
fi
mkdir -p "$out"
printf '%s\n' "$w" > "$marker"

"$VERILATOR" --cc --exe --build --assert -Wall -Wno-fatal \
    --top-module rob -Mdir "$out" \
    -DCPU_ISSUE_WIDTH="$w" \
    "$root/verilog/cpu_config.sv" "$root/verilog/if_defs.sv" \
    "$root/verilog/commit.sv" "$root/verilog/rob.sv" "$here/rob_tb.cpp" \
    -CFLAGS "-std=c++17 -DTB_W=$w" -o "$out/tb"

exec "$out/tb" "$@"
