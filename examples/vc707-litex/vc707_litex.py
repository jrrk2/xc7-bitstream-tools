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
        That input's IOB (AV40, single-ended LVCMOS18) is marginal on the open
        flow -- its ILOGIC ZINV_D is a gap in the prjxray database -- so
        gating reset on it spuriously holds the SoC in reset. Self-boot from
        block RAM needs no button.

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

# The VC707's SGMII reference clock (SGMIICLK, AH8/AH7). Named here because
# the PHY's GT reset FSMs size their timers from it, so a wrong value is a
# link that never comes up rather than a build error.
SGMII_REFCLK_FREQ = 125e6


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


class BaseSoC(SoCCore):
    def __init__(self, sys_clk_freq=SYS_CLK_FREQ, with_led_chaser=True,
                 with_ethernet=False, flow="unknown", **kwargs):
        platform = xilinx_vc707.Platform()

        self.crg = _CRG(platform, sys_clk_freq)

        # The two implementation flows build the SAME gateware, so a board
        # running one is indistinguishable from a board running the other.
        # Naming the flow in the SoC identifier is what tells them apart:
        # `ident` at the BIOS prompt reads it back out of the identifier CSR.
        SoCCore.__init__(self, platform, sys_clk_freq,
                         ident=f"LiteX SoC on VC707 [{flow}]", **kwargs)

        # ...and announce it at boot rather than only on request, in the
        # banner's tagline. NOT in CONFIG_CPU_HUMAN_NAME: that field means
        # "which CPU", and the implementation flow is not a property of the
        # CPU. The tagline needs patches/litex-bios-configurable-tagline.patch
        # applied to the litex submodule; without it the stock tagline is
        # printed and the flow is still readable with the `ident` command.
        self.add_config("BIOS_BANNER_TAGLINE", TAGLINES.get(flow, f"Built with {flow}"))

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
            self.add_ethernet(phy=self.ethphy)

        if with_led_chaser:
            self.leds = LedChaser(
                pads=platform.request_all("user_led"),
                sys_clk_freq=sys_clk_freq)


def main():
    from litex.build.parser import LiteXArgumentParser
    parser = LiteXArgumentParser(platform=xilinx_vc707.Platform,
                                 description="Minimal LiteX SoC on VC707.")
    parser.add_target_argument("--sys-clk-freq", default=SYS_CLK_FREQ, type=float,
                               help="System clock frequency (MMCM CLKOUT0; 25 MHz is what the open flow closes).")
    parser.add_target_argument("--with-led-chaser", action="store_true", help="Enable Led Chaser.")
    parser.add_target_argument("--with-ethernet", action="store_true",
                               help="Enable LiteEth over the SGMII GTX transceiver.")
    parser.add_target_argument("--flow", default="unknown",
                               help="Name of the implementation flow this build is for; "
                                    "reported by the BIOS 'ident' command.")
    args = parser.parse_args()

    soc = BaseSoC(
        sys_clk_freq=args.sys_clk_freq,
        with_led_chaser=args.with_led_chaser,
        with_ethernet=args.with_ethernet,
        flow=args.flow,
        **parser.soc_argdict)
    builder = Builder(soc, **parser.builder_argdict)
    if args.build:
        builder.build(**parser.toolchain_argdict)


if __name__ == "__main__":
    main()
