#!/usr/bin/env python3
"""vivado_place2json.py place.tsv tilegrid.json out.json -- Vivado's placement in nextpnr's shape.

scripts/vivado_placement.tcl dumps cell, primitive, BEL and site; the
extractor's --placement wants {cell: {tile, site, bel, type}}, keyed by the
netlist's own cell names.  The tile comes from the site through the
database's tilegrid, and the names are yosys's -- Vivado keeps them when it
links an EDIF -- so the result lines up with the design.json the LVS reads.
"""
import json, sys

tsv, grid_p, out = sys.argv[1:4]
grid = json.load(open(grid_p))
site_tile = {}
for tile, t in grid.items():
    for site in t.get('sites', {}):
        site_tile[site] = tile
place = {}
missing = 0
for line in open(tsv).read().split('\n')[1:]:
    if not line.strip(): continue
    cell, ref, bel, site = line.split('\t')
    tile = site_tile.get(site)
    if not tile: missing += 1; continue
    bel = bel.split('.')[-1]            # "SLICEL.AFF" -> "AFF"
    typ = {'FDRE': 'SLICE_FFX', 'FDSE': 'SLICE_FFX', 'FDCE': 'SLICE_FFX', 'FDPE': 'SLICE_FFX',
           'RAMB36E1': 'RAMB36E1_RAMB36E1', 'RAMB18E1': 'RAMB18E1_RAMB18E1', 'BUFG': 'BUFGCTRL',
           'DSP48E1': 'DSP48E1_DSP48E1'}.get(ref, 'SLICE_LUTX' if ref.startswith('LUT') else ref)
    # Vivado's escaped names: strip the leading backslash it keeps on yosys's
    cell = cell.lstrip('\\')
    place[cell] = {'tile': tile, 'site': site, 'bel': bel, 'type': typ}
json.dump(place, open(out, 'w'), indent=1)
print(f'{len(place)} cells placed, {missing} on sites the tilegrid does not list')
