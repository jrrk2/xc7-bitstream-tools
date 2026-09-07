#!/usr/bin/env bash
# Does building Eigen 3.4.0 from source, to match the Linux host, make macOS
# produce the same place-and-route?
#
# The experiment holds everything else fixed.  It runs the SAME netlist through
# nextpnr twice -- once with whatever Eigen is installed now, once against a
# from-source Eigen 3.4.0 -- and compares both against the Linux result.
#
# You must copy these two files from the Linux host first; regenerating them
# here will NOT do, because the LiteX BIOS bakes __DATE__/__TIME__ into the ROM
# and every regeneration produces a different netlist.  That is what made the
# earlier "nextpnr is nondeterministic" reading wrong.
#
#   xilinx_vc707.json   sha256 5288f3c4f0873d97e5a06d9d88340383f004395f25a7138e0dfa61e1efd5082c
#   xilinx_vc707.xdc
#
# Linux reference FASM (Eigen 3.4.0, nextpnr e8c0b845 + the .IN fix):
#   a204ba4f975421429a7d4a1c8b7f6b0654fc540bd4d68fd9eaf9b7054d1bf69a
#
# Usage:  ./eigen_check.sh <path-to-xilinx_vc707.json> <path-to-xilinx_vc707.xdc>
set -euo pipefail

JSON=${1:?need the reference json}
XDC=${2:?need the reference xdc}
# Find the checkout: walk up from here until we see nextpnr/ and .deps/.
# The kit is normally unpacked *inside* the checkout, so $0's directory is
# one level too deep.  XC7_ROOT overrides if the layout is unusual.
ROOT=${XC7_ROOT:-}
if [ -z "$ROOT" ]; then
    d=$(cd "$(dirname "$0")" && pwd)
    while [ "$d" != "/" ]; do
        [ -d "$d/nextpnr" ] && [ -d "$d/.deps/prjxray-db" ] && { ROOT=$d; break; }
        d=$(dirname "$d")
    done
fi
[ -n "$ROOT" ] || { echo "no checkout found above $(dirname "$0"): set XC7_ROOT"; exit 2; }
echo "  checkout: $ROOT"
REF_FASM_SHA="a204ba4f975421429a7d4a1c8b7f6b0654fc540bd4d68fd9eaf9b7054d1bf69a"
REF_JSON_SHA="5288f3c4f0873d97e5a06d9d88340383f004395f25a7138e0dfa61e1efd5082c"

say() { printf '\n== %s\n' "$*"; }

say "inputs"
printf '  json sha256: %s\n' "$(shasum -a 256 <"$JSON" | cut -d' ' -f1)"
printf '  expected   : %s\n' "$REF_JSON_SHA"
[ "$(shasum -a 256 <"$JSON" | cut -d' ' -f1)" = "$REF_JSON_SHA" ] \
  || { echo "  netlist differs from the Linux one -- the comparison is meaningless; copy it across"; exit 2; }

