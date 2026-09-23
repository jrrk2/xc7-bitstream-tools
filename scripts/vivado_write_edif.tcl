# Write Vivado's synthesised netlist as EDIF, for SVS to read.
#
# EDIF is the interchange SVS expects (svd.read_edif); yosys has no EDIF
# reader at all, which is why the structural-Verilog route exists alongside
# this one.  Reading Vivado's own output through SVS lets the two synthesis
# results be compared in one IR rather than through two different importers.
#
#   vivado -mode batch -source scripts/vivado_write_edif.tcl \
#          -tclargs <synth.dcp> <out.edif>
open_checkpoint [lindex $argv 0]
write_edif -force [lindex $argv 1]
puts "cells: [llength [get_cells -hier]]"
