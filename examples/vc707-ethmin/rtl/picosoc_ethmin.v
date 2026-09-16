// picosoc_ethmin -- picosoc_noflash with the main RAM's SECOND BRAM port
// brought out to the top, so Ethernet frames stream straight into and out of
// the CPU's own memory (see ethmin/README.md).
//
// Generated from picosoc/picosoc_noflash.v with three edits ONLY -- module
// name, the new mem_b_* ports, and picosoc_mem -> picosoc_mem_dp -- so the
// proven SoC stays untouched and this stays diffable against it.
`timescale 1 ns / 1 ps

module picosoc_ethmin (
	input clk,
	input resetn,
	input [31:0] progaddr_reset_i,

	// Main-RAM SECOND PORT, brought out for the Ethernet DMA.  Independent
	// clock: the 125 MHz eth side writes/reads the CPU's own memory directly,
	// so packets need no FIFO and the data path never crosses a clock domain.
	input         mem_b_clk,
	input         mem_b_en,
	input         mem_b_we,
	input  [13:0] mem_b_addr,
	input  [31:0] mem_b_wdata,
	output [31:0] mem_b_rdata,

	output        iomem_valid,
	input         iomem_ready,
	output [ 3:0] iomem_wstrb,
	output [31:0] iomem_addr,
	output [31:0] iomem_wdata,
	input  [31:0] iomem_rdata,

	input  irq_5,
	input  irq_6,
	input  irq_7,

	output ser_tx,
	input  ser_rx,

	// ---- CPU memory-bus debug taps (open-flow JTAG observability) ----
	output        dbg_mem_valid,
	output        dbg_mem_ready,
	output        dbg_mem_instr,
	output [31:0] dbg_mem_addr,
	output        dbg_progmem_ready,
	output [31:0] dbg_reg_pc
);
	parameter integer MEM_WORDS = 4096;
	parameter [31:0] STACKADDR = (4*MEM_WORDS);       // end of memory
	parameter [31:0] PROGADDR_RESET = 32'h 0010_0000; // 1 MB into flash

	reg [31:0] irq;
	wire irq_stall = 0;
	wire irq_uart = 0;

	always @* begin
		irq = 0;
		irq[3] = irq_stall;
		irq[4] = irq_uart;
		irq[5] = irq_5;
		irq[6] = irq_6;
		irq[7] = irq_7;
	end

	wire mem_valid;
	wire mem_instr;
	wire mem_ready;
	wire [31:0] mem_addr;
	wire [31:0] mem_wdata;
	wire [3:0] mem_wstrb;
	wire [31:0] mem_rdata;

	wire progmem_ready;
	wire [31:0] progmem_rdata;

	reg ram_ready;
	wire [31:0] ram_rdata;

	assign dbg_mem_valid = mem_valid;
	assign dbg_mem_ready = mem_ready;
	assign dbg_mem_instr = mem_instr;
	assign dbg_mem_addr  = mem_addr;
	assign dbg_progmem_ready = progmem_ready;

	assign iomem_valid = mem_valid && (mem_addr[31:24] > 8'h 01);
	assign iomem_wstrb = mem_wstrb;
	assign iomem_addr = mem_addr;
	assign iomem_wdata = mem_wdata;

	wire        spimemio_cfgreg_sel    = mem_valid && (mem_addr == 32'h 0200_0000);

	wire        simpleuart_reg_div_sel = mem_valid && (mem_addr == 32'h 0200_0004);
	wire [31:0] simpleuart_reg_div_do;

	wire        simpleuart_reg_dat_sel = mem_valid && (mem_addr == 32'h 0200_0008);
	wire [31:0] simpleuart_reg_dat_do;
	wire        simpleuart_reg_dat_wait;

	assign mem_ready = 
            (iomem_valid && iomem_ready) || progmem_ready || ram_ready || spimemio_cfgreg_sel ||
			simpleuart_reg_div_sel || (simpleuart_reg_dat_sel && !simpleuart_reg_dat_wait);

	assign mem_rdata = 
            (iomem_valid && iomem_ready) ? iomem_rdata :
            progmem_ready ? progmem_rdata :
            ram_ready ? ram_rdata :
            spimemio_cfgreg_sel ? 32'h0000_0000 : // Mockup, will always read 0
			simpleuart_reg_div_sel ? simpleuart_reg_div_do :
			simpleuart_reg_dat_sel ? simpleuart_reg_dat_do : 32'h 0000_0000;

`ifdef SIMULATION    
	wire        trace_valid;
	wire [35:0] trace_data;
    integer     trace_file;
