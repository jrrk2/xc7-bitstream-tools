#!/usr/bin/env python3
"""The VC707 Linux SoC of ../vc707-litex (VexRiscv-SMP linux, 1 GB of DDR3,
ethmin's SGMII PHY), booting Linux from its own BIOS ROM.

The ROM is enlarged and split in three:

    0x00000  the LiteX BIOS               (BIOS_SIZE)
    0x20000  the unpacker (unpacker/)     ROM_BOOT_ADDRESS, the BIOS's "romboot"
    0x28000  the ROM test (unpacker/)     ROM_TEST_ADDRESS, the BIOS's "romtest"
    0x30000  the payload (mkpayload.py)   PAYLOAD_ADDRESS
             OpenSBI, the device tree, the kernel and a busybox initramfs,
             each xz-compressed

The BIOS brings up DDR as usual and then, ahead of the network and serial
boots, jumps to the unpacker (LiteX's ROM_BOOT_ADDRESS hook), which unpacks
the payload into DDR and starts OpenSBI.  Nothing is fetched over the network.

The ROM is sized to what it holds, not to its address window, so the BRAM
cost is the BIOS and unpacker partitions plus the compressed payload.

    vc707_romlinux.py --kernel Image --opensbi opensbi.bin --sysroot ~/vc707-nfsroot \\
        --output-dir build --no-compile-gateware --build

and everything else as for vc707_litex.py.  The gateware Verilog lands in
build/gateware, ROM contents in its .init files.
"""
import argparse, os, subprocess, sys

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(here, "..", "vc707-litex"))
import vc707_litex as base
from litex.soc.integration import soc as litex_soc

BIOS_SIZE        = 0x20000
ROM_BOOT_ADDRESS = 0x20000
ROM_TEST_ADDRESS = 0x28000
PAYLOAD_ADDRESS  = 0x30000
ROM_WINDOW       = 0x1000000   # address decode only; the memory is sized to its contents


class RomLinuxSoC(base.BaseSoC):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.add_constant("ROM_BOOT_ADDRESS", ROM_BOOT_ADDRESS)
        self.add_constant("ROM_TEST_ADDRESS", ROM_TEST_ADDRESS)
        # Before the network boot (-10), which would otherwise wait out its
        # ARP timeouts first
        self.add_constant("ROM_BOOT_PRIORITY", -20)
        # Seconds in which ESC stops at the BIOS console ("romboot" resumes)
        self.add_constant("ROM_BOOT_TIMEOUT", 3)


