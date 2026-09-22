#!/usr/bin/env python3
"""Run a program and compare the result written through AXI4-Lite."""
import argparse
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("--expected", required=True, type=lambda value: int(value, 0))
    parser.add_argument("--build", type=Path, default=Path("build"))
    parser.add_argument("--max-cycles", type=int, default=1000000)
    parser.add_argument("--latency", type=int, default=10)
    parser.add_argument("--wave", type=Path)
    parser.add_argument("--log", type=Path, help="file to save simulation output log")
    parser.add_argument("--sim", type=Path, help="prebuilt simulator executable")
    args = parser.parse_args()
    if not 0 <= args.expected <= 0xffffffff:
        parser.error("--expected must be a 32-bit unsigned value")
    if not 1 <= args.max_cycles < 2**63 or not 1 <= args.latency <= 1000000:
        parser.error("--max-cycles must be 1..2^63-1; --latency must be 1..1000000")
    command = [str((args.sim or args.build / "sim").expanduser().resolve()), str(args.image.resolve()),
               str(args.expected), str(args.max_cycles), str(args.latency)]
    if args.wave:
        args.wave.parent.mkdir(parents=True, exist_ok=True)
        command.append(str(args.wave.resolve()))
    if args.log:
        args.log.parent.mkdir(parents=True, exist_ok=True)
        with args.log.open("w", encoding="utf-8", errors="replace") as log_file:
            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                errors="replace",
            )
            for line in process.stdout:
                sys.stdout.write(line)
                sys.stdout.flush()
                log_file.write(line)
                log_file.flush()
            process.wait()
            raise SystemExit(process.returncode)
    raise SystemExit(subprocess.call(command))


if __name__ == "__main__":
    main()
