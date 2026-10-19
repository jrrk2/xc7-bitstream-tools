// Teleprinter interface (ASR-33/35 style).  OTA loads the output register; STC either prints the
// low 7 bits (print mode) or requests a keyboard character (output register bits 15:13 all set).
// A print request pre-empts a pending keyboard read.  Host side: byte stream in/out.
module hp_tty #(parameter [5:0] SC = 6'o12, parameter STEP = 12, parameter PRINT_STEPS = 200) (
    input             clk,
    input             rst,
    input      [5:0]  sc_s,           // select code accompanying the strobes
    input             stc,
    input             ot,
    input      [15:0] dout,
    input      [5:0]  rd_sc,
    output     [15:0] rd_data,
    output            rd_sel,
    output reg        setflag,
    // host
    output reg        tx_valid,
    output reg [6:0]  tx_data,
    input             rx_avail,
    input      [7:0]  rx_data,
    output reg        rx_take
);
    reg [15:0] outreg;
    reg [7:0]  kbd;
    reg        busy, waiting, printing;
    reg [31:0] pcnt;
    assign rd_sel = (rd_sc == SC);
    assign rd_data = {8'd0, kbd};

    always @(posedge clk) begin
        setflag <= 1'b0; tx_valid <= 1'b0; rx_take <= 1'b0;
        if (rst) begin
            outreg <= 0; kbd <= 0; busy <= 0; waiting <= 0; printing <= 0; pcnt <= 0;
        end else begin
            if (ot && sc_s == SC) outreg <= dout;
            if (stc && sc_s == SC) begin
                if (outreg[15:13] == 3'b111) begin                 // keyboard request
                    if (!(busy && !waiting)) begin busy <= 1; waiting <= 1; end
                end else begin                                      // print
                    if (!(busy && !waiting)) begin
                        waiting <= 0; busy <= 1; printing <= 1;
                        tx_valid <= 1; tx_data <= outreg[6:0];
                        pcnt <= PRINT_STEPS * STEP;
                    end
                end
            end
            if (waiting && rx_avail && !(stc && sc_s == SC)) begin
                kbd <= rx_data | 8'h80; rx_take <= 1; waiting <= 0; busy <= 0; setflag <= 1;
            end
            if (printing) begin
                if (pcnt != 0) pcnt <= pcnt - 1;
                else begin printing <= 0; busy <= 0; setflag <= 1; end
            end
        end
    end
endmodule
