// CPU + I/O backplane.  Devices attach to the dev_* bus.
module hp_core (
    input             clk,
    input             rst,
    output            mem_req,
    output            mem_we,
    output     [14:0] mem_addr,
    output     [15:0] mem_wdata,
    input             mem_gnt,
    input      [15:0] mem_rdata,
    input      [15:0] sw,
    input             run_req,
    input      [14:0] set_p,
    input             set_p_en,
    input             stall,
    input             ld_en,
    input      [15:0] ld_a,
    input      [15:0] ld_b,
    input             ld_e,
    input             ld_o,
    // device bus
    output     [5:0]  dev_sc,
    output     [5:0]  dev_sc_s,
    output            dev_stc,
    output            dev_clc,
    output            dev_stf,
    output            dev_clf,
    output            dev_ot,
    output            dev_crs,
    output     [15:0] dev_dout,
    input      [15:0] dev_din,
    output            dev_edt,
    output            dev_h,
    output            dev_dma,
    output            dev_rd,
    input             dev_noclf,
    input      [63:0] dev_setflag,
    input      [63:0] dev_clrflag,
    input      [63:0] dev_srq_en,     // device overrides default service request (flag & control)
    input      [63:0] dev_srq_val,
    output     [63:0] flag_q,
    output     [63:0] flagbuf_q,
    output     [63:0] control_q,
    // status
    output            halted,
    output     [15:0] halt_ir,
    output            retire,
    output     [15:0] A,
    output     [15:0] B,
    output     [14:0] P,
    output            E,
    output            O,
    output            defer,
    output            intsys,
    output     [5:0]  cir
);
    wire io_start, io_h, io_r, io_done, io_skip, irq_valid, irq_ack, crs, cpu_idle, dma_stall;
    wire [5:0] io_sc, irq_sc;
    wire [2:0] io_op;
    wire [15:0] io_dout, io_din;
    // CPU memory port and DMA memory port
    wire c_req, c_we, d_req, d_we, d_own;
    wire [14:0] c_addr, d_addr;
    wire [15:0] c_wdata, d_wdata;
    // DMA master port
    wire dm_start, dm_in, dm_stc, dm_clc, dm_last, dm_done;
    wire [5:0] dm_sc;
    wire [15:0] dm_dout, dm_din;
    wire [63:0] f_q, fb_q, c_q, dma_setflag, srq;
    wire [15:0] dma_rd; wire dma_rd_sel;
    wire        bus_stc, bus_clc, bus_stf, bus_ot;
    wire [5:0]  bus_sc, bus_sc_s;
    wire [15:0] bus_dout, bus_din_in;
    wire        bus_h;

    assign mem_req   = d_own ? d_req : c_req;
    assign mem_we    = d_own ? d_we  : c_we;
    assign mem_addr  = d_own ? d_addr : c_addr;
    assign mem_wdata = d_own ? d_wdata : c_wdata;
    assign flag_q = f_q; assign flagbuf_q = fb_q; assign control_q = c_q;
    assign srq = (dev_srq_en & dev_srq_val) | (~dev_srq_en & f_q & c_q);
    assign dev_sc = bus_sc; assign dev_sc_s = bus_sc_s; assign dev_stc = bus_stc; assign dev_clc = bus_clc; assign dev_stf = bus_stf;
    assign dev_ot = bus_ot; assign dev_dout = bus_dout; assign dev_h = bus_h;

    hp2100_cpu cpu (
        .clk(clk), .rst(rst),
        .mem_req(c_req), .mem_we(c_we), .mem_addr(c_addr), .mem_wdata(c_wdata),
        .mem_gnt(mem_gnt & ~d_own), .mem_rdata(mem_rdata),
        .io_start(io_start), .io_sc(io_sc), .io_op(io_op), .io_h(io_h), .io_r(io_r), .io_dout(io_dout),
        .io_done(io_done), .io_din(io_din), .io_skip(io_skip),
        .irq_valid(irq_valid), .irq_sc(irq_sc), .irq_ack(irq_ack), .crs(crs), .intsys(intsys), .cir(cir),
        .sw(sw), .run_req(run_req), .set_p(set_p), .set_p_en(set_p_en), .stall(stall | dma_stall),
        .ld_en(ld_en), .ld_a(ld_a), .ld_b(ld_b), .ld_e(ld_e), .ld_o(ld_o),
        .idle(cpu_idle),
        .halted(halted), .halt_ir(halt_ir), .retire(retire), .A(A), .B(B), .P(P), .E(E), .O(O), .defer(defer));

    hp_iobus bus (
        .clk(clk), .rst(rst),
        .io_start(io_start), .io_sc(io_sc), .io_op(io_op), .io_h(io_h), .io_r(io_r), .io_dout(io_dout),
        .io_done(io_done), .io_din(io_din), .io_skip(io_skip),
        .intsys(intsys), .crs(crs), .irq_ack(irq_ack), .ack_sc(cir),
        .irq_valid(irq_valid), .irq_sc(irq_sc),
        .dma_start(dm_start), .dma_sc(dm_sc), .dma_in(dm_in), .dma_stc_en(dm_stc), .dma_clc_en(dm_clc),
        .dma_last(dm_last), .dma_dout(dm_dout), .dma_din(dm_din), .dma_done(dm_done),
        .dev_sc(bus_sc), .dev_sc_s(bus_sc_s), .dev_stc(bus_stc), .dev_clc(bus_clc), .dev_stf(bus_stf), .dev_clf(dev_clf),
        .dev_ot(bus_ot), .dev_crs(dev_crs), .dev_edt(dev_edt), .dev_h(bus_h), .dev_dma(dev_dma), .dev_rd(dev_rd), .dev_dout(bus_dout),
        .dev_din(dma_rd_sel ? dma_rd : dev_din), .dev_noclf(dev_noclf),
        .dev_setflag(dev_setflag | dma_setflag), .dev_clrflag(dev_clrflag), .flag_q(f_q), .flagbuf_q(fb_q), .control_q(c_q));

    hp_dma dma (
        .clk(clk), .rst(rst),
        .dev_sc(bus_sc_s), .rd_sc(bus_sc), .dev_ot(bus_ot), .dev_stc(bus_stc), .dev_clc(bus_clc), .dev_stf(bus_stf), .dev_h(bus_h),
        .dev_dout(bus_dout), .rd_data(dma_rd), .rd_sel(dma_rd_sel),
        .flagbuf_q(fb_q), .srq(srq), .setflag(dma_setflag),
        .cpu_idle(cpu_idle), .stall(dma_stall),
        .io_start(dm_start), .io_sc(dm_sc), .io_in(dm_in), .io_stc_en(dm_stc), .io_clc_en(dm_clc),
        .io_last(dm_last), .io_dout(dm_dout), .io_done(dm_done), .io_din(dm_din),
        .mem_req(d_req), .mem_we(d_we), .mem_addr(d_addr), .mem_wdata(d_wdata),
        .mem_gnt(mem_gnt & d_own), .mem_rdata(mem_rdata), .mem_own(d_own));
endmodule
