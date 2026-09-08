#!/usr/bin/env python3
"""The SD block, a state machine that drives it to the first data transfer, and
eight LEDs.

Why this exists.  The SD card works through Vivado on this board and fails
through the open flow, and every attempt to find the difference has been made
on a full SoC: a SERV CPU, a BIOS, block RAM, a wishbone fabric.  The
equivalence proof on that design reports over twelve hundred differing
registers, which is too many to read, and the console is the only instrument.

This design removes everything that is not the SD block.  No CPU, no BIOS, no
bus: SDPHY and SDCore with their CSR signals driven straight from a hardcoded
FSM, and the result on the LEDs.  It is small enough that lvs_equiv's answer
can be read line by line, and simple enough to simulate first, so the stimulus
is known-good before any bitstream is built.

LED encoding, chosen so a phone camera of the board is a complete bug report:

    led[3:0]   the step reached, counting up (see STEPS below)
    led[6:4]   why it stopped: 0 running, 1 ok, 2 timeout, 3 CRC, 4 wrong data
    led[7]     heartbeat, so a dead clock is distinguishable from a stuck FSM
"""

import os
import sys

from migen import *
from migen.genlib.resetsync import AsyncResetSynchronizer

from litex.gen import LiteXModule
from litex.build.generic_platform import Pins, Subsignal
from litex_boards.platforms import xilinx_vc707

from litesdcard.phy import SDPHY
from litesdcard.core import SDCore

# Command encodings, from the SD physical layer spec.  cmd_command is
# {index[13:8], ..., data_transfer[6:5], response_type[1:0]}; the fields are
# named in litesdcard/core.py.
RSP_NONE, RSP_SHORT, RSP_LONG, RSP_SHORT_BUSY = 0, 1, 2, 3
XFER_NONE, XFER_READ, XFER_WRITE = 0, 1, 2

STEPS = [
    "CMD0  GO_IDLE",          # 1
    "CMD8  IF_COND",          # 2
    "CMD55 APP_CMD",          # 3
    "ACMD41 OP_COND",         # 4
    "CMD2  ALL_SEND_CID",     # 5
    "CMD3  SEND_RCA",         # 6
    "CMD7  SELECT",           # 7
    "CMD17 READ_SINGLE",      # 8  <- the first data transfer
]

STOP_RUNNING, STOP_OK, STOP_TIMEOUT, STOP_CRC, STOP_DATA = 0, 1, 2, 3, 4


class _CRG(LiteXModule):
    """The board's 200 MHz differential input, divided to the system clock.

    Deliberately the same MMCM configuration the other VC707 examples use, so
    that a difference between this design and those is never the clocking.
    """
    def __init__(self, platform, sys_clk_freq):
        self.cd_sys = ClockDomain()

        clk200 = platform.request("clk200")
        clk200_se = Signal()
        self.specials += Instance("IBUFDS", i_I=clk200.p, i_IB=clk200.n, o_O=clk200_se)

        fb, unbuf, locked = Signal(), Signal(), Signal()
        self.specials += Instance("MMCME2_ADV",
            p_BANDWIDTH        = "OPTIMIZED",
            p_COMPENSATION     = "ZHOLD",
            p_DIVCLK_DIVIDE    = 1,
            p_CLKFBOUT_MULT_F  = 5.0,
            p_CLKOUT0_DIVIDE_F = 200e6 * 5.0 / sys_clk_freq,
            p_CLKIN1_PERIOD    = 1e9 / 200e6,
            i_CLKIN1  = clk200_se,
            i_CLKINSEL = 1,
            i_CLKFBIN = fb,
            o_CLKFBOUT = fb,
            o_CLKOUT0 = unbuf,
            i_DADDR=0, i_DCLK=0, i_DEN=0, i_DI=0, i_DWE=0,
            i_PSCLK=0, i_PSEN=0, i_PSINCDEC=0, i_PWRDWN=0, i_RST=0,
            o_LOCKED  = locked,
        )
        self.specials += Instance("BUFG", i_I=unbuf, o_O=self.cd_sys.clk)
        # The board's CPU_RESET button, so the sequence can be re-run without
        # reflashing: press it and the FSM starts again from the PHY init.
        # Active high on the VC707 (AV40), combined with the MMCM lock so a
        # press and a loss of lock reset the design the same way.
        rst_button = platform.request("cpu_reset")
        self.specials += AsyncResetSynchronizer(self.cd_sys, ~locked | rst_button)
        platform.add_period_constraint(self.cd_sys.clk, 1e9 / sys_clk_freq)


