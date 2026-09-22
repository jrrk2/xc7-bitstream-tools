// bram9 -- RAMB36E1 port widths the halves cannot express alone: 9 (8 data + parity),
// with 1, 4 and 18 beside it for reference.  One instance per case, each read out to
// an LED so nothing is optimised away.  Vivado's bitstream is the oracle for what the
// tile-level width bits are; nextpnr's FASM is the answer under test.
`default_nettype none
module bram9 (
	input  wire       clk,
	input  wire       rst,
	output wire [7:0] LED
);
	reg [15:0] addr = 0;
	reg [8:0]  wd = 9'h155;
	reg        we = 1'b0;
	always @(posedge clk) begin
		addr <= addr + 1;
		wd   <= {wd[7:0], wd[8] ^ wd[3]};
		we   <= ~we;
	end
	wire [31:0] do_a9, do_b9, do_a1, do_a4, do_a18, do_b18;
	wire [3:0]  dop_a9, dop_b9, dop_a18, dop_b18;

	// port A and B both 9 wide: written on A, read on B
	RAMB36E1 #(.READ_WIDTH_A(9), .READ_WIDTH_B(9), .WRITE_WIDTH_A(9), .WRITE_WIDTH_B(9),
	           .RAM_MODE("TDP"), .DOA_REG(0), .DOB_REG(0)) m9 (
		.CLKARDCLK(clk), .CLKBWRCLK(clk), .ENARDEN(1'b1), .ENBWREN(1'b1),
		.REGCEAREGCE(1'b0), .REGCEB(1'b0), .RSTRAMARSTRAM(1'b0), .RSTRAMB(1'b0), .RSTREGARSTREG(1'b0), .RSTREGB(1'b0),
		.ADDRARDADDR({1'b1, addr[11:0], 3'b000}), .ADDRBWRADDR({1'b1, addr[11:0] ^ 12'h55, 3'b000}),
		.DIADI({24'd0, wd[7:0]}), .DIBDI(32'd0), .DIPADIP({3'b0, wd[8]}), .DIPBDIP(4'd0),
		.WEA({4{we}}), .WEBWE(8'd0), .CASCADEINA(1'b0), .CASCADEINB(1'b0), .INJECTDBITERR(1'b0), .INJECTSBITERR(1'b0),
		.DOADO(do_a9), .DOBDO(do_b9), .DOPADOP(dop_a9), .DOPBDOP(dop_b9));

	// 1 wide (known good) and 4 wide, 18 wide on both ports
	RAMB36E1 #(.READ_WIDTH_A(1), .READ_WIDTH_B(1), .WRITE_WIDTH_A(1), .WRITE_WIDTH_B(1), .RAM_MODE("TDP")) m1 (
		.CLKARDCLK(clk), .CLKBWRCLK(clk), .ENARDEN(1'b1), .ENBWREN(1'b1),
		.REGCEAREGCE(1'b0), .REGCEB(1'b0), .RSTRAMARSTRAM(1'b0), .RSTRAMB(1'b0), .RSTREGARSTREG(1'b0), .RSTREGB(1'b0),
		.ADDRARDADDR({1'b1, addr[14:0]}), .ADDRBWRADDR({1'b1, addr[14:0] ^ 15'h55}),
		.DIADI({31'd0, wd[0]}), .DIBDI(32'd0), .DIPADIP(4'd0), .DIPBDIP(4'd0),
		.WEA({4{we}}), .WEBWE(8'd0), .CASCADEINA(1'b0), .CASCADEINB(1'b0), .INJECTDBITERR(1'b0), .INJECTSBITERR(1'b0),
		.DOADO(do_a1), .DOBDO(), .DOPADOP(), .DOPBDOP());
	RAMB36E1 #(.READ_WIDTH_A(4), .READ_WIDTH_B(4), .WRITE_WIDTH_A(4), .WRITE_WIDTH_B(4), .RAM_MODE("TDP")) m4 (
		.CLKARDCLK(clk), .CLKBWRCLK(clk), .ENARDEN(1'b1), .ENBWREN(1'b1),
		.REGCEAREGCE(1'b0), .REGCEB(1'b0), .RSTRAMARSTRAM(1'b0), .RSTRAMB(1'b0), .RSTREGARSTREG(1'b0), .RSTREGB(1'b0),
		.ADDRARDADDR({1'b1, addr[12:0], 2'b00}), .ADDRBWRADDR({1'b1, addr[12:0] ^ 13'h55, 2'b00}),
		.DIADI({28'd0, wd[3:0]}), .DIBDI(32'd0), .DIPADIP(4'd0), .DIPBDIP(4'd0),
		.WEA({4{we}}), .WEBWE(8'd0), .CASCADEINA(1'b0), .CASCADEINB(1'b0), .INJECTDBITERR(1'b0), .INJECTSBITERR(1'b0),
		.DOADO(do_a4), .DOBDO(), .DOPADOP(), .DOPBDOP());
	RAMB36E1 #(.READ_WIDTH_A(18), .READ_WIDTH_B(18), .WRITE_WIDTH_A(18), .WRITE_WIDTH_B(18), .RAM_MODE("TDP")) m18 (
		.CLKARDCLK(clk), .CLKBWRCLK(clk), .ENARDEN(1'b1), .ENBWREN(1'b1),
		.REGCEAREGCE(1'b0), .REGCEB(1'b0), .RSTRAMARSTRAM(1'b0), .RSTRAMB(1'b0), .RSTREGARSTREG(1'b0), .RSTREGB(1'b0),
		.ADDRARDADDR({1'b1, addr[10:0], 4'b0000}), .ADDRBWRADDR({1'b1, addr[10:0] ^ 11'h55, 4'b0000}),
		.DIADI({16'd0, wd[7:0], wd[7:0]}), .DIBDI(32'd0), .DIPADIP({2'b0, wd[8], wd[0]}), .DIPBDIP(4'd0),
		.WEA({4{we}}), .WEBWE(8'd0), .CASCADEINA(1'b0), .CASCADEINB(1'b0), .INJECTDBITERR(1'b0), .INJECTSBITERR(1'b0),
		.DOADO(do_a18), .DOBDO(do_b18), .DOPADOP(dop_a18), .DOPBDOP(dop_b18));

	assign LED = {do_b9[0], dop_b9[0], do_a9[7], do_a1[0], do_a4[3], do_a18[15], dop_a18[1], dop_b18[0] ^ do_b18[0]};
endmodule
`default_nettype wire
