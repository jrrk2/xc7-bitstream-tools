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

## The one real blocker

    ERROR: Failed to route arc 0.0 of net 'main_k7_1000basex_rxoutclk_rebuffer',
           from X192Y160/BUFGCTRL_X0Y0.O to X100Y197/SLICE_X1Y0.CLKINV_OUT.

The net *is* given to the dedicated clock router -- the log shows `routing
clock 'main_k7_1000basex_rxoutclk_rebuffer'` -- and nine of its loads then
report `failed to find a route using dedicated resources`. They fall through
to router2, which cannot reach a slice's clock pin through general
interconnect, and the build stops. `main_crgddr_clkout0/1/2` each lose one
load the same way.

The arc crosses device halves: a BUFG in tile row Y160 driving a slice at
Y197. That is what the `CLK_BUFG_REBUF` spine exists for, and the spine *is*
modelled -- the working block-RAM SoC emits 31 of those features. But Vivado's
build of this design emits **170**, across several GCLK indices, where ours
uses essentially one. So the gap is not "the spine is missing" but "the clock
router gives up on loads the spine could reach".

That is a router/model problem, not a device-database gap, and it is the whole
of what stands between here and a routed design.

## Work items, in order

1. **Establish why nine loads fail dedicated routing.** Instrument or gdb the
   dedicated clock router at the point it gives up for this net, exactly as
   the earlier unbounded-search diagnosis was done. Everything below depends
   on the answer, so nothing else should start first.

2. **Compare against the golden spine usage.** `prjxray/utils/bit2fasm.py` on
   `examples/vc707-litex-ddr-eth/build-vivado/gateware/xilinx_vc707.bit` --
   which works on hardware -- and diff the `CLK_BUFG_REBUF`, `CLK_HROW_*` and
   `HCLK_*` tiles against ours. 170 features against 31 is the shape of the
   answer; the diff says which GCLK indices and which enables we never set.

3. **Remove the BUFHs at the generator, not afterwards.** The LiteX gateware
   has three `BUFH`s where ethmin has none, and a BUFH drives a single clock
   region. `S7MMCM.create_clkout(..., buf=...)` selects the buffer, so this
   belongs in the LiteEth PHY generation rather than in a post-hoc retype of
   the emitted Verilog. The retype was tried and sent router2 into an
   unbounded whole-device search, which is a separate router bug worth
   isolating on its own (a bounded attempt that fails should not fall back to
   an A* over thirty million wires).

4. **Only then, timing.** This SoC runs at 100 MHz because V7DDRPHY needs
   `sys4x`; `examples/vc707-litex/vc707_litex.py` records that 25 MHz is what
   the open flow closes, and that it has no proper hold STA. Expect work here
   and do not read a routed-but-silent board as a routing failure.

## How each step gets verified

Not by LVS alone. On 2026-09-05 LVS proved this SoC at 2820 proved / 0 differ
while it drove every signal onto the wrong package pin with an inverted input:
it models fabric logic and never inspects pad or I/O-logic configuration. All
four of that day's bugs were found by decoding a golden Vivado bitstream of
identical RTL with `bit2fasm`, diffing feature by feature, and then confirming
the claim against the segbits database rather than inferring it.

Every variant here has such a golden bitstream, and all three are known to
work on the board:

* `examples/vc707-litex-ddr/build-vivado` -- DDR3, memtest passes
* `examples/vc707-litex-eth/build-vivado` -- LiteEth
* `examples/vc707-litex-ddr-eth/build-vivado` -- both; ARP and ICMP answered,
  512 MiB at 800 MT/s

Use them. A design that routes is not a design that works.
