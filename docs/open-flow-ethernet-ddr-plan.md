# Bringing Ethernet and DDR3 to the open flow

What stands between the open flow (yosys -> nextpnr-himbaechel -> prjxray) and
the LiteX SoC it already boots gaining a DDR3 controller and a working SGMII
link. Everything below was measured on 2026-09-05, not inferred; where an
older note in this repository says otherwise, the note is wrong and is called
out as such.

## Where the flow actually stands

The open flow boots an interactive SoC on the VC707: banner, `BIOS CRC
passed`, `Memtest OK`, and a console that accepts commands. That took four
I/O fixes on the day and is the baseline everything here builds on.

Running the full DDR3 + LiteEth SoC through the flow gets:

| stage | result |
| --- | --- |
| yosys synthesis | clean |
| packing | clean, including all 198 DDR serialiser/delay cells |
| placement | complete, 8801 cells |
| clock routing | complete for 9 of 12 clocks |
| general routing | **fails on one arc** |

## Two blocking claims that turned out to be false

**"The GT clock route may not exist in the chipdb"**
(`examples/vc707-litex-eth/README.md`). It does. `examples/vc707-ethmin` uses
the same LiteEth `K7_1000BASEX` PHY -- one `GTXE2_CHANNEL`, one
`IBUFDS_GTE2`, three `MMCME2_ADV` -- and places, routes and answers ARP on
hardware through this flow. One constraint is what the LiteX design was
missing:

    set_property LOC GTXE2_CHANNEL_X1Y1 [get_cells GTXE2_CHANNEL]

With the transceiver pinned to the site ethmin uses, nextpnr's own clocking
pass then places the TX and RX MMCMs itself "based on dedicated routing",
deriving their sites from the GT->MMCM dedicated paths. Copying ethmin's MMCM
sites as well is unnecessary and slightly wrong: nextpnr overrode them. The
technique is one LOC, not the twelve ethmin carries.

**"DDR3 needs ISERDES/OSERDES/PHASER modelling."** At the `nphases=4` this
board uses, V7DDRPHY instantiates no PHASER, no PHY_CONTROL and no
IN/OUT_FIFO at all -- only `IDELAYE2`, `ODELAYE2`, `ISERDESE2`, `OSERDESE2`
and one `IDELAYCTRL`. Every one of those already has a FASM writer in
`fasm.cc`, and `IDELAYCTRL` has packing support in `pack_io.cc`. All 198 cells
synthesised, packed and placed without complaint.

## DDR3: done (2026-09-06)

It routes, calibrates against the SODIMM and passes memtest, with either CPU.
The delay taps agree with Vivado's build of the same gateware. See
`examples/vc707-litex-ddr/README.md`.

## Ethernet: the blocker was LiteEth's clock tree, not the router

The failure was

    ERROR: Failed to route arc of net 'main_k7_1000basex_rxoutclk_rebuffer',
           from BUFGCTRL_X0Y0.O to SLICE_X1Y0.CLKINV_OUT

and the guess recorded here was that the clock router could not reach across
device halves. That was wrong. Substituting the PHY wrapper from
`examples/vc707-ethmin` -- the *same* LiteEth 1000BASE-X PCS, behind a plain
GMII interface, instantiated as a black box -- routes every clock including
that one. `--with-ethmin-phy` selects it.

So the fault is in how LiteEth builds its clocking, not in the router's reach
and not in a missing chipdb path. One constraint anchors the rest:

    set_property LOC GTXE2_CHANNEL_X1Y1 [get_cells liteeth_sgmii_phy.GTXE2_CHANNEL]

With the transceiver pinned, nextpnr's clocking pass places the PHY's MMCMs
itself from the dedicated GT->MMCM routing. Copying ethmin's other eleven LOCs
is unnecessary; nextpnr overrides the MMCM ones and says so.

## What is left: placement locality, not routing

The design routes and produces a bitstream. It does not meet timing on the
GMII clocks, and the reason is where the logic sits rather than how much of it
there is:

    eth_tx_clk critical path: 1.10 ns logic, 3.92 ns routing
    (324,96) -> (350,149) -> (330,73)

78% wire, on a path that hops ~76 rows. The SGMII pins and the GT quad are in
the bottom right of the die; the eth datapath should be beside them and is
not. Two runs of identical RTL gave `eth_tx_clk` 120.1 MHz and 91.3 MHz -- a
24% swing decided by nothing but where the placer happened to scatter it.

The same pathology puts clock sources far from their loads: in the DDR-only
build 97% of 12642 slices sat in Y300-349 while the MMCM was at tile Y4, the
BUFGs at Y17-25 and the block RAMs at Y62-69.

### 1. Region constraints (do this first)

`himbaechel/uarch/xilinx/xdc.cc` understands only `create_clock`,
`set_property` and `set_multicycle_path`. There is no `create_pblock`, so
there is currently no way to say "this clock domain belongs in the bottom
right". Adding that -- and honouring it in the placer -- fixes the cause
rather than the symptom, removes the run-to-run lottery, and helps every
design through this flow rather than this one. Vivado's own implementation of
the LiteEth SoC uses `create_pblock CLKAG_*` groups for exactly this.

Re-rolling placer seeds until one passes is not a substitute; it is the same
lottery with extra steps.

### 2. The .IN bits when both halves of a tile are inputs

prjxray's `IOB_Y0...IN` and `IOB_Y1...IN` share bit `39_01` with opposite
polarity -- it selects *which* half is the input, so "both halves are inputs"
cannot be expressed, and fasm2frames rejects it as inconsistent. Vivado emits
no `.IN` bits at all for such a tile and relies on `IN_ONLY`. The writer
should do the same. Worked around for now by driving the board PHY's unused
management pins so only one half of that tile is an input.

### 3. Timing at 100 MHz

Unchanged: `examples/vc707-litex/vc707_litex.py` records that 25 MHz is what
the open flow closes and that it has no proper hold STA. The DDR3 build
reports one -0.02 ns hold violation and works; ethmin reports 18 and works.
Treat hold results here as advisory until the STA is trustworthy.

## How each step gets verified

Not by LVS alone. On 2026-09-05 LVS proved the LiteX SoC at 2820 proved / 0
differ while it drove every signal onto the wrong package pin with an inverted
input: it models fabric logic and never inspects pad or I/O-logic
configuration. All four of that day's bugs were found by decoding a golden
Vivado bitstream of identical RTL with `bit2fasm`, diffing feature by feature,
and confirming each claim against the segbits database rather than inferring
it.

Every variant has such a bitstream, and all are known to work on the board:

* `examples/vc707-litex-ddr/build-vivado` -- DDR3, memtest passes
* `examples/vc707-litex-eth/build-vivado` -- LiteEth
* `examples/vc707-litex-ddr-eth/build-vivado` -- both; ARP and ICMP answered

Use them. A design that routes is not a design that works.
