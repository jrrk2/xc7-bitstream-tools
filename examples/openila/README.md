# openila -- an internal logic analyser over JTAG, no vendor tool required

`openila.v` is a probe-and-capture block that lives in a design and is read
with openFPGALoader: two BSCANE2 user registers (control on USER2, data on
USER3 by default), a block-RAM ring buffer of `DEPTH` samples of `WIDTH`
bits, a mask/value trigger with a post-trigger count.  `scripts/openila.py`
arms it and reads it back (a table, or a VCD); `scripts/openila_merge.py`
splices it into an existing yosys netlist by net name, so a design can be
probed without touching its RTL -- and, with nextpnr's replay options,
without touching its placement or routing either.

## Adding it to a design

    # 1. synthesise the ILA alone, sized as wanted
    yosys -p "read_verilog openila.v; chparam -set WIDTH 64 -set DEPTH 1024 openila; \
              synth_xilinx -abc9 -arch xc7 -noiopad -noclkbuf -top openila; write_json ila.json"

    # 2. splice: clock net (after its BUFG) and the nets to probe, LSB first
    scripts/openila_merge.py design.json ila.json design_ila.json --clk clk_mac \
        --probe mac.tx_en --probe mac.txd --probe dma.state/4
    # -> design_ila.json, design_ila.json.map (probe bit -> net name)

    # 3. place and route as usual; or keep a reference build's placement and
    #    routing (scripts/routing_dump.py from that build's --write JSON):
    nextpnr-himbaechel ... --json design_ila.json -o preplaced=bels.txt \
        -o prerouted=routes.txt -o holdbufs=holdbufs.txt -o hold-fix

The replay reproduces the reference bit for bit (checked on fpga/rbtest and
on the VC707 OCaml processor build: 0 differing FASM features apart from
the hold-fix's search artefacts); the ILA and the probed nets' new branches
are all that is new.  Pinned cells' tiles are closed to the ILA's cells, so
it cannot take site resources the reference's routes already use.

## Using it

    openila.py status
    openila.py arm --mask 1 --value 1 --post 1000     # trigger on probe[0] == 1
    ... let the design run ...
    openila.py status                                 # armed, triggered, done; waddr=...
    openila.py read --map design_ila.json.map --vcd cap.vcd

`read` shifts the whole buffer out in one DR scan ((DEPTH+1)*WIDTH bits, a
header word first) and rotates it so the oldest sample is row 0; the
trigger sample is row DEPTH-1-POST.  `--width/--depth/--ctl/--dat` must
match the instance; `--clk-ns` sets the VCD timescale.  A wrong chain or a
design without the ILA shows as "BAD KEY".

## Register formats

Control (USER<CTL>), LSB first, taken on UPDATE when KEY = 0x5A:

    [WIDTH-1:0] MASK  [2W-1:W] VALUE  [2W+AW-1:2W] POST  [2W+AW] ARM  [+8:+1] KEY

Status (USER<CTL> CAPTURE, and the data register's header word):

    [AW-1:0] WADDR  [AW] ARMED  [AW+1] TRIGGERED  [AW+2] DONE  [AW+10:AW+3] 0x1A

Data (USER<DAT>): header, then samples 0..DEPTH-1, each LSB first.  CAPTURE
rewinds; the block RAM's read pipeline is covered by the header word.

The probes are registered once on `clk` before the trigger compare and the
write, so every probe adds one flip-flop of load to its net and nothing
combinational.  Trigger: `(sample & MASK) == (VALUE & MASK)`; MASK = 0
triggers at once (a snapshot).  Re-arming is `arm` again (the script
disarms first).  The flags in the header are read raw, so read the buffer
when DONE; WIDTH >= AW+11 and DEPTH a power of two.

## The GUI

`gui/` is a Qt (5 or 6) front end in C++: the same driver as `openila.py`
(openFPGALoader `--user-dr`, one child process per DR scan, asynchronous),
a trigger table (per signal: `x`, `0`/`1`, or a hex value for a bus), a
post-trigger count, arm / disarm / status / read with a poll that reads
the buffer as soon as the ILA reports done, and a waveform view: bits as
square waves, buses as hex boxes, wheel zooms about the mouse, drag pans,
click places the cursor (values by the names; arrows step, `T` goes to the
trigger, `F` fits).  Captures save and load as JSON and export as VCD.

    cmake -S examples/openila/gui -B build-openila-gui && cmake --build build-openila-gui
    build-openila-gui/openila-gui design_ila.json.map

Settings (loader path, cable, TCK, WIDTH/DEPTH/chains, clock period, map)
persist in `~/.config/openXC7/openila-gui.conf`.  `OPENILA_AUTOTEST=<path>`
arms, reads, writes the first samples to that path and two screenshots
beside it, then quits -- a smoke test; `gui/fake_openfpgaloader.py` stands
in for the loader (set it as the loader path) so the test needs no board.
