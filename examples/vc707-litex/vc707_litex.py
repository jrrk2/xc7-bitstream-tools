#!/usr/bin/env python3
"""A minimal LiteX SoC for the VC707, ported from openXC7's
demo-projects/litex-minimal-arty-s7.

Two things differ from the upstream litex-boards VC707 target, both on
purpose:

  * No DDR3.  The upstream target instantiates a V7DDRPHY, whose IDELAY /
    ISERDES / OSERDES this project's extraction does not model.  The SoC gets
    its memory from integrated block RAM instead, which is also what makes it
    a useful test: the ROM and RAM contents have to come back out of the
    bitstream.

  * The clock generator is not LiteX's S7MMCM but the raw MMCME2_ADV
    configuration from vc707-openflow-demos' ethmin (clkgen_vc707.sv), which
    is proven on this board in both the Vivado and the open nextpnr flow.
    Two things in it are load-bearing and are the reason for copying it
    rather than letting LiteX pick:

      - 25 MHz, not 50.  200 MHz x5 = 1 GHz VCO, CLKOUT0_DIVIDE_F = 40.  The
        open flow has no proper hold STA and does not reliably close 50 MHz.
      - Reset comes from MMCM LOCKED, NOT from the board's CPU_RESET button.
        This was originally done because that input looked unreliable on the
        open flow, blamed on "ILOGIC ZINV_D is a gap in the prjxray
        database".  That diagnosis was wrong: segbits_lioi.db has defined
        LIOI.ILOGIC_Y{0,1}.ZINV_D all along, and nextpnr simply never emitted
        it, so every input arrived inverted.  Fixed 2026-09-05; the real gap
        is narrower -- no RIOI* or SING tile type defines the bit, so an input
        on a right-hand bank still cannot have its inversion set from FASM.
        Self-booting from block RAM needs no button either way, so this is
        left as it is.

    The MMCM itself is not something this project's extraction models, so it
    will not appear as a cell in the extracted netlist; that costs nothing
    here, because the extraction ties every slice clock straight to the
    top-level clock port rather than reconstructing the clock tree anyway.

What it should exercise, once extracted: block RAM (ROM + main RAM),
distributed RAM (the CPU register file and the CSR/UART FIFOs), CARRY4 (every
counter and address adder in the SoC) and the LUT/FF fabric.
"""

from migen import *
from migen.genlib.resetsync import AsyncResetSynchronizer

from litex.gen import *

from litex_boards.platforms import xilinx_vc707

from litex.soc.integration.soc import *
from litex.soc.integration.soc_core import SoCCore
from litex.soc.integration.builder import Builder
from litex.soc.cores.led import LedChaser
from litex.soc.cores.clock import S7MMCM, S7IDELAYCTRL

# The VC707's SGMII reference clock (SGMIICLK, AH8/AH7). Named here because
# the PHY's GT reset FSMs size their timers from it, so a wrong value is a
# link that never comes up rather than a build error.
SGMII_REFCLK_FREQ = 125e6

# Where the SoC lives on the network, and where it looks for a boot image.
# The BIOS's own defaults are 192.168.1.50 / 192.168.1.100; the remote is
# overridden here to this development host, so that "Booting from network"
# reaches a machine that actually exists rather than timing out on an address
# nothing answers.  Both are --local-ip / --remote-ip on the command line.
LOCAL_IP  = "192.168.1.50"
REMOTE_IP = "192.168.1.106"

# LiteEth's default MAC is 10:e2:d5:00:00:00, and EVERY LiteX SoC built with
# defaults answers to it.  There is more than one such SoC on this network --
# the Sonata Linux triage in ~/sonata-linux is another -- so this one is given
# an address of its own.  Two boards sharing a MAC is not a subtle failure to
# debug later: ARP resolves to whichever answered last.
MAC_ADDRESS = 0x10e2d5000007

# ...and, for the same reason, its own TFTP server rather than the system one
# on port 69.  That server's root holds the Sonata triage's boot.json, and the
# BIOS asks for "boot.json" by a name it does not let us change -- so the two
# boards would fetch each other's boot image.  Pointing this SoC at a separate
# port with a separate root keeps each triage's payload its own, and leaves
# the running tftpd-hpa (which the Sonata setup depends on) untouched.
TFTP_PORT = 6969


