#!/usr/bin/env bash
# Build every eligible nextpnr xilinx example from source and prove the
# bitstream's extracted netlist equal to the synthesis it came from.
#
# "Eligible" means the tile model covers every primitive the design uses.
# Designs that need something it does not are listed too, with the reason,
# rather than quietly left out: a sweep that hides what it cannot do is a
# sweep that looks finished before it is.
#
# Environment: YOSYS, NEXTPNR_BIN, PRJXRAY_DB, EXAMPLES, OUT (all have
# defaults from the Makefile that calls this).
set -u -o pipefail

: ${YOSYS:=yosys}
: ${NEXTPNR_BIN:=build/nextpnr-himbaechel}
: ${PRJXRAY_DB:=.deps/prjxray-db}
: ${EXAMPLES:=nextpnr/himbaechel/uarch/xilinx/examples}
: ${OUT:=.verify/examples}
: ${TILEVERILOG:=fasm2netlist/build/tileverilog}
: ${LVS_EQUIV:=fasm2netlist/build/lvs_equiv}

# name | sources | top | xdc | part | device | family
DESIGNS=(
  "vc707-johnson|$EXAMPLES/vc707-johnson/top.v $EXAMPLES/vc707-johnson/counter25_core.v|top|$EXAMPLES/vc707-johnson/top.xdc|xc7vx485tffg1761-2|xc7vx485t|virtex7"
  "vc707-multibufg|$EXAMPLES/vc707-multibufg/top.v|top|$EXAMPLES/vc707-multibufg/top.xdc|xc7vx485tffg1761-2|xc7vx485t|virtex7"
  "arty-a35|$EXAMPLES/arty-a35/blinky.v|top|$EXAMPLES/arty-a35/arty.xdc|xc7a35tcsg324-1|xc7a50t|artix7"
  "johnson-sonata|$EXAMPLES/sonata/johnson_sonata.v|johnson_sonata|$EXAMPLES/sonata/johnson_sonata.xdc|xc7a50tcsg324-1|xc7a50t|artix7"
  "blinky-sonata|$EXAMPLES/sonata/blinky_sonata.v|blinky_sonata|$EXAMPLES/sonata/blinky_sonata.xdc|xc7a50tcsg324-1|xc7a50t|artix7"
  "arty-blinky|examples/arty-blinky/blinky.v|blinky|examples/arty-blinky/blinky.xdc|xc7a35tcsg324-1|xc7a50t|artix7"
  "vc707-hp-diffio|$EXAMPLES/vc707-hp-diffio/top.v|top|$EXAMPLES/vc707-hp-diffio/top.xdc|xc7vx485tffg1761-2|xc7vx485t|virtex7"
  "vc707-idelay|$EXAMPLES/vc707-idelay/top.v|top|$EXAMPLES/vc707-idelay/top.xdc|xc7vx485tffg1761-2|xc7vx485t|virtex7"
)

# name | what the tile model would have to learn first.  Empty is the goal, not
# the end of the story: a design here is one nobody has tried, not one that
# cannot be tried.
NOT_YET=()

# Designs that SHOULD build but do not, each pinned to the one known failure
# stopping it.  Unlike NOT_YET these are actually run, every time, because a
# skipped test measures nothing: the point is to tell the difference between
# "still blocked on the thing we know about", "blocked on something ELSE now"
# and "not blocked any more".  A design here is a bug report you can execute.
#
# name | sources | top | xdc | part | device | family | error marker | blocker
BLOCKED=(
  "vc707-gtrefclk|examples/vc707-gtrefclk/top.v|top|examples/vc707-gtrefclk/top.xdc|xc7vx485tffg1761-2|xc7vx485t|virtex7|failed to find IBUFDS_GTE2 site for pad|nextpnr cannot bind a gigabit-transceiver reference clock to its pad, so no GT design (LiteEth SGMII included) can be placed"
)

