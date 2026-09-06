# Place and route a netlist the OPEN flow produced, in Vivado.
#
# The point is not to build the design again -- that would change synthesis and
# place-and-route together, and a timing difference would attribute to neither.
# This reads the same netlist yosys handed to nextpnr, so synthesis is held fixed
# and placement/routing is the only variable.  If Vivado closes timing on a
# netlist nextpnr cannot, the deficit is placement, and Vivado's own placement
# says what a region constraint ought to express.
#
#   vivado -mode batch -source scripts/vivado_pnr_netlist.tcl \
#          -tclargs <netlist.edif> <constraints.xdc> <outdir> [part]

set netlist [lindex $argv 0]
set xdc    [lindex $argv 1]
set outdir [lindex $argv 2]
set part   [expr {[llength $argv] > 3 ? [lindex $argv 3] : "xc7vx485tffg1761-2"}]

file mkdir $outdir

create_project -force -in_memory -part $part

# EDIF, not Verilog.  read_verilog would make Vivado elaborate the netlist and
# it may restructure what it finds -- and then a timing difference could not be
# attributed to placement, which is the whole point of this script.  EDIF plus
# link_design places exactly the cells yosys emitted.
#
# Three things the EDIF needs on the yosys side, all of them silent traps:
#   hilomap -hicell VCC P -locell GND G   (or: "Design contains constant nodes")
#   delete t:$scopeinfo                   (debug hierarchy markers, emitted as
#                                          instances of a cell never defined)
#   the file must be NAMED for the top cell -- "No files found to match top
#   module" means files, literally, not cells.
read_edif $netlist
read_xdc  $xdc

# link_design builds the design from the netlist as-is.  Deliberately NOT
# synth_design: re-synthesising would change the cells, and then a timing
# difference could not be attributed to placement.
link_design -top xilinx_vc707 -part $part

# The comparison is only honest if Vivado is placing what nextpnr placed.
puts "=== cell count after link: [llength [get_cells -hier]]"

report_utilization -file $outdir/utilization.rpt

opt_design   -directive Explore
place_design -directive Explore
phys_opt_design
route_design -directive Explore

report_timing_summary -max_paths 10 -file $outdir/timing.rpt
report_clock_utilization           -file $outdir/clocks.rpt
report_route_status                -file $outdir/route_status.rpt

# Where did the transceiver's datapath actually land?  This is the number the
# open flow is being compared against: nextpnr scattered it ~76 rows from the
# GT, and 78% of the critical path was wire.
puts "=== placement of the SGMII hard blocks ==="
foreach c [get_cells -hier -filter {REF_NAME =~ "GTXE2_*" || REF_NAME =~ "MMCME2_*" || REF_NAME =~ "BUFG*"}] {
    puts [format "  %-28s %s" [get_property REF_NAME $c] [get_property LOC $c]]
}

write_checkpoint -force $outdir/routed.dcp
write_bitstream  -force $outdir/design.bit
puts "NETLIST_PNR_DONE"
