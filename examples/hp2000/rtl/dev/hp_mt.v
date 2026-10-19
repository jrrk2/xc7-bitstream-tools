// HP 13181-style magnetic tape interface (7970 drive): data channel at SC, command channel at SC+1.
// Port of emu/mt.c.  The tape image lives in DRAM in the layout of tools/taphw.py; this controller walks it
// one word at a time through a simple access port (ta_*), so the tape can be a file fetched by the host
// (e.g. over TFTP) and written into DRAM, and written tapes can be read back out and stored the same way.
//
//   record: W0 = [15] tape mark, [14:0] byte length; W1 = words back to the previous header;
//           then ceil(len/2) data words.  End marker: W0 = 0xFFFF.
module hp_mt #(parameter [5:0] SC = 6'o21, parameter STEP = 12, parameter [25:0] TAPE_BASE = 26'h2000000) (
    input             clk,
    input             rst,
    // bus strobes (valid the cycle after the operation)
    input      [5:0]  sc_s,
    input             stc,
    input             ot,
    input             edt,
    input      [15:0] dout,
    // bus reads
    input      [5:0]  rd_sc,
    output reg [15:0] rd_data,
    output            rd_sel,
    // flags / control
    output reg        setflag_dc,
    output reg        clrflag_dc,
    output reg        setflag_cc,
    input             flag_dc,
    input             ctl_dc,
    output            srq_dc,
    // host: a tape image is present in DRAM / has a write ring; controller reports modification
    input             mounted,
    input             writable,
    output reg        dirty,
    // DRAM word access: pulse ta_req; ta_done pulses when finished (read data in ta_rdata)
    output reg        ta_req,
    output reg        ta_we,
    output reg [25:0] ta_addr,
    output reg [15:0] ta_wdata,
    input             ta_done,
    input      [15:0] ta_rdata
);
    localparam [8:0] FNC_CLR = 9'o110, FNC_GAP = 9'o015, FNC_GFM = 9'o215, FNC_RC = 9'o023, FNC_WC = 9'o031,
                     FNC_FSR = 9'o003, FNC_BSR = 9'o041, FNC_FSF = 9'o203, FNC_BSF = 9'o241, FNC_REW = 9'o101,
                     FNC_RWS = 9'o105, FNC_WFM = 9'o211, FNC_CMPL = 9'o400;
    localparam STA_ODD = 12'o4000, STA_REW = 12'o2000, STA_TBSY = 12'o1000, STA_BUSY = 12'o0400, STA_EOF = 12'o0200,
               STA_BOT = 12'o0100, STA_TIM = 12'o0020, STA_REJ = 12'o0010, STA_WLK = 12'o0004, STA_PAR = 12'o0002,
               STA_LOCAL = 12'o0001;
    localparam T_CMD = 1000, T_REW = 100, T_XFER = 10, T_IRG = 1;
    localparam [15:0] EOM = 16'hFFFF;

    reg [24:0] pos;                       // word offset of the next header
    reg [8:0]  fnc;
    reg        active, offline, ust_rew, first;
    reg [11:0] sta;
    reg [15:0] msc_buf, msd_buf;
    reg [15:0] max_bytes;
    reg [15:0] wptr;                      // words transferred so far in the current (read) record
    reg [24:0] rec_base;
    reg [15:0] wpd;                       // previous-header distance for a record being written
    reg [15:0] svc_timer; reg svc_pend;
    wire       online = mounted && !offline;
    wire       bot = (pos == 25'd0);

    assign rd_sel = (rd_sc == SC) || (rd_sc == SC + 6'd1);
    assign srq_dc = flag_dc;
    always @* begin
        rd_data = 16'd0;
        if (rd_sc == SC) rd_data = msd_buf;
        else if (rd_sc == SC + 6'd1) begin
            rd_data = {4'd0, sta & ~(STA_TBSY | STA_BOT | STA_WLK | STA_LOCAL)};
            if (online) begin
                if (ust_rew) rd_data[10] = 1'b1;
                if (bot) rd_data[6] = 1'b1;
                if (active && !((fnc & 9'o100) != 0 && bot)) rd_data[9] = 1'b1;
                if (!writable) rd_data[2] = 1'b1;
            end else begin rd_data[9] = 1'b1; rd_data[0] = 1'b1; end
        end
    end

    // ---------------------------------------------------------------- DRAM access sub-engine
    localparam [5:0]
        M_IDLE = 0, M_ACCW = 1, M_DECODE = 2, M_COMPLETE = 3,
        M_FSR1 = 4, M_BSR1 = 5, M_BSR2 = 6, M_FSF1 = 7, M_BSF1 = 8, M_BSF2 = 9,
        M_RC1 = 10, M_RCDATA = 11, M_RC2 = 12,
        M_WC1 = 13, M_WCST = 14, M_WCINC = 15, M_WCCTL = 16, M_WFM1 = 17,
        M_HW0 = 18, M_HW1 = 19, M_HE0 = 20, M_HE1 = 21, M_FIN = 22;
    reg [5:0]  mst, acc_ret;
    reg [15:0] acc_rd;
    reg [24:0] newpos;
    reg [15:0] hdrval;                    // header word to write
    reg [15:0] adv;                       // words the position advances after a write (header + data)
    reg [15:0] wcount;                    // data words stored in the record being written

    task acc_read;                       // start a read of word `a` of the tape image; continue in state r
        input [24:0] a; input [5:0] r;
        begin ta_req <= 1'b1; ta_we <= 1'b0; ta_addr <= TAPE_BASE + {1'b0, a}; acc_ret <= r; mst <= M_ACCW; end
    endtask
    task acc_write;
        input [24:0] a; input [15:0] d; input [5:0] r;
        begin ta_req <= 1'b1; ta_we <= 1'b1; ta_addr <= TAPE_BASE + {1'b0, a}; ta_wdata <= d; acc_ret <= r; mst <= M_ACCW; end
    endtask
    task arm;
        input [15:0] steps;
        begin svc_pend <= 1'b1; svc_timer <= steps * STEP; end
    endtask

    wire sel_d = (sc_s == SC);
    wire sel_c = (sc_s == SC + 6'd1);
    wire [8:0] cmd_fnc = {1'b0, msc_buf[7:0]};

    always @(posedge clk) begin
        setflag_dc <= 1'b0; clrflag_dc <= 1'b0; setflag_cc <= 1'b0; ta_req <= 1'b0;
        if (rst) begin
            pos <= 0; fnc <= 0; active <= 0; offline <= 0; ust_rew <= 0; first <= 0; sta <= 0; msc_buf <= 0; msd_buf <= 0;
            mst <= M_IDLE; svc_pend <= 0; dirty <= 0; wptr <= 0; max_bytes <= 0; wcount <= 0;
        end else begin
            // ---------------------------------------------------------- bus: data channel
            if (ot && sel_d) msd_buf <= dout;
            if (edt && sel_d) clrflag_dc <= 1'b1;
            // ---------------------------------------------------------- bus: command channel
            if (ot && sel_c) begin
                msc_buf <= dout;
                sta[3] <= 1'b0;                                   // clear reject
                if (dout[7:0] != FNC_CLR[7:0]) begin
                    if (sta & STA_BUSY) sta[3] <= 1'b1;
                    else if (((dout[0]) && active) || (dout[5] && bot) || (dout[3] && !writable)) sta[3] <= 1'b1;
                end
            end
            if (stc && sel_c && !sta[3]) begin
                if (msc_buf[7:0] == FNC_CLR[7:0]) begin           // clear: completes at once
                    active <= 0; sta <= 0; svc_pend <= 0; mst <= M_IDLE; wptr <= 0; max_bytes <= 0;
                    setflag_cc <= 1'b1;
                end else begin
                    fnc <= cmd_fnc;
                    if (msc_buf[6]) begin if (!bot) ust_rew <= 1'b1; end            // rewind
                    if ((msc_buf & ~16'o17400) != 16'd0) arm(msc_buf[6] ? T_REW : T_CMD);   // unit select alone is a NOP
                    active <= 1'b1; sta <= STA_BUSY; first <= 1'b1;
                end
            end
            // ---------------------------------------------------------- service timer
            if (svc_pend) begin
                if (svc_timer > 1) svc_timer <= svc_timer - 1;
                else if (mst == M_IDLE) begin svc_pend <= 0; mst <= M_DECODE; end
            end
            // ---------------------------------------------------------- state machine
            case (mst)
              M_IDLE: ;
              M_ACCW: if (ta_done) begin acc_rd <= ta_rdata; mst <= acc_ret; end
              M_DECODE: begin
                  case (fnc)
                    FNC_RWS: begin pos <= 0; offline <= 1; ust_rew <= 0; mst <= M_COMPLETE; end
                    FNC_REW: begin
                        if (ust_rew) begin fnc <= fnc | FNC_CMPL; arm(T_CMD); end
                        mst <= M_COMPLETE;
                    end
                    FNC_REW | FNC_CMPL: begin pos <= 0; ust_rew <= 0; active <= 0; mst <= M_IDLE; end
                    FNC_GAP, FNC_GFM, FNC_WC | FNC_CMPL, FNC_RC | FNC_CMPL: mst <= M_COMPLETE;
                    FNC_WFM: begin
                        if (!writable) begin sta <= STA_REJ; mst <= M_COMPLETE; end
                        else acc_read(pos + 25'd1, M_WFM1);
                    end
                    FNC_FSR, FNC_FSF: acc_read(pos, fnc == FNC_FSR ? M_FSR1 : M_FSF1);
                    FNC_BSR: begin if (bot) mst <= M_COMPLETE; else acc_read(pos + 25'd1, M_BSR1); end
                    FNC_BSF: begin if (bot) begin sta <= sta | STA_EOF | STA_ODD; mst <= M_COMPLETE; end
                                   else acc_read(pos + 25'd1, M_BSF1); end
                    FNC_RC: begin
                        if (first) begin first <= 0; wptr <= 0; max_bytes <= 0; acc_read(pos, M_RC1); end
                        else mst <= M_RCDATA;
                    end
                    FNC_WC: begin
                        if (first) begin first <= 0; wcount <= 0; acc_read(pos + 25'd1, M_WC1); end
                        else acc_write(pos + 25'd2 + {9'd0, wcount}, msd_buf, M_WCINC);        // store the word the DMA delivered
                    end
                    default: mst <= M_COMPLETE;
                  endcase
              end
              // ---- forward space record / file
              M_FSR1: begin
                  if (acc_rd == EOM) sta <= sta | STA_EOF | STA_ODD;
                  else if (acc_rd[15]) begin pos <= pos + 25'd2; sta <= sta | STA_EOF | STA_ODD; end
                  else begin pos <= pos + 25'd2 + ({10'd0, acc_rd[14:0] + 15'd1} >> 1);
                       sta <= (sta & ~STA_ODD) | (acc_rd[0] ? STA_ODD : 12'd0); end
                  mst <= M_COMPLETE;
              end
              M_FSF1: begin
                  if (acc_rd == EOM) begin sta <= sta | STA_EOF | STA_ODD; mst <= M_COMPLETE; end
                  else begin
                      if (acc_rd[15]) begin pos <= pos + 25'd2; sta <= sta | STA_EOF | STA_ODD; mst <= M_COMPLETE; end
                      else begin pos <= pos + 25'd2 + ({10'd0, acc_rd[14:0] + 15'd1} >> 1);
                                 acc_read(pos + 25'd2 + ({10'd0, acc_rd[14:0] + 15'd1} >> 1), M_FSF1); end
                  end
              end
              // ---- backward space record
              M_BSR1: begin newpos <= pos - {9'd0, acc_rd}; acc_read(pos - {9'd0, acc_rd}, M_BSR2); end
              M_BSR2: begin
                  pos <= newpos;
                  if (acc_rd[15]) sta <= sta | STA_EOF | STA_ODD;
                  else sta <= (sta & ~STA_ODD) | (acc_rd[0] ? STA_ODD : 12'd0);
                  mst <= M_COMPLETE;
              end
              // ---- backward space file
              M_BSF1: begin newpos <= pos - {9'd0, acc_rd}; acc_read(pos - {9'd0, acc_rd}, M_BSF2); end
              M_BSF2: begin
                  pos <= newpos;
                  if (acc_rd[15] || newpos == 25'd0) begin sta <= sta | STA_EOF | STA_ODD; mst <= M_COMPLETE; end
                  else acc_read(newpos + 25'd1, M_BSF1);
              end
              // ---- read record
              M_RC1: begin
                  if (acc_rd == EOM) begin sta <= sta | STA_EOF | STA_ODD; mst <= M_COMPLETE; end
                  else if (acc_rd[15]) begin pos <= pos + 25'd2; sta <= sta | STA_EOF | STA_ODD; mst <= M_COMPLETE; end
                  else begin
                      max_bytes <= {1'b0, acc_rd[14:0]}; rec_base <= pos + 25'd2; wptr <= 0;
                      pos <= pos + 25'd2 + ({10'd0, acc_rd[14:0] + 15'd1} >> 1);
                      mst <= M_RCDATA;
                  end
              end
              M_RCDATA: begin
                  if (ctl_dc && {wptr, 1'b0} < max_bytes) acc_read(rec_base + {9'd0, wptr}, M_RC2);
                  else begin
                      sta <= (sta & ~STA_ODD) | (max_bytes[0] ? STA_ODD : 12'd0);
                      fnc <= fnc | FNC_CMPL; arm(T_IRG); mst <= M_IDLE;
                  end
              end
              M_RC2: begin
                  if (flag_dc) sta <= sta | STA_TIM | STA_PAR;
                  msd_buf <= ({wptr, 1'b0} + 17'd1 == {1'b0, max_bytes}) ? {acc_rd[15:8], 8'd0} : acc_rd;
                  setflag_dc <= 1'b1; wptr <= wptr + 16'd1;
                  arm(T_XFER); mst <= M_IDLE;
              end
              // ---- write record: words are stored as the DMA delivers them; the header and end marker go last
              M_WC1:   begin wpd <= acc_rd; mst <= M_WCCTL; end
              M_WCINC: begin wcount <= wcount + 16'd1; mst <= M_WCCTL; end
              M_WCCTL: begin
                  if (ctl_dc) begin setflag_dc <= 1'b1; arm(T_XFER); mst <= M_IDLE; end    // ask for the next word
                  else if (wcount != 16'd0) begin hdrval <= {1'b0, wcount[13:0], 1'b0}; adv <= 16'd2 + wcount; mst <= M_HW0; end
                  else begin fnc <= fnc | FNC_CMPL; arm(T_IRG); mst <= M_IDLE; end
              end
              // ---- write tape mark
              M_WFM1:  begin wpd <= acc_rd; hdrval <= 16'h8000; adv <= 16'd2; mst <= M_HW0; end
              // ---- header, then new end marker
              M_HW0:   acc_write(pos, hdrval, M_HW1);
              M_HW1:   acc_write(pos + 25'd1, wpd, M_HE0);
              M_HE0:   acc_write(pos + {9'd0, adv}, EOM, M_HE1);
              M_HE1:   acc_write(pos + {9'd0, adv} + 25'd1, adv, M_FIN);
              M_FIN: begin
                  dirty <= 1'b1; pos <= pos + {9'd0, adv};
                  if (fnc == FNC_WC) begin fnc <= fnc | FNC_CMPL; arm(T_IRG); mst <= M_IDLE; end
                  else begin sta <= sta | STA_EOF; mst <= M_COMPLETE; end
              end
              M_COMPLETE: begin
                  setflag_cc <= 1'b1; sta <= sta & ~STA_BUSY; active <= 0; mst <= M_IDLE;
              end
              default: mst <= M_IDLE;
            endcase
        end
    end
endmodule
