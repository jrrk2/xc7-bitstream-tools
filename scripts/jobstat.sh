#!/usr/bin/env bash
# Is a background job running, finished, or dead?  Answer unambiguously.
#
#   scripts/jobstat.sh <log-file> [process-pattern]
#
# Three mistakes this exists to stop making, all of them made in one session:
#
#   * `pgrep -f foo` matches the shell running the pgrep, because the pattern
#     is in its own command line.  "Still running" then means "I am running".
#     The [f]oo bracket trick is the fix and it is easy to forget.
#
#   * Polling for the SUCCESS marker only.  A build that died produces no
#     marker, which is indistinguishable from one still working, so a crash
#     reads as progress.  Silence is not success.
#
#   * Treating "the output file does not exist yet" as "still building".
set -u
LOG=${1:?usage: jobstat.sh <log> [pattern]}
PAT=${2:-}

if [ -n "$PAT" ]; then
    # Bracketing the pattern is not enough: it is passed as an ARGUMENT, so
    # the bare word appears in this script's own command line and in the
    # shell that invoked it.  Exclude our own process tree by PID instead --
    # the only way that cannot be defeated by how the pattern is spelled.
    SELF=$$; PARENT=$PPID
    HITS=$(pgrep -f "$PAT" 2>/dev/null | grep -vxE "$SELF|$PARENT" || true)
    if [ -n "$HITS" ]; then
        STATE="RUNNING (pid $(echo $HITS | tr '\n' ' '))"
    else
        STATE="not running"
    fi
else
    STATE="(no pattern given)"
fi

[ -f "$LOG" ] || { echo "$STATE; no log at $LOG"; exit 0; }

# Not anchored to the line start: yosys writes "file.v:62: ERROR: ...",
# Vivado writes "ERROR: [Place 30-69] ...", make writes "make: *** ...".
# Anchoring missed the first kind entirely and reported errors: 0 on a run
# that had already failed -- the exact thing this script exists to prevent.
ERRPAT="ERROR|error:|make(\[[0-9]+\])?: \*\*\*|Error [0-9]+$|OSError|Traceback|CRITICAL WARNING|FAILED|Segmentation fault|Killed"
ERRS=$(grep -cE "$ERRPAT" "$LOG" 2>/dev/null || true)
LAST=$(tail -1 "$LOG" | cut -c1-80)

echo "state    : $STATE"
echo "errors   : $ERRS"
if [ "${ERRS:-0}" -gt 0 ]; then
    echo "first few:"
    grep -E "$ERRPAT" "$LOG" | head -3 | cut -c1-110 | sed 's/^/  /'
fi
echo "last line: $LAST"
