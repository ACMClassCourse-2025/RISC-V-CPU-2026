# Loaded after Liberty/netlist linking; all command times are in ns, loads in fF.
set clock_input [get_ports $clock_port]
if {[llength $clock_input] != 1} { error "Expected one clock input named $clock_port" }

proc apply_clock {period} {
    global clock_input
    create_clock -name core_clock -period $period $clock_input
    set_clock_transition 0.05 [get_clocks core_clock]
    set_clock_uncertainty 0.05 [get_clocks core_clock]
}
apply_clock $clock_period
set data_inputs {}
foreach port [all_inputs] {
    if {[get_full_name $port] ne $clock_port} { lappend data_inputs $port }
}
if {[llength $data_inputs]} {
    set_input_delay -max 0.2 -clock core_clock $data_inputs
    set_input_delay -min 0.0 -clock core_clock $data_inputs
    set_input_transition 0.05 $data_inputs
}
if {[llength [all_outputs]]} {
    set_output_delay -max 0.2 -clock core_clock [all_outputs]
    set_output_delay -min 0.0 -clock core_clock [all_outputs]
    set_load 5.0 [all_outputs]
}
set reset [get_ports -quiet reset]
if {[llength $reset]} { set_case_analysis 0 $reset }
write_sdc $report_dir/constraints.sdc

if {![check_setup -verbose > $report_dir/timing_checks.rpt]} {
    error "Incomplete timing constraints or combinational loops; see $report_dir/timing_checks.rpt"
}

proc worst_setup {} {
    set paths [find_timing_paths -path_delay max -sort_by_slack -group_path_count 1]
    if {![llength $paths]} { return "" }
    return [get_property [lindex $paths 0] slack]
}

# Clock pulse-width and minimum-period checks are also frequency constraints.
proc clock_checks_pass {} {
    global report_dir
    report_check_types -min_pulse_width -min_period -violators -max_count 1 \
        > $report_dir/clock_checks.rpt
    set f [open $report_dir/clock_checks.rpt r]
    set result [read $f]
    close $f
    return [expr {![string match "*VIOLATED*" $result]}]
}

proc period_passes {period} {
    apply_clock $period
    set slack [worst_setup]
    return [expr {($slack eq "" || $slack >= 0) && [clock_checks_pass]}]
}

set target_slack [worst_setup]
set minimum_period null
set frequency null
if {$target_slack ne ""} {
    # Searching the clock period also handles paths between opposite clock edges.
    # Interface budgets and uncertainty stay fixed throughout the search.
    set lo 0.0
    set hi $clock_period
    for {set i 0} {![period_passes $hi]} {incr i} {
        if {$i >= 20} { error "Timing did not converge to a feasible clock period" }
        set hi [expr {$hi * 2}]
    }
    while {$hi - $lo > 0.001} {
        set mid [expr {($lo + $hi) / 2}]
        if {[period_passes $mid]} { set hi $mid } else { set lo $mid }
    }
    set minimum_period $hi
    set frequency [expr {1000.0 / $hi}]
}

# All published paths and slack describe the requested target, not a search step.
apply_clock $clock_period
report_checks -path_delay max -sort_by_slack -group_path_count 5 \
    -format full_clock_expanded -fields {slew capacitance fanout input_pins} -digits 4 \
    > $report_dir/timing.rpt
report_checks -path_delay max -sort_by_slack -group_path_count 5 -format json \
    > $report_dir/critical_paths.json
report_check_types -min_pulse_width -min_period -digits 4 > $report_dir/clock_checks.rpt
if {$target_slack eq ""} { set target_slack null }
set f [open $report_dir/timing_values.json w]
puts $f "{\"minimum_period_ns\": $minimum_period, \"estimated_fmax_mhz\": $frequency, \"worst_setup_slack_ns\": $target_slack}"
close $f
