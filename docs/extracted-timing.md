# Timing from the bitstream: the receive fault, and what was built to see it

*2026-09-21.* Status notes for the open-flow Ethernet receive fault on the
VC707 OCaml VM (`~/bytecode`, `fpga/vc707-ethmin`), and for the tooling
that came out of chasing it: transport delays in the extractor, a calibrated
static timing analysis of a bitstream, and the plan to hand that to OpenSTA.

## The fault, as established

Same RTL, same yosys netlist, same board, same cable, same Mac, same
clocking (VM 62.5 MHz, MAC 125 MHz, PCS 125 MHz):

| build | P&R | result |
|---|---|---|
| old loader netlist, nextpnr seed 1 (`results/ethfault/fail`, `vm_rxclk.bit`) | nextpnr | never binds; ~1/3 of its DISCOVERs are runts |
| the same netlist, nextpnr seed 2 (`results/ethfault/work_A`) | nextpnr | boots, REPL works |
| the same netlist, Vivado (`vm-yosys-vivado-A`) | Vivado | boots |
| trace-loader netlist, nextpnr, two seeds (`results/ethfault/work`) | nextpnr | boots; also with the prints patched off in the bitstream |
| Vivado from RTL at 100 and at 62.5 MHz | Vivado | boots (fib 18: 249 / 400 ms) |
| LiteX Linux SoC, open flow, same PHY | nextpnr | receives (TFTP reply seen) |

So: not synthesis (Vivado P&R of the identical netlist works), not the PHY,
GTX, MMCMs or the database's memory models, not frequency (Vivado at the
same clocks works), not the loader's timing (prints patched off, same
bitstream, still works).  One nextpnr placement fails, others of the same
netlist pass.  The reproduction of the failing run is bit-for-bit identical,
so it is deterministic.

The runts are the decisive symptom.  On the wire (`tcpdump -e -xx`) a bad
DISCOVER is the good one with its **first seven bytes removed** and a valid
FCS -- the Mac's NIC only delivers frames whose FCS checks -- so the bytes
were lost between the DMA and the MAC's CRC engine, and seven is exactly the
number of cycles `axis_gmii_tx` spends in `STATE_PREAMBLE` with `tready`
low before it takes the first byte.  Halving the MAC clock changed nothing.
Runts come in runs (several attempts good, several bad), i.e. the condition
varies on a timescale of tens of seconds -- thermal, or something the RX
traffic does to shared state.  The RX side is dead throughout.

What the static checks say about the failing build, all of them clean:

- LVS (`lvs_equiv`): every register's next-state function, every memory's
  contents and configuration equal to the netlist's (the only DIFFERs are
  the GTX-fed registers, because the extractor ties GTX outputs to 1).
- `clockcheck.py`: every one of 3545 slice and block-RAM clock pins on the
  right source; no domain shares a source.
- `fabsta.py` (calibrated): no hold or setup violation on the DMA<->MAC
  handshake; the packet-lane `DIBDI` pins are the tightest hold in *both*
  builds (+0.11 ns); setup in the VM domain is negative in both (see below).
- Round trip: every bit-carrying routing pip nextpnr wrote decodes back out
  of the bitstream.

So whatever it is, it is in a corner none of these model: clock skew (not
in the database per instance), the untimed GTX arcs, or analog.

## Tooling

### `tileverilog --timing [--net-delays out.csv]`

