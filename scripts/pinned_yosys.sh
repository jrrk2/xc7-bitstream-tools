#!/usr/bin/env bash
# Resolve the yosys to use, and refuse one that is not the pinned build.
#
# Which yosys synthesised a design decides what the equivalence check is
# asking: the LiteX SoC proves completely under the pinned version and shows
# 36 differences under 0.64, because the two produce different netlists.  So a
# result from an unpinned yosys is not a weaker result, it is a result about a
# different question -- and the failure mode is silent, because everything
# still runs and still prints numbers.
#
# The pin is not written down here.  It is read from the submodule the
# repository already records, so moving the pin moves this check with it and
# there is no second place to forget.
#
# Prints the yosys to use on stdout.  Exits non-zero, with the reason on
# stderr, if that would be the wrong one.
#
#   YOSYS            use this one instead of the pinned build (still checked)
#   YOSYS_UNPINNED=1 accept whatever it is, and say so -- for deliberately
#                    measuring one version against another, which is how the
#                    pin was chosen in the first place
set -u

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
say() { printf '%s\n' "$*" >&2; }

# The commit this repository pins, read from the index rather than from the
# checked-out submodule: it is the right answer even when the submodule has
# not been checked out, which is exactly when the message below is needed.
pinned=$(git -C "$root" ls-tree HEAD yosys 2>/dev/null | awk '$2 == "commit" { print $3 }')

candidate=${YOSYS:-}
if [ -z "$candidate" ]; then
    # The in-tree build `make yosys` produces, then the install prefix CI uses
    # when it has to hand the binary to another job.  Both are the pinned
    # submodule; neither is whatever apt put on PATH.
    if [ -x "$root/yosys/yosys" ]; then
        candidate="$root/yosys/yosys"
    elif [ -x "$root/yosys-install/bin/yosys" ]; then
        candidate="$root/yosys-install/bin/yosys"
    else
        say "yosys has not been built.  Run:"
        say "    git submodule update --init --recursive yosys"
        say "    make yosys"
        say "Set YOSYS_UNPINNED=1 to use whatever is on PATH instead, accepting"
        say "that its results are not comparable with this repository's."
        if [ "${YOSYS_UNPINNED:-0}" = 1 ]; then
            command -v yosys >/dev/null || { say "...and there is none on PATH."; exit 2; }
            say "YOSYS_UNPINNED=1: using $(command -v yosys)"
            command -v yosys
            exit 0
        fi
        exit 2
    fi
fi

# Absolute, because one design is synthesised from inside its own directory
# and a relative tool path does not survive that cd.
case "$candidate" in
    */*) [ -x "$candidate" ] && candidate="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")" ;;
esac

if ! version=$("$candidate" -V 2>/dev/null | head -1); then
    say "cannot run $candidate"
    exit 2
fi
sha=$(printf '%s' "$version" | sed -n 's/.*git sha1 \([0-9a-f]\{7,\}\).*/\1/p')

if [ -z "$pinned" ]; then
    # Not a git checkout, so there is nothing to check against.  Say so rather
    # than pretending the check passed.
    say "note: no pinned yosys recorded here, using $version"
elif [ -z "$sha" ]; then
    say "cannot tell which commit $candidate was built from: $version"
    [ "${YOSYS_UNPINNED:-0}" = 1 ] || exit 2
elif case "$pinned" in "$sha"*) false ;; *) true ;; esac; then
    say "yosys is not the pinned build."
    say "    pinned:  ${pinned:0:9}   (the submodule, and what the results are quoted for)"
    say "    offered: $sha   $version"
    say "Two versions do not synthesise the same netlist, so their results are"
    say "not comparable.  Run 'make yosys', or set YOSYS_UNPINNED=1 if you mean"
    say "to compare versions deliberately."
    if [ "${YOSYS_UNPINNED:-0}" = 1 ]; then
        say "YOSYS_UNPINNED=1: continuing anyway."
    else
        exit 2
    fi
fi

printf '%s\n' "$candidate"