# What each implementation flow puts in the BIOS banner, in place of LiteX's
# stock "Build your hardware, easily!". This is the line that tells you at a
# glance which of the two bitstreams the board is running -- they are built
# from identical gateware and are otherwise indistinguishable.
TAGLINES = {
    "openXC7": "Build your hardware, with nextpnr",
    "vivado":  "Build your hardware, with Vivado",
}

CLK_IN_FREQ  = 200e6    # the VC707's LVDS board clock
SYS_CLK_FREQ = 25e6     # 1 GHz VCO / CLKOUT0_DIVIDE_F

# With DDR3 the system clock is the memory bus clock / 4, and 100 MHz is what
# this board's -2 speed grade and the module's 1:4 phase ratio are comfortable
# with -- upstream's 125 MHz leaves the open flow no margin at all later.
DDR_SYS_CLK_FREQ = 100e6


class _CRG(LiteXModule):
    """VC707 clock generator, transcribed from vc707-openflow-demos' ethmin.

    A raw MMCME2_ADV rather than LiteX's S7MMCM, so that the parameters stay
    exactly the ones proven on this board: a direct feedback loop, ZHOLD
    compensation, x5 to a 1 GHz VCO and /40 back down to 25 MHz.
    """

    def __init__(self, platform, sys_clk_freq):
        self.rst    = Signal()
        self.cd_sys = ClockDomain()

        clk200    = platform.request("clk200")
        clk200_se = Signal()
        self.specials += Instance("IBUFDS", i_I=clk200.p, i_IB=clk200.n, o_O=clk200_se)

        clk_fb        = Signal()
        clk_sys_unbuf = Signal()
        locked        = Signal()
        self.specials += Instance("MMCME2_ADV",
            p_BANDWIDTH          = "OPTIMIZED",
            p_COMPENSATION       = "ZHOLD",
            p_STARTUP_WAIT       = "FALSE",
            p_DIVCLK_DIVIDE      = 1,
            p_CLKFBOUT_MULT_F    = 5.0,
            p_CLKFBOUT_PHASE     = 0.0,
            p_CLKOUT0_DIVIDE_F   = CLK_IN_FREQ * 5.0 / sys_clk_freq,
            p_CLKOUT0_PHASE      = 0.0,
            p_CLKOUT0_DUTY_CYCLE = 0.5,
            p_CLKIN1_PERIOD      = 1e9 / CLK_IN_FREQ,
            i_CLKIN1             = clk200_se,
            i_CLKIN2             = 0,
            i_CLKINSEL           = 1,
            i_CLKFBIN            = clk_fb,
            o_CLKFBOUT           = clk_fb,
            o_CLKOUT0            = clk_sys_unbuf,
            i_DADDR = 0, i_DCLK = 0, i_DEN = 0, i_DI = 0, i_DWE = 0,
            i_PSCLK = 0, i_PSEN = 0, i_PSINCDEC = 0,
            i_PWRDWN = 0, i_RST = 0,
            o_LOCKED             = locked,
        )
        self.specials += Instance("BUFG", i_I=clk_sys_unbuf, o_O=self.cd_sys.clk)

        # Reset on MMCM lock, deliberately NOT on the board's CPU_RESET pin --
        # see the note at the top of this file.
        self.specials += AsyncResetSynchronizer(self.cd_sys, ~locked | self.rst)

        platform.add_period_constraint(self.cd_sys.clk, 1e9 / sys_clk_freq)


class _CRGDDR(LiteXModule):
    """The clock generator the DDR3 PHY needs, which the one above cannot be.

    V7DDRPHY runs the memory bus at 4x the system clock and calibrates its
    input delays against a 200 MHz IDELAYCTRL reference, so it needs three
    related clocks rather than one.  That rules out the hand-written
    MMCME2_ADV above -- it produces a single output -- so this path uses
    LiteX's S7MMCM, exactly as litex-boards' own xilinx_vc707 target does.

    The consequence worth knowing when reading a triage result: a DDR build
    and a non-DDR build do NOT share a clock generator, so they are not a
    controlled comparison of the memory controller alone.  Reset here comes
    from the CPU_RESET button, as upstream has it, where the non-DDR CRG
    deliberately self-boots from MMCM lock instead.
    """

    def __init__(self, platform, sys_clk_freq):
        self.rst       = Signal()
        self.cd_sys    = ClockDomain()
        self.cd_sys4x  = ClockDomain()
        self.cd_idelay = ClockDomain()

        self.pll = pll = S7MMCM(speedgrade=-2)
        self.comb += pll.reset.eq(platform.request("cpu_reset") | self.rst)
        pll.register_clkin(platform.request("clk200"), CLK_IN_FREQ)
        pll.create_clkout(self.cd_sys,    sys_clk_freq)
        pll.create_clkout(self.cd_sys4x,  4 * sys_clk_freq)
        pll.create_clkout(self.cd_idelay, 200e6)
        # The SoC's reset makes a sys_clk -> pll.clkin path that is not real.
        platform.add_false_path_constraints(self.cd_sys.clk, pll.clkin)

        self.idelayctrl = S7IDELAYCTRL(self.cd_idelay)


