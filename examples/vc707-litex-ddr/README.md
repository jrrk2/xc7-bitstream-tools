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

## The open flow: it works (2026-09-06)

It routes, calibrates against the SODIMM and passes `memtest`.

    Build your hardware, with nextpnr
    CPU:    SERV @ 100MHz
    SDRAM:  512.0MiB 32-bit @ 800MT/s (CL-6 CWL-5)
    Write leveling / latency calibration / read leveling ... all converge
    Memtest at 0x40000000 (2.0MiB)...  Memtest OK

The PHY was expected to be the hard part and was not. Two assumptions were
wrong. At the `nphases=4` this board uses, V7DDRPHY instantiates no PHASER, no
PHY_CONTROL and no IN/OUT_FIFO -- only `IDELAYE2`, `ODELAYE2`, `ISERDESE2`,
`OSERDESE2` and one `IDELAYCTRL`, every one of which already had a FASM writer.
And the Ethernet variant's routing failure, which had masked this, was in a
clock net belonging to the SGMII PHY; without it the design routes.

What makes the result trustworthy is not that it booted but that it agrees with
Vivado's build of the same gateware, tap for tap:

| | Vivado | open flow |
| --- | --- | --- |
| Write latency | `m0:6 m1:6 m2:6 m3:6` | identical |
| Write DQ-DQS | 03+-03, 03+-03, 02+-02, 03+-03 | 03+-03, 02+-02, 02+-02, 03+-03 |
| Read leveling | best `b03` on all four | best `b03` on all four |
| Memtest | OK | OK |

Two independently produced bitstreams converging on the same physical delays is
a much stronger statement than "it ran".

## Which CPU

`LITEX_CPU` selects it, and the DDR3 controller is untouched by the choice --
both variants instantiate exactly 32 `IDELAYE2`, 32 `ISERDESE2`, 67 `ODELAYE2`
and 67 `OSERDESE2`:

    make vc707-litex-ddr-vivado LITEX_CPU=vexriscv

VexRiscv needs `litex-deps/pythondata-cpu-vexriscv`, vendored as a submodule
beside SERV's. It costs about a third more fabric (4093 FFs against 3026, 2267
LUT5s against 1577) and buys a great deal:

| | SERV | VexRiscv |
| --- | --- | --- |
| Memtest | OK | OK |
| Memspeed write / read | 3.6 / 3.8 MiB/s | **61.7 / 64.3 MiB/s** |
| SDRAM calibration | 51 s | 1.3 s |
| Power-on to console | 80.6 s | 15.9 s |

That 17x is worth reading carefully: SERV and Vivado's build of the same SoC
report *identical* 3.6/3.8 MiB/s, which says the figure was never the memory.
It is the bit-serial CPU's copy loop. Changing the CPU moves the ceiling; the
DDR3 was never near its own.

It also serves as an independence check on the PHY work -- the same
configuration calibrates correctly inside a design with a third more registers
and an entirely different floorplan, so the first result was not an artefact of
one lucky placement.

## Still not proved by LVS

`lvs_equiv` models neither `IDELAYE2` in a data path nor the serialisers, so it
cannot prove this design, and the extraction does not cover the PHY. That is
why the comparison above is against a golden bitstream rather than against a
netlist: on this device LVS has certified a design at 2820 proved / 0 differ
while it drove every signal onto the wrong package pin.
