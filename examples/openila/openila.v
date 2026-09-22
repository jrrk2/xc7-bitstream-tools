// openila -- an internal logic analyser read over JTAG, with no vendor tool
// in the loop: BSCANE2 user registers for control and data, openFPGALoader
// --user-dr on the host (scripts/openila.py drives it).
//
// WIDTH probe bits are registered on clk every cycle into a DEPTH-deep ring
// buffer (block RAM, written on clk, read on the TAP's clock) until POST
// samples after the trigger, then the buffer holds.  Trigger: the registered
// probe masked equals VALUE; MASK = 0 triggers at once (a snapshot).
//
//   USER<CTL> data register, LSB first, written on UPDATE when the key matches:
//     [WIDTH-1:0]            MASK
//     [2*WIDTH-1:WIDTH]      VALUE
//     [2*WIDTH+AW-1:2*WIDTH] POST     samples kept after the trigger
//     [2*WIDTH+AW]           ARM      1 = arm (or re-arm), 0 = disarm
//     [2*WIDTH+AW+8:+1]      KEY      0x5A
//   CAPTURE loads the status for reading back:
//     [AW-1:0]  WADDR   the next write slot = the oldest sample when done
//     [AW]      ARMED
//     [AW+1]    TRIGGERED
//     [AW+2]    DONE
//     [AW+10:AW+3] 0x1A, so a wrong chain is visible
//
//   USER<DAT> data register: (DEPTH+1)*WIDTH bits, one shift of the whole
//   buffer: the status word (as above, zero-extended) then sample 0, 1, ...
//   each LSB first.  CAPTURE rewinds.  The host rotates by WADDR to put the
//   oldest sample first.  WIDTH >= AW+11, DEPTH a power of two.
`default_nettype none
module openila #(
	parameter integer WIDTH = 64,
	parameter integer DEPTH = 1024,
	parameter integer CTL   = 2,
	parameter integer DAT   = 3
) (
	input  wire             clk,
	input  wire [WIDTH-1:0] probe
);
	localparam integer AW = $clog2(DEPTH);
	localparam integer CW = 2*WIDTH + AW + 9;
	localparam integer SW = AW + 11;

	// ---- control: USER<CTL> ----
	wire c_cap, c_drck, c_sel, c_shift, c_tdi, c_update, c_tdo;
	BSCANE2 #(.JTAG_CHAIN(CTL)) bscan_ctl (
		.CAPTURE(c_cap), .DRCK(c_drck), .RESET(), .RUNTEST(), .SEL(c_sel), .SHIFT(c_shift),
		.TCK(), .TDI(c_tdi), .TMS(), .UPDATE(c_update), .TDO(c_tdo));

	reg  [CW-1:0] csr = {CW{1'b0}};
	wire [SW-1:0] status;
	always @(posedge c_drck)
		if (c_sel) begin
			if (c_cap)        csr <= {{(CW-SW){1'b0}}, status};
			else if (c_shift) csr <= {c_tdi, csr[CW-1:1]};
		end
	assign c_tdo = csr[0];

	reg [WIDTH-1:0] mask  = {WIDTH{1'b0}};
	reg [WIDTH-1:0] value = {WIDTH{1'b0}};
	reg [AW-1:0]    post  = {AW{1'b0}};
	reg             arm_t = 1'b0;      // level, in the TAP domain
	always @(posedge c_update)
		if (c_sel && csr[2*WIDTH+AW+8 -: 8] == 8'h5A) begin
			mask  <= csr[WIDTH-1:0];
			value <= csr[2*WIDTH-1:WIDTH];
			post  <= csr[2*WIDTH+AW-1:2*WIDTH];
			arm_t <= csr[2*WIDTH+AW];
		end

	// ---- capture, in the probed clock domain ----
	reg [WIDTH-1:0] sample = {WIDTH{1'b0}};
	reg [2:0]       arm_s  = 3'b000;
	reg             armed  = 1'b0, trig = 1'b0, done = 1'b0;
	reg [AW-1:0]    waddr  = {AW{1'b0}};
	reg [AW-1:0]    left   = {AW{1'b0}};
	wire            arm    = arm_s[2];
	wire            hit    = ((sample & mask) == (value & mask));
	wire            we     = armed && !done;
	always @(posedge clk) begin
		sample <= probe;
		arm_s  <= {arm_s[1:0], arm_t};
		if (!arm) begin
			armed <= 1'b0; trig <= 1'b0; done <= 1'b0;
		end else if (!armed) begin
			armed <= 1'b1; trig <= 1'b0; done <= 1'b0; left <= post;
		end else if (!done) begin
			waddr <= waddr + 1'b1;
			if (!trig) begin
				if (hit) begin trig <= 1'b1; if (post == 0) done <= 1'b1; end
			end else if (left == 1) done <= 1'b1;
			else left <= left - 1'b1;
		end
	end

	(* ram_style = "block" *) reg [WIDTH-1:0] mem [0:DEPTH-1];
	always @(posedge clk)
		if (we) mem[waddr] <= sample;

	// ---- data: USER<DAT> ----
	wire d_cap, d_drck, d_sel, d_shift, d_tdi, d_update, d_tdo;
	BSCANE2 #(.JTAG_CHAIN(DAT)) bscan_dat (
		.CAPTURE(d_cap), .DRCK(d_drck), .RESET(), .RUNTEST(), .SEL(d_sel), .SHIFT(d_shift),
		.TCK(), .TDI(d_tdi), .TMS(), .UPDATE(d_update), .TDO(d_tdo));

	// The header word goes out first, which is also the WIDTH TAP cycles the
	// block RAM's read pipeline needs before sample 0 is due.
	reg [AW-1:0]    raddr = {AW{1'b0}};
	reg [WIDTH-1:0] rdata;
	reg [WIDTH-1:0] dsr   = {WIDTH{1'b0}};
	reg [15:0]      bitn  = 16'd0;
	always @(posedge d_drck) begin
		rdata <= mem[raddr];
		if (d_sel) begin
			if (d_cap) begin
				dsr   <= {{(WIDTH-SW){1'b0}}, status};
				raddr <= {AW{1'b0}};
				bitn  <= 16'd0;
			end else if (d_shift) begin
				if (bitn == WIDTH-1) begin
					dsr   <= rdata;
					raddr <= raddr + 1'b1;
					bitn  <= 16'd0;
				end else begin
					dsr  <= {d_tdi, dsr[WIDTH-1:1]};
					bitn <= bitn + 1'b1;
				end
			end
		end
	end
	assign d_tdo = dsr[0];

	// The flags are read raw: they are static once done, which is when the
	// buffer is read (a synchroniser on a gated TAP clock would only ever show
	// the previous access's value).
	assign status = {8'h1A, done, trig, armed, waddr};
endmodule
`default_nettype wire
