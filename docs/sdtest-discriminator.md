# The minimal SD test as a discriminator

## What it settled

The same RTL — SDPHY + SDCore driven by a hardcoded FSM, 325 LUTs / 281 FFs —
built through Vivado and through yosys + nextpnr-himbaechel + fasm2frames, run
against the same card in the same slot.

**Both flows read a block.** LEDs `0x18` in each case: step 8 (CMD17), stop OK,
heartbeat running. The sequence CMD0 → CMD8 → CMD55 → ACMD41 → CMD2 → CMD3 →
CMD7 → CMD17 completes with no timeout, no CRC error and no data error.

So the open toolchain is not broken for SD. Whatever stops the SERV+LiteSDCard
SoC is above the I/O logic, not in it, and the day's ruled-out list (IN_DIFF,
ZSRVAL, DAT ZINV_T1, clock rate over a 128x sweep, coherent DMA, card, slot,
wiring, ILOGIC clock leaf) can stand without the toolchain hanging over it.

The last bug in the harness was not in the toolchain either. Jonathan's ILA
capture showed eight probe bits as `<const0>`: `cmd_event.status` and
`data_event.status`. `CSRStatus` keeps `.fields` and `.status` as separate
signals and only a SoC's CSR bank joins them, so outside a SoC `.status` is
never driven and synthesis folds it away. The FSM waited in `WAIT1` for a done
bit wired to nothing. Third LiteX-semantics bug in this harness, after the
skipped `phy.init.initialize` and the `.re`/`wr_stb` question — all silent.

## What it found in the LVS flow

At 325 LUTs the difference list is short enough to read, which is the whole
reason the design exists. It went 335 proved / 25 differ -> 347 / 13, and the
hard-block census from two blocks reported missing to all present. Four faults,
none of them in either bitstream:

1. **The OLOGIC's second register was never extracted.** The site holds an
   OUTFF on the data path and a TFF on the tristate path, and the synthesis
   spends a separate ODDR cell on each. Five bidirectional pads came out five
   cells short. `ODDR_TDDR.IN_USE` marks it but over-states — the SD clock is
   output-only and wears the bit — so the routing settles it: a real tristate
   has the fabric driving T1, which picks out exactly the five sites prjxray
   independently marks `ZINV_T1`.

2. **The FASM site index is the complement of the site's position in the tile.**
   nextpnr's `write_iol_config` spells it `1 - siteloc.y`. In
   `LIOI_TBYTESRC_X82Y8` the command pad sits at the LOWER site, `ILOGIC_X0Y7`,
   and both Vivado and nextpnr write its IDDR to `ILOGIC_Y1`. Extracting
   Vivado's own bitstream with `bit2fasm` settled it rather than either tool's
   intentions. Indexed straight, a tile with one half in use reports a hard
   block missing; a tile with both halves in use pairs each cell with its
   neighbour and says nothing at all.

3. **The DDR cut was never joined.** The extractor's comment said the two sides
   "cut the same primitive with the same port names, so the two cuts cancel",
   but nothing paired them — `IDDR`/`ODDR` were absent from `OPAQUE_OUT` and had
   no memory-map entry. Each side minted its own free variable for the same
   pin, so every cone downstream of a pad differed on the strength of a name:
   gold read `sdtest_sdpads_cmd_i` where the extraction read
   `LIOI_TBYTESRC_X82Y8_IOI_ILOGIC1_Q1`. `--explain` is what made it visible.

4. **A pin a DDR register drives also carried the bypass past it.** The database
   declares the output bypass as a hardwired pseudo-PIP and it was applied to
   every site, register or not, leaving the OQ net with two drivers. Suppressing
   the emission was not enough — the pseudo-PIP is in the assign list before the
   I/O pass runs, so the stale one has to be removed.

`vc707-litex` still proves 2820/0 and the other ten designs are unchanged.

## Still open

Thirteen differences remain, all one cluster: `sdtest_init_wait[3..15]`, the
16-bit PHY-init delay counter. For bit N the extracted cone omits bits 0..N-1 —
the carry dependency is lost — while bit 2, the bottom of the same CARRY4 at
`CLBLM_R_X31Y58`, proves.

Traced so far, and all of it looks right: the chain is wired A -> B -> C -> D
with `PRECYINIT.AX`; column A has `A6 = VCC`, `A3 = AQ` (bit 2) and `A1 = GND`,
giving `CO_A = init_wait[2] & AX`; `AX` comes from `CLBLM_R_X31Y55_CLBLM_M_CMUX`
via `COUTMUX.XOR`, and that column is emitted with `OUTMUX("XOR")` driving its
MUX port. So the structure carries the dependency at every step checked, which
is not yet consistent with what the cone comparison reports. Unresolved.

One caution for whoever picks this up: `grep 'assign X ='` does not find a net
driven by an instance PORT, and reading that as "no driver" sends you looking
for a missing driver that is not missing. Both counting mistakes made here were
of that kind — the other was `grep -o` counting a module name and an instance
name of the same spelling as two cells.
