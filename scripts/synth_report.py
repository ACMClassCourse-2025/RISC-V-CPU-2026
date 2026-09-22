"""Area accounting and student-facing synthesis reports."""
import math


def area_report(design, statistics, macros):
    """Count leaf cells once per instance, keeping direct and inclusive area."""
    modules = design["modules"]
    stats = statistics["modules"]
    instances = []

    def visit(kind, path, ancestors):
        if kind in ancestors:
            raise ValueError(f"recursive module hierarchy at {path}")
        module = modules[kind]
        logic = sram = 0.0
        children = []
        for name, cell in sorted(module.get("cells", {}).items()):
            child_kind = cell["type"]
            child_path = f"{path}/{name}"
            child = modules.get(child_kind, {})
            attrs = child.get("attributes", {})
            if child_kind in macros and "area" in attrs:
                sram += float(attrs["area"])
                instances.append({"instance": child_path, "module": child_kind,
                                  **macros[child_kind]})
            elif child_kind.endswith("_ASAP7_75t_R") and "area" in attrs:
                logic += float(attrs["area"])
            elif child and not int(attrs.get("blackbox", "0"), 2):
                children.append(visit(child_kind, child_path, ancestors | {kind}))
            else:
                raise ValueError(f"unmapped or undeclared black-box cell {child_path}: {child_kind}")
        # Yosys 0.63's JSON area fields include descendants even without -hierarchy.
        module_stats = stats.get(kind, stats.get("\\" + kind))
        if module_stats is None:
            raise ValueError(f"missing Yosys area statistics for {path}")
        sequential = float(module_stats["sequential_area"]) - sum(c["sequential_area_um2"] for c in children)
        if not -1e-6 <= sequential <= logic + 1e-6:
            raise ValueError(f"inconsistent sequential area for {path}")
        sequential = max(0.0, sequential)
        direct = {"logic_area_um2": logic, "sequential_area_um2": sequential,
                  "combinational_area_um2": max(0.0, logic - sequential),
                  "sram_area_um2": sram, "area_um2": logic + sram}
        total = {key: value + sum(c[key] for c in children) for key, value in direct.items()}
        return {"instance": path, "module": kind,
                "source_module": module.get("attributes", {}).get("hdlname", kind),
                "direct_area_um2": direct["area_um2"], "direct": direct,
                **total, "children": sorted(children, key=lambda c: (-c["area_um2"], c["instance"]))}

    tree = visit("student_top", "student_top", set())
    # The leaf sum is independent of Yosys's recursive aggregate; require agreement.
    expected = statistics.get("design", {}).get("area")
    if expected is not None and not math.isclose(tree["area_um2"], expected, rel_tol=1e-6, abs_tol=1e-5):
        raise ValueError(f"area accounting mismatch: {tree['area_um2']} vs Yosys {expected}")

    def percentages(node):
        node["percent_of_total"] = 100 * node["area_um2"] / tree["area_um2"] if tree["area_um2"] else 0.0
        for child in node["children"]:
            percentages(child)
    percentages(tree)
    return {key: tree[key] for key in tree["direct"]} | {
        "module_tree": tree, "sram_instances": instances}


def module_rows(tree, max_depth=None, depth=0):
    label = tree["instance"].rsplit("/", 1)[-1]
    yield ("  " * depth + label, tree)
    if max_depth is None or depth < max_depth:
        for child in tree["children"]:
            yield from module_rows(child, max_depth, depth + 1)


def format_report(report, *, full=False):
    area, timing = report["area"], report["timing"]
    description = "hierarchy preserved" if report["mode"] == "diagnose" else "flattened and optimized"
    lines = [f"Synthesis mode: {report['mode']} ({description})", "",
             f"Total area:           {area['area_um2']:,.3f} um^2",
             f"  Combinational:      {area['combinational_area_um2']:,.3f} um^2",
             f"  Sequential:         {area['sequential_area_um2']:,.3f} um^2",
             f"  SRAM:               {area['sram_area_um2']:,.3f} um^2", ""]
    frequency = timing["estimated_fmax_mhz"]
    if frequency is None:
        lines.append("Estimated frequency:  N/A (no active timing paths)")
    else:
        lines += [f"Estimated frequency:  {frequency:,.2f} MHz",
                  f"Minimum period:       {timing['minimum_period_ns']:.4f} ns"]
    lines.append(f"Clock target:         {timing['clock_period_ns']:.3f} ns")
    if timing["worst_setup_slack_ns"] is not None:
        lines.append(f"Worst setup slack:    {timing['worst_setup_slack_ns']:+.4f} ns")
    if report["mode"] == "diagnose":
        rows = list(module_rows(area["module_tree"], None if full else 2))
        heading = "Module area (including children)"
        width = max(len(heading), *(len(label) for label, _ in rows))
        lines += ["", f"{heading:<{width}}  {'Area (um^2)':>13}  {'% total':>8}  {'Direct (um^2)':>13}"]
        for label, node in rows:
            lines.append(f"{label:<{width}}  {node['area_um2']:13,.3f}  "
                         f"{node['percent_of_total']:7.2f}%  {node['direct_area_um2']:13,.3f}")
        lines += ["Direct area excludes children; parent and child totals overlap.",
                  "This breakdown describes the diagnose netlist; opt may produce different area and timing."]
        if not full:
            lines.append("Console shows up to two levels below the top; full hierarchy in report.txt and report.json.")
    if timing["critical_paths"]:
        worst = timing["critical_paths"][0]
        lines += ["", "Critical path:", f"  {worst['startpoint']}", f"    -> {worst['endpoint']}"]
    lines += ["", f"Reports: {report['output_directory']}/report.txt, report.json, timing.rpt"]
    return "\n".join(lines) + "\n"
