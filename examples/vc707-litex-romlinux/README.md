# Linux from the BIOS ROM

The 1 GB VC707 Linux SoC (`../vc707-litex`, VexRiscv-SMP linux, 64-bit DDR3,
ethmin's SGMII PHY) with the kernel, a busybox root filesystem, OpenSBI and
the device tree compressed into its own BIOS ROM.  It boots to a shell with no
TFTP server, SD card or serial upload.

## The ROM

    0x00000  LiteX BIOS                       (128 KiB partition)
    0x20000  unpacker/                        ROM_BOOT_ADDRESS, "romboot"
    0x28000  unpacker/romtest.c               ROM_TEST_ADDRESS, "romtest"
    0x30000  payload (mkpayload.py)           xz images + their load addresses

The BIOS brings up DDR as it always does.  The SoC defines `ROM_BOOT_ADDRESS`
and puts ROM boot ahead of the network boot (`ROM_BOOT_PRIORITY -20`), so it
then counts down for `ROM_BOOT_TIMEOUT` (3 s): ESC stops at the BIOS console,
where `romboot` resumes the boot and `romtest` runs the ROM test; otherwise it
jumps to the unpacker.  The unpacker decompresses each image into DDR,
at the addresses the TFTP boot of the same SoC uses, and starts OpenSBI:

| image | raw | xz | at |
|---|---|---|---|
| Image (kernel/romlinux.config) | 3676432 | 1211460 | 0x40000000 |
| rootfs.cpio (busybox + glibc) | 2810368 | 1089872 | 0x40800000 |
| device tree | 3280 | 1164 | 0x40770000 |
| opensbi.bin | 263652 | 54864 | 0x40780000 |

The ROM memory is sized to what it holds, not to its 16 MiB address window:
2.5 MB, 640 RAMB36 through the Verilator flow.

**unpacker/** is freestanding C, executed in place from the ROM.  Its stack
and heap sit in the last MiB of DDR, and it uses the Linux tree's xz decoder
(`linux-deps/linux/lib/xz`, single-call mode, about 30 KB of state).  It is
built against the SoC's generated `csr.h`, which gives it the UART address.

**unpacker/romtest.c** is the ROM test.  It reads the whole ROM, 1 KiB at a
time, against signatures taken on the host (`romtest_data.py`), and prints
each run of bad blocks with the data bits involved.  It checks each payload
image's CRC as read, unpacks it, and names the first 64 KiB block that
unpacks wrongly.  Last, it tests all 1 GB of DDR with address-in-data and its
complement, which catches aliased addresses and stuck data bits.  Its stack is
in the SRAM, so a bad DDR cannot take it down; it halts when done.  A ROM
block RAM that reads wrongly shows up as one data bit wrong across one 128 KiB
tile of the ROM: `rom_inst_t<bit>_d<tile>`.

**fasm_rom_patch.py** rewrites the ROM's contents in a routed FASM, so new
firmware (a BIOS, the unpacker, the ROM test) goes into an existing build
without placing and routing again; the placement and routing, and any fault in
them, stay as they were.  It checks the FASM holds the old ROM first.  In the
FASM, ROM address a of a RAMB36 is `RAMB18_Y(a%2)` bit `a/2`.

    fasm_rom_patch.py placement.json in.fasm old_rom.bin new_rom.bin out.fasm

**mkpayload.py** writes the initramfs and generates the device tree from the
SoC's own `csr.json` with LiteX's `litex_json2dts_linux`.  It moves the
reserved region and the initrd to the layout this OpenSBI build expects:
linked at 0x40780000, with the device tree at 0x40770000.  It then packs the
four images into the payload.

**The kernel** is `tinyconfig` plus `kernel/romlinux.config`, after
sonata-linux's `ram-additions.config`: `-Os`, `SLUB_TINY`, `BASE_SMALL`, no
modules and no kallsyms, plus only this SoC's drivers (liteuart, PLIC, CLINT
timer, the LiteX SoC controller, LiteEth).  It is rv32ima with no C and no
FPU, matching the CPU.  The initramfs is not compressed inside the kernel,
since the unpacker has already done that, so no `RD_*` decompressors are
built in.  The result is 3.7 MB, against 5.2 MB for the TFTP-booted kernel.

**The rootfs** is busybox and the three libraries it links (`ld.so`, `libc`,
`libresolv`) from a buildroot glibc sysroot (`~/vc707-nfsroot`, rv32ima
ilp32), with the overlay in `rootfs/`.  `/init` is busybox's init, and
`etc/init.d/rcS` mounts proc, sys, devtmpfs and tmp and asks DHCP for an
address on `eth0` in the background (busybox's `udhcpc`, with its
`simple.script` as `usr/share/udhcpc/default.script` to set the route and
`resolv.conf`).  This glibc searches `/lib32`, so that is a link to `/lib`.

## Building

    make -C linux-deps/linux ARCH=riscv O=$K tinyconfig
    linux-deps/linux/scripts/kconfig/merge_config.sh -m -O $K $K/.config \
        examples/vc707-litex-romlinux/kernel/romlinux.config
    make -C linux-deps/linux ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- O=$K olddefconfig Image

    cd examples/vc707-litex-romlinux
    PATH=../../.venv/bin:$PATH ../../.venv/bin/python vc707_romlinux.py \
        --kernel $K/arch/riscv/boot/Image --opensbi opensbi.bin --sysroot ~/vc707-nfsroot \
        --output-dir build --no-compile-gateware --build
    python3 export_synthgui.py build ~/synthgui

`opensbi.bin` is the litex-hub 1.3.1 fw_jump that the TFTP boot of this SoC
uses (FW_TEXT_START 0x40780000).  `export_synthgui.py` copies the gateware
Verilog, the `.init` files, the XDC, the VexRiscv-SMP cluster and its RAM
primitive, ethmin's PHY and nextpnr's measured delay matrix into
`~/synthgui/projects/vc707_romlinux-src`.  It writes
`projects/vc707_romlinux.json` with the black boxes the design instantiates.
Dropping `--no-compile-gateware` builds the same SoC with Vivado instead.

## On the board (2026-10-21)

Verilator's netlist of this SoC, placed and routed by Vivado from its EDIF
(timing met on the 100 MHz system clock), boots from the ROM to a busybox
shell with the init script's mounts in place, and runs CoreMark, built on
the board:

| compiler | CoreMark/s | CoreMark/MHz |
|---|---|---|
| gcc 13.4.0 `-O3 -march=rv32ima -mabi=ilp32` | 186.99 | 1.87 |
| tinycc riscv32 `194bf323` `-O2` | 34.75 | 0.35 |

Both validated; the gcc validation run gave the reference CRCs.  The
compilers came from kits fetched with busybox `wget`
(`~/bytecode-work/tcckit`): tinycc with its runtime and 455 glibc headers,
and CoreMark with gcc-built baselines.

Vivado's own synthesis of the same LiteX Verilog also boots, with all 1 GB
of DDR3 (`Memory: 1031564K/1048576K available`) and LiteEth working: a
DHCP lease and DNS lookups through the SGMII PHY.  The same
netlist through nextpnr failed at first -- the system clock reached 88.9
MHz of 100 and memtest failed on data -- until congestion-driven spreading
was added to the placement.  With openXC7 nextpnr main (5ff2661e, plus the
timing-opt-radius-iterations commits) and

    --router router2 --timing-allow-fail -o hold-fix
    -o delay-matrix=<delay-matrix-xc7vx485t.txt> --placer-heap-timingweight 100
    --placer-heap-congestion-spread

the system clock routes at 102.00 MHz (87.95 without spreading, router 10
iterations against 26), memtest passes and Linux boots: an all-open-source
flow, Verilator synthesis to prjxray bitstream, on silicon.  Running
-o timing-opt=2,30 after the spreading placement undoes it (91.58 MHz).

## nextpnr and the ROM (2026-10-22)

The netlist with the two-read block RAM fix (only the 10 LiteEth buffers
change) did not boot from two nextpnr placements that met timing by nextpnr's
report: the kernel or the rootfs failed to unpack.  The ROM test found the
fault: three ROM block RAMs, at the top and bottom edges of the die, reading
about a quarter of their bits wrongly, with no fit to any stuck or swapped
address bit.  Their contents in the FASM were right, and DDR passed in full.
They are timing failures that nextpnr does not report:

- nextpnr gives every sink of a global clock the same delay (762 ps), so it
  sees no clock skew.  Vivado's placement of the same netlist has -0.45 to
  -0.87 ns of skew on these paths: about 0.17 ns per clock region row from the
  centre, 1.7 ps per column from the spine, and a block RAM's clock pin
  0.43 ns later than a flip-flop's.
- nextpnr spreads each ROM data bit's 20 block RAMs over the whole height of
  the die and fills whole columns, edge columns included; Vivado clusters
  each bit's block RAMs (40% smaller span) and fills columns outward from the
  logic.

With the block RAMs placed at Vivado's sites (`set_property LOC` in the XDC,
taken from Vivado's placement) and everything else placed by nextpnr,
the same netlist reads its ROM cleanly and boots Linux.  OpenSTA on nextpnr's
SDF (per-cell SDF blocks dropped, which crash its reader) tells the working
placements from the failing ones where nextpnr's own report does not: worst
ROM path -1.24 ns on the build that boots, -5.42 ns on one that does not.

### The fix in nextpnr, and a figure of merit

nextpnr's `clock-tree-bram-place` branch adds both halves: the clock tree's
insertion delay (`clock_tree.cc`; `-o clock-tree=off` to disable), and a
block RAM pass (`bram_place.cc`; `-o bram-place=off`).  After the heap
placement it groups the block RAMs by their read-mux cones (this ROM: 32
groups of 20, one per data bit), anchors each group at the registers its
cones end in, regrows the groups together from their anchors by estimated
delay plus clock skew, locks them, and places everything else again around
them.  With it, and nothing from Vivado, the same netlist (N2) reads its ROM
cleanly, unpacks every image, boots Linux and takes a DHCP lease.

`bram_fom.py` scores a placement's block RAMs from the placement alone, so
it compares nextpnr's placements with Vivado's: each block RAM's worst
estimated arrival at the registers its read cone ends in (the measured delay
matrix, plus the clock-tree skew).  Against the board:

| placement | board | worst | p95 | OpenSTA worst ROM path |
|---|---|---|---|---|
| Vivado | boots | 4908 ps | 4084 ps | |
| N2: nextpnr, new block RAM placement | boots | 5048 ps | 4187 ps | -2.58 ns |
| synthgui's nextpnr (another prjxray-db) | ROM reads | 5632 ps | 5083 ps | |
| V: Vivado's block RAM sites, nextpnr logic | boots | 5663 ps | 5038 ps | -3.77 ns |
| D: nextpnr, before the netlist fix | boots | 5995 ps | 4979 ps | -1.24 ns |
| H: nextpnr, seed 2 | ROM reads wrongly | 6251 ps | 5113 ps | |
| G: nextpnr | ROM reads wrongly | 6961 ps | 5639 ps | -5.42 ns |

Every placement that works scores 5995 ps or less worst, both that fail
6251 ps or more; the p95 alone does not separate them (5083 reads, 5113 does
not).  The gap is about 250 ps, so the score is a screen for which
placements to try on the board, not a proof.  The three block RAMs that failed in H rank #11,
#31 and #113 of 735 by score.

    bram_fom.py --netlist xilinx_vc707.json --tilegrid <prjxray-db>/virtex7/xc7vx485t/tilegrid.json \
        --delay-matrix delay-matrix-xc7vx485t.txt N2=xilinx_vc707_placement.json \
        vivado=vivado:cell_sites.txt

### The network

With N3 (the netlist through Verilator and nextpnr with the clock-tree and
block RAM work) booted and holding a DHCP lease, iperf3 against a host on
the same gigabit switch (`iperf3-kit`, `net-stress`), against the Vivado
build of the same netlist:

| test | Vivado P&R | nextpnr P&R (N3) |
|---|---|---|
| TCP, board sending | 10.3 Mbit/s, 0 retransmits | 10.2 Mbit/s, 0 retransmits |
| TCP, board receiving | 6.70 Mbit/s, 1655 retransmits | 6.49 Mbit/s, 1515 retransmits |
| TCP, both ways at once | | 3.98 + 4.13 Mbit/s |
| TCP, receiving, 4 streams | | 6.99 Mbit/s in all |
| UDP 100 Mbit/s offered, board sending | | 8.9 Mbit/s, 0% lost |
| UDP 5 Mbit/s, board receiving | | 0.02% lost |
| UDP 20 Mbit/s, board receiving | | never finished: the control connection starved |
| UDP 100 Mbit/s, board receiving | | 99.94% lost, 50 kbit/s delivered |

The two place-and-route flows behave alike; the limits are the SoC's.  One
100 MHz VexRiscv runs the TCP/IP stack and copies every frame through
LiteEth's two receive and two transmit slots, so about 10 Mbit/s out and 6.5
in is what it can do.  Received at that rate or below, nothing is lost.
Offered more, it livelocks: every arriving frame interrupts, and the CPU
spends its time taking interrupts and dropping frames, so delivery falls to
almost nothing (TCP backs off and survives it with retransmits; UDP does
not).  The cure is in the SoC: frames streamed into DDR by a receive DMA
through a FIFO, with NAPI polling in the LiteEth driver, and more receive
slots.
