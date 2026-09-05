# A LiteX SoC on the VC707, with DDR3

The deliberate opposite of `examples/vc707-litex`. That one has **no** DDR3 —
it runs from block RAM so the ROM and RAM contents have to come back out of the
bitstream, and because the DDR PHY's IDELAY/ISERDES/OSERDES are not something
the extraction models. Here the memory controller **is** the point.

|  | vc707-litex | vc707-litex-ddr |
| --- | --- | --- |
| gateware | 1933 lines | 21101 lines |
| `IDELAYE2` | 0 | 128 |
| `ISERDESE2` | 0 | 128 |
| `OSERDESE2` | 0 | 268 |
| `IDELAYCTRL` | 0 | 4 |
| main memory | block RAM | 1 GB DDR3 SODIMM (MT8JTF12864) |

It follows litex-boards' own `xilinx_vc707` target closely — the same S7MMCM
CRG (sys, sys4x, idelay at 200 MHz), the same `S7IDELAYCTRL`, the same
`V7DDRPHY` on the same SODIMM — with two deliberate differences, both recorded
at the top of `vc707_litex_ddr.py`: no PCIe (the upstream target imports
`litepcie` at module scope, which this design never instantiates), and 100 MHz
rather than 125.

## Vivado first, deliberately

This is built with Vivado before the open flow is asked the same question, so
that "does the design work" and "does the open flow reproduce it" stay separate
questions. A DDR3 controller is the wrong place to be debugging both at once:
the PHY calibrates against real silicon timing, and a board that fails to train
tells you nothing about which half is at fault.

    make vc707-litex-ddr-gen        # regenerate the gateware (needs the LiteX venv)
    make vc707-litex-ddr-vivado     # build it with Vivado

The BIOS banner names the flow, so two bitstreams built from identical gateware
can be told apart on the board — the same trick the sibling example uses. What
to look for on the console is the memory test: a working DDR3 reports its size
and passes `memtest`, and that is the thing block RAM cannot tell you.

## The open flow: not attempted yet

The extraction models neither `IDELAYE2` in a data path, `ISERDESE2` nor
`OSERDESE2`, so this design is a long way past what `lvs_equiv` can currently
prove — and the PHY's calibration makes it a hardware question as much as a
netlist one. It is here as the next target, with a golden Vivado bitstream to
compare against, not as something that works today.
