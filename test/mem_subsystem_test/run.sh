#!/bin/sh
# mem_subsystem v1 unit test.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)

exec python3 "$root/tools/unit/build.py" \
    --top mem_subsystem \
    --tb "$here/mem_subsystem_tb.cpp" \
    --sources "$root/verilog/axi_mem_if.sv" "$root/verilog/mem_subsystem.sv" \
    "$@"