class SDTest(LiteXModule):
    def __init__(self, platform, sys_clk_freq=50e6, sim=False, with_ila=False):
        if sim:
            # The domain has to exist as a domain, not just as a driven
            # ClockSignal: finalize() looks for one.
            self.cd_sys = ClockDomain()
            self.comb += [
                self.cd_sys.clk.eq(platform.request("sys_clk")),
                self.cd_sys.rst.eq(platform.request("sys_rst")),
            ]
        else:
            self.crg = _CRG(platform, sys_clk_freq)

        self.probes = []

        pads = platform.request("sdcard")
        # LiteX's add_sdcard uses 1.0 s timeouts, which is 50 million cycles at
        # 50 MHz -- fine on hardware, useless in simulation, where waiting one
        # simulated second for a command that gets no reply looks exactly like a
        # hung state machine.  A millisecond is still thousands of SD clocks.
        timeout = 1e-3 if sim else 10e-1
        self.phy  = phy  = SDPHY(pads, platform.device, sys_clk_freq,
                                 cmd_timeout=timeout, data_timeout=timeout)
        self.core = core = SDCore(phy)

        # The core's CSRs are never collected into a bank here -- this is a
        # plain module, not a SoC -- so the FSM drives them directly.  That is
        # the whole reason there is no CPU: the register writes a BIOS would
        # make are the FSM's transitions instead.
        arg     = Signal(32)
        command = Signal(32)
        send    = Signal()
        self.comb += [
            core.cmd_argument.storage.eq(arg),
            core.cmd_command.storage.eq(command),
            core.cmd_send.re.eq(send),
            core.cmd_send.storage.eq(1),
            core.block_length.storage.eq(512),
            core.block_count.storage.eq(1),
            # Nothing consumes the read data here; the test is whether the
            # transfer completes, not what the card holds.
            core.source.ready.eq(1),
            core.sink.valid.eq(0),
        ]

        step = Signal(4)
        stop = Signal(3, reset=STOP_RUNNING)
        rca  = Signal(16)

        # A slow free-running counter, so a stopped clock and a stopped FSM
        # look different on the board.
        beat = Signal(24)
        self.sync += beat.eq(beat + 1)


        # The ILA, instantiated directly rather than through mark_debug: the
        # attribute route needs Vivado to insert a debug core, which fails in
        # batch ("Design needs to be saved before implementing debug cores"),
        # and the pad nets it would want are not reachable from the fabric
        # anyway.  An explicit instance takes the signals we choose, on the
        # fabric side of the I/O buffers where they exist.  Generated by
        # ip/gen_ila.tcl, after cva6's xlnx_ila.
        if with_ila:
            ila_ip = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                  "ip", "sdtest_ila.srcs", "sources_1", "ip",
                                  "sdtest_ila", "sdtest_ila.xci")
            platform.add_source(ila_ip)
            self.ila_probes = None   # filled in after the FSM builds its signals

        step = Signal(4)
        stop = Signal(3, reset=STOP_RUNNING)
        rca  = Signal(16)

        # A slow free-running counter, so a stopped clock and a stopped FSM
        # look different on the board.
        beat = Signal(24)
        self.sync += beat.eq(beat + 1)

        leds = platform.request_all("user_led")
        self.comb += leds.eq(Cat(step, stop, beat[23]))

        # What to capture on hardware.  The LEDs say where it stopped; the ILA
        # says what the bus was doing when it did, which is the part no amount
        # of staring at a FASM diff has been able to answer.
        if not sim:
            for sig, name in [
                (step,                     "dbg_step"),
                (stop,                     "dbg_stop"),
                (core.cmd_event.status,    "dbg_cmd_event"),
                (core.data_event.status,   "dbg_data_event"),
                (command,                  "dbg_command"),
                (arg,                      "dbg_arg"),
                (send,                     "dbg_send"),
                (pads.cmd,                 "dbg_sd_cmd"),
                (pads.data,                "dbg_sd_dat"),
                (pads.clk,                 "dbg_sd_clk"),
            ]:
                probe = Signal(len(sig), name=name)
                probe.attr.add(("mark_debug", "true"))
                probe.attr.add("keep")
                self.comb += probe.eq(sig)
                self.probes.append(probe)

        def issue(index, argument, rsp, xfer=XFER_NONE, nxt=None, n=None):
            """One command: drive the registers, pulse send, wait, classify."""
            return [
                NextValue(step, n),
                NextValue(arg, argument),
                NextValue(command, (index << 8) | (xfer << 5) | rsp),
                NextState("SEND_" + nxt),
            ]

        # An explicit entry state.  With S1 as the reset state migen folded its
        # branch into the case default, which is "stay here", so the machine
        # never left it -- visible in simulation as fsm=0 forever while the
        # heartbeat counted normally.  One state that does nothing but leave
        # avoids relying on how the reset state is encoded.
        # The PHY must be initialised before any command: SDPHYInit sends the
        # 80 clocks the SD spec requires at power-up, gated on a write to its
        # "initialize" CSR.  A BIOS does this explicitly and I had skipped it,
        # so the SD clock never ran, CMD0 was never transmitted, and the machine
        # waited in WAIT1 for a completion that could not arrive -- step 1 lit
        # and nothing else, on the board and in simulation alike.
        phy_init = Signal()
        self.comb += phy.init.initialize.re.eq(phy_init)

        init_wait = Signal(16)
        self.fsm = fsm = FSM(reset_state="INIT")
        # Let everything settle, then hold "initialize" high for a while rather
        # than pulsing it on the first cycle out of reset -- that raced the
        # PHY's own FSM leaving reset in the same cycle, and a missed strobe
        # looks exactly like a card that never answers.  The PHY leaves IDLE on
        # the first cycle it sees the strobe, so holding it is harmless.
        fsm.act("INIT",
            NextValue(init_wait, init_wait + 1),
            If(init_wait == 1023, NextValue(init_wait, 0), NextState("INIT_PULSE")),
        )
        fsm.act("INIT_PULSE",
            phy_init.eq(1),
            NextValue(init_wait, init_wait + 1),
            If(init_wait == 63, NextValue(init_wait, 0), NextState("INIT_WAIT")),
        )
        # The 80 clocks run at the divider's reset value, sys_clk/256, so about
        # 20k system clocks; wait well past that.
        fsm.act("INIT_WAIT",
            NextValue(init_wait, init_wait + 1),
            If(init_wait == 0xffff, NextState("S1")),
        )

        for i, (index, argument, rsp, xfer) in enumerate([
            ( 0, 0x00000000, RSP_NONE,       XFER_NONE),
            ( 8, 0x000001aa, RSP_SHORT,      XFER_NONE),
            (55, 0x00000000, RSP_SHORT,      XFER_NONE),
            (41, 0x40100000, RSP_SHORT,      XFER_NONE),
            ( 2, 0x00000000, RSP_LONG,       XFER_NONE),
            ( 3, 0x00000000, RSP_SHORT,      XFER_NONE),
            ( 7, 0x00000000, RSP_SHORT_BUSY, XFER_NONE),
            (17, 0x00000000, RSP_SHORT,      XFER_READ),
        ], start=1):
            nxt = "S{}".format(i + 1) if i < len(STEPS) else "DONE"
            arg_expr = argument if index != 7 else Cat(Signal(16), rca)

            fsm.act("S{}".format(i),
                NextValue(step, i),
                NextValue(arg, arg_expr),
                NextValue(command, (index << 8) | (xfer << 5) | rsp),
                NextState("SEND{}".format(i)),
            )
            fsm.act("SEND{}".format(i),
                send.eq(1),
                NextState("WAIT{}".format(i)),
            )
            # cmd_event bits: 0 done, 1 (unused), 2 timeout, 3 CRC error.
            # Read the FIELDS, not .status.  CSRStatus keeps the two separate
            # and only the CSR bank machinery in a SoC joins them; this is a
            # plain module, so .status is never driven and synthesis folds it
            # to zero -- which is exactly what the ILA captured, eight probe
            # bits reported as <const0>, and why WAIT1 never saw a done.
            done    = core.cmd_event.fields.done
            timeout = core.cmd_event.fields.timeout
            crc     = core.cmd_event.fields.crc
            dat_done    = core.data_event.fields.done
            dat_timeout = core.data_event.fields.timeout
            dat_crc     = core.data_event.fields.crc

            checks = [
                If(timeout, NextValue(stop, STOP_TIMEOUT), NextState("STOPPED")),
                # ACMD41 answers R3, which carries no CRC: the card sends ones
                # where the checksum would be, so a CRC "error" there is the
                # spec working as intended and not a fault.
                If(crc & (index != 41), NextValue(stop, STOP_CRC), NextState("STOPPED")),
            ]
            if index == 3:
                checks.append(NextValue(rca, core.cmd_response.status[16:32]))
            if xfer == XFER_READ:
                fsm.act("WAIT{}".format(i),
                    If(done,
                        *checks,
                        If(~timeout & ~crc, NextState("DATA{}".format(i))),
                    ),
                )
                fsm.act("DATA{}".format(i),
                    If(dat_done,
                        If(dat_timeout, NextValue(stop, STOP_TIMEOUT), NextState("STOPPED")
                        ).Elif(dat_crc,  NextValue(stop, STOP_DATA),    NextState("STOPPED")
                        ).Else(          NextValue(stop, STOP_OK),      NextState("STOPPED")),
                    ),
                )
            else:
                fsm.act("WAIT{}".format(i),
                    If(done,
                        *checks,
                        If(~timeout & ~(crc & (index != 41)), NextState(nxt)),
                    ),
                )

        fsm.act("DONE",   NextValue(stop, STOP_OK), NextState("STOPPED"))
        fsm.act("STOPPED", NextState("STOPPED"))

        if with_ila:
            sd_bus = Cat(phy.sdpads.clk, phy.sdpads.cmd.o, phy.sdpads.cmd.oe,
                         phy.sdpads.cmd.i, phy.sdpads.data.i[:4])
            self.specials += Instance("sdtest_ila",
                i_clk    = ClockSignal("sys"),
                i_probe0 = step,
                i_probe1 = stop,
                i_probe2 = Cat(core.cmd_event.fields.done, core.cmd_event.fields.error,
                               core.cmd_event.fields.timeout, core.cmd_event.fields.crc),
                i_probe3 = Cat(core.data_event.fields.done, core.data_event.fields.error,
                               core.data_event.fields.timeout, core.data_event.fields.crc),
                i_probe4 = send,
                i_probe5 = phy_init,
                i_probe6 = command[:16],
                i_probe7 = sd_bus,
                i_probe8 = Cat(phy.clocker.clk, phy.clocker.clk_en),
            )

        # Build the debug core from whatever carries MARK_DEBUG, rather than
        # naming nets: synthesis renames them, and a hand-written net list goes
        # stale the first time the design changes.
        # Auto-inserting the debug core in batch fails with "Design needs to be
        # saved before implementing debug cores" even with a checkpoint written
        # first, so this is opt-in.  The mark_debug attributes above are always
        # emitted, which is what "Set Up Debug" in the GUI keys off -- that path
        # inserts the core reliably and is the one to use.
        if not sim and self.probes and os.environ.get("SDTEST_AUTO_ILA"):
            depth = 4096
            # LiteX puts these through str.format(), so every literal brace
            # has to be doubled or the TCL never reaches Vivado.
            tcl = [
                "set dbg [get_nets -hier -filter {{MARK_DEBUG}}]",
                "create_debug_core u_ila_0 ila",
                "set_property C_DATA_DEPTH {} [get_debug_cores u_ila_0]".format(depth),
                "set_property C_TRIGIN_EN false [get_debug_cores u_ila_0]",
                "set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_0]",
                "set_property port_width 1 [get_debug_ports u_ila_0/clk]",
                "connect_debug_port u_ila_0/clk [get_nets -hier -filter {{NAME =~ *sys_clk*}}]",
                "set i 0",
                "foreach n $dbg {{",
                "    if {{$i > 0}} {{ create_debug_port u_ila_0 probe }}",
                "    set_property port_width 1 [get_debug_ports u_ila_0/probe$i]",
                "    connect_debug_port u_ila_0/probe$i $n",
                "    incr i",
                "}}",
                # implement_debug_core refuses on an unsaved design.
                "write_checkpoint -force post_synth_debug.dcp",
                "implement_debug_core",
            ]
            for line in tcl:
                platform.toolchain.pre_placement_commands.append(line)


