# The mczerski SD controller as a discriminator

Vendored at rtl-deps/sd-card-controller (submodule, LGPL v2.1+, originally
from opencores.org).  Built with `make vc707-serv-sdc`, flashed with
`make vc707-serv-sdc-flash`.

## Why it is here

LiteSDCard captures CMD and DAT with IDDR primitives at the pad.
fasm2netlist's tile model handles ILOGIC only as a bypass and skips
anything else -- verify-extraction on the LiteSDCard design reports "10
doing more than a wire (not modelled)" and then 1275 register differences
that say nothing, where the same SoC without the card proves 2820 with
zero.  So the proof cannot see the SD data path at all.

This core samples with a plain fabric flip-flop and exposes the pads
split into in/out/oe, so the tristate is instantiated in our wrapper.
The synthesised design confirms it: zero IDDR, zero ODDR, five plain
IOBUFs.  Every ILOGIC stays a bypass, which the tile model does cover.

## What is working

  - generation, synthesis and place-and-route through the open flow
  - check-fasm passes: every feature resolves against virtex7
  - nextpnr recognises the core's fabric-divided sd_clk_o as its own
    clock domain and closes it at 122 MHz against 12 required; sys_clk
    closes at 116 MHz against 25
  - the SoC boots and the Wishbone slave works: clock_divider written and
    read back correctly at 0xb0000024
  - CMD0 completes (cmd_isr bit 0, command-complete, no error bits)

## What is not working yet

CMD8 returns cmd_isr 0x06 -- INT_CMD_EI | INT_CMD_CTE, a command timeout
-- where LiteSDCard on the same board and card answers with 0x1AA.  After
a software reset even CMD0 stops completing.

Do not read that as a discriminator result yet.  The register sequence
used was reconstructed from sd_defines.h rather than from the core's own
specification, and the reset behaviour in particular was guessed.  The
spec ships in the tree -- doc/src/sw_if.tex and the PDF beside it -- and
documents the reset register, the clock divider semantics and the
required initialisation order.  Following it is the next step, and a
bounded one.

## Register map, from sd_defines.h, at base 0xb0000000

    0x00 argument      0x1c control        0x40 data_event_enable
    0x04 command       0x20 cmd_timeout    0x44 block_size
    0x08 resp0         0x24 clock_divider  0x48 block_count
    0x0c resp1         0x28 reset          0x60 dst_src_addr
    0x10 resp2         0x2c voltage
    0x14 resp3         0x30 capabilities
    0x18 data_timeout  0x34 cmd_event_status
                       0x38 cmd_event_enable
                       0x3c data_event_status

command register: [13:8] index, [6:5] with-data (01 read, 10 write),
[4] index check, [3] CRC check, [2] busy check, [1:0] response
(0 none, 1 = 48-bit, 2 = 136-bit).

cmd_event_status bits: 0 complete, 1 error, 2 timeout, 3 CRC error,
4 index error.

## The point of the exercise

Once it drives the card, two outcomes and both are informative.  If it
works where LiteSDCard does not, the fault is specific to the IDDR
capture path.  If it fails the same way, the fault is shared -- the pads,
the clocking or the Wishbone side -- and either way verify-extraction can
now localise it, because nothing in this design is unmodelled.
