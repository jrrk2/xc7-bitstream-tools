// vc707_ethmin -- the MINIMUM Ethernet SoC: picosoc + SGMII, with frames
// streamed straight into and out of the CPU's own RAM through the main
// memory's second BRAM port.
//
// What is deliberately ABSENT compared with ethsoc/framing_top_sgmii:
//   * the 32 x 2 KB RX packet buffer array
//   * the RX/TX async FIFOs and their gray-pointer crossings
//   * the byte<->word packers feeding those FIFOs
//   * the whole framing/ARP control plane
// The MAC's byte stream is packed to words and written to BRAM port B, which
// is clocked by eth_clk.  Because a true dual-port BRAM takes an independent
// clock per port, the packet data never crosses a clock domain -- only an
// ownership toggle does.
//
// MEMORY MAP (MEM_WORDS = 4096 -> 16 KiB RAM at 0x0000_0000)
//   0x0000_0000  RAM: data + stack          words 0..1023   (STACKADDR 0x1000)
//   0x0000_1000  RX window (2 KiB)          words 1024..1535
//   0x0000_1800  TX window (2 KiB)          words 1536..2047
// 8 KiB total = 8 BRAM tiles; code lives in the progmem ROM, not here.
//   0x0200_0004  simpleuart divisor         (picosoc built-in)
//   0x0200_0008  simpleuart data            (picosoc built-in)
//   0x0300_0000  GPIO/LED    rw low 8 bits drive the LEDs (picosoc convention)
//   0x0400_0000  ETH_STATUS  r  bit0 rx_valid, bit1 tx_busy, bit2 rx_trunc,
//                               bits[31:16] pcspma_status
//   0x0400_0004  ETH_RXLEN   r  received length in bytes
//                            w  any value = release the RX window
//   0x0400_0008  ETH_TXLEN   w  length in bytes = start transmitting
//
// The linker script MUST keep data+stack below 0x1000 or the CPU will be
// overwritten by an inbound packet; that is the one hazard this arrangement
// introduces, and eth_stream_dma truncates rather than wraps to bound it.
`default_nettype none
module vc707_ethmin (
	input  wire       IO_CLK_P,        // 200 MHz LVDS system clock
	input  wire       IO_CLK_N,
	input  wire       IO_RST,          // CPU_RESET, active high
	output wire [7:0] LED,
	input  wire       UART_RX,
	output wire       UART_TX,

	input  wire       sgmii_rxp,
	input  wire       sgmii_rxn,
	output wire       sgmii_txp,
	output wire       sgmii_txn,
	input  wire       sgmii_refclk_p,
	input  wire       sgmii_refclk_n,
	output wire       eth_rst_n
);
	localparam [13:0] RX_WORD_BASE = 14'd1024;   // 0x1000
	localparam [13:0] TX_WORD_BASE = 14'd1536;   // 0x1800
	localparam integer WINDOW_WORDS = 512;

	// ─── clocking ────────────────────────────────────────────────────────
	// MAC_DIV picks the MAC's clock: VCO 1000 MHz / MAC_DIV.  8 -> 125 MHz.
	// The MAC no longer has to match the PCS, so this is a build knob -- lower
	// it if timing does not close, at the cost of sustained throughput (which
	// this design does not use: it holds one frame at a time).
	// Overridable so the open flow can lower it WITHOUT a second copy of this
	// file: the open placer reaches ~98 MHz on the MAC domain where Vivado
	// reaches 125+, and that gap is placement quality, not the design.
	// Default 8 keeps every existing flow byte-identical.
`ifndef MAC_DIV
`define MAC_DIV 8
`endif
	localparam integer MAC_DIV = `MAC_DIV;

	wire clk_sys, clk_mac, rst_sys_n, locked;
	clkgen_vc707 #(.MAC_DIV(MAC_DIV)) clkgen (
		.IO_CLK_P(IO_CLK_P), .IO_CLK_N(IO_CLK_N), .IO_RST_N(~IO_RST),
		.clk_sys(clk_sys), .clk_mac(clk_mac),
		.rst_sys_n(rst_sys_n), .locked(locked));
	wire resetn = rst_sys_n;

	wire eth_clk, rx_clk;
	wire eth_rst = ~rst_sys_n;

	// ─── SGMII PCS/PMA + MAC ─────────────────────────────────────────────
	wire [7:0] rx_tdata, tx_tdata;
	wire       rx_tvalid, rx_tlast, rx_tuser;
	wire       tx_tvalid, tx_tlast, tx_tready, tx_tuser;
	wire [15:0] pcspma_status;

	// RETIME_MAC=1: the MAC runs on clk_mac, decoupled from the PCS's 125 MHz
	// by 256-byte RAM256X1S packet buffers.  Frames over 256 bytes are dropped.
	sgmii_soc #(.RETIME_MAC(1)) eth (
		.clk_int(clk_sys), .rst_int(~rst_sys_n),
		.mac_clk_in(clk_mac),
		.eth_clk(eth_clk),
		.sgmii_rxp(sgmii_rxp), .sgmii_rxn(sgmii_rxn),
		.sgmii_txp(sgmii_txp), .sgmii_txn(sgmii_txn),
		.sgmii_refclk_p(sgmii_refclk_p), .sgmii_refclk_n(sgmii_refclk_n),
		.phy_reset_n(eth_rst_n),
		.mac_gmii_tx_en(),
		.tx_axis_tvalid(tx_tvalid), .tx_axis_tlast(tx_tlast),
		.tx_axis_tdata(tx_tdata),   .tx_axis_tready(tx_tready),
		.tx_axis_tuser(tx_tuser),
		.rx_clk(rx_clk),
		.rx_axis_tdata(rx_tdata),   .rx_axis_tvalid(rx_tvalid),
		.rx_axis_tlast(rx_tlast),   .rx_axis_tuser(rx_tuser),
		.rx_fcs_reg(), .tx_fcs_reg(),
		.pcspma_status(pcspma_status));

	// ─── SoC + DMA + registers (see ethmin/ethmin_core.v) ────────────────
	ethmin_core #(
		.RX_WORD_BASE(RX_WORD_BASE), .TX_WORD_BASE(TX_WORD_BASE),
		.WINDOW_WORDS(WINDOW_WORDS)
	) core (
		.clk_sys(clk_sys), .resetn(resetn),
		// clk_mac DIRECTLY, not the eth_clk that comes back out of sgmii_soc.
		//
		// With RETIME_MAC=1 -- which this top hardcodes, and which the LiteEth
		// PCS requires -- sgmii_soc's eth_clk IS mac_clk_in, i.e. clk_mac
		// routed out of one module and back into another.  yosys's clkbufmap
		// cannot know that net is already buffered by clkgen.clk_mac_bufg, so
		// it inserted a SECOND global buffer in series: a BUFG->BUFG cascade,
		// which Vivado's DRC flags (PLCK-1) and which costs two insertion
		// delays instead of one.  That delay lands as skew against eth_tx and
		// eth_rx, the two domains already tightest at 125 MHz.
		//
		// eth_clk stays connected below purely as an observable; with no loads
		// no buffer is inferred for it.
		.eth_clk(clk_mac), .eth_rst(eth_rst),
		.rx_axis_tdata(rx_tdata), .rx_axis_tvalid(rx_tvalid),
		.rx_axis_tlast(rx_tlast), .rx_axis_tuser(rx_tuser),
		.tx_axis_tdata(tx_tdata), .tx_axis_tvalid(tx_tvalid),
		.tx_axis_tlast(tx_tlast), .tx_axis_tready(tx_tready),
		.tx_axis_tuser(tx_tuser),
		.pcspma_status(pcspma_status),
		.LED(LED), .UART_RX(UART_RX), .UART_TX(UART_TX));
endmodule
`default_nettype wire
