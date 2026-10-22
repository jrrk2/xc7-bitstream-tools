#!/usr/bin/env python3
"""The ROM test's expected values, from the host's copy of the ROM:

  expected.h  each payload image's CRC32 as stored, and the CRC32 of each
              64 KiB block it unpacks to
  romsig.h    the XOR of each 256-word block of the ROM

    romtest_data.py --rom rom.bin --payload-address 0x30000 --out DIR

The unpacker and ROM test partitions are skipped by the test, so rom.bin may
hold either version of them."""
import argparse, lzma, os, struct, zlib

ap = argparse.ArgumentParser()
ap.add_argument("--rom", required=True)
ap.add_argument("--payload-address", type=lambda s: int(s, 0), required=True)
ap.add_argument("--out", required=True)
a = ap.parse_args()

rom = open(a.rom, "rb").read()
rom += b"\0" * (-len(rom) % 4)
p = rom[a.payload_address:]
magic, count, entry, _ = struct.unpack_from("<4sIII", p)
assert magic == b"LXRP", "no payload at 0x%x" % a.payload_address
rom_crc, nblocks, blocks = [], [], []
for i in range(count):
    dest, off, csize, usize = struct.unpack_from("<IIII", p, 16 + 16 * i)
    c = p[off:off + csize]
    rom_crc.append(zlib.crc32(c))
    d = lzma.decompress(c)
    assert len(d) == usize
    b = [zlib.crc32(d[k:k + 65536]) for k in range(0, usize, 65536)]
    nblocks.append(len(b))
    blocks += b
hexes = lambda v: ",".join("0x%08x" % x for x in v)
open(os.path.join(a.out, "expected.h"), "w").write(
    "/* romtest_data.py: the payload images, from the host */\n"
    "#define NIMAGES %d\n" % count +
    "static const uint32_t rom_crc[NIMAGES] = {%s};\n" % hexes(rom_crc) +
    "static const uint32_t nblocks[NIMAGES] = {%s};\n" % ",".join(map(str, nblocks)) +
    "static const uint32_t blk_crc[] = {%s};\n" % hexes(blocks))

w = struct.unpack("<%dI" % (len(rom) // 4), rom)
sig = []
for b in range(0, len(w), 256):
    v = 0
    for x in w[b:b + 256]:
        v ^= x
    sig.append(v)
open(os.path.join(a.out, "romsig.h"), "w").write(
    "/* romtest_data.py: the XOR of each 256-word block of the ROM */\n"
    "#define ROM_WORDS %d\n" % len(w) +
    "static const uint32_t rom_xor[] = {%s};\n" % hexes(sig))
print("romtest data: %d images, %d ROM blocks" % (count, len(sig)))
