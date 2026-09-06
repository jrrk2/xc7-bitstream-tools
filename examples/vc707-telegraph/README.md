# VC707 telegraph — a UART and an LED, and nothing else

A bit-banged 8N1 transmitter that repeats the string `JRRK` at 115200 baud,
plus a ripple-counter heartbeat LED. No CPU, no BRAM, no MMCM, no PLL, no
memory controller: 47 flip-flops in total.

## Why it exists

The minimal LiteX SoC builds through the open flow, configures on the board
(`done 1`), and prints nothing. That single observation is consistent with two
completely different faults:

* the clock never reaches the fabric, so the CPU never runs; or
* the clock is fine and the CPU is running, but the UART output path — pad,
  IOB configuration, or routing to it — is broken.

The SoC cannot tell them apart, because it drives no LED. Telegraph answers
both questions at once, on the same board and the same pins:

| Observation | Conclusion |
| --- | --- |
| `led[0]` blinks at ~0.75 Hz | sysclk reaches the fabric and flops toggle |
| `JRRK` arrives on the UART | the AU36 TX path works end to end |
| LED blinks, UART silent | the fault is in the output path, not the clock |
| neither | the clock or the configuration itself is at fault |

The pin choices make this a controlled experiment rather than a new design.
The clock, reset and LED pins are the ones `vc707-johnson` already drives on
this board; `uart_tx` is the pin the LiteX SoC uses (AU36). The open flow
places TX on `LIOB18_X81Y35.IOB_Y0` — the same tile and site as the silent
LiteX UART, with the same three IOB features — so telegraph exercises exactly
the configuration under suspicion.

The core is imported from `vc707-openflow-demos/telegraph`, with `CLK_HZ`
lifted to a parameter so one core serves both the VC707's 200 MHz sysclk and
the Sonata's 25 MHz clk25. Its header records why the message is a 2-bit index
into a combinational ROM rather than an incrementing character register: the
wide-counter version tripped a place-and-route bug that froze the counter.

## Building

```sh
make vc707-telegraph PRJXRAY_DB=$PWD/.deps/prjxray-db   # open flow -> telegraph_vc707.bit
make vc707-telegraph-vivado                             # Vivado    -> build-vivado/telegraph.bit
make vc707-telegraph-flash                              # flash the open-flow build
make vc707-telegraph-flash-vivado                       # flash the Vivado build
```

Both are built because the diagnosis needs both. A design that fails on
hardware through the open flow raises the question "how does this differ from
a bitstream that works?", and only the golden Vivado build of the *same RTL on
the same pins* can answer it — the two can be converted back to FASM with
`prjxray/utils/bit2fasm.py` and compared feature by feature.

## Status

The open-flow build is LVS-clean against its own synthesis: **52 proved, 0
differ**, with all 47 registers matched by name. That establishes the fabric
logic is right; it says nothing about IOB configuration, which LVS does not
model — which is precisely what the hardware test and the FASM comparison are
for.
