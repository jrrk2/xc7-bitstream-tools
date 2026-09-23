// vc707_bufr: a design whose only clock comes through BUFIO and BUFR, so
// that the HCLK regional-clock bits are what makes it run.  The 200 MHz
// board clock goes IBUFDS -> BUFIO -> BUFR (divide by 8) -> a counter, and
// the counter's top bits drive the LEDs.  If the HCLK_L enable-buffer or
// the HCLK_IOI rows in the database are wrong, the bitstream comes out with
// a dead regional clock and the LEDs stand still.
module vc707_bufr (
	input  wire       IO_CLK_P,
	input  wire       IO_CLK_N,
	output wire [7:0] LED
);
	wire clk_ibuf, clk_bufr;

	IBUFDS #(.DIFF_TERM("FALSE"), .IBUF_LOW_PWR("FALSE")) ibufds (
		.I(IO_CLK_P), .IB(IO_CLK_N), .O(clk_ibuf));

	// the regional clock, divided from the pin's own clock.  (A BUFIO
	// output cannot clock fabric -- it only reaches IO logic -- so the
	// BUFIO rows of the database need a design with an ODDR to exercise
	// them; this one is about the BUFR enable buffers.)
	BUFR #(.BUFR_DIVIDE("8"), .SIM_DEVICE("7SERIES")) bufr (
		.I(clk_ibuf), .CE(1'b1), .CLR(1'b0), .O(clk_bufr));

	// 200 MHz / 8 = 25 MHz: bit 24 of the counter is about 0.7 Hz, so the
	// LEDs walk visibly while the regional clock runs, and stand still if
	// the bitstream's enable buffers are wrong.
	(* keep = "true" *) reg [27:0] count_bufr = 0;
	always @(posedge clk_bufr) count_bufr <= count_bufr + 1'b1;

	assign LED = count_bufr[27:20];
endmodule
