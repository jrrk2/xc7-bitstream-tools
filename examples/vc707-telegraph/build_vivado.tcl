# Golden Vivado build of the telegraph.  The point of this example is to tell a
# dead clock apart from a dead output path, which it can only do if the
# bitstream itself is above suspicion -- so the reference build is Vivado's,
# and the open flow's is graded against it rather than trusted on its own.
set part xc7vx485tffg1761-2
read_verilog top.v telegraph_core.v
read_xdc top.xdc
synth_design -top top -part $part
opt_design
place_design
route_design
report_timing_summary -file build-vivado/timing.rpt
report_utilization -file build-vivado/util.rpt
write_bitstream -force build-vivado/telegraph.bit
puts "TELEGRAPH_BUILD_DONE"