eigen_version() {
  # Portable to BSD awk/sed: pull the three numbers, join with dots.  Falls
  # back to printing the raw lines, because Eigen 5 may lay them out
  # differently and a wrong parse is worse than no parse.
  local h=$1 w m n
  [ -f "$h" ] || { echo "not found"; return; }
  w=$(sed -n 's/^#define[[:space:]]*EIGEN_WORLD_VERSION[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$h" | head -1)
  m=$(sed -n 's/^#define[[:space:]]*EIGEN_MAJOR_VERSION[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$h" | head -1)
  n=$(sed -n 's/^#define[[:space:]]*EIGEN_MINOR_VERSION[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$h" | head -1)
  if [ -n "$w" ] && [ -n "$m" ]; then
      echo "$w.$m.${n:-0}"
  else
      echo "unparsed -- raw lines follow:"
      grep -E '#define[[:space:]]+EIGEN_(WORLD|MAJOR|MINOR)_VERSION' "$h" | sed 's/^/      /'
  fi
}

say "Eigen currently visible"
BREW=$(brew --prefix 2>/dev/null || echo /usr/local)
for h in "$BREW/include/eigen3/Eigen/src/Core/util/Macros.h" \
         /usr/local/include/eigen3/Eigen/src/Core/util/Macros.h; do
  [ -f "$h" ] && printf '  %-60s %s\n' "$h" "$(eigen_version "$h")"
done

run_pnr() {   # $1 = label, $2 = extra cmake args
  local label=$1; shift
  rm -rf "$ROOT/build-$label"
  cmake -S "$ROOT/nextpnr" -B "$ROOT/build-$label" \
        -DARCH=himbaechel -DHIMBAECHEL_UARCH=xilinx \
        -DBUILD_GUI=OFF -DBUILD_PYTHON=OFF \
        -DHIMBAECHEL_XILINX_DEVICES="xc7vx485t" \
        -DHIMBAECHEL_PRJXRAY_DB="$ROOT/.deps/prjxray-db" "$@" >/dev/null
  cmake --build "$ROOT/build-$label" --target nextpnr-himbaechel --parallel 8 >/dev/null
  "$ROOT/build-$label/nextpnr-himbaechel" --device xc7vx485tffg1761-2 \
        --json "$JSON" -o xdc="$XDC" -o fasm="$ROOT/$label.fasm" \
        --router router2 --placer-heap-timingweight 60 --timing-allow-fail \
        >"$ROOT/$label.log" 2>&1
  shasum -a 256 <"$ROOT/$label.fasm" | cut -d' ' -f1
}

say "1/2  nextpnr against the Eigen already installed"
BEFORE=$(run_pnr before)
printf '  fasm sha256: %s\n' "$BEFORE"

say "building Eigen 3.4.0 from source"
mkdir -p "$ROOT/eigen-src" && cd "$ROOT/eigen-src"
[ -d eigen-3.4.0 ] || {
  curl -fsSL -o eigen-3.4.0.tar.gz \
    https://gitlab.com/libeigen/eigen/-/archive/3.4.0/eigen-3.4.0.tar.gz
  tar xf eigen-3.4.0.tar.gz
}
cmake -S eigen-3.4.0 -B build -DCMAKE_INSTALL_PREFIX="$ROOT/eigen-3.4.0-install" >/dev/null
cmake --build build --target install >/dev/null
printf '  installed: %s\n' \
  "$(eigen_version "$ROOT/eigen-3.4.0-install/include/eigen3/Eigen/src/Core/util/Macros.h")"
cd "$ROOT"

say "2/2  nextpnr against Eigen 3.4.0"
AFTER=$(run_pnr after -DEigen3_DIR="$ROOT/eigen-3.4.0-install/share/eigen3/cmake")
printf '  fasm sha256: %s\n' "$AFTER"

say "result"
printf '  linux (Eigen 3.4.0) : %s\n' "$REF_FASM_SHA"
printf '  macos before        : %s  %s\n' "$BEFORE" \
  "$([ "$BEFORE" = "$REF_FASM_SHA" ] && echo MATCH || echo differs)"
printf '  macos after         : %s  %s\n' "$AFTER" \
  "$([ "$AFTER"  = "$REF_FASM_SHA" ] && echo MATCH || echo differs)"
echo
if   [ "$AFTER" = "$REF_FASM_SHA" ] && [ "$BEFORE" != "$REF_FASM_SHA" ]; then
  echo "  Eigen was the cause.  Pin 3.4.0 and the hosts agree."
elif [ "$BEFORE" = "$REF_FASM_SHA" ]; then
  echo "  Already matching -- Eigen was not the variable here."
elif [ "$AFTER" = "$BEFORE" ]; then
  echo "  Eigen changed nothing.  Something else differs: compare"
  echo "  nextpnr git rev, chipdb .bin sha256, and compiler/stdlib."
else
  echo "  Eigen moved the result but not onto the Linux one -- a second"
  echo "  input differs as well.  Compare the chipdb .bin next."
fi
