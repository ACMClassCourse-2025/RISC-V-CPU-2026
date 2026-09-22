"""Run OpenSTA with the course's shared clock and interface constraints."""
import json
from pathlib import Path
import re
import subprocess


def tcl_word(value):
    """A literal Tcl word, including paths containing $, brackets or braces."""
    escaped = str(value)
    for char in '\\"$[]{}':
        escaped = escaped.replace(char, '\\' + char)
    return '"' + escaped.replace('\n', '\\n').replace('\r', '\\r') + '"'


def analyze(sta, out, libs, period, clock_port):
    script = out / "timing.tcl"
    constraints = {
        "clock_port": clock_port, "clock_period_ns": period,
        "input_delay_ns": 0.2, "output_delay_ns": 0.2,
        "input_transition_ns": 0.05, "clock_transition_ns": 0.05,
        "clock_uncertainty_ns": 0.05, "output_load_ff": 5.0,
        "reset_value": 0, "clock_model": "ideal", "interconnect": "no_parasitics",
        "frequency_resolution_ns": 0.001,
    }
    commands = [f"set report_dir {tcl_word(out)}",
                f"set clock_port {tcl_word(clock_port)}",
                f"set clock_period {period:.12g}",
                *[f"read_liberty {tcl_word(lib)}" for lib in libs],
                "set_cmd_units -time ns -capacitance fF",
                f"read_verilog {tcl_word(out / 'mapped.v')}",
                "link_design student_top",
                f"source {tcl_word(Path(__file__).with_suffix('.tcl'))}"]
    # OpenSTA can otherwise exit successfully after Tcl errors. Propagate them.
    script.write_text("if {[catch {\n" + "\n".join(commands) +
                      '\n} message]} {\n  puts stderr "Timing analysis failed: $message"\n  exit 1\n}\nexit 0\n')
    log = out / "timing.log"
    with log.open("w") as stream:
        # OpenSTA evaluates its command-line script path as Tcl. A fixed relative
        # filename avoids substitution in project paths containing [] or $.
        result = subprocess.run([sta, "-no_init", "-exit", script.name], cwd=out,
                                stdout=stream, stderr=subprocess.STDOUT)
    text = log.read_text()
    if result.returncode or re.search(r"(?m)^Error(?: \d+)?:", text):
        raise ValueError(f"OpenSTA failed; see {log}\n" + "\n".join(text.splitlines()[-12:]))
    values = json.loads((out / "timing_values.json").read_text())
    checks = json.loads((out / "critical_paths.json").read_text()).get("checks", [])
    # OpenSTA's JSON uses SI seconds, independently of the display units.
    paths = [{"startpoint": c["startpoint"], "endpoint": c["endpoint"],
              "slack_ns": c["slack"] * 1e9,
              "arrival_ns": c["data_arrival_time"] * 1e9,
              "required_ns": c["required_time"] * 1e9,
              "points": [{"pin": p["pin"], "cell": p.get("cell"),
                          "arrival_ns": p["arrival"] * 1e9}
                         for p in c.get("source_path", [])]}
             for c in checks]
    return {**constraints, **values, "critical_paths": sorted(paths, key=lambda p: p["slack_ns"]),
            "timing_analyzed": True}
