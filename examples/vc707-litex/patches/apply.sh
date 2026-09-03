#!/usr/bin/env bash
# Apply the patches this example needs to the LiteX submodules.
#
# They are kept as patches rather than as commits in the submodules so that
# the recorded submodule pointers stay on upstream, and so that each change is
# visible and reviewable instead of being an invisible dirty working tree.
# All three are small and upstreamable; none is a workaround.
set -eu
cd "$(dirname "$0")/../../.."   # repository root

apply() {   # submodule, patch
    if git -C "$1" apply --check -R "$2" 2>/dev/null; then
        echo "  already applied: $(basename "$2")"
    elif git -C "$1" apply "$2"; then
        echo "  applied:         $(basename "$2")"
    else
        echo "  FAILED:          $(basename "$2") -- has $1 moved on?" >&2
        exit 1
    fi
}

P="$PWD/examples/vc707-litex/patches"
apply litex-deps/litex   "$P/litex-bios-configurable-tagline.patch"
apply litex-deps/liteeth "$P/liteeth-k7-1000basex-125mhz-refclk.patch"
apply nextpnr            "$P/nextpnr-ibufds-gte2-toplevel-pin.patch"
echo "done; rebuild nextpnr if its patch was newly applied"
