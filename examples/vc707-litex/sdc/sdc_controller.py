"""mczerski/SD-card-controller wrapped as a LiteX peripheral.

Why this core exists in this repository at all: it is a discriminator, not a
replacement.  LiteSDCard captures CMD and DAT with IDDR primitives at the pad,
and fasm2netlist's tile model handles ILOGIC only as a bypass -- so
verify-extraction drops those ten sites ("10 doing more than a wire (not
modelled)") and every register downstream of them differs, which is the whole
SD block.  The equivalence proof therefore cannot say whether the open flow
implements the SD data path correctly.

This core samples with a plain fabric flip-flop:

    always @(posedge sd_clk)
        DAT_dat_reg <= DAT_dat_i;

and exposes the pads split into in/out/oe, so the tristate is instantiated
here rather than inside it.  That keeps the ILOGIC a pure bypass, which the
tile model does cover, and makes the proof able to see the data path.

Two outcomes, both informative.  If this core works through the open flow
where LiteSDCard does not, the fault is specific to the IDDR capture path.
If it fails the same way, the fault is shared -- the pads, the clocking, or
the Wishbone side -- and the proof can now localise it either way.
"""

import os

from migen import *
# TSTriple lives in migen.fhdl.specials and is re-exported by "from migen import *"

from litex.gen import LiteXModule
from litex.soc.interconnect import wishbone

# Byte offsets, from rtl/verilog/sd_defines.h.  Recorded here because the core
# decodes wb_adr_i as a BYTE address (it compares against 0x04, 0x08, ...)
# whereas LiteX's wishbone adr is a word address; the shift is applied below,
# so software sees these offsets from the peripheral's base.
REGS = {
    "argument":     0x00, "command":      0x04,
    "resp0":        0x08, "resp1":        0x0c,
    "resp2":        0x10, "resp3":        0x14,
    "data_timeout": 0x18, "controller":   0x1c,
    "cmd_timeout":  0x20, "clock_d":      0x24,
    "reset":        0x28, "voltage":      0x2c,
    "capa":         0x30, "cmd_isr":      0x34,
    "cmd_iser":     0x38, "data_isr":     0x3c,
    "data_iser":    0x40, "blksize":      0x44,
    "blkcnt":       0x48, "dst_src_addr": 0x60,
}


class SDCController(LiteXModule):
    def __init__(self, platform, pads, rtl_dir):
        self.bus     = wishbone.Interface(data_width=32)  # slave: registers
        self.dma_bus = wishbone.Interface(data_width=32)  # master: the DMA
        self.int_cmd  = Signal()
        self.int_data = Signal()

        # The pads.  cmd and dat are bidirectional and the core hands us the
        # three halves separately, so these are ordinary IOBUFs with no input
        # register -- which is the entire point of using this core here.
        cmd_t = TSTriple()
        self.specials += cmd_t.get_tristate(pads.cmd)

        dat_t = TSTriple(4)
        self.specials += dat_t.get_tristate(pads.data)

        cmd_oe = Signal()
        dat_oe = Signal()
        # oe is active-high "drive" on this core; TSTriple.oe is the same sense.
        self.comb += [cmd_t.oe.eq(cmd_oe), dat_t.oe.eq(dat_oe)]

        self.specials += Instance("sdc_controller",
            # Wishbone slave.  adr is byte-addressed in the core and
            # word-addressed in LiteX, hence the two zero bits below.
            i_wb_clk_i = ClockSignal("sys"),
            i_wb_rst_i = ResetSignal("sys"),
            i_wb_dat_i = self.bus.dat_w,
            o_wb_dat_o = self.bus.dat_r,
            i_wb_adr_i = Cat(Signal(2, reset=0), self.bus.adr[:6]),
            i_wb_sel_i = self.bus.sel,
            i_wb_we_i  = self.bus.we,
            i_wb_cyc_i = self.bus.cyc,
            i_wb_stb_i = self.bus.stb,
            o_wb_ack_o = self.bus.ack,

            # Wishbone master for the DMA.
            o_m_wb_dat_o = self.dma_bus.dat_w,
            i_m_wb_dat_i = self.dma_bus.dat_r,
            o_m_wb_adr_o = Cat(Signal(2), self.dma_bus.adr[:30]),
            o_m_wb_sel_o = self.dma_bus.sel,
            o_m_wb_we_o  = self.dma_bus.we,
            o_m_wb_cyc_o = self.dma_bus.cyc,
            o_m_wb_stb_o = self.dma_bus.stb,
            i_m_wb_ack_i = self.dma_bus.ack,
            o_m_wb_cti_o = self.dma_bus.cti,
            o_m_wb_bte_o = self.dma_bus.bte,

            # The SD bus.
            i_sd_cmd_dat_i = cmd_t.i,
            o_sd_cmd_out_o = cmd_t.o,
            o_sd_cmd_oe_o  = cmd_oe,
            i_sd_dat_dat_i = dat_t.i,
            o_sd_dat_out_o = dat_t.o,
            o_sd_dat_oe_o  = dat_oe,
            o_sd_clk_o_pad = pads.clk,
            i_sd_clk_i_pad = ClockSignal("sys"),

            o_int_cmd  = self.int_cmd,
            o_int_data = self.int_data,
        )

        # Every file in rtl/verilog except the header, which is `include`d.
        for f in sorted(os.listdir(rtl_dir)):
            if f.endswith(".v"):
                platform.add_source(os.path.join(rtl_dir, f))
        platform.add_verilog_include_path(rtl_dir)
