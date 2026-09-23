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
domains, and it is big enough (some 12,500 cells, 168 RAMB36s) to be worth
timing a placer against.

## What is here

    vm_sv2v.v            the processor, converted from SystemVerilog
    ethmin_vm_core.v     code ROM, I/O map, packet window, boot sequencer
    program_bram.v       the code ROM's block RAM
    vc707_ethmin_vm.v    the top: clocking, Ethernet, reset, LEDs
    program.hex          the loader's bytecode, with heap.hex and globals.hex
    program.vh           its sizes, written beside it by the image tools
    vc707_ethmin_vm.xdc  pins, and the clocking placed by hand for this flow

The Ethernet, clocking and UART RTL is shared with `../vc707-ethmin/rtl`
rather than copied: the two SoCs differ only in the processor.

`$readmemh` reads `program.hex`, `heap.hex` and `globals.hex` by relative
path, so synthesis must run **in this directory**. Run yosys anywhere else
and the ROM reads as zero, silently, and the processor boots into nothing.

## Provenance

The processor and SoC come from https://github.com/jrrk2/bytecode
(`ocaml4142_vm_rtl.sv`, `fpga/vc707-ethmin`). `vm_sv2v.v` is generated,
because yosys does not read the SystemVerilog the processor is written in:

    sv2v -DSYNTHESIS -I<bytecode> <bytecode>/ocaml4142_vm_rtl.sv > vm_sv2v.v

Regenerate it with the same command when the processor changes. The `.hex`
images come from that repository's `tools/progimage.sh io/netboot.ml`.

## The clock

`SYS_DIV` divides a 1 GHz VCO for the processor's clock, and `CLK_HZ` must
agree with it — the UART divider and the millisecond timer are counted from
it, so a mismatch shows up as a garbled console and a clock that runs at the
wrong speed rather than as a build failure.
