# Replaying a build: frozen placement and routing, plus something new

*2026-09-21.*  To instrument the one nextpnr build of the VC707 OCaml
processor that fails (`docs/extracted-timing.md`) without changing what is
being instrumented, nextpnr can now rebuild a design from a reference
build's placement and routing, bit for bit, and place and route only what
was added since -- a JTAG clock controller (`examples/jtag-clkctl`), an
internal logic analyser (`examples/openila`).

## The flow

    # the reference, run once more with --write (deterministic: same FASM)
    nextpnr-himbaechel ... --json design.json --write routed.json
    scripts/routing_dump.py routed.json routes.txt bels.txt holdbufs.txt

    # the same netlist plus the new cells (openila_merge.py, jtag_ctl_merge.py)
    nextpnr-himbaechel ... --json design_plus.json \
        -o preplaced=bels.txt -o prerouted=routes.txt -o holdbufs=holdbufs.txt -o hold-fix

- `-o preplaced`: every cell named gets a `BEL` attribute -- once before
  packing (so the packer's single-site primitives, BSCAN and friends, do
  not take a pinned site) and once after (for the packer's own cells).
  The tiles of pinned cells, and every logic/BRAM tile a reference route
  passes through (route-through LUTs; a block RAM's address cascade used as
  the way into the block RAM below), are closed to new cells.
- `-o holdbufs`: the reference's hold-fix feedthrough buffers are
  re-created before placement, as `fixup_hold()` makes them, so the
  reference's bels and routes name only cells and nets this design has.
- `-o prerouted`: each net's reference route is bound `STRENGTH_LOCKED`
  before the router runs; a branch that led to a sink this design lacks is
  pruned; a clock route_clocks only partly routed (an MMCM output that
  reaches its BUFG through the fabric) is replaced by the reference's.
  router2 treats a locked wire as reserved for its net rather than
  unavailable, so a net can still branch off its locked tree for a new sink
  (a BRAM output's only exit is through it).

The packer's feedthrough LUTs and MUXes are named after the pin they feed
(`<net>$LUT$<cell>$<port>`) instead of a counter, so the names survive a
netlist addition; results are unchanged.

## Verified

- `fpga/rbtest`: replay of the reference = 0 differing FASM features; with
  the 64x1024 ILA added, still 0 reference features missing.
- The failing processor build (`vc707-ethmin-open-A-repro`, 17,207 cells,
  31,941 nets, 1 hold buffer): replay = 27 features differ, all `NOCLKINV`
  bits in slices that hold nothing -- the reference's hold-fix search
  bound and unbound candidate bels there, which allocates the tile status
  the FASM writer then describes.  Harmless, and absent when there is
  nothing to fix.

## Also fixed on the way

- `pack_lutffs` dereferenced an FF's absent D (yosys's `x`); it skips now.
- The hold-fix would buffer an arc whose source (an O5, a 5FF's Q) had no
  slice output mux left, handing the router an unroutable site; it now
  leaves such an arc alone and says so.  Its reroute also rips up the nets
  driven from a touched source's tile, since the incremental reroute
  cannot take a first-pass route back from a neighbour.
- router2: an arc that needed the unbounded search marks its net, so the
  net's other arcs skip the bounded attempt (a BSCAN's sinks: seconds each,
  every routing pass).  The source-exit search (`find_source_sink_locs`)
  looks 20000 wires deep instead of 500.

## Limits

Adding a sink to a net can change packing where packing depends on fanout
(a LUT->FF pair needs fanout 1); the pinned placement still holds the
cells where they were, and the replay reports any reference cell the new
design lacks.  A net alias from the spliced module must not be added for a
design net (the merge scripts skip them), or nextpnr may take the alias as
the net's name and neither bels nor routes will match it.
