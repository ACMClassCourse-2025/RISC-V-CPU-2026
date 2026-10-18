#!/bin/sh
# P1 integration smoke: build the OOO top from the test-only filelist and run
# one course testcase.  The official verilog/filelist.f is not touched.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
case_name=${1:-correctness_add_to_100}
max_cycles=${2:-200000}

make -C "$root" build FILELIST="$here/filelist.f" BUILD="$root/build/ooo" JOBS=4
python3 "$root/scripts/testcase.py" \
    --build "$root/build/ooo" \
    --case "$case_name" \
    --max-cycles "$max_cycles" \
    --latency 10
