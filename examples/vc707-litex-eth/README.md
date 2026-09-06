# The LiteX SoC with LiteEth over SGMII

`examples/vc707-litex` plus a LiteEth 1000BASE-X/SGMII PHY driving the GTXE2
transceiver — the same SERV SoC, generated with `--with-ethernet`.

Genuinely a different design, not a copy: 9088 lines of gateware against 1933,
4 `GTXE2_CHANNEL`, 3 `IBUFDS_GTE2`, 12 `MMCME2_ADV` against none/none/4, plus
`xilinx_vc707_mem_6b5b.init` — the 8b/10b tables the PCS reads.

## Status: blocked, in the router

It synthesises, packs and places. The transceiver, both PHY MMCMs and every
clock buffer land where Vivado put them (the constraints at the end of the XDC
come from Vivado's own implementation of this design). Routing then fails:

    Failed to route arc of 'main_k7_1000basex_s7mmcm0_clkin_signal',
      from BUFHCE_X0Y0.O to SLICE_X1Y0.CLKINV_OUT

A BUFH drives one clock region. Its loads have to be placed inside that region,
and nothing here confines them — Vivado does it with the `create_pblock
CLKAG_*` groups in the same report the LOC constraints came from, which is
region-constrained placement rather than a constraint that can be copied
across.

Retyping the three BUFHs to BUFGs (they are pin-compatible, and 7 of the
device's 32 global buffers are then in use) removes the region question
entirely, and it does get further — but not to a bitstream. The router then
spends its time in an UNBOUNDED search: router2 tries an arc inside a bounding
box, and on failure retries with the box disabled, which on this device means
an A* over some thirty million wires. A backtrace of the stuck process shows
exactly that:

    Router2::route_arc (..., is_bb=false) -> was_visited_fwd (wire=30148782, cost=3.4e38)

So the BUFG swap turned a fast, explicit failure into a slow one; the bounded
attempt had already failed before that point.

## Correction (2026-09-05): the path exists

An earlier version of this file guessed that "the route this design needs is
one the router cannot find at all -- whether because the path does not exist
in the chipdb or because it is not modelled as a dedicated route". That is
wrong, and `examples/vc707-ethmin` disproves it: the same LiteEth
`K7_1000BASEX` PHY, the same single `GTXE2_CHANNEL`, `IBUFDS_GTE2` and three
`MMCME2_ADV`, and it places, routes and answers ARP on hardware through this
flow.

What the LiteX design was missing is one constraint:

    set_property LOC GTXE2_CHANNEL_X1Y1 [get_cells GTXE2_CHANNEL]

With the transceiver pinned there, every clock in the DDR3+LiteEth SoC routes
except one, and nextpnr places the PHY's two MMCMs itself from the dedicated
GT->MMCM paths. The remaining failure is a global clock that cannot reach nine
of its loads across device halves -- a clock-router limitation, not a missing
path. See `docs/open-flow-ethernet-ddr-plan.md`.
