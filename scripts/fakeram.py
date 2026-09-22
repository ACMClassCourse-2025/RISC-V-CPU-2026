"""Local SRAM library generator using FakeRAM2.0's ASAP7 cost assumptions.

The formula and timing reference is documented in docs/sram.md. The upstream
generator is not bundled or executed.
No network access, Chisel metadata, physical compiler, or third-party Python
packages are needed. All names and numeric values emitted here are generated
from validated integer parameters, never from student-supplied strings.
"""
from dataclasses import dataclass
import json
from pathlib import Path

RAM_SOURCE = Path(__file__).resolve().with_name("ram") / "sram_fakeram.sv"
MODEL = {
    "name": "fakeram-asap7-v1",
    # Formula/timing provenance, not a bundled software dependency.
    "upstream": "ABKGroup/FakeRAM2.0",
    "commit": "49dad15badc28a55363813e105c830c7776fc588",
    "estimated": True,
    "area_per_bit_um2": 0.0419904,
    "clock_to_q_formula_ns": "0.071262 + 0.0000167155 * depth + 0.001243254 * width",
    "setup_ns": 0.050,
    "hold_ns": 0.050,
    "min_period_ns": 0.157,
}


def with_ram_source(sources):
    return [RAM_SOURCE, *[path for path in sources if path != RAM_SOURCE]]


def ram_error(where, message):
    return ValueError(f"RAM library error at {where}: {message}. See docs/sram.md")


def integer_parameter(parameters, name, where):
    value = parameters[name]
    if not isinstance(value, str) or not value or set(value) - {"0", "1"}:
        raise ram_error(where, f"{name} must be a known integer")
    # Public parameters are signed Verilog integers.
    number = int(value, 2)
    if len(value) == 32 and value[0] == "1":
        number -= 1 << 32
    return number


@dataclass(frozen=True, order=True)
class Shape:
    depth: int
    width: int
    granularity: int

    def validate(self, where):
        if not 1 <= self.depth <= 1048576:
            raise ram_error(where, f"DEPTH={self.depth} is unsupported; use 1..1048576")
        if not 1 <= self.width <= 4096:
            raise ram_error(where, f"WIDTH={self.width} is unsupported; use 1..4096")
        if self.depth * self.width > 16777216:
            raise ram_error(where, "capacity exceeds the supported 16777216 bits per RAM")
        if not 1 <= self.granularity <= self.width:
            raise ram_error(where, "WRITE_GRANULARITY must be 1..WIDTH")
        if self.width % self.granularity:
            raise ram_error(where, f"WIDTH={self.width} must be divisible by "
                            f"WRITE_GRANULARITY={self.granularity}")

    @property
    def address_width(self):
        return max(1, (self.depth - 1).bit_length())

    @property
    def lanes(self):
        return self.width // self.granularity

    @property
    def wrapper(self):
        return f"sram_fakeram_{self.depth}x{self.width}_m{self.granularity}"

    @property
    def macro(self):
        return f"fakeram_asap7_{self.depth}x{self.granularity}"

    @property
    def lane_area(self):
        return round(self.depth * self.granularity * MODEL["area_per_bit_um2"], 6)

    @property
    def clock_to_q_ns(self):
        # Fit to official asap7_sram_0p0 (9f5af093), at 20 ps slew / 23.04 fF.
        # Each write-mask lane is a separate macro; use its raw width.
        return 0.071262 + 0.0000167155 * self.depth + 0.001243254 * self.granularity

    def verilog(self):
        lines = [
            f"module {self.wrapper} (",
            "    input clk, en, we,",
            f"    input [{self.lanes - 1}:0] wmask,",
            f"    input [{self.address_width - 1}:0] addr,",
            f"    input [{self.width - 1}:0] wdata,",
            f"    output [{self.width - 1}:0] rdata);",
        ]
        for lane in range(self.lanes):
            lo, hi = lane * self.granularity, (lane + 1) * self.granularity - 1
            lines += [
                f"    {self.macro} lane_{lane} (",
                f"        .clk(clk), .ce_in(en & (~we | wmask[{lane}])), .we_in(we),",
                f"        .addr_in(addr), .wd_in(wdata[{hi}:{lo}]), .rd_out(rdata[{hi}:{lo}]));",
            ]
        return "\n".join([*lines, "endmodule", ""])


