# Golden RV32IM model

`riscv_golden.py` is a dependency-free sequential RV32IM interpreter for the
course `program.data` format.  It is the reference used by `trace_diff.py` and
by backend debugging.

## Quick use

```sh
python3 tools/golden/riscv_golden.py \
    testcases/correctness_add_to_100/program.data \
    --expected testcases/correctness_add_to_100/expected.txt \
    --trace build/golden.trace
```

The exit protocol is the course one: a word store to `0x8000_0000`; the stored
value is the program result.

## Commit trace

Each retired instruction emits:

```text
pc rd value
```

- `pc` — 8-digit lowercase hex;
- `rd` — decimal destination register, `0` when the instruction does not write
  a register;
- `value` — writeback value for register writes, store data for stores,
  resolved target for taken branches/jumps, otherwise `0`.

This matches the intended RTL `ifdef LOCAL_TRACE` output.  `tools/trace_diff.py`
compares two traces line by line and reports the first mismatches.

## Notes

- Memory is sparse, so stack/data addresses up to the course layout work
  without allocating a giant array.
- RV32IM only; `FENCE`/`FENCE.I` are no-ops, `SYSTEM` is illegal.
- Signed division truncates toward zero, matching RISC-V; divide-by-zero and
  `INT_MIN / -1` follow the M-extension rules.
