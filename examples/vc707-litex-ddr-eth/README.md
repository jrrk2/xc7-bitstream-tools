# The LiteX SoC with DDR3 and LiteEth — the full-feature triage

The SERV SoC with *both* the DDR3 SODIMM (V7DDRPHY) and LiteEth's
1000BASE-X/SGMII PCS on the GTX transceiver. 28256 lines of gateware, against
21101 for DDR3 alone, 9088 for LiteEth alone and 1933 for neither.

All four variants come from one generator, `examples/vc707-litex/vc707_litex.py`,
with composable `--with-ddr` / `--with-ethernet` flags. That is deliberate: three
separately-maintained scripts would drift, and a triage whose variants differ in
ways nobody intended proves nothing.

## Status: works on hardware, through Vivado

Built with `make vc707-litex-ddr-eth-vivado` and flashed on 2026-09-05. Timing
met, 0 errors, 0 critical warnings, 9550/9550 nets fully routed. It configures
(`done 1`) and boots:

* **UART** — full BIOS banner, `BIOS CRC passed`, console prompt reached.
* **DDR3** — write levelling, write DQ-DQS training and read levelling all
  converge (`best: m0..m3, b03`), `Memtest OK`, 512 MiB 32-bit @ 800 MT/s
  (CL-6 CWL-5).
* **Ethernet** — `Local IP: 192.168.1.50`, answering both ARP (6/6, ~0.7 ms)
  and ICMP (4/4, 0% loss) from the host.

The one failure in the boot log is not one:

    Booting from network...  Remote IP: 192.168.1.100
    ARP failed

That is the SoC looking for a TFTP server at LiteX's default remote address,
which does not exist on this network. It falls through to the console prompt,
which is the expected outcome with no boot medium.

A caution when reading a *failed* DDR triage: `--with-ddr` moves three things at
once. V7DDRPHY needs `sys4x` and a 200 MHz IDELAYCTRL reference, so the DDR
variants use LiteX's `S7MMCM` rather than the hand-written single-output
`MMCME2_ADV`; reset moves from self-boot on MMCM lock to the CPU_RESET button;
and the system clock goes 25 -> 100 MHz. Three suspects stand before the memory
controller itself. See `_CRGDDR` in the generator.

The DDR builds also carry

    set_property BITSTREAM.STARTUP.MATCH_CYCLE NoWait [current_design]

because the SSTL15_T_DCI pins otherwise leave Vivado's startup sequence waiting
for DCI match: the bitstream loads with no CRC error and the FPGA sits in
startup state 3 with `DONE` low, so nothing runs. With it, `done 1`.

## Why this matters to the open flow

This is the golden reference the open flow is graded against. The open flow
cannot build this design yet — it cannot route the transceiver's clock (see
`../vc707-litex-eth/README.md`) — but a Vivado bitstream that demonstrably works
turns "our build is broken" into "our build differs from one that works, here",
which `prjxray/utils/bit2fasm.py` can answer feature by feature. That comparison
is what found the inverted `IOB_Y` half that had every VC707 signal driven onto
the wrong package pin; it is also the only way to check GTX, MMCM and
IDELAY/ISERDES *configuration*, which LVS does not model and cannot see.

## Building

```sh
make vc707-litex-ddr-eth-vivado         # -> build-vivado/gateware/xilinx_vc707.bit
make vc707-litex-ddr-eth-flash-vivado   # OFL=... if openFPGALoader is not on PATH
```