`endif

	picorv32 #(
		.STACKADDR(STACKADDR),
		.PROGADDR_RESET(PROGADDR_RESET),
		.PROGADDR_IRQ(32'h 0000_0000),
		.BARREL_SHIFTER(1),
		.COMPRESSED_ISA(1),
		.ENABLE_MUL(0),
		.ENABLE_DIV(0),
		.ENABLE_COUNTERS64(0),
		.ENABLE_IRQ(1),
`ifdef SIMULATION    
		.ENABLE_IRQ_QREGS(0),
        .ENABLE_TRACE(1)
`else
		.ENABLE_IRQ_QREGS(0)
`endif
	) cpu (
		.clk         (clk        ),
		.resetn      (resetn     ),
		.progaddr_reset_i (progaddr_reset_i),
		.dbg_reg_pc       (dbg_reg_pc),
		.mem_valid   (mem_valid  ),
		.mem_instr   (mem_instr  ),
		.mem_ready   (mem_ready  ),
		.mem_addr    (mem_addr   ),
		.mem_wdata   (mem_wdata  ),
		.mem_wstrb   (mem_wstrb  ),
		.mem_rdata   (mem_rdata  ),
`ifdef SIMULATION
		.irq         (irq        ),
		.trace_valid (trace_valid),
		.trace_data  (trace_data )
`else
		.irq         (irq        )
`endif
	);

    // This it the program ROM memory for the PicoRV32
    progmem progmem (
        .clk    (clk),
        .rstn   (resetn),

        .valid  (mem_valid && mem_addr >= 4*MEM_WORDS && mem_addr < 32'h 0200_0000),
        .ready  (progmem_ready),
        .addr   (mem_addr),
        .rdata  (progmem_rdata)
    );

	// DEFAULT_DIV matters because THIS FIRMWARE NEVER SETS THE DIVIDER.
	// simpleuart's own default is 1, i.e. one clock per bit = 25 Mbaud on
	// clk_sys, which no FTDI can capture -- so every uart_puts in ethmin.c
	// (the banner, " -> arp reply", " !! rx truncated") has been emitted as
	// unreadable line noise, and the design's own diagnostics were invisible
	// during bring-up.  25 MHz / 115200 = 217.
	simpleuart #(.DEFAULT_DIV(217)) simpleuart (
		.clk         (clk         ),
		.resetn      (resetn      ),

		.ser_tx      (ser_tx      ),
		.ser_rx      (ser_rx      ),

		.reg_div_we  (simpleuart_reg_div_sel ? mem_wstrb : 4'b 0000),
		.reg_div_di  (mem_wdata),
		.reg_div_do  (simpleuart_reg_div_do),

		.reg_dat_we  (simpleuart_reg_dat_sel ? mem_wstrb[0] : 1'b 0),
		.reg_dat_re  (simpleuart_reg_dat_sel && !mem_wstrb),
		.reg_dat_di  (mem_wdata),
		.reg_dat_do  (simpleuart_reg_dat_do),
		.reg_dat_wait(simpleuart_reg_dat_wait)
	);

	always @(posedge clk)
		ram_ready <= mem_valid && !mem_ready && mem_addr < 4*MEM_WORDS;

	picosoc_mem_dp #(.WORDS(MEM_WORDS)) memory (
		.clk_b(mem_b_clk), .en_b(mem_b_en), .we_b(mem_b_we),
		.addr_b(mem_b_addr), .wdata_b(mem_b_wdata), .rdata_b(mem_b_rdata),
		.clk(clk),
		.wen((mem_valid && !mem_ready && mem_addr < 4*MEM_WORDS) ? mem_wstrb : 4'b0),
		.addr(mem_addr[23:2]),
		.wdata(mem_wdata),
		.rdata(ram_rdata)
	);

    // Simulation debug
`ifdef SIMULATION
`ifdef SIMULATION_VERBOSE
    always @(posedge clk) begin
        if (resetn) begin
            if ( mem_instr && mem_valid && mem_ready)
                $display("Inst rd: [0x%08X] = 0x%08X", mem_addr, mem_rdata);
            if (!mem_instr && mem_valid && mem_ready)
                $display("Data rd: [0x%08X] = 0x%08X", mem_addr, mem_rdata);
        end
    end
`endif // SIMULATION_VERBOSE

    // Trace (disabled for Verilator - timing constructs not supported)
`ifndef VERILATOR
    initial begin

        trace_file = $fopen("testbench.trace", "w");
        repeat (10) @(posedge clk);

        while(1) begin
            @(posedge clk);
            if (resetn && trace_valid) begin
                $fwrite(trace_file, "%x\n", trace_data);
                $fflush(trace_file);
                //$display("Trace  : %09X", trace_data);
            end
        end
    end
`endif // VERILATOR

`endif // SIMULATION

endmodule
