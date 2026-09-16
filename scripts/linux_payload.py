#!/usr/bin/env python3
"""Assemble the Linux netboot payload for a LiteX SoC.

Two things here must come from the SoC rather than be assumed, and both have
already cost a boot:

  * the UART address in the device tree.  Adding the CPU timer that Linux
    needs shifts every CSR bank, so a dtb written for one build is wrong for
    the next.  It is read from csr.json.

  * `linux,initrd-end`.  It must be the start plus the ACTUAL size of
    rootfs.cpio: round it up and the kernel reads past the archive and
    reports "Initramfs unpacking failed: junk in compressed archive", then
    limps on from /dev/ram0 with tmpfs mounts failing.

The emulator is built separately (see examples/vc707-litex-linux/emulator);
it takes its addresses from generated/csr.h the same way.

Load addresses follow the LiteX convention for a 512 MiB DDR3 at 0x40000000,
and boot.json lists the emulator LAST because the BIOS boots to the address of
the last image unless told otherwise.
"""

import argparse
import json
import os
import re
import subprocess
import sys

KERNEL_ADDR   = 0x40000000
ROOTFS_ADDR   = 0x40800000
DTB_ADDR      = 0x41000000
EMULATOR_ADDR = 0x50000000


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--dts",    required=True, help="Device tree source to patch and compile.")
    p.add_argument("--csr",    required=True, help="The SoC's csr.json.")
    p.add_argument("--images", required=True, help="Directory holding Image and rootfs.cpio.")
    p.add_argument("--out",    required=True, help="Where to write the payload (a TFTP directory).")
    args = p.parse_args()

    csr  = json.load(open(args.csr))
    uart = csr["csr_bases"]["uart"]

    rootfs = os.path.join(args.images, "rootfs.cpio")
    if not os.path.isfile(rootfs):
        sys.exit(f"no rootfs.cpio in {args.images}")
    initrd_end = ROOTFS_ADDR + os.path.getsize(rootfs)

    dts = open(args.dts).read()
    dts = re.sub(r"serial@[0-9a-f]+",  f"serial@{uart:x}", dts)
    dts = re.sub(r"0x[0-9a-f]*f0[0-9a-f]{6}", f"0x{uart:08x}", dts)  # the reg entry
    dts = re.sub(r"(linux,initrd-end\s*=\s*<)0x[0-9a-f]+(>)",
                 rf"\g<1>0x{initrd_end:08x}\g<2>", dts)

    os.makedirs(args.out, exist_ok=True)
    dts_out = os.path.join(args.out, "rv32.dts")
    dtb_out = os.path.join(args.out, "rv32.dtb")
    open(dts_out, "w").write(dts)
    subprocess.run(["dtc", "-I", "dts", "-O", "dtb", "-o", dtb_out, dts_out], check=True)

    # The emulator goes last: boot.c takes the boot address from the final
    # image unless a bootargs.addr key says otherwise.
    boot = {
        "Image":        f"0x{KERNEL_ADDR:08x}",
        "rootfs.cpio":  f"0x{ROOTFS_ADDR:08x}",
        "rv32.dtb":     f"0x{DTB_ADDR:08x}",
        "emulator.bin": f"0x{EMULATOR_ADDR:08x}",
    }
    with open(os.path.join(args.out, "boot.json"), "w") as f:
        json.dump(boot, f, indent=4)

    print(f"  uart          0x{uart:08x} (from csr.json)")
    print(f"  initrd        0x{ROOTFS_ADDR:08x}..0x{initrd_end:08x} "
          f"({os.path.getsize(rootfs)} bytes)")
    for name, addr in boot.items():
        print(f"  {name:14} {addr}")


if __name__ == "__main__":
    main()
