#!/usr/bin/env bash
# Synthesise a design to a yosys-JSON netlist of Xilinx 7-series primitives,
# the form nextpnr-himbaechel reads, with whichever synthesiser SYNTH names.
#
#   SYNTH=verilator (default)  the Verilator synthesis backend pinned as the
#                              `verilator` submodule (`make verilator`): the
#                              design is elaborated by Verilator itself, so
#                              SystemVerilog needs no sv2v pass, and mapped to
#                              LUTs, carry chains, DSPs and block RAM in process
#                              by ABC.
#   SYNTH=yosys                the pinned yosys's synth_xilinx, as before.
#
#   synth.sh --top TOP --out NETLIST.json [--edif NETLIST.edf] [--nobram] [--sv]
#            [-I DIR]... [-D NAME[=VALUE]]... SOURCE...
#   synth.sh --check           resolve and check the synthesiser, print it, exit
#
# Runs in the current directory, which matters: a design that $readmemh's its
# memory contents from a relative path reads them relative to here, and from
# anywhere else the memory reads as zero without a word of complaint.
#
#   --nobram   yosys: synth_xilinx -nobram.  Verilator infers block RAM only
#              where a memory is too big for distributed RAM, so it has no
#              equivalent and none is needed; the flag is accepted and ignored.
#   --sv       yosys: read every source with -sv.  Verilator always reads
#              SystemVerilog.
#   --edif     also write an EDIF netlist for Vivado (Verilator only).
#
#   VERILATOR_ABC_SCRIPT  ABC script for the LUT mapping, in place of the
#                         backend's default.
set -u -o pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
say() { printf '%s\n' "$*" >&2; }
synth=${SYNTH:-verilator}

resolve() {
    case "$synth" in
        verilator) "$root/scripts/pinned_verilator.sh" ;;
        yosys)     "$root/scripts/pinned_yosys.sh" ;;
        *)         say "SYNTH must be verilator or yosys, not '$synth'"; return 2 ;;
    esac
}

if [ "${1:-}" = "--check" ]; then
    resolve
    exit $?
fi

top= out= edif= nobram= sv=
incs=() defs=() srcs=()
while [ $# -gt 0 ]; do
    case "$1" in
        --top)    top=$2; shift 2 ;;
        --out)    out=$2; shift 2 ;;
        --edif)   edif=$2; shift 2 ;;
        --nobram) nobram=-nobram; shift ;;
        --sv)     sv=-sv; shift ;;
        -I)       incs+=("$2"); shift 2 ;;
        -I*)      incs+=("${1#-I}"); shift ;;
        -D)       defs+=("$2"); shift 2 ;;
        -D*)      defs+=("${1#-D}"); shift ;;
        -*)       say "synth.sh: unknown option $1"; exit 2 ;;
        *)        srcs+=("$1"); shift ;;
    esac
done
[ -n "$top" ] && [ -n "$out" ] && [ ${#srcs[@]} -gt 0 ] || {
    say "usage: synth.sh --top TOP --out NETLIST.json [options] SOURCE..."; exit 2; }

tool=$(resolve) || exit 2

if [ "$synth" = yosys ]; then
    [ -z "$edif" ] || { say "synth.sh: --edif is for SYNTH=verilator"; exit 2; }
    if [ -z "$sv" ] && [ ${#incs[@]} -eq 0 ] && [ ${#defs[@]} -eq 0 ]; then
        # Sources on the command line, read by extension: exactly what the
        # targets did before this script existed.
        exec "$tool" -q -p "synth_xilinx -flatten -abc9 $nobram -arch xc7 -top $top; write_json $out" "${srcs[@]}"
    fi
    opts=$sv
    for i in ${incs[@]+"${incs[@]}"}; do opts+=" -I$i"; done
    for d in ${defs[@]+"${defs[@]}"}; do opts+=" -D$d"; done
    exec "$tool" -q -p "read_verilog $opts ${srcs[*]}; synth_xilinx -flatten -abc9 $nobram -arch xc7 -top $top; write_json $out"
fi

# --- Verilator ---------------------------------------------------------------
vroot=$(dirname "$(dirname "$tool")")
# The primitive library the design's own instances are checked against: port
# names, directions and widths, nothing else.  yosys's source tree carries it
# (checked in, so the yosys submodule needs no build for this).
# A built yosys installs the same two files under share/, which is all a CI job
# that downloads the tools without the yosys sources has.
prims=()
for dir in "$root/yosys/techlibs/xilinx" "$root/yosys-install/share/yosys/xilinx" "$root/yosys/share/xilinx"; do
    if [ -f "$dir/cells_sim.v" ] && [ -f "$dir/cells_xtra.v" ]; then
        prims=("$dir/cells_sim.v" "$dir/cells_xtra.v"); break
    fi
done
[ ${#prims[@]} -gt 0 ] || { say "no Xilinx primitive library (cells_sim.v): run 'git submodule update --init yosys'"; exit 2; }

# Every primitive the design instantiates becomes a black box -- kept as the
# cell itself in the netlist -- unless the design defines a module of that
# name.  Worked out from the sources rather than listed per target, so a
# design that starts using an IDELAYE2 does not quietly get one synthesised
# from its simulation model.
blackboxes=$(python3 - "${prims[@]}" -- "${srcs[@]}" <<'EOF'
import re, sys
args = sys.argv[1:]; k = args.index("--")
libs, srcs = args[:k], args[k + 1:]
strip = re.compile(r"//[^\n]*|/\*.*?\*/", re.S)
decl = re.compile(r"^\s*(?:module|macromodule)\s+(\w+)", re.M)
prims = set()
for f in libs:
    prims |= set(decl.findall(open(f, errors="replace").read()))
defined, text = set(), []
for f in srcs:
    try:
        t = strip.sub("", open(f, errors="replace").read())
    except OSError:
        continue
    defined |= set(decl.findall(t)); text.append(t)
inst = re.compile(r"^\s*(\w+)\s*(?:#\s*\(|\w+\s*\(|\\\S+\s*\()", re.M)
used = {m for t in text for m in inst.findall(t)}
print(" ".join(sorted((used & prims) - defined)))
EOF
) || exit 2

args=(-Wno-fatal --quiet -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-MULTIDRIVEN
      -Wno-BLKANDNBLK -Wno-PINMISSING -Wno-UNOPTFLAT -Wno-TIMESCALEMOD
      -Wno-SPECIFYIGN
      # yosys defines this for every file it reads; designs rely on it to keep
      # simulation-only code out of the netlist.
      +define+SYNTHESIS
      --top-module "$top" --map-only-output "$out" --Mdir "${out%.json}.vobj")
[ -z "$edif" ] || args+=(--map-only-edif "$edif")
[ -z "${VERILATOR_ABC_SCRIPT:-}" ] || args+=(--map-only-abc-script "$VERILATOR_ABC_SCRIPT")
for i in ${incs[@]+"${incs[@]}"}; do args+=("-I$i"); done
for d in ${defs[@]+"${defs[@]}"}; do args+=("+define+$d"); done
for b in $blackboxes; do args+=(--struct-only-blackbox "$b"); done
[ -z "$blackboxes" ] || say "synth.sh: primitives kept as cells: $blackboxes"

MEM_INIT_DIR=$PWD VERILATOR_ROOT=$vroot exec "$tool" "${args[@]}" "${prims[@]}" "${srcs[@]}"
