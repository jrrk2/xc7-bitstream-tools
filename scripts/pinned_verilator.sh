#!/usr/bin/env bash
# Resolve the Verilator synthesis backend to use, and refuse one that is not
# the pinned build -- the same contract as pinned_yosys.sh, for the same
# reason: which synthesiser produced a netlist decides what every later check
# is a statement about.
#
# The pin is the `verilator` submodule (jrrk2/verilator, branch synthesis),
# read from the index, so moving the submodule moves this check with it.
# Verilator's version string carries no commit, so the check is on the
# checkout the binary was built in: its HEAD must be the pinned commit, and
# the binary must be newer than that commit.
#
# Prints the verilator to use on stdout; non-zero with the reason otherwise.
#
#   VERILATOR            use this one instead (still checked, if it is a
#                        checkout of the submodule's repository)
#   VERILATOR_UNPINNED=1 accept whatever it is, and say so
set -u

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
say() { printf '%s\n' "$*" >&2; }

pinned=$(git -C "$root" ls-tree HEAD verilator 2>/dev/null | awk '$2 == "commit" { print $3 }')
candidate=${VERILATOR:-$root/verilator/bin/verilator}
vroot=$(cd "$(dirname "$candidate")/.." 2>/dev/null && pwd)

if [ ! -x "$candidate" ] || [ ! -x "$vroot/bin/verilator_bin" ]; then
    say "the Verilator synthesis backend has not been built.  Run:"
    say "    git submodule update --init --recursive verilator"
    say "    make verilator"
    say "or set SYNTH=yosys to synthesise with the pinned yosys instead."
    exit 2
fi

unpinned() {
    say "$1"
    if [ "${VERILATOR_UNPINNED:-0}" = 1 ]; then
        say "VERILATOR_UNPINNED=1: continuing anyway."
    else
        say "Run 'make verilator', or set VERILATOR_UNPINNED=1 to use it deliberately."
        exit 2
    fi
}

head=$(git -C "$vroot" rev-parse HEAD 2>/dev/null)
if [ -z "$pinned" ]; then
    say "note: no pinned verilator recorded here, using $vroot${head:+ at ${head:0:9}}"
elif [ -z "$head" ]; then
    unpinned "cannot tell which commit $vroot was built from"
elif [ "$head" != "$pinned" ]; then
    unpinned "verilator is not the pinned build.
    pinned:  ${pinned:0:9}   (the submodule)
    checked out: ${head:0:9}   in $vroot"
else
    built=$(stat -c %Y "$vroot/bin/verilator_bin")
    committed=$(git -C "$vroot" log -1 --format=%ct HEAD)
    [ "$built" -ge "$committed" ] || unpinned "$vroot/bin/verilator_bin is older than the pinned commit: run 'make verilator'"
fi

printf '%s\n' "$candidate"