def liberty(shape):
    """Emit fitted output delay; interface timing remains an estimate."""
    def constraints():
        return "\n".join(f'''
        timing() {{
            related_pin : "clk";
            timing_type : {kind}_rising;
            rise_constraint(scalar) {{ values("{MODEL[kind + '_ns']:.3f}"); }}
            fall_constraint(scalar) {{ values("{MODEL[kind + '_ns']:.3f}"); }}
        }}''' for kind in ("setup", "hold"))

    def bus_type(name, width):
        return f'''
    type({name}) {{
        base_type : array;
        data_type : bit;
        bit_width : {width};
        bit_from : {width - 1};
        bit_to : 0;
        downto : true;
    }}'''

    inputs = []
    for name in ("ce_in", "we_in", "addr_in", "wd_in"):
        bus = name in ("addr_in", "wd_in")
        bus_attr = f"bus_type : {'ADDRESS' if name == 'addr_in' else 'DATA'};" if bus else ""
        inputs.append(f'''
        {'bus' if bus else 'pin'}({name}) {{
            {bus_attr}
            direction : input;
            capacitance : 0.005;
            {constraints()}
        }}''')
    return f'''/* {MODEL['name']}: estimated area and fitted output delay, no power model. */
library({shape.macro}) {{
    technology(cmos);
    delay_model : table_lookup;
    time_unit : "1ns";
    voltage_unit : "1V";
    current_unit : "1mA";
    capacitive_load_unit(1,pf);
    nom_process : 1;
    nom_temperature : 25;
    nom_voltage : 0.7;
    input_threshold_pct_rise : 50;
    input_threshold_pct_fall : 50;
    output_threshold_pct_rise : 50;
    output_threshold_pct_fall : 50;
    slew_lower_threshold_pct_rise : 20;
    slew_lower_threshold_pct_fall : 20;
    slew_upper_threshold_pct_rise : 80;
    slew_upper_threshold_pct_fall : 80;
    {bus_type('ADDRESS', shape.address_width)}
    {bus_type('DATA', shape.granularity)}
    cell({shape.macro}) {{
        area : {shape.lane_area:.6f};
        interface_timing : true;
        dont_use : true;
        memory() {{ type : ram; address_width : {shape.address_width}; word_width : {shape.granularity}; }}
        pin(clk) {{
            direction : input;
            clock : true;
            capacitance : 0.025;
            min_period : {MODEL['min_period_ns']:.3f};
        }}
        {''.join(inputs)}
        bus(rd_out) {{
            bus_type : DATA;
            direction : output;
            max_capacitance : 0.5;
            memory_read() {{ address : addr_in; }}
            timing() {{
                related_pin : "clk";
                timing_type : rising_edge;
                timing_sense : non_unate;
                cell_rise(scalar) {{ values("{shape.clock_to_q_ns:.6f}"); }}
                cell_fall(scalar) {{ values("{shape.clock_to_q_ns:.6f}"); }}
                rise_transition(scalar) {{ values("0.050"); }}
                fall_transition(scalar) {{ values("0.050"); }}
            }}
        }}
    }}
}}
'''


def prepare_memories(design, out):
    """Replace elaborated sram_fakeram specializations with concrete wrappers."""
    modules = design["modules"]
    replacements, shapes = {}, set()
    for name, module in modules.items():
        if name == "sram_fakeram" or module.get("attributes", {}).get("hdlname") == "sram_fakeram":
            params = module["parameter_default_values"]
            shape = Shape(*(integer_parameter(params, key, name)
                            for key in ("DEPTH", "WIDTH", "WRITE_GRANULARITY")))
            replacements[name] = shape

    for module_name, module in modules.items():
        for instance, cell in module.get("cells", {}).items():
            kind = cell["type"]
            where = f"{module_name}.{instance} ({cell.get('attributes', {}).get('src', 'unknown source')})"
            if kind in replacements:
                shape = replacements[kind]
                shape.validate(where)
                for port in ("clk", "en", "we", "wmask", "addr", "wdata"):
                    if not cell.get("connections", {}).get(port):
                        raise ram_error(where, f"required input {port} is not connected")
                if shape.wrapper in modules or shape.macro in modules:
                    raise ram_error(where, "generated RAM module names are reserved by the framework")
                cell["type"] = shape.wrapper
                cell["parameters"] = {}
                shapes.add(shape)
            elif kind.startswith("sram_fakeram") or kind.startswith("fakeram_asap7_"):
                raise ram_error(where, f"unsupported RAM module {kind}; instantiate sram_fakeram")
            elif not kind.startswith("$"):
                target = modules.get(kind)
                if target is None or target.get("attributes", {}).get("blackbox", "0").endswith("1"):
                    raise ram_error(where, f"unsupported external module {kind}; "
                                    "only sram_fakeram has a RAM library implementation")
    for name in replacements:
        del modules[name]

    out.mkdir(parents=True, exist_ok=True)
    prepared = out / "prepared.json"
    prepared.write_text(json.dumps(design) + "\n")
    wrappers = out / "wrappers.v"
    wrappers.write_text("// Generated SRAM wrappers; do not edit.\n" +
                        "\n".join(shape.verilog() for shape in sorted(shapes)))
    macros = {}
    for shape in sorted(shapes):
        macros[shape.macro] = {"depth": shape.depth, "width": shape.granularity,
                               "area_um2": shape.lane_area}
        (out / f"{shape.macro}.lib").write_text(liberty(shape))
    (out / "manifest.json").write_text(json.dumps({
        "model": MODEL,
        "configurations": [{"module": s.wrapper, "depth": s.depth, "width": s.width,
                            "write_granularity": s.granularity, "lanes": s.lanes,
                            "macro": s.macro} for s in sorted(shapes)],
        "macros": macros,
    }, indent=2) + "\n")
    return prepared, wrappers, [out / f"{name}.lib" for name in sorted(macros)], macros
