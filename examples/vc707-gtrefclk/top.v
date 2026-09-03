// Minimal reproducer: a gigabit-transceiver REFERENCE CLOCK taken from a pad.
//
// This is the smallest design that reaches the place where nextpnr-himbaechel
// currently gives up on 7-series transceivers.  There is no GTXE2 here at all
// -- just the reference-clock input buffer every GT design must have -- which
// is the point: the blocker is in binding IBUFDS_GTE2 to a pad, upstream of
// anything transceiver-specific.
//
// Expected today:
//     ERROR: failed to find IBUFDS_GTE2 site for pad '.../IPAD_X0Y0.PAD'
//
// When that stops happening this design places and routes, and the CI entry
// for it flips from "blocked" to "unblocked" -- see scripts/verify_examples.sh.
module top (
    input  wire sgmii_refclk_p,
    input  wire sgmii_refclk_n,
    output wire [7:0] led
);
    wire refclk, refclk_bufg;

    IBUFDS_GTE2 #(
        .CLKCM_CFG("TRUE"),
        .CLKRCV_TRST("TRUE"),
        .CLKSWING_CFG(2'b11)
    ) refclk_ibuf (
        .I(sgmii_refclk_p), .IB(sgmii_refclk_n),
        .CEB(1'b0), .O(refclk), .ODIV2()
    );

    BUFG refclk_bufg_i (.I(refclk), .O(refclk_bufg));

    // Something for the clock to drive, so nothing is optimised away.
    reg [27:0] ctr = 28'd0;
    always @(posedge refclk_bufg) ctr <= ctr + 1'b1;

    genvar i;
    generate for (i = 0; i < 8; i = i + 1) begin : g_led
        OBUF obuf_i (.I(ctr[20 + i]), .O(led[i]));
    end endgenerate
endmodule
