// HP 12920A 16-channel asynchronous multiplexer: lower data card (SC), upper data card (SC+1) and
// modem control card (SC_CTL).  Port of emu/mux.c.  Host side: per-line byte streams.
module hp_mux #(parameter [5:0] SC = 6'o13, parameter [5:0] SC_CTL = 6'o15,
                parameter STEP = 12, parameter STEPS_PER_SEC = 500000, parameter POLL_STEPS = 500) (
    input             clk,
    input             rst,
    // bus strobes (valid the cycle after the operation)
    input      [5:0]  sc_s,
    input             stc,
    input             clf,
    input             ot,
    input             rd,                // LIA/MIA happened on sc_s
    input             crs,               // CLC 0
    input      [15:0] dout,
    // bus reads
    input      [5:0]  rd_sc,
    output reg [15:0] rd_data,
    output            rd_sel,
    // flags
    output reg        setflag_lo,
    output reg        setflag_ctl,
    input             flag_lo,
    input             flag_ctl,
    // host lines
    input      [15:0] line_conn,
    input      [15:0] rx_avail,
    input      [127:0] rx_data,          // 8 bits per line
    output reg [15:0] rx_take,
    output reg [15:0] tx_valid,
    output reg [111:0] tx_data           // 7 bits per line
);
    localparam [15:0] OTL_P = 16'o100000, OTL_TX = 16'o040000, OTL_ENB = 16'o020000, OTL_TPAR = 16'o010000,
                      OTL_ECHO = 16'o010000, OTL_SYNC = 16'o004000;

    reg [15:0] rpar [0:15];
    reg [15:0] xpar [0:15];
    reg [15:0] rbuf [0:15];
    reg [15:0] xbuf [0:15];
    reg [2:0]  sta  [0:15];
    reg        rchp [0:15];
    reg        xdon [0:15];
    reg        xbusy[0:15];
    reg        a_x  [0:15];
    reg [31:0] c_x  [0:15];
    reg [5:0]  cota [0:15];
    reg [1:0]  clia [0:15];
    reg [47:0] next_rx [0:15];
    reg [47:0] now;
    reg [15:0] lo_ibuf, lo_obuf, up_ibuf, up_obuf;
    reg [3:0]  ctl_chan;
    reg        ctl_scan;
    reg [31:0] pollc;
    reg [4:0]  scan_i;
    reg        scanning;
    reg        do_data_int, do_ctrl_int;

    assign rd_sel = (rd_sc == SC) || (rd_sc == SC + 6'd1) || (rd_sc == SC_CTL);

    function odd_par;
        input [15:0] c;
        reg [7:0] b;
        begin b = c[7:0]; odd_par = ^b; end
    endfunction

    // Character time in clock cycles: bits * (divisor+1) * K, K = STEPS_PER_SEC*STEP/14400 (the 12920A bit clock is
    // 14400/(divisor+1) baud).  A multiply by a constant instead of the divide the C model uses; within 0.5% of it.
    localparam integer KTIME = (STEPS_PER_SEC * STEP + 7200) / 14400;
    function [31:0] char_time;
        input [15:0] par;
        reg [31:0] bits;
        begin
            case (par[10:8])
              3'd0: bits = 9;  3'd1: bits = 10; 3'd2: bits = 11; 3'd3: bits = 12;
              3'd4: bits = 5;  3'd5: bits = 6;  3'd6: bits = 7;  default: bits = 8;
            endcase
            char_time = bits * ({24'd0, par[7:0]} + 32'd1) * KTIME;
        end
    endfunction

    // ---------------------------------------------------------------- interrupt scans (combinational)
    reg        di_found;  reg [3:0] di_line;  reg di_xmt;
    integer i;
    always @* begin
        di_found = 1'b0; di_line = 4'd0; di_xmt = 1'b0;
        for (i = 0; i < 16; i = i + 1)
            if (!di_found && (rpar[i] & OTL_ENB) != 16'd0 && rchp[i]) begin di_found = 1'b1; di_line = i[3:0]; di_xmt = 1'b0; end
        for (i = 0; i < 16; i = i + 1)
            if (!di_found && (xpar[i] & OTL_ENB) != 16'd0 && xdon[i]) begin di_found = 1'b1; di_line = i[3:0]; di_xmt = 1'b1; end
    end

    function [1:0] tsti;
        input [5:0] co;
        input [1:0] li;
        begin tsti = (li ^ co[1:0]) & co[3:2]; end
    endfunction

    reg        ci_found;  reg [3:0] ci_chan;
    reg [4:0]  kk;
    reg [3:0]  chk;
    always @* begin
        ci_found = 1'b0; ci_chan = ctl_chan; chk = ctl_chan;
        if (ctl_scan) begin
            for (kk = 1; kk <= 16; kk = kk + 1) begin
                chk = ctl_chan + kk[3:0];
                if (!ci_found && tsti(cota[chk], clia[chk]) != 2'b00) begin ci_found = 1'b1; ci_chan = chk; end
            end
        end else begin
            if (tsti(cota[ctl_chan], clia[ctl_chan]) != 2'b00) ci_found = 1'b1;
        end
    end

    // ---------------------------------------------------------------- reads
    wire [1:0] ti_cur = tsti(cota[ctl_chan], clia[ctl_chan]);
    always @* begin
        rd_data = 16'd0;
        if (rd_sc == SC)             rd_data = lo_ibuf;
        else if (rd_sc == SC + 6'd1) rd_data = up_ibuf;
        else if (rd_sc == SC_CTL)    rd_data = 16'o140000 | ({12'd0, ctl_chan} << 10) | ({14'd0, ti_cur} << 8)
                                              | {12'd0, cota[ctl_chan][3:2], 2'b00} | {14'd0, clia[ctl_chan]};
    end

    // host output helper (flattened per-line byte)
    reg [6:0] put_c;
    task host_put;
        input [3:0] ln;
        input [7:0] ch;
        begin
            put_c = ch[6:0];
            if (put_c != 7'd0 && put_c != 7'h7F) begin
                if (put_c >= 7'o140) put_c = put_c - 7'o40;
                tx_valid[ln] <= 1'b1;
                tx_data[ln*7 +: 7] <= put_c;
            end
        end
    endtask

    reg [3:0] ln_w;
    reg [15:0] v_w;
    reg [7:0] rc; reg brk;
    integer j;
    always @(posedge clk) begin
        setflag_lo <= 1'b0; setflag_ctl <= 1'b0; rx_take <= 16'd0; tx_valid <= 16'd0;
        do_data_int <= 1'b0; do_ctrl_int <= 1'b0;
        now <= now + 48'd1;
        if (rst) begin
            now <= 0; pollc <= 0; scanning <= 0; scan_i <= 0; ctl_chan <= 0; ctl_scan <= 0;
            lo_ibuf <= 0; lo_obuf <= 0; up_ibuf <= 0; up_obuf <= 0;
            for (j = 0; j < 16; j = j + 1) begin
                rpar[j] <= 0; xpar[j] <= 0; rbuf[j] <= 0; xbuf[j] <= 0; sta[j] <= 0; rchp[j] <= 0; xdon[j] <= 0;
                xbusy[j] <= 0; a_x[j] <= 0; c_x[j] <= 0; cota[j] <= 0; clia[j] <= 0; next_rx[j] <= 0;
            end
        end else begin
            // ---------------------------------------------------------- transmit completion timers
            for (j = 0; j < 16; j = j + 1) begin
                if (a_x[j]) begin
                    if (c_x[j] > 1) c_x[j] <= c_x[j] - 1;
                    else begin
                        a_x[j] <= 0; xbusy[j] <= 0;
                        if (line_conn[j] && (xbuf[j] & OTL_SYNC) == 16'd0) host_put(j[3:0], xbuf[j][7:0]);
                        xdon[j] <= 1'b1;
                        if (!flag_lo) do_data_int <= 1'b1;
                    end
                end
            end
            // ---------------------------------------------------------- host polling
            if (pollc + 1 >= POLL_STEPS * STEP) begin pollc <= 0; scanning <= 1; scan_i <= 0; end
            else pollc <= pollc + 1;
            if (scanning) begin
                j = scan_i;
                clia[scan_i[3:0]] <= line_conn[scan_i[3:0]] ? 2'b01 : 2'b00;
                if (line_conn[scan_i[3:0]] && now >= next_rx[scan_i[3:0]] && rx_avail[scan_i[3:0]]) begin
                    rc = rx_data[scan_i[3:0]*8 +: 8];
                    rx_take[scan_i[3:0]] <= 1'b1;
                    if (rchp[scan_i[3:0]]) sta[scan_i[3:0]] <= sta[scan_i[3:0]] | 3'd2;
                    brk = rc[7];                                    // bit 7 of the host byte = line BREAK: NUL + break status
                    rc = rc & 8'h7F; if (rc >= 8'o140) rc = rc - 8'o40;
                    if (brk) begin rc = 8'd0; sta[scan_i[3:0]] <= sta[scan_i[3:0]] | (rchp[scan_i[3:0]] ? 3'd6 : 3'd4); end
                    else if ((rpar[scan_i[3:0]] & OTL_ECHO) != 16'd0) host_put(scan_i[3:0], rc);
                    rbuf[scan_i[3:0]] <= {8'd0, rc};
                    rchp[scan_i[3:0]] <= 1'b1;
                    next_rx[scan_i[3:0]] <= now + char_time(rpar[scan_i[3:0]]);
                end
                if (scan_i == 5'd15) begin
                    scanning <= 0;
                    if (!flag_lo) do_data_int <= 1'b1;
                    if (!flag_ctl) do_ctrl_int <= 1'b1;
                end else scan_i <= scan_i + 5'd1;
            end
            // ---------------------------------------------------------- bus strobes: lower data card
            if (ot && sc_s == SC) lo_obuf <= dout;
            if (ot && sc_s == SC + 6'd1) up_obuf <= dout;
            if (stc && sc_s == SC) begin
                ln_w = up_obuf[13:10]; v_w = lo_obuf;
                if (v_w & OTL_TX) begin
                    if (v_w & OTL_P) xpar[ln_w] <= v_w;
                    else begin
                        if (xpar[ln_w] & OTL_TPAR) v_w = (v_w & ~16'o200) | (odd_par(v_w) ? 16'd0 : 16'o200);
                        xbuf[ln_w] <= v_w;
                        if (xbusy[ln_w]) sta[ln_w] <= sta[ln_w] | 3'd2;
                        else begin xbusy[ln_w] <= 1'b1; a_x[ln_w] <= 1'b1; c_x[ln_w] <= char_time(16'd0); end
                    end
                end else if (v_w & OTL_P) rpar[ln_w] <= v_w;
            end
            if (clf && sc_s == SC) do_data_int <= 1'b1;
            if (crs) begin
                for (j = 0; j < 16; j = j + 1) begin
                    xbuf[j] <= 0; xpar[j] <= 0; rbuf[j] <= 0; rpar[j] <= 0; sta[j] <= 0; rchp[j] <= 0; xdon[j] <= 0;
                    cota[j] <= 0; clia[j] <= line_conn[j] ? 2'b01 : 2'b00; a_x[j] <= 0; xbusy[j] <= 0;
                end
            end
            // ---------------------------------------------------------- control card
            if (ot && sc_s == SC_CTL) begin
                ctl_chan <= dout[13:10]; ctl_scan <= dout[15];
                if (dout[14]) begin
                    cota[dout[13:10]][3:0] <= dout[3:0];
                    if (dout[7]) cota[dout[13:10]][5] <= dout[5];
                    if (dout[6]) cota[dout[13:10]][4] <= dout[4];
                end
            end
            if (rd && sc_s == SC_CTL) ctl_chan <= ctl_chan + 4'd1;
            if (clf && sc_s == SC_CTL) do_ctrl_int <= 1'b1;
            // ---------------------------------------------------------- interrupt scans
            if (do_data_int && di_found) begin
                lo_ibuf <= ({1'b0, di_line, 10'd0} & 16'h7C00) | (rbuf[di_line] & 16'h03FF) | (odd_par(rbuf[di_line]) ? 16'd0 : 16'o100000);
                up_ibuf <= ({1'b0, di_line, 10'd0} & 16'h7C00) | {13'd0, sta[di_line]} | (di_xmt ? 16'd1 : 16'd0);
                if (di_xmt) xdon[di_line] <= 1'b0; else rchp[di_line] <= 1'b0;
                sta[di_line] <= 3'd0;
                setflag_lo <= 1'b1;
            end
            if (do_ctrl_int && ci_found) begin
                ctl_chan <= ci_chan;
                setflag_ctl <= 1'b1;
            end
        end
    end
endmodule
