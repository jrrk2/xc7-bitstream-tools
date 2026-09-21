# vivado_net_delays.tcl <routed.dcp> <out.csv> -- every routed net's delay, pin to pin.
#
# The oracle for the extractor's timing: Vivado's own figure for each
# driver -> load of every net it routed, identified by SITE PIN
# (SLICE_X10Y20/AQ, RAMB18_X1Y2/DIBDI8) so it lines up with what the
# extractor recovers from the same design's bitstream without any naming.
# Four corners, ns.
#
#   vivado -mode batch -source scripts/vivado_net_delays.tcl -tclargs routed.dcp net_delays.csv
set dcp [lindex $argv 0]
set out [lindex $argv 1]
open_checkpoint $dcp
set fh [open $out w]
puts $fh "net,from,to,fast_min,fast_max,slow_min,slow_max"
set n 0
foreach net [get_nets -hierarchical -filter {TYPE != POWER && TYPE != GROUND && ROUTE_STATUS == ROUTED}] {
    # a net_delay object knows only its load (TO_PIN); the driver is the net's
    set drv [get_pins -of_objects $net -filter {DIRECTION == OUT} -quiet]
    if {$drv eq ""} continue
    set f [get_site_pins -of_objects $drv -quiet]
    if {$f eq ""} continue
    foreach d [get_net_delays -of_objects $net -quiet] {
        set t [get_site_pins -of_objects [get_pins [get_property TO_PIN $d]] -quiet]
        if {$t eq ""} continue
        puts $fh "[get_property NAME $net],$f,$t,[get_property FAST_MIN $d],[get_property FAST_MAX $d],[get_property SLOW_MIN $d],[get_property SLOW_MAX $d]"
        incr n
    }
}
close $fh
puts "NET_DELAYS_DONE $n"
