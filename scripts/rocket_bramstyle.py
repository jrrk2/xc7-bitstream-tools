#!/usr/bin/env python3
"""Mark LiteX's wide, shallow AXI buffers as block RAM.

    scripts/rocket_bramstyle.py <top.v>            # edits in place

Rocket with --cpu-mem-width 8 gives LiteDRAM a 512-bit port, and the AXI
read/write buffers either side of it come out as memories like

    reg [583:0] storage_10[0:15];      16 words x 584 bits
    reg [521:0] storage_13[0:15];      16 words x 522 bits

Wide and shallow is the worst case for yosys' default inference: it maps
them to distributed RAM, which costs thousands of LUTs for something a
single RAMB36 holds.  `(* ram_style = "block" *)` says what the hardware
obviously wants.

Chosen by SHAPE rather than by name or line number.  storage_10 and
storage_13 are whatever LiteX numbered them on the day; regenerate the SoC
with one more memory anywhere and the names move, which is exactly how an
in-place patch goes stale without telling anyone.
"""
import re
import sys

WIDE = 256       # bits: anything this wide is not distributed-RAM material
SHALLOW = 64     # words: and this shallow fits a single block RAM

def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    src = open(path).read()
    if 'ram_style' in src:
        print("%s already annotated, leaving it alone" % path)
        return 0

    decl = re.compile(r'^(\s*)reg \[(\d+):0\] (\w+)\[0:(\d+)\];$', re.M)
    hits = []

    def mark(m):
        indent, hi, name, last = m.group(1), int(m.group(2)), m.group(3), int(m.group(4))
        if hi + 1 >= WIDE and last + 1 <= SHALLOW:
            hits.append((name, hi + 1, last + 1))
            return '%s(* ram_style = "block" *)\n%s' % (indent, m.group(0))
        return m.group(0)

    out = decl.sub(mark, src)
    if not hits:
        sys.exit("%s: no wide/shallow memories found -- has the SoC changed?" % path)
    open(path, 'w').write(out)
    for name, w, d in hits:
        print("  block RAM: %-14s %d words x %d bits" % (name, d, w))
    return 0

if __name__ == '__main__':
    sys.exit(main())
