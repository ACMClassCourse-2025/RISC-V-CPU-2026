#!/bin/sh
# -----------------------------------------------------------------------------
# run.sh — 编译并运行 if_defs.sv 的宽度/偏移校验
#
#   sh test/if_defs_test/run.sh
#
# 环境变量（会同时覆盖 SV 宏与 C++ 期望值）：
#   IF_TEST_W / IF_TEST_PRF / IF_TEST_CDB / IF_TEST_ROB / IF_TEST_LSQ
#   VERILATOR
# -----------------------------------------------------------------------------
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
w=${IF_TEST_W:-1}
prf=${IF_TEST_PRF:-64}
cdb=${IF_TEST_CDB:-1}
rob=${IF_TEST_ROB:-32}
lsq=${IF_TEST_LSQ:-8}

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
mkdir -p "$out"

"$VERILATOR" --cc --exe --build --assert -Wall -Wno-fatal \
    --top-module if_defs_check -Mdir "$out" \
    -DCPU_ISSUE_WIDTH="$w" -DCPU_PRF_SIZE="$prf" -DCPU_CDB_NUM="$cdb" \
    -DCPU_ROB_DEPTH="$rob" -DCPU_LSQ_DEPTH="$lsq" \
    "$root/verilog/cpu_config.sv" "$root/verilog/if_defs.sv" \
    "$here/if_defs_check.sv" "$here/if_defs_tb.cpp" \
    -CFLAGS "-std=c++17 -DTB_W=$w -DTB_PRF=$prf -DTB_CDB=$cdb -DTB_ROB=$rob -DTB_LSQ=$lsq" \
    -o "$out/tb"

exec "$out/tb" "$@"
