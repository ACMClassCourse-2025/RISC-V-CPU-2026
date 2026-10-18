#!/bin/sh
# LSU + LSQ v1 integration test (W=1).
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)

exec python3 "$root/tools/unit/build.py" \
    --top lsu \
    --tb "$here/lsu_tb.cpp" \
    --sources "$root/verilog/rv32_defs.sv" "$root/verilog/cpu_config.sv" \
              "$root/verilog/if_defs.sv" "$root/verilog/lsq.sv" \
              "$root/verilog/lsu.sv" \
    "$@"
