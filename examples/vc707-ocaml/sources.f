# vc707-ocaml: a processor whose native instruction set is OCaml 4.14
# bytecode, with the same 1G Ethernet MAC and LiteEth SGMII PCS the
# picorv32 ethmin example uses.  See README.md.
#
# The Ethernet, UART and clocking RTL is shared with examples/vc707-ethmin
# rather than copied: the two SoCs differ only in the processor.

# The processor, converted from SystemVerilog by sv2v (see README.md)
vm_sv2v.v

# The SoC around it: code ROM, I/O map, packet window, boot sequencer
program_bram.v
ethmin_vm_core.v
vc707_ethmin_vm.v

# Ethernet: MAC, framing, buffering, DMA
../vc707-ethmin/rtl/eth_mac_1g.sv
../vc707-ethmin/rtl/axis_gmii_rx.sv
../vc707-ethmin/rtl/axis_gmii_tx.sv
../vc707-ethmin/rtl/rgmii_lfsr.sv
../vc707-ethmin/rtl/eth_lutram_fifo.sv
../vc707-ethmin/rtl/eth_stream_dma.sv
../vc707-ethmin/rtl/eth_gmii_retime256.sv
../vc707-ethmin/rtl/eth_pkt_buf256.sv

# The SGMII PCS/PMA and the GTX beneath it
../vc707-ethmin/rtl/liteeth_sgmii_phy.v
../vc707-ethmin/rtl/sgmii_soc_liteeth.sv

# Clocking and console
../vc707-ethmin/rtl/clkgen_vc707.sv
../vc707-ethmin/rtl/simpleuart.v
