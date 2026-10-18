// One end of a processor-to-processor link card (12566-style): OTA loads the output register,
// STC strobes the peer (data latched there, its flag set); LIA reads the latched input.
module hp_link #(parameter [5:0] SC = 6'o10) (
    input             clk,
    input             rst,
    input      [5:0]  sc_s,
    input             stc,
    input             ot,
    input      [15:0] dout,
    input      [5:0]  rd_sc,
    output     [15:0] rd_data,
    output            rd_sel,
    output reg        setflag,
    // peer connection
    output reg        tx_stb,
    output reg [15:0] tx_data,
    input             rx_stb,
    input      [15:0] rx_data
);
    reg [15:0] outreg, inreg;
    assign rd_sel = (rd_sc == SC);
    assign rd_data = inreg;
    always @(posedge clk) begin
        setflag <= 1'b0; tx_stb <= 1'b0;
        if (rst) begin outreg <= 0; inreg <= 0; end
        else begin
            if (ot && sc_s == SC) outreg <= dout;
            if (stc && sc_s == SC) begin tx_stb <= 1'b1; tx_data <= outreg;
`ifdef TRACE
                $display("LINK sc%02o: %06o", SC, outreg);
`endif
            end
            if (rx_stb) begin inreg <= rx_data; setflag <= 1'b1; end
        end
    end
endmodule