class BaseSoC(SoCCore):
    def __init__(self, sys_clk_freq=SYS_CLK_FREQ, with_led_chaser=True,
                 with_ethernet=False, with_ddr=False, flow="unknown",
                 local_ip=LOCAL_IP, remote_ip=REMOTE_IP,
                 mac_address=MAC_ADDRESS, tftp_port=TFTP_PORT, **kwargs):
        platform = xilinx_vc707.Platform()

        self.crg = _CRGDDR(platform, sys_clk_freq) if with_ddr \
            else _CRG(platform, sys_clk_freq)

        # The two implementation flows build the SAME gateware, so a board
        # running one is indistinguishable from a board running the other.
        # Naming the flow in the SoC identifier is what tells them apart:
        # `ident` at the BIOS prompt reads it back out of the identifier CSR.
        variant = "+".join(["LiteX SoC on VC707"]
                           + (["DDR3"] if with_ddr else [])
                           + (["LiteEth"] if with_ethernet else []))
        SoCCore.__init__(self, platform, sys_clk_freq,
                         ident=f"{variant} [{flow}]", **kwargs)

        # ...and announce it at boot rather than only on request, in the
        # banner's tagline. NOT in CONFIG_CPU_HUMAN_NAME: that field means
        # "which CPU", and the implementation flow is not a property of the
        # CPU. The tagline needs patches/litex-bios-configurable-tagline.patch
        # applied to the litex submodule; without it the stock tagline is
        # printed and the flow is still readable with the `ident` command.
        self.add_config("BIOS_BANNER_TAGLINE", TAGLINES.get(flow, f"Built with {flow}"))

        # DDR3 --------------------------------------------------------------
        # The MT8JTF12864 SODIMM through the 7-series PHY, as litex-boards'
        # own target has it.  Only when the SoC was not given integrated main
        # RAM instead: that is how the block-RAM-only variant opts out, and
        # asking for both would leave the controller built but unused.
        if with_ddr:
            from litedram.modules import MT8JTF12864
            from litedram.phy import s7ddrphy

            if self.integrated_main_ram_size:
                raise ValueError(
                    "--with-ddr and --integrated-main-ram-size are alternatives: "
                    "the SoC takes its main RAM from one or the other")

            self.ddrphy = s7ddrphy.V7DDRPHY(platform.request("ddram"),
                                            memtype      = "DDR3",
                                            nphases      = 4,
                                            sys_clk_freq = sys_clk_freq)
            self.add_sdram("sdram",
                           phy           = self.ddrphy,
                           module        = MT8JTF12864(sys_clk_freq, "1:4"),
                           l2_cache_size = kwargs.get("l2_size", 8192))

            # The DDR3 pins are SSTL15_T_DCI, and Vivado's startup sequence
            # waits for DCI match before releasing DONE.  On this board that
            # wait does not complete: the bitstream loads with no CRC error
            # and the FPGA sits in startup state 3 with DONE low, so nothing
            # ever runs.  DCI still calibrates; this only stops the startup
            # sequence blocking on it.
            platform.add_platform_command(
                "set_property BITSTREAM.STARTUP.MATCH_CYCLE NoWait [current_design]")

        # Ethernet ---------------------------------------------------------
        # LiteEth's open 1000BASE-X/SGMII PCS driving the GTXE2 directly, in
        # the configuration vc707-openflow-demos' ethmin proved on this board
        # (ethmin/liteeth_phy/gen_liteeth_phy.py): the K7 PHY -- Virtex-7 and
        # Kintex-7 share the GTX -- fed from SGMIICLK at 125 MHz, with
        # sys_clk_freq passed truthfully because the GT reset FSMs size their
        # timers from it.
        #
        # The transceiver and the PHY's two user-clock MMCMs are outside what
        # this project's extraction models, so they will not appear as cells
        # in the extracted netlist. The MAC, its FIFOs and the SoC around it
        # are ordinary fabric and are exactly the point: they are what turns
        # this into a real test of the block RAM and distributed RAM support.
        if with_ethernet:
            from liteeth.phy.k7_1000basex import K7_1000BASEX

            class _Pads:
                """K7_1000BASEX reads .txp/.txn/.rxp/.rxn -- the `sfp` naming
                of the boards it was written against. The VC707 spells the
                same SGMII pins tx_p/tx_n/rx_p/rx_n, so rename rather than
                request a resource this design does not use."""

            eth = platform.request("eth")
            data_pads = _Pads()
            data_pads.txp, data_pads.txn = eth.tx_p, eth.tx_n
            data_pads.rxp, data_pads.rxn = eth.rx_p, eth.rx_n

            self.ethphy = K7_1000BASEX(
                refclk_or_clk_pads = platform.request("sgmii_clock"),
                data_pads          = data_pads,
                sys_clk_freq       = sys_clk_freq,
                refclk_freq        = SGMII_REFCLK_FREQ)
            # Naming both addresses here is what puts LOCALIP*/REMOTEIP* in
            # the generated software config.  Left unset, the BIOS falls back
            # to its own compiled-in defaults and the remote is 192.168.1.100.
            self.add_ethernet(phy=self.ethphy, local_ip=local_ip,
                              remote_ip=remote_ip, mac_address=mac_address)

            # boot.c takes TFTP_SERVER_PORT from a #ifndef, so a constant here
            # redirects the BIOS's network boot without patching the BIOS.
            self.add_constant("TFTP_SERVER_PORT", tftp_port)

        if with_led_chaser:
            self.leds = LedChaser(
                pads=platform.request_all("user_led"),
                sys_clk_freq=sys_clk_freq)


