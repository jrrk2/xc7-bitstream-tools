#!/usr/bin/env python3
"""ff_state.py -- flip-flop state as bitstream bits, both ways.

  ff_state.py read  design.fasm placement.json design.json            > state.txt
  ff_state.py write design.fasm placement.json design.json state.txt  > out.fasm

A slice flip-flop's value is one bit of the bitstream: its ZINI feature
(<tile>.<slice>.<bel>.ZINI; present means 0).  On a readback with capture
the same bit holds the live value, so `read` on a readback-derived FASM
(readback2bit.py + bit2fasm) is scan-out, and `write` on the design's FASM
is scan-in: every flop named in state.txt ("<net name> <0|1>" per line)
has its ZINI set accordingly, the rest untouched.  Net names are yosys's;
a flop that yosys merged with another answers to every name of the merged
net, and `read` prints one line per name.
"""
import json, re, sys

mode, fasm_p, place_p, design_p = sys.argv[1:5]
place = json.load(open(place_p))
top = json.load(open(design_p))['modules']
top = next(m for m in top.values() if m.get('attributes', {}).get('top'))
names_of = {}
for n, d in top['netnames'].items():
    for i, b in enumerate(d['bits']):
        if isinstance(b, int):
            names_of.setdefault(b, []).append(n if len(d['bits']) == 1 else f"{n}[{i}]")

def feature(pl):
    sx = int(re.search(r'X(\d+)', pl['site']).group(1)) % 2
    kind = pl['tile'].split('_X')[0]
    slice_kind = 'M' if kind.startswith('CLBLM') and sx == 0 else 'L'
    return f"{pl['tile']}.SLICE{slice_kind}_X{sx}.{pl['bel']}.ZINI"

flops = {}               # feature -> [names]
for cn, c in top['cells'].items():
    if not c['type'].startswith('FD'): continue
    pl = place.get(cn)
    if not pl or pl['type'] != 'SLICE_FFX': continue
    q = c['connections']['Q'][0]
    flops[feature(pl)] = sorted(n for n in names_of.get(q, [cn]) if not n.startswith('$')) or [cn]

lines = open(fasm_p).read().split('\n')
present = set(l.strip() for l in lines if l.strip().endswith('.ZINI'))

if mode == 'read':
    for feat, names in sorted(flops.items(), key=lambda kv: kv[1][0]):
        v = 0 if feat in present else 1
        for n in names: print(n, v)
elif mode == 'write':
    want = {}
    for l in open(sys.argv[5]):
        l = l.split('#')[0].split()
        if len(l) == 2: want[l[0]] = int(l[1])
    by_name = {n: feat for feat, names in flops.items() for n in names}
    edits = {}
    unknown = [n for n in want if n not in by_name]
    if unknown: print(f'{len(unknown)} names not placed as flops (ignored): {unknown[:5]}', file=sys.stderr)
    for n, v in want.items():
        if n in by_name: edits[by_name[n]] = v
    out = [l for l in lines if l.strip() not in edits or edits[l.strip()] == 0]
    for feat, v in edits.items():
        if v == 0 and feat not in present: out.append(feat)
    sys.stdout.write('\n'.join(out) + ('\n' if out and out[-1] else ''))
    print(f'{len(edits)} flops set', file=sys.stderr)
else:
    sys.exit(__doc__)
