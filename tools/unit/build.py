#!/usr/bin/env python3
"""Compile and optionally run a Verilator unit test.

This is the backend-side counterpart of ``test/divider_test/run.sh``.  It is
deliberately independent of ``verilog/filelist.f``: unit tests pass an explicit
source list, so stubs and testbenches can never leak into the OJ build.

Examples
--------
    python3 tools/unit/build.py \
        --top divider \
        --tb test/divider_test/divider_tb.cpp \
        --sources verilog/divider.sv

    python3 tools/unit/build.py --top prf --tb test/prf_test/prf_tb.cpp \
        --sources verilog/rv32_defs.sv verilog/cpu_config.sv verilog/if_defs.sv \
                  verilog/prf.sv -- --quick

The default output directory is ``build/unit/<top>``.  The script uses the
course AppImage when Verilator is not on PATH, and accepts ``--appimage`` /
``--verilator`` overrides just like ``make build``.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from toolchain import DEFAULT_APPIMAGE, enter_appimage, executable, packaged_tool  # noqa: E402


def resolve_sources(entries: list[str]) -> list[Path]:
    sources: list[Path] = []
    for entry in entries:
        path = Path(entry).expanduser().resolve()
        if not path.is_file():
            raise ValueError(f"source does not exist: {entry}")
        if path.suffix not in (".v", ".sv"):
            raise ValueError(f"source is not a Verilog file: {entry}")
        if path in sources:
            raise ValueError(f"duplicate source: {entry}")
        sources.append(path)
    if not sources:
        raise ValueError("no RTL sources given (use --sources)")
    return sources


def find_verilator(override: str | None) -> str:
    if override:
        return executable(override)
    packaged = packaged_tool("verilator")
    if packaged:
        return packaged
    installed = shutil.which("verilator")
    if installed:
        return installed
    raise ValueError(
        "Verilator not found: put it on PATH, pass --verilator, or use the "
        "course AppImage (--appimage / default repo path)"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--top", required=True, help="top module name")
    parser.add_argument("--tb", required=True, type=Path, help="C++ testbench")
    parser.add_argument("--sources", nargs="+", required=True,
                        help="explicit RTL source list (test-only; never filelist.f)")
    parser.add_argument("--out", type=Path, default=None,
                        help="output directory (default: build/unit/<top>)")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--appimage", default=str(DEFAULT_APPIMAGE),
                        help="course AppImage providing Verilator")
    parser.add_argument("--verilator", help="explicit Verilator executable")
    parser.add_argument("--define", "-D", action="append", default=[],
                        help="Verilog macro override, e.g. -DCPU_ISSUE_WIDTH=2")
    parser.add_argument("--include", "-I", action="append", default=[],
                        help="additional include directory")
    parser.add_argument("--no-run", action="store_true", help="compile only")
    parser.add_argument("--keep", action="store_true",
                        help="keep the Verilator object directory before build")
    parser.add_argument("--trace", action="store_true", help="enable VCD tracing")
    parser.add_argument("rest", nargs=argparse.REMAINDER,
                        help="arguments after '--' are passed to the test binary")
    args = parser.parse_args()

    if args.jobs < 1:
        parser.error("--jobs must be positive")

    # Re-enter the course AppImage when no native Verilator is requested.  This
    # is the same mechanism as scripts/build.py; CPU2026_APPDIR then lets
    # packaged_tool() find the bundled Verilator.
    if not args.verilator:
        enter_appimage(args.appimage)

    try:
        sources = resolve_sources(args.sources)
        tb = args.tb.expanduser().resolve()
        if not tb.is_file():
            raise ValueError(f"testbench does not exist: {args.tb}")
        verilator = find_verilator(args.verilator)
    except (ValueError, OSError) as error:
        parser.error(str(error))

    out = (args.out or (ROOT / "build" / "unit" / args.top)).expanduser().resolve()
    objects = out / "obj"
    if objects.exists() and not args.keep:
        shutil.rmtree(objects)
    out.mkdir(parents=True, exist_ok=True)
    binary = out / "tb"
    binary.unlink(missing_ok=True)

    command = [
        verilator,
        "--cc", "--exe", "--build", "--assert",
        "-Wall", "-Wno-fatal",
        "--top-module", args.top,
        "--Mdir", str(objects),
        "-o", str(binary),
        "-j", str(args.jobs),
        "-CFLAGS", "-std=c++17",
    ]
    if args.trace:
        command.append("--trace")
    for define in args.define:
        command.append(f"-D{define}")
    for include in args.include:
        command.append(f"-I{Path(include).expanduser().resolve()}")
    command.extend(str(path) for path in sources)
    command.append(str(tb))

    environment = os.environ.copy()
    environment.setdefault("MAKE", shutil.which("make") or "make")
    subprocess.run(command, check=True, env=environment)

    if args.no_run:
        print(binary)
        return 0

    run_args = list(args.rest)
    if run_args and run_args[0] == "--":
        run_args = run_args[1:]
    return subprocess.call([str(binary), *run_args])


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.returncode)
