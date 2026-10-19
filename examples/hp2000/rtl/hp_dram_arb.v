// Two clients on one DRAM port.
//   A: pipelined burst client (the disc store engine) - owns the port while its engine is busy.
//   B: single-word client (the tape controller): pulse b_req; b_done pulses when finished.
// Ownership changes only when the current owner is idle, so read data needs no routing tags.
module hp_dram_arb (
    input             clk,
    input             rst,
    // client A
    input             a_busy,          // engine busy or about to start (not idle)
    input             a_req, input a_we, input [24:0] a_addr, input [15:0] a_wdata,
    output            a_rdy, output a_rvalid, output [15:0] a_rdata,
    // client B
    input             b_req, input b_we, input [25:0] b_addr, input [15:0] b_wdata,
    output reg        b_done, output reg [15:0] b_rdata,
    // DRAM
    output            dram_req, output dram_we, output [25:0] dram_addr, output [15:0] dram_wdata,
    input             dram_rdy, input dram_rvalid, input [15:0] dram_rdata
);
    localparam [1:0] O_IDLE = 0, O_A = 1, O_B = 2;
    reg [1:0]  own;
    reg        b_pend, b_sent;           // B request latched / issued
    reg        b_is_wr;
    reg [25:0] b_addr_q;
    reg [15:0] b_wdata_q;
    wire       own_a = (own == O_A);
    wire       own_b = (own == O_B);

    assign dram_req   = own_a ? a_req : (own_b && b_pend && !b_sent);
    assign dram_we    = own_a ? a_we : b_is_wr;
    assign dram_addr  = own_a ? {1'b0, a_addr} : b_addr_q;
    assign dram_wdata = own_a ? a_wdata : b_wdata_q;
    assign a_rdy      = own_a && dram_rdy;
    assign a_rvalid   = own_a && dram_rvalid;
    assign a_rdata    = dram_rdata;

    always @(posedge clk) begin
        b_done <= 1'b0;
        if (rst) begin own <= O_IDLE; b_pend <= 0; b_sent <= 0; end
        else begin
            if (b_req && !b_pend) begin
                b_pend <= 1'b1; b_sent <= 1'b0; b_is_wr <= b_we; b_addr_q <= b_addr; b_wdata_q <= b_wdata;
            end
            case (own)
              O_IDLE: begin
                  if (a_busy) own <= O_A;
                  else if (b_pend || b_req) own <= O_B;
              end
              O_A: if (!a_busy) own <= O_IDLE;
              O_B: begin
                  if (b_pend && !b_sent && dram_rdy) begin
                      b_sent <= 1'b1;
                      if (b_is_wr) begin b_done <= 1'b1; b_pend <= 1'b0; own <= O_IDLE; end
                  end
                  if (b_sent && dram_rvalid) begin b_rdata <= dram_rdata; b_done <= 1'b1; b_pend <= 1'b0; own <= O_IDLE; end
              end
              default: own <= O_IDLE;
            endcase
        end
    end
endmodule
