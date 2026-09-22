// jtag_clkctl -- a clock gate that JTAG drives, for bitstream-as-scan-chain
// testing: the design's state is loaded by configuration (INIT bits), held,
// released for exactly N cycles of its own clock, then read back (GCAPTURE).
//
//   USER<CHAIN> data register, 32 bits, LSB first:
//     [23:0]  N       cycles to release on the next UPDATE
//     [30:24] KEY     0x2A, or the write is ignored (the TAP passes
//                     Update-DR for reasons of its own; only a keyed write
//                     is a request)
//     [31]    FREE    run freely while set (KEY still required)
//   CAPTURE loads {status} for reading back over JTAG.
//
// ce is a registered enable for a BUFGCE on clk_free's own domain, so the
// gate sees it change on its own edge and passes exactly N pulses.
`default_nettype none
module jtag_clkctl #(parameter integer CHAIN = 1) (
	input  wire        clk_free,
	output reg         ce,
	input  wire [31:0] status
);
	wire cap, drck, sel, shift, tdi, update;
	wire tdo;
	BSCANE2 #(.JTAG_CHAIN(CHAIN)) bscan (
		.CAPTURE(cap), .DRCK(drck), .RESET(), .RUNTEST(), .SEL(sel), .SHIFT(shift),
		.TCK(), .TDI(tdi), .TMS(), .UPDATE(update), .TDO(tdo));

	reg [31:0] sr = 32'd0;
	always @(posedge drck)
		if (sel) begin
			if (cap)        sr <= status;
			else if (shift) sr <= {tdi, sr[31:1]};
		end
	assign tdo = sr[0];

	reg [31:0] ctrl  = 32'd0;
	reg        req_t = 1'b0;
	always @(posedge update)
		if (sel && sr[30:24] == 7'h2A) begin
			ctrl  <= sr;
			req_t <= ~req_t;
		end

	reg [2:0]  req_s = 3'b000;
	reg [23:0] left  = 24'd0;
	initial ce = 1'b0;
	always @(posedge clk_free) begin
		req_s <= {req_s[1:0], req_t};
		if (req_s[2] != req_s[1])
			left <= ctrl[23:0];
		else if (left != 0 && ce)
			left <= left - 24'd1;
		ce <= ctrl[31] || (req_s[2] != req_s[1] ? (ctrl[23:0] != 0) : (left > (ce ? 24'd1 : 24'd0)));
	end
endmodule
`default_nettype wire
