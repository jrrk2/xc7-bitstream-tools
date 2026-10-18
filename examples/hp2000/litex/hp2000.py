"""HP 2000F Time-Shared BASIC system as a LiteX module (runs in its own, slower clock domain "hp").

The machine (two HP 2100 cores, devices, BRAM memories) is the Verilog in ../rtl.  This wrapper gives it
  * a Wishbone *slave* window (clock-crossed from sys): words 0x0000-0x7fff main memory, 0x8000-0xffff IOP memory,
    0x10000+ the control registers (see REG_* below): reset/run/set-P/status/registers, console FIFO,
    32 multiplexer line registers, tape/disc config
  * a Wishbone *master* through which the machine's disc and tape controllers read and write their images,
    which live in DDR3 at `dram_offset` bytes above the start of main RAM (big-endian 16-bit words, i.e. the
    on-disk byte order of the .img / .hwtape files, so a BIOS TFTP transfer lands them ready to use)

The soft CPU is the machine's I/O processor in the sense of the original: it brings up DRAM, loads images, and
then only moves bytes between the console/line registers and its UART / UDP.
"""
import os

from migen import *
from migen.genlib.resetsync import AsyncResetSynchronizer

from litex.gen import *
from litex.soc.interconnect import wishbone
from litex.soc.interconnect.csr import CSRStorage, CSRStatus, CSRField
from litex.soc.integration.soc import SoCRegion

HERE   = os.path.dirname(os.path.abspath(__file__))
RTLDIR = os.path.normpath(os.path.join(HERE, "..", "rtl"))

RTL_SOURCES = [
    "hp2000_top.v", "hp2000_sys.v", "hp_core.v", "hp2100_cpu.v", "hp_iobus.v", "hp_dma.v", "hp_fp.v",
    "hp_divu.v", "hp_dram_arb.v",
    "dev/hp_tty.v", "dev/hp_iss.v", "dev/hp_disc_store.v", "dev/hp_mt.v", "dev/hp_pr.v", "dev/hp_link.v",
    "dev/hp_tbg.v", "dev/hp_mux.v",
]

DISC_WORDS = 1 << 24          # unit 0 at DRAM word 0 ... (2 units of 2^24 words)
TAPE_WORDS = 1 << 25          # tape image base, in 16-bit words


class _DramPort(LiteXModule):
    """16-bit word-addressed request/ready/rvalid port  ->  32-bit Wishbone master (one access at a time)."""
    def __init__(self, wb, base_adr):
        self.req    = Signal()
        self.we     = Signal()
        self.addr   = Signal(26)
        self.wdata  = Signal(16)
        self.rdy    = Signal()
        self.rvalid = Signal()
        self.rdata  = Signal(16)

        a_q  = Signal(26)
        we_q = Signal()
        wd_q = Signal(16)
        # HP word w lives at byte offset 2w, high byte first.  The 32-bit little-endian bus word at 4*(w>>1)
        # therefore holds the even word in bits 7:0 (hi) / 15:8 (lo) and the odd word in 23:16 / 31:24.
        swap = lambda v: Cat(v[8:16], v[0:8])
        self.fsm = fsm = FSM(reset_state="IDLE")
        fsm.act("IDLE",
            self.rdy.eq(1),
            If(self.req,
                NextValue(a_q, self.addr), NextValue(we_q, self.we), NextValue(wd_q, self.wdata),
                NextState("BUS")))
        fsm.act("BUS",
            wb.cyc.eq(1), wb.stb.eq(1), wb.we.eq(we_q),
            wb.adr.eq(base_adr + a_q[1:]),
            If(we_q,
                wb.dat_w.eq(Cat(swap(wd_q), swap(wd_q))),
                wb.sel.eq(Mux(a_q[0], 0b1100, 0b0011))
            ).Else(
                wb.sel.eq(0b1111)
            ),
            If(wb.ack,
                If(~we_q,
                    self.rvalid.eq(1),
                    self.rdata.eq(Mux(a_q[0], swap(wb.dat_r[16:32]), swap(wb.dat_r[0:16])))),
                NextState("IDLE")))



# register map (word index within the register half of the window)
REG_CONTROL, REG_M_RUN, REG_I_RUN, REG_M_SETP, REG_I_SETP, REG_STATUS = 0, 1, 2, 3, 4, 5
REG_M_PC, REG_M_A, REG_M_B, REG_M_HALT_IR, REG_I_PC, REG_I_HALT_IR = 6, 7, 8, 9, 10, 11
REG_CON_TX, REG_CON_RX, REG_LINE_CONN, REG_LINE_TX, REG_LINE_RX, REG_LINE_RX_FULL = 12, 13, 14, 15, 16, 17