Every routing `assign` is written `#(fast_min:slow_max:slow_max)`, the pip's
own delay from `tile_type_<T>.json` plus the RC terms exactly as nextpnr's
chipdb computes them (driver resistance times the source's total load
capacitance, output resistance times the destination wire's capacitance).
99.8 % of pips have a figure; the rest (site and pseudo pips) get a 20 ps
stub.  The slice model gains a `specify` block from the library SDF (LUT
0.045..0.124, FF clk->Q 0.099..0.303, `$setuphold` gated on the column
having a register), so `iverilog -Tmin` / `-Tmax` is a timing simulation
with no SDF.  `--net-delays` writes every net's driver->load delay keyed by
site pin (`SLICE_X10Y20/AQ,RAMB18_X1Y2/DIBDI8,...`), which is how Vivado
names the same thing.

### The oracle: `scripts/vivado_net_delays.tcl`, `vivado_placement.tcl`, `vivado_place2json.py`

Vivado places and routes the *same yosys netlist* (`fpga/vc707-ethmin/vivado_pnr_edif.tcl`,
which now also writes the routed checkpoint), then the two Tcl scripts dump
its per-net delays (four corners, by site pin) and its placement; the
converter makes the placement JSON the extractor and LVS read.  The
oracle's bitstream is extracted with `--timing`, and
`scripts/calibrate_net_delays.py` joins the two tables.

### Calibration (33,323 pairs)

| model slow_max bin | n | model fast_min -> Vivado | model slow_max -> Vivado |
|---|---|---|---|
| < 0.15 ns | 2753 | 0.041 -> 0.136 | 0.091 -> 0.262 |
| 0.15-0.30 | 10771 | 0.101 -> 0.220 | 0.218 -> 0.417 |
| 0.30-0.50 | 7296 | 0.184 -> 0.350 | 0.389 -> 0.634 |
| 0.5-1.0 | 6986 | 0.343 -> 0.608 | 0.714 -> 1.062 |
| 1-2 | 4572 | 0.662 -> 1.082 | 1.365 -> 1.870 |

Fits: `vivado_fast_min = 1.506 * model + 0.076 ns` (sd 0.11),
`vivado_slow_max = 1.246 * model + 0.154 ns` (sd 0.14).  The database's
pip sums -- which are also what nextpnr's timing is built on -- are short
by a constant (the site-pin ends the pip table does not carry) plus 25-50 %.
Library requirements read off Vivado's own paths (`probe2.log`): FF clk->Q
0.100 (fast), hold 0.087, setup 0.034; RAMB18 hold: DI 0.296 (port B) /
0.255 (A), ADDR 0.183, EN 0.096, WE 0.046.  nextpnr's chipdb uses 0.30 for
clk->Q, 0.20 for FF hold, and the slow_max pip delay at both corners.

Consequences worth stating plainly:

- nextpnr's "PASS at 62.5 MHz, Fmax 65.8" for the VM domain is, by Vivado's
  reckoning, about 19 ns of path in a 16 ns period.  Both same-netlist
  builds have negative setup slack there in the calibrated STA (the walker
  caps at nine LUT levels and follows every LUT pin, so it over-reports
  depth; the sign is still right).  Marginal at the actual corner: a
  build can pass warm and fail cold, or the reverse.
- Hold analysis in nextpnr is optimistic by roughly two: real short hops are
  0.05-0.8 ns at the fast corner where it assumes >= 0.30 + slow routing.

### `fabsta.py`, `clockcheck.py` (`~/bytecode-work/lvs`)

The STA prototype over the timed extraction: nets from the annotated
assigns, FF->FF and FF->BRAM paths through LUT columns, each end's clock
arrival from its routed clock net, hold at the fast corner and setup at the
slow one, clock-domain crossings listed separately by raw delay.  Sanity on
the oracle: worst hold +0.12 (BRAM DI) / +0.16 (FF) where Vivado says
+0.13 / +0.09; no false violations.  Its known gaps are why it is being
replaced by OpenSTA: it follows LUT pins the function does not depend on
(false paths, e.g. `frame_ptr` "reaching" the VM's stack RAM through a
fractured LUT), it caps depth, and the database's clock-tree pips are per
class, so every leaf gets the same arrival and skew is zero.

`clockcheck.py`: every slice/BRAM clock pin traced to its source and
compared with the netlist's clock net for that cell.

### Also from this investigation

- `lvs_equiv --only TEXT`: check just the registers whose name contains TEXT.
- `HOLDFIX_VERBOSE=1` makes nextpnr's hold-fix log each detour and
  feedthrough (net -> sink pin, deficit).
- `INT_L_X32Y128.LH12.ER1END3` collides with `LIOB18_X81Y133` IOB bits in
  assembly (seed 3 of the trace netlist): a tilegrid overlap to fuzz, like
  `BRAM_L_X114Y0`.
- System-Verilog-suite proves yosys's `axis_gmii_tx` equivalent to its RTL
  (Z3 miter); `eth_stream_dma` (indexed part-select), `eth_pkt_buf256`
  (memory box) and `axis_gmii_rx` (CRC port shape) hit suite limits.

## OpenSTA

The extractor has what OpenSTA needs; `fabsta.py` was the proof that the
numbers are sane.  The plan:

1. `tileverilog --sta-out DIR` writes a structural netlist of primitives
   (LUT1-6 with INIT, FDRE/FDSE/FDCE/FDPE, CARRY4, MUXF7/8, RAMB18/36 as
   black boxes with clock pins, BUFG, MMCM/GTX as black boxes) instead of
   `xcol` columns, one wire per net.
2. A Liberty for those primitives: arcs from the library SDF, setup/hold
   from the Vivado-probed figures above, BRAM clock->out from the SDF.
3. An SDF with one INTERCONNECT per driver->load from the calibrated pip
   sums (both corners), which is the `--net-delays` table in SDF form.
4. SDC: the clocks at their BUFG outputs (periods from the design), the
   MMCM-derived ones as generated clocks, async groups as in the XDC.
5. `sta`: `read_liberty`, `read_verilog`, `link_design`, `read_sdf`,
   `read_sdc`, `report_checks -path_delay min/max`, `report_clock_skew`.

Then run it on `results/ethfault/{fail,work_A}` and the oracle, and check
the oracle's numbers against Vivado's report before believing the diff.
