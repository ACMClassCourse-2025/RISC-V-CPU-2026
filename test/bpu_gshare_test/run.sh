#!/bin/sh
# -----------------------------------------------------------------------------
# run.sh — bpu_gshare 的 Verilator 单元测试
#
#   sh test/bpu_gshare_test/run.sh [--quick] [--seed N] [--cycles N]
#
# 环境变量：BTB_BITS / BHT_BITS / GHIST_BITS
# -----------------------------------------------------------------------------
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
btb=${BTB_BITS:-6}
bht=${BHT_BITS:-8}
gh=${GHIST_BITS:-8}

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
marker="$out/.bpu_gshare"
want="$btb/$bht/$gh"
if [ ! -f "$marker" ] || [ "$(cat "$marker" 2>/dev/null || true)" != "$want" ]; then
    rm -rf "$out"
fi
mkdir -p "$out"
printf '%s\n' "$want" > "$marker"

"$VERILATOR" --cc --exe --build --assert -Wall -Wno-fatal \
    --top-module bpu_gshare -Mdir "$out" \
    -GBTB_INDEX_BITS="$btb" -GBHT_INDEX_BITS="$bht" -GGHIST_BITS="$gh" \
    "$root/verilog/cpu_config.sv" "$root/verilog/bpu_gshare.sv" "$here/bpu_gshare_tb.cpp" \
    -CFLAGS "-std=c++17 -DTB_BTB_BITS=$btb -DTB_BHT_BITS=$bht -DTB_GHIST_BITS=$gh" \
    -o "$out/tb"

exec "$out/tb" "$@"