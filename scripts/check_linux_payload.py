#!/usr/bin/env python3
"""Check a staged Linux netboot payload against the SoC it is meant for.

Everything here is a failure that has actually happened on this board, and
each one presents as something else entirely, which is why they are worth
machine-checking rather than remembering:

  * THE DIRECTORY IS KEYED BY MAC, AND TWO SoCs CAN SHARE ONE.  The BIOS
    fetches from a directory named after its own MAC, so staging a payload
    for SoC A into SoC B's directory silently replaces B's.  The non-SMP
    VexRiscv_Linux build and an older SMP build both answer to
    10:e2:d5:00:00:07; the SMP payload landed there, and the non-SMP board
    jumped into an OpenSBI built for another machine and went quiet with no
    output at all -- no panic, no banner, nothing to search for.

  * THE KERNEL MUST BE ABLE TO DRIVE THE CSR BUS.  The 5.0.13 image is
    compiled for an 8-bit CSR bus; on a 32-bit SoC liteeth's litex_read32
    concatenates four registers and asks for a ~3.9 GB skb.  The board boots
    perfectly and simply has no network.

  * THE liteeth BINDING IS NAMED, NOT INDEXED.  The 6.9 driver looks its
    regions up by name; given the older three-unnamed-reg form it reports
    "invalid resource (null)" and fails to probe with -22, again on a board
    that otherwise boots fine.

  * THE EMULATOR GOES LAST IN boot.json.  The BIOS boots to the address of
    the LAST image listed.

A warning is for something that works but is worth knowing (a polling MAC).
An error is for something that will not work.
"""

import argparse
import json
import os
import re
import subprocess
import sys

errors = []
warnings = []


def err(msg):
    errors.append(msg)


def warn(msg):
    warnings.append(msg)


def soc_mac(csr):
    b = [csr["constants"].get("macaddr%d" % i) for i in range(1, 7)]
    if any(x is None for x in b):
        return None
    return ":".join("%02x" % x for x in b)


def dtb_to_dts(path):
    try:
        return subprocess.run(["dtc", "-I", "dtb", "-O", "dts", path],
                              capture_output=True, text=True, check=True).stdout
    except FileNotFoundError:
        warn("dtc not installed; device tree not checked")
    except subprocess.CalledProcessError as e:
        err("%s does not decompile: %s" % (path, e.stderr.strip().split("\n")[-1]))
    return None


