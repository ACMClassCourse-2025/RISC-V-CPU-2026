#!/usr/bin/env python3
"""Compare two commit traces in ``pc rd value`` format.

The golden model (``tools/golden/riscv_golden.py``) and the RTL
``ifdef LOCAL_TRACE`` output use the same three fields:

    pc      8-digit hex
    rd      decimal register index (0 when there is no writeback)
    value   8-digit hex writeback / store / target value

Usage:
    python3 tools/trace_diff.py golden.trace rtl.trace
    python3 tools/trace_diff.py golden.trace rtl.trace --pc-only
    python3 tools/trace_diff.py golden.trace rtl.trace --limit 5
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import sys


@dataclass
class Entry:
    line: int
    pc: int
    rd: int
    value: int
    text: str


def load(path: Path) -> list[Entry]:
    entries: list[Entry] = []
    for line_no, raw in enumerate(path.read_text().splitlines(), start=1):
        text = raw.split("#", 1)[0].split("//", 1)[0].strip()
        if not text:
            continue
        parts = text.split()
        if len(parts) < 3:
            raise ValueError(f"{path}:{line_no}: expected 'pc rd value', got {raw!r}")
        try:
            pc = int(parts[0], 16)
            rd = int(parts[1], 10)
            value = int(parts[2], 16)
        except ValueError as error:
            raise ValueError(f"{path}:{line_no}: invalid trace entry: {raw!r}") from error
        entries.append(Entry(line_no, pc, rd, value, text))
    return entries


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("golden", type=Path, help="golden trace")
    parser.add_argument("rtl", type=Path, help="RTL trace")
    parser.add_argument("--pc-only", action="store_true",
                        help="compare only the PC field")
    parser.add_argument("--ignore-rd", action="store_true",
                        help="ignore the rd field")
    parser.add_argument("--ignore-value", action="store_true",
                        help="ignore the value field")
    parser.add_argument("--limit", type=int, default=20,
                        help="maximum mismatches to print (default: 20)")
    parser.add_argument("--allow-prefix", action="store_true",
                        help="allow the RTL trace to stop before the golden trace")
    args = parser.parse_args()

    try:
        golden = load(args.golden)
        rtl = load(args.rtl)
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    common = min(len(golden), len(rtl))
    mismatches = 0
    shown = 0

    def mismatch(index: int, why: str) -> None:
        nonlocal mismatches, shown
        mismatches += 1
        if shown < args.limit:
            g = golden[index] if index < len(golden) else None
            r = rtl[index] if index < len(rtl) else None
            print(f"MISMATCH #{mismatches} at entry {index}: {why}")
            if g:
                print(f"  golden line {g.line}: {g.text}")
            if r:
                print(f"  rtl    line {r.line}: {r.text}")
            shown += 1

    for i in range(common):
        g, r = golden[i], rtl[i]
        if g.pc != r.pc:
            mismatch(i, f"pc 0x{g.pc:08x} != 0x{r.pc:08x}")
        elif not args.pc_only and not args.ignore_rd and g.rd != r.rd:
            mismatch(i, f"rd {g.rd} != {r.rd}")
        elif not args.pc_only and not args.ignore_value and g.value != r.value:
            mismatch(i, f"value 0x{g.value:08x} != 0x{r.value:08x}")

    if len(golden) != len(rtl):
        if args.allow_prefix and len(rtl) <= len(golden):
            pass
        else:
            shorter = "golden" if len(golden) < len(rtl) else "RTL"
            extra = max(len(golden), len(rtl)) - common
            mismatches += 1
            if shown < args.limit:
                print(f"MISMATCH: {shorter} trace is shorter; {extra} extra entries")

    if mismatches:
        print(f"\nFAIL: {mismatches} mismatch(es), compared {common} entries "
              f"(golden={len(golden)}, rtl={len(rtl)})")
        return 1

    print(f"PASS: {common} entries match (golden={len(golden)}, rtl={len(rtl)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
