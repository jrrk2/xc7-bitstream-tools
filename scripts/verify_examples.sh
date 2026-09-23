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

: ${NEXTPNR_BIN:=build/nextpnr-himbaechel}
: ${PRJXRAY_DB:=.deps/prjxray-db}
: ${EXAMPLES:=nextpnr/himbaechel/uarch/xilinx/examples}
: ${OUT:=.verify/examples}
: ${TILEVERILOG:=fasm2netlist/build/tileverilog}
: ${LVS_EQUIV:=fasm2netlist/build/lvs_equiv}

# name | dir | sources | top | xdc | part | device | family | synth flags
#
# The same eight fields BLOCKED uses, so a design that stops being blocked
# moves between the two tables unchanged.
#
# dir    working directory for synthesis, "." for the repository root.  It
#        matters for designs whose Verilog $readmemh's its memory contents from
#        a relative path: run yosys anywhere else and the ROM reads as zero,
#        SILENTLY.
# srcs   a list, or @file naming one (relative to dir).
# synth  extra flags for synth_xilinx.  -nobram keeps a small example in LUTs
#        where that is what it is meant to exercise; a design that means to use
#        block RAM leaves it off.
DESIGNS=(
  "vc707-johnson|.|$EXAMPLES/vc707-johnson/top.v $EXAMPLES/vc707-johnson/counter25_core.v|top|$EXAMPLES/vc707-johnson/top.xdc|xc7vx485tffg1761-2|xc7vx485t|virtex7|-nobram"
  "vc707-telegraph|examples/vc707-telegraph|top.v telegraph_core.v|top|top.xdc|xc7vx485tffg1761-2|xc7vx485t|virtex7|-nobram"
  "vc707-multibufg|.|$EXAMPLES/vc707-multibufg/top.v|top|$EXAMPLES/vc707-multibufg/top.xdc|xc7vx485tffg1761-2|xc7vx485t|virtex7|-nobram"
  "arty-a35|.|$EXAMPLES/arty-a35/blinky.v|top|$EXAMPLES/arty-a35/arty.xdc|xc7a35tcsg324-1|xc7a50t|artix7|-nobram"
  "johnson-sonata|.|$EXAMPLES/sonata/johnson_sonata.v|johnson_sonata|$EXAMPLES/sonata/johnson_sonata.xdc|xc7a50tcsg324-1|xc7a50t|artix7|-nobram"
  "blinky-sonata|.|$EXAMPLES/sonata/blinky_sonata.v|blinky_sonata|$EXAMPLES/sonata/blinky_sonata.xdc|xc7a50tcsg324-1|xc7a50t|artix7|-nobram"
  "arty-blinky|.|examples/arty-blinky/blinky.v|blinky|examples/arty-blinky/blinky.xdc|xc7a35tcsg324-1|xc7a50t|artix7|-nobram"
  "vc707-hp-diffio|.|$EXAMPLES/vc707-hp-diffio/top.v|top|$EXAMPLES/vc707-hp-diffio/top.xdc|xc7vx485tffg1761-2|xc7vx485t|virtex7|-nobram"
  "vc707-idelay|.|$EXAMPLES/vc707-idelay/top.v|top|$EXAMPLES/vc707-idelay/top.xdc|xc7vx485tffg1761-2|xc7vx485t|virtex7|-nobram"
  # A gigabit-transceiver reference clock buffer.  This was blocked -- nextpnr
  # could not bind an IBUFDS_GTE2 to its pad -- until the site-name match in
  # nextpnr's packer was corrected; it now places, extracts and proves.
  "vc707-gtrefclk|.|examples/vc707-gtrefclk/top.v|top|examples/vc707-gtrefclk/top.xdc|xc7vx485tffg1761-2|xc7vx485t|virtex7|-nobram"
  # The LiteX SoC: a SERV CPU with its BIOS in block RAM, its register file in
  # distributed RAM and carry chains throughout.  It was blocked until the tile
  # model learned to cut a block RAM at its boundary; it proves now, with the
  # yosys this repository pins.
  # The SERV SoC WITH the SD card -- the design that works under Vivado and
  # fails through the open flow.  The no-SD control beside it proves 2820/0,
  # so the two together isolate the SD block exactly.
  "vc707-serv-sd|examples/vc707-litex/build-serv-sd/gateware|@sources.f|xilinx_vc707|xilinx_vc707.xdc|xc7vx485tffg1761-2|xc7vx485t|virtex7|"
  # A gated counter with a comparison: the shape of the SD test's PHY-init
  # delay and nothing else, written to isolate the one cluster that design
  # still differs on -- a carry chain whose CYINIT comes from the fabric.
  "vc707-gatedcount|.|examples/vc707-gatedcount/top.v|top|examples/vc707-gatedcount/top.xdc|xc7vx485tffg1761-2|xc7vx485t|virtex7|-nobram"
  # The minimal SD test: SDPHY and SDCore driven by a hardcoded FSM, no CPU
  # and no bus.  It exists to be small enough that a difference list can be
  # read line by line, and it is the first design here whose bitstream is
  # known to work against a real card through BOTH flows -- Vivado's and this
  # one -- so a difference it reports is a modelling gap, not a broken build.
  "vc707-sdtest|examples/vc707-sdtest/build-openflow|vc707_sdtest.v|vc707_sdtest|vc707_sdtest.xdc|xc7vx485tffg1761-2|xc7vx485t|virtex7|"
  "vc707-litex|examples/vc707-litex/gateware|@sources.f|xilinx_vc707|xilinx_vc707.xdc|xc7vx485tffg1761-2|xc7vx485t|virtex7|"
  # Formerly BLOCKED, now run through full LVS to see where they really stand.
  # vc707-ethmin: reached the router but reported 18 hold violations; hold-fix
  # (on by default above) clears them, so it now completes and can be LVSed.
  # vc707-smpsd and vc707-litex-eth still fail earlier -- smpsd misses eth_tx_clk
  # (setup, placement), litex-eth cannot route the transceiver clock -- so they
  # surface as P&R FAILs here rather than being quietly set aside.
  "vc707-ethmin|examples/vc707-ethmin|@sources.f|vc707_ethmin|vc707_ethmin.xdc|xc7vx485tffg1761-2|xc7vx485t|virtex7|"
  # The same SoC with a processor whose instruction set is OCaml 4.14
  # bytecode in place of the picorv32: block RAM with contents, carry chains,
  # DSPs, an MMCM, a GTX and HP I/O in both directions, at a size worth
  # timing a placer against.  Its $readmemh paths are relative, hence the
  # directory.
  "vc707-ocaml|examples/vc707-ocaml|@sources.f|vc707_ethmin_vm|vc707_ethmin_vm.xdc|xc7vx485tffg1761-2|xc7vx485t|virtex7|"
  "vc707-smpsd|examples/vc707-litex-ddr-ethmin/build-smpsd-openXC7/gateware|@sources.f|xilinx_vc707|xilinx_vc707.xdc|xc7vx485tffg1761-2|xc7vx485t|virtex7|"
  "vc707-litex-eth|examples/vc707-litex-eth/gateware|@sources.f|xilinx_vc707|xilinx_vc707.xdc|xc7vx485tffg1761-2|xc7vx485t|virtex7|"
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
# name | dir | sources | top | xdc | part | device | family | stage | marker | blocker
#
# dir      working directory for synthesis, "." for the repository root.  It
#          matters for designs whose Verilog $readmemh's its memory contents
#          from a relative path: run yosys anywhere else and the ROM reads as
#          zero, SILENTLY.
# sources  a list, or @file naming one (relative to dir).
# stage    where the blocker bites, and therefore what "no longer blocked"
#          would look like:
#            pnr    place-and-route fails, with `marker` in the log
#            equiv  it builds and extracts, but the equivalence check differs
# All formerly-blocked designs were promoted into DESIGNS above so LVS runs on
# them and their real state is measured, not assumed: vc707-ethmin (hold-fix
# clears its 18 hold violations) now completes and is LVSed; vc707-smpsd and
# vc707-litex-eth still fail earlier (setup on eth_tx_clk; routing the
# transceiver clock) and surface as P&R FAILs there.
BLOCKED=()

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

# The pinned yosys, and nothing else unless you say so.  Which yosys
# synthesised a design decides what this sweep is even asking, so a run with
# the wrong one does not produce a worse answer, it answers a different
# question while looking identical.  scripts/pinned_yosys.sh resolves it,
# checks it against the submodule this repository records, and refuses
# anything else; YOSYS_UNPINNED=1 is the way to mean it on purpose.
YOSYS=$("$(dirname "$0")/pinned_yosys.sh") || exit 2
export YOSYS

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
# Say which tools produced this, before saying what they produced.  A result
# here is a statement about one synthesis of one design, and two yosys versions
# do not synthesise the same netlist -- the LiteX SoC proves completely under
# one and shows differences under another, which is a fact about the two
# netlists and not about the extractor.  A run that does not record its
# toolchain cannot be compared with a run from last week, and the version was
# unrecoverable exactly once, which was once too often.
yosys_version=$("$YOSYS" -V 2>/dev/null | head -1)
echo "yosys:   ${yosys_version:-unknown ($YOSYS)}"
echo "nextpnr: $("$NEXTPNR_BIN" --version 2>&1 | head -1)"
echo
printf '%-18s %10s %8s %8s   %s\n' DESIGN RESULT PROVED DIFFER NOTE
printf '%.0s-' {1..70}; echo

mkdir -p "$OUT"
for row in "${DESIGNS[@]}"; do
    IFS='|' read -r name dir srcs top xdc part device family synth <<< "$row"
    wanted "$name" || continue
    d="$(cd "$OUT" && pwd)/$name"; mkdir -p "$d"
    log="$d/build.log"

    # @file names a source list, read relative to dir
    case "$srcs" in
        @*) srcs="$(sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]][[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$dir/${srcs#@}" | tr '\n' ' ')" ;;
    esac

    { echo "yosys: ${yosys_version:-unknown}"
      echo "nextpnr: $("$NEXTPNR_BIN" --version 2>&1 | head -1)"; } > "$d/toolchain"
    if ! ( cd "$dir" && "$YOSYS" -q -p \
            "synth_xilinx -flatten -abc9 $synth -arch xc7 -top $top; write_json $d/gold.json" \
            $srcs ) >"$log" 2>&1; then
        printf '%-18s %10s %8s %8s   %s\n' "$name" FAIL - - "synthesis failed, see $log"
        annotate error "$name" "synthesis failed"; tail_log "$log"; summary "| $name | FAIL | - | - |"; fail=$((fail+1)); continue
    fi
    if ! "$NEXTPNR_BIN" --device "$part" -o xdc="$dir/$xdc" --json "$d/gold.json" \
            -o fasm="$d/design.fasm" -o placement="$d/placement.json" --router router2 -o hold-fix >>"$log" 2>&1; then
        printf '%-18s %10s %8s %8s   %s\n' "$name" FAIL - - "place and route failed, see $log"
        annotate error "$name" "place and route failed"; tail_log "$log"; summary "| $name | FAIL | - | - |"; fail=$((fail+1)); continue
    fi
    if ! "$TILEVERILOG" --fasm "$d/design.fasm" --db "$PRJXRAY_DB/$family" --device "$device" \
            --xdc "$dir/$xdc" --part "$part" --out "$d/fabric.v" --model-out "$d/tile_model.v" >>"$log" 2>&1; then
        printf '%-18s %10s %8s %8s   %s\n' "$name" FAIL - - "extraction failed, see $log"
        annotate error "$name" "extraction from the bitstream failed"; tail_log "$log"; summary "| $name | FAIL | - | - |"; fail=$((fail+1)); continue
    fi
    # the design's own names, for reading when a result needs explaining
    "$TILEVERILOG" --fasm "$d/design.fasm" --db "$PRJXRAY_DB/$family" --device "$device" \
        --xdc "$dir/$xdc" --part "$part" --placement "$d/placement.json" --gold-json "$d/gold.json" \
        --out "$d/fabric_named.v" >>"$log" 2>&1
    # -norename: without it write_verilog renames every internal object to
    # _<number>_, inventing names that appear in no other file.  The two
    # representations of this one design then share nothing for a register
    # correspondence to be built on, and an unmatched register makes every
    # cone downstream of it incomparable.  Keeping the names makes the
    # correspondence an identity instead of a reconstruction.
    "$YOSYS" -q -p "read_json $d/gold.json; hierarchy -top $top; splitnets; select $top; \
        write_verilog -noattr -norename -selected $d/gold.v" >>"$log" 2>&1

    # Bounded.  How long this proof takes depends on the placement it was
    # given, and the same design has run in seconds and in many minutes; a
    # sweep that can hang is a sweep nobody will keep in CI.  A timeout is
    # reported as still-blocked rather than as a pass or a failure, because
    # that is exactly what it tells us: not proved, for a known reason.
    res=$(timeout "${EQUIV_TIMEOUT:-600}" \
          "$LVS_EQUIV" --gold "$d/gold.v" --gold-top "$top" --gate "$d/fabric.v" --gate-top fabric \
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
#   blocked    the named blocker is still what stops it   (expected)
#   UNBLOCKED  it got past that blocker                   (fixed -- promote it)
#   FAIL       it broke somewhere else                    (a real regression)
unblocked=0
for row in ${BLOCKED[@]+"${BLOCKED[@]}"}; do
    IFS='|' read -r name dir srcs top xdc part device family stage marker why <<< "$row"
    wanted "$name" || continue
    d="$(cd "$OUT" && pwd)/$name"; mkdir -p "$d"
    log="$d/build.log"; : > "$log"
    root="$PWD"

    # @file names a source list, read relative to dir
    case "$srcs" in
        @*) srcs="$(sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]][[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$dir/${srcs#@}" | tr '\n' ' ')" ;;
    esac

    { echo "yosys: ${yosys_version:-unknown}"
      echo "nextpnr: $("$NEXTPNR_BIN" --version 2>&1 | head -1)"; } > "$d/toolchain"
    if ! ( cd "$dir" && "$YOSYS" -q -p \
            "synth_xilinx -flatten -abc9 -arch xc7 -top $top; write_json $d/gold.json" \
            $srcs ) >>"$log" 2>&1; then
        printf '%-18s %10s %8s %8s   %s\n' "$name" FAIL - - "synthesis failed, see $log"
        annotate error "$name" "synthesis failed"; tail_log "$log"
        summary "| $name | FAIL | - | - |"; fail=$((fail+1)); continue
    fi

    if ! "$NEXTPNR_BIN" --device "$part" -o xdc="$dir/$xdc" --json "$d/gold.json" \
            -o fasm="$d/design.fasm" -o placement="$d/placement.json" --router router2 -o hold-fix \
            >>"$log" 2>&1; then
        if [ "$stage" = pnr ] && grep -qF "$marker" "$log"; then
            printf '%-18s %10s %8s %8s   %s\n' "$name" blocked - - "$why"
            annotate warning "$name" "still blocked: $why"
            summary "| $name | blocked | - | - |"
        else
            printf '%-18s %10s %8s %8s   %s\n' "$name" FAIL - - "place and route failed unexpectedly, see $log"
            annotate error "$name" "failed on something other than the known blocker"
            tail_log "$log"; summary "| $name | FAIL | - | - |"; fail=$((fail+1))
        fi
        continue
    fi

    if [ "$stage" = pnr ]; then
        printf '%-18s %10s %8s %8s   %s\n' "$name" UNBLOCKED - - "place and route now succeeds -- promote this design"
        annotate notice "$name" "no longer blocked: $why"
        summary "| $name | **UNBLOCKED** | - | - |"; unblocked=$((unblocked+1)); continue
    fi

    # stage=equiv: it builds, so take it all the way and see whether it proves
    if ! "$TILEVERILOG" --fasm "$d/design.fasm" --db "$PRJXRAY_DB/$family" --device "$device" \
            --xdc "$dir/$xdc" --part "$part" --out "$d/fabric.v" --model-out "$d/tile_model.v" >>"$log" 2>&1; then
        printf '%-18s %10s %8s %8s   %s\n' "$name" FAIL - - "extraction failed, see $log"
        annotate error "$name" "extraction from the bitstream failed"
        tail_log "$log"; summary "| $name | FAIL | - | - |"; fail=$((fail+1)); continue
    fi
    # -norename: without it write_verilog renames every internal object to
    # _<number>_, inventing names that appear in no other file.  The two
    # representations of this one design then share nothing for a register
    # correspondence to be built on, and an unmatched register makes every
    # cone downstream of it incomparable.  Keeping the names makes the
    # correspondence an identity instead of a reconstruction.
    "$YOSYS" -q -p "read_json $d/gold.json; hierarchy -top $top; splitnets; select $top; \
        write_verilog -noattr -norename -selected $d/gold.v" >>"$log" 2>&1
    # Bounded.  How long this proof takes depends on the placement it was
    # given, and the same design has run in seconds and in many minutes; a
    # sweep that can hang is a sweep nobody will keep in CI.  A timeout is
    # reported as still-blocked rather than as a pass or a failure, because
    # that is exactly what it tells us: not proved, for a known reason.
    res=$(timeout "${EQUIV_TIMEOUT:-600}" \
          "$LVS_EQUIV" --gold "$d/gold.v" --gold-top "$top" --gate "$d/fabric.v" --gate-top fabric \
          --placement "$d/placement.json" --gold-json "$d/gold.json" \
          --db "$PRJXRAY_DB/$family" --device "$device" --quiet 2>&1 | tee -a "$log" | grep -E '^[0-9]+ proved')
    proved=$(echo "$res" | awk '{print $1}')
    differ=$(echo "$res" | awk '{print $3}')
    if [ -z "${differ:-}" ]; then
        printf '%-18s %10s %8s %8s   %s\n' "$name" blocked - - "no verdict within ${EQUIV_TIMEOUT:-600}s; $why"
        annotate warning "$name" "still blocked (no verdict in time): $why"
        summary "| $name | blocked | - | - |"
    elif [ "$differ" -gt 0 ]; then
        printf '%-18s %10s %8s %8s   %s\n' "$name" blocked "$proved" "$differ" "$why"
        annotate warning "$name" "still blocked: $differ differ; $why"
        summary "| $name | blocked | $proved | $differ |"
    else
        printf '%-18s %10s %8s %8s   %s\n' "$name" UNBLOCKED "$proved" 0 "it proves now -- promote this design"
        annotate notice "$name" "no longer blocked: $why"
        summary "| $name | **UNBLOCKED** | $proved | 0 |"; unblocked=$((unblocked+1))
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
