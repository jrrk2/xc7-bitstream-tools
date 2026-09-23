module ocaml4142_vm_rtl (
	clk,
	reset,
	pc,
	code_rdata,
	code_valid,
	trap_valid,
	trap_prim,
	trap_arg0,
	trap_arg1,
	trap_ready,
	trap_result,
	accu,
	sp,
	state_out,
	imm,
	nvars,
	offset,
	alloc_wosize,
	alloc_base,
	alloc_tag,
	closure_codeptr,
	closure_nvars,
	closure_i,
	opcode_out,
	tos,
	halted,
	putc_valid,
	putc_char,
	load_we,
	load_globals,
	load_addr,
	load_data,
	image_heap_words
);
	reg _sv2v_0;
	parameter signed [31:0] PCW = 24;
	parameter signed [31:0] VALUEW = 32;
	parameter signed [31:0] STACK_AW = 16;
	parameter signed [31:0] HEAP_AW = 18;
	parameter signed [31:0] GLOBALS_AW = 12;
	parameter HEAP_INIT = "";
	parameter GLOBALS_INIT = "";
	parameter signed [31:0] HEAP_INIT_WORDS = 0;
	parameter [0:0] EXTERNAL_IMAGE = 1'b0;
	input wire clk;
	input wire reset;
	output reg [PCW - 1:0] pc;
	input wire [31:0] code_rdata;
	input wire code_valid;
	output reg trap_valid;
	output reg [7:0] trap_prim;
	output reg [VALUEW - 1:0] trap_arg0;
	output reg [VALUEW - 1:0] trap_arg1;
	input wire trap_ready;
	input wire [VALUEW - 1:0] trap_result;
	output reg [VALUEW - 1:0] accu;
	output reg [STACK_AW - 1:0] sp;
	output wire [6:0] state_out;
	output reg [31:0] imm;
	output reg [31:0] nvars;
	output reg [31:0] offset;
	output reg [31:0] alloc_wosize;
	output reg [31:0] alloc_base;
	output reg [31:0] alloc_tag;
	output wire [31:0] closure_codeptr;
	output wire [7:0] closure_nvars;
	output wire [7:0] closure_i;
	output wire [7:0] opcode_out;
	output wire [31:0] tos;
	output reg halted;
	output reg putc_valid;
	output reg [7:0] putc_char;
	input wire load_we;
	input wire load_globals;
	input wire [HEAP_AW - 1:0] load_addr;
	input wire [VALUEW - 1:0] load_data;
	input wire [HEAP_AW - 1:0] image_heap_words;
	localparam [31:0] FIRST_UNIMPLEMENTED_OP = 149;
	function automatic opcode_has_imm8;
		input reg [7:0] op;
		(* full_case, parallel_case *)
		case (op)
			8'd18, 8'd8, 8'd19, 8'd20, 8'd30, 8'd25, 8'd31, 8'd32, 8'd37, 8'd38, 8'd39, 8'd40, 8'd42, 8'd54, 8'd53, 8'd57, 8'd61, 8'd59, 8'd63, 8'd64, 8'd65, 8'd66, 8'd71, 8'd72, 8'd77, 8'd78, 8'd84, 8'd85, 8'd86, 8'd89, 8'd93, 8'd94, 8'd95, 8'd96, 8'd97, 8'd103, 8'd108, 8'd127, 8'd128, 8'd48, 8'd52, 8'd87: opcode_has_imm8 = 1'b1;
			default: opcode_has_imm8 = 1'b0;
		endcase
	endfunction
	function automatic opcode_has_imm16;
		input reg [7:0] op;
		(* full_case, parallel_case *)
		case (op)
			8'd36, 8'd43, 8'd56, 8'd55, 8'd62, 8'd98, 8'd131, 8'd132, 8'd133, 8'd134, 8'd135, 8'd136, 8'd139, 8'd140, 8'd141: opcode_has_imm16 = 1'b1;
			default: opcode_has_imm16 = 1'b0;
		endcase
	endfunction
	reg [7:0] opcode;
	assign opcode_out = opcode;
	function automatic [VALUEW - 1:0] Val_int;
		input integer n;
		Val_int = (n <<< 1) | 1;
	endfunction
	function automatic integer Int_val;
		input reg [VALUEW - 1:0] v;
		Int_val = $signed(v) >>> 1;
	endfunction
	function automatic Is_int;
		input reg [VALUEW - 1:0] v;
		Is_int = v[0];
	endfunction
	function automatic [VALUEW - 1:0] Wosize_hd;
		input reg [VALUEW - 1:0] hdr;
		Wosize_hd = hdr[31:16];
	endfunction
	function automatic [VALUEW - 1:0] Val_long;
		input reg [VALUEW - 1:0] n;
		Val_long = (n << 1) | 1;
	endfunction
	localparam [VALUEW - 1:0] VAL_FALSE = Val_int(0);
	localparam [VALUEW - 1:0] VAL_TRUE = Val_int(1);
	localparam [VALUEW - 1:0] VAL_UNIT = Val_int(0);
	reg [VALUEW - 1:0] stack_mem [0:(1 << STACK_AW) - 1];
	reg [STACK_AW - 1:0] trapsp;
	reg [VALUEW - 1:0] heap_mem [0:(1 << HEAP_AW) - 1];
	reg [HEAP_AW - 1:0] hp;
	reg [HEAP_AW - 1:0] hp_after_image = HEAP_INIT_WORDS;
	reg [HEAP_AW:0] heap_lo;
	reg [HEAP_AW:0] gc_semi;
	reg [HEAP_AW:0] from_lo;
	reg [HEAP_AW:0] to_lo;
	reg [HEAP_AW:0] hp_limit;
	reg [HEAP_AW:0] gc_semispace_override = 1'sb0;
	reg [HEAP_AW:0] gc_free;
	reg [HEAP_AW:0] gc_scan;
	reg [HEAP_AW:0] gc_obj;
	reg [HEAP_AW:0] gc_new_idx;
	reg [VALUEW - 1:0] gc_val;
	reg [VALUEW - 1:0] gc_new;
	reg [VALUEW - 1:0] gc_hdr;
	reg [15:0] gc_size;
	reg [15:0] gc_rd;
	reg [15:0] gc_wr;
	reg [15:0] gc_j;
	reg [15:0] gc_scan_size;
	reg gc_copy_valid;
	reg gc_mark_second;
	reg [STACK_AW:0] gc_i;
	reg [31:0] gc_need;
	reg [31:0] alloc_need;
	reg signed [VALUEW - 1:0] mul_a;
	reg signed [VALUEW - 1:0] mul_b;
	reg signed [(2 * VALUEW) - 1:0] mul_p;
	reg [2:0] gc_phase;
	localparam [2:0] GC_ACCU = 0;
	localparam [2:0] GC_ENV = 1;
	localparam [2:0] GC_STACK = 2;
	localparam [2:0] GC_GLOBALS = 3;
	localparam [2:0] GC_SCAN = 4;
	reg gc_return_to_scan;
	reg [15:0] gc_infix_off;
	localparam [7:0] GC_FORWARDED = 8'hff;
	localparam signed [31:0] NO_SCAN_TAG = 251;
	reg signed [31:0] gc_count;
	wire [HEAP_AW - 1:0] image_words;
	wire [HEAP_AW:0] heap_base;
	wire [HEAP_AW:0] semi_space;
	assign image_words = (EXTERNAL_IMAGE ? image_heap_words : hp_after_image);
	assign heap_base = (image_words == 0 ? 1 : image_words);
	assign semi_space = (gc_semispace_override != 0 ? gc_semispace_override : (((1 << HEAP_AW) - 1) - heap_base) >> 1);
	function automatic gc_points_to_from;
		input reg [VALUEW - 1:0] v;
		reg [VALUEW - 1:0] idx;
		begin
			idx = {2'b00, v[VALUEW - 1:2]};
			gc_points_to_from = ((!v[0] && !v[VALUEW - 1]) && (idx >= from_lo)) && (idx < (from_lo + gc_semi));
		end
	endfunction
	function automatic [VALUEW - 1:0] Make_codeptr;
		input reg [PCW - 1:0] pc;
		Make_codeptr = {1'b1, {(VALUEW - PCW) - 3 {1'b0}}, pc, 2'b00};
	endfunction
	function automatic [VALUEW - 1:0] Ptr_of_heap_index;
		input reg [HEAP_AW - 1:0] idx;
		Ptr_of_heap_index = {{(VALUEW - 2) - HEAP_AW {1'b0}}, idx, 2'b00};
	endfunction
	function automatic [HEAP_AW - 1:0] Heap_index_of_ptr;
		input reg [VALUEW - 1:0] ptr;
		Heap_index_of_ptr = ptr[HEAP_AW + 1:2];
	endfunction
	function automatic [PCW - 1:0] Codeptr_val;
		input reg [VALUEW - 1:0] ptr;
		Codeptr_val = ptr[PCW + 1:2];
	endfunction
	function automatic [VALUEW - 1:0] Make_header;
		input reg signed [31:0] wosize;
		input reg signed [31:0] tag;
		reg [7:0] tag8;
		reg [15:0] wosize16;
		begin
			tag8 = tag;
			wosize16 = wosize;
			Make_header = {wosize16, 8'd0, tag8};
		end
	endfunction
	localparam signed [31:0] TAG_CLOSURE = 247;
	localparam signed [31:0] ZERO_DIVIDE_EXN = 5;
	reg [VALUEW - 1:0] env;
	reg [7:0] extra_args;
	reg [VALUEW - 1:0] oo_id;
	reg [6:0] state;
	assign state_out = state;
	reg [7:0] imm_b;
	reg [31:0] imm2;
	reg [15:0] alloc_i;
	reg [15:0] alloc_prefix;
	reg [7:0] alloc_nfuncs;
	reg [PCW - 1:0] alloc_table;
	reg [7:0] alloc_fn_i;
	reg [1:0] alloc_phase;
	reg [7:0] alloc_push_i;
	localparam signed [31:0] INFIX_TAG = 249;
	reg alloc_use_accu;
	reg [PCW - 1:0] alloc_code;
	reg alloc_push_result;
	reg alloc_then_return;
	reg [7:0] restart_n;
	localparam [VALUEW - 1:0] CLOSINFO = 32'h00000005;
	reg [VALUEW - 1:0] temp_arg1;
	reg [VALUEW - 1:0] temp_arg2;
	reg [VALUEW - 1:0] temp_arg3;
	reg [VALUEW - 1:0] temp_field1;
	reg [VALUEW - 1:0] temp_field2;
	reg [VALUEW - 1:0] temp_field3;
	reg [VALUEW - 1:0] temp_stack_val;
	reg [VALUEW - 1:0] temp_heap_val;
	reg [VALUEW - 1:0] temp_value;
	reg [VALUEW - 1:0] temp_index;
	reg [VALUEW - 1:0] temp_array_ptr;
	reg [VALUEW - 1:0] temp_base_ptr;
	reg [VALUEW - 1:0] temp_return_pc;
	reg [VALUEW - 1:0] temp_return_env;
	reg [7:0] temp_extra_args;
	reg [7:0] op_cycle_count;
	localparam [7:0] TRAP_IO_READ = 8'h01;
	localparam [7:0] TRAP_IO_WRITE = 8'h02;
	reg [15:0] str_words;
	reg [1:0] str_byte;
	reg [7:0] byte_value;
	reg streq_negate;
	reg [HEAP_AW - 1:0] str2_addr;
	localparam signed [31:0] STRING_TAG = 252;
	reg [31:0] div_quo;
	reg [31:0] div_rem;
	reg [31:0] div_dsr;
	reg [5:0] div_bits_left;
	reg div_quo_negative;
	reg div_rem_negative;
	reg div_want_mod;
	reg [6:0] next_state_after_mem;
	reg [STACK_AW - 1:0] temp_stack_addr;
	reg [HEAP_AW - 1:0] temp_heap_addr;
	reg [GLOBALS_AW - 1:0] temp_globals_addr;
	reg [VALUEW - 1:0] globals_mem [0:(1 << GLOBALS_AW) - 1];
	initial begin
		if (HEAP_INIT != "")
			$readmemh(HEAP_INIT, heap_mem);
		if (GLOBALS_INIT != "")
			$readmemh(GLOBALS_INIT, globals_mem);
	end
	reg st_re_a;
	reg st_we_a;
	reg st_re_b;
	reg [STACK_AW - 1:0] st_addr_a;
	reg [STACK_AW - 1:0] st_addr_b;
	reg [VALUEW - 1:0] st_wd_a;
	reg [VALUEW - 1:0] st_rd_a;
	reg [VALUEW - 1:0] st_rd_b;
	reg hm_re_a;
	reg hm_we_a;
	reg hm_re_b;
	reg [HEAP_AW - 1:0] hm_addr_a;
	reg [HEAP_AW - 1:0] hm_addr_b;
	reg [VALUEW - 1:0] hm_wd_a;
	reg [VALUEW - 1:0] hm_rd_a;
	reg [VALUEW - 1:0] hm_rd_b;
	reg gm_re_a;
	reg gm_we_a;
	reg gm_re_b;
	reg [GLOBALS_AW - 1:0] gm_addr_a;
	reg [GLOBALS_AW - 1:0] gm_addr_b;
	reg [VALUEW - 1:0] gm_wd_a;
	reg [VALUEW - 1:0] gm_rd_a;
	reg [VALUEW - 1:0] gm_rd_b;
	reg rd_phase;
	reg [VALUEW - 1:0] tos_q;
	reg st_a_was_tos;
	assign tos = tos_q;
	assign closure_codeptr = alloc_code;
	assign closure_nvars = nvars[7:0];
	assign closure_i = alloc_i[7:0];
	task automatic stack_read_a;
		input reg [STACK_AW - 1:0] a;
		begin
			st_re_a = 1'b1;
			st_addr_a = a;
		end
	endtask
	task automatic stack_read_b;
		input reg [STACK_AW - 1:0] a;
		begin
			st_re_b = 1'b1;
			st_addr_b = a;
		end
	endtask
	task automatic heap_read_a;
		input reg [HEAP_AW - 1:0] a;
		begin
			hm_re_a = 1'b1;
			hm_addr_a = a;
		end
	endtask
	task automatic heap_read_b;
		input reg [HEAP_AW - 1:0] a;
		begin
			hm_re_b = 1'b1;
			hm_addr_b = a;
		end
	endtask
	task automatic globals_read_a;
		input reg [GLOBALS_AW - 1:0] a;
		begin
			gm_re_a = 1'b1;
			gm_addr_a = a;
		end
	endtask
	task automatic stack_write;
		input reg [STACK_AW - 1:0] a;
		input reg [VALUEW - 1:0] d;
		if (!st_re_a && !st_we_a) begin
			st_we_a = 1'b1;
			st_addr_a = a;
			st_wd_a = d;
		end
	endtask
	task automatic heap_write;
		input reg [HEAP_AW - 1:0] a;
		input reg [VALUEW - 1:0] d;
		if (!hm_re_a && !hm_we_a) begin
			hm_we_a = 1'b1;
			hm_addr_a = a;
			hm_wd_a = d;
		end
	endtask
	task automatic globals_write;
		input reg [GLOBALS_AW - 1:0] a;
		input reg [VALUEW - 1:0] d;
		if (!gm_re_a && !gm_we_a) begin
			gm_we_a = 1'b1;
			gm_addr_a = a;
			gm_wd_a = d;
		end
	endtask
	task automatic hold_for_read;
		begin
			rd_phase <= 1'b1;
			state <= state;
		end
	endtask
	reg uncaught_exn;
	always @(posedge clk)
		if (reset)
			halted <= 1'b0;
		else if (((opcode == 8'd143) && (state == 7'd3)) || uncaught_exn)
			halted <= 1'b1;
	task read_acc_from_heap;
		input [31:0] ptr_value;
		input [31:0] offset_used;
		if (!rd_phase) begin
			heap_read_a(Heap_index_of_ptr(ptr_value) + offset_used);
			hold_for_read;
		end
		else
			accu <= hm_rd_a;
	endtask
	task caml_ml_open_descriptor_in;
		begin
			$display("caml_ml_open_descriptor_in");
			accu <= 32'hc0010000;
		end
	endtask
	task caml_ml_open_descriptor_out;
		begin
			$display("caml_ml_open_descriptor_out");
			accu <= 32'hf00d0000;
		end
	endtask
	task caml_ml_output_char;
		begin
			$display("caml_ml_output_char %c (%d)", Int_val(st_rd_a), Int_val(st_rd_a));
			putc_valid <= 1'b1;
			putc_char <= st_rd_a[8:1];
			accu <= Val_int(0);
		end
	endtask
	task caml_ml_flush;
		begin
			$display("caml_ml_flush");
			accu <= Val_int(0);
		end
	endtask
	task caml_string_get;
		begin
			$display("caml_string_get %x %x", accu, Int_val(st_rd_a));
			temp_heap_addr <= (Heap_index_of_ptr(accu) + 1) + st_rd_a[HEAP_AW + 2:3];
			str_byte <= st_rd_a[2:1];
			state <= 7'd80;
		end
	endtask
	task automatic div_start;
		input reg signed [31:0] dividend;
		input reg signed [31:0] divisor;
		input reg want_mod;
		begin
			div_quo <= (dividend[31] ? -dividend : dividend);
			div_dsr <= (divisor[31] ? -divisor : divisor);
			div_rem <= 1'sb0;
			div_bits_left <= 6'd32;
			div_quo_negative <= dividend[31] ^ divisor[31];
			div_rem_negative <= dividend[31];
			div_want_mod <= want_mod;
		end
	endtask
	always @(*) begin
		if (_sv2v_0)
			;
		case (opcode)
			8'd63: alloc_need = 2;
			8'd64: alloc_need = 3;
			8'd65: alloc_need = 4;
			8'd62: alloc_need = alloc_wosize + 1;
			8'd43: alloc_need = 3 + nvars;
			8'd44: alloc_need = (3 * imm) + nvars;
			8'd42: alloc_need = (extra_args < imm ? 5 + extra_args : 0);
			8'd93: alloc_need = (imm == 16'h0052 ? (Int_val(accu) >> 2) + 2 : 0);
			default: alloc_need = 0;
		endcase
	end
	function automatic [7:0] sv2v_cast_8;
		input reg [7:0] inp;
		sv2v_cast_8 = inp;
	endfunction
	always @(posedge clk) begin
		st_re_a = 1'b0;
		st_we_a = 1'b0;
		st_re_b = 1'b0;
		st_addr_a = 1'sb0;
		st_addr_b = 1'sb0;
		st_wd_a = 1'sb0;
		hm_re_a = 1'b0;
		hm_we_a = 1'b0;
		hm_re_b = 1'b0;
		hm_addr_a = 1'sb0;
		hm_addr_b = 1'sb0;
		hm_wd_a = 1'sb0;
		gm_re_a = 1'b0;
		gm_we_a = 1'b0;
		gm_re_b = 1'b0;
		gm_addr_a = 1'sb0;
		gm_addr_b = 1'sb0;
		gm_wd_a = 1'sb0;
		putc_valid <= 1'b0;
		if (reset && load_we) begin
			if (load_globals) begin
				gm_we_a = 1'b1;
				gm_addr_a = load_addr[GLOBALS_AW - 1:0];
				gm_wd_a = load_data;
			end
			else begin
				hm_we_a = 1'b1;
				hm_addr_a = load_addr;
				hm_wd_a = load_data;
			end
		end
		if (reset) begin
			putc_char <= 1'sb0;
			trap_valid <= 1'b0;
			trap_prim <= 1'sb0;
			trap_arg0 <= 1'sb0;
			trap_arg1 <= 1'sb0;
			rd_phase <= 1'b0;
			tos_q <= 1'sb0;
			st_a_was_tos <= 1'b0;
			state <= 7'd0;
			pc <= 1'sb0;
			opcode <= 8'd143;
			imm <= 1'sb0;
			imm_b <= 1'sb0;
			imm2 <= 1'sb0;
			nvars <= 1'sb0;
			offset <= 1'sb0;
			alloc_wosize <= 1'sb0;
			alloc_tag <= 1'sb0;
			accu <= VAL_UNIT;
			env <= 1'sb0;
			extra_args <= 8'd0;
			temp_arg1 <= 1'sb0;
			temp_arg2 <= 1'sb0;
			temp_arg3 <= 1'sb0;
			temp_field1 <= 1'sb0;
			temp_field2 <= 1'sb0;
			temp_field3 <= 1'sb0;
			temp_stack_val <= 1'sb0;
			temp_heap_val <= 1'sb0;
			temp_return_pc <= 1'sb0;
			temp_return_env <= 1'sb0;
			temp_extra_args <= 1'sb0;
			op_cycle_count <= 1'sb0;
			next_state_after_mem <= 7'd4;
			temp_stack_addr <= 1'sb0;
			temp_heap_addr <= 1'sb0;
			temp_globals_addr <= 1'sb0;
			sp <= (1 << STACK_AW) - 1;
			trapsp <= (1 << STACK_AW) - 1;
			oo_id <= 0;
			uncaught_exn <= 1'b0;
			heap_lo <= heap_base;
			gc_semi <= semi_space;
			from_lo <= heap_base;
			hp <= heap_base;
			hp_limit <= heap_base + semi_space;
			gc_count <= 0;
		end
		else if (!halted) begin
			rd_phase <= 1'b0;
			(* full_case, parallel_case *)
			case (state)
				7'd0:
					if (!code_valid)
						;
					else begin
						opcode <= code_rdata[7:0];
						imm <= 1'sb0;
						nvars <= 1'sb0;
						offset <= 1'sb0;
						alloc_wosize <= 1'sb0;
						alloc_tag <= 1'sb0;
						$display("  at fetch, acc=0x%08x, pc=%d, bytecode=%d", accu, pc, code_rdata);
						pc <= pc + 1;
						state <= 7'd1;
					end
				7'd1:
					if (opcode_has_imm8(opcode))
						state <= 7'd2;
					else if (opcode_has_imm16(opcode) || (opcode == 8'd44)) begin
						state <= 7'd2;
						if (opcode == 8'd43) begin
							nvars <= code_rdata;
							pc <= pc + 1;
						end
						else if (opcode == 8'd44) begin
							imm <= code_rdata;
							pc <= pc + 1;
						end
						else if (opcode == 8'd62) begin
							alloc_wosize <= code_rdata;
							pc <= pc + 1;
						end
						else if ((((((((opcode == 8'd131) || (opcode == 8'd132)) || (opcode == 8'd133)) || (opcode == 8'd134)) || (opcode == 8'd135)) || (opcode == 8'd136)) || (opcode == 8'd139)) || (opcode == 8'd140)) begin
							imm <= code_rdata;
							pc <= pc + 1;
						end
						else begin
							imm <= code_rdata;
							pc <= pc + 1;
						end
					end
					else
						state <= 7'd3;
				7'd2:
					if (!code_valid)
						;
					else if (opcode == 8'd44) begin
						nvars <= code_rdata;
						pc <= pc + 1;
						state <= 7'd3;
					end
					else if (opcode == 8'd43) begin
						offset <= code_rdata;
						pc <= pc + 1;
						state <= 7'd3;
					end
					else if (opcode == 8'd62) begin
						alloc_tag <= code_rdata;
						pc <= pc + 1;
						state <= 7'd3;
					end
					else if (((((((((((opcode == 8'd131) || (opcode == 8'd132)) || (opcode == 8'd85)) || (opcode == 8'd133)) || (opcode == 8'd134)) || (opcode == 8'd86)) || (opcode == 8'd135)) || (opcode == 8'd136)) || (opcode == 8'd84)) || (opcode == 8'd139)) || (opcode == 8'd140)) begin
						offset <= code_rdata;
						pc <= pc + 1;
						state <= 7'd3;
					end
					else if (opcode_has_imm16(opcode)) begin
						imm2 <= code_rdata;
						pc <= pc + 1;
						state <= 7'd3;
					end
					else begin
						imm <= code_rdata;
						pc <= pc + 1;
						state <= 7'd3;
					end
				7'd3: begin
					state <= 7'd4;
					if ((!rd_phase && (alloc_need != 0)) && (({1'b0, hp} + alloc_need) > hp_limit)) begin
						gc_need <= alloc_need;
						state <= 7'd54;
					end
					else
						(* full_case, parallel_case *)
						case (opcode)
							8'd0: begin
								temp_stack_addr <= sp + 0;
								next_state_after_mem <= 7'd4;
								state <= 7'd5;
							end
							8'd1: begin
								temp_stack_addr <= sp + 1;
								next_state_after_mem <= 7'd4;
								state <= 7'd5;
							end
							8'd2: begin
								temp_stack_addr <= sp + 2;
								next_state_after_mem <= 7'd4;
								state <= 7'd5;
							end
							8'd3: begin
								temp_stack_addr <= sp + 3;
								next_state_after_mem <= 7'd4;
								state <= 7'd5;
							end
							8'd4: begin
								temp_stack_addr <= sp + 4;
								next_state_after_mem <= 7'd4;
								state <= 7'd5;
							end
							8'd5: begin
								temp_stack_addr <= sp + 5;
								next_state_after_mem <= 7'd4;
								state <= 7'd5;
							end
							8'd6: begin
								temp_stack_addr <= sp + 6;
								next_state_after_mem <= 7'd4;
								state <= 7'd5;
							end
							8'd7: begin
								temp_stack_addr <= sp + 7;
								next_state_after_mem <= 7'd4;
								state <= 7'd5;
							end
							8'd8: begin
								temp_stack_addr <= sp + imm;
								next_state_after_mem <= 7'd4;
								state <= 7'd5;
							end
							8'd32: begin
								extra_args <= imm - 1;
								temp_heap_addr <= Heap_index_of_ptr(accu) + 1;
								state <= 7'd6;
								next_state_after_mem <= 7'd33;
							end
							8'd33:
								if (!rd_phase) begin
									stack_read_a(sp);
									hold_for_read;
								end
								else begin
									stack_write(sp - 3, st_rd_a);
									op_cycle_count <= 0;
									state <= 7'd32;
								end
							8'd31: begin
								op_cycle_count <= 0;
								state <= 7'd44;
							end
							8'd34, 8'd35:
								if (!rd_phase) begin
									stack_read_a(sp);
									stack_read_b(sp + 1);
									hold_for_read;
								end
								else begin
									stack_write(sp - 3, st_rd_a);
									temp_arg2 <= st_rd_b;
									op_cycle_count <= 0;
									state <= (opcode == 8'd34 ? 7'd34 : 7'd36);
								end
							8'd37:
								if (!rd_phase) begin
									stack_read_a(sp);
									hold_for_read;
								end
								else begin
									temp_arg1 <= st_rd_a;
									sp <= (sp + imm) - 1;
									state <= 7'd21;
								end
							8'd38: begin
								temp_stack_addr <= sp;
								imm_b <= 2;
								op_cycle_count <= 0;
								state <= 7'd23;
							end
							8'd36: begin
								op_cycle_count <= imm - 1;
								state <= 7'd53;
							end
							8'd39: begin
								temp_stack_addr <= sp;
								imm_b <= 3;
								op_cycle_count <= 0;
								state <= 7'd26;
							end
							8'd109: accu <= Val_int(-Int_val(accu));
							8'd110:
								if (!rd_phase) begin
									stack_read_a(sp);
									hold_for_read;
								end
								else begin
									accu <= Val_int(Int_val(accu) + Int_val(st_rd_a));
									sp <= sp + 1;
								end
							8'd111:
								if (!rd_phase) begin
									stack_read_a(sp);
									hold_for_read;
								end
								else begin
									accu <= Val_int(Int_val(accu) - Int_val(st_rd_a));
									sp <= sp + 1;
								end
							8'd112:
								if (!rd_phase) begin
									stack_read_a(sp);
									hold_for_read;
								end
								else begin
									mul_a <= Int_val(accu);
									mul_b <= Int_val(st_rd_a);
									sp <= sp + 1;
									state <= 7'd72;
								end
							8'd113:
								if (!rd_phase) begin
									stack_read_a(sp);
									hold_for_read;
								end
								else begin
									sp <= sp + 1;
									if (Int_val(st_rd_a) == 0)
										state <= 7'd87;
									else begin
										div_start(Int_val(accu), Int_val(st_rd_a), 1'b0);
										state <= 7'd71;
									end
								end
							8'd114:
								if (!rd_phase) begin
									stack_read_a(sp);
									hold_for_read;
								end
								else begin
									sp <= sp + 1;
									if (Int_val(st_rd_a) == 0)
										state <= 7'd87;
									else begin
										div_start(Int_val(accu), Int_val(st_rd_a), 1'b1);
										state <= 7'd71;
									end
								end
							8'd115:
								if (!rd_phase) begin
									stack_read_a(sp);
									hold_for_read;
								end
								else begin
									accu <= Val_int(Int_val(accu) & Int_val(st_rd_a));
									sp <= sp + 1;
								end
							8'd116:
								if (!rd_phase) begin
									stack_read_a(sp);
									hold_for_read;
								end
								else begin
									accu <= Val_int(Int_val(accu) | Int_val(st_rd_a));
									sp <= sp + 1;
								end
							8'd117:
								if (!rd_phase) begin
									stack_read_a(sp);
									hold_for_read;
								end
								else begin
									accu <= Val_int(Int_val(accu) ^ Int_val(st_rd_a));
									sp <= sp + 1;
								end
							8'd118:
								if (!rd_phase) begin
									stack_read_a(sp);
									hold_for_read;
								end
								else begin
									accu <= Val_int(Int_val(accu) << Int_val(st_rd_a));
									sp <= sp + 1;
								end
							8'd119:
								if (!rd_phase) begin
									stack_read_a(sp);
									hold_for_read;
								end
								else begin
									accu <= Val_int(Int_val(accu) >>> Int_val(st_rd_a));
									sp <= sp + 1;
								end
							8'd120:
								if (!rd_phase) begin
									stack_read_a(sp);
									hold_for_read;
								end
								else begin
									accu <= Val_int($signed(Int_val(accu)) >>> Int_val(st_rd_a));
									sp <= sp + 1;
								end
							8'd121:
								if (!rd_phase) begin
									stack_read_a(sp);
									hold_for_read;
								end
								else begin
									accu <= (accu == st_rd_a ? VAL_TRUE : VAL_FALSE);
									sp <= sp + 1;
								end
							8'd122:
								if (!rd_phase) begin
									stack_read_a(sp);
									hold_for_read;
								end
								else begin
									accu <= (accu != st_rd_a ? VAL_TRUE : VAL_FALSE);
									sp <= sp + 1;
								end
							8'd123:
								if (!rd_phase) begin
									stack_read_a(sp);
									hold_for_read;
								end
								else begin
									accu <= (Int_val(accu) < Int_val(st_rd_a) ? VAL_TRUE : VAL_FALSE);
									sp <= sp + 1;
								end
							8'd124:
								if (!rd_phase) begin
									stack_read_a(sp);
									hold_for_read;
								end
								else begin
									accu <= (Int_val(accu) <= Int_val(st_rd_a) ? VAL_TRUE : VAL_FALSE);
									sp <= sp + 1;
								end
							8'd125:
								if (!rd_phase) begin
									stack_read_a(sp);
									hold_for_read;
								end
								else begin
									accu <= (Int_val(accu) > Int_val(st_rd_a) ? VAL_TRUE : VAL_FALSE);
									sp <= sp + 1;
								end
							8'd126:
								if (!rd_phase) begin
									stack_read_a(sp);
									hold_for_read;
								end
								else begin
									accu <= (Int_val(accu) >= Int_val(st_rd_a) ? VAL_TRUE : VAL_FALSE);
									sp <= sp + 1;
								end
							8'd99: accu <= Val_int(0);
							8'd100: accu <= Val_int(1);
							8'd101: accu <= Val_int(2);
							8'd102: accu <= Val_int(3);
							8'd103: accu <= Val_int($signed(imm));
							8'd127: accu <= Val_int(Int_val(accu) + $signed(imm));
							8'd104: begin
								sp <= sp - 1;
								stack_write(sp - 1, accu);
								accu <= Val_int(0);
							end
							8'd105: begin
								sp <= sp - 1;
								stack_write(sp - 1, accu);
								accu <= Val_int(1);
							end
							8'd106: begin
								sp <= sp - 1;
								stack_write(sp - 1, accu);
								accu <= Val_int(2);
							end
							8'd107: begin
								sp <= sp - 1;
								stack_write(sp - 1, accu);
								accu <= Val_int(3);
							end
							8'd108: begin
								sp <= sp - 1;
								stack_write(sp - 1, accu);
								accu <= Val_int($signed(imm));
							end
							8'd20: begin
								stack_write(sp + imm, accu);
								accu <= VAL_UNIT;
								state <= 7'd4;
							end
							8'd88: accu <= (accu == VAL_FALSE ? VAL_TRUE : VAL_FALSE);
							8'd84: pc <= (pc + $signed(offset)) - 1;
							8'd85:
								if (accu != VAL_FALSE)
									pc <= (pc + $signed(offset)) - 1;
							8'd86:
								if (accu == VAL_FALSE)
									pc <= (pc + $signed(offset)) - 1;
							8'd131:
								if ($signed(imm) == Int_val(accu))
									pc <= (pc + $signed(offset)) - 1;
							8'd132:
								if ($signed(imm) != Int_val(accu))
									pc <= (pc + $signed(offset)) - 1;
							8'd133:
								if ($signed(imm) < Int_val(accu))
									pc <= (pc + $signed(offset)) - 1;
							8'd134:
								if ($signed(imm) <= Int_val(accu))
									pc <= (pc + $signed(offset)) - 1;
							8'd135:
								if ($signed(imm) > Int_val(accu))
									pc <= (pc + $signed(offset)) - 1;
							8'd136:
								if ($signed(imm) >= Int_val(accu))
									pc <= (pc + $signed(offset)) - 1;
							8'd139:
								if ($unsigned($signed(imm)) < $unsigned(Int_val(accu)))
									pc <= (pc + $signed(offset)) - 1;
							8'd140:
								if ($unsigned($signed(imm)) >= $unsigned(Int_val(accu)))
									pc <= (pc + $signed(offset)) - 1;
							8'd87:
								if (accu[0]) begin
									temp_index <= Int_val(accu);
									pc <= pc + Int_val(accu);
									state <= 7'd65;
								end
								else begin
									temp_heap_addr <= Heap_index_of_ptr(accu);
									state <= 7'd64;
								end
							8'd42:
								if (extra_args >= imm)
									extra_args <= extra_args - imm;
								else begin
									alloc_wosize <= 4 + extra_args;
									alloc_tag <= TAG_CLOSURE;
									alloc_prefix <= 3;
									alloc_nfuncs <= 0;
									alloc_use_accu <= 1'b0;
									alloc_code <= pc - 3;
									alloc_push_result <= 1'b0;
									alloc_then_return <= 1'b1;
									state <= 7'd49;
								end
							8'd41: begin
								temp_heap_addr <= Heap_index_of_ptr(env);
								state <= 7'd68;
							end
							8'd143: state <= 7'd4;
							8'd21: begin
								temp_heap_addr <= Heap_index_of_ptr(env) + 2;
								next_state_after_mem <= 7'd4;
								state <= 7'd6;
								next_state_after_mem <= 7'd10;
							end
							8'd22: begin
								temp_heap_addr <= Heap_index_of_ptr(env) + 3;
								state <= 7'd6;
								next_state_after_mem <= 7'd10;
							end
							8'd23: begin
								temp_heap_addr <= Heap_index_of_ptr(env) + 4;
								state <= 7'd6;
								next_state_after_mem <= 7'd10;
							end
							8'd24: begin
								temp_heap_addr <= Heap_index_of_ptr(env) + 5;
								state <= 7'd6;
								next_state_after_mem <= 7'd10;
							end
							8'd25: begin
								temp_heap_addr <= (Heap_index_of_ptr(env) + 1) + imm;
								state <= 7'd6;
								next_state_after_mem <= 7'd10;
							end
							8'd67: begin
								temp_heap_addr <= Heap_index_of_ptr(accu) + 1;
								state <= 7'd6;
								next_state_after_mem <= 7'd11;
							end
							8'd68: begin
								temp_heap_addr <= Heap_index_of_ptr(accu) + 2;
								state <= 7'd6;
								next_state_after_mem <= 7'd11;
							end
							8'd69: begin
								temp_heap_addr <= Heap_index_of_ptr(accu) + 3;
								state <= 7'd6;
								next_state_after_mem <= 7'd11;
							end
							8'd70: begin
								temp_heap_addr <= Heap_index_of_ptr(accu) + 4;
								state <= 7'd6;
								next_state_after_mem <= 7'd11;
							end
							8'd71: begin
								temp_heap_addr <= (Heap_index_of_ptr(accu) + 1) + imm;
								state <= 7'd6;
								next_state_after_mem <= 7'd11;
							end
							8'd89: begin
								op_cycle_count <= 0;
								state <= 7'd82;
							end
							8'd90: state <= 7'd83;
							8'd91, 8'd146, 8'd147: state <= 7'd84;
							8'd53: begin
								temp_globals_addr <= imm[GLOBALS_AW - 1:0];
								state <= 7'd7;
								next_state_after_mem <= 7'd4;
							end
							8'd57: begin
								globals_write(imm[GLOBALS_AW - 1:0], accu);
								accu <= VAL_UNIT;
								state <= 7'd4;
							end
							8'd62, 8'd63, 8'd64, 8'd65: begin
								if (opcode != 8'd62) begin
									alloc_wosize <= (opcode == 8'd63 ? 1 : (opcode == 8'd64 ? 2 : 3));
									alloc_tag <= imm;
								end
								alloc_prefix <= 0;
								alloc_nfuncs <= 0;
								alloc_use_accu <= 1'b1;
								alloc_push_result <= 1'b0;
								alloc_then_return <= 1'b0;
								state <= 7'd49;
							end
							8'd128:
								if (!rd_phase) begin
									heap_read_a(Heap_index_of_ptr(accu) + 1);
									hold_for_read;
								end
								else begin
									heap_write(Heap_index_of_ptr(accu) + 1, hm_rd_a + (imm << 1));
									accu <= VAL_UNIT;
								end
							8'd19: begin
								sp <= sp + imm;
								state <= 7'd4;
							end
							8'd9: begin
								sp <= sp - 1;
								stack_write(sp - 1, accu);
								state <= 7'd4;
							end
							8'd10: begin
								temp_stack_addr <= sp - 1;
								state <= 7'd8;
							end
							8'd11: begin
								temp_stack_addr <= sp + 0;
								state <= 7'd8;
							end
							8'd12: begin
								temp_stack_addr <= sp + 1;
								state <= 7'd8;
							end
							8'd13: begin
								temp_stack_addr <= sp + 2;
								state <= 7'd8;
							end
							8'd14: begin
								temp_stack_addr <= sp + 3;
								state <= 7'd8;
							end
							8'd15: begin
								temp_stack_addr <= sp + 4;
								state <= 7'd8;
							end
							8'd16: begin
								temp_stack_addr <= sp + 5;
								state <= 7'd8;
							end
							8'd17: begin
								temp_stack_addr <= sp + 6;
								state <= 7'd8;
							end
							8'd18: begin
								temp_stack_addr <= (sp + imm) - 1;
								state <= 7'd8;
							end
							8'd26: begin
								sp <= sp - 1;
								stack_write(sp - 1, accu);
								temp_heap_addr <= Heap_index_of_ptr(env) + 2;
								state <= 7'd6;
								next_state_after_mem <= 7'd10;
							end
							8'd27: begin
								sp <= sp - 1;
								stack_write(sp - 1, accu);
								temp_heap_addr <= Heap_index_of_ptr(env) + 3;
								state <= 7'd6;
								next_state_after_mem <= 7'd10;
							end
							8'd28: begin
								sp <= sp - 1;
								stack_write(sp - 1, accu);
								temp_heap_addr <= Heap_index_of_ptr(env) + 4;
								state <= 7'd6;
								next_state_after_mem <= 7'd10;
							end
							8'd29: begin
								sp <= sp - 1;
								stack_write(sp - 1, accu);
								temp_heap_addr <= Heap_index_of_ptr(env) + 5;
								state <= 7'd6;
								next_state_after_mem <= 7'd10;
							end
							8'd30: begin
								sp <= sp - 1;
								stack_write(sp - 1, accu);
								temp_heap_addr <= (Heap_index_of_ptr(env) + 1) + imm;
								state <= 7'd6;
								next_state_after_mem <= 7'd10;
							end
							8'd52: begin
								sp <= sp - 1;
								stack_write(sp - 1, accu);
								accu <= env + (imm << 2);
							end
							8'd40:
								if (extra_args != 0) begin
									sp <= sp + imm;
									extra_args <= extra_args - 1;
									temp_heap_addr <= Heap_index_of_ptr(accu) + 1;
									state <= 7'd6;
									next_state_after_mem <= 7'd33;
								end
								else begin
									op_cycle_count <= 0;
									state <= 7'd38;
								end
							8'd73:
								if (!rd_phase) begin
									stack_read_a(sp);
									hold_for_read;
								end
								else begin
									heap_write(Heap_index_of_ptr(accu) + 1, st_rd_a);
									sp <= sp + 1;
									accu <= VAL_UNIT;
									state <= 7'd4;
								end
							8'd74:
								if (!rd_phase) begin
									stack_read_a(sp);
									hold_for_read;
								end
								else begin
									heap_write(Heap_index_of_ptr(accu) + 2, st_rd_a);
									sp <= sp + 1;
									accu <= VAL_UNIT;
									state <= 7'd4;
								end
							8'd75:
								if (!rd_phase) begin
									stack_read_a(sp);
									hold_for_read;
								end
								else begin
									heap_write(Heap_index_of_ptr(accu) + 3, st_rd_a);
									sp <= sp + 1;
									accu <= VAL_UNIT;
									state <= 7'd4;
								end
							8'd76:
								if (!rd_phase) begin
									stack_read_a(sp);
									hold_for_read;
								end
								else begin
									heap_write(Heap_index_of_ptr(accu) + 4, st_rd_a);
									sp <= sp + 1;
									accu <= VAL_UNIT;
									state <= 7'd4;
								end
							8'd77:
								if (!rd_phase) begin
									stack_read_a(sp);
									hold_for_read;
								end
								else begin
									heap_write((Heap_index_of_ptr(accu) + 1) + imm, st_rd_a);
									sp <= sp + 1;
									accu <= VAL_UNIT;
									state <= 7'd4;
								end
							8'd79: begin
								temp_heap_addr <= Heap_index_of_ptr(accu);
								state <= 7'd6;
								next_state_after_mem <= 7'd45;
							end
							8'd148, 8'd82:
								if (!rd_phase) begin
									stack_read_a(sp);
									hold_for_read;
								end
								else begin
									temp_heap_addr <= (Heap_index_of_ptr(accu) + 1) + st_rd_a[HEAP_AW + 2:3];
									str_byte <= st_rd_a[2:1];
									sp <= sp + 1;
									state <= 7'd80;
								end
							8'd83:
								if (!rd_phase) begin
									stack_read_a(sp);
									stack_read_b(sp + 1);
									hold_for_read;
								end
								else begin
									temp_heap_addr <= (Heap_index_of_ptr(accu) + 1) + st_rd_a[HEAP_AW + 2:3];
									str_byte <= st_rd_a[2:1];
									byte_value <= st_rd_b[8:1];
									sp <= sp + 2;
									accu <= VAL_UNIT;
									state <= 7'd74;
								end
							8'd81:
								if (!rd_phase) begin
									stack_read_a(sp);
									stack_read_b(sp + 1);
									hold_for_read;
								end
								else begin
									temp_index <= Int_val(st_rd_a);
									temp_value <= st_rd_b;
									temp_base_ptr <= accu;
									state <= 7'd47;
								end
							8'd80:
								if (!rd_phase) begin
									stack_read_a(sp);
									hold_for_read;
								end
								else begin
									temp_index <= Int_val(st_rd_a);
									temp_array_ptr <= accu;
									sp <= sp + 1;
									temp_heap_addr <= (Heap_index_of_ptr(accu) + Int_val(st_rd_a)) + 1;
									state <= 7'd6;
									next_state_after_mem <= 7'd46;
								end
							8'd93:
								(* full_case, parallel_case *)
								case (imm)
									16'h00fd:
										caml_ml_flush;
									16'h0103:
										caml_ml_open_descriptor_in;
									16'h0104:
										caml_ml_open_descriptor_out;
									16'h0136:
										if (accu[0])
											state <= 7'd4;
										else begin
											temp_heap_addr <= Heap_index_of_ptr(accu);
											state <= 7'd66;
										end
									16'h0052: begin
										alloc_base <= hp;
										alloc_wosize <= (Int_val(accu) >> 2) + 1;
										temp_index <= Int_val(accu);
										heap_write(hp, Make_header((Int_val(accu) >> 2) + 1, STRING_TAG));
										alloc_i <= 0;
										state <= 7'd75;
									end
									16'h0164:
										;
									16'h00f7, 16'h0116: begin
										temp_heap_addr <= Heap_index_of_ptr(accu);
										state <= 7'd78;
									end
									16'h0193: begin
										trap_valid <= 1'b1;
										trap_prim <= TRAP_IO_READ;
										trap_arg0 <= Int_val(accu);
										state <= 7'd81;
									end
									16'h005a: accu <= VAL_UNIT;
									16'h0084: begin
										accu <= Val_int(oo_id);
										oo_id <= oo_id + 1;
									end
									default: begin
										$display("Unsupported C_CALL1: 0x%x", imm);
										accu <= VAL_UNIT;
									end
								endcase
							8'd94:
								if (!rd_phase) begin
									stack_read_a(sp);
									hold_for_read;
								end
								else begin
									(* full_case, parallel_case *)
									case (imm)
										16'h0108:
											caml_ml_output_char;
										16'h000d, 16'h000c: begin
											temp_heap_addr <= (Heap_index_of_ptr(accu) + 1) + st_rd_a[HEAP_AW:1];
											state <= 7'd6;
											next_state_after_mem <= 7'd11;
										end
										16'h015b, 16'h003a:
											caml_string_get;
										16'h015a, 16'h0163: begin
											temp_heap_addr <= Heap_index_of_ptr(accu);
											str2_addr <= Heap_index_of_ptr(st_rd_a);
											streq_negate <= imm == 16'h0163;
											state <= 7'd76;
										end
										16'h0194: begin
											trap_valid <= 1'b1;
											trap_prim <= TRAP_IO_WRITE;
											trap_arg0 <= Int_val(accu);
											trap_arg1 <= Int_val(st_rd_a);
											state <= 7'd81;
										end
										default: begin
											$display("Unsupported C_CALL2: 0x%x", imm);
											accu <= VAL_UNIT;
										end
									endcase
									sp = sp + 1;
								end
							8'd95:
								if (imm == 16'h0044) begin
									if (!rd_phase) begin
										stack_read_a(sp);
										stack_read_b(sp + 1);
										hold_for_read;
									end
									else begin
										temp_heap_addr <= (Heap_index_of_ptr(accu) + 1) + st_rd_a[HEAP_AW + 2:3];
										str_byte <= st_rd_a[2:1];
										byte_value <= st_rd_b[8:1];
										sp <= sp + 2;
										accu <= VAL_UNIT;
										state <= 7'd74;
									end
								end
								else if ((imm == 16'h000f) || (imm == 16'h000e)) begin
									if (!rd_phase) begin
										stack_read_a(sp);
										stack_read_b(sp + 1);
										hold_for_read;
									end
									else begin
										temp_index <= Int_val(st_rd_a);
										temp_value <= st_rd_b;
										temp_base_ptr <= accu;
										state <= 7'd47;
									end
								end
								else begin
									$display("Unsupported C_CALL3: 0x%x", imm);
									accu <= VAL_UNIT;
									sp = sp + 2;
								end
							8'd96: begin
								accu <= VAL_UNIT;
								sp = sp + 3;
							end
							8'd97: begin
								accu <= VAL_UNIT;
								sp = sp + 4;
							end
							8'd98: begin
								accu <= VAL_UNIT;
								sp = sp + imm;
							end
							8'd58:
								;
							8'd43: begin
								alloc_wosize <= 2 + nvars;
								alloc_tag <= TAG_CLOSURE;
								alloc_prefix <= 2;
								alloc_code <= ($signed(pc) + $signed(offset)) - 1;
								alloc_nfuncs <= 0;
								alloc_use_accu <= nvars != 0;
								alloc_push_result <= 1'b0;
								alloc_then_return <= 1'b0;
								state <= 7'd49;
							end
							8'd44: begin
								alloc_wosize <= ((3 * imm) - 1) + nvars;
								alloc_tag <= TAG_CLOSURE;
								alloc_prefix <= (3 * imm) - 1;
								alloc_nfuncs <= imm;
								alloc_table <= pc;
								alloc_use_accu <= nvars != 0;
								alloc_push_result <= 1'b1;
								alloc_then_return <= 1'b0;
								state <= 7'd49;
							end
							8'd46: accu <= env;
							8'd47: accu <= env + 12;
							8'd45: accu <= env - 12;
							8'd48: accu <= env + (imm << 2);
							8'd50: begin : sv2v_autoblock_1
								reg [31:0] old_sp;
								old_sp = sp;
								sp <= sp - 1;
								stack_write(old_sp - 1, accu);
								accu <= env;
							end
							8'd51: begin : sv2v_autoblock_2
								reg [31:0] old_sp;
								old_sp = sp;
								sp <= sp - 1;
								stack_write(old_sp - 1, accu);
								accu <= env + 12;
							end
							8'd49: begin : sv2v_autoblock_3
								reg [31:0] old_sp;
								old_sp = sp;
								sp <= sp - 1;
								stack_write(old_sp - 1, accu);
								accu <= env - 12;
							end
							8'd54:
								if (!rd_phase) begin
									globals_read_a(imm);
									hold_for_read;
								end
								else begin : sv2v_autoblock_4
									reg [31:0] old_sp;
									old_sp = sp;
									sp <= sp - 1;
									stack_write(old_sp - 1, accu);
									accu <= gm_rd_a;
								end
							8'd55, 8'd56:
								if (!rd_phase) begin
									globals_read_a(imm);
									hold_for_read;
								end
								else begin
									if (opcode == 8'd56) begin
										stack_write(sp - 1, accu);
										sp <= sp - 1;
									end
									temp_heap_addr <= (Heap_index_of_ptr(gm_rd_a) + 1) + imm2;
									state <= 7'd6;
									next_state_after_mem <= 7'd11;
								end
							8'd92:
								;
							default: begin
								$display("almost complete, unhandled ops go to trap instead of silently wrong behavior.");
								trap_valid <= 1'b1;
								trap_prim <= 8'hff;
								trap_arg0 <= Val_int(opcode);
								state <= 7'd48;
							end
						endcase
				end
				7'd54: begin
					to_lo <= (from_lo == heap_lo ? heap_lo + gc_semi : heap_lo);
					gc_free <= (from_lo == heap_lo ? heap_lo + gc_semi : heap_lo);
					gc_scan <= (from_lo == heap_lo ? heap_lo + gc_semi : heap_lo);
					gc_phase <= GC_ACCU;
					gc_i <= {1'b0, sp};
					gc_infix_off <= 0;
					state <= 7'd55;
				end
				7'd55:
					case (gc_phase)
						GC_ACCU, GC_ENV: begin
							gc_val <= (gc_phase == GC_ACCU ? accu : env);
							gc_return_to_scan <= 1'b0;
							if (gc_points_to_from((gc_phase == GC_ACCU ? accu : env)))
								state <= 7'd57;
							else
								gc_phase <= gc_phase + 1;
						end
						GC_STACK:
							if (gc_i >= ((1 << STACK_AW) - 1)) begin
								gc_i <= 0;
								gc_phase <= GC_GLOBALS;
							end
							else if (!rd_phase) begin
								stack_read_a(gc_i[STACK_AW - 1:0]);
								hold_for_read;
							end
							else begin
								gc_val <= st_rd_a;
								gc_return_to_scan <= 1'b0;
								if (gc_points_to_from(st_rd_a))
									state <= 7'd57;
								else
									gc_i <= gc_i + 1;
							end
						GC_GLOBALS:
							if (gc_i >= (1 << GLOBALS_AW))
								gc_phase <= GC_SCAN;
							else if (!rd_phase) begin
								globals_read_a(gc_i[GLOBALS_AW - 1:0]);
								hold_for_read;
							end
							else begin
								gc_val <= gm_rd_a;
								gc_return_to_scan <= 1'b0;
								if (gc_points_to_from(gm_rd_a))
									state <= 7'd57;
								else
									gc_i <= gc_i + 1;
							end
						default: state <= 7'd60;
					endcase
				7'd56: begin
					gc_infix_off <= 0;
					case (gc_phase)
						GC_ACCU: accu <= gc_new;
						GC_ENV: env <= gc_new;
						GC_STACK:
							stack_write(gc_i[STACK_AW - 1:0], gc_new);
						default:
							globals_write(gc_i[GLOBALS_AW - 1:0], gc_new);
					endcase
					if ((gc_phase == GC_ACCU) || (gc_phase == GC_ENV))
						gc_phase <= gc_phase + 1;
					else
						gc_i <= gc_i + 1;
					state <= 7'd55;
				end
				7'd57:
					if (!rd_phase) begin
						heap_read_a(gc_val[HEAP_AW + 1:2]);
						heap_read_b(gc_val[HEAP_AW + 1:2] + 1);
						hold_for_read;
					end
					else if (hm_rd_a[7:0] == INFIX_TAG) begin
						gc_val <= gc_val - {hm_rd_a[31:16], 2'b00};
						gc_infix_off <= gc_infix_off + hm_rd_a[31:16];
					end
					else if (hm_rd_a[15:8] == GC_FORWARDED) begin
						gc_new <= hm_rd_b + {gc_infix_off, 2'b00};
						state <= (gc_return_to_scan ? 7'd62 : 7'd56);
					end
					else begin
						heap_write(gc_free, hm_rd_a);
						gc_obj <= gc_val[HEAP_AW + 1:2];
						gc_hdr <= hm_rd_a;
						gc_size <= hm_rd_a[31:16];
						gc_new <= Ptr_of_heap_index(gc_free) + {gc_infix_off, 2'b00};
						gc_new_idx <= gc_free;
						gc_rd <= 0;
						gc_wr <= 0;
						gc_copy_valid <= 1'b0;
						state <= 7'd58;
					end
				7'd58: begin
					if (gc_copy_valid) begin
						heap_write((gc_new_idx + 1) + gc_wr, hm_rd_b);
						gc_wr <= gc_wr + 1;
					end
					if (gc_rd < gc_size) begin
						heap_read_b((gc_obj + 1) + gc_rd);
						gc_rd <= gc_rd + 1;
						gc_copy_valid <= 1'b1;
					end
					else
						gc_copy_valid <= 1'b0;
					if (((gc_wr + gc_copy_valid) == gc_size) && (gc_rd == gc_size)) begin
						gc_mark_second <= 1'b0;
						state <= 7'd59;
					end
				end
				7'd59:
					if (!gc_mark_second) begin
						heap_write(gc_obj, {gc_hdr[31:16], GC_FORWARDED, gc_hdr[7:0]});
						gc_mark_second <= 1'b1;
						if (gc_size == 0) begin
							gc_free <= gc_free + 1;
							state <= (gc_return_to_scan ? 7'd62 : 7'd56);
						end
					end
					else begin
						heap_write(gc_obj + 1, Ptr_of_heap_index(gc_new_idx));
						gc_free <= (gc_free + 1) + gc_size;
						state <= (gc_return_to_scan ? 7'd62 : 7'd56);
					end
				7'd60:
					if (gc_scan == gc_free)
						state <= 7'd63;
					else if (!rd_phase) begin
						heap_read_a(gc_scan);
						hold_for_read;
					end
					else if ((hm_rd_a[7:0] >= NO_SCAN_TAG) || (hm_rd_a[31:16] == 0))
						gc_scan <= (gc_scan + 1) + hm_rd_a[31:16];
					else begin
						gc_scan_size <= hm_rd_a[31:16];
						gc_j <= 0;
						state <= 7'd61;
					end
				7'd61:
					if (gc_j == gc_scan_size) begin
						gc_scan <= (gc_scan + 1) + gc_scan_size;
						state <= 7'd60;
					end
					else if (!rd_phase) begin
						heap_read_a((gc_scan + 1) + gc_j);
						hold_for_read;
					end
					else if (gc_points_to_from(hm_rd_a)) begin
						gc_val <= hm_rd_a;
						gc_return_to_scan <= 1'b1;
						state <= 7'd57;
					end
					else
						gc_j <= gc_j + 1;
				7'd62: begin
					gc_infix_off <= 0;
					heap_write((gc_scan + 1) + gc_j, gc_new);
					gc_j <= gc_j + 1;
					state <= 7'd61;
				end
				7'd63: begin
					from_lo <= to_lo;
					hp <= gc_free;
					hp_limit <= to_lo + gc_semi;
					gc_count <= gc_count + 1;
					if ((gc_free + gc_need) > (to_lo + gc_semi)) begin
						$display("GC: out of memory (%0d words live, %0d needed, semi-space %0d)", gc_free - to_lo, gc_need, gc_semi);
						trap_valid <= 1'b1;
						trap_prim <= 8'hf1;
						state <= 7'd48;
					end
					else
						state <= 7'd3;
				end
				7'd66:
					if (!rd_phase) begin
						heap_read_a(temp_heap_addr);
						hold_for_read;
					end
					else if ((({1'b0, hp} + hm_rd_a[31:16]) + 1) > hp_limit) begin
						gc_need <= hm_rd_a[31:16] + 1;
						state <= 7'd54;
					end
					else begin
						heap_write(hp, hm_rd_a);
						alloc_base <= hp;
						alloc_wosize <= hm_rd_a[31:16];
						alloc_i <= 0;
						state <= 7'd67;
					end
				7'd67:
					if (alloc_i == alloc_wosize) begin
						hp <= (alloc_base + 1) + alloc_wosize;
						accu <= Ptr_of_heap_index(alloc_base);
						state <= 7'd4;
					end
					else if (!rd_phase) begin
						heap_read_a((temp_heap_addr + 1) + alloc_i);
						hold_for_read;
					end
					else begin
						heap_write((alloc_base + 1) + alloc_i, hm_rd_a);
						alloc_i <= alloc_i + 1;
					end
				7'd68:
					if (!rd_phase) begin
						heap_read_a(temp_heap_addr);
						hold_for_read;
					end
					else begin
						restart_n <= hm_rd_a[31:16] - 3;
						sp <= sp - (hm_rd_a[31:16] - 3);
						alloc_i <= 0;
						state <= 7'd69;
					end
				7'd69:
					if (alloc_i == restart_n)
						state <= 7'd70;
					else if (!rd_phase) begin
						heap_read_a((Heap_index_of_ptr(env) + 4) + alloc_i);
						hold_for_read;
					end
					else begin
						stack_write(sp + alloc_i, hm_rd_a);
						alloc_i <= alloc_i + 1;
					end
				7'd70:
					if (!rd_phase) begin
						heap_read_a(Heap_index_of_ptr(env) + 3);
						hold_for_read;
					end
					else begin
						env <= hm_rd_a;
						extra_args <= extra_args + restart_n;
						state <= 7'd4;
					end
				7'd64:
					if (!rd_phase) begin
						heap_read_a(temp_heap_addr);
						hold_for_read;
					end
					else begin
						temp_index <= imm[15:0] + hm_rd_a[7:0];
						pc <= (pc + imm[15:0]) + hm_rd_a[7:0];
						state <= 7'd65;
					end
				7'd65:
					if (!code_valid)
						;
					else begin
						pc <= (pc - temp_index) + $signed(code_rdata);
						state <= 7'd4;
					end
				7'd45: begin
					accu <= Val_long(Wosize_hd(temp_heap_val));
					state <= 7'd4;
				end
				7'd49: begin
					heap_write(hp, Make_header(alloc_wosize, alloc_tag));
					alloc_base <= hp;
					alloc_i <= 0;
					alloc_fn_i <= 0;
					alloc_phase <= 1;
					alloc_push_i <= 0;
					state <= 7'd50;
				end
				7'd50: begin : sv2v_autoblock_5
					reg [15:0] item;
					reg [15:0] stack_item;
					reg field_is_accu;
					reg field_from_stack;
					reg [VALUEW - 1:0] prefix_field;
					reg rec_code_field;
					item = alloc_i - alloc_prefix;
					field_is_accu = ((alloc_i >= alloc_prefix) && alloc_use_accu) && (item == 0);
					field_from_stack = (alloc_i >= alloc_prefix) && !field_is_accu;
					stack_item = (alloc_use_accu ? item - 1 : item);
					if (alloc_nfuncs != 0)
						case (alloc_phase)
							2'd0: prefix_field = Make_header(3 * alloc_fn_i, INFIX_TAG);
							2'd1: prefix_field = Make_codeptr($signed(alloc_table) + $signed(code_rdata));
							default: prefix_field = (((3 * (alloc_nfuncs - alloc_fn_i)) - 1) << 1) | 1;
						endcase
					else
						prefix_field = (alloc_i == 0 ? Make_codeptr(alloc_code) : (alloc_i == 1 ? CLOSINFO : env));
					rec_code_field = ((alloc_nfuncs != 0) && (alloc_i < alloc_prefix)) && (alloc_phase == 1);
					if (alloc_i == alloc_wosize)
						state <= 7'd51;
					else if (field_from_stack && !rd_phase) begin
						stack_read_a(sp + stack_item);
						hold_for_read;
					end
					else if (rec_code_field && (!rd_phase || !code_valid)) begin
						pc <= alloc_table + alloc_fn_i;
						hold_for_read;
					end
					else begin
						heap_write((alloc_base + 1) + alloc_i, (alloc_i < alloc_prefix ? prefix_field : (field_is_accu ? accu : st_rd_a)));
						alloc_i <= alloc_i + 1;
						alloc_phase <= (alloc_phase == 2 ? 2'd0 : alloc_phase + 1);
						if (alloc_phase == 2)
							alloc_fn_i <= alloc_fn_i + 1;
					end
				end
				7'd51: begin : sv2v_autoblock_6
					reg [STACK_AW - 1:0] sp_after;
					sp_after = sp + ((alloc_wosize - alloc_prefix) - alloc_use_accu);
					hp <= (alloc_base + 1) + alloc_wosize;
					accu <= Ptr_of_heap_index(alloc_base);
					sp <= sp_after;
					if (alloc_nfuncs != 0)
						pc <= alloc_table + alloc_nfuncs;
					if (alloc_push_result)
						state <= 7'd52;
					else if (alloc_then_return) begin
						imm <= 0;
						op_cycle_count <= 0;
						state <= 7'd38;
					end
					else
						state <= 7'd4;
				end
				7'd52:
					if (alloc_push_i == alloc_nfuncs)
						state <= 7'd4;
					else begin
						stack_write(sp - 1, Ptr_of_heap_index(alloc_base + (3 * alloc_push_i)));
						sp <= sp - 1;
						alloc_push_i <= alloc_push_i + 1;
					end
				7'd72: begin
					mul_p <= mul_a * mul_b;
					state <= 7'd73;
				end
				7'd73: begin
					accu <= Val_int(mul_p[VALUEW - 2:0]);
					state <= 7'd4;
				end
				7'd71: begin : sv2v_autoblock_7
					reg [32:0] trial;
					reg divisor_fits;
					reg divide_by_zero;
					reg [31:0] quotient;
					reg [31:0] remainder;
					trial = {div_rem, div_quo[31]} - {1'b0, div_dsr};
					divisor_fits = !trial[32];
					if (div_bits_left != 0) begin
						div_rem <= (divisor_fits ? trial[31:0] : {div_rem[30:0], div_quo[31]});
						div_quo <= {div_quo[30:0], divisor_fits};
						div_bits_left <= div_bits_left - 1;
					end
					else begin
						divide_by_zero = div_dsr == 0;
						quotient = (div_quo_negative ? -div_quo : div_quo);
						remainder = (div_rem_negative ? -div_rem : div_rem);
						accu <= Val_int((divide_by_zero ? 32'd0 : (div_want_mod ? remainder : quotient)));
						state <= 7'd4;
					end
				end
				7'd78:
					if (!rd_phase) begin
						heap_read_a(temp_heap_addr);
						hold_for_read;
					end
					else begin
						str_words <= hm_rd_a[31:16];
						temp_heap_addr <= temp_heap_addr + hm_rd_a[31:16];
						state <= 7'd79;
					end
				7'd79:
					if (!rd_phase) begin
						heap_read_a(temp_heap_addr);
						hold_for_read;
					end
					else begin
						accu <= Val_int(({str_words, 2'b00} - 1) - hm_rd_a[31:24]);
						state <= 7'd4;
					end
				7'd74:
					if (!rd_phase) begin
						heap_read_a(temp_heap_addr);
						hold_for_read;
					end
					else begin : sv2v_autoblock_8
						reg [VALUEW - 1:0] word;
						word = hm_rd_a;
						word[8 * str_byte+:8] = byte_value;
						heap_write(temp_heap_addr, word);
						state <= 7'd4;
					end
				7'd75:
					if (alloc_i == alloc_wosize) begin
						hp <= (alloc_base + 1) + alloc_wosize;
						accu <= Ptr_of_heap_index(alloc_base);
						state <= 7'd4;
					end
					else begin
						heap_write((alloc_base + 1) + alloc_i, (alloc_i == (alloc_wosize - 1) ? {sv2v_cast_8(((4 * alloc_wosize) - 1) - temp_index), 24'd0} : {32 {1'sb0}}));
						alloc_i <= alloc_i + 1;
					end
				7'd76:
					if (!rd_phase) begin
						heap_read_a(temp_heap_addr);
						heap_read_b(str2_addr);
						hold_for_read;
					end
					else if (hm_rd_a[31:16] != hm_rd_b[31:16]) begin
						accu <= (streq_negate ? VAL_TRUE : VAL_FALSE);
						state <= 7'd4;
					end
					else begin
						alloc_wosize <= hm_rd_a[31:16];
						alloc_i <= 0;
						state <= 7'd77;
					end
				7'd77:
					if (alloc_i == alloc_wosize) begin
						accu <= (streq_negate ? VAL_FALSE : VAL_TRUE);
						state <= 7'd4;
					end
					else if (!rd_phase) begin
						heap_read_a((temp_heap_addr + 1) + alloc_i);
						heap_read_b((str2_addr + 1) + alloc_i);
						hold_for_read;
					end
					else if (hm_rd_a != hm_rd_b) begin
						accu <= (streq_negate ? VAL_TRUE : VAL_FALSE);
						state <= 7'd4;
					end
					else
						alloc_i <= alloc_i + 1;
				7'd80:
					if (!rd_phase) begin
						heap_read_a(temp_heap_addr);
						hold_for_read;
					end
					else begin
						accu <= Val_int(hm_rd_a[8 * str_byte+:8]);
						state <= 7'd4;
					end
				7'd81:
					if (trap_ready) begin
						trap_valid <= 1'b0;
						accu <= (trap_prim == TRAP_IO_READ ? Val_int(trap_result) : VAL_UNIT);
						state <= 7'd4;
					end
				7'd48:
					if (trap_ready) begin
						accu <= trap_result;
						state <= 7'd4;
					end
				7'd5:
					if (!rd_phase) begin
						stack_read_a(temp_stack_addr);
						hold_for_read;
					end
					else begin
						accu <= st_rd_a;
						state <= next_state_after_mem;
					end
				7'd6:
					if (!rd_phase) begin
						heap_read_a(temp_heap_addr);
						hold_for_read;
					end
					else begin
						temp_heap_val <= hm_rd_a;
						state <= next_state_after_mem;
					end
				7'd82:
					case (op_cycle_count)
						0: begin
							stack_write(sp - 4, Make_codeptr($signed(pc - 1) + $signed(imm)));
							op_cycle_count <= 1;
						end
						1: begin
							stack_write(sp - 3, {{(VALUEW - STACK_AW) - 1 {1'b0}}, trapsp, 1'b1});
							op_cycle_count <= 2;
						end
						2: begin
							stack_write(sp - 2, env);
							op_cycle_count <= 3;
						end
						3: begin
							stack_write(sp - 1, Val_int(extra_args));
							sp <= sp - 4;
							trapsp <= sp - 4;
							state <= 7'd4;
						end
					endcase
				7'd83:
					if (!rd_phase) begin
						stack_read_a(sp + 1);
						hold_for_read;
					end
					else begin
						trapsp <= st_rd_a[STACK_AW:1];
						sp <= sp + 4;
						state <= 7'd4;
					end
				7'd85:
					if (!rd_phase) begin
						stack_read_a(trapsp);
						stack_read_b(trapsp + 1);
						hold_for_read;
					end
					else begin
						pc <= Codeptr_val(st_rd_a);
						trapsp <= st_rd_b[STACK_AW:1];
						temp_stack_addr <= trapsp;
						state <= 7'd86;
					end
				7'd86:
					if (!rd_phase) begin
						stack_read_a(temp_stack_addr + 2);
						stack_read_b(temp_stack_addr + 3);
						hold_for_read;
					end
					else begin
						env <= st_rd_a;
						extra_args <= Int_val(st_rd_b);
						sp <= temp_stack_addr + 4;
						state <= 7'd4;
					end
				7'd87:
					if (!rd_phase) begin
						globals_read_a(ZERO_DIVIDE_EXN[GLOBALS_AW - 1:0]);
						hold_for_read;
					end
					else begin
						accu <= gm_rd_a;
						state <= 7'd84;
					end
				7'd84:
					if (trapsp == {STACK_AW {1'b1}}) begin
						uncaught_exn <= 1'b1;
						state <= 7'd4;
					end
					else begin
						sp <= trapsp;
						state <= 7'd85;
					end
				7'd7:
					if (!rd_phase) begin
						globals_read_a(temp_globals_addr);
						hold_for_read;
					end
					else begin
						accu <= gm_rd_a;
						state <= next_state_after_mem;
					end
				7'd8: begin
					stack_write(sp - 1, accu);
					sp <= sp - 1;
					state <= 7'd9;
				end
				7'd9:
					if (!rd_phase) begin
						stack_read_a(temp_stack_addr);
						hold_for_read;
					end
					else begin
						accu <= st_rd_a;
						state <= 7'd4;
					end
				7'd10: begin
					accu <= temp_heap_val;
					state <= 7'd4;
				end
				7'd11: begin
					accu <= temp_heap_val;
					state <= 7'd4;
				end
				7'd21: begin
					stack_write(sp, temp_arg1);
					temp_heap_addr <= Heap_index_of_ptr(accu) + 1;
					state <= 7'd6;
					next_state_after_mem <= 7'd22;
				end
				7'd22: begin
					pc <= Codeptr_val(temp_heap_val);
					env <= accu;
					state <= 7'd4;
				end
				7'd23:
					if (!rd_phase) begin
						stack_read_a(sp + op_cycle_count);
						hold_for_read;
					end
					else
						case (op_cycle_count)
							0: begin
								temp_arg1 <= st_rd_a;
								op_cycle_count <= 1;
							end
							1: begin
								temp_arg2 <= st_rd_a;
								sp <= (sp + imm) - 2;
								op_cycle_count <= 0;
								state <= 7'd24;
							end
						endcase
				7'd24:
					case (op_cycle_count)
						0: begin
							stack_write(sp, temp_arg1);
							op_cycle_count <= 1;
						end
						1: begin
							stack_write(sp + 1, temp_arg2);
							extra_args <= extra_args + 1;
							temp_heap_addr <= Heap_index_of_ptr(accu) + 1;
							state <= 7'd6;
							next_state_after_mem <= 7'd25;
						end
					endcase
				7'd25: begin
					pc <= Codeptr_val(temp_heap_val);
					env <= accu;
					state <= 7'd4;
				end
				7'd26:
					if (!rd_phase) begin
						stack_read_a(sp + op_cycle_count);
						hold_for_read;
					end
					else
						case (op_cycle_count)
							0: begin
								temp_arg1 <= st_rd_a;
								op_cycle_count <= 1;
							end
							1: begin
								temp_arg2 <= st_rd_a;
								op_cycle_count <= 2;
							end
							2: begin
								temp_arg3 <= st_rd_a;
								sp <= (sp + imm) - 3;
								op_cycle_count <= 0;
								state <= 7'd27;
							end
						endcase
				7'd27:
					case (op_cycle_count)
						0: begin
							stack_write(sp, temp_arg1);
							op_cycle_count <= 1;
						end
						1: begin
							stack_write(sp + 1, temp_arg2);
							op_cycle_count <= 2;
						end
						2: begin
							stack_write(sp + 2, temp_arg3);
							extra_args <= extra_args + 2;
							temp_heap_addr <= Heap_index_of_ptr(accu) + 1;
							state <= 7'd6;
							next_state_after_mem <= 7'd28;
						end
					endcase
				7'd53:
					if (!rd_phase) begin
						stack_read_a(sp + op_cycle_count);
						hold_for_read;
					end
					else begin
						stack_write(((sp + imm2) - imm) + op_cycle_count, st_rd_a);
						if (op_cycle_count == 0) begin
							sp <= (sp + imm2) - imm;
							extra_args <= (extra_args + imm) - 1;
							temp_heap_addr <= Heap_index_of_ptr(accu) + 1;
							state <= 7'd6;
							next_state_after_mem <= 7'd28;
						end
						else
							op_cycle_count <= op_cycle_count - 1;
					end
				7'd28: begin
					pc <= Codeptr_val(temp_heap_val);
					env <= accu;
					state <= 7'd4;
				end
				7'd32:
					case (op_cycle_count)
						0: begin
							stack_write(sp - 2, Make_codeptr(pc));
							op_cycle_count <= 1;
						end
						1: begin
							stack_write(sp - 1, env);
							op_cycle_count <= 2;
						end
						2: begin
							stack_write(sp, Val_int(extra_args));
							sp <= sp - 3;
							extra_args <= 0;
							temp_heap_addr <= Heap_index_of_ptr(accu) + 1;
							state <= 7'd6;
							next_state_after_mem <= 7'd33;
						end
					endcase
				7'd33: begin
					pc <= Codeptr_val(temp_heap_val);
					env <= accu;
					state <= 7'd4;
				end
				7'd34:
					case (op_cycle_count)
						0: begin
							stack_write(sp - 2, temp_arg2);
							op_cycle_count <= 1;
						end
						1: begin
							stack_write(sp - 1, Make_codeptr(pc));
							op_cycle_count <= 2;
						end
						2: begin
							stack_write(sp, env);
							op_cycle_count <= 3;
						end
						3: begin
							stack_write(sp + 1, Val_int(extra_args));
							sp <= sp - 3;
							extra_args <= 1;
							temp_heap_addr <= Heap_index_of_ptr(accu) + 1;
							state <= 7'd6;
							next_state_after_mem <= 7'd35;
						end
					endcase
				7'd35: begin
					pc <= Codeptr_val(temp_heap_val);
					env <= accu;
					state <= 7'd4;
				end
				7'd36:
					case (op_cycle_count)
						0:
							if (!rd_phase) begin
								stack_read_a(sp + 2);
								hold_for_read;
							end
							else begin
								stack_write(sp - 2, temp_arg2);
								temp_arg3 <= st_rd_a;
								op_cycle_count <= 1;
							end
						1: begin
							stack_write(sp - 1, temp_arg3);
							op_cycle_count <= 2;
						end
						2: begin
							stack_write(sp, Make_codeptr(pc));
							op_cycle_count <= 3;
						end
						3: begin
							stack_write(sp + 1, env);
							op_cycle_count <= 4;
						end
						4: begin
							stack_write(sp + 2, Val_int(extra_args));
							sp <= sp - 3;
							extra_args <= 2;
							temp_heap_addr <= Heap_index_of_ptr(accu) + 1;
							state <= 7'd6;
							next_state_after_mem <= 7'd37;
						end
					endcase
				7'd37: begin
					pc <= Codeptr_val(temp_heap_val);
					env <= accu;
					state <= 7'd4;
				end
				7'd38:
					if (!rd_phase) begin
						stack_read_a((sp + imm) + op_cycle_count);
						hold_for_read;
					end
					else
						case (op_cycle_count)
							0: begin
								temp_return_pc <= st_rd_a;
								op_cycle_count <= 1;
							end
							1: begin
								temp_return_env <= st_rd_a;
								op_cycle_count <= 2;
							end
							2: begin
								temp_extra_args <= Int_val(st_rd_a);
								sp <= (sp + imm) + 3;
								state <= 7'd39;
							end
						endcase
				7'd39: begin
					pc <= Codeptr_val(temp_return_pc);
					env <= temp_return_env;
					extra_args <= temp_extra_args;
					state <= 7'd4;
				end
				7'd44:
					case (op_cycle_count)
						0: begin
							stack_write(sp - 3, Make_codeptr($signed(pc - 1) + $signed(imm)));
							op_cycle_count <= 1;
						end
						1: begin
							stack_write(sp - 2, env);
							op_cycle_count <= 2;
						end
						2: begin
							stack_write(sp - 1, Val_int(extra_args));
							sp <= sp - 3;
							state <= 7'd4;
						end
					endcase
				7'd46: begin
					accu <= temp_heap_val;
					state <= 7'd4;
				end
				7'd47: begin
					heap_write((Heap_index_of_ptr(temp_base_ptr) + temp_index) + 1, temp_value);
					sp <= sp + 2;
					accu <= VAL_UNIT;
					state <= 7'd4;
				end
				7'd4: begin
					$display("  instruction done, acc=0x%08x, pc=%d", accu, pc);
					state <= 7'd0;
				end
				default:
					$display("Invalid state %d", state);
			endcase
		end
		if (st_we_a)
			stack_mem[st_addr_a] <= st_wd_a;
		if (st_re_a)
			st_rd_a <= stack_mem[st_addr_a];
		if (st_re_b)
			st_rd_b <= stack_mem[st_addr_b];
		if (hm_we_a)
			heap_mem[hm_addr_a] <= hm_wd_a;
		if (hm_re_a)
			hm_rd_a <= heap_mem[hm_addr_a];
		if (hm_re_b)
			hm_rd_b <= heap_mem[hm_addr_b];
		if (gm_we_a)
			globals_mem[gm_addr_a] <= gm_wd_a;
		if (gm_re_a)
			gm_rd_a <= globals_mem[gm_addr_a];
		if (gm_re_b)
			gm_rd_b <= globals_mem[gm_addr_b];
		st_a_was_tos <= st_re_a && (st_addr_a == sp);
		if (st_a_was_tos)
			tos_q <= st_rd_a;
	end
	initial _sv2v_0 = 0;
endmodule
