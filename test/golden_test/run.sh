#!/bin/sh
# Golden-model + trace-diff smoke test.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
out="$root/build/golden_test"

rm -rf "$out"
mkdir -p "$out"

cases="correctness_add_to_100 correctness_expr correctness_gcd correctness_naive correctness_manyarguments"
for case in $cases; do
    image="$root/testcases/$case/program.data"
    expected="$root/testcases/$case/expected.txt"
    [ -f "$image" ] && [ -f "$expected" ] || {
        echo "skip $case (testcases submodule missing)" >&2
        continue
    }
    python3 "$root/tools/golden/riscv_golden.py" "$image" \
        --expected "$expected" --trace "$out/$case.trace" --quiet
    python3 "$root/tools/trace_diff.py" "$out/$case.trace" "$out/$case.trace" >/dev/null
    echo "$case PASS"
done

# Negative test: one changed PC must be reported as a mismatch.
python3 "$root/tools/golden/riscv_golden.py" \
    "$root/testcases/correctness_add_to_100/program.data" \
    --trace "$out/base.trace" --quiet
awk 'NR == 1 { $1 = "00000004" } { print }' "$out/base.trace" > "$out/bad.trace"
if python3 "$root/tools/trace_diff.py" "$out/base.trace" "$out/bad.trace" >/dev/null 2>&1; then
    echo "FAIL: trace_diff accepted a changed PC" >&2
    exit 1
fi
echo "negative trace_diff PASS"
