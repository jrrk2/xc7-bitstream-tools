// Photoreader (sc 13 on the main CPU): STC,C starts a frame read; the frame appears after a short delay
// with the flag set.  Frames come from a ROM (BRAM) holding the loader paper tape; past the end it reads blanks.
module hp_pr #(parameter [5:0] SC = 6'o13, parameter STEP = 12, parameter DELAY = 20,
               parameter AW = 17, parameter [AW:0] LEN = 0, parameter INIT = "tape.hex") (
    input             clk,
    input             rst,
    input      [5:0]  sc_s,
    input             stc,
    input      [5:0]  rd_sc,
    output     [15:0] rd_data,
    output            rd_sel,
    output reg        setflag
);
    reg [7:0] rom [0:(1<<AW)-1];
    initial $readmemh(INIT, rom);
    reg [AW:0] pos;
    reg [7:0]  frame;
    reg [31:0] cnt;
    reg        run;
    assign rd_sel = (rd_sc == SC);
    assign rd_data = {8'd0, frame};
    always @(posedge clk) begin
        setflag <= 1'b0;
        if (rst) begin pos <= 0; frame <= 0; run <= 0; cnt <= 0; end
        else begin
            if (stc && sc_s == SC && !run) begin run <= 1; cnt <= DELAY * STEP; end
            if (run) begin
                if (cnt > 1) cnt <= cnt - 1;
                else begin
                    run <= 0; setflag <= 1'b1;
                    frame <= (pos < LEN) ? rom[pos[AW-1:0]] : 8'd0;
                    pos <= pos + 1;
                end
            end
        end
    end
endmodule
