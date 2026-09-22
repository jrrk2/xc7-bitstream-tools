set part xc7vx485tffg1761-2
file mkdir out
read_verilog bram9.v
read_xdc bram9.xdc
synth_design -top bram9 -part $part -flatten_hierarchy none
opt_design
place_design
route_design
write_bitstream -force out/bram9.bit
write_checkpoint -force out/routed.dcp
puts "BRAM9_BUILD_DONE"
