#!/usr/bin/env python3
"""mkpayload.py: the Linux payload for the BIOS ROM's second partition.

Builds a busybox initramfs, the SoC's device tree, and the payload the ROM
unpacker reads: xz images, each with the DDR address it unpacks to.

    mkpayload.py --csr <build>/csr.json --kernel Image --opensbi opensbi.bin \\
                 --sysroot ~/vc707-nfsroot --out <dir>

The load addresses are the ones the TFTP boot of the same SoC uses
(boot.json): OpenSBI is linked at 0x40780000 and takes the device tree from
0x40770000, and the kernel runs from the base of DDR.

Payload format (little-endian words, offsets from the payload's start):
    "LXRP", count, entry, 0, then count x {dest, offset, csize, usize}
"""
import argparse, lzma, os, re, stat, struct, subprocess, sys

KERNEL, DTB, OPENSBI, INITRD = 0x40000000, 0x40770000, 0x40780000, 0x40800000
here = os.path.dirname(os.path.abspath(__file__))
tools = os.path.abspath(os.path.join(here, "..", ".."))

# What busybox needs from the sysroot (readelf -d bin/busybox: NEEDED)
LIBS = ["lib/ld-linux-riscv32-ilp32.so.1", "lib/libc.so.6", "lib/libresolv.so.2"]


def cpio_newc(entries):
    """entries: (path, mode, data, rdev) in order; returns a newc archive."""
    out = bytearray()
    def rec(name, mode, data, rdev, ino):
        name = name.encode() + b"\0"
        hdr = b"070701" + b"".join(b"%08x" % v for v in (
            ino, mode, 0, 0, 1, 0, len(data), 0, 0, rdev >> 8, rdev & 0xff, len(name), 0))
        out.extend(hdr + name)
        out.extend(b"\0" * (-len(out) % 4))
        out.extend(data)
        out.extend(b"\0" * (-len(out) % 4))
    for ino, (path, mode, data, rdev) in enumerate(entries, 1):
        rec(path, mode, data, rdev, ino)
    rec("TRAILER!!!", 0, b"", 0, 0)
    out.extend(b"\0" * (-len(out) % 512))
    return bytes(out)


def rootfs(sysroot, overlay):
    d, f, l, c = stat.S_IFDIR | 0o755, stat.S_IFREG, stat.S_IFLNK | 0o777, stat.S_IFCHR | 0o600
    e = [(p, d, b"", 0) for p in ("bin", "sbin", "lib", "dev", "proc", "sys", "tmp", "root",
                                  "etc", "etc/init.d", "usr", "usr/bin", "usr/sbin")]
    e.append(("dev/console", c, b"", (5 << 8) | 1))
    e.append(("dev/null", stat.S_IFCHR | 0o666, b"", (1 << 8) | 3))
    e.append(("bin/busybox", f | 0o755, open(os.path.join(sysroot, "bin/busybox"), "rb").read(), 0))
    for lib in LIBS:
        e.append((lib, f | 0o755, open(os.path.join(sysroot, lib), "rb").read(), 0))
    # The kernel runs /init; as a link to busybox it is busybox's init, which
    # reads /etc/inittab.  sh is needed before rcS has installed the rest.
    e.append(("init", l, b"bin/busybox", 0))
    e.append(("bin/sh", l, b"busybox", 0))
    # This glibc's loader searches /lib32, not /lib (buildroot's layout)
    e.append(("lib32", l, b"lib", 0))
    for top, dirs, files in sorted(os.walk(overlay)):
        for n in sorted(files):
            p = os.path.join(top, n)
            mode = os.stat(p).st_mode & 0o777
            e.append((os.path.relpath(p, overlay), f | mode, open(p, "rb").read(), 0))
    return cpio_newc(e)


def devicetree(csr, initrd_size, out):
    py = os.path.join(tools, ".venv", "bin", "python")
    dts = subprocess.run([py, os.path.join(tools, "litex-deps/litex/litex/tools/litex_json2dts_linux.py"),
                          "--initrd-start", str(INITRD - KERNEL), "--initrd-size", str(initrd_size), csr],
                         check=True, capture_output=True, text=True).stdout
    # json2dts reserves OpenSBI at its current link address; this OpenSBI is
    # linked below the initrd and reserves its own memory, so only the device
    # tree's page is reserved here, as in the TFTP boot's tree.
    dts, n = re.subn(r"opensbi@[0-9a-f]+ \{\s*reg = <0x[0-9a-f]+ 0x[0-9a-f]+>;",
                     "opensbi@%x {\n                reg = <0x%x 0x10000>;" % (DTB, DTB), dts)
    assert n == 1, "json2dts output has no opensbi reservation to move"
    # An initramfs needs no root=; and this kernel has no IP autoconfiguration
    dts, n = re.subn(r'bootargs = "[^"]*"', 'bootargs = "console=liteuart earlycon=liteuart,0x%x"'
                     % int(re.search(r"earlycon=liteuart,(0x[0-9a-f]+)", dts).group(1), 16), dts)
    assert n == 1
    open(out + ".dts", "w").write(dts)
    subprocess.run(["dtc", "-q", "-I", "dts", "-O", "dtb", "-o", out + ".dtb", out + ".dts"], check=True)
    return open(out + ".dtb", "rb").read()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--csr", required=True, help="the SoC's csr.json")
    ap.add_argument("--kernel", required=True, help="rv32ima Linux Image")
    ap.add_argument("--opensbi", required=True, help="OpenSBI fw_jump, linked at 0x40780000")
    ap.add_argument("--sysroot", required=True, help="where bin/busybox and its libraries come from")
    ap.add_argument("--overlay", default=os.path.join(here, "rootfs"))
    ap.add_argument("--out", required=True, help="output directory")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    cpio = rootfs(a.sysroot, a.overlay)
    open(os.path.join(a.out, "rootfs.cpio"), "wb").write(cpio)
    dtb = devicetree(a.csr, len(cpio), os.path.join(a.out, "romlinux"))
    kernel = open(a.kernel, "rb").read()
    opensbi = open(a.opensbi, "rb").read()
    assert KERNEL + len(kernel) <= DTB, "kernel overlaps the device tree"
    assert OPENSBI + len(opensbi) <= INITRD, "OpenSBI overlaps the initrd"

    images = [(KERNEL, kernel, "Image"), (INITRD, cpio, "rootfs.cpio"),
              (DTB, dtb, "dtb"), (OPENSBI, opensbi, "opensbi.bin")]
    head = 16 + 16 * len(images)
    body, table = bytearray(), bytearray()
    for dest, data, name in images:
        xz = lzma.compress(data, format=lzma.FORMAT_XZ, check=lzma.CHECK_CRC32,
                           preset=9 | lzma.PRESET_EXTREME)
        table += struct.pack("<4I", dest, head + len(body), len(xz), len(data))
        body += xz + b"\0" * (-len(xz) % 4)
        print("  %-12s %8d -> %8d bytes at 0x%08x" % (name, len(data), len(xz), dest))
    payload = b"LXRP" + struct.pack("<3I", len(images), OPENSBI, 0) + table + body
    open(os.path.join(a.out, "payload.bin"), "wb").write(payload)
    print("payload.bin: %d bytes (%d KiB)" % (len(payload), len(payload) // 1024))


if __name__ == "__main__":
    main()
