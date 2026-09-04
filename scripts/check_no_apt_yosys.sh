#!/usr/bin/env bash
# Fail if anything here would install or default to a yosys that is not the
# pinned one.
#
# The runtime guard (scripts/pinned_yosys.sh) already refuses to USE a wrong
# yosys, so this is not what makes the results trustworthy -- it is what stops
# a future edit reintroducing the problem and discovering it as a red build
# ten minutes into CI.  An apt yosys is whatever the runner image happens to
# carry; it was 0.33 against a pinned 0.63+173 when this was written.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bad=0

# Package lists: a bare "yosys" among apt-get install arguments, allowing for
# the line continuations these workflows are written with.
while IFS= read -r f; do
    if awk '/apt-get[ \t]+install/ { grab = 1 }
            grab { line = line " " $0; if ($0 !~ /\\[ \t]*$/) { grab = 0;
                     if (line ~ /(^|[ \t])yosys([ \t]|$)/) { print FILENAME; exit 1 }
                     line = "" } }' "$f" >/dev/null; then :; else
        echo "$f installs yosys from a package manager" >&2
        bad=1
    fi
done < <(find "$root/.github" "$root/scripts" -type f \( -name '*.yml' -o -name '*.sh' \) 2>/dev/null)

# Defaults that silently fall back to PATH instead of asking the guard.
if grep -rnE '^[^#]*(YOSYS[[:space:]]*[:?]?=[[:space:]]*yosys[[:space:]]*$|YOSYS:[[:space:]]*yosys[[:space:]]*$)' \
        "$root/.github" "$root/scripts" "$root/Makefile" 2>/dev/null \
        | grep -v pinned_yosys | grep -v check_no_apt_yosys; then
    echo "the above default to a bare 'yosys' instead of scripts/pinned_yosys.sh" >&2
    bad=1
fi

if [ "$bad" = 0 ]; then
    echo "toolchain pinning: no package-manager yosys, no bare-yosys defaults"
fi
exit "$bad"
