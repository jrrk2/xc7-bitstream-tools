# readback.tcl <out.rbd> [capture] -- read the configuration memory back.
#
# With "capture", GCAPTURE first: the flip-flops' live values land in the
# frames where their INIT bits were, and the block RAMs' contents in theirs.
#
#   vivado -mode batch -source scripts/jtag/readback.tcl -tclargs state.rbd capture
set out [lindex $argv 0]
set cap [expr {[llength $argv] > 1 && [lindex $argv 1] eq "capture"}]
open_hw_manager
connect_hw_server -quiet
open_hw_target -quiet
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
if {$cap} {
    readback_hw_device -capture -readback_file $out -bin_file ${out}.bin $dev
} else {
    readback_hw_device -readback_file $out -bin_file ${out}.bin $dev
}
puts "READBACK_DONE $out"
close_hw_target -quiet
