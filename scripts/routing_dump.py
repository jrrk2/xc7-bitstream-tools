#!/usr/bin/env python3
"""routing_dump.py routed.json routes.txt [bels.txt [holdbufs.txt]] -- a build's routes, bels
and hold-fix buffers, for nextpnr.

routed.json is nextpnr's --write output: every net carries a ROUTING
attribute (wire;pip;strength triples) and every placed cell a NEXTPNR_BEL.
routes.txt is one line per net, name TAB route, for -o prerouted=; bels.txt
one line per cell, name TAB bel, for -o preplaced=; holdbufs.txt one line
per hold-fix feedthrough buffer (name, input net, output net, the sink cell
and port it feeds), for -o holdbufs=, which re-creates them before placing
so that the reference's bels and routes have every cell and net they name.
Together they make a later run of the same design (plus something new)
keep this build's placement and routing.
"""
import json, sys
m = json.load(open(sys.argv[1]))['modules']
top = next(v for v in m.values() if v.get('attributes', {}).get('top'))
n = 0
with open(sys.argv[2], 'w') as f:
    for name, net in top['netnames'].items():
        r = net.get('attributes', {}).get('ROUTING')
        if r:
            f.write(f'{name}\t{r}\n'); n += 1
print(f'{n} routed nets', file=sys.stderr)
if len(sys.argv) > 3:
    b = 0
    with open(sys.argv[3], 'w') as f:
        for name, cell in top['cells'].items():
            bel = cell.get('attributes', {}).get('NEXTPNR_BEL')
            if bel:
                f.write(f'{name}\t{bel}\n'); b += 1
    print(f'{b} placed cells', file=sys.stderr)
if len(sys.argv) > 4:
    net_of = {}
    for name, net in top['netnames'].items():
        for b in net['bits']:
            if isinstance(b, int): net_of.setdefault(b, name)
    users = {}   # bit -> [(cell, port)]
    for name, cell in top['cells'].items():
        for port, bits in cell['connections'].items():
            if cell['port_directions'].get(port) == 'input':
                for b in bits:
                    if isinstance(b, int): users.setdefault(b, []).append((name, port))
    h = 0
    with open(sys.argv[4], 'w') as f:
        for name, cell in top['cells'].items():
            if '$holdbuf' not in name or cell['type'] != 'SLICE_LUTX': continue
            ins = [b for port, bits in cell['connections'].items() if port.startswith('A') for b in bits if isinstance(b, int)]
            outs = [b for b in cell['connections'].get('O6', []) if isinstance(b, int)]
            if len(ins) != 1 or len(outs) != 1 or len(users.get(outs[0], [])) != 1:
                print(f'{name}: not a simple feedthrough, skipped', file=sys.stderr); continue
            sc, sp = users[outs[0]][0]
            f.write(f'{name}\t{net_of[ins[0]]}\t{net_of[outs[0]]}\t{sc}\t{sp}\n'); h += 1
    print(f'{h} hold-fix buffers', file=sys.stderr)
