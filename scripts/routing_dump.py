#!/usr/bin/env python3
"""routing_dump.py routed.json routes.txt [bels.txt] -- a build's routes and bels, for nextpnr.

routed.json is nextpnr's --write output: every net carries a ROUTING
attribute (wire;pip;strength triples) and every placed cell a NEXTPNR_BEL.
routes.txt is one line per net, name TAB route, for -o prerouted=; bels.txt
one line per cell, name TAB bel, for -o preplaced=.  Together they make a
later run of the same design (plus something new) keep this build's
placement and routing.
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
