// HP 2000F system with BRAM memories and a simple host interface, ready to be wrapped (LiteX) or driven by a testbench.
//   - main and IOP memories: 32K x 16 BRAM, CPU on port A, host window on port B
//   - console: TX byte FIFO toward the host, one RX byte register from the host
//   - 32 multiplexer lines: per-line TX holding registers drained to one output, per-line RX byte registers
//   - disc/tape images live in DRAM, reached through the dram_* port (word address, 16-bit data)
module hp2000_top #(parameter STEP = 12, parameter [17:0] TAPE_LEN = 18'd60108, parameter TAPE_HEX = "build/tape.hex") (
    input             clk,
    input             rst,
    // ---- host control
    input             m_run,                 // pulses
    input             i_run,
    input             m_setp_en, input [14:0] m_setp,
    input             i_setp_en, input [14:0] i_setp,
    output            m_halted, output [15:0] m_halt_ir, output [14:0] m_P, output [15:0] m_A, output [15:0] m_B,
    output            i_halted, output [15:0] i_halt_ir, output [14:0] i_P,
    // ---- host memory window (core 0 = main, 1 = IOP).  Read data valid the cycle after h_re.
    input             h_core,
    input      [14:0] h_addr,
    input             h_we,
    input             h_re,
    input      [15:0] h_wdata,
    output reg [15:0] h_rdata,
    // ---- console
    output            con_tx_valid,          // a byte is waiting
    output     [6:0]  con_tx_byte,
    input             con_tx_pop,
    input             con_rx_wr,
    input      [7:0]  con_rx_byte,
    output            con_rx_full,
    // ---- multiplexer lines
    input      [31:0] line_conn,
    output reg        line_tx_valid,
    output reg [4:0]  line_tx_line,
    output reg [6:0]  line_tx_byte,
    input             line_tx_pop,
    input             line_rx_wr,
    input      [4:0]  line_rx_line,
    input      [7:0]  line_rx_byte,
    output     [31:0] line_rx_full,
    // ---- devices' host-visible state
    input      [1:0]  dsk_unit_present,
    input             mt_mounted,
    input             mt_writable,
    output            mt_dirty,
    // ---- DRAM (disc image at word 0, tape image at word 2^25)
    output            dram_req, output dram_we, output [25:0] dram_addr, output [15:0] dram_wdata,
    input             dram_rdy, input dram_rvalid, input [15:0] dram_rdata
);
    // ------------------------------------------------------------------ core memories
    reg [15:0] mmem [0:32767];
    reg [15:0] imem [0:32767];
    reg [15:0] m_rd, i_rd, h_m_rd, h_i_rd;
    wire        m_req, m_we, i_req, i_we;
    wire [14:0] m_addr, i_addr;
    wire [15:0] m_wd, i_wd;
    // Simple dual-port block RAMs: each port is `if (we) mem[a] <= d; q <= mem[a];` (read-first), the form
    // Vivado and yosys both infer as RAMB36 without help.
    always @(posedge clk) begin
        if (m_req && m_we) mmem[m_addr] <= m_wd;
        m_rd <= mmem[m_addr];
    end
    always @(posedge clk) begin
        if (h_core == 1'b0 && h_we) mmem[h_addr] <= h_wdata;
        h_m_rd <= mmem[h_addr];
    end
    always @(posedge clk) begin
        if (i_req && i_we) imem[i_addr] <= i_wd;
        i_rd <= imem[i_addr];
    end
    always @(posedge clk) begin
        if (h_core == 1'b1 && h_we) imem[h_addr] <= h_wdata;
        h_i_rd <= imem[h_addr];
    end
    reg h_core_q;
    always @(posedge clk) h_core_q <= h_core;
    always @* h_rdata = h_core_q ? h_i_rd : h_m_rd;

    // ------------------------------------------------------------------ console and lines
    wire        ct_valid; wire [6:0] ct_data; wire ct_take;
    wire [7:0]  crx_data; wire crx_avail;
    reg  [6:0]  cfifo [0:63];
    reg  [5:0]  cwp, crp;
    reg  [6:0]  cnt;
    assign con_tx_valid = (cnt != 0);
    assign con_tx_byte  = cfifo[crp];
    reg         crx_full; reg [7:0] crx_q;
    assign con_rx_full = crx_full;
    assign crx_avail = crx_full; assign crx_data = crx_q;

    wire        con_rx_take_w;
    always @(posedge clk) begin
        if (rst) begin cwp <= 0; crp <= 0; cnt <= 0; crx_full <= 0; end
        else begin
            if (ct_valid && cnt != 7'd64) begin cfifo[cwp] <= ct_data; cwp <= cwp + 6'd1; end
            if (con_tx_pop && cnt != 0) crp <= crp + 6'd1;
            cnt <= cnt + ((ct_valid && cnt != 7'd64) ? 7'd1 : 7'd0) - ((con_tx_pop && cnt != 0) ? 7'd1 : 7'd0);
            if (con_rx_wr && !crx_full) begin crx_full <= 1'b1; crx_q <= con_rx_byte; end
            if (con_rx_take_w) crx_full <= 1'b0;
        end
    end

    // line receive registers
    reg [31:0] lrx_full;
    reg [7:0]  lrx [0:31];
    wire [15:0] a_take, b_take;
    wire [127:0] a_data, b_data;
    wire [15:0] a_avail = lrx_full[15:0], b_avail = lrx_full[31:16];
    genvar g;
    generate for (g = 0; g < 16; g = g + 1) begin : lines
        assign a_data[g*8 +: 8] = lrx[g];
        assign b_data[g*8 +: 8] = lrx[16+g];
    end endgenerate
    assign line_rx_full = lrx_full;
    integer li;
    always @(posedge clk) begin
        if (rst) lrx_full <= 32'd0;
        else begin
            for (li = 0; li < 16; li = li + 1) begin
                if (a_take[li]) lrx_full[li] <= 1'b0;
                if (b_take[li]) lrx_full[16+li] <= 1'b0;
            end
            if (line_rx_wr && !lrx_full[line_rx_line]) begin
                lrx_full[line_rx_line] <= 1'b1; lrx[line_rx_line] <= line_rx_byte;
            end
        end
    end

    // line transmit: pending byte per line, drained one at a time to the host
    wire [15:0] a_txv, b_txv;
    wire [111:0] a_txd, b_txd;
    reg  [31:0] ltx_pend;
    reg  [6:0]  ltx [0:31];
    reg  [4:0]  scan;
    integer lj;
    always @(posedge clk) begin
        if (rst) begin ltx_pend <= 32'd0; line_tx_valid <= 1'b0; scan <= 5'd0; end
        else begin
            for (lj = 0; lj < 16; lj = lj + 1) begin
                if (a_txv[lj]) begin ltx_pend[lj] <= 1'b1; ltx[lj] <= a_txd[lj*7 +: 7]; end
                if (b_txv[lj]) begin ltx_pend[16+lj] <= 1'b1; ltx[16+lj] <= b_txd[lj*7 +: 7]; end
            end
            if (line_tx_valid) begin
                if (line_tx_pop) line_tx_valid <= 1'b0;
            end else begin
                scan <= scan + 5'd1;
                if (ltx_pend[scan]) begin
                    line_tx_valid <= 1'b1; line_tx_line <= scan; line_tx_byte <= ltx[scan];
                    ltx_pend[scan] <= 1'b0;
                end
            end
        end
    end

    // ------------------------------------------------------------------ the machine
    hp2000_sys #(.STEP(STEP), .TAPE_LEN(TAPE_LEN), .TAPE_HEX(TAPE_HEX)) sys (
        .clk(clk), .rst(rst),
        .m_mem_req(m_req), .m_mem_we(m_we), .m_mem_addr(m_addr), .m_mem_wdata(m_wd), .m_mem_gnt(1'b1), .m_mem_rdata(m_rd),
        .i_mem_req(i_req), .i_mem_we(i_we), .i_mem_addr(i_addr), .i_mem_wdata(i_wd), .i_mem_gnt(1'b1), .i_mem_rdata(i_rd),
        .m_run_req(m_run), .m_set_p(m_setp), .m_set_p_en(m_setp_en),
        .i_run_req(i_run), .i_set_p(i_setp), .i_set_p_en(i_setp_en),
        .con_tx_valid(ct_valid), .con_tx_data(ct_data), .con_rx_avail(crx_avail), .con_rx_data(crx_data),
        .con_rx_take(con_rx_take_w),
        .dsk_unit_present(dsk_unit_present),
        .dram_req(dram_req), .dram_we(dram_we), .dram_addr(dram_addr), .dram_wdata(dram_wdata),
        .dram_rdy(dram_rdy), .dram_rvalid(dram_rvalid), .dram_rdata(dram_rdata),
        .mt_mounted(mt_mounted), .mt_writable(mt_writable), .mt_dirty(mt_dirty),
        .a_conn(line_conn[15:0]), .a_rx_avail(a_avail), .a_rx_data(a_data), .a_rx_take(a_take),
        .a_tx_valid(a_txv), .a_tx_data(a_txd),
        .b_conn(line_conn[31:16]), .b_rx_avail(b_avail), .b_rx_data(b_data), .b_rx_take(b_take),
        .b_tx_valid(b_txv), .b_tx_data(b_txd),
        .m_retire_o(), .m_halted(m_halted), .m_halt_ir(m_halt_ir), .m_P(m_P), .m_A(m_A), .m_B(m_B),
        .i_halted(i_halted), .i_halt_ir(i_halt_ir), .i_P(i_P));
endmodule
