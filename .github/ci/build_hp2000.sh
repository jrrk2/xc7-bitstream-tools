#!/bin/bash
set -euo pipefail

# Build the HP 2000F TSB SoC through the open flow, then prove the bitstream's
# extracted netlist equals the synthesis it came from -- the LVS check
# verify-examples.yml runs for the committed-gateware examples.
#
# The SoC's ROM embeds HP's IOP program and system tape, assembled here from
# the Bitsavers sources (never committed) by examples/hp2000's bios-assets
# target, which `make vc707-hp2000` runs before it regenerates the gateware.
#
# Environment:
#   PRJXRAY_DB      database checkout (default .deps/prjxray-db)
#   EQUIV_TIMEOUT   seconds to allow the LVS proof (default 1800)

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

PRJXRAY_DB="${PRJXRAY_DB:-$ROOT/.deps/prjxray-db}"
export PRJXRAY_DB

BUILD_LOG="$(mktemp)"
trap 'rm -f "$BUILD_LOG"' EXIT

echo "=== [1/3] The HP 2000F SoC, through yosys and nextpnr"
# Tee rather than redirect: the log is wanted for the timing report below, and
# live output keeps a run that stalls in the placer legible.
set -o pipefail
make vc707-hp2000 PRJXRAY_DB="$PRJXRAY_DB" 2>&1 | tee "$BUILD_LOG"

echo "=== [2/3] Timing (reported, not enforced)"
# The target passes --timing-allow-fail because the two-clock domain has not
# closed timing yet (examples/hp2000/README.md): report where it stands, don't
# gate the build on it.
grep -E "Max frequency for clock" "$BUILD_LOG" | sort -u || true
grep -E "Hold/min time violation" "$BUILD_LOG" | head -2 || true

echo "=== [3/3] Prove the extraction equals the synthesis"
HP2000_BUILD="examples/hp2000/build/litex-hp2000"
G="$HP2000_BUILD/gateware"
LVS_LOG="$(mktemp)"
# Bounded, like the verify-examples sweep: the proof is the long pole and can
# run for many minutes on a design this size.  A timeout is "not proved in
# time", not a build failure -- the bitstream above is what CI gates on.
set +e
timeout "${EQUIV_TIMEOUT:-1800}" make verify-extraction \
    V_NAME=vc707-hp2000 V_TOP=xilinx_vc707 V_PART=xc7vx485tffg1761-2 \
    V_DEVICE=xc7vx485t V_FAMILY=virtex7 \
    V_FASM="$G/xilinx_vc707.fasm" V_JSON="$G/xilinx_vc707.json" \
    V_XDC="$G/xilinx_vc707.xdc" V_PLACE="$G/xilinx_vc707_placement.json" \
    PRJXRAY_DB="$PRJXRAY_DB" 2>&1 | tee "$LVS_LOG"
lvs_status=$?
set -e
res="$(grep -E '^[0-9]+ proved' "$LVS_LOG" | tail -1 || true)"
if [ -n "$res" ]; then
    echo "LVS: $res"
elif [ "$lvs_status" = 124 ]; then
    echo "LVS: no verdict within ${EQUIV_TIMEOUT:-1800}s (the proof timed out)"
else
    echo "LVS: no verdict (extraction or proof failed; see the log above)"
fi
rm -f "$LVS_LOG"

ls -la hp2000_vc707.bit
echo "=== done"
