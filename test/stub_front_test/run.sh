#!/bin/sh
# Scripted frontend stub test: W=1 and W=2 groups.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)

run_one() {
    w=$1
    python3 "$root/tools/unit/build.py" \
        --top stub_front_ooo \
        --tb "$here/stub_front_tb.cpp" \
        --sources "$root/verilog/rv32_defs.sv" "$root/verilog/cpu_config.sv" \
                  "$root/verilog/if_defs.sv" "$root/verilog/stub_front_ooo.sv" \
        --define "CPU_ISSUE_WIDTH=$w" \
        --cxx-define "TB_W=$w"
}

run_one 1
run_one 2
