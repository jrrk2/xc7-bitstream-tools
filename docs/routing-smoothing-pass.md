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

## Status: implemented behind a flag, working, no measured gain yet

    --router2-smooth-iters N       rounds (0 = off, the default)
    --router2-smooth-weight W      how hard the density term pushes (default 1.0)
    --router2-smooth-percentile P  occupancy percentile treated as hot (default 0.95)
    --router2-smooth-max-crit C    leave nets at or above this criticality alone (default 0.8)
    --router2-smooth-max-fanout N  leave nets with more sinks than this alone (default 32)
    --router2-smooth-cap F         fraction of candidates to try per round (default 0.25)
    --router2-smooth-min-wires N   skip nets held in fewer wires than this (default 8)
    --router2-smooth-stagnant N    non-improving rounds to tolerate (default 0)

The last six exist because the selection, not the cost weight, is what bounds
this pass: on vc707-litex the defaults offer it 138 nets out of the whole
design, and a quarter of those per round.

A note on the float ones.  `Property` has constructors for `int64_t` and
`std::string` and nothing else, so assigning a float to `ctx->settings[...]`
converts silently to an integer: 0.75 became 0.  Every other float setting in
`command.cc` wraps the value in `std::to_string` for exactly this reason, and
`--router2-smooth-weight` did not -- it had been truncating to an integer
since it was added, so any value below 1.0 was 0.  All four float settings now
go through `std::to_string`.

The density term, the occupancy map, the hot-tile selection, the criticality
and fanout guards, snapshot and restore, the accept/reject test, the legality
recovery and the before/after reporting are all in
`common/route/router2.cc`.  With the flag off the pass returns immediately and
the routed result is BIT-IDENTICAL to before the change -- verified on
vc707-johnson -- so nothing is at risk by default.

### Snapshot and restore

Step 5 of the design above is what makes the rest safe, and it is now in.

`snapshot_net()` copies the net's `wires` map (wire -> uphill pip, plus the
number of arcs sharing it) and each arc's `routed`/`pre_routed` flags.
`restore_net()` rips the net back to nothing, drains any residue through
`unbind_pip_internal()` so the per-wire congestion and per-resource counts
fall together, then re-binds each saved pip through `bind_pip_internal()` as
many times as it had arcs sharing it.  Going back in through the same two
functions that built the state is what keeps `curr_cong`, `net.resources` and
the global resource value counts consistent; restoring the maps by assignment
would not.

A net the search cannot rebuild is reported by `route_net()` with
`log_error()`, which *throws* (`log.cc:146`) rather than exiting.  Nothing
hangs off that throw -- `log_error_atexit` is never installed in this tree --
so the trial is wrapped in a `try`/`catch (log_execution_error_exception &)`,
`reset_wires()` clears the search's visit marks, and the snapshot goes back.
A move is also refused, and restored, when the net comes back with more pips
in hot tiles than it started with.

There is a second transaction around the whole pass: `snapshot_all()` before,
and if `bind_and_check_all()` will not take the smoothed result at the end,
everything reverts.  That matters because `bind_and_check()` rips up any arc
it cannot bind and records the net as failed, and by this point there is no
loop left to repair it.

### Two defects the safety net then exposed

Once failures were data instead of a crash, the numbers said what was wrong.
On the first run 13 of 13 johnson nets and 132 of 138 vc707-litex nets came
back unroutable -- a rate far too high to be real congestion.

1. **The pass routed with an empty bounding box.**  `smooth_congestion()` is
   handed the `ThreadContext` declared in `operator()`, whose `bb` is never
   set.  `BoundingBox` default-constructs to `(-1,-1,-1,-1)` and
   `thread_test_wire()` requires a wire to be inside it, so *every* wire in
   the fabric was rejected and the search could not expand at all.  The only
   arcs that routed were the ones whose two ends already met.  The
   single-threaded main loop sets its own context's bb to the whole device
   (`router2.cc:1566`); the pass now does the same.  That alone took johnson
   from 10 unroutable to 0 and vc707-litex from 132 to 0.

2. **Intra-slice arcs cannot be rebuilt** -- `SLICE_X1Y0.D5FF_Q` to
   `SLICE_X1Y0.D4` -- and they occupy no interconnect, so there is nothing to
   gain from trying.  `ad.bb` does not identify them:
   `getRouteBoundingBox()` adds a search margin, so even X79Y221 to X79Y221
   comes back as a box with area.  `PerWireData` already caches the tile each
   wire is in, and comparing those is exact.

Arcs the placer pre-bound are skipped too: `bind_and_check()` lets those break
the normal availability rules and `ripup_arc()` drops that privilege
irreversibly.  No johnson or vc707-litex arc is in that class, so that guard
is reasoned from the code rather than measured.

The Arch-level binding is also released for the duration of the pass.  The
search does not consult it -- `PerWireData` was fixed at setup -- but
`bind_and_check_all()` rips up and re-binds one net at a time, so a net whose
route moved can collide with a net it has not reached yet.  Clearing the lot
first removes that ordering hazard.

### Where it stands

    vc707-litex, defaults              p75 83, max 531, 41103 pips, 190.55 MHz
    aggressive (cap 1.0, min-wires 2,
    percentile 0.75, 8 rounds)         p75 82, max 525, 41122 pips, 190.55 MHz
                                       ~1570 candidates a round, ~1400 kept,
                                       ~170 rejected, 0 unroutable, 0 reverts

    vc707-johnson, aggressive          p75 3 -> 4, max 148, 899 -> 905 pips
                                       466.20 MHz unchanged at max-crit 0.8

The mechanism is sound: nets move in bulk, the accept/reject test rejects
about one in nine, nothing is ever left unroutable, the Arch always takes the
result, and timing is untouched.  The gain is small -- peak tile occupancy
-1.1%, mean -2.7%, at +0.05% total pips -- and fmax does not move.

### What the selection experiment established

Raising `cap` to 1.0 and dropping `min-wires` to 2 took the candidate list
from 138 nets to ~1570 and the mean occupancy down, but the peak did not
budge.  The peak-tile diagnostic says why:

    busiest tile X59Y218 holds 531 pips:
      79 eligible, 6 clock-driven, 412 high-fanout, 34 critical, 0 too-small

A fanout cap of 64 put 412 of 531 pips out of reach.  The cap was there as a
proxy for "do not touch clocks", and that proxy is simply wrong for this flow:
the only global buffer meaningfully supported is CLKG, which is on dedicated
routing and therefore does not appear in the tile occupancy at all, and the
driver-bel test catches it directly -- 6 pips in that tile, not 412.
Everything else with a large fanout is an ordinary signal on ordinary
interconnect, and it is what the crowded tiles are made of.  The cap is now
off by default and the same tile offers 491 eligible pips.

That is what let the peak move at all: 531 -> 525, all of it in round 1.
Rounds 2 through 6 hold at 525 with ~1400 nets re-routed each time, so the
tile is not merely preferred, it is needed -- which makes the remaining peak a
placement result, not a routing one.  A router pass cannot fix it.

Raising `max-crit` from 0.8 to 0.9 costs timing: vc707-johnson went 466.20 ->
431.97 MHz while its peak stayed at 148.  0.8 stays.

### What is still not demonstrated

That the pass is worth running.  It is safe, it does what it claims, and it
buys about one percent of peak density for no timing change and a little
runtime.  The next thing worth trying is not more aggression in the router --
that is now exhausted -- but feeding the occupancy map back into placement.
