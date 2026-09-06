# Linux on the VC707, through the open flow

An MMU-capable RISC-V running Linux to a shell, on a bitstream built entirely
by yosys, nextpnr-himbaechel and prjxray.  The kernel arrives over the board's
gigabit transceiver.

    Build your hardware, with nextpnr
    CPU:    VexRiscv_Linux @ 100MHz
    SDRAM:  512.0MiB 32-bit @ 800MT/s (CL-6 CWL-5)
    Memtest OK
    [    2.602300] f0004000.serial: ttyLXU0 at MMIO 0xf0004000 ... is a liteuart
    root@buildroot:~#

## The three pieces, and why each is here

**The SoC** is `../vc707-litex/vc707_litex.py --cpu-variant linux --with-ddr
--with-ethmin-phy`.  The Linux variant needs one thing a stock LiteX SoC does
not build: `self.cpu.add_timer()`.  LiteX's `VexRiscvTimer` is only
instantiated when the CPU is constructed with `with_timer=True`, and nothing
in the standard path does that -- so without it the SoC has no `cpu_timer`
CSR, the machine-mode software polls a register that is not there, Linux never
receives a timer interrupt, and the boot stops dead after "Executing booted
program" with nothing on the console.  In the log above it shows up as
`sched_clock: 64 bits at 100MHz`.

**The emulator** (`emulator/`) is the machine-mode software that provides SBI.
It was recovered from linux-on-litex-vexriscv at `382fe2a^`, the commit before
that project moved to vexriscv_smp and OpenSBI -- which our SoC cannot use,
because that OpenSBI platform expects a CLINT at 0xF0010000 and a PLIC at
0xf0c00000 and we have neither.

Do not patch its addresses.  It `#include`s `generated/csr.h`, so building it
against a SoC's own build directory gives the right UART and timer addresses
for that SoC.  Five changes were needed to build 2020 sources against 2026
LiteX, all in place here:

  * link through `$(CC)`, not `$(LD)` -- LDFLAGS now carry `-mabi=ilp32`
  * build `crt0` from `$(CPU_DIRECTORY)`; libbase no longer ships `crt0.o`
  * declare the `emulator` memory region the old SoCLinux used to add
  * add `.preinit_array`/`.init_array`/`.fini_array`; `startup.c` needs them
  * `--allow-multiple-definition`, so the emulator's minimal `isr` wins over
    libbase's (ours is listed first)

and one behavioural fix: `litex_putchar` dropped `'\r'` and added none, so
every line after the first began where the last ended.  It now synthesises a
CR before each LF.

**The device tree** (`rv32.dts`) describes memory and the UART.  Both come
from the SoC's own `csr.json` -- the UART is at `0xf0004000` here, and adding
the CPU timer shifts every CSR bank, so regenerate rather than assume.
`linux,initrd-end` must be `initrd-start + the actual size of rootfs.cpio`:
rounding it up leaves the kernel reading past the archive and reporting
"Initramfs unpacking failed: junk in compressed archive".

There is no ethernet node.  The SGMII PHY is imported as a black box and
exposes no `ethphy` CSR for the LiteEth driver to bind to; `fixed-link` is the
way in, since the PCS autonegotiates in hardware.  Linux boots without it.

## The network boot is host-specific

The address the BIOS boots from is compiled into the gateware, so a bitstream
built on one machine looks for a TFTP server on *that* machine's network.  The
Makefile detects the build host's address rather than carrying a default; an
earlier version hardcoded one developer's, which built fine anywhere and then
failed on the board with an ARP timeout for a host that did not exist on that
network.

The build prints what it chose:

    network boot will look for a TFTP server at 192.168.1.106

Override it when the server is elsewhere:

    make vc707-litex-linux LITEX_REMOTE_IP=10.0.0.5

And serve the payload from that machine:

    make tftp-serve

which dispatches on the requesting MAC -- so several boards can be served
their own payload out of one directory -- and logs each request, the quickest
way to tell whether the board got as far as asking.

## Building

    make vc707-litex-linux PRJXRAY_DB=...        # SoC + emulator + dtb
    make vc707-litex-linux-payload              # stage kernel/rootfs/dtb/emulator
    make vc707-litex-linux-flash

The kernel and rootfs are not vendored and have no default; `LINUX_IMAGES`
names a directory holding `Image` and `rootfs.cpio` built for rv32ima.  Those used here came
from f4pga-examples' `linux_litex_demo` (Linux 5.0.13, Buildroot 2020.02).

## What the open flow had to close

Every clock, simultaneously, with the MMU CPU at 5994 FDREs on top of 99 DDR3
serialisers and a transceiver:

| clock | achieved | required |
| --- | --- | --- |
| `main_crgddr_clkout_buf0` | 110.17 MHz | 100 |
| `eth_tx_clk` | 208.42 MHz | 125 |
| `eth_rx_clk` | 214.00 MHz | 125 |
| `idelay_clk` | 493.83 MHz | 200 |

That needs `--placer-heap-timingweight 60` (the `NEXTPNR_FLAGS` default): at
HeAP's default weight this design's GMII datapath lands anywhere between 60
and 120 MHz across runs of identical RTL.

Two hold violations are reported at -0.03 ns on a VexRiscv data-cache path.
This flow has no trustworthy hold STA -- it reports one at -0.02 ns on the
DDR3-only build that passes memtest, and eighteen on `../vc707-ethmin`, which
answers ARP.  Treat them as advisory; the board is the arbiter.
