#!/bin/bash
set -euo pipefail

# Build the Linux-capable VC707 SoC through the open flow, and the
# machine-mode software that boots Linux on it.
#
# What this does NOT do is stage a payload: the kernel and rootfs are not
# vendored (they are ~9 MB of external artifacts), so CI checks the half it
# can reproduce -- that the SoC still builds, still closes timing, still has
# every feature prjxray can express, and still provides what the emulator
# expects of it.
#
# That last point is the one worth having.  The emulator #includes the SoC's
# generated/csr.h, so it only compiles if the SoC still offers cpu_timer and a
# UART.  When the SoC was built without VexRiscvTimer, Linux booted to a
# silent hang; here it would have been a compile error.
#
# Environment:
#   PRJXRAY_DB   database checkout (default .deps/prjxray-db)
#   KEEP_BUILD   keep the build tree (default 0; the SoC tree is ~1 GB)

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

PRJXRAY_DB="${PRJXRAY_DB:-$ROOT/.deps/prjxray-db}"
export PRJXRAY_DB

BUILD_LOG="$(mktemp)"
trap 'rm -f "$BUILD_LOG"' EXIT

echo "=== [1/4] The Linux SoC, through yosys and nextpnr"
# Tee rather than redirect: the log is wanted for the timing check below, and
# the output is wanted live so a run that stalls in the placer is legible.
set -o pipefail
make vc707-litex-linux PRJXRAY_DB="$PRJXRAY_DB" 2>&1 | tee "$BUILD_LOG"

echo "=== [2/4] Timing"
# The target passes --timing-allow-fail because this flow has no trustworthy
# hold STA -- it reports violations on designs that demonstrably run, so a
# hold failure must not fail the build.  Setup is a different matter: a clock
# that misses its constraint is a real regression and is caught here.
grep -E "Max frequency for clock" "$BUILD_LOG" | sort -u || true
if grep -qE "Max frequency for clock.*FAIL" "$BUILD_LOG"; then
    echo "!!! a clock missed its setup constraint"
    exit 1
fi
grep -E "Hold/min time violation" "$BUILD_LOG" | head -2 || true

echo "=== [3/4] The machine-mode software, against this SoC's own headers"
make vc707-litex-linux-emulator

echo "=== [4/4] What the SoC has to offer it"
"$ROOT/.venv/bin/python" - <<'PY'
import json, sys
csr = json.load(open("examples/vc707-litex-ddr-ethmin/build-linux/csr.json"))
regs = csr["csr_registers"]
need = ["cpu_timer_latch", "cpu_timer_time"]
missing = [n for n in need if n not in regs]
if missing:
    print(f"!!! the SoC is missing {missing}: Linux would boot to a silent hang")
    sys.exit(1)
for n in need:
    print(f"  {n:20} 0x{regs[n]['addr']:08x}")
print(f"  {'uart':20} 0x{csr['csr_bases']['uart']:08x}")
PY

ls -la litex_linux_vc707.bit examples/vc707-litex-linux/emulator/emulator.bin

if [ "${KEEP_BUILD:-0}" != "1" ]; then
    rm -rf examples/vc707-litex-ddr-ethmin/build-linux
fi
echo "=== done"
