#!/bin/sh
# -----------------------------------------------------------------------------
# run.sh — core_ooo 薄封装的编译 / lint / Yosys 结构检查
#
# 不跑程序（真实后端尚未接入）；用于保证 P1 逐边替换时 core_ooo 的
# 端口、参数和模块连接始终可编译、可综合。
# -----------------------------------------------------------------------------
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)

if [ -z "${CPU2026_APPDIR:-}" ]; then
    if [ -z "${VERILATOR:-}" ] && command -v verilator >/dev/null 2>&1; then
        VERILATOR=$(command -v verilator)
    fi
    if [ -z "${YOSYS:-}" ] && command -v yosys >/dev/null 2>&1; then
        YOSYS=$(command -v yosys)
    fi
    if [ -z "${VERILATOR:-}" ] || [ -z "${YOSYS:-}" ]; then
        image="$root/cpu2026-tools-x86_64.AppImage"
        if [ -x "$image" ]; then
            exec env APPIMAGE_EXTRACT_AND_RUN=1 "$image" exec sh "$0" "$@"
        fi
    fi
fi

if [ -z "${VERILATOR:-}" ] && [ -n "${CPU2026_APPDIR:-}" ]; then
    VERILATOR="$CPU2026_APPDIR/bin/verilator"
fi
if [ -z "${YOSYS:-}" ] && [ -n "${CPU2026_APPDIR:-}" ]; then
    YOSYS="$CPU2026_APPDIR/bin/yosys"
fi
if [ ! -x "$VERILATOR" ] || [ ! -x "$YOSYS" ]; then
    echo "error: need verilator and yosys (AppImage or PATH)" >&2
    exit 2
fi

srcs="
$root/verilog/cpu_config.sv
$root/verilog/if_defs.sv
$root/verilog/rv32_defs.sv
$root/verilog/pc_unit.sv
$root/verilog/icache_pipe.sv
$root/verilog/decoder.sv
$root/verilog/bpu.sv
$root/verilog/rename.sv
$root/verilog/commit.sv
$root/verilog/rob.sv
$root/verilog/frontend_ooo.sv
$root/verilog/core_ooo.sv
$root/scripts/ram/sram_fakeram.sv
"

echo "== Verilator lint: core_ooo =="
"$VERILATOR" --lint-only --top-module core_ooo -Wall -Wno-fatal \
    -DCPU_ISSUE_WIDTH=1 $srcs

echo "== Yosys check: core_ooo =="
srcs_one=$(printf '%s ' $srcs)
mkdir -p "$here/build"
yosys_log="$here/build/yosys.log"
if ! "$YOSYS" -Q -p "read_verilog -sv -DSYNTHESIS $srcs_one; hierarchy -top core_ooo; proc; opt; check" \
        >"$yosys_log" 2>&1; then
    tail -30 "$yosys_log"
    echo "core_skeleton: YOSYS FAIL" >&2
    exit 1
fi
tail -8 "$yosys_log"

echo "core_skeleton: PASS"