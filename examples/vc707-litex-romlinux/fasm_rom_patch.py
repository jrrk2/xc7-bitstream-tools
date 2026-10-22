#!/usr/bin/env python3
"""Rewrite the LiteX ROM's contents in a routed FASM, leaving placement and
routing alone.  The ROM is rom_inst_t<D>_d<T>: RAMB36 x1, bit D of words
T*32768.., and in the FASM ROM address a of a RAMB36 is RAMB18_Y(a%2) bit a//2.

  fasm_rom_patch.py placement.json in.fasm old_rom.bin new_rom.bin out.fasm"""
import json, re, struct, sys

plj, fin, oldf, newf, fout = sys.argv[1:]
pl = json.load(open(plj))
words = lambda f: struct.unpack('<%dI' % (len(open(f, 'rb').read()) // 4), open(f, 'rb').read())
old, new = words(oldf), words(newf)
assert len(old) == len(new)
changed = [w for w in range(len(old)) if old[w] != new[w]]
tiles = sorted({w // 32768 for w in changed})
print('%d words differ, in ROM tiles %s' % (len(changed), tiles))

rx = re.compile(r"(BRAM_\w+)\.RAMB18_Y(\d)\.INIT_([0-9A-F]{2})\[255:0\] = 256'b([01]+)")
lines = open(fin).read().split('\n')
have = {}
for i, l in enumerate(lines):
    m = rx.match(l)
    if m:
        have[(m[1], int(m[2]), int(m[3], 16))] = i

def init_strings(rom, t, d):
    """the FASM INIT strings of one ROM cell: {(y, index): 256-char string}"""
    out = {}
    for y in (0, 1):
        bits = []
        for b in range(16384):
            w = t * 32768 + 2 * b + y
            bits.append((rom[w] >> d) & 1 if w < len(rom) else 0)
        for i in range(64):
            out[(y, i)] = ''.join(str(x) for x in reversed(bits[i * 256:(i + 1) * 256]))
    return out

add, edits, verified = [], 0, 0
for t in tiles:
    for d in range(32):
        cell = 'rom_inst_t%d_d%d' % (d, t)
        if cell not in pl:
            sys.exit('%s not placed (constant bit?): cannot patch' % cell)
        tile = pl[cell]['tile']
        o, n = init_strings(old, t, d), init_strings(new, t, d)
        for (y, i), s in o.items():
            k = (tile, y, i)
            cur = rx.match(lines[have[k]])[4] if k in have else '0' * 256
            if cur != s:
                sys.exit('%s %s: FASM does not hold the old ROM' % (cell, k))
            verified += 1
            if n[(y, i)] == s:
                continue
            l = "%s.RAMB18_Y%d.INIT_%02X[255:0] = 256'b%s" % (tile, y, i, n[(y, i)])
            if k in have:
                lines[have[k]] = l
            else:
                add.append(l)
            edits += 1
open(fout, 'w').write('\n'.join(lines + add))
print('verified %d INIT strings against the old ROM; %d rewritten (%d new lines)' % (verified, edits, len(add)))
