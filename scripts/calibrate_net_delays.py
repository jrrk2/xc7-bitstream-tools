#!/usr/bin/env python3
"""calibrate_net_delays.py vivado.csv extracted.csv -- how far the extractor's timing is from Vivado's.

Both files list a net's delay from its driver to each load by site pin:
scripts/vivado_net_delays.tcl writes Vivado's four corners for the routes
it made; tileverilog --net-delays writes the database model's fast_min and
slow_max for the routes it recovered from the same design's bitstream.
Joined on (driver, load), the pairs give the model's error per net, which
is what to fix before trusting any slack it reports.
"""
import csv, sys, statistics as st

viv, ext = sys.argv[1:3]
v = {}
for r in csv.DictReader(open(viv)):
    # Vivado reports picoseconds
    v[(r['from'], r['to'])] = tuple(float(r[k]) / 1000 for k in ('fast_min', 'fast_max', 'slow_min', 'slow_max')) + (r['net'],)
e = {}
for r in csv.DictReader(open(ext)):
    e[(r['from'], r['to'])] = (float(r['fast_min']), float(r['slow_max']))
common = sorted(set(v) & set(e))
print(f'{len(v)} Vivado pairs, {len(e)} extracted pairs, {len(common)} joined')
if not common: sys.exit(1)
fm = [(e[k][0], v[k][0]) for k in common]
sm = [(e[k][1], v[k][3]) for k in common]
def fit(pairs, name):
    xs, ys = zip(*pairs)
    n = len(xs); mx, my = sum(xs)/n, sum(ys)/n
    sxy = sum((x-mx)*(y-my) for x, y in pairs); sxx = sum((x-mx)**2 for x in xs)
    a = sxy/sxx if sxx else 0; b = my - a*mx
    res = [y - (a*x+b) for x, y in pairs]
    ratio = [y/x for x, y in pairs if x > 0.01]
    print(f'{name}: vivado = {a:.3f} * model + {b:.3f} ns; residual sd {st.pstdev(res):.3f} ns;'
          f' median ratio {st.median(ratio):.2f}, mean model {mx:.3f} vs vivado {my:.3f}')
    return a, b
fit(fm, 'fast_min')
fit(sm, 'slow_max')
# by size: the short nets are the ones hold depends on
print('by model slow_max bin: n, mean model fast_min -> vivado fast_min, mean model slow_max -> vivado slow_max')
bins = [(0, 0.15), (0.15, 0.3), (0.3, 0.5), (0.5, 1.0), (1.0, 2.0), (2.0, 99)]
for lo, hi in bins:
    ks = [k for k in common if lo <= e[k][1] < hi]
    if not ks: continue
    a = lambda f: sum(f(k) for k in ks) / len(ks)
    print(f'  [{lo:.2f},{hi:.2f}) n={len(ks):6d}  fast {a(lambda k: e[k][0]):.3f} -> {a(lambda k: v[k][0]):.3f}'
          f'   slow {a(lambda k: e[k][1]):.3f} -> {a(lambda k: v[k][3]):.3f}')
# the short direct hops: FF Q -> next slice, the hold-critical shape
short = [k for k in common if e[k][1] < 0.3 and k[0].split('/')[1].endswith('Q')]
if short:
    print(f'FF->next slice, model slow_max < 0.3 ns: n={len(short)}; vivado fast_min min/median/max ='
          f' {min(v[k][0] for k in short):.3f}/{st.median(v[k][0] for k in short):.3f}/{max(v[k][0] for k in short):.3f},'
          f' model fast_min median {st.median(e[k][0] for k in short):.3f}')
worst = sorted(common, key=lambda k: -abs(e[k][1] - v[k][3]))[:12]
print('largest slow_max disagreements (model vs vivado, ns):')
for k in worst:
    print(f'  {e[k][1]:.3f} vs {v[k][3]:.3f}  {k[0]} -> {k[1]}  ({v[k][4]})')