# --list prints the design names as JSON, so a CI matrix can be generated from
# this table rather than repeating it in a workflow file where the two would
# drift apart.  Naming designs on the command line runs only those, which is
# what each matrix job does.
if [ "${1:-}" = "--list" ]; then
    printf '['
    sep=""
    for row in "${DESIGNS[@]}"; do
        printf '%s"%s"' "$sep" "${row%%|*}"; sep=", "
    done
    for row in ${NOT_YET[@]+"${NOT_YET[@]}"}; do
        printf '%s"%s"' "$sep" "${row%%|*}"; sep=", "
    done
    for row in ${BLOCKED[@]+"${BLOCKED[@]}"}; do
        printf '%s"%s"' "$sep" "${row%%|*}"; sep=", "
    done
    printf ']\n'
    exit 0
fi

WANTED=("$@")
wanted() {
    [ ${#WANTED[@]} -eq 0 ] && return 0
    for w in "${WANTED[@]}"; do [ "$w" = "$1" ] && return 0; done
    return 1
}

# GitHub reads these; a plain terminal ignores them.
# A failure should say why where the reader already is.  Pointing at a log
# that only exists inside an uploaded artifact means opening the artifact to
# learn what a single line would have told you.
tail_log() {
    echo "--- last 20 lines of $1"
    tail -20 "$1" | sed 's/^/    /'
    echo "---"
}

annotate() {   # level, title, message
    [ -n "${GITHUB_ACTIONS:-}" ] || return 0
    printf '::%s title=%s::%s\n' "$1" "$2" "$3"
}
summary() {
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
    printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
}

mkdir -p "$OUT"
summary "| design | result | proved | differ |"
summary "|---|---|---|---|"
fail=0 pass=0
printf '%-18s %10s %8s %8s   %s\n' DESIGN RESULT PROVED DIFFER NOTE
printf '%.0s-' {1..70}; echo

for row in "${DESIGNS[@]}"; do
    IFS='|' read -r name srcs top xdc part device family <<< "$row"
    wanted "$name" || continue
    d="$OUT/$name"; mkdir -p "$d"
    log="$d/build.log"

    if ! "$YOSYS" -q -p "synth_xilinx -flatten -abc9 -nobram -arch xc7 -top $top; write_json $d/gold.json" \
            $srcs >"$log" 2>&1; then
        printf '%-18s %10s %8s %8s   %s\n' "$name" FAIL - - "synthesis failed, see $log"
        annotate error "$name" "synthesis failed"; tail_log "$log"; summary "| $name | FAIL | - | - |"; fail=$((fail+1)); continue
    fi
    if ! "$NEXTPNR_BIN" --device "$part" -o xdc="$xdc" --json "$d/gold.json" \
            -o fasm="$d/design.fasm" -o placement="$d/placement.json" --router router2 >>"$log" 2>&1; then
        printf '%-18s %10s %8s %8s   %s\n' "$name" FAIL - - "place and route failed, see $log"
        annotate error "$name" "place and route failed"; tail_log "$log"; summary "| $name | FAIL | - | - |"; fail=$((fail+1)); continue
    fi
    if ! "$TILEVERILOG" --fasm "$d/design.fasm" --db "$PRJXRAY_DB/$family" --device "$device" \
            --xdc "$xdc" --part "$part" --out "$d/fabric.v" --model-out "$d/tile_model.v" >>"$log" 2>&1; then
        printf '%-18s %10s %8s %8s   %s\n' "$name" FAIL - - "extraction failed, see $log"
        annotate error "$name" "extraction from the bitstream failed"; tail_log "$log"; summary "| $name | FAIL | - | - |"; fail=$((fail+1)); continue
    fi
    # the design's own names, for reading when a result needs explaining
    "$TILEVERILOG" --fasm "$d/design.fasm" --db "$PRJXRAY_DB/$family" --device "$device" \
        --xdc "$xdc" --part "$part" --placement "$d/placement.json" --gold-json "$d/gold.json" \
        --out "$d/fabric_named.v" >>"$log" 2>&1
    "$YOSYS" -q -p "read_json $d/gold.json; hierarchy -top $top; splitnets; select $top; \
        write_verilog -noattr -selected $d/gold.v" >>"$log" 2>&1

    res=$("$LVS_EQUIV" --gold "$d/gold.v" --gold-top "$top" --gate "$d/fabric.v" --gate-top fabric \
          --placement "$d/placement.json" --gold-json "$d/gold.json" \
          --db "$PRJXRAY_DB/$family" --device "$device" --quiet 2>&1 | tee -a "$log" | grep -E '^[0-9]+ proved')
    proved=$(echo "$res" | awk '{print $1}')
    differ=$(echo "$res" | awk '{print $3}')
    if [ "${differ:-1}" = 0 ] && [ "${proved:-0}" -gt 0 ]; then
        printf '%-18s %10s %8s %8s\n' "$name" PROVED "$proved" "$differ"
        annotate notice "$name" "$proved proved, 0 differ"
        summary "| $name | PROVED | $proved | 0 |"; pass=$((pass+1))
    else
        printf '%-18s %10s %8s %8s   %s\n' "$name" DIFFER "${proved:--}" "${differ:--}" "see $log"
        annotate error "$name" "the extracted netlist is not equivalent to the synthesis: ${differ:-?} differ"
        summary "| $name | **DIFFER** | ${proved:--} | ${differ:--} |"; fail=$((fail+1))
    fi
done

# ---- designs blocked on a known, named bug -------------------------------
# Three outcomes, deliberately distinguishable at a glance:
#   blocked    the named error is still what stops it   (expected, not a failure)
#   UNBLOCKED  it got past that error                   (fixed -- promote it)
#   FAIL       it broke somewhere else                  (a real regression)
unblocked=0
for row in ${BLOCKED[@]+"${BLOCKED[@]}"}; do
    IFS='|' read -r name srcs top xdc part device family marker why <<< "$row"
    wanted "$name" || continue
    d="$OUT/$name"; mkdir -p "$d"
    log="$d/build.log"; : > "$log"

    if ! "$YOSYS" -q -p "synth_xilinx -flatten -abc9 -arch xc7 -top $top; write_json $d/gold.json" \
            $srcs >>"$log" 2>&1; then
        printf '%-18s %10s %8s %8s   %s\n' "$name" FAIL - - "synthesis failed, see $log"
        annotate error "$name" "synthesis failed"; tail_log "$log"
        summary "| $name | FAIL | - | - |"; fail=$((fail+1)); continue
    fi

    if "$NEXTPNR_BIN" --device "$part" -o xdc="$xdc" --json "$d/gold.json" \
            -o fasm="$d/design.fasm" -o placement="$d/placement.json" --router router2 >>"$log" 2>&1; then
        printf '%-18s %10s %8s %8s   %s\n' "$name" UNBLOCKED - - "the known error is gone -- promote this design"
        annotate notice "$name" "no longer blocked: $why"
        summary "| $name | **UNBLOCKED** | - | - |"; unblocked=$((unblocked+1))
    elif grep -qF "$marker" "$log"; then
        printf '%-18s %10s %8s %8s   %s\n' "$name" blocked - - "$why"
        annotate warning "$name" "still blocked: $why"
        summary "| $name | blocked | - | - |"
    else
        printf '%-18s %10s %8s %8s   %s\n' "$name" FAIL - - "blocked on something NEW, not the known error; see $log"
        annotate error "$name" "failed on something other than the known blocker"
        tail_log "$log"; summary "| $name | FAIL | - | - |"; fail=$((fail+1))
    fi
done

for row in ${NOT_YET[@]+"${NOT_YET[@]}"}; do
    IFS='|' read -r name why <<< "$row"
    wanted "$name" || continue
    printf '%-18s %10s %8s %8s   %s\n' "$name" skipped - - "$why"
    annotate warning "$name" "$why"
    summary "| $name | skipped | - | - |"
done

echo
echo "$pass proved, $fail failed, ${#NOT_YET[@]} not yet eligible, ${#BLOCKED[@]} blocked on a known bug ($unblocked now unblocked)"
if [ "${unblocked:-0}" -gt 0 ]; then
    echo
    echo "$unblocked design(s) are no longer blocked: move them from BLOCKED to DESIGNS"
    echo "in scripts/verify_examples.sh so the sweep starts proving them."
fi
exit $(( fail > 0 ))
