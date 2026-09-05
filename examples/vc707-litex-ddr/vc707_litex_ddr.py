#!/usr/bin/env python3
"""A LiteX SoC for the VC707 with its DDR3 SODIMM.

The sibling example, examples/vc707-litex, deliberately has NO DDR3: it runs
from block RAM so that the ROM and RAM contents have to come back out of the
bitstream, and because the V7DDRPHY's IDELAY/ISERDES/OSERDES are not something
that project's extraction models.  This one is the opposite experiment -- the
memory controller IS the point -- so it is built with Vivado first, where the
answer is known, before the open flow is asked the same question.

It follows litex-boards' own xilinx_vc707 target closely: the same S7MMCM CRG
(sys, sys4x, idelay at 200 MHz), the same S7IDELAYCTRL, the same V7DDRPHY on
the same MT8JTF12864 SODIMM.  Two deliberate differences:

  * No PCIe.  The upstream target imports litepcie at module scope, so using
    it at all would mean vendoring a dependency this design never
    instantiates.

  * 100 MHz rather than the upstream 125 MHz default, which is what the DDR3
    module's 1:4 phase ratio and this board's -2 speed grade are comfortable
    with, and leaves margin for the open flow to have a chance later.

Everything else -- the SODIMM model, the PHY, the L2 -- is upstream's.
"""

from migen import *

from litex.gen import LiteXModule
from litex.build.xilinx.vivado import vivado_build_args, vivado_build_argdict
from litex_boards.platforms import xilinx_vc707
from litex.soc.cores.clock import S7MMCM, S7IDELAYCTRL
from litex.soc.integration.soc_core import SoCCore
from litex.soc.integration.builder import Builder, builder_args, builder_argdict
from litex.soc.cores.led import LedChaser
from litedram.modules import MT8JTF12864
from litedram.phy import s7ddrphy


class _CRG(LiteXModule):
    def __init__(self, platform, sys_clk_freq):
        self.rst       = Signal()
        self.cd_sys    = ClockDomain()
        self.cd_sys4x  = ClockDomain()
        self.cd_idelay = ClockDomain()

        self.pll = pll = S7MMCM(speedgrade=-2)
        self.comb += pll.reset.eq(platform.request("cpu_reset") | self.rst)
        pll.register_clkin(platform.request("clk200"), 200e6)
        pll.create_clkout(self.cd_sys,    sys_clk_freq)
        pll.create_clkout(self.cd_sys4x,  4 * sys_clk_freq)
        pll.create_clkout(self.cd_idelay, 200e6)
        # The SoC's reset makes a sys_clk -> pll.clkin path that is not real.
        platform.add_false_path_constraints(self.cd_sys.clk, pll.clkin)

        self.idelayctrl = S7IDELAYCTRL(self.cd_idelay)


class BaseSoC(SoCCore):
    def __init__(self, sys_clk_freq=100e6, with_led_chaser=True, flow="unknown", **kwargs):
        platform = xilinx_vc707.Platform()
        self.crg = _CRG(platform, sys_clk_freq)
        SoCCore.__init__(self, platform, sys_clk_freq,
                         ident=f"LiteX SoC on VC707 - DDR3 - {flow}", **kwargs)

        # DDR3 SODIMM, through the 7-series PHY.  Only when the SoC has not
        # been given integrated main RAM instead -- that is how the sibling
        # example opts out of the controller entirely.
        if not self.integrated_main_ram_size:
            self.ddrphy = s7ddrphy.V7DDRPHY(platform.request("ddram"),
                                            memtype      = "DDR3",
                                            nphases      = 4,
                                            sys_clk_freq = sys_clk_freq)
            self.add_sdram("sdram",
                           phy           = self.ddrphy,
                           module        = MT8JTF12864(sys_clk_freq, "1:4"),
                           l2_cache_size = kwargs.get("l2_size", 8192))

        if with_led_chaser:
            self.leds = LedChaser(pads=platform.request_all("user_led"),
                                  sys_clk_freq=sys_clk_freq)


def main():
    from litex.build.parser import LiteXArgumentParser
    parser = LiteXArgumentParser(platform=xilinx_vc707.Platform,
                                 description="LiteX SoC on VC707 with DDR3.")
    parser.add_target_argument("--sys-clk-freq", default=100e6, type=float,
                               help="System clock frequency.")
    parser.add_target_argument("--flow", default="unknown",
                               help="Names the flow in the BIOS banner, so two "
                                    "bitstreams built from identical gateware "
                                    "can be told apart on the board.")
    args = parser.parse_args()

    soc = BaseSoC(sys_clk_freq=args.sys_clk_freq, flow=args.flow,
                  **parser.soc_argdict)
    builder = Builder(soc, **parser.builder_argdict)
    if args.build:
        builder.build(**parser.toolchain_argdict)


if __name__ == "__main__":
    main()
