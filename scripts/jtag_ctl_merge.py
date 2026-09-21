#!/usr/bin/env python3
"""jtag_ctl_merge.py design.json ctl.json placement.json BUFG_CELL out.json [--status NET...]

Splice a JTAG clock controller (examples/jtag-clkctl, synthesised with
-noiopad -noclkbuf) into a placed design's netlist, and freeze the design's
placement, so the design under test is the one already built:

  - the controller's cells come in under the prefix "tctl.";
  - BUFG_CELL, the global buffer of the clock to gate, becomes a BUFGCE with
    the controller's ce on its CE;
  - a new BUFG "tctl.bufg_free" on the same input gives the controller its
    own copy of that clock, ungated, so ce changes on the gated clock's own
    edges and the gate passes exactly N pulses;
  - every cell the placement names gets a BEL attribute with nextpnr's own
    bel name (the placement JSON's "nextpnr_bel", written by the patched
    nextpnr), which nextpnr's placer binds before placing anything else.

The controller and the new buffer are placed by nextpnr; the routing is
redone for everything.  --status names nets (by their yosys names) whose
values the controller's CAPTURE should present, bit 0 first; unnamed bits
read 0.
"""
import json, sys

args = sys.argv[1:]
status_nets = []
while '--status' in args:
    i = args.index('--status'); status_nets.append(args[i + 1]); del args[i:i + 2]
design_p, ctl_p, place_p, bufg_name, out_p = args[:5]

design = json.load(open(design_p))
top_name = next(k for k, m in design['modules'].items() if m.get('attributes', {}).get('top'))
top = design['modules'][top_name]
ctl = next(m for m in json.load(open(ctl_p))['modules'].values() if m.get('attributes', {}).get('top'))
place = json.load(open(place_p))

# ---- the design's nets by name, and a fresh id space ----
bits_of = {}
for n, d in top['netnames'].items():
    bits_of[n] = d['bits']
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

def remap(b):
    return b if not isinstance(b, int) else base + b

# ---- the target buffer ----
bufg = top['cells'][bufg_name]
assert bufg['type'] in ('BUFG', 'BUFGCE'), f'{bufg_name} is a {bufg["type"]}'
clk_in = bufg['connections']['I']
free_net = [base + 10**7]        # a fresh bit for the ungated copy
ce_net = [base + 10**7 + 1]
bufg['type'] = 'BUFGCE'
bufg['connections']['CE'] = ce_net
bufg['port_directions']['CE'] = 'input'
top['cells']['tctl.bufg_free'] = {
    'hide_name': 0, 'type': 'BUFG', 'parameters': {}, 'attributes': {},
    'port_directions': {'I': 'input', 'O': 'output'},
    'connections': {'I': clk_in, 'O': free_net}}
top['netnames']['tctl.clk_free'] = {'hide_name': 0, 'bits': free_net, 'attributes': {}}
top['netnames']['tctl.ce'] = {'hide_name': 0, 'bits': ce_net, 'attributes': {}}

# ---- the controller's ports -> the design's nets ----
port_map = {}
for pin, p in ctl['ports'].items():
    if pin == 'clk_free': port_map.update({p['bits'][0]: free_net[0]})
    elif pin == 'ce': port_map.update({p['bits'][0]: ce_net[0]})
    elif pin == 'status':
        status_bits = []
        for n in status_nets:
            status_bits.extend(bits_of.get(n, []))
        for i, b in enumerate(p['bits']):
            port_map[b] = status_bits[i] if i < len(status_bits) else '0'
def ctl_bit(b):
    if not isinstance(b, int): return b
    return port_map.get(b, remap(b))
for cn, c in ctl['cells'].items():
    c2 = json.loads(json.dumps(c))
    c2['connections'] = {k: [ctl_bit(b) for b in v] for k, v in c['connections'].items()}
    top['cells']['tctl.' + cn] = c2
for n, d in ctl['netnames'].items():
    top['netnames']['tctl.' + n] = {'hide_name': d.get('hide_name', 0), 'attributes': d.get('attributes', {}),
                                    'bits': [ctl_bit(b) for b in d['bits']]}

# ---- freeze the placement ----
pinned = missing = 0
for cn, pl in place.items():
    c = top['cells'].get(cn)
    if c is None:
        missing += 1; continue
    if 'nextpnr_bel' not in pl:
        sys.exit('the placement has no nextpnr_bel entries: it needs the patched nextpnr -o placement=')
    c.setdefault('attributes', {})['BEL'] = pl['nextpnr_bel']; pinned += 1
print(f'{len(ctl["cells"])} controller cells spliced; {pinned} cells pinned, {missing} placement entries have no netlist cell (packer-made)', file=sys.stderr)
json.dump(design, open(out_p, 'w'))
print('wrote', out_p, file=sys.stderr)
