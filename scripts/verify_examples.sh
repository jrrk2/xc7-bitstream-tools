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
)

# name | what the tile model would have to learn first
NOT_YET=(
  "vc707-idelay|IDELAYE2: a delay is not a boolean function, so equivalence needs a decision first"
)

mkdir -p "$OUT"
fail=0 pass=0
printf '%-18s %10s %8s %8s   %s\n' DESIGN RESULT PROVED DIFFER NOTE
printf '%.0s-' {1..70}; echo

for row in "${DESIGNS[@]}"; do
    IFS='|' read -r name srcs top xdc part device family <<< "$row"
    d="$OUT/$name"; mkdir -p "$d"
    log="$d/build.log"

    if ! "$YOSYS" -q -p "synth_xilinx -flatten -abc9 -nobram -arch xc7 -top $top; write_json $d/gold.json" \
            $srcs >"$log" 2>&1; then
        printf '%-18s %10s %8s %8s   %s\n' "$name" FAIL - - "synthesis failed, see $log"; fail=$((fail+1)); continue
    fi
    if ! "$NEXTPNR_BIN" --device "$part" -o xdc="$xdc" --json "$d/gold.json" \
            -o fasm="$d/design.fasm" -o placement="$d/placement.json" --router router2 >>"$log" 2>&1; then
        printf '%-18s %10s %8s %8s   %s\n' "$name" FAIL - - "place and route failed, see $log"; fail=$((fail+1)); continue
    fi
    if ! "$TILEVERILOG" --fasm "$d/design.fasm" --db "$PRJXRAY_DB/$family" --device "$device" \
            --xdc "$xdc" --part "$part" --out "$d/fabric.v" --model-out "$d/tile_model.v" >>"$log" 2>&1; then
        printf '%-18s %10s %8s %8s   %s\n' "$name" FAIL - - "extraction failed, see $log"; fail=$((fail+1)); continue
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
        printf '%-18s %10s %8s %8s\n' "$name" PROVED "$proved" "$differ"; pass=$((pass+1))
    else
        printf '%-18s %10s %8s %8s   %s\n' "$name" DIFFER "${proved:--}" "${differ:--}" "see $log"; fail=$((fail+1))
    fi
done

for row in "${NOT_YET[@]}"; do
    IFS='|' read -r name why <<< "$row"
    printf '%-18s %10s %8s %8s   %s\n' "$name" skipped - - "$why"
done

echo
echo "$pass proved, $fail failed, ${#NOT_YET[@]} not yet eligible"
exit $(( fail > 0 ))
