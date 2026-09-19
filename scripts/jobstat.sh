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
    # Bracket the first character so the pattern cannot match this process.
    BPAT="[${PAT:0:1}]${PAT:1}"
    if pgrep -f "$BPAT" >/dev/null 2>&1; then STATE=RUNNING; else STATE="not running"; fi
else
    STATE="(no pattern given)"
fi

[ -f "$LOG" ] || { echo "$STATE; no log at $LOG"; exit 0; }

ERRS=$(grep -cE "^ERROR|^make.*\*\*\*|Error [0-9]+$|OSError|Traceback|CRITICAL WARNING|FAILED|Segmentation fault" "$LOG" 2>/dev/null || true)
LAST=$(tail -1 "$LOG" | cut -c1-80)

echo "state    : $STATE"
echo "errors   : $ERRS"
if [ "${ERRS:-0}" -gt 0 ]; then
    echo "first few:"
    grep -E "^ERROR|^make.*\*\*\*|Error [0-9]+$|OSError|Traceback|CRITICAL WARNING|FAILED|Segmentation fault" "$LOG" \
        | head -3 | cut -c1-110 | sed 's/^/  /'
fi
echo "last line: $LAST"
