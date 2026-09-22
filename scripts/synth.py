#!/usr/bin/env python3
"""Report optimized or hierarchical ASIC area and frequency with Yosys/OpenSTA."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess

from build import read_sources
from fakeram import MODEL, RAM_SOURCE, prepare_memories
from toolchain import DEFAULT_APPIMAGE, enter_appimage, executable, packaged_tool
from synth_report import area_report, format_report
from timing import analyze


def quote(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'


def run_yosys(yosys, out, name, commands):
    script = out / f"{name}.ys"
    script.write_text("\n".join(commands) + "\n")
    subprocess.run([yosys, "-Q", "-T", "-q", "-l", str(out / f"{name}.log"),
                    "-s", str(script)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--filelist", type=Path, default=Path("verilog/filelist.f"))
    parser.add_argument("--out", type=Path, default=Path("build/synth"),
                        help="output root; results go in its opt/ or diagnose/ subdirectory")
    parser.add_argument("--mode", choices=("opt", "diagnose"), default="opt")
    parser.add_argument("--clock-period", type=float, default=2.0, help="target clock period in ns (default: 2)")
    parser.add_argument("--clock-port", default="clock", help="top-level clock input (default: clock)")
    parser.add_argument("--blackboxes", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--appimage", default=str(DEFAULT_APPIMAGE))
    parser.add_argument("--yosys", help="custom Yosys executable")
    parser.add_argument("--abc", help="custom ABC executable")
    parser.add_argument("--sta", help="custom OpenSTA executable")
    parser.add_argument("--asap7-lib", type=Path, help="directory containing the five ASAP7 libraries")
    args = parser.parse_args()
    out = args.out.resolve() / args.mode
    out.mkdir(parents=True, exist_ok=True)
    for name in ("area.json", "report.json", "report.txt", "timing.json", "timing_values.json",
                 "critical_paths.json", "timing.rpt", "timing_checks.rpt", "clock_checks.rpt", "constraints.sdc"):
        (out / name).unlink(missing_ok=True)
    if not math.isfinite(args.clock_period) or args.clock_period <= 0:
        parser.error("--clock-period must be a finite positive number in ns")
    (out / "blackboxes.v").unlink(missing_ok=True)
    if args.blackboxes:
        parser.error("--blackboxes has been removed; instantiate sram_fakeram for library-backed SRAM")
    legacy = args.filelist.resolve().parent / "blackboxes.txt"
    if legacy.is_file() and any(line.split("#", 1)[0].strip() for line in legacy.read_text().splitlines()):
        parser.error(f"{legacy}: zero-area blackbox exclusions are no longer supported; "
                     "migrate SRAMs to sram_fakeram and remove this list")
    try:
        sources = read_sources(args.filelist)
        if not (args.yosys and args.asap7_lib and args.sta):
            enter_appimage(args.appimage)
        yosys = executable(args.yosys) if args.yosys else (packaged_tool("yosys") or executable("yosys"))
        abc = executable(args.abc) if args.abc else packaged_tool("yosys-abc")
        if not abc and os.environ.get("CPU2026_ABC"):
            abc = executable(os.environ["CPU2026_ABC"])
        try:
            sta = executable(args.sta) if args.sta else (packaged_tool("sta") or executable("sta"))
        except ValueError as error:
            raise ValueError("OpenSTA is required for synthesis: configure STA=/path/to/sta "
                             "or use a course AppImage containing OpenSTA") from error
    except (ValueError, OSError) as error:
        parser.error(str(error))
    library_dir = args.asap7_lib or Path(os.environ.get("CPU2026_ASAP7_LIB", "/opt/asap7/lib"))
    libs = sorted(library_dir.expanduser().resolve().glob("*.lib"))
    if len(libs) != 5:
        parser.error("five ASAP7 RVT TT libraries required; configure APPIMAGE or ASAP7_LIB")
    # Elaborate the framework's empty SRAM interface as a normal module so
    # Yosys resolves parameter expressions, defaults, hierarchy and generates.
    # No RAM array is lowered to flops in this stage.
    run_yosys(yosys, out, "elaborate", [
        *["read_verilog -sv -D SYNTHESIS " + quote(path) for path in sources if path != RAM_SOURCE],
        "read_verilog -sv -noblackbox -D SYNTHESIS " + quote(RAM_SOURCE),
        "hierarchy -top student_top",
        "proc",
        "memory_collect",
        "write_json " + quote(out / "elaborated.json"),
    ])
    try:
        elaborated = json.loads((out / "elaborated.json").read_text())
        clock = elaborated["modules"]["student_top"].get("ports", {}).get(args.clock_port, {})
        if clock.get("direction") != "input" or len(clock.get("bits", [])) != 1:
            raise ValueError(f"student_top must have a one-bit clock input named {args.clock_port}")
        prepared, wrappers, ram_libs, macros = prepare_memories(elaborated, out / "ram")
    except ValueError as error:
        parser.error(str(error))
    library_args = " ".join("-liberty " + quote(lib) for lib in libs)
    all_library_args = " ".join("-liberty " + quote(lib) for lib in [*libs, *ram_libs])
    library_reads = ["read_liberty -lib -ignore_miss_func " + quote(lib) for lib in [*libs, *ram_libs]]
    seq = next(lib for lib in libs if "_SEQ_" in lib.name)
    script = [
        "read_json " + quote(prepared),
        "read_verilog " + quote(wrappers),
        *library_reads,
        "hierarchy -check -top student_top",
        "synth -top student_top -noabc " + ("-flatten" if args.mode == "opt" else "-hieropt"),
        "check -assert",
        "select -assert-none a:init t:$dlatch* t:$_DLATCH*",
        "dfflibmap -liberty " + quote(seq),
        "abc " + ("-exe " + quote(abc) + " " if abc else "") + library_args + f" -D {args.clock_period * 1000:.9g}",
        "clean",
        "delete t:$scopeinfo",
        "clean -purge",
        "hilomap -hicell TIEHIx1_ASAP7_75t_R H -locell TIELOx1_ASAP7_75t_R L",
        "check -assert -mapped",
        f"tee -o {quote(out / 'stat.json')} stat -json {all_library_args}",
        "write_json " + quote(out / "design.json"),
        "write_verilog -noattr -noexpr " + quote(out / "mapped.v"),
        "design -reset",
        *library_reads,
        "read_verilog " + quote(out / "mapped.v"),
        "hierarchy -check -top student_top",
        "check -assert -mapped",
    ]
    run_yosys(yosys, out, "synth", script)
    try:
        area = area_report(json.loads((out / "design.json").read_text()),
                           json.loads((out / "stat.json").read_text()), macros)
        timing = analyze(sta, out, [*libs, *ram_libs], args.clock_period, args.clock_port)
    except (ValueError, OSError) as error:
        parser.error(str(error))
    def identities(paths):
        return [{"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()} for path in paths]
    report = {"schema_version": 1, "mode": args.mode, "output_directory": str(out),
              "area": area, "timing": timing,
              "inputs": identities([*sources, RAM_SOURCE]), "libraries": identities([*libs, *ram_libs]),
              "sram_model": MODEL,
              "tools": {"yosys": subprocess.check_output([yosys, "-V"], text=True).strip(),
                        "opensta": subprocess.check_output([sta, "-version"], text=True).strip()}}
    for name, data in (("report.json", report), ("timing.json", timing),
                       ("area.json", {"mode": args.mode, **area, "sram_model": MODEL, "timing_analyzed": True})):
        (out / name).write_text(json.dumps(data, indent=2, allow_nan=False) + "\n")
    (out / "report.txt").write_text(format_report(report, full=True))
    print(format_report(report), end="")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.returncode)
