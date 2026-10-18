// HP 2000F system: main (TSB) processor + I/O processor, each an hp_core, with their devices.
//   main: teleprinter console (sc 12), ISS disc (sc 15/16), link cards (sc 10 in, 11 out)
//   IOP : time base generator (sc 12), two 12920A multiplexers (sc 13/14+15 and 16/17+20), link cards
// Memories live outside (host/testbench or FPGA BRAM); mux lines, console and the disc image are host
// interfaces.
module hp2000_sys #(parameter STEP = 12, parameter [17:0] TAPE_LEN = 18'd60108, parameter TAPE_HEX = "build/tape.hex") (
    input             clk,
    input             rst,
    // main memory
    output            m_mem_req, output m_mem_we, output [14:0] m_mem_addr, output [15:0] m_mem_wdata,
    input             m_mem_gnt, input [15:0] m_mem_rdata,
    // IOP memory
    output            i_mem_req, output i_mem_we, output [14:0] i_mem_addr, output [15:0] i_mem_wdata,
    input             i_mem_gnt, input [15:0] i_mem_rdata,
    // run control
    input             m_run_req, input [14:0] m_set_p, input m_set_p_en,
    input             i_run_req, input [14:0] i_set_p, input i_set_p_en,
    // console
    output            con_tx_valid, output [6:0] con_tx_data,
    input             con_rx_avail, input [7:0] con_rx_data, output con_rx_take,
    // disc image lives in DRAM: word address = {unit, lba[16:0], word[6:0]}
    input      [1:0]  dsk_unit_present,
    output            dram_req, output dram_we, output [25:0] dram_addr, output [15:0] dram_wdata,
    input             dram_rdy, input dram_rvalid, input [15:0] dram_rdata,
    // magnetic tape: image (taphw layout) at word 2^25 of the same DRAM
    input             mt_mounted, input mt_writable, output mt_dirty,
    // multiplexer lines
    input      [15:0] a_conn, input [15:0] a_rx_avail, input [127:0] a_rx_data, output [15:0] a_rx_take,
    output     [15:0] a_tx_valid, output [111:0] a_tx_data,
    input      [15:0] b_conn, input [15:0] b_rx_avail, input [127:0] b_rx_data, output [15:0] b_rx_take,
    output     [15:0] b_tx_valid, output [111:0] b_tx_data,
    // status
    output            m_retire_o,
    output            m_halted, output [15:0] m_halt_ir, output [14:0] m_P, output [15:0] m_A, output [15:0] m_B,
    output            i_halted, output [15:0] i_halt_ir, output [14:0] i_P
);
    assign m_retire_o = m_retire;
    // ------------------------------------------------------------------ main processor
    wire [5:0]  m_sc_s, m_sc;
    wire        m_stc, m_clc, m_stf, m_clf, m_ot, m_crs, m_edt, m_h, m_dma, m_rd;
    wire [15:0] m_dout, m_din;
    wire [63:0] m_flag, m_fb, m_ctl;
    wire [63:0] m_setflag, m_clrflag, m_srq_en, m_srq_val;
    wire        m_defer, m_intsys, m_retire, m_E, m_O;
    wire [5:0]  m_cir;

    hp_core mcore (
        .clk(clk), .rst(rst),
        .mem_req(m_mem_req), .mem_we(m_mem_we), .mem_addr(m_mem_addr), .mem_wdata(m_mem_wdata),
        .mem_gnt(m_mem_gnt), .mem_rdata(m_mem_rdata),
        .sw(16'd0), .run_req(m_run_req), .set_p(m_set_p), .set_p_en(m_set_p_en), .stall(1'b0),
        .ld_en(1'b0), .ld_a(16'd0), .ld_b(16'd0), .ld_e(1'b0), .ld_o(1'b0),
        .dev_sc(m_sc), .dev_sc_s(m_sc_s), .dev_stc(m_stc), .dev_clc(m_clc), .dev_stf(m_stf), .dev_clf(m_clf),
        .dev_ot(m_ot), .dev_crs(m_crs), .dev_edt(m_edt), .dev_h(m_h), .dev_dma(m_dma), .dev_rd(m_rd),
        .dev_dout(m_dout), .dev_din(m_din), .dev_noclf(1'b0), .dev_setflag(m_setflag), .dev_clrflag(m_clrflag),
        .dev_srq_en(m_srq_en), .dev_srq_val(m_srq_val),
        .flag_q(m_flag), .flagbuf_q(m_fb), .control_q(m_ctl),
        .halted(m_halted), .halt_ir(m_halt_ir), .retire(m_retire), .A(m_A), .B(m_B), .P(m_P), .E(m_E), .O(m_O),
        .defer(m_defer), .intsys(m_intsys), .cir(m_cir));

    // main devices
    wire [15:0] tty_rd, dsk_rd, mlk_in_rd, mlk_out_rd;
    wire        tty_sel, dsk_sel, mlk_in_sel, mlk_out_sel;
    wire        tty_sf, dsk_sf_dc, dsk_sf_cc, dsk_cf_cc, mlk_in_sf, mlk_out_sf;
    wire        dsk_srq;
    // links
    wire        m2i_stb, i2m_stb, m2i_ack, i2m_ack;      // data/command direction and the acknowledge back
    wire [15:0] m2i_data, i2m_data, m2i_ackd, i2m_ackd;

    hp_tty #(.SC(6'o12), .STEP(STEP)) tty (
        .clk(clk), .rst(rst), .sc_s(m_sc_s), .stc(m_stc), .ot(m_ot), .dout(m_dout), .rd_sc(m_sc),
        .rd_data(tty_rd), .rd_sel(tty_sel), .setflag(tty_sf),
        .tx_valid(con_tx_valid), .tx_data(con_tx_data), .rx_avail(con_rx_avail), .rx_data(con_rx_data),
        .rx_take(con_rx_take));

    wire        bs_req, bs_wr, bs_unit, bs_idle, bs_done, bb_we;
    wire [16:0] bs_lba;
    wire [6:0]  bb_waddr, bb_raddr;
    wire [15:0] bb_wdata, bb_rdata;

    hp_iss #(.SC(6'o15), .STEP(STEP)) disc (
        .clk(clk), .rst(rst), .sc_s(m_sc_s), .stc(m_stc), .ot(m_ot), .edt(m_edt), .dma(m_dma), .dout(m_dout),
        .rd_sc(m_sc), .rd_data(dsk_rd), .rd_sel(dsk_sel),
        .setflag_dc(dsk_sf_dc), .setflag_cc(dsk_sf_cc), .clrflag_cc(dsk_cf_cc), .flag_dc(m_flag[6'o15]), .srq_dc(dsk_srq),
        .unit_present(dsk_unit_present),
        .bs_req(bs_req), .bs_wr(bs_wr), .bs_unit(bs_unit), .bs_lba(bs_lba), .bs_idle(bs_idle), .bs_done(bs_done),
        .bufb_we(bb_we), .bufb_waddr(bb_waddr), .bufb_wdata(bb_wdata), .bufb_raddr(bb_raddr), .bufb_rdata(bb_rdata));

    wire        da_req, da_we, da_rdy, da_rvalid;
    wire [24:0] da_addr;
    wire [15:0] da_wdata, da_rdata;
    hp_disc_store dstore (
        .clk(clk), .rst(rst), .req(bs_req), .wr(bs_wr), .unit(bs_unit), .lba(bs_lba), .idle(bs_idle), .done(bs_done),
        .bufb_we(bb_we), .bufb_waddr(bb_waddr), .bufb_wdata(bb_wdata), .bufb_raddr(bb_raddr), .bufb_rdata(bb_rdata),
        .dram_req(da_req), .dram_we(da_we), .dram_addr(da_addr), .dram_wdata(da_wdata),
        .dram_rdy(da_rdy), .dram_rvalid(da_rvalid), .dram_rdata(da_rdata));

    // tape controller and the shared DRAM port
    wire [15:0] mt_rd;
    wire        mt_sel, mt_sf_dc, mt_cf_dc, mt_sf_cc, mt_srq;
    wire        ta_req, ta_we, ta_done;
    wire [25:0] ta_addr;
    wire [15:0] ta_wdata, ta_rdata;
    hp_mt #(.SC(6'o21), .STEP(STEP)) tape (
        .clk(clk), .rst(rst), .sc_s(m_sc_s), .stc(m_stc), .ot(m_ot), .edt(m_edt), .dout(m_dout),
        .rd_sc(m_sc), .rd_data(mt_rd), .rd_sel(mt_sel),
        .setflag_dc(mt_sf_dc), .clrflag_dc(mt_cf_dc), .setflag_cc(mt_sf_cc),
        .flag_dc(m_flag[6'o21]), .ctl_dc(m_ctl[6'o21]), .srq_dc(mt_srq),
        .mounted(mt_mounted), .writable(mt_writable), .dirty(mt_dirty),
        .ta_req(ta_req), .ta_we(ta_we), .ta_addr(ta_addr), .ta_wdata(ta_wdata), .ta_done(ta_done), .ta_rdata(ta_rdata));
    hp_dram_arb arb (
        .clk(clk), .rst(rst), .a_busy(!bs_idle), .a_req(da_req), .a_we(da_we), .a_addr(da_addr), .a_wdata(da_wdata),
        .a_rdy(da_rdy), .a_rvalid(da_rvalid), .a_rdata(da_rdata),
        .b_req(ta_req), .b_we(ta_we), .b_addr(ta_addr), .b_wdata(ta_wdata), .b_done(ta_done), .b_rdata(ta_rdata),
        .dram_req(dram_req), .dram_we(dram_we), .dram_addr(dram_addr), .dram_wdata(dram_wdata),
        .dram_rdy(dram_rdy), .dram_rvalid(dram_rvalid), .dram_rdata(dram_rdata));

    wire [15:0] pr_rd; wire pr_sel, pr_sf;
    hp_pr #(.SC(6'o13), .STEP(STEP), .LEN(TAPE_LEN), .INIT(TAPE_HEX)) photoreader (
        .clk(clk), .rst(rst), .sc_s(m_sc_s), .stc(m_stc), .rd_sc(m_sc), .rd_data(pr_rd), .rd_sel(pr_sel), .setflag(pr_sf));

    hp_link #(.SC(6'o10)) m_link_in (       // main receives from the IOP
        .clk(clk), .rst(rst), .sc_s(m_sc_s), .stc(m_stc), .ot(m_ot), .dout(m_dout), .rd_sc(m_sc),
        .rd_data(mlk_in_rd), .rd_sel(mlk_in_sel), .setflag(mlk_in_sf),
        .tx_stb(i2m_ack), .tx_data(i2m_ackd), .rx_stb(i2m_stb), .rx_data(i2m_data));
    hp_link #(.SC(6'o11)) m_link_out (      // main sends to the IOP
        .clk(clk), .rst(rst), .sc_s(m_sc_s), .stc(m_stc), .ot(m_ot), .dout(m_dout), .rd_sc(m_sc),
        .rd_data(mlk_out_rd), .rd_sel(mlk_out_sel), .setflag(mlk_out_sf),
        .tx_stb(m2i_stb), .tx_data(m2i_data), .rx_stb(m2i_ack), .rx_data(m2i_ackd));

    assign m_din = (tty_sel ? tty_rd : 16'd0) | (dsk_sel ? dsk_rd : 16'd0) | (mt_sel ? mt_rd : 16'd0) | (pr_sel ? pr_rd : 16'd0) |
                   (mlk_in_sel ? mlk_in_rd : 16'd0) | (mlk_out_sel ? mlk_out_rd : 16'd0);
    assign m_setflag = ({63'd0, tty_sf} << 6'o12) | ({63'd0, dsk_sf_dc} << 6'o15) | ({63'd0, dsk_sf_cc} << 6'o16) |
                       ({63'd0, mlk_in_sf} << 6'o10) | ({63'd0, mlk_out_sf} << 6'o11) |
                       ({63'd0, pr_sf} << 6'o13) | ({63'd0, mt_sf_dc} << 6'o21) | ({63'd0, mt_sf_cc} << 6'o22);
    assign m_clrflag = ({63'd0, dsk_cf_cc} << 6'o16) | ({63'd0, mt_cf_dc} << 6'o21);
    assign m_srq_en  = (64'd1 << 6'o15) | (64'd1 << 6'o21);
    assign m_srq_val = ({63'd0, dsk_srq} << 6'o15) | ({63'd0, mt_srq} << 6'o21);

    // ------------------------------------------------------------------ I/O processor
    wire [5:0]  i_sc_s, i_sc;
    wire        i_stc, i_clc, i_stf, i_clf, i_ot, i_crs, i_edt, i_h, i_dma, i_rd;
    wire [15:0] i_dout, i_din;
    wire [63:0] i_flag, i_fb, i_ctl;
    wire [63:0] i_setflag;
    wire        i_defer, i_intsys, i_retire, i_E, i_O;
    wire [5:0]  i_cir;
    wire [15:0] i_A, i_B;

    hp_core icore (
        .clk(clk), .rst(rst),
        .mem_req(i_mem_req), .mem_we(i_mem_we), .mem_addr(i_mem_addr), .mem_wdata(i_mem_wdata),
        .mem_gnt(i_mem_gnt), .mem_rdata(i_mem_rdata),
        .sw(16'd0), .run_req(i_run_req), .set_p(i_set_p), .set_p_en(i_set_p_en), .stall(1'b0),
        .ld_en(1'b0), .ld_a(16'd0), .ld_b(16'd0), .ld_e(1'b0), .ld_o(1'b0),
        .dev_sc(i_sc), .dev_sc_s(i_sc_s), .dev_stc(i_stc), .dev_clc(i_clc), .dev_stf(i_stf), .dev_clf(i_clf),
        .dev_ot(i_ot), .dev_crs(i_crs), .dev_edt(i_edt), .dev_h(i_h), .dev_dma(i_dma), .dev_rd(i_rd),
        .dev_dout(i_dout), .dev_din(i_din), .dev_noclf(1'b0), .dev_setflag(i_setflag), .dev_clrflag(64'd0),
        .dev_srq_en(64'd0), .dev_srq_val(64'd0),
        .flag_q(i_flag), .flagbuf_q(i_fb), .control_q(i_ctl),
        .halted(i_halted), .halt_ir(i_halt_ir), .retire(i_retire), .A(i_A), .B(i_B), .P(i_P), .E(i_E), .O(i_O),
        .defer(i_defer), .intsys(i_intsys), .cir(i_cir));

    wire [15:0] tbg_rd, ma_rd, mb_rd, ilk_in_rd, ilk_out_rd;
    wire        tbg_sel, ma_sel, mb_sel, ilk_in_sel, ilk_out_sel;
    wire        tbg_sf, ma_sf_lo, ma_sf_ctl, mb_sf_lo, mb_sf_ctl, ilk_in_sf, ilk_out_sf;

    hp_tbg #(.SC(6'o12), .STEP(STEP)) tbg (
        .clk(clk), .rst(rst), .sc_s(i_sc_s), .stc(i_stc), .clf(i_clf), .ot(i_ot), .dout(i_dout), .rd_sc(i_sc),
        .rd_data(tbg_rd), .rd_sel(tbg_sel), .flag(i_flag[6'o12]), .control(i_ctl[6'o12]), .setflag(tbg_sf));

    hp_mux #(.SC(6'o13), .SC_CTL(6'o15), .STEP(STEP)) muxa (
        .clk(clk), .rst(rst), .sc_s(i_sc_s), .stc(i_stc), .clf(i_clf), .ot(i_ot), .rd(i_rd), .crs(i_crs), .dout(i_dout),
        .rd_sc(i_sc), .rd_data(ma_rd), .rd_sel(ma_sel),
        .setflag_lo(ma_sf_lo), .setflag_ctl(ma_sf_ctl), .flag_lo(i_flag[6'o13]), .flag_ctl(i_flag[6'o15]),
        .line_conn(a_conn), .rx_avail(a_rx_avail), .rx_data(a_rx_data), .rx_take(a_rx_take),
        .tx_valid(a_tx_valid), .tx_data(a_tx_data));

    hp_mux #(.SC(6'o16), .SC_CTL(6'o20), .STEP(STEP)) muxb (
        .clk(clk), .rst(rst), .sc_s(i_sc_s), .stc(i_stc), .clf(i_clf), .ot(i_ot), .rd(i_rd), .crs(i_crs), .dout(i_dout),
        .rd_sc(i_sc), .rd_data(mb_rd), .rd_sel(mb_sel),
        .setflag_lo(mb_sf_lo), .setflag_ctl(mb_sf_ctl), .flag_lo(i_flag[6'o16]), .flag_ctl(i_flag[6'o20]),
        .line_conn(b_conn), .rx_avail(b_rx_avail), .rx_data(b_rx_data), .rx_take(b_rx_take),
        .tx_valid(b_tx_valid), .tx_data(b_tx_data));

    hp_link #(.SC(6'o10)) i_link_in (       // IOP receives from main
        .clk(clk), .rst(rst), .sc_s(i_sc_s), .stc(i_stc), .ot(i_ot), .dout(i_dout), .rd_sc(i_sc),
        .rd_data(ilk_in_rd), .rd_sel(ilk_in_sel), .setflag(ilk_in_sf),
        .tx_stb(m2i_ack), .tx_data(m2i_ackd), .rx_stb(m2i_stb), .rx_data(m2i_data));
    hp_link #(.SC(6'o11)) i_link_out (      // IOP sends to main
        .clk(clk), .rst(rst), .sc_s(i_sc_s), .stc(i_stc), .ot(i_ot), .dout(i_dout), .rd_sc(i_sc),
        .rd_data(ilk_out_rd), .rd_sel(ilk_out_sel), .setflag(ilk_out_sf),
        .tx_stb(i2m_stb), .tx_data(i2m_data), .rx_stb(i2m_ack), .rx_data(i2m_ackd));

    assign i_din = (tbg_sel ? tbg_rd : 16'd0) | (ma_sel ? ma_rd : 16'd0) | (mb_sel ? mb_rd : 16'd0) |
                   (ilk_in_sel ? ilk_in_rd : 16'd0) | (ilk_out_sel ? ilk_out_rd : 16'd0);
    assign i_setflag = ({63'd0, tbg_sf} << 6'o12) | ({63'd0, ma_sf_lo} << 6'o13) | ({63'd0, ma_sf_ctl} << 6'o15) |
                       ({63'd0, mb_sf_lo} << 6'o16) | ({63'd0, mb_sf_ctl} << 6'o20) |
                       ({63'd0, ilk_in_sf} << 6'o10) | ({63'd0, ilk_out_sf} << 6'o11);
endmodule
