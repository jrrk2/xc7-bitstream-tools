# user1.tcl <hex32> [<hex32>...] -- shift 32-bit words through USER1, print what came out.
#
# Vivado's hw_jtag mode drives the cable directly: IR = USER1 (0x02 on
# 7-series), then one 32-bit DR shift per word.  The word shifted in is the
# design's control register; the word that comes out is whatever the design
# loaded on CAPTURE (vc707_rbtest: {cnt, lfsr, ac, ss}).
#
#   vivado -mode batch -source scripts/jtag/user1.tcl -tclargs 00000003
open_hw_manager
connect_hw_server -quiet
open_hw_target -jtag_mode 1 -quiet
run_state_hw_jtag reset
run_state_hw_jtag idle
scan_ir_hw_jtag 6 -tdi 02
foreach w $argv {
    set out [scan_dr_hw_jtag 32 -tdi $w]
    puts "USER1 in $w out $out"
}
run_state_hw_jtag idle
close_hw_target -quiet
