# A measured interconnect delay matrix for the xilinx uarch

## The problem

Two functions guide place and route with an *estimate* of how long a
connection will take:

* `XilinxImpl::predictDelay()` -- bel pin to bel pin, before there is any
  routing.  It reaches the placer indirectly but really: it supplies the
  pre-routing delay to the timing analyser, which turns it into criticality,
  which weights the analytic solver at `placer_heap.cc:946`.
* `XilinxImpl::estimateDelay()` -- wire to wire, the router's A* guidance,
  weighted by `router2/estimateWeight` (1.25).

Both collapsed to one hand-tuned formula, ported from nextpnr-xilinx:

    30*min(dx,18) + 10*max(dx-18,0) + 60*min(dy,6) + 20*max(dy-6,0) + 300   (x1.5 for xc7)

It has one real structural insight -- the knees at dx=18 and dy=6, where the
per-tile cost drops from 30 to 10 and from 60 to 20, standing in for the long
lines -- and the 30-versus-60 anisotropy, vertical resources being scarcer at
short range.

Everything else about it is wrong for this fabric, in two specific ways:

* **It is separable**, so it charges a diagonal the sum of both legs.  The
  7-series INT tile has `BENTQUAD` and the bent doubles precisely so that a
  diagonal is reached in ONE hop.
* **It is linear**, so it charges two tiles twice what it charges one.  A
  `SINGLE`, a `DOUBLE` and a `QUAD` are each one hop whatever distance they
  span.  The resource classes are quantised where the formula is smooth.

The classification was never the problem: `SINGLE`, `DOUBLE`, `BENTQUAD`,
`HQUAD`, `VQUAD`, `HLONG`, `VLONG`, `VLONG12` are all present in the device
data (see `pack_clocking.cc:57-59`), and real per-pip delays with R and C come
from the interchange database, so `getPipDelay()` -- the router's *actual*
cost -- has always been right.  Only the estimates were guessing.  In
`estimateDelay()` the wire types were consulted for nothing but snapping an
endpoint coordinate to the pip's tile.

## What was done

`himbaechel/uarch/xilinx/delay_matrix.cc`.  Rather than guess a better shape,
measure it: a Dijkstra over the real routing graph, using the chipdb's per-pip
delays, records the cheapest delay at which a logic-tile input pin in each
surrounding tile is reached.  This is VPR's `place_delay_matrix` idea.

    -o delay-matrix=<file>     build the table (and cache it in <file>)
    -o delay-matrix=build      build it without caching

Three source bels near the middle of the device, at offsets deliberately not
multiples of the clock region height so they sit at different heights within
one, and the results are averaged.  Window +/-24 tiles.  Build cost is 2.4 s,
and the file reloads instantly on later runs.

Two things were needed beyond the measurement itself:

* **Structural holes.**  Only about one column in three carries CLBs, so a
  third of the table can never be measured: 1340 of 2401 offsets came back
  filled.  Leaving the rest to the formula mixed two incompatible scales in
  one function -- real picoseconds against tuned arbitrary units -- and an
  estimate that changes units from offset to offset is worse than either scale
  used consistently.  That first attempt dropped johnson from 466 MHz to 302.
  The holes are now interpolated from the nearest measured ring.
* **The out-of-window fallback** is multiplied by a scale fitted against the
  measured entries, so the estimate stays continuous at the window edge.  The
  fitted factor is 0.343 -- the tuned formula was about three times too large
  relative to real picoseconds.

## What the measurement says

Both predictions hold, and by a wide margin.

Diagonals cost about 60% of the sum of their legs, never the 100% the
separable formula charges:

    n   (n,0) east  (0,n) north  (n,n) diag  diag/sum
    1          201          227         204      0.48
    2          230          235         289      0.62
    4          257          324         339      0.58
    8          319          368         456      0.66
   12          340          486         582      0.70

Cost along +X is not even monotonic -- the steps run 51, 29, -3, 30, -17, 75,
0, 4, -4, -10, 28.  `dx=3` (227 ps) is cheaper than `dx=2` (230), `dx=5`
cheaper than `dx=4`, `dx=10` cheaper than `dx=8`.  Landing exactly where one
hop reaches beats a distance that needs two.  The formula charges a flat 45 ps
per tile throughout.

## Results

    vc707-johnson   routed fmax  466.20 -> 515.46 MHz   (+10.6%)
                    pre-route estimate  347.83 -> 545.85 against routed 515.46
                    (a 34% under-prediction becomes 6% over)

    vc707-litex     routed fmax  190.55 -> 197.20 MHz   (+3.5%)
                    pre-route estimate  118.95 -> 203.75 against routed 197.20
                    (a 60% under-prediction becomes 3% over)

    smpsd-ddr64-l2  main_crgddr_clkout_buf0  75.59 -> 89.39 MHz   (+18.3%)
    (the 1 GB SMP     still FAILs its 100 MHz target, but 24.4 MHz short
     open-flow build)  becomes 10.6 MHz short
                      eth_tx_clk  181.32 -> 200.72 MHz

That last one is the build whose `sys_clk` miss on hardware started this: the
estimate the placer was steering on was 60% pessimistic, so the placer was
spending its timing weight in the wrong places.  The measured table does not
make the design meet 100 MHz, but it closes more than half the gap without
any change to placement or routing algorithms.

The calibration improvement is the more interesting half.  A placer steering
on an estimate that is 60% pessimistic is optimising the wrong thing; the
timing weight it applies is derived from criticalities computed against that
estimate.

## Status and what is not yet established

Opt-in, via `-o delay-matrix=<file>`.  Two designs, both improved, is not
enough to flip the default -- a sweep over the CI matrix should come first,
and the table is per device, so every device in
`HIMBAECHEL_XILINX_DEVICES` wants its own measurement and a cached file
checked in or generated at build time.

Open questions worth an experiment each:

* The measurement takes the *minimum* delay over the graph, which is the
  congestion-free best case.  It is consistent everywhere, so it works as a
  relative guide, but a percentile of several routes might track reality
  better.
* Three sources near the centre.  Delays near the device edges, across the
  central clock spine, and across the SLR-like boundaries are not sampled.
* The window is 24.  Beyond it the scaled formula takes over, and long
  connections are exactly where the long lines make the formula least wrong --
  so this may matter less than it looks, but it is untested.