def kernel_version(path):
    try:
        with open(path, "rb") as f:
            blob = f.read()
    except OSError as e:
        err("cannot read %s: %s" % (path, e))
        return None
    m = re.search(rb"Linux version (\d+)\.(\d+)[.\d]*", blob)
    if not m:
        warn("no 'Linux version' string in %s; cannot check the kernel" % path)
        return None
    return int(m.group(1)), int(m.group(2))


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--dir", required=True, help="Staged payload directory (named after the MAC).")
    p.add_argument("--csr", required=True, help="csr.json of the SoC that will boot it.")
    p.add_argument("--min-kernel", default="6.0",
                   help="Lowest kernel that can drive this SoC's CSR bus (default 6.0).")
    args = p.parse_args()

    d = args.dir.rstrip("/")
    csr = json.load(open(args.csr))

    # 1. The directory name must be this SoC's MAC.
    mac = soc_mac(csr)
    base = os.path.basename(d)
    if mac is None:
        warn("csr.json carries no macaddr constants; directory name not checked")
    elif base.lower() != mac.lower():
        err("directory is '%s' but this SoC's MAC is %s.\n"
            "    The BIOS fetches from the directory named after its own MAC, so this\n"
            "    payload would be served to a DIFFERENT SoC -- or silently overwrite\n"
            "    the payload belonging to one." % (base, mac))

    # 2. boot.json: present, parses, every file real, loader last.
    bj = os.path.join(d, "boot.json")
    entries = {}
    if not os.path.isfile(bj):
        err("no boot.json in %s" % d)
    else:
        try:
            entries = json.load(open(bj))
        except ValueError as e:
            err("boot.json does not parse: %s" % e)
        for name in entries:
            f = os.path.join(d, name)
            if not os.path.isfile(f):
                err("boot.json lists '%s', which is not in %s" % (name, d))
            elif os.path.getsize(f) == 0:
                err("'%s' is empty" % name)
        if entries:
            last = list(entries)[-1]
            if not re.match(r"(emulator|opensbi)", last):
                err("boot.json lists '%s' last, so the BIOS boots to ITS address.\n"
                    "    The machine-mode payload (emulator.bin / opensbi.bin) must be last."
                    % last)

    # 3. The kernel has to be able to drive this SoC's CSR bus.
    image = os.path.join(d, "Image")
    want = tuple(int(x) for x in args.min_kernel.split("."))
    if os.path.isfile(image):
        v = kernel_version(image)
        if v and v < want:
            err("Image is Linux %d.%d, older than %s.\n"
                "    A kernel built for an 8-bit CSR bus drives this 32-bit SoC's liteeth\n"
                "    by concatenating four registers -- the board boots and has no network."
                % (v[0], v[1], args.min_kernel))

    # 4. The device tree has to describe THIS SoC.
    dtbs = [f for f in os.listdir(d) if f.endswith(".dtb")] if os.path.isdir(d) else []
    staged_dtbs = [f for f in dtbs if f in entries] or dtbs
    for name in staged_dtbs:
        dts = dtb_to_dts(os.path.join(d, name))
        if dts is None:
            continue

        uart = csr["csr_bases"].get("uart")
        if uart is not None and ("serial@%x" % uart) not in dts:
            err("%s has no serial@%x; this SoC's UART is there (from csr.json).\n"
                "    A device tree written for another build points the console at an\n"
                "    address that answers nothing, and the boot is silent." % (name, uart))

        if "ethmac" in csr["csr_bases"]:
            ethmac = csr["csr_bases"]["ethmac"]
            buf = csr.get("memories", {}).get("ethmac", {}).get("base")
            if ("mac@%x" % ethmac) not in dts:
                err("%s has no mac@%x, so Linux sees no ethernet device at all\n"
                    "    even though the BIOS netbooted over that same MAC." % (name, ethmac))
            else:
                if "reg-names" not in dts:
                    err("%s: the mac node has no reg-names.  The 6.9 liteeth driver looks\n"
                        "    its regions up BY NAME and reports 'invalid resource (null)',\n"
                        "    failing to probe with -22." % name)
                else:
                    for want_name in ("mac", "buffer"):
                        if want_name not in re.findall(r'reg-names = "([^"]*)"', dts.replace("\\0", " ")) \
                           and want_name not in dts:
                            err("%s: mac node reg-names lacks '%s'" % (name, want_name))
                if buf is not None and ("%x" % buf) not in dts:
                    err("%s: mac node does not reference the ethmac buffer at 0x%x" % (name, buf))
                if mac and ("[" + mac.replace(":", " ") + "]") not in dts.lower():
                    err("%s: local-mac-address is not %s, so the board answers to an\n"
                        "    address other than the one naming this directory." % (name, mac))
                if "interrupts" not in dts.split("mac@")[1].split("};")[0]:
                    warn("%s: the mac node has no interrupts; the driver will poll.\n"
                         "    Works, but this SoC has no interrupt controller node to name."
                         % name)

        if "root=/dev/nfs" in dts:
            if "ip=" not in dts:
                err("%s: NFS root without an ip= argument; the kernel cannot reach the server"
                    % name)
            cpio = os.path.join(d, "rootfs.cpio")
            if os.path.isfile(cpio):
                warn("%s roots on NFS but rootfs.cpio is still staged; it is sent for nothing"
                     % name)

    for w in warnings:
        print("warning: %s" % w)
    for e in errors:
        print("ERROR: %s" % e, file=sys.stderr)
    if errors:
        print("\n%d problem(s) in %s" % (len(errors), d), file=sys.stderr)
        return 1
    print("payload in %s is consistent with %s" % (d, args.csr))
    if mac:
        print("  MAC %s matches the directory name" % mac)
    return 0


if __name__ == "__main__":
    sys.exit(main())
