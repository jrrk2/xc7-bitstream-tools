`timescale 1ns/1ps
// picosoc_mem_dp -- picosoc's main RAM with the SECOND BRAM port brought out,
// bit-sliced at 8K x 2 rather than 16K x 1.
//
// WHY THE WIDTH MATTERS: picosoc_mem uses 32 x RAMB18E1 in WIDTH-1 mode, one
// primitive per data bit.  That is 32 RAMB18 = 16 tiles no matter how small
// the RAM is -- the `WORDS` parameter only narrows picosoc's address decode
// and never reaches the primitives, so shrinking the memory saves nothing.
// At 8K x 2 each primitive carries TWO data bits, so a 32-bit word needs 16
// slices: 16 RAMB18 = 8 tiles, half the block RAM for the same design, and
// 8192 words of address space (far more than this SoC's 2048).
//
// Addressing: RAMB18E1 always presents a 14-bit address and ignores the low
// bits as the port widens.  At x2 the memory has 8K locations selected by
// ADDR[13:1], so the word address goes in as {addr[12:0], 1'b0}.
//
// Byte write enables: slice i holds data bits [2i+1:2i], which live in byte
// i/4, so that slice takes wen[i/4].
//
// The second port is what an Ethernet DMA needs: a true dual-port BRAM takes
// an INDEPENDENT CLOCK per port, so the 125 MHz eth side streams words
// straight into the CPU's own memory with no packet FIFO and no clock crossing
// on the data path.  Only the ownership handshake crosses (eth_stream_dma.sv).
//
// SAFETY: the ports are NOT arbitrated.  Correctness rests on the ownership
// protocol in eth_stream_dma.sv -- the CPU touches the RX window only while it
// owns a completed frame, and the TX window only while no transmit is in
// flight, so a same-address collision is unreachable.
`default_nettype none
module picosoc_mem_dp #(
	parameter integer WORDS = 2048
) (
	// Port A -- CPU
	input  wire        clk,
	input  wire [3:0]  wen,
	input  wire [21:0] addr,
	input  wire [31:0] wdata,
	output wire [31:0] rdata,

	// Port B -- Ethernet DMA (independent clock)
	input  wire        clk_b,
	input  wire        en_b,
	input  wire        we_b,      // whole-word write
	input  wire [13:0] addr_b,    // WORD address
	input  wire [31:0] wdata_b,
	output wire [31:0] rdata_b
);
	wire [12:0] a  = addr[12:0];
	wire [12:0] ab = addr_b[12:0];
	genvar i;
	generate for (i = 0; i < 16; i = i + 1) begin : membit
		wire [15:0] doa, dob;
		RAMB18E1 #(
			.READ_WIDTH_A(2), .WRITE_WIDTH_A(2), .WRITE_MODE_A("WRITE_FIRST"),
			.READ_WIDTH_B(2), .WRITE_WIDTH_B(2), .WRITE_MODE_B("WRITE_FIRST"),
			.SIM_DEVICE("7SERIES")
		) ram (
			// A: CPU.  Slice i carries bits [2i+1:2i], i.e. byte i/4.
			.CLKARDCLK(clk), .ENARDEN(1'b1),
			.REGCEAREGCE(1'b0), .RSTRAMARSTRAM(1'b0), .RSTREGARSTREG(1'b0),
			.WEA({2{wen[i/4]}}),
			.ADDRARDADDR({a, 1'b0}), .DIADI({14'b0, wdata[2*i+1:2*i]}),
			.DIPADIP(2'b0), .DOADO(doa),
			// B: DMA, whole-word writes.
			.CLKBWRCLK(clk_b), .ENBWREN(en_b), .REGCEB(1'b0),
			.RSTRAMB(1'b0), .RSTREGB(1'b0), .WEBWE({4{we_b}}),
			.ADDRBWRADDR({ab, 1'b0}), .DIBDI({14'b0, wdata_b[2*i+1:2*i]}),
			.DIPBDIP(2'b0), .DOBDO(dob));
		assign rdata[2*i+1:2*i]   = doa[1:0];
		assign rdata_b[2*i+1:2*i] = dob[1:0];
	end endgenerate
endmodule
`default_nettype wire
