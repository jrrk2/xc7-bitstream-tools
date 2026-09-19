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
16-bit PHY-init delay counter. The mechanism is now known, and most of it is
fixed.

`LVS_SUPPORT_OF` shows what each side reads in full rather than only the
difference, and for `init_wait[3]` it said:

```
gold reads (10): fsm_state[0..4] init_wait[0] init_wait[1] init_wait[2] init_wait[3] sys_rst
gate reads  (7): fsm_state[0..4]                           init_wait[3] sys_rst
```

The extracted cone had lost the carry entirely. Not because the extraction is
wrong -- walking the netlist by hand gives
`init_wait[3] ^ (init_wait[2] & init_wait[1] & ...)`, a correct incrementer --
but because **the checker had replaced the carry with a constant 0 and said
nothing about it**.

A column holds two functions over the same five pins. The router feeds a pin
because the O6 half wants it; the O5 half is then wired to a signal it ignores.
The cone builder evaluated all six inputs before consulting the truth table, so
it walked a path the logic does not have, and that path closed a ring. It
called the ring a combinational loop and broke it with a constant -- and a
constant is indistinguishable from a real zero once it is in the network.

Two fixes: descend only into inputs the truth table actually depends on, over a
reduced table; and report every loop that still gets broken, both as a warning
naming the cycle and as a line beside the verdict. The second matters as much
as the first: `vc707-gatedcount` proved 27/0 while silently breaking two loops.
A proof from such a run is conditional on those paths, and it was not saying so.

`examples/vc707-gatedcount` is that reduced case -- 27 registers rather than
347, and it still proves, which is exactly why it is worth keeping.

What is left is a single nine-node ring on `vc707-sdtest`:

```
CMUX(Y55) -> CO_B,CO_A(Y55) -> Y57_M_A(LUT) -> AMUX(Y59)
          -> CO_D..CO_A(Y58) -> back to CMUX(Y55)
```

Every edge checks out: the pips are in the FASM, Y59 takes `PRECYINIT.CIN`
from Y58, and Y57's LUT genuinely depends on the input that closes it
(`INIT=0f0f0f0faaaa00aa`, reached through a `BYP_BOUNCE`). So it is either a
real ring in nextpnr's routing -- which the board disproves, since the design
reads a block -- or an extraction fault further up that ring. Unresolved, but
visible now rather than silent, and reduced to nine named nets.

## Cautions for whoever picks this up

Three mistakes made here, all of the same kind -- a tool answering a slightly
different question than the one asked:

- `grep -o` counts a module name and a same-spelled instance name as two cells.
  That is what made 5 IDDRs look like 6.
- `grep 'assign X ='` does not find a net driven by an instance PORT, or one
  tied by `wire X = 1'b0;`. Reading either as "no driver" sends you hunting for
  a missing driver that is not missing.
- A non-greedy regex spanning `xcol #(...) \NAME (...)` will happily start at
  an earlier instance's header and report another cell's parameters. It said
  `OUTMUX=none` where the FASM plainly said `COUTMUX.XOR`. Parse by finding the
  instance and walking back to its own header.

When the netlist and the checker disagree, instrument the checker. Hand-tracing
established the netlist was right four separate times without ever explaining
the difference; a six-line warning found it immediately.