def main():
    from litex.build.parser import LiteXArgumentParser
    parser = LiteXArgumentParser(platform=xilinx_vc707.Platform,
                                 description="Minimal LiteX SoC on VC707.")
    parser.add_target_argument("--sys-clk-freq", default=None, type=float,
                               help="System clock frequency.  Defaults to 25 MHz, which is what "
                                    "the open flow closes, or to 100 MHz with --with-ddr, which "
                                    "is what the DDR3 module's 1:4 phase ratio needs.")
    parser.add_target_argument("--with-led-chaser", action="store_true", help="Enable Led Chaser.")
    parser.add_target_argument("--with-ethernet", action="store_true",
                               help="Enable LiteEth over the SGMII GTX transceiver.")
    parser.add_target_argument("--local-ip", default=LOCAL_IP,
                               help="IP address the SoC answers on.")
    parser.add_target_argument("--remote-ip", default=REMOTE_IP,
                               help="IP address the BIOS network-boots from (a TFTP server).")
    parser.add_target_argument("--mac-address", default=MAC_ADDRESS, type=lambda v: int(v, 0),
                               help="MAC address the SoC answers to.")
    parser.add_target_argument("--tftp-port", default=TFTP_PORT, type=int,
                               help="UDP port the BIOS network-boots from.")
    parser.add_target_argument("--with-ddr", action="store_true",
                               help="Enable the DDR3 SODIMM through the V7DDRPHY.  Selects a "
                                    "different clock generator; see _CRGDDR.")
    parser.add_target_argument("--flow", default="unknown",
                               help="Name of the implementation flow this build is for; "
                                    "reported by the BIOS 'ident' command.")
    args = parser.parse_args()

    sys_clk_freq = args.sys_clk_freq
    if sys_clk_freq is None:
        sys_clk_freq = DDR_SYS_CLK_FREQ if args.with_ddr else SYS_CLK_FREQ

    soc = BaseSoC(
        sys_clk_freq=sys_clk_freq,
        with_led_chaser=args.with_led_chaser,
        with_ethernet=args.with_ethernet,
        with_ddr=args.with_ddr,
        local_ip=args.local_ip,
        remote_ip=args.remote_ip,
        mac_address=args.mac_address,
        tftp_port=args.tftp_port,
        flow=args.flow,
        **parser.soc_argdict)
    builder = Builder(soc, **parser.builder_argdict)
    if args.build:
        builder.build(**parser.toolchain_argdict)


if __name__ == "__main__":
    main()