# The pads the simulation platform needs.  Same names and widths as the VC707
# platform's "sdcard" resource, so the design elaborates identically; only the
# I/O primitives differ, which is the point -- generic ones simulate.
_SIM_IO = [
    ("sys_clk", 0, Pins(1)),
    ("sys_rst", 0, Pins(1)),
    ("sdcard", 0,
        Subsignal("clk",  Pins(1)),
        Subsignal("cmd",  Pins(1)),
        Subsignal("data", Pins(4)),
    ),
    ("user_led", 0, Pins(1)), ("user_led", 1, Pins(1)),
    ("user_led", 2, Pins(1)), ("user_led", 3, Pins(1)),
    ("user_led", 4, Pins(1)), ("user_led", 5, Pins(1)),
    ("user_led", 6, Pins(1)), ("user_led", 7, Pins(1)),
]


def build_sim(output_dir, sys_clk_freq):
    """Emit the design with generic I/O, for iverilog.

    The board build instantiates IBUFDS, MMCME2_ADV, IDDR, ODDR and IOBUF.
    Simulating those needs the vendor's models; simulating the SD protocol does
    not need them at all.  SimPlatform lowers the same SDROutput/SDRTristate
    specials to plain Verilog, so the logic under test is the same and the pads
    become ordinary wires.
    """
    from litex.build.sim.platform import SimPlatform
    platform = SimPlatform("SIM", _SIM_IO)
    dut = SDTest(platform, sys_clk_freq=sys_clk_freq, sim=True)
    platform.build(dut, build_dir=output_dir, build_name="vc707_sdtest_sim", run=False)


def main():
    import argparse
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--build",   action="store_true", help="Run the vendor flow.")
    p.add_argument("--flow",    default="openXC7",   help="Label for provenance.")
    p.add_argument("--output-dir", default="build")
    p.add_argument("--ila", action="store_true", help="Instantiate the ILA (Vivado only).")
    p.add_argument("--sim", action="store_true", help="Emit generic-IO Verilog for iverilog.")
    p.add_argument("--sys-clk-freq", type=float, default=50e6)
    args = p.parse_args()

    if args.sim:
        build_sim(args.output_dir, args.sys_clk_freq)
        return

    platform = xilinx_vc707.Platform()
    dut = SDTest(platform, sys_clk_freq=args.sys_clk_freq, with_ila=args.ila)
    platform.build(dut, build_dir=args.output_dir, build_name="vc707_sdtest",
                   run=args.build)


if __name__ == "__main__":
    main()
