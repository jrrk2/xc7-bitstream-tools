# vc707-ocaml — a processor whose instruction set is OCaml bytecode

The same VC707 SoC as `examples/vc707-ethmin` — 1G Ethernet MAC, LiteEth
SGMII PCS/PMA over a GTX, UART console — with one difference: in place of
the picorv32 sits a processor that executes **OCaml 4.14 bytecode
directly**, with no interpreter in between. Its memories are block RAM: a
32K-word code ROM, a 32K-word heap with a Cheney copying collector, and 8K
of globals. Sixteen of the runtime's primitives are in hardware; the rest
reach the SoC through a trap interface, which is how the program drives the
UART and the packet window.

The ROM here holds the netboot loader: it does DHCP, ARP and TFTP in OCaml,
fetches a program image over Ethernet and runs it. That makes this design a
useful thing to build from source — it exercises block RAM with contents,
carry chains, DSPs, an MMCM, a GTX, HP I/O in both directions and two clock
domains, and it is big enough (some 14,300 cells, 168 RAMB36s, 20 DSP48E1s)
to be worth timing a placer against.

Floating point is in hardware: Berkeley HardFloat's cores behind the
processor's trap port, so `caml_add_float` and its siblings are answered by
silicon rather than by a library.  The FPU is proved against the host's own
doubles in the source repository -- every operation, bit for bit.

## What is here

    ocaml4142_vm_rtl.sv  the processor, in SystemVerilog
    state_rtl_complete.h its state and opcode definitions, `included by it
    fpu_hardfloat.v      a double-precision FPU on the processor's trap port
    recode64.v           IEEE-754 <-> HardFloat's recoded format
    hardfloat.v          Berkeley HardFloat's cores (BSD)
    ethmin_vm_core.v     code ROM, I/O map, packet window, boot sequencer
    program_bram.v       the code ROM's block RAM
    vc707_ethmin_vm.v    the top: clocking, Ethernet, reset, LEDs
    program.hex          the loader's bytecode, with heap.hex and globals.hex
    program.vh           its sizes, written beside it by the image tools
    vc707_ethmin_vm.xdc  pins, and the clocking placed by hand for this flow
    vivado.xdc           the same pins for Vivado, which places the clocking itself
    vivado.tcl           Vivado place and route of Verilator's EDIF

The Ethernet, clocking and UART RTL is shared with `../vc707-ethmin/rtl`
rather than copied: the two SoCs differ only in the processor.

`$readmemh` reads `program.hex`, `heap.hex` and `globals.hex` by relative
path, so synthesis must run **in this directory**. Run it anywhere else
and the ROM reads as zero, silently, and the processor boots into nothing.

## Provenance

The processor and SoC come from https://github.com/jrrk2/bytecode
(`ocaml4142_vm_rtl.sv`, `fpga/vc707-ethmin`). The processor is that
repository's SystemVerilog, unconverted -- `ocaml4142_vm_rtl.sv` and the
`state_rtl_complete.h` it includes, as of bytecode commit 4bd1d08. Verilator,
the default synthesiser here, elaborates SystemVerilog itself, so there is no
sv2v step. (An sv2v conversion of the same commit is what this directory used
to carry for yosys; `SYNTH=yosys` cannot read the SystemVerilog, so build this
example with the default synthesiser.)

Copy both files again when the processor changes. The `.hex`
images come from that repository's `tools/progimage.sh io/netboot.ml`.

## The clock

This example asks for **50 MHz**, which is what it closes through the open
flow with the FPU in it:

    100 MHz   Vivado closes it (WNS +0.559); the open flow reaches 71.8
     75 MHz   61.0 MHz achieved   fails
     62.5 MHz 59.5 MHz achieved   fails, and leaves two hold violations
     50 MHz   62.2 MHz achieved   passes, no hold violations   <- shipped

Without the FPU the same design reaches about 72-77 MHz through the open
flow, varying with placement -- which is why 75 MHz, tried first, was too
close to the edge to ship even then.

`SYS_DIV` divides a 1 GHz VCO for the processor's clock, and `CLK_HZ` must
agree with it — the UART divider and the millisecond timer are counted from
it, so a mismatch shows up as a garbled console and a clock that runs at the
wrong speed rather than as a build failure.

## Building with Vivado

Verilator writes an EDIF netlist beside the JSON, and Vivado places that
directly, so the same synthesis can be laid out by either placer:

    cd examples/vc707-ocaml
    mkdir -p build
    ../../scripts/synth.sh --top vc707_ethmin_vm --out build/vc707_ethmin_vm.json \
        --edif build/vc707_ethmin_vm.edf $(grep -v '^#' sources.f)
    cd build && vivado -mode batch -nojournal -source ../vivado.tcl

Synthesis must still run in this directory, for the `$readmemh` paths.
Use `vivado.xdc`, not `vc707_ethmin_vm.xdc`: the nextpnr file's hand
placement names cells the way nextpnr's flat netlist does (`clkgen.mmcm`),
and none of them match a cell in the hierarchical EDIF. Left out, those
constraints do no harm in Vivado, which puts the MMCMs where the
transceiver's clocks reach them on its own.

Built this way from Verilator f814989b6 with Vivado 2020.1: 22020 LUTs, 199
block RAM tiles, 12 DSPs, timing met with 3.8 ns to spare at 50 MHz
(clk_sys) and 2.1 ns at 125 MHz (the MAC), in about 6 minutes and 3 GB. It
netboots on the board.

## Booting it

The loader fetches `vm.img` by TFTP from **port 6969**, not the standard 69,
so a system TFTP server will not answer it: the requests arrive at a port
nothing is listening on, and the console says `boot: no answer` over and
over. Serve the image with `scripts/tftp_serve.py`, which looks in a
directory named after the board's MAC first:

    scripts/tftp_serve.py --root ~/tftp-vc707 --port 6969
    # serves ~/tftp-vc707/02:00:00:4d:47:33/vm.img to this board

The image goes into a **64 KiB** staging RAM, so it must be no larger than
that. A bigger one -- such as one packed for the bytecode repository's
current core, whose code RAM is 128K words -- stops after block 128 (64 KiB
in 512-byte blocks) and the transfer never finishes. Pack one with the
bytecode repository's tools:

    tools/progimage.sh fact.ml build/fact
    tools/mkvmimage.py build/fact ~/tftp-vc707/02:00:00:4d:47:33/vm.img

The factorial then boots:

    boot: tftp vm.img
    boot: 1372 bytes
    boot: 223 code, 98 heap, 14 globals words: starting it
    00120
