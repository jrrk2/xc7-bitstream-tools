// ISS moving-head disc controller (HP 2883-class): data channel at SC, command channel at SC+1,
// up to two drives of 203 cylinders x 20 heads x 23 sectors x 128 words.  Port of emu/iss.c.
//
// The controller owns a 128-word sector buffer (inferred BRAM).  A backing-store engine (hp_disc_store,
// which talks to DRAM) loads a sector into it or writes it back; the controller issues the requests
// and waits for completion where the emulated timing does not already cover the latency.
module hp_iss #(parameter [5:0] SC = 6'o15, parameter STEP = 12) (
    input             clk,
    input             rst,
    // bus strobes (valid the cycle after the I/O operation)
    input      [5:0]  sc_s,
    input             stc,
    input             ot,
    input             edt,
    input             dma,
    input      [15:0] dout,
    // bus reads
    input      [5:0]  rd_sc,
    output reg [15:0] rd_data,
    output            rd_sel,
    // flag control toward the bus
    output reg        setflag_dc,
    output reg        setflag_cc,
    output reg        clrflag_cc,
    input             flag_dc,
    output            srq_dc,                // DMA service request follows the data channel flag
    input      [1:0]  unit_present,
    // backing-store engine
    output reg        bs_req,                // pulse: start a transfer
    output reg        bs_wr,                 // 1: buffer -> store, 0: store -> buffer
    output reg        bs_unit,
    output reg [16:0] bs_lba,
    input             bs_idle,
    input             bs_done,               // pulse when the transfer finished
    // sector buffer port B (used by the engine)
    input             bufb_we,
    input      [6:0]  bufb_waddr,
    input      [15:0] bufb_wdata,
    input      [6:0]  bufb_raddr,
    output reg [15:0] bufb_rdata
);
    localparam D_SHORT = 3, D_SEEK = 300, D_SECTOR = 40;
    localparam [2:0] ST_IDLE = 0, ST_WAIT_HS = 1, ST_SEEKING = 2, ST_READING = 3, ST_WRITING = 4;

    reg [7:0]  cyl   [0:1];
    reg [4:0]  head  [0:1];
    reg [4:0]  sec   [0:1];
    reg        seeking [0:1];
    reg [15:0] data_reg, cmd_reg, pending_param;
    reg [2:0]  state;
    reg        cur;
    reg [6:0]  idx;
    reg        write_cmd_seen, edt_seen, streaming;
    reg        flushing;
    reg [7:0]  fl_idx;
    reg        fl_complete;

    assign rd_sel  = (rd_sc == SC);
    assign srq_dc  = flag_dc;
    always @* rd_data = data_reg;

    wire [16:0] cur_lba = ({9'd0, cyl[cur]} * 17'd20 + {12'd0, head[cur]}) * 17'd23 + {12'd0, sec[cur]};

    // ---------------------------------------------------------------- sector buffer (two ports, synchronous)
    reg [15:0] sbuf [0:127];
    reg        bufa_we;
    reg [6:0]  bufa_waddr;
    reg [15:0] bufa_wdata;
    reg [6:0]  bufa_raddr;
    reg [15:0] bufa_rdata;
    // true dual-port BRAM template: one address per port (the write address wins while writing)
    wire [6:0] a_addr = bufa_we ? bufa_waddr : bufa_raddr;
    wire [6:0] b_addr = bufb_we ? bufb_waddr : bufb_raddr;
    always @(posedge clk) begin
        if (bufa_we) sbuf[a_addr] <= bufa_wdata;
        bufa_rdata <= sbuf[a_addr];
    end
    always @(posedge clk) begin
        if (bufb_we) sbuf[b_addr] <= bufb_wdata;
        bufb_rdata <= sbuf[b_addr];
    end

    // ---------------------------------------------------------------- backing-store request bookkeeping
    reg        st_pend, ld_pend;                // store / load waiting for the engine
    reg        st_unit_q, ld_unit_q;
    reg [16:0] st_lba_q, ld_lba_q;
    reg        eng_busy;                        // a request has been handed to the engine
    reg        eng_is_load;
    reg        ld_ready;                        // buffer holds the sector the last load asked for
    wire       store_busy = st_pend || (eng_busy && !eng_is_load);

    // ---------------------------------------------------------------- event timers
    reg        a_dc, a_cc, a_seek, a_read, a_next;
    reg [31:0] c_dc, c_cc, c_seek, c_read, c_next;
    // word fetch sequencer: waits for the buffer, reads a word, raises the data flag
    localparam [2:0] WF_IDLE = 0, WF_LD = 1, WF_ST = 2, WF_RD = 3, WF_CAP = 4;
    reg [2:0] wf;
    reg       wf_flag_only;

    task next_sector;
        input u;
        begin
            if (sec[u] + 5'd1 >= 5'd23) begin
                sec[u] <= 5'd0;
                if (head[u] + 5'd1 >= 5'd20) begin head[u] <= 5'd0; cyl[u] <= cyl[u] + 8'd1; end
                else head[u] <= head[u] + 5'd1;
            end else sec[u] <= sec[u] + 5'd1;
        end
    endtask

    wire sel_d = (sc_s == SC);
    wire sel_c = (sc_s == SC + 6'd1);
    wire [3:0] cmd = cmd_reg[15:12];
    wire       cmd_unit = (cmd_reg[1:0] > 2'd1) ? 1'b1 : cmd_reg[0];
    wire [8:0] dist_abs = (pending_param[8:0] > {1'b0, cyl[cur]}) ? (pending_param[8:0] - {1'b0, cyl[cur]})
                                                                  : ({1'b0, cyl[cur]} - pending_param[8:0]);
    wire [6:0] wi = streaming ? idx : 7'd0;

    integer k;
    reg edt_d;                                   // end-of-transfer is handled a cycle after the last word
    always @(posedge clk) begin
        edt_d <= edt && sel_d;
        setflag_dc <= 1'b0; setflag_cc <= 1'b0; clrflag_cc <= 1'b0; bufa_we <= 1'b0;
        bs_req <= 1'b0;
        if (rst) begin
            st_pend <= 0; ld_pend <= 0; eng_busy <= 0; ld_ready <= 1; eng_is_load <= 0;
            for (k = 0; k < 2; k = k + 1) begin cyl[k] <= 0; head[k] <= 0; sec[k] <= 0; seeking[k] <= 0; end
            data_reg <= 0; cmd_reg <= 0; pending_param <= 0; state <= ST_IDLE; cur <= 0; idx <= 0;
            write_cmd_seen <= 0; edt_seen <= 0; streaming <= 0; flushing <= 0; fl_idx <= 0; fl_complete <= 0;
            a_dc <= 0; a_cc <= 0; a_seek <= 0; a_read <= 0; a_next <= 0; wf <= WF_IDLE; wf_flag_only <= 0;
        end else begin
            // ---------------------------------------------------------- backing-store engine hand-off
            if (bs_done) begin eng_busy <= 0; if (eng_is_load) ld_ready <= 1'b1; end
            if (!eng_busy && bs_idle && !bs_req) begin
                if (st_pend) begin
`ifdef TRACE
                    $display("ISS STORE lba=%0d", st_lba_q);
`endif
                    bs_req <= 1; bs_wr <= 1; bs_unit <= st_unit_q; bs_lba <= st_lba_q;
                    eng_busy <= 1; eng_is_load <= 0; st_pend <= 0;
                end else if (ld_pend) begin
`ifdef TRACE
                    $display("ISS LOAD lba=%0d", ld_lba_q);
`endif
                    bs_req <= 1; bs_wr <= 0; bs_unit <= ld_unit_q; bs_lba <= ld_lba_q;
                    eng_busy <= 1; eng_is_load <= 1; ld_pend <= 0;
                end
            end
            // ---------------------------------------------------------- timers
            if (a_dc)   begin if (c_dc > 1)   c_dc <= c_dc - 1;     else begin a_dc <= 0; setflag_dc <= 1; end end
            if (a_cc)   begin if (c_cc > 1)   c_cc <= c_cc - 1;     else begin a_cc <= 0; setflag_cc <= 1; end end
            if (a_seek) begin if (c_seek > 1) c_seek <= c_seek - 1; else begin
                a_seek <= 0; seeking[cur] <= 0; state <= ST_IDLE; setflag_cc <= 1; end end
            if (a_read) begin if (c_read > 1) c_read <= c_read - 1; else begin
                a_read <= 0; ld_pend <= 1; ld_unit_q <= cur; ld_lba_q <= cur_lba; ld_ready <= 1'b0; wf <= WF_LD; end end                 // load sector, then word 0
            if (a_next) begin if (c_next > 1) c_next <= c_next - 1; else begin
                a_next <= 0;
                if (state == ST_READING) wf <= WF_LD;
                else if (state == ST_WRITING || streaming) wf <= WF_ST;
            end end
            // ---------------------------------------------------------- word fetch / write-ready sequencer
            case (wf)
              WF_LD: if (ld_ready && !ld_pend && !eng_busy) begin bufa_raddr <= idx; wf <= WF_RD; end
              WF_RD: wf <= WF_CAP;
              WF_CAP: begin data_reg <= bufa_rdata; setflag_dc <= 1'b1; wf <= WF_IDLE; end
              WF_ST: if (!store_busy) begin setflag_dc <= 1'b1; wf <= WF_IDLE; end
              default: ;
            endcase
            // ---------------------------------------------------------- partial-sector flush after end of data
            if (flushing) begin
                bufa_we <= 1'b1; bufa_waddr <= fl_idx[6:0]; bufa_wdata <= 16'd0;
                if (fl_idx == 8'd127) begin
                    flushing <= 0; st_pend <= 1; st_unit_q <= cur; st_lba_q <= cur_lba; next_sector(cur); idx <= 0;
                    if (fl_complete) begin
                        state <= ST_IDLE; write_cmd_seen <= 0; edt_seen <= 0; streaming <= 0;
                        a_cc <= 1; c_cc <= D_SHORT * STEP;
                    end
                end else fl_idx <= fl_idx + 8'd1;
            end
            // ---------------------------------------------------------- data channel strobes
            if (ot && sel_d) begin
`ifdef TRACE
                $display("ISS dc_out %06o in_dma=%0d state=%0d idx=%0d", dout, dma, state, idx);
`endif
                data_reg <= dout;
                if (dma && (state == ST_WRITING || state == ST_IDLE)) begin
                    // streaming write data goes into the sector buffer; a full sector is written back
                    streaming <= 1'b1;
                    bufa_we <= 1'b1; bufa_waddr <= wi; bufa_wdata <= dout;
                    idx <= wi + 7'd1;
                    if (wi == 7'd127) begin st_pend <= 1; st_unit_q <= cur; st_lba_q <= cur_lba; next_sector(cur); end
                end
            end
            if (stc && sel_d) begin
`ifdef TRACE
                if (dma && state == ST_READING) $display("ISS dmaword idx=%0d data=%06o", idx, data_reg);
`endif
                if (dma) begin
                    if (state == ST_READING) begin
                        if (idx == 7'd127) begin
                            next_sector(cur); idx <= 0;                              // next sector's load starts at once
                            ld_pend <= 1; ld_unit_q <= cur; ld_lba_q <= cur_lba + 17'd1; ld_ready <= 1'b0;
                            a_next <= 1; c_next <= D_SECTOR * STEP;
                        end else begin
                            idx <= idx + 7'd1;
                            a_next <= 1; c_next <= D_SHORT * STEP;
                        end
                    end else begin
                        a_next <= 1; c_next <= D_SHORT * STEP;
                    end
                end else if (state == ST_WAIT_HS) begin
                    head[cur] <= (data_reg[15:8] >= 8'd20 || data_reg[7:0] >= 8'd23) ? 5'd0 : data_reg[12:8];
                    sec[cur]  <= (data_reg[15:8] >= 8'd20 || data_reg[7:0] >= 8'd23) ? 5'd0 : data_reg[4:0];
                    a_dc <= 1; c_dc <= D_SHORT * STEP;
                    cyl[cur] <= (pending_param < 16'd203) ? pending_param[7:0] : 8'd202;
                    seeking[cur] <= 1; state <= ST_SEEKING;
                    a_seek <= 1; c_seek <= (D_SEEK + 20 * dist_abs) * STEP;
                end else begin
                    pending_param <= data_reg;
                end
            end
            if (edt_d) begin
                if (state == ST_READING) begin
                    state <= ST_IDLE; a_cc <= 1; c_cc <= D_SHORT * STEP;
                end else if (streaming) begin
                    edt_seen <= 1;
                    if (idx != 0) begin                        // partial sector: zero-pad, then store and complete
                        flushing <= 1; fl_idx <= {1'b0, idx}; fl_complete <= write_cmd_seen;
                    end else if (write_cmd_seen) begin
                        state <= ST_IDLE; write_cmd_seen <= 0; edt_seen <= 0; streaming <= 0;
                        a_cc <= 1; c_cc <= D_SHORT * STEP;
                    end
                end
            end
            // ---------------------------------------------------------- command channel strobes
            if (ot && sel_c) cmd_reg <= dout;
            if (stc && sel_c) begin
`ifdef TRACE
                $display("ISS cmd %0o unit %0d", cmd, cmd_unit);
`endif
                case (cmd)
                  4'd1: begin                                   // STATUS
                      data_reg <= !unit_present[cmd_unit] ? 16'o101 : (seeking[cmd_unit] ? 16'o4 : 16'o0);
                      clrflag_cc <= 1'b1;
                      a_dc <= 1; c_dc <= D_SHORT * STEP;
                  end
                  4'd2: begin                                   // RECALIBRATE
                      cur <= cmd_unit; cyl[cmd_unit] <= 0; seeking[cmd_unit] <= 1; state <= ST_SEEKING;
                      a_seek <= 1; c_seek <= D_SEEK * STEP;
                  end
                  4'd3: begin                                   // SEEK: cylinder already in pending_param
                      cur <= cmd_unit; state <= ST_WAIT_HS;
                      a_dc <= 1; c_dc <= D_SHORT * STEP;
                  end
                  4'd4: begin                                   // READ
                      cur <= cmd_unit; state <= ST_READING; idx <= 0; edt_seen <= 0;
                      a_read <= 1; c_read <= D_SECTOR * STEP;
                  end
                  4'd5: begin                                   // WRITE
                      cur <= cmd_unit; write_cmd_seen <= 1; state <= ST_WRITING;
                      if (edt_seen) begin
                          state <= ST_IDLE; write_cmd_seen <= 0; edt_seen <= 0; streaming <= 0;
                          a_cc <= 1; c_cc <= D_SHORT * STEP;
                      end
                  end
                  default: ;
                endcase
            end
        end
    end
endmodule
