// Dual-channel DMA (12895A style, 2100): select codes 6/7 (control word 1, completion flag) and 2/3
// (memory address / word count).  One word per cycle, stolen between CPU instructions.
module hp_dma (
    input             clk,
    input             rst,
    // bus decode (CPU I/O operations)
    input      [5:0]  dev_sc,         // select code accompanying the strobes
    input      [5:0]  rd_sc,          // select code being read (combinational)
    input             dev_ot,
    input             dev_stc,
    input             dev_clc,
    input             dev_stf,
    input             dev_h,
    input      [15:0] dev_dout,
    output reg [15:0] rd_data,        // LIA/MIA data for sc 2,3
    output            rd_sel,         // 1: this module answers reads for dev_sc
    input      [63:0] flagbuf_q,
    input      [63:0] srq,            // device service requests (index = select code)
    output reg [63:0] setflag,        // completion flags for sc 6/7
    // CPU interlock
    input             cpu_idle,
    output            stall,
    // DMA master port toward the I/O bus
    output reg        io_start,
    output reg [5:0]  io_sc,
    output reg        io_in,
    output reg        io_stc_en,
    output reg        io_clc_en,
    output reg        io_last,
    output reg [15:0] io_dout,
    input             io_done,
    input      [15:0] io_din,
    // memory port (used only during a DMA cycle)
    output reg        mem_req,
    output reg        mem_we,
    output reg [14:0] mem_addr,
    output reg [15:0] mem_wdata,
    input             mem_gnt,
    input      [15:0] mem_rdata,
    output            mem_own
);
    reg [15:0] cw1 [0:1];
    reg [15:0] cw2 [0:1];
    reg [15:0] cw3 [0:1];
    reg        sel [0:1];             // register-select flip-flop (0: OTA 2/3 writes cw2, 1: cw3)
    reg        xfer_en [0:1];
    reg [5:0]  xfer_sc [0:1];

    assign rd_sel = (rd_sc == 6'd2) || (rd_sc == 6'd3) || (rd_sc == 6'd6) || (rd_sc == 6'd7);

    always @* begin
        rd_data = 16'd0;
        if (rd_sc == 6'd2) rd_data = cw3[0];
        if (rd_sc == 6'd3) rd_data = cw3[1];
    end

    // request: which channel, if any, wants a cycle
    wire req0 = xfer_en[0] && srq[xfer_sc[0]];
    wire req1 = xfer_en[1] && srq[xfer_sc[1]];
    wire want = req0 || req1;

    localparam [2:0] D_IDLE = 0, D_RD = 1, D_RD2 = 2, D_BUS = 3, D_BUSW = 4, D_WR = 5, D_FIN = 6;
    reg [2:0]  dstate;
    reg        ch;
    reg [15:0] dat;
    reg holdoff;                       // one CPU instruction slot between DMA cycles
    assign stall = (want && !holdoff) || (dstate != D_IDLE);
    assign mem_own = (dstate == D_RD && !cw2[ch][15]) || (dstate == D_WR);
    always @* begin
        mem_req = 1'b0; mem_we = 1'b0; mem_addr = 15'd0; mem_wdata = 16'd0;
        if (dstate == D_RD && !cw2[ch][15]) begin mem_req = 1'b1; mem_addr = ma; end
        if (dstate == D_WR) begin mem_req = 1'b1; mem_we = 1'b1; mem_addr = ma; mem_wdata = dat; end
    end

    wire        cw3_last = (cw3[ch] == 16'hFFFF);
    wire        input_dir = cw2[ch][15];
    wire [14:0] ma = cw2[ch][14:0];

    always @(posedge clk) begin
        setflag  <= 64'd0;
        io_start <= 1'b0;
        if (rst) begin
            dstate <= D_IDLE; holdoff <= 1'b0; xfer_en[0] <= 0; xfer_en[1] <= 0; sel[0] <= 0; sel[1] <= 0;
            cw1[0] <= 0; cw1[1] <= 0; cw2[0] <= 0; cw2[1] <= 0; cw3[0] <= 0; cw3[1] <= 0;
        end else begin
            // ---- CPU-visible registers
            if (dev_ot) begin
                case (dev_sc)
                  6'd6: cw1[0] <= dev_dout;
                  6'd7: cw1[1] <= dev_dout;
                  6'd2: if (sel[0]) cw3[0] <= dev_dout; else cw2[0] <= dev_dout;
                  6'd3: if (sel[1]) cw3[1] <= dev_dout; else cw2[1] <= dev_dout;
                  default: ;
                endcase
            end
            if (dev_stc) begin
                case (dev_sc)
                  6'd2: sel[0] <= 1'b1;
                  6'd3: sel[1] <= 1'b1;
                  6'd6: if (!flagbuf_q[6] || dev_h) begin xfer_sc[0] <= cw1[0][5:0]; xfer_en[0] <= 1'b1; end
                  6'd7: if (!flagbuf_q[7] || dev_h) begin xfer_sc[1] <= cw1[1][5:0]; xfer_en[1] <= 1'b1; end
                  default: ;
                endcase
            end
            if (dev_clc) begin
                if (dev_sc == 6'd2) sel[0] <= 1'b0;
                if (dev_sc == 6'd3) sel[1] <= 1'b0;
            end
            if (dev_stf) begin
                if (dev_sc == 6'd6) xfer_en[0] <= 1'b0;           // setting the channel flag aborts a transfer
                if (dev_sc == 6'd7) xfer_en[1] <= 1'b0;
            end
            if (!cpu_idle) holdoff <= 1'b0;
            // ---- cycle engine
            case (dstate)
              D_IDLE: if (cpu_idle && want && !holdoff) begin
                  ch <= req0 ? 1'b0 : 1'b1;
                  dstate <= D_RD;
              end
              D_RD: begin
                  if (cw2[ch][15]) begin                             // device -> memory: bus cycle first
                      io_start <= 1'b1; io_sc <= xfer_sc[ch]; io_in <= 1'b1; io_stc_en <= cw1[ch][15];
                      io_clc_en <= cw1[ch][13]; io_last <= cw3_last; io_dout <= 16'd0;
                      dstate <= D_BUSW;
                  end else begin                                      // memory -> device: read memory first
                      if (mem_gnt) dstate <= D_RD2;
                  end
              end
              D_RD2: begin
                  dat <= mem_rdata;
                  io_start <= 1'b1; io_sc <= xfer_sc[ch]; io_in <= 1'b0; io_stc_en <= cw1[ch][15];
                  io_clc_en <= cw1[ch][13]; io_last <= cw3_last; io_dout <= mem_rdata;
                  dstate <= D_BUSW;
              end
              D_BUSW: if (io_done) begin
                  if (cw2[ch][15]) begin dat <= io_din; dstate <= D_WR; end
                  else dstate <= D_FIN;
              end
              D_WR: begin
                  if (mem_gnt) dstate <= D_FIN;
              end
              D_FIN: begin
                  cw2[ch] <= {cw2[ch][15], 15'd0} | ((cw2[ch][14:0] + 15'd1) & 15'h7FFF);
                  cw3[ch] <= cw3[ch] + 16'd1;
                  if (cw3[ch] + 16'd1 == 16'd0) begin
                      setflag[ch ? 7 : 6] <= 1'b1;
                      xfer_en[ch] <= 1'b0;
                  end
                  dstate <= D_IDLE;
                  holdoff <= 1'b1;
              end
              default: dstate <= D_IDLE;
            endcase
        end
    end
endmodule
