# HP 2000F on the VC707 (LiteX)

`hp2000_vc707.py` extends the `vc707-litex-linux-1gb` configuration (same flags) with the HP 2000 machine
(`../rtl`, wrapped by `hp2000.py`) and BIOS commands (`../firmware/cmd_hp2000.c`).  `make litex` generates the
SoC and builds the BIOS; the bitstream flow is the template's (yosys/nextpnr or Vivado on the generated sources).

* HP window: Wishbone slave at 0xa0000000 (word address bit 15 = core, 14:0 = HP word) — front-panel examine/deposit and image loading.
* Disc and tape images: DDR3 at main_ram + 0x30000000 (disc at +0, tape at +64 MB), big-endian words, i.e. the
  file byte order, so a TFTP transfer lands them directly. The machine's disc/tape controllers are Wishbone masters.
* BIOS: `hp_load hp_disc hp_disc_blank hp_disc_save hp_tape hp_tape_blank hp_tape_rw hp_tape_save hp_ex hp_dep hp_setp hp_run
  hp_status hp_reset hp_type hp_console hp_cold hp_sysgen`.  Operator console = BIOS UART; terminal lines = telnet port 23 served by the BIOS (hp_standalone; the UDP tunnel was retired),
* Stage the files with `make tftp-stage`, copy `build/tftp-hp2000` to the TFTP root as `hp2000/`, then at the BIOS prompt:
  `hp_cold` (boot the saved system) or `hp_sysgen` (generate one from the tape held in ROM).

Vivado 2020.1 (`--flow vivado`, run from `make litex`'s command with `--build` and no `--no-compile-gateware`) builds a
bitstream that MEETS TIMING: WNS +0.283 ns at 100 MHz (sys), +1.561 ns in the 20 MHz `hp` domain (the machine), WHS +0.034 ns;
109 BRAM36 tiles, 19 DSP. First attempts failed in turn: BRAM inference (core memories, disc sector buffer), mux baud divide
(-34 ns), CPU FP/DIV paths (-27 ns, fixed by the 20 MHz domain), a duplicate reset driver. Not yet loaded on the board.

Earlier status: gateware and BIOS generate and compile (BIOS ROM 64 KiB of 128 KiB); yosys synthesises the machine alone
(≈56k LUT, 8k CARRY4, 35 DSP, 61 RAMB36). Not yet run through place-and-route, timing, or on the board; no host UDP bridge
script exists yet; the BIOS commands are untested on hardware.
