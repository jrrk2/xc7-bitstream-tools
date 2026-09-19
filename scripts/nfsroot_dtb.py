#!/usr/bin/env python3
"""Turn a working device tree into an NFS-root one.

Patches an existing dtb rather than regenerating it, because the dtb in
service encodes things this script has no way to rederive -- the SoC's CSR
addresses, the PLIC layout, the ip= string already known to work on this
board.  Changing only what root= needs keeps every one of those fixed.

    scripts/nfsroot_dtb.py in.dtb out.dtb SERVER:/PATH
"""
import re, subprocess, sys

def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    src, dst, nfsroot = sys.argv[1:4]
    dts = subprocess.run(["dtc", "-I", "dtb", "-O", "dts", src],
                         capture_output=True, text=True, check=True).stdout

    m = re.search(r'bootargs\s*=\s*"([^"]*)"', dts)
    if not m:
        sys.exit("no bootargs in " + src)
    args = m.group(1)
    if "root=" not in args:
        sys.exit("bootargs has no root= to replace")

    # The ip= already in the tree is left exactly as it is: it is the string
    # this board is known to autoconfigure with, and nfsroot= only needs the
    # server, which it carries itself.
    new = re.sub(r"root=\S+",
                 f"root=/dev/nfs rw nfsroot={nfsroot},vers=3,tcp,nolock", args)
    if "ip=" not in new:
        sys.exit("bootargs has no ip= -- NFS root needs kernel IP autoconfiguration")
    dts = dts[:m.start(1)] + new + dts[m.end(1):]

    # An initramfs, if present, is mounted and root= is never consulted.  It
    # has to go, or the board boots the old rootfs and the NFS mount looks
    # like it silently failed.
    dts, n = re.subn(r"\s*linux,initrd-(start|end)\s*=\s*<[^>]*>;", "", dts)

    subprocess.run(["dtc", "-I", "dts", "-O", "dtb", "-o", dst],
                   input=dts, text=True, check=True)
    print(f"  {src} -> {dst}")
    print(f"  initrd properties removed: {n}")
    print(f"  bootargs: {new}")

if __name__ == "__main__":
    main()
