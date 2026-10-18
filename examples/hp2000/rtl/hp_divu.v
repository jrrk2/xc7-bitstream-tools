// Restoring divider: 32-bit numerator / 16-bit divisor (d != 0), 33 cycles.  q = n / d (32 bits), r = n % d.
module hp_divu (
    input             clk,
    input             rst,
    input             start,
    input      [31:0] n,
    input      [15:0] d,
    output reg        busy,
    output reg        done,
    output reg [31:0] q,
    output reg [15:0] r
);
    reg [31:0] nn;
    reg [15:0] dd;
    reg [5:0]  cnt;
    wire [16:0] sh = {r, nn[31]};
    wire        ge = (sh >= {1'b0, dd});
    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin busy <= 0; end
        else if (start && !busy) begin
            nn <= n; dd <= d; r <= 16'd0; q <= 32'd0; cnt <= 6'd32; busy <= 1'b1;
        end else if (busy) begin
            r  <= ge ? sh - {1'b0, dd} : sh[15:0];
            q  <= {q[30:0], ge};
            nn <= {nn[30:0], 1'b0};
            cnt <= cnt - 6'd1;
            if (cnt == 6'd1) begin busy <= 1'b0; done <= 1'b1; end
        end
    end
endmodule
