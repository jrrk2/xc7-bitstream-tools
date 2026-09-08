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
        self.specials += AsyncResetSynchronizer(self.cd_sys, ~locked)
        platform.add_period_constraint(self.cd_sys.clk, 1e9 / sys_clk_freq)


class SDTest(LiteXModule):
    def __init__(self, platform, sys_clk_freq=50e6, sim=False):
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

        leds = platform.request_all("user_led")
        self.comb += leds.eq(Cat(step, stop, beat[23]))

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
        self.fsm = fsm = FSM(reset_state="INIT")
        fsm.act("INIT", NextState("S1"))
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
            done    = core.cmd_event.status[0]
            timeout = core.cmd_event.status[2]
            crc     = core.cmd_event.status[3]
            dat_done    = core.data_event.status[0]
            dat_timeout = core.data_event.status[2]
            dat_crc     = core.data_event.status[3]

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
    p.add_argument("--sim", action="store_true", help="Emit generic-IO Verilog for iverilog.")
    p.add_argument("--sys-clk-freq", type=float, default=50e6)
    args = p.parse_args()

    if args.sim:
        build_sim(args.output_dir, args.sys_clk_freq)
        return

    platform = xilinx_vc707.Platform()
    dut = SDTest(platform, sys_clk_freq=args.sys_clk_freq)
    platform.build(dut, build_dir=args.output_dir, build_name="vc707_sdtest",
                   run=args.build)


if __name__ == "__main__":
    main()
