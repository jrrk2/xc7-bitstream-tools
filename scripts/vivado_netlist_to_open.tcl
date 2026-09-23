# Write Vivado's SYNTHESISED netlist in a form the open backend can read.
#
# The mirror of vivado_pnr_netlist.tcl, which places the open flow's netlist
# in Vivado.  This goes the other way: Vivado synthesises, nextpnr places and
# routes.  It separates two questions that are otherwise entangled -- whether
# yosys can synthesise a core, and whether the open backend can place it --
# so a failure attributes to one or the other.
#
# EDIF would be the natural interchange and yosys has no reader for it, so
# structural Verilog it is: the same Xilinx primitives, in a syntax both
# tools agree on.
#
#   vivado -mode batch -source scripts/vivado_netlist_to_open.tcl \
#          -tclargs <synth.dcp> <out.v>
open_checkpoint [lindex $argv 0]
# funcsim, not design.  -mode design preserves internal name aliasing and
# emits module headers that mix bare identifiers with explicit .name(sig)
# connections -- illegal Verilog, since a header must be all one form, and
# yosys rejects it with "unexpected TOK_ID, expecting '.'".  funcsim writes
# the same UNISIM primitives without the aliasing.
write_verilog -mode funcsim -force [lindex $argv 1]
puts "cells written: [llength [get_cells -hier]]"
