#!/bin/sh
# -----------------------------------------------------------------------------
# run.sh — frontend_ooo + rename + rob + stub_exec 子系统测试
#
#   sh test/frontend_test/run.sh [--quick] [--seed N]
#
# 环境变量：VERILATOR、FRONTEND_W（默认 1）
# -----------------------------------------------------------------------------
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
w=${FRONTEND_W:-1}

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
marker="$out/.front_w"
if [ ! -f "$marker" ] || [ "$(cat "$marker" 2>/dev/null || true)" != "$w" ]; then
    rm -rf "$out"
fi
mkdir -p "$out"
printf '%s\n' "$w" > "$marker"

"$VERILATOR" --cc --exe --build --assert -Wall -Wno-fatal \
    --top-module frontend_subsystem -Mdir "$out" \
    -DCPU_ISSUE_WIDTH="$w" \
    "$root/verilog/cpu_config.sv" "$root/verilog/if_defs.sv" \
    "$root/verilog/rv32_defs.sv" "$root/verilog/pc_unit.sv" \
    "$root/verilog/icache_pipe.sv" "$root/verilog/decoder.sv" \
    "$root/verilog/bpu.sv" "$root/verilog/rename.sv" \
    "$root/verilog/commit.sv" "$root/verilog/rob.sv" \
    "$root/verilog/frontend_ooo.sv" "$root/verilog/stub_exec.sv" \
    "$root/scripts/ram/sram_fakeram.sv" \
    "$here/frontend_subsystem.sv" "$here/frontend_tb.cpp" \
    -CFLAGS "-std=c++17 -DTB_W=$w" -o "$out/tb"

exec "$out/tb" "$@"
