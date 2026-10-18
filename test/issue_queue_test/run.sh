#!/bin/sh
# Issue-queue behavior test: W=1 and W=2 dispatch, IW=1 issue.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)

run_one() {
    w=$1
    r=$2
    python3 "$root/tools/unit/build.py" \
        --top issue_queue \
        --tb "$here/issue_queue_tb.cpp" \
        --sources "$root/verilog/rv32_defs.sv" "$root/verilog/cpu_config.sv" \
                  "$root/verilog/if_defs.sv" "$root/verilog/issue_queue.sv" \
        --define "CPU_ISSUE_WIDTH=$w" --define "CPU_CDB_NUM=$r" \
        --cxx-define "TB_W=$w" --cxx-define "TB_R=$r"
}

run_one 1 1
run_one 2 1