class HP2000(LiteXModule):
    def __init__(self, platform, soc, dram_offset, step=12, window_origin=0xa0000000, hp_freq=20e6, tape_hex=None):
        self.platform = platform
        # --------------------------------------------------------------- clock domain: slower than sys
        # The FP/DIV/mpy paths are long and combinational; 20 MHz (50 ns) closes them with margin.
        # One instruction takes ~12 hp clocks (~600 ns), about 3x faster than a real 2100.
        self.cd_hp = ClockDomain("hp")
        soc.crg.pll.create_clkout(self.cd_hp, hp_freq, with_reset=False)
        platform.add_false_path_constraints(soc.crg.cd_sys.clk, self.cd_hp.clk)
        self.specials += AsyncResetSynchronizer(self.cd_hp, ResetSignal("sys"))

        # --------------------------------------------------------------- bus interfaces
        wb_win_sys  = wishbone.Interface(data_width=32, adr_width=30)
        wb_dram_sys = wishbone.Interface(data_width=32, adr_width=30)
        wb_win      = wishbone.Interface(data_width=32, adr_width=30)      # hp domain
        wb_dram     = wishbone.Interface(data_width=32, adr_width=30)      # hp domain
        soc.bus.add_slave("hp2000", wb_win_sys, SoCRegion(origin=window_origin, size=0x80000, cached=False))
        soc.bus.add_master(name="hp2000_dram", master=wb_dram_sys)
        self.cdc_win  = wishbone.ClockDomainCrossing(wb_win_sys, wb_win, cd_from="sys", cd_to="hp")
        self.cdc_dram = wishbone.ClockDomainCrossing(wb_dram, wb_dram_sys, cd_from="hp", cd_to="sys")
        main_ram_origin = soc.mem_map["main_ram"]
        base_adr = (main_ram_origin + dram_offset) >> 2
        self.dport = _DramPort(wb_dram, base_adr)
        self.dport = ClockDomainsRenamer("hp")(self.dport)

        # --------------------------------------------------------------- the machine and its registers (hp domain)
        h_core  = Signal(); h_addr = Signal(15); h_we = Signal(); h_re = Signal()
        h_wdata = Signal(16); h_rdata = Signal(16)
        m_halted = Signal(); i_halted = Signal(); mt_dirty = Signal(); con_rx_full = Signal()
        con_tx_valid = Signal(); con_tx_byte = Signal(7)
        line_tx_valid = Signal(); line_tx_line = Signal(5); line_tx_byte = Signal(7)
        m_pc = Signal(15); m_a = Signal(16); m_b = Signal(16); m_halt_ir = Signal(16)
        i_pc = Signal(15); i_halt_ir = Signal(16); line_rx_full = Signal(32)

        control   = Signal(5, reset=1)           # reset, mount, rw, disc0, disc1
        m_run = Signal(); i_run = Signal(); m_setp_en = Signal(); i_setp_en = Signal()
        setp_val  = Signal(15)
        con_pop = Signal(); con_rx_wr = Signal(); con_rx_byte = Signal(8)
        line_conn = Signal(32); line_pop = Signal(); line_rx_wr = Signal(); line_rx_val = Signal(13)
        m_setp_q = Signal(15); i_setp_q = Signal(15)
        reset = Signal()
        self.comb += reset.eq(ResetSignal("hp") | control[0])

        for f in RTL_SOURCES:
            platform.add_source(os.path.join(RTLDIR, f))
        if tape_hex is None:
            tape_hex = os.path.normpath(os.path.join(HERE, "..", "build", "tape.hex"))
        self.specials += Instance("hp2000_top",
            p_STEP=step, p_TAPE_HEX=tape_hex,
            i_clk=ClockSignal("hp"), i_rst=reset,
            i_m_run=m_run, i_i_run=i_run,
            i_m_setp_en=m_setp_en, i_m_setp=setp_val, i_i_setp_en=i_setp_en, i_i_setp=setp_val,
            o_m_halted=m_halted, o_m_halt_ir=m_halt_ir, o_m_P=m_pc, o_m_A=m_a, o_m_B=m_b,
            o_i_halted=i_halted, o_i_halt_ir=i_halt_ir, o_i_P=i_pc,
            i_h_core=h_core, i_h_addr=h_addr, i_h_we=h_we, i_h_re=h_re, i_h_wdata=h_wdata, o_h_rdata=h_rdata,
            o_con_tx_valid=con_tx_valid, o_con_tx_byte=con_tx_byte, i_con_tx_pop=con_pop,
            i_con_rx_wr=con_rx_wr, i_con_rx_byte=con_rx_byte, o_con_rx_full=con_rx_full,
            i_line_conn=line_conn,
            o_line_tx_valid=line_tx_valid, o_line_tx_line=line_tx_line, o_line_tx_byte=line_tx_byte,
            i_line_tx_pop=line_pop,
            i_line_rx_wr=line_rx_wr, i_line_rx_line=line_rx_val[8:13], i_line_rx_byte=line_rx_val[0:8],
            o_line_rx_full=line_rx_full,
            i_dsk_unit_present=control[3:5],
            i_mt_mounted=control[1], i_mt_writable=control[2], o_mt_dirty=mt_dirty,
            o_dram_req=self.dport.req, o_dram_we=self.dport.we, o_dram_addr=self.dport.addr,
            o_dram_wdata=self.dport.wdata, i_dram_rdy=self.dport.rdy, i_dram_rvalid=self.dport.rvalid,
            i_dram_rdata=self.dport.rdata)

        # --------------------------------------------------------------- Wishbone window (hp domain)
        wb = wb_win
        ra = Signal(5)
        rdat = Signal(32)
        status = Cat(m_halted, i_halted, mt_dirty, con_rx_full)
        self.comb += Case(ra, {
            REG_CONTROL:     rdat.eq(control),
            REG_STATUS:      rdat.eq(status),
            REG_M_PC:        rdat.eq(m_pc),
            REG_M_A:         rdat.eq(m_a),
            REG_M_B:         rdat.eq(m_b),
            REG_M_HALT_IR:   rdat.eq(m_halt_ir),
            REG_I_PC:        rdat.eq(i_pc),
            REG_I_HALT_IR:   rdat.eq(i_halt_ir),
            REG_CON_TX:      rdat.eq(con_tx_byte | (con_tx_valid << 8)),
            REG_LINE_CONN:   rdat.eq(line_conn),
            REG_LINE_TX:     rdat.eq(line_tx_byte | (line_tx_line << 8) | (line_tx_valid << 16)),
            REG_LINE_RX_FULL: rdat.eq(line_rx_full),
            "default":       rdat.eq(0),
        })
        fsm = ClockDomainsRenamer("hp")(FSM(reset_state="IDLE"))
        self.fsm = fsm
        fsm.act("IDLE",
            If(wb.cyc & wb.stb,
                If(wb.adr[16],
                    NextValue(ra, wb.adr[0:5]),
                    If(wb.we,
                        Case(wb.adr[0:5], {
                            REG_CONTROL:   NextValue(control, wb.dat_w[0:5]),
                            REG_M_RUN:     NextValue(m_run, wb.dat_w[0]),
                            REG_I_RUN:     NextValue(i_run, wb.dat_w[0]),
                            REG_M_SETP:    [NextValue(setp_val, wb.dat_w[0:15]), NextValue(m_setp_en, 1)],
                            REG_I_SETP:    [NextValue(setp_val, wb.dat_w[0:15]), NextValue(i_setp_en, 1)],
                            REG_CON_TX:    NextValue(con_pop, 1),
                            REG_CON_RX:    [NextValue(con_rx_byte, wb.dat_w[0:8]), NextValue(con_rx_wr, 1)],
                            REG_LINE_CONN: NextValue(line_conn, wb.dat_w),
                            REG_LINE_TX:   NextValue(line_pop, 1),
                            REG_LINE_RX:   [NextValue(line_rx_val, wb.dat_w[0:13]), NextValue(line_rx_wr, 1)],
                        })),
                    NextState("REG")
                ).Else(
                    NextValue(h_core, wb.adr[15]), NextValue(h_addr, wb.adr[0:15]),
                    NextValue(h_wdata, wb.dat_w[0:16]),
                    If(wb.we, NextValue(h_we, 1), NextState("WRITE")).Else(NextValue(h_re, 1), NextState("READ0")))))
        fsm.act("REG",                          # strobes last one cycle
            NextValue(m_run, 0), NextValue(i_run, 0), NextValue(m_setp_en, 0), NextValue(i_setp_en, 0),
            NextValue(con_pop, 0), NextValue(con_rx_wr, 0), NextValue(line_pop, 0), NextValue(line_rx_wr, 0),
            wb.ack.eq(1), wb.dat_r.eq(rdat), NextState("IDLE"))
        fsm.act("WRITE",
            NextValue(h_we, 0), wb.ack.eq(1), NextState("IDLE"))
        fsm.act("READ0",                       # the RAM presents its data one cycle after the address
            NextValue(h_re, 0), NextState("READ1"))
        fsm.act("READ1",
            wb.ack.eq(1), wb.dat_r.eq(h_rdata), NextState("IDLE"))
