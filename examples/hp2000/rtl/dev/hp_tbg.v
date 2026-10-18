// 12539C time base generator: OTA selects the tick rate (0..7 = 100us,1ms,10ms,100ms,1s,10s,100s,1000s);
// STC starts it; each tick sets the flag while control stays set; a tick arriving with the flag still set
// records a lost tick (read back as bit 4); CLF clears the lost-tick bit.
module hp_tbg #(parameter [5:0] SC = 6'o12, parameter STEP = 12, parameter STEPS_PER_SEC = 500000) (
    input             clk,
    input             rst,
    input      [5:0]  sc_s,
    input             stc,
    input             clf,
    input             ot,
    input      [15:0] dout,
    input      [5:0]  rd_sc,
    output     [15:0] rd_data,
    output            rd_sel,
    input             flag,           // this card's flag / control as held by the I/O bus
    input             control,
    output reg        setflag
);
    reg [2:0]  rate;
    reg        running, lost;
    reg [47:0] cnt;
    assign rd_sel = (rd_sc == SC);
    assign rd_data = lost ? 16'o20 : 16'o0;

    function [47:0] period;                           // in clock cycles
        input [2:0] r;
        reg [47:0] us;
        reg [47:0] steps;
        begin
            case (r)
              3'd0: us = 48'd100;
              3'd1: us = 48'd1000;
              3'd2: us = 48'd10000;
              3'd3: us = 48'd100000;
              3'd4: us = 48'd1000000;
              3'd5: us = 48'd10000000;
              3'd6: us = 48'd100000000;
              default: us = 48'd1000000000;
            endcase
            steps = us * STEPS_PER_SEC / 1000000;
            if (steps == 0) steps = 1;
            period = steps * STEP;
        end
    endfunction

    always @(posedge clk) begin
        setflag <= 1'b0;
        if (rst) begin rate <= 0; running <= 0; lost <= 0; cnt <= 0; end
        else begin
            if (ot && sc_s == SC) rate <= dout[2:0];
            if (clf && sc_s == SC) lost <= 1'b0;
            if (stc && sc_s == SC && !running) begin running <= 1; cnt <= period(rate); end
            if (running && !(stc && sc_s == SC && !running)) begin
                if (cnt > 1) cnt <= cnt - 1;
                else begin
                    if (!control) running <= 0;
                    else begin
                        if (flag) lost <= 1'b1;
                        setflag <= 1'b1;
                        cnt <= period(rate);
                    end
                end
            end
        end
    end
endmodule
