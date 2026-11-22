# Vivado out-of-context synthesis + implementation for SysMAC.
#
# UNTESTED in this repository so far: written from AMD's documented flow
# (UG905, UG903, UG835). The first person to run it should commit the
# reports and fix anything Vivado complains about.
#
# Run from the repository root, with Vivado 2025.2 (the last release that
# needs no licence file):
#   vivado -mode batch -nojournal -nolog -source synthesis/vivado/ooc.tcl
#   vivado -mode batch -nojournal -nolog -source synthesis/vivado/ooc.tcl -tclargs 10.0
#   vivado -mode batch -nojournal -nolog -source synthesis/vivado/ooc.tcl -tclargs 10.0 xc7a100tcsg324-1 seq_matmul
#
# Arguments (optional): clock period in ns (default 8.0), part (default
# xc7a35tcpg236-1, the Basys 3 chip), then the top modules (default: both).
# Writes synthesis/vivado/<top>/*.rpt, fmax.txt and synthesis/vivado/summary.txt.
#
# Why out-of-context: the top has 436 port bits; an xc7a35t has 106 user I/O
# in cpg236 and 210 in csg324, so a normal pinned implementation cannot be
# placed. Out-of-context mode inserts no I/O buffers and measures the core
# alone. Port-to-register paths are not timed (see the unconstrained section
# of timing.rpt); register-to-register paths, which include the PE
# multiply-add, are.

# Paths are taken from this script's location, so Vivado may be started
# from any directory.
set here [file normalize [file dirname [info script]]]
set root [file normalize [file join $here .. ..]]

# Arguments (all optional): period in ns, part, then one or more top modules.
# With no tops given, both designs are run in one Vivado session.
set period [expr {[llength $argv] > 0 ? [lindex $argv 0] : 8.0}]
set part   [expr {[llength $argv] > 1 ? [lindex $argv 1] : "xc7a35tcpg236-1"}]
set tops   [expr {[llength $argv] > 2 ? [lrange $argv 2 end] : {systolic_accelerator_top seq_matmul}}]

set files_for(systolic_accelerator_top) {
    systolic_controller.v input_buffer.v input_scheduler.v
    processing_element.v systolic_array.v output_registers.v
    systolic_accelerator_top.v
}
set files_for(seq_matmul) {seq_matmul.v}

set summary [list [format "%-26s %7s %7s %5s %10s %10s" design LUT FF DSP "WNS (ns)" "Fmax (MHz)"]]

foreach top $tops {
    catch {close_design}
    set out [file join $here $top]
    file mkdir $out

    # Clock constraint, written fresh for this period.
    set xdc [file join $out ooc.xdc]
    set fh [open $xdc w]
    puts $fh "create_clock -name clk -period $period \[get_ports clk\]"
    close $fh

    foreach f $files_for($top) { read_verilog [file join $root rtl $f] }
    read_xdc -mode out_of_context $xdc

    synth_design -top $top -part $part -mode out_of_context
    report_utilization -file [file join $out utilization_synth.rpt]

    opt_design
    place_design
    phys_opt_design
    route_design

    report_utilization               -file [file join $out utilization.rpt]
    report_utilization -hierarchical -file [file join $out utilization_hier.rpt]
    report_timing_summary -report_unconstrained -max_paths 10 -file [file join $out timing.rpt]
    report_power                     -file [file join $out power.rpt]
    report_drc                       -file [file join $out drc.rpt]

    # Fmax from the worst register-to-register setup slack: Fmax = 1 / (T - WNS).
    set path [get_timing_paths -setup -max_paths 1 -nworst 1]
    set wns  [get_property SLACK $path]
    set fmax [expr {1000.0 / ($period - $wns)}]
    set lut  [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]]
    set ff   [llength [get_cells -hier -filter {PRIMITIVE_GROUP == REGISTER}]]
    set dsp  [llength [get_cells -hier -filter {PRIMITIVE_GROUP == ARITHMETIC && REF_NAME =~ DSP*}]]
    set fh [open [file join $out fmax.txt] w]
    puts $fh "vivado  [version -short]"
    puts $fh "part    $part"
    puts $fh "top     $top"
    puts $fh "period  $period ns"
    puts $fh "WNS     $wns ns"
    puts $fh [format "Fmax    %.1f MHz  (1000 / (period - WNS))" $fmax]
    puts $fh "worst path: [get_property STARTPOINT_PIN $path] -> [get_property ENDPOINT_PIN $path]"
    close $fh
    lappend summary [format "%-26s %7d %7d %5d %10.3f %10.1f" $top $lut $ff $dsp $wns $fmax]
}

set fh [open [file join $here summary.txt] w]
puts $fh "Vivado [version -short], $part, out-of-context, clock period $period ns"
puts $fh ""
puts $fh [join $summary "\n"]
close $fh
puts [join $summary "\n"]
