# The SD card through the open flow

State as of 2026-09-08.  Two real nextpnr defects found and fixed; the
command path now works; the data path does not.

## What works now

The open-flow bitstream drives the SD command path correctly.  Driven by
hand through the BIOS with the sdc/sdst/sdblk commands added for this:

    sdc 0 0 0        evt=01
    sdc 8 0x1aa 5    evt=01  r0=0x000001aa     check pattern echoed
    sdc 55 0 5       evt=01  r0=0x00000120
    sdc 41 0x40100000 1  evt=01  r0=0x40ff8000  ready, high-capacity

That is the card powering up and negotiating.  Before the fixes the core
never transacted at all: the event register read DONE before any command
was issued and the response was always zero.

## The two defects, both in fasm.cc

**Tile-type name.**  xlnx_build_pseudo_pip_config registered the left I/O
column as LIOI3*, but Virtex-7 names those tiles LIOI*.  The right column
escaped because it had its own is_virtex7-aware block registering RIOI*.
So DDR3 on RIOI_X311* worked and SD on LIOI_X82* got nothing.  The
failure is silent in the worst way: the router still uses the pseudo-pip
and the OLOGIC configuration that must accompany it is never emitted.

**Tristate inversion unreachable under router2.**  ZINV_T1 came only from
a pseudo-pip that fires when the route crosses OLOGIC's T1->TQ transit as
a tile pip -- how DDR3 reaches the right column.  With router2 and a
plain tristate buffer that transit is internal to the bel, so no pip is
emitted.  The one handler that would catch it is router1-only by its own
comment.  Registering the pad-side pip, LIOI_T<i> <- LIOI_OLOGIC<i>_TQ,
reproduces exactly the ZINV_T1 set bit2fasm extracts from Vivado,
including only Y1 of the TBYTESRC tile.

Both were Jonathan's suggestion to handle the two columns with one
pattern; the split maintenance is what allowed them.

## What is still broken

sdcard_init fails with dataevt=05, a DATA timeout, where Vivado on the
identical design reaches "Initialize SDCard: OK" and negotiates 4-bit.
The failure is in the data phase -- ACMD51 SEND_SCR, the first transfer
over the DAT lines -- which matches the SMP build stalling at CMD51.

## Ruled out by experiment, not by argument

  IN_DIFF (bit 38_126)   three separate builds, including after the
                         command path started working
  ZSRVAL on the SD ILOGIC  removed, no change
  ZINV_T1 on the DAT pins  removed, no change (kept on CMD)
  clock rate             fails identically at 12.5 MHz, 1 MHz, 390 kHz
                         and 98 kHz -- a 12x margin does not mask it
  coherent DMA           works without it; the driver's requirement is
                         overstated, dma_alloc_coherent suffices
  card, slot, wiring     Vivado drives the same card on the same pins

The remaining FASM delta on the SD tiles is IN_DIFF and the card-detect
tile.  Detect carries no signal at all -- sdcard_detect reports inserted
with the card removed, in both flows -- so that difference is moot.

## Where to look next

The pads are now configured equivalently to Vivado and the data path
still fails, so the fault is most likely in the fabric rather than the
I/O: the LiteSDCard core's data path or its DMA, i.e. synthesis or
placement of the core rather than the pins.

The principled next step is this repository's own equivalence machinery.
fasm2netlist can extract the netlist back out of the bitstream and the
LVS pass can prove it against the synthesis it came from.  If the
extracted core differs from the netlist, that finds it directly instead
of by bisecting configuration bits.

A caveat on the SERV target: Vivado reaches init OK on it but then gets
FatFs error 1 on mount, where the VexRiscv Vivado build reads the same
card perfectly.  The bit-serial CPU is probably too slow to service the
core.  So this design validates the init path but not sustained reads.

## Driving the board

scripts are in the scratchpad; the console is /dev/ttyUSB2 at 115200.
The BIOS line editor on a 25 MHz SERV drops characters if a whole line
arrives at once -- send one token at a time with a pause between them.
