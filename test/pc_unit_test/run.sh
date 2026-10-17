#!/bin/sh
# -----------------------------------------------------------------------------
# run.sh — 编译并运行 pc_unit 的 Verilator 单元测试
#
#   sh test/pc_unit_test/run.sh [--quick] [--seed N] [--cycles N]
#
# 环境变量：
#   VERILATOR   指定 verilator 可执行文件
#               （默认顺序：$VERILATOR > AppImage 环境 > PATH > 仓库根目录的
#                 AppImage 自动重入）
# -----------------------------------------------------------------------------
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)

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
mkdir -p "$out"

"$VERILATOR" --cc --exe --build --assert -Wall -Wno-fatal \
    --top-module pc_unit -Mdir "$out" \
    "$root/verilog/pc_unit.sv" "$here/pc_unit_tb.cpp" \
    -CFLAGS -std=c++17 -o "$out/tb"

exec "$out/tb" "$@"
