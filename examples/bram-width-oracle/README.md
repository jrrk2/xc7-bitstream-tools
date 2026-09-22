# RAMB36E1 port widths: Vivado's bitstream as the oracle

*2026-09-22.*  A RAMB36E1 port 1 or 9 bits wide does not halve evenly
between the two RAMB18s, and nextpnr's FASM writer encodes those widths
as each half at 1 (or 4) plus the tile-level `RAMB36.BRAM36_*_WIDTH_*_1`
bit.  Width 1 was proven on hardware when the processor's 32K x 1
memories were fixed; width 9 was the same guess, taken from prjxray's
fuzzer 027, and had no hardware or oracle behind it -- the design that
motivated the fix keeps its packet lanes' ninth bit in RAMB18s, which
carry their own `_9` markers.

`bram9.v` instantiates one RAMB36E1 each at widths 1, 4, 9 and 18 on
both ports, with every output reaching an LED.  `build.tcl` builds it with
Vivado (`vivado -mode batch -source build.tcl`); `bit2fasm` on
`out/bram9.bit` and the open flow's FASM of the same design (yosys
`synth_xilinx`, nextpnr) then compare per instance:

| width | RAMB18 halves | tile-level bit | Vivado | nextpnr |
|---|---|---|---|---|
| 1  | `*_WIDTH_*_1` each | `BRAM36_*_WIDTH_*_1` all four | yes | yes |
| 4  | `*_WIDTH_*_2` each | none | yes | yes |
| 9  | `*_WIDTH_*_4` each | `BRAM36_*_WIDTH_*_1` all four | yes | yes |
| 18 | `*_WIDTH_*_9` each | none | yes | yes |

Identical for all four widths, and bit2fasm names every bit of Vivado's
BRAM tiles (no unknown bits), so the database's width features need no
re-fuzzing.  The only other difference is `ZINV_ENBWREN`, which nextpnr
writes and Vivado does not on the instances whose B port is unused -- an
unused port either way.
