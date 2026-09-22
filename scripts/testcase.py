#!/usr/bin/env python3
"""Run testcases using the same stdin/stdout protocol and answers as ACMOJ."""
import argparse
import json
import math
import re
import subprocess
import sys
from pathlib import Path

from oj_io import prepare_case, compare_output

CYCLES = re.compile(r"^CPU2026 cycles=(\d+)$", re.MULTILINE)


def cases_of(root, kind, case):
    if case:
        return [root / case]
    return sorted(path for path in root.glob(f"{kind}_*") if path.is_dir())


def execute(build, case, max_cycles, latency, simulator=None):
    data, answer = prepare_case(case, max_cycles, latency)
    run = subprocess.run([str((simulator or build / "sim").expanduser().resolve())], input=data,
                         text=True, capture_output=True)
    if run.returncode:
        raise ValueError(f"simulator exited with status {run.returncode}: {run.stderr.strip()}")
    error = compare_output(run.stdout, answer)
    if error:
        raise ValueError(error)
    return run


def correctness(build, cases, max_cycles, latency, simulator=None):
    passed = failed = 0
    for case in cases:
        print(f"\n[{case.name}]")
        try:
            run = execute(build, case, max_cycles, latency, simulator)
        except (OSError, ValueError) as error:
            print(f"FAIL: {error}", file=sys.stderr)
            failed += 1
        else:
            match = CYCLES.search(run.stderr)
            print("PASS" + (f" cycles={match.group(1)}" if match else ""))
            passed += 1
    print(f"\nResults: {passed} passed, {failed} failed")
    return 1 if failed else 0


def performance(build, cases, max_cycles, latency, simulator=None):
    scores = []
    print(f"{'benchmark':<24} {'instructions':>14} {'cycles':>12} {'IPC':>10}")
    for case in cases:
        try:
            instructions = json.loads((case / "metrics.json").read_text())["dynamic_instructions"]
        except (OSError, json.JSONDecodeError, KeyError) as error:
            raise SystemExit(f"{case.name}: {error}")
        try:
            run = execute(build, case, max_cycles, latency, simulator)
        except (OSError, ValueError) as error:
            raise SystemExit(f"{case.name}: {error}")
        match = CYCLES.search(run.stderr)
        if not match:
            raise SystemExit(f"{case.name}: missing cycle report on stderr: {run.stderr!r}")
        cycles = int(match.group(1))
        ipc = instructions / cycles
        scores.append(ipc)
        print(f"{case.name:<24} {instructions:>14} {cycles:>12} {ipc:>10.4f}")
    geomean = math.exp(sum(map(math.log, scores)) / len(scores)) if scores else 0.0
    print(f"{'GEOMEAN':<24} {'':>14} {'':>12} {geomean:>10.4f}")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, default=Path("build"))
    parser.add_argument("--testcases", type=Path,
                        default=(Path(__file__).resolve().parent / "testcases"
                                 if (Path(__file__).resolve().parent / "testcases").is_dir()
                                 else Path(__file__).resolve().parents[1] / "testcases"))
    parser.add_argument("--kind", choices=("correctness", "perf"), default="correctness")
    parser.add_argument("--case")
    parser.add_argument("--max-cycles", type=int, default=1_000_000)
    parser.add_argument("--latency", type=int, default=10)
    parser.add_argument("--sim", type=Path, help="prebuilt simulator executable")
    args = parser.parse_args()
    cases = cases_of(args.testcases, args.kind, args.case)
    if not cases:
        parser.error(f"no {args.kind}_* testcases in {args.testcases}")
    if not all(case.is_dir() for case in cases):
        parser.error(f"testcase does not exist: {cases[0]}")
    if args.kind == "perf":
        return performance(args.build, cases, args.max_cycles, args.latency, args.sim)
    return correctness(args.build, cases, args.max_cycles, args.latency, args.sim)


if __name__ == "__main__":
    raise SystemExit(main())
