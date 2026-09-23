#!/usr/bin/env python3
"""check_bit_owners.py <db-root/family> <part> <design.fasm> -- does one
bitstream bit belong to two tiles?

prjxray's assembler already refuses a FASM where one line sets a bit another
clears (FasmInconsistentBits).  It says nothing when two tiles set the same
bit to the same value, and that silence is the dangerous case: the bitstream
assembles, the board takes it, and something far from either tile behaves
differently -- an I/O pin's pull-down arriving as an interconnect pip, say.

A bit belongs to exactly one tile.  When the database says otherwise, every
design that configures both tiles is quietly wrong, and only the designs
that happen to agree on the value get as far as the board.  So this reports
any bit two tiles claim, whatever values they wanted.
"""
import collections, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
sys.path.insert(0, os.path.join(ROOT, "prjxray"))

import fasm_fast
fasm_fast.install()

from prjxray import fasm_assembler, db as prjxray_db

db_root, part, fasm_path = sys.argv[1:4]
database = prjxray_db.Database(db_root, part)
assembler = fasm_assembler.FasmAssembler(database)

owner = {}                       # (frame, word, bit) -> tile that claimed it
clashes = collections.defaultdict(set)


def tile_of(line):
    return str(line).strip().split('.')[0]


def watch(method):
    def wrapped(frame_addr, word_addr, bit_index, line):
        key = (frame_addr, word_addr, bit_index)
        tile = tile_of(line)
        seen = owner.get(key)
        if seen is not None and seen != tile:
            clashes[key] |= {seen, tile}
        else:
            owner[key] = tile
        return method(frame_addr, word_addr, bit_index, line)
    return wrapped


assembler.frame_set = watch(assembler.frame_set)
assembler.frame_clear = watch(assembler.frame_clear)

try:
    assembler.parse_fasm_filename(fasm_path)
except fasm_assembler.FasmInconsistentBits as e:
    # a contradiction is the same fault, caught by the assembler first
    print(f"check_bit_owners: {e}", file=sys.stderr)

if not clashes:
    print(f"check_bit_owners: every bit in {os.path.basename(fasm_path)} belongs to one tile")
    sys.exit(0)

pairs = collections.Counter()
for tiles in clashes.values():
    pairs[tuple(sorted(tiles))] += 1
print(f"check_bit_owners: {len(clashes)} bit(s) claimed by two tiles", file=sys.stderr)
for (a, b), n in pairs.most_common(12):
    print(f"   {n:6d}  {a}  and  {b}", file=sys.stderr)
print("\nA bit belongs to one tile: this is the database's tile grid disagreeing\n"
      "with the silicon, not the design.  The bitstream would configure one of\n"
      "these tiles by accident.", file=sys.stderr)
sys.exit(1)
