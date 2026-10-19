// Backing-store engine for the disc: moves one 128-word sector between the controller's sector buffer
// (port B) and DRAM.  The DRAM port is abstract: a request is accepted in a cycle where dram_req && dram_rdy;
// read data returns in order on dram_rvalid/dram_rdata.  Maps onto a MIG app interface behind a width adapter.
// DRAM word address = {unit, lba[16:0], word[6:0]}.
module hp_disc_store (
    input             clk,
    input             rst,
    // controller side
    input             req,
    input             wr,                 // 1: sector buffer -> DRAM, 0: DRAM -> sector buffer
    input             unit,
    input      [16:0] lba,
    output            idle,
    output reg        done,
    output reg        bufb_we,
    output reg [6:0]  bufb_waddr,
    output reg [15:0] bufb_wdata,
    output reg [6:0]  bufb_raddr,
    input      [15:0] bufb_rdata,
    // DRAM
    output reg        dram_req,
    output reg        dram_we,
    output reg [24:0] dram_addr,
    output reg [15:0] dram_wdata,
    input             dram_rdy,
    input             dram_rvalid,
    input      [15:0] dram_rdata
);
    localparam [3:0] S_IDLE = 0, S_LDISS = 1, S_STRD = 3, S_STWAIT = 4, S_STWR = 5, S_STDRAIN = 6, S_FIN = 7;
    reg [3:0]  state;
    reg        r_unit;
    reg [16:0] r_lba;
    reg [7:0]  issued, got;
    assign idle = (state == S_IDLE) && !req;

    wire can_issue = !dram_req || dram_rdy;        // the previous request (if any) is accepted this cycle

    always @(posedge clk) begin
        done <= 1'b0; bufb_we <= 1'b0;
        if (dram_req && dram_rdy) dram_req <= 1'b0;   // accepted
        if (rst) begin state <= S_IDLE; issued <= 0; got <= 0; dram_req <= 0; end
        else begin
            case (state)
              S_IDLE: if (req) begin
                  r_unit <= unit; r_lba <= lba; issued <= 0; got <= 0;
                  state <= wr ? S_STRD : S_LDISS;
                  bufb_raddr <= 7'd0;
              end
              // ---- DRAM -> buffer: present reads back to back, capture returning data in order
              S_LDISS: begin
                  if (can_issue && issued < 8'd128) begin
                      dram_req <= 1'b1; dram_we <= 1'b0; dram_addr <= {r_unit, r_lba, issued[6:0]};
                      issued <= issued + 8'd1;
                  end
                  if (dram_rvalid) begin
                      bufb_we <= 1'b1; bufb_waddr <= got[6:0]; bufb_wdata <= dram_rdata; got <= got + 8'd1;
                      if (got == 8'd127) state <= S_FIN;
                  end
              end
              // ---- buffer -> DRAM: read the buffer (one-cycle latency), then present the write
              S_STRD: state <= S_STWAIT;
              S_STWAIT: state <= S_STWR;
              S_STWR: if (can_issue) begin
                  dram_req <= 1'b1; dram_we <= 1'b1; dram_addr <= {r_unit, r_lba, issued[6:0]};
                  dram_wdata <= bufb_rdata;
                  issued <= issued + 8'd1;
                  if (issued == 8'd127) state <= S_STDRAIN;
                  else begin bufb_raddr <= issued[6:0] + 7'd1; state <= S_STRD; end
              end
              S_STDRAIN: if (!dram_req || dram_rdy) state <= S_FIN;
              S_FIN: begin done <= 1'b1; state <= S_IDLE; end
              default: state <= S_IDLE;
            endcase
        end
    end
endmodule
