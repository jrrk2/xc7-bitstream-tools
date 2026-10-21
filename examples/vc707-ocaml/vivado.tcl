# Place and route Verilator's EDIF of this example in Vivado, from the
# directory holding vc707_ethmin_vm.edf (see README.md, "Building with Vivado"):
#   vivado -mode batch -nojournal -source <this dir>/vivado.tcl
# The directives are those of the bytecode repository's fpga/vc707-ethmin/build.tcl.
set here [file dirname [file normalize [info script]]]
read_edif vc707_ethmin_vm.edf
link_design -part xc7vx485tffg1761-2 -top vc707_ethmin_vm
read_xdc $here/vivado.xdc
opt_design
place_design -directive Explore
phys_opt_design -directive AggressiveExplore
route_design -directive Explore
phys_opt_design -directive AggressiveExplore
report_timing_summary -file timing.txt
report_utilization -file util.txt
write_bitstream -force vc707_ocaml_viv.bit
