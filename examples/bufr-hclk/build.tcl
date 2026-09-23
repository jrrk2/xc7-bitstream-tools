set part xc7vx485tffg1761-2
file mkdir out
read_verilog vc707_bufr.v
read_xdc vc707_bufr.xdc
synth_design -top vc707_bufr -part $part
opt_design
place_design
route_design
report_utilization -file out/util.rpt
write_bitstream -force out/vc707_bufr.bit
puts "BUFR_BUILD_DONE"
