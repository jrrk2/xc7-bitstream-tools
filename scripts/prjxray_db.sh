#!/usr/bin/env bash
# Check the Project X-Ray database is present and is the pinned revision,
# and with --fetch, put it there.
#
# Every other input to a build here is pinned by git submodule: yosys,
# nextpnr, prjxray, and all nine LiteX packages.  The segbits database is
# not -- it is a separate clone -- and it is the one that decides which
# actual bits a line of FASM sets.  So two machines can check out the same
# commit of this repository, synthesise the same netlist, place it
# identically and close timing identically, and still write different
# bitstreams.
#
# That failure is silent in the worst way: the build succeeds, the numbers
# all look right, the bitstream loads, and the design comes up with its I/O
# subtly misconfigured -- a link that never negotiates, an input that reads
# back constant.  Nothing in the log says which revision produced it.  Hence
# a revision check rather than a mere existence check.
#
#   $1  path to the database        (default $PRJXRAY_DB)
#   $2  revision it should be at    (default $PRJXRAY_DB_REV)
#
#   --fetch                 clone it, pinned, if it is not already there
#   PRJXRAY_DB_UNPINNED=1   accept a different revision, and say so
set -u

URL=https://github.com/openXC7/prjxray-db
say() { printf '%s\n' "$*" >&2; }

fetch=0
[ "${1:-}" = --fetch ] && { fetch=1; shift; }

db=${1:-${PRJXRAY_DB:-}}
rev=${2:-${PRJXRAY_DB_REV:-}}

# The pin lives in one place, the Makefile, so a caller that does not pass it
# still gets it right rather than silently checking nothing.
if [ -z "$rev" ]; then
    root=$(cd "$(dirname "$0")/.." && pwd)
    rev=$(sed -n 's/^PRJXRAY_DB_REV[[:space:]]*?*=[[:space:]]*\([0-9a-f]\{40\}\).*/\1/p' \
          "$root/Makefile" 2>/dev/null | head -1)
fi

[ -n "$db" ] || { say "no database path given"; exit 2; }

if [ "$fetch" = 1 ] && [ ! -d "$db" ]; then
    say "fetching the Project X-Ray database into $db, pinned at ${rev:0:12}"
    mkdir -p "$db" || exit 2
    # Ask for the one commit rather than the history; GitHub serves a fetch
    # by SHA.  Fall back to a full clone where that is refused, since a
    # shallow clone cannot then check out an older pin.
    if git -C "$db" init -q 2>/dev/null &&
       git -C "$db" remote add origin "$URL" 2>/dev/null &&
       git -C "$db" fetch -q --depth 1 origin "$rev" 2>/dev/null; then
        git -C "$db" checkout -q --detach FETCH_HEAD || exit 2
    else
        say "  (fetch by revision refused; cloning in full)"
        rm -rf "$db"
        git clone -q "$URL" "$db" || exit 2
        git -C "$db" checkout -q --detach "$rev" || exit 2
    fi
fi

if [ ! -d "$db" ]; then
    say "no Project X-Ray database at $db"
    say "    make prjxray-db                     (clones it, pinned)"
    say "    (or build with PRJXRAY_DB=/path/to/prjxray-db)"
    exit 2
fi

[ -n "$rev" ] || exit 0

have=$(git -C "$db" rev-parse HEAD 2>/dev/null)
if [ -z "$have" ]; then
    # Not a git checkout, so the revision cannot be established.  Say so
    # rather than letting silence read as a pass.
    say "note: $db is not a git checkout; cannot confirm it is ${rev:0:12}"
    exit 0
fi

case "$have" in
    "$rev"*) exit 0 ;;
esac

# Tracking the tip on purpose (CI does) is not a fault, so say it in one
# line.  The revision still gets printed either way: a result quoted against
# an unknown database is the thing to avoid, not one quoted against a new.
if [ "${PRJXRAY_DB_UNPINNED:-0}" = 1 ]; then
    say "note: Project X-Ray database is ${have:0:12}, not the pin ${rev:0:12} (PRJXRAY_DB_UNPINNED=1)"
    exit 0
fi

say "the Project X-Ray database is not the pinned revision."
say "    pinned: ${rev:0:12}"
say "    found:  ${have:0:12}   in $db"
say "Different revisions assign different bits, so a bitstream built against"
say "one is not comparable with results quoted for the other -- and the"
say "difference shows up on hardware, not in the build log.  To pin it:"
say "    git -C $db fetch origin $rev && git -C $db checkout --detach $rev"
say "Set PRJXRAY_DB_UNPINNED=1 to build against this one deliberately."
exit 2
