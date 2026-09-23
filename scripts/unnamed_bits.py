#!/usr/bin/env python3
"""unnamed_bits.py <db/family> <part> <reference.bit> -- what the database cannot say.

A bitstream Vivado made is ground truth: every bit it sets means something.
The database can only describe a bit if some feature names that position in
the tile's own coordinates.  A bit that is set in a tile whose type has no
feature naming that position is terra incognita -- silicon the fuzzers have
not reached, and a bit the open flow can neither write nor read back.

That is not a curiosity.  A single such bit on the VC707 was the input
enable of one half of an I/O tile: Vivado set it, no feature could express
it, the open flow left it clear, and the board sat in reset with every
check passing.  This finds that class before the board does.

Reports per tile type: how many distinct positions are set-but-unnameable,
how many tiles show them, and an example tile for each position, so a
fuzzer can be pointed straight at it.
"""
import collections, json, os, subprocess, sys

db_family, part, bitfile = sys.argv[1:4]
dirs = [d for d in os.listdir(db_family) if os.path.isdir(os.path.join(db_family, d))]
device_dir = next(d for d in sorted(dirs, key=len, reverse=True)
                  if part.startswith(d) and os.path.exists(os.path.join(db_family, d, 'tilegrid.json')))
part_dir = next(d for d in dirs if os.path.exists(os.path.join(db_family, d, 'part.yaml'))
                and part.startswith(d.split('-')[0]))

tilegrid = json.load(open(os.path.join(db_family, device_dir, 'tilegrid.json')))

# positions any feature of a tile type can name, as "<minor>_<index>"
named = collections.defaultdict(set)
for path in os.listdir(db_family):
    if not (path.startswith(('segbits_', 'ppips_')) and path.endswith('.db')):
        continue
    if 'origin_info' in path or 'mask_' in path:
        continue
    for line in open(os.path.join(db_family, path)):
        parts = line.split()
        if len(parts) < 2:
            continue
        tile_type = parts[0].split('.')[0]
        for bit in parts[1:]:
            bit = bit.lstrip('!')
            if '_' in bit and bit.split('_')[0].isdigit():   # "always" and ppip tags are not positions
                named[tile_type].add(bit)

bitread = os.path.expanduser('~/xc7-bitstream-tools/prjxray/build/tools/bitread')
part_yaml = os.path.join(db_family, part_dir, 'part.yaml')
out = subprocess.run([bitread, '--part_file', part_yaml, '-x', bitfile],
                     capture_output=True, text=True).stdout
set_bits = collections.defaultdict(set)          # frame -> {(word, bit)}
for line in out.splitlines():
    f = line.split('_')
    if len(f) < 4:
        continue
    try:
        set_bits[int(f[1], 16)].add((int(f[2]), int(f[3])))
    except ValueError:
        pass
print(f"{sum(len(v) for v in set_bits.values())} bits set in {os.path.basename(bitfile)}")

# A tile's frames are shared with its neighbours in the column -- a CLB's
# span covers the INT tile's minors too -- so a bit only belongs to this
# type if its minor is one this type's own features use.  Contents are not
# features: BLOCK_RAM holds memory, not configuration.
own_minors = {t: {int(b.split('_')[0]) for b in bits} for t, bits in named.items()}

unnamed = collections.defaultdict(lambda: collections.defaultdict(list))
for tile, entry in tilegrid.items():
    ttype = entry['type']
    for block_name, block in entry.get('bits', {}).items():
        if block_name == 'BLOCK_RAM':
            continue
        base = block['baseaddr']
        base = int(base, 16) if isinstance(base, str) else base
        off, words, frames = block['offset'], block['words'], block['frames']
        for minor in sorted(own_minors.get(ttype, ())):
            if minor >= frames:
                continue
            frame = base + minor
            for (word, bit) in set_bits.get(frame, ()):
                if not (off <= word < off + words):
                    continue
                pos = f"{minor}_{(word - off) * 32 + bit:02d}"
                if pos not in named.get(ttype, ()):
                    unnamed[ttype][pos].append(tile)

if not unnamed:
    print("every set bit is one the database can name")
    sys.exit(0)
print(f"\n{'tile type':22s} {'positions':>9s} {'tiles':>7s}   examples")
for ttype in sorted(unnamed, key=lambda t: -len(unnamed[t])):
    positions = unnamed[ttype]
    tiles = {t for v in positions.values() for t in v}
    sample = sorted(positions)[:4]
    detail = ', '.join(f"{p} (e.g. {positions[p][0]})" for p in sample)
    print(f"{ttype:22s} {len(positions):9d} {len(tiles):7d}   {detail}")
