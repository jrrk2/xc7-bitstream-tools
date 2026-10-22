#!/usr/bin/env python3
"""export_synthgui.py <litex build dir> <synthgui root> [name]

Copy a vc707_romlinux.py build's gateware into synthgui as a self-contained
project: projects/<name>-src/ (the Verilog, the ROM and RAM .init files, the
XDC, the VexRiscv-SMP cluster and its RAM primitive, ethmin's SGMII PHY, the
nextpnr delay matrix) and projects/<name>.json, from the vc707_ethmin project's
flow steps.
"""
import glob, json, os, re, shutil, sys

here = os.path.dirname(os.path.abspath(__file__))
tools = os.path.abspath(os.path.join(here, "..", ".."))
build, sg = map(os.path.abspath, sys.argv[1:3])
name = sys.argv[3] if len(sys.argv) > 3 else "vc707_romlinux"
top = "xilinx_vc707"
gw = os.path.join(build, "gateware")
src = os.path.join(sg, "projects", name + "-src")
os.makedirs(src, exist_ok=True)

files = {
    "Ram_1w_1rs_Generic.v": os.path.join(tools, "litex-deps/pythondata-cpu-vexriscv-smp/"
                                         "pythondata_cpu_vexriscv_smp/verilog/Ram_1w_1rs_Generic.v"),
    "liteeth_sgmii_phy.v": os.path.join(tools, "examples/vc707-ethmin/rtl/liteeth_sgmii_phy.v"),
    "delay-matrix-xc7vx485t.txt": os.path.join(tools, "examples/vc707-litex-ddr-ethmin/delay-matrix-xc7vx485t.txt"),
}
cluster = glob.glob(os.path.join(gw, "VexRiscvLitexSmpCluster_*.v"))
assert len(cluster) == 1, cluster
for f in cluster + glob.glob(os.path.join(gw, top + "*.init")) + [os.path.join(gw, top + ".v"), os.path.join(gw, top + ".xdc")]:
    files[os.path.basename(f)] = f
for dst, f in files.items():
    shutil.copyfile(f, os.path.join(src, dst))
for f in ("rom.bin", "romlinux.dts", "payload.bin"):
    shutil.copyfile(os.path.join(build, "romlinux", f), os.path.join(src, f))

# Black boxes: the Xilinx primitives the design instantiates and does not
# define -- worked out the way xc7-bitstream-tools' scripts/synth.sh does
cells = os.path.join(sg, "deps/yosys/share/xilinx")
strip = re.compile(r"//[^\n]*|/\*.*?\*/", re.S)
decl = re.compile(r"^\s*(?:module|macromodule)\s+(\w+)", re.M)
prims = set()
for f in ("cells_sim.v", "cells_xtra.v"):
    prims |= set(decl.findall(open(os.path.join(cells, f), errors="replace").read()))
verilog = [f for f in sorted(files) if f.endswith(".v")]
order = ["Ram_1w_1rs_Generic.v", os.path.basename(cluster[0]), "liteeth_sgmii_phy.v", top + ".v"]
assert sorted(order) == verilog, verilog
defined, used = set(), set()
inst = re.compile(r"^\s*(\w+)\s*(?:#\s*\(|\w+\s*\(|\\\S+\s*\()", re.M)
for f in order:
    t = strip.sub("", open(os.path.join(src, f), errors="replace").read())
    defined |= set(decl.findall(t))
    used |= set(inst.findall(t))
blackboxes = sorted((used & prims) - defined)

p = json.load(open(os.path.join(sg, "projects", "vc707_ethmin.json")))
r = "{root}/projects/%s-src" % name
p.update({
    "name": "vc707 LiteX Linux from ROM",
    "top": top,
    "work": "~/synthgui-work/" + name,
    "xdc": r + "/" + top + ".xdc",
    "srcdir": r,
    "sources": [r + "/" + f for f in order],
    "incdirs": [r],
    "defines": ["SYNTHESIS"],
    "blackboxes": blackboxes,
    "nextpnr": "{builds}/nextpnr/nextpnr-himbaechel",
    # The flags the board build used (see the README): the measured delay
    # matrix and a raised timing weight close the DDR clock, congestion
    # spreading is what makes it work at all, and the clock-tree model and
    # block RAM placement are what make the ROM read correctly
    "options": {
        "pnr.router": "router2",
        "pnr.allow_fail": "1",
        "pnr.hold_fix": "8",
        "pnr.delay_matrix": r + "/delay-matrix-xc7vx485t.txt",
        "pnr.timingweight": "100",
        "pnr.cong_spread": "1",
        "pnr.clock_tree": "on",
        "pnr.bram_place": "on",
    },
    # bram_fom.py's score of the block RAM placement, worst/p95 in ps: every
    # placement that read the ROM on the board was 5995 or less worst, the
    # two that did not 6251 and 6961 (the p95 limit is a backstop)
    "bram_fom_budget": "6100/5400",
})
# The block RAM figure of merit, after place and route
fom = {"id": "fom", "label": "Block RAM merit",
       "command": "{python} {bram_fom} --netlist {json} --tilegrid {prjxray_db}/{family}/{device}/tilegrid.json "
                  "--delay-matrix {delay_matrix_file} {top}={placement}"}
steps = [s for s in p["steps"] if s["id"] != "fom"]
p["steps"] = steps[:[s["id"] for s in steps].index("pnr") + 1] + [fom] + steps[[s["id"] for s in steps].index("pnr") + 1:]
p.pop("nextpnr_flags", None)
json.dump(p, open(os.path.join(sg, "projects", name + ".json"), "w"), indent=2)
open(os.path.join(sg, "projects", name + ".json"), "a").write("\n")
print("wrote projects/%s.json and %d files in projects/%s-src; black boxes: %s"
      % (name, len(os.listdir(src)), name, " ".join(blackboxes)))
