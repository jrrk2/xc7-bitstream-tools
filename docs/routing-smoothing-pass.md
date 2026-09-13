# A routing smoothing pass: rip up and retry on density, not overuse

## The measurement that motivates it

Same design (VexRiscv-SMP, 1 GB, 128 KB L2), same part, both flows:

    flow      INT feats  INT tiles  mean/tile   p95   max
    vivado      182,950      6,921       26.4    88   113
    nextpnr     359,810      7,646       47.1   151   180
                  x1.97        x1.10      x1.78 x1.72 x1.59

nextpnr spends nearly twice the interconnect to express the same netlist, over
only 10% more tiles -- so it is not spreading wider, each tile is carrying
more.  Its 95th percentile (151) is worse than Vivado's single worst tile
(113).  On hardware that design closes `sys_clk` at 75.59 MHz against the
100 MHz it is clocked at, and the board miscomputes: the kernel is fine,
`crypt()` rejects a correct password and dropbear cannot start.

(Caveat on the Vivado column: it is `bit2fasm` output, so it counts pips
prjxray has bits for.  INT is prjxray's best-characterised tile and a 2x gap
is far beyond plausible database gaps, but the honest reading is "pips
prjxray can see".)

## Why more router iterations cannot fix it

router2 is a negotiated-congestion router whose cost is driven by OVERUSE:

    present_cost = 1.0f + overuse * curr_cong_weight * crit_weight   (router2.cc:478)

`overuse` is the count of nets illegally sharing a wire, and
`update_congestion()` stops the loop when `overused_wires` reaches zero.  A
tile holding 180 pips is legal.  Once legality is reached the gradient is
flat, so the uneven distribution is not a convergence failure -- it is
outside what the cost function can see.

## The pass

A POST-ROUTING pass, run only after legality, that makes tile DENSITY a cost
and redistributes against it.

### 1. Occupancy map

Walk bound pips once, bucket by `ctx->getPipLocation(pip)`:

    occ[Loc] = number of bound pips in that tile

Cheap, and it is the same quantity measured above, so the pass can be judged
by the metric that motivated it.

### 2. Choose hot tiles

Target the tail, not the mean: tiles with `occ > p95`, or `> mean + k*sigma`.
The aim is to pull 151 toward 47, not to shave the average -- peak occupancy
is what lengthens the paths that set fmax.

### 3. Choose victim nets

For each hot tile, the nets with pips in it, ranked by:

  - LOW criticality first.  Critical nets are already where the timing-driven
    router put them; disturbing them is how a smoothing pass makes timing
    worse.  Slack is the budget being spent, so spend it where there is some.
  - most pips inside hot tiles (most to gain)
  - short detour potential (bounding box has room)

Cap the nets ripped per round so one round is bounded work.

### 4. Rip up and re-route with a density term

Reuse `ripup_arc()` and `route_net()` unchanged, with one new term in
`get_wire_score`:

    smooth_cost = 1 + smooth_weight * max(0, occ[tile] - target) / target

multiplied into the score alongside `present_cost` and `hist_cost`.  This is
the whole idea: router2 has present and history costs for LEGALITY; this adds
a cost for DENSITY, so a wire in a crowded tile is expensive even when it is
perfectly legal.

`target` starts at the current p95 and is lowered each round; `smooth_weight`
decays, so early rounds move traffic freely and later ones only take clear
wins.

### 5. Accept or reject, per net

A reroute is kept only if all hold:

  - it introduces NO overuse (legality is not negotiable after the fact)
  - the net's own worst slack does not regress beyond a tolerance
  - the summed occupancy of the tiles it touches went down

Otherwise restore the previous route.  Without this the pass trades a
congested-but-fast route for a spread-out-but-slow one, which is the obvious
way for it to do harm.

### 6. Stop

Bounded rounds; stop early when p95 stops improving, when no net is accepted,
or when any accepted move would cost criticality.

## What it must report

Before and after, the same five numbers as the table above, plus total pips.
A pass that cannot show p95 falling is not working, and the Vivado column is
the reference for how much headroom exists (182,950 pips, max 113).

## Risks worth stating

  - Peak occupancy is a PROXY for delay.  The real target is fmax; a net can
    be moved out of a hot tile and get slower.  The per-net slack guard is
    what keeps the proxy honest, and the pass should be judged on fmax, not
    on the occupancy table.
  - It cannot fix placement.  If two heavily-connected blocks are placed far
    apart, the interconnect between them is congested because it must be.
    Smoothing redistributes; it does not move cells.  A 2x pip gap is more
    likely a placement deficit than a routing one, so the honest expectation
    is that this recovers part of it.
  - Run time.  Rip-up and re-route with an accept/reject guard is a routing
    pass in its own right; it belongs behind a flag, off by default, until it
    has shown it pays for itself.

## Status: implemented behind a flag, NOT yet working

    --router2-smooth-iters N     (0 = off, the default)
    --router2-smooth-weight W    (default 1.0)

The density term, the occupancy map, the hot-tile selection, the criticality
and fanout guards, the legality recovery and the before/after reporting are
all in `common/route/router2.cc`.  With the flag off the routed result is
BIT-IDENTICAL to before the change -- verified on vc707-johnson, same FASM,
same 455.17 MHz -- so nothing is at risk by default.

With the flag on it aborts:

    Info: Smoothing congestion: 102 tiles, mean 8.8, p95 64, max 126, 898 pips
    ERROR: Failed to route arc 0.0 of net 'core.prbs[19]',
           from X79Y221/SLICE_X1Y0.A5FF_Q to X79Y221/SLICE_X1Y0.A4

`route_net()` cannot rebuild every arc it is asked to.  That one is a
flip-flop output going back into a LUT input in the SAME slice: a path the
general search does not find, because it was established by the packer and
the router's own site handling rather than by search.  Ripping it up destroys
something that cannot be recreated, and the failure is a `log_error`, so it
takes the whole run with it.

Three filters were tried and none is the right answer: excluding globals
(`NetInfo::is_global` does not exist on this arch), capping fanout (the
johnson clock has 25 sinks), and skipping degenerate arc bounding boxes (the
arc bb carries the router's search margin, so an intra-slice arc's box is not
degenerate).  Each is a guess at a class that is not cleanly identifiable
from outside.

WHAT IT ACTUALLY NEEDS is snapshot and restore, which is also what the design
above already asks for in step 5 and what makes the accept/reject guard
possible at all: record the net's `wires` before rip-up, attempt the
re-route, and on failure OR on a worse result re-bind the original pips
through `bind_pip_internal`.  Then an unroutable arc is a rejected move
rather than a dead run, and the pass can be judged on whether it improves
p95 and fmax instead of on whether it survives.

The clock exclusion earned its place regardless: ripping up a clock fails
every time, and the driver-bel-type test is the portable way to recognise
one.
