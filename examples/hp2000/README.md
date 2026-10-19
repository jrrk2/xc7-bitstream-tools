# HP 2000F Time-Shared BASIC (1974) on the VC707

HP's 1974 2000F TSB, rebuilt from the original sources: the two HP 2100 CPUs and their I/O as
Verilog (`rtl/`), wrapped as a LiteX SoC (`litex/`) whose BIOS serves the machine's 32 terminal
lines over telnet (`firmware/`). It is the exact `vexriscv_smp` / DDR3-1GB / ethmin / SD SoC that
`vc707-litex-ddr-ethmin-smpsd-1gb` builds, plus the `--with-hp2000` module.

This directory holds only what a **bitstream build** needs. The rest of the project — the C
emulator, the disc-image/`sysgen` tooling, the hardware history — lives in `~/hp2000` (see its
`PLAN.md`).

## Building

    make vc707-hp2000

runs the open flow end to end: it fetches and assembles the HP-source-derived ROM assets
(`make -C examples/hp2000 bios-assets`), regenerates the LiteX gateware, then synthesises and
places-and-routes with the pinned yosys and `nextpnr-himbaechel`. The result is
`hp2000_vc707.bit`.

## HP sources

The bitstream's ROM embeds the IOP program and the system tape, assembled from HP's 1974 sources.
Those are Hewlett-Packard copyright and are **not in this repository** — `tools/fetch_sources.sh`
downloads the pinned Bitsavers tarball on first build (like `scripts/prjxray_db.sh` does for the
database), and `src/` is git-ignored.

## Notes

* The machine runs in its own 20 MHz `hp` clock domain beside the 100 MHz sys domain; the FP/DIV
  paths are long and combinational. `vc707-hp2000` passes `--timing-allow-fail` for now — the
  build is "does it still come up", not "does it meet timing", until the two-clock design has been
  tuned like the single-domain `smpsd-1gb` one was.
