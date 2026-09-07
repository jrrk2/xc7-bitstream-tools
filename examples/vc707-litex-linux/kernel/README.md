# Linux 6.9 for the open-flow VC707 SoC

Built from `linux-deps/linux` (pinned `af93851`, branch `rv32-sonata-litex`),
cross-compiled with the stock `riscv64-linux-gnu-gcc`:

    make -C linux-deps/linux O=<build> ARCH=riscv \
         CROSS_COMPILE=riscv64-linux-gnu- olddefconfig
    make -C linux-deps/linux O=<build> ARCH=riscv \
         CROSS_COMPILE=riscv64-linux-gnu- -j$(nproc)

starting from `linux-6.9.config` here.  No kernel source changes were needed.

## What it achieves, on hardware

    SBI specification v0.1 detected
    riscv: base ISA extensions aim
    LiteX SoC Controller driver initialized
    f0004000.serial: ttyLXU0 ... is a liteuart
    liteeth f0001800.mac eth0: irq 0 slots: tx 2 rx 2 size 2048
    Run /init as init process

The SoC-controller line is worth more than it looks: that driver *panics* if
the scratch register does not read back `0x12345678`, so it is a direct test
of the 32-bit CSR access that the 5.0.13 image got wrong.

## Why the config differs from the sonata board's

Because it describes the opposite machine.  The sonata board has **8 MiB of
RAM**, so nothing is copied into it that does not have to be: the kernel text
executes in place from flash at `XIP_PHYS_ADDR=0x02000000`, and the root
filesystem is romfs read directly off MTD (`ROMFS_BACKED_BY_MTD`,
`ROMFS_ON_MTD`, `MTD_ROM`) rather than unpacked anywhere.  RAM holds data and
bss and little else.

Seen that way, `BLK_DEV_INITRD=n` and `CONFIG_NET=n` are not omissions -- they
are RAM that board cannot spare.  And `STRICT_KERNEL_RWX`, which aligns every
kernel section to a PMD, costs *flash address space* there rather than RAM,
which is why it is affordable on sonata and was ruinous here.

This SoC is the inverse: 512 MiB of DDR3 at 0x40000000, netbooted into RAM,
with no flash in the path at all.  Every change below follows from that:

*The firmware is our 6 KB emulator, not OpenSBI.*

  - `RISCV_SBI_V01=y` -- the emulator implements the legacy console and timer
    calls plus the v0.2 BASE probe, and nothing else.  There is no Sstc to
    fall back on either: VexRiscv has no `stimecmp`.  Without this the timer
    call returns NOT_SUPPORTED and the boot hangs in silence.

*The CPU is `rv32ima` and nothing more.*

  - `RISCV_ISA_C=n` -- no compressed instructions in the core.
  - `EFI=n` -- **the trap**.  EFI is `default y` and `depends on !XIP_KERNEL`,
    and it `select`s `RISCV_ISA_C`.  So turning XIP off, which netbooting
    requires, silently re-enabled instructions this CPU cannot execute.
  - `ZBB`, `ZICBOM`, `ZICBOZ` off.

*We netboot into DDR; the sonata board executes in place from flash.*

  - `XIP_KERNEL=n` -- otherwise the build produces `xipImage` at 0x02000000.
  - `BLK_DEV_INITRD=y` -- the rootfs arrives at 0x40800000 and is handed over
    by `linux,initrd-start/end`; the sonata config has initrd off entirely.
  - `STRICT_KERNEL_RWX=n` -- it aligns every kernel section to a PMD, which on
    sv32 is 4 MB.  Six sections made a 4.5 MB kernel into a 21.5 MB image that
    would have overwritten the initramfs at 0x40800000.  Packed, it is
    4,280,752 bytes.

    **This one should be revisited.**  It was disabled to dodge an address
    collision, but the collision only exists because the initramfs sits 8 MiB
    above the kernel -- an address inherited from a 4.6 MB kernel, on a board
    with 512 MiB where 13 MiB is in use.  Moving `ROOTFS_ADDR` to 0x42000000
    costs nothing and buys back the protection the boot log currently
    laments: "Kernel memory protection not selected by kernel config."
    Trading away hardening to save 17 MB of a 512 MB address space is the
    sonata board's reasoning applied where it does not belong.
  - `NET`, `INET`, `NET_VENDOR_LITEX`, `LITEX_LITEETH` -- the sonata config has
    `CONFIG_NET` off entirely, so the ethernet driver was not even reachable.

## The device tree

`rv32-6.9.dts` differs from the 5.0.13 one in three ways:

  - `riscv,isa-extensions` as well as `riscv,isa`.  6.9 with
    `RISCV_ISA_FALLBACK=n` does not parse the old string.
  - a `litex,soc-controller` node at the ctrl CSR (reset +0x00, scratch +0x04).
  - the **new** liteeth binding: `reg-names = "mac", "buffer"` with
    `litex,rx-slots`/`tx-slots`/`slot-size`, and no MDIO region at all.  6.9's
    driver never touches MDIO, which retires the phantom address the older
    binding forced on us for a black-box PHY.

## What does not work yet

The rootfs.  It is Buildroot 2020.02 built against a 5.x kernel, and on 6.9 it
hits `ENOSYS`:

    /bin/sh: can't access tty; job control turned off
    / # sh: poll: Function not implemented

riscv never had `sys_poll` -- only `ppoll` -- and whatever provided it for the
5.0.13 image is gone.  `uname -a` reports `Linux 6.9.0+ riscv32` from that
shell, so userspace runs; it is the 2020 libc that is mismatched.  The fix is
to build a rootfs from the pinned buildroot rather than reuse the f4pga one.
