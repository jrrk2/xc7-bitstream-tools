# DDR3 and a transceiver, in one open-flow bitstream

VexRiscv, the DDR3 SODIMM, and LiteEth's 1000BASE-X/SGMII PCS on the GTX --
built by yosys, nextpnr-himbaechel and prjxray, with no Vivado in the path.

    make vc707-litex-ddr-ethmin-vivado          # golden reference
    # open flow: --with-ddr --with-ethmin-phy --cpu-type vexriscv

## Why the PHY comes from ethmin

LiteX builds this PCS itself with `--with-ethernet`, via K7_1000BASEX, and the
result does not route: the router fails on
`main_k7_1000basex_rxoutclk_rebuffer`, a global clock that cannot reach nine of
its loads. `examples/vc707-ethmin` wraps the *same* PCS behind a plain GMII
interface and does place, route and answer ARP on this board through this flow,
so `--with-ethmin-phy` imports that wrapper as Verilog and treats it as a black
box. LiteEth's own `LiteEthPHYGMIITX/RX` carry it from there to the MAC.

With it, every clock routes -- including the one that failed. The blocker was
how LiteEth constructs its clock tree, not the router's reach and not a missing
path in the chipdb.

One placement constraint anchors the rest:

    set_property LOC GTXE2_CHANNEL_X1Y1 [get_cells liteeth_sgmii_phy.GTXE2_CHANNEL]

nextpnr then places the PHY's two MMCMs itself from the dedicated GT->MMCM
routing. ethmin's other eleven LOCs are not copied: nextpnr overrides the MMCM
ones, and its six BUFG sites were chosen for a design with no DDR3 controller
competing for the same global buffers.

## Status (2026-09-06): boots, DDR3 works, link does not

    CPU:      VexRiscv @ 100MHz
    SDRAM:    512.0MiB 32-bit @ 800MT/s (CL-6 CWL-5)
    Memtest OK
    Memspeed: Write 62.1MiB/s  Read 64.3MiB/s
    Booting from network... ARP failed

The memory controller is untouched by the transceiver's presence -- 62.1/64.3
MiB/s against 61.7/64.3 for the DDR-only build. What fails is the GMII timing:

    eth_rx_clk  78.8 MHz (needs 125)
    eth_tx_clk  91.3 MHz (needs 125)

and the cause is placement rather than fabric. The critical path is 1.10 ns of
logic against 3.92 ns of routing, hopping (324,96) -> (350,149) -> (330,73):
~76 rows, for a datapath that should sit beside the transceiver in the bottom
right of the die. Two runs of identical RTL produced 120.1 MHz and 91.3 MHz on
the same clock -- a 24% swing decided by nothing but where the placer scattered
it.

So this is not a timing problem to be tuned, and re-rolling placer seeds until
one passes is the same lottery with extra steps. It needs region constraints:
nextpnr's XDC reader has no `create_pblock`, so there is currently no way to
confine a clock domain to the part of the die its pins are on. See
`docs/open-flow-ethernet-ddr-plan.md`.

## The board PHY's management pins

`--with-ethmin-phy` drives `eth_rst_n` high and `eth_mdc` low rather than
leaving them floating. 1000BASE-X autonegotiation needs no MDIO, and the two
pins are the halves of one IOB tile whose `IOB_Y{0,1}...IN` features share bit
39_01 with opposite polarity -- that bit selects *which* half is the input, so
"both halves are inputs" cannot be expressed and fasm2frames rejects it.
Vivado emits no `.IN` bits at all for such a tile. Driving these leaves one
input there, which is expressible; the writer should learn the general rule.
