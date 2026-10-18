#!/bin/sh
# Full backend smoke test: W=1 and W=2 dispatch absorption.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)

run_one() {
    w=$1
    python3 "$root/tools/unit/build.py" \
        --top backend_ooo \
        --tb "$here/backend_tb.cpp" \
        --sources "$root/verilog/rv32_defs.sv" "$root/verilog/cpu_config.sv" \
                  "$root/verilog/if_defs.sv" "$root/verilog/alu.sv" \
                  "$root/verilog/divider.sv" "$root/verilog/prf.sv" \
                  "$root/verilog/cdb.sv" "$root/verilog/issue_queue.sv" \
                  "$root/verilog/lsq.sv" "$root/verilog/lsu.sv" \
                  "$root/verilog/backend_ooo.sv" \
        --define "CPU_ISSUE_WIDTH=$w" \
        --cxx-define "TB_W=$w"
}

run_one 1
run_one 2
