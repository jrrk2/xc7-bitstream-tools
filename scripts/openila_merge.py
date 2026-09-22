#!/usr/bin/env python3
"""openila_merge.py design.json ila.json out.json --clk NET --probe NET[/N] ... [--prefix ila.]

Splice a synthesised openila (examples/openila, yosys with -noiopad
-noclkbuf and chparam'd to the WIDTH/DEPTH wanted) into a design's yosys
netlist.  --clk names the design net (yosys name, after its BUFG) the
probes are sampled on; each --probe names a net whose bits fill the probe
word in order, LSB first, a bus's bits low to high; NET/N takes the first N
bits.  Unfilled probe bits read 0.  Writes the probe map (bit -> net name)
to stderr and out.json.map for the host script.

The design's cells are untouched, so the ILA can be added to a build whose
placement and routing are then replayed with nextpnr's -o preplaced /
-o prerouted: only the ILA and the probed nets' new branches are new.
"""
import json, re, sys

args = sys.argv[1:]
clk = None; probes = []; prefix = 'ila.'
i = 0; pos = []
while i < len(args):
    if args[i] == '--clk': clk = args[i + 1]; i += 2
    elif args[i] == '--probe': probes.append(args[i + 1]); i += 2
    elif args[i] == '--prefix': prefix = args[i + 1]; i += 2
    else: pos.append(args[i]); i += 1
design_p, ila_p, out_p = pos
if clk is None: sys.exit('--clk is required')

design = json.load(open(design_p))
top_name = next(k for k, m in design['modules'].items() if m.get('attributes', {}).get('top'))
top = design['modules'][top_name]
ila = next(m for m in json.load(open(ila_p))['modules'].values() if m.get('attributes', {}).get('top'))

bits_of = {n: d['bits'] for n, d in top['netnames'].items()}
def find(n):
    if n in bits_of: return bits_of[n]
    m = re.fullmatch(r'(.*)\[(\d+)\]', n)
    if m and m.group(1) in bits_of: return [bits_of[m.group(1)][int(m.group(2))]]
    sys.exit(f'no net {n!r} in {top_name}')

maxid = 0
for m in design['modules'].values():
    for d in m['netnames'].values():
        for b in d['bits']:
            if isinstance(b, int): maxid = max(maxid, b)
    for c in m['cells'].values():
        for v in c['connections'].values():
            for b in v:
                if isinstance(b, int): maxid = max(maxid, b)
base = maxid + 1

# ---- probe word ----
probe_bits = []; probe_map = []
for p in probes:
    name, _, n = p.partition('/')
    bits = find(name)
    if n: bits = bits[:int(n)]
    for k, b in enumerate(bits):
        if b == 'x':
            print(f'  {name}[{k}] is undriven in the netlist (optimised away): probed as 0', file=sys.stderr); b = '0'
        probe_bits.append(b)
        probe_map.append(f'{name}[{k}]' if len(bits) > 1 else name)
width = len(ila['ports']['probe']['bits'])
if len(probe_bits) > width: sys.exit(f'{len(probe_bits)} probe bits for a {width}-bit ILA')
port_map = {}
for k, b in enumerate(ila['ports']['probe']['bits']):
    port_map[b] = probe_bits[k] if k < len(probe_bits) else '0'
port_map[ila['ports']['clk']['bits'][0]] = find(clk)[0]

def ila_bit(b):
    if not isinstance(b, int): return b
    return port_map.get(b, base + b)
for cn, c in ila['cells'].items():
    c2 = json.loads(json.dumps(c))
    c2['connections'] = {k: [ila_bit(b) for b in v] for k, v in c['connections'].items()}
    top['cells'][prefix + cn] = c2
for n, d in ila['netnames'].items():
    if all(b in port_map or not isinstance(b, int) for b in d['bits']):
        continue   # the design's own nets keep their names: an alias here could become nextpnr's name for them
    top['netnames'][prefix + n] = {'hide_name': d.get('hide_name', 0), 'attributes': d.get('attributes', {}),
                                   'bits': [ila_bit(b) for b in d['bits']]}
json.dump(design, open(out_p, 'w'))
with open(out_p + '.map', 'w') as f:
    for k, n in enumerate(probe_map): f.write(f'{k} {n}\n')
print(f'{len(ila["cells"])} ILA cells spliced as {prefix}*; {len(probe_bits)} of {width} probe bits used on {clk}', file=sys.stderr)
for k, n in enumerate(probe_map): print(f'  probe[{k}] = {n}', file=sys.stderr)
