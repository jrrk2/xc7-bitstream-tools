// A gated counter with a comparison -- the shape the SD test's PHY-init delay
// has, reduced to nothing else.
//
// It exists to answer one question: does a carry chain whose CYINIT is taken
// from the fabric (PRECYINIT.AX) rather than from the slice below extract
// correctly?  On vc707-sdtest exactly one counter differs, and its chain is
// split across slices with the carry crossing through general routing.
module top (
    input  wire sysclk_p,
    input  wire sysclk_n,
    input  wire rst,
    output wire [7:0] led
);
    wire clk;
    IBUFDS #(.DIFF_TERM("FALSE"), .IOSTANDARD("LVDS")) sysclk_buf
        (.I(sysclk_p), .IB(sysclk_n), .O(clk));

    // Two counters that step on different conditions, so the synthesis has a
    // reason to split a chain and route a carry through the fabric rather than
    // keep one contiguous run of slices.
    reg [15:0] wait_ct = 16'h0;
    reg  [2:0] step    = 3'h0;

    always @(posedge clk) begin
        if (rst) begin
            wait_ct <= 16'h0;
            step    <= 3'h0;
        end else if (wait_ct == 16'hffff) begin
            wait_ct <= 16'h0;
            step    <= step + 1'b1;
        end else if (wait_ct == 16'h03ff) begin
            wait_ct <= wait_ct + 1'b1;
            step    <= step + 1'b1;
        end else begin
            wait_ct <= wait_ct + 1'b1;
        end
    end

    assign led = {wait_ct[15], wait_ct[10:8], step[2:0], wait_ct[0]};
endmodule
