`timescale 1ns/1ps
// ethmin_core -- the SoC, the Ethernet DMA and the register file, with the
// MAC's byte streams as ports.  Split out of vc707_ethmin so a testbench can
// drive the MAC side directly (ethmin/tb/tb_ethmin.sv) without the GT: the
// PCS/PMA is not simulatable here, but the firmware, the DMA and the register
// interface are exactly what needs smoke-testing.
`default_nettype none
module ethmin_core #(
	// 8 KiB of RAM is enough for this SoC and halves the BRAM: the firmware is
	// ~2.3 KiB of ROM-resident code with a few hundred bytes of data/stack, and
	// the two windows need 2 KiB each to hold a full 1518-byte frame.
	//   0x0000..0x0FFF  code data + stack (STACKADDR = 0x1000)
	//   0x1000..0x17FF  RX window
	//   0x1800..0x1FFF  TX window
	parameter integer MEM_WORDS   = 2048,      // 8 KiB
	parameter [31:0] STACKADDR    = 32'h1000,  // MUST stay below the RX window
	parameter [13:0] RX_WORD_BASE = 14'd1024,
	parameter [13:0] TX_WORD_BASE = 14'd1536,
	parameter integer WINDOW_WORDS = 512
) (
	input  wire        clk_sys,
	input  wire        resetn,
	input  wire        eth_clk,
	input  wire        eth_rst,

	input  wire [7:0]  rx_axis_tdata,
	input  wire        rx_axis_tvalid,
	input  wire        rx_axis_tlast,
	input  wire        rx_axis_tuser,
	output wire [7:0]  tx_axis_tdata,
	output wire        tx_axis_tvalid,
	output wire        tx_axis_tlast,
	input  wire        tx_axis_tready,
	output wire        tx_axis_tuser,

	input  wire [15:0] pcspma_status,
	output wire [7:0]  LED,
	input  wire        UART_RX,
	output wire        UART_TX
);
	// ─── the DMA: MAC stream <-> main RAM port B ─────────────────────────
	wire        mem_b_en, mem_b_we;
	wire [13:0] mem_b_addr;
	wire [31:0] mem_b_wdata, mem_b_rdata;
	wire        rx_valid, rx_trunc, tx_busy;
	wire [10:0] rx_len;
	reg  [10:0] tx_len;
	reg         tx_start, rx_ack;

	eth_stream_dma #(
		.RX_WORD_BASE(RX_WORD_BASE), .TX_WORD_BASE(TX_WORD_BASE),
		.WINDOW_WORDS(WINDOW_WORDS)
	) dma (
		.eth_clk(eth_clk), .eth_rst(eth_rst),
		.rx_axis_tdata(rx_axis_tdata), .rx_axis_tvalid(rx_axis_tvalid),
		.rx_axis_tlast(rx_axis_tlast), .rx_axis_tuser(rx_axis_tuser),
		.tx_axis_tdata(tx_axis_tdata), .tx_axis_tvalid(tx_axis_tvalid),
		.tx_axis_tlast(tx_axis_tlast), .tx_axis_tready(tx_axis_tready),
		.tx_axis_tuser(tx_axis_tuser),
		.mem_en(mem_b_en), .mem_we(mem_b_we), .mem_addr(mem_b_addr),
		.mem_wdata(mem_b_wdata), .mem_rdata(mem_b_rdata),
		.cpu_clk(clk_sys), .cpu_rst(~resetn),
		.rx_valid(rx_valid), .rx_len(rx_len), .rx_trunc(rx_trunc),
		.rx_ack(rx_ack), .tx_len(tx_len), .tx_start(tx_start),
		.tx_busy(tx_busy));

	// ─── SoC ─────────────────────────────────────────────────────────────
	wire        iomem_valid;
	reg         iomem_ready;
	wire [3:0]  iomem_wstrb;
	wire [31:0] iomem_addr, iomem_wdata;
	reg  [31:0] iomem_rdata;
	reg  [31:0] gpio;

	picosoc_ethmin #(.MEM_WORDS(MEM_WORDS), .STACKADDR(STACKADDR)) soc (
		.clk(clk_sys), .resetn(resetn),
		.progaddr_reset_i(32'h0010_0000),   // boot from progmem
		// port B is now the CPU's clock: the DMA buffers frames in CLB FIFOs and
		// moves them here at 25 MHz, so eth_clk is no longer tethered to a BRAM
		// column.  Putting eth_clk back reinstates the tether silently.
		.mem_b_clk(eth_clk), .mem_b_en(mem_b_en), .mem_b_we(mem_b_we),
		.mem_b_addr(mem_b_addr), .mem_b_wdata(mem_b_wdata),
		.mem_b_rdata(mem_b_rdata),
		.iomem_valid(iomem_valid), .iomem_ready(iomem_ready),
		.iomem_wstrb(iomem_wstrb), .iomem_addr(iomem_addr),
		.iomem_wdata(iomem_wdata), .iomem_rdata(iomem_rdata),
		.irq_5(1'b0), .irq_6(1'b0), .irq_7(1'b0),
		.ser_tx(UART_TX), .ser_rx(UART_RX),
		.dbg_mem_valid(), .dbg_mem_ready(), .dbg_mem_instr(),
		.dbg_mem_addr(), .dbg_progmem_ready(), .dbg_reg_pc());

	assign LED = gpio[7:0];

	// ─── iomem devices: GPIO at 0x03xx_xxxx, eth at 0x04xx_xxxx ──────────
	wire gpio_sel = iomem_valid && (iomem_addr[31:24] == 8'h03);
	wire eth_sel  = iomem_valid && (iomem_addr[31:24] == 8'h04);
	always @(posedge clk_sys) begin
		iomem_ready <= 1'b0;
		rx_ack      <= 1'b0;
		tx_start    <= 1'b0;
		if (!resetn) begin
			gpio <= 32'd0;
		end else if (gpio_sel && !iomem_ready) begin
			iomem_ready <= 1'b1;
			iomem_rdata <= gpio;
			if (iomem_wstrb[0]) gpio[ 7: 0] <= iomem_wdata[ 7: 0];
			if (iomem_wstrb[1]) gpio[15: 8] <= iomem_wdata[15: 8];
			if (iomem_wstrb[2]) gpio[23:16] <= iomem_wdata[23:16];
			if (iomem_wstrb[3]) gpio[31:24] <= iomem_wdata[31:24];
		end else if (eth_sel && !iomem_ready) begin
			iomem_ready <= 1'b1;
			case (iomem_addr[7:0])
				8'h00: iomem_rdata <= {pcspma_status, 13'd0,
				                       rx_trunc, tx_busy, rx_valid};
				8'h04: begin
					iomem_rdata <= {21'd0, rx_len};
					if (|iomem_wstrb) rx_ack <= 1'b1;      // release the window
				end
				8'h08: begin
					iomem_rdata <= {21'd0, tx_len};
					if (|iomem_wstrb) begin
						tx_len   <= iomem_wdata[10:0];
						tx_start <= 1'b1;
					end
				end
				default: iomem_rdata <= 32'd0;
			endcase
		end
	end
endmodule
`default_nettype wire