class RomLinuxBuilder(base.Builder):
    payload_args = None

    def _initialize_rom_software(self):
        a, words = self.payload_args, self.soc.bus.data_width // 8
        out = os.path.join(self.output_dir, "romlinux")
        os.makedirs(out, exist_ok=True)
        bios = open(os.path.join(self.software_dir, "bios", "bios.bin"), "rb").read()
        if len(bios) > BIOS_SIZE:
            raise SystemExit("BIOS is %d bytes, its partition %d" % (len(bios), BIOS_SIZE))

        make = ["make", "-s", "-C", os.path.join(here, "unpacker"),
                "BUILD_DIR=" + os.path.abspath(self.output_dir), "OUT=" + out,
                "ROM_BOOT_ADDRESS=0x%x" % ROM_BOOT_ADDRESS, "ROM_TEST_ADDRESS=0x%x" % ROM_TEST_ADDRESS,
                "PAYLOAD_ADDRESS=0x%x" % PAYLOAD_ADDRESS]
        subprocess.run(make + ["unpacker"], check=True)
        unpacker = open(os.path.join(out, "unpacker.bin"), "rb").read()
        if len(unpacker) > ROM_TEST_ADDRESS - ROM_BOOT_ADDRESS:
            raise SystemExit("unpacker is %d bytes, its partition %d"
                             % (len(unpacker), ROM_TEST_ADDRESS - ROM_BOOT_ADDRESS))

        subprocess.run([sys.executable, os.path.join(here, "mkpayload.py"),
                        "--csr", self.csr_json, "--kernel", a.kernel, "--opensbi", a.opensbi,
                        "--sysroot", a.sysroot, "--out", out], check=True)
        payload = open(os.path.join(out, "payload.bin"), "rb").read()

        rom = bytearray(PAYLOAD_ADDRESS + len(payload))
        rom[0:len(bios)] = bios
        rom[ROM_BOOT_ADDRESS:ROM_BOOT_ADDRESS + len(unpacker)] = unpacker
        rom[PAYLOAD_ADDRESS:] = payload
        rom += b"\0" * (-len(rom) % words)
        # The ROM test checks the ROM it is part of, so it is built last, from
        # this ROM; it skips its own partition and the unpacker's
        open(os.path.join(out, "rom.bin"), "wb").write(rom)
        subprocess.run([sys.executable, os.path.join(here, "unpacker", "romtest_data.py"),
                        "--rom", os.path.join(out, "rom.bin"),
                        "--payload-address", hex(PAYLOAD_ADDRESS), "--out", out], check=True)
        subprocess.run(make + ["romtest"], check=True)
        romtest = open(os.path.join(out, "romtest.bin"), "rb").read()
        if len(romtest) > PAYLOAD_ADDRESS - ROM_TEST_ADDRESS:
            raise SystemExit("ROM test is %d bytes, its partition %d"
                             % (len(romtest), PAYLOAD_ADDRESS - ROM_TEST_ADDRESS))
        rom[ROM_TEST_ADDRESS:ROM_TEST_ADDRESS + len(romtest)] = romtest
        open(os.path.join(out, "rom.bin"), "wb").write(rom)
        print("ROM: BIOS %d + unpacker %d + ROM test %d + payload %d = %d bytes (%d KiB, ~%d RAMB36)"
              % (len(bios), len(unpacker), len(romtest), len(payload), len(rom), len(rom) // 1024,
                 (len(rom) + 4095) // 4096))
        data = litex_soc.get_mem_data(os.path.join(out, "rom.bin"),
                                      data_width=self.soc.bus.data_width,
                                      endianness=self.soc.cpu.endianness)
        self.soc.init_rom(name="rom", contents=data, auto_size=True)


def main():
    pre = argparse.ArgumentParser(add_help=False)
    pre.add_argument("--kernel", required=True, help="rv32ima Linux Image (see kernel/)")
    pre.add_argument("--opensbi", required=True, help="OpenSBI fw_jump linked at 0x40780000")
    pre.add_argument("--sysroot", required=True, help="where bin/busybox and its glibc come from")
    args, rest = pre.parse_known_args()
    for f in (args.kernel, args.opensbi, args.sysroot):
        if not os.path.exists(f):
            raise SystemExit("%s: not found" % f)
    args.kernel, args.opensbi, args.sysroot = map(os.path.abspath, (args.kernel, args.opensbi, args.sysroot))

    defaults = ["--cpu-type", "vexriscv_smp", "--cpu-variant", "linux", "--cpu-count", "1",
                "--hardware-breakpoints", "0", "--with-wishbone-memory", "--with-ddr", "--with-ddr64",
                "--with-ethmin-phy", "--l2-size", "131072", "--with-led-chaser",
                "--integrated-rom-size", hex(ROM_WINDOW)]
    given = {a.split("=")[0] for a in rest if a.startswith("--")}
    argv, i = [], 0
    while i < len(defaults):
        opt = defaults[i]
        has_value = i + 1 < len(defaults) and not defaults[i + 1].startswith("--")
        if opt not in given:
            argv += defaults[i:i + 2] if has_value else [opt]
        i += 2 if has_value else 1
    sys.argv = [sys.argv[0]] + argv + rest
    if "--csr-json" not in given:
        out = rest[rest.index("--output-dir") + 1] if "--output-dir" in rest else "build"
        sys.argv += ["--csr-json", os.path.join(out, "csr.json")]

    RomLinuxBuilder.payload_args = args
    base.BaseSoC, base.Builder = RomLinuxSoC, RomLinuxBuilder
    base.main()


if __name__ == "__main__":
    main()
