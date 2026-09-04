# A LiteX SoC on the VC707

A minimal LiteX SoC — SERV CPU, block-RAM ROM/SRAM/main RAM, UART, LED chaser —
ported from openXC7's `demo-projects/litex-minimal-arty-s7`, plus an optional
LiteEth SGMII Ethernet PHY.

It exists to give the extraction something real to chew on. The Johnson counter
this repository started from is 27 LUTs and 36 flip-flops; this is a SoC with a
BIOS in block RAM, a register file in distributed RAM and carry chains
everywhere, and it runs on the board.

## What it proves

Built through the open flow (yosys → nextpnr-himbaechel → prjxray) and
extracted with `fasm2netlist`, graded against nextpnr's own placement dump:

| | placed | extracted |
| --- | --- | --- |
| CARRY4 | 65 | 65 |
| RAMB18E1 | 11 | 11 |
| RAMB36E1 | 6 | 6 |
| flip-flops | 688 | 688 |
| fabric sites | 371 | 371 recovered |
| ROM/RAM contents | 729 non-zero rows | 729, none lost |

That last row is the whole 23 KB BIOS image, read back out of block-RAM INIT
rows — the bitstream really does round-trip to a netlist and back.

## Equivalence, and which toolchain it was proved with

The SoC is also proved equal to its own synthesis: every register matched from
the placement, every memory cut at its boundary and that boundary discharged,
and every remaining cone shown equivalent by SAT.

    2820 proved, 0 differ

It is a proving example in `scripts/verify_examples.sh`, so CI fails if that
stops being true.

That result is a statement about one synthesis, and **which yosys built it
matters** — two versions do not produce the same netlist, so they do not pose
the same question. This is why yosys is pinned as a submodule and built from
source rather than installed:

| yosys | outcome |
| --- | --- |
| **0.63+173 (`66306a8ca`) — the pinned one** | 2820 proved, **0 differ** |
| 0.64 (`8449dd470`, the-openroad-project) | 2784 proved, 36 differ |
| 0.27+22 (`0f5e7c244`, f4pga conda) | nextpnr cannot place its netlist |

The differences under 0.64 are concentrated in the SERV register file and the
CSR block — a distributed-RAM read address the fabric computes and the
synthesis does not — and are not yet understood. They are a fault in the model
or in that netlist, not a regression: the same toolchain showed 126 before the
block-RAM work.

`scripts/verify_examples.sh` prints the yosys and nextpnr versions it used, and
writes them beside each design's artefacts in `toolchain`, so a result can be
compared with the run that produced it rather than guessed at.

Build the pinned yosys with `make yosys`; the sweep picks it up automatically
if it is there, and falls back to whatever is on `PATH` if it is not.

Both flows produce a bitstream that boots on the board. They are built from
identical gateware, so each announces itself in the BIOS banner:

    Build your hardware, with nextpnr        (openXC7)
    Build your hardware, with Vivado         (Vivado 2020.1)

## Two things copied deliberately, not chosen

Both come from `vc707-openflow-demos`' ethmin (`clkgen_vc707.sv`), which is
proven on this board in both flows:

- **25 MHz, from a raw `MMCME2_ADV`** rather than LiteX's `S7MMCM`: 200 MHz ×5
  to a 1 GHz VCO, `CLKOUT0_DIVIDE_F=40`. The open flow has no proper hold STA
  and does not reliably close 50 MHz.
- **Reset from MMCM `LOCKED`, not from CPU_RESET.** That input's IOB (AV40,
  single-ended LVCMOS18) is marginal on the open flow — its ILOGIC `ZINV_D` is
  a gap in the prjxray database — so gating reset on it holds the SoC down.

There is no DDR3: the V7DDRPHY's IDELAY/ISERDES are outside what the
extraction models, and integrated block RAM is the more useful test anyway.

## Building

    ../../.venv/bin/pip install -e ../../litex-deps/*   # once

    PATH=../../.venv/bin:$PATH ../../.venv/bin/python ./vc707_litex.py \
        --with-led-chaser --cpu-type serv --integrated-main-ram-size 0x4000 \
        --flow openXC7 --no-compile-gateware --build --output-dir build-openXC7

Then synthesise the sources listed in the generated `.tcl` with yosys, place
with `nextpnr-himbaechel --device xc7vx485tffg1761-2`, and turn the FASM into a
bitstream with `scripts/convert.py`. `--flow vivado` plus the generated
`xilinx_vc707.tcl` gives the Vivado build.

## Patches

Three small changes are needed in the submodules. They are already in the
commits this repository pins -- `litex-deps/litex` and `litex-deps/liteeth`
point at forks carrying them, and the nextpnr one is on `openXC7/nextpnr`
itself -- so a recursive clone gets them and there is nothing to apply. The
patch files are kept only so the changes can be offered upstream; all three
are small and none is a workaround.

| patch | why |
| --- | --- |
| `litex-bios-configurable-tagline` | the BIOS banner tagline is hard-coded, so two bitstreams built from the same gateware are indistinguishable on the board |
| `liteeth-k7-1000basex-125mhz-refclk` | `K7_1000BASEX` accepts a `refclk_freq` argument and then hard-codes 200 MHz; the VC707's SGMIICLK is 125 MHz, which the CPLL solves fine |
| `nextpnr-ibufds-gte2-toplevel-pin` | `pins.cc` lists `IBUFDS_GTE3`/`GTE4` as top-level pin consumers but not `IBUFDS_GTE2`, so a 7-series GT reference clock from a pad is rejected before `pack_io.cc` -- which handles it -- is ever reached |

## Ethernet: generated, implements, not yet placeable by nextpnr

`--with-ethernet` adds LiteEth's open 1000BASE-X/SGMII PCS driving the GTXE2,
in ethmin's configuration (`K7_1000BASEX`, `sys_clk_freq=25e6`,
`refclk_freq=125e6` on SGMIICLK AH8/AH7). It roughly doubles the design and is
much the better test — `RAM32M` goes from 4 to 24, `CARRY4` from 62 to 155.

Vivado implements it: WNS +1.560 ns, 0 failing of 4568 endpoints, 3276/3276
nets routed, no critical warnings.

nextpnr cannot place it yet. With the `IBUFDS_GTE2` patch above it gets one
step further and then stops at

    ERROR: failed to find IBUFDS_GTE2 site for pad '.../IPAD_X0Y0.PAD'

`examples/vc707-gtrefclk` is that failure in forty lines of Verilog, and
`scripts/verify_examples.sh` runs it every time so the maintainer can see
whether it is still blocked, blocked on something new, or fixed.
