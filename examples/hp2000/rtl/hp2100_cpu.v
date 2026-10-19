// HP 2100A-class CPU: memory-reference, shift/rotate, alter/skip, I/O group, EAU, FP firmware.
// Multi-cycle FSM.  Instruction-for-instruction equivalent to the C reference model (emu/cpu.c).
//
// Memory port: request/grant.  A request is performed in the cycle where mem_gnt is high; read
// data is then valid on mem_rdata in the following cycle.  Addresses 0 and 1 are the A and B
// registers and never reach the memory port.
//
// I/O: flag / flag-buffer / control flip-flops and the interrupt priority chain live in
// hp_iobus.v.  The CPU issues one bus operation per I/O-group instruction (io_start, wait io_done).
module hp2100_cpu (
    input             clk,
    input             rst,
    // memory port
    output reg        mem_req,
    output reg        mem_we,
    output reg [14:0] mem_addr,
    output reg [15:0] mem_wdata,
    input             mem_gnt,
    input      [15:0] mem_rdata,
    // I/O bus
    output reg        io_start,
    output reg [5:0]  io_sc,
    output reg [2:0]  io_op,
    output reg        io_h,
    output reg        io_r,
    output reg [15:0] io_dout,
    input             io_done,
    input      [15:0] io_din,
    input             io_skip,
    input             irq_valid,
    input      [5:0]  irq_sc,
    output reg        irq_ack,
    output reg        crs,            // CLC 0: control reset to all devices
    output reg        intsys,         // interrupt system enabled
    output reg [5:0]  cir,            // central interrupt register (LIA 4)
    input      [15:0] sw,             // switch register (LIA 1)
    // run control
    input             run_req,        // pulse: clear halt (press RUN)
    input      [14:0] set_p,
    input             set_p_en,
    input             stall,          // hold at an instruction boundary (DMA cycle stealing)
    input             ld_en,          // test/debug: load A, B, E, O
    input      [15:0] ld_a,
    input      [15:0] ld_b,
    input             ld_e,
    input             ld_o,
    // status / debug
    output            idle,           // at an instruction boundary and running
    output reg        halted,
    output reg [15:0] halt_ir,
    output reg        retire,         // one-cycle pulse: an instruction (or trap-cell instruction) completed
    output reg [15:0] A,
    output reg [15:0] B,
    output reg [14:0] P,
    output reg        E,
    output reg        O,
    output reg        defer
);

    localparam [5:0]
        S_IDLE = 0,  S_RD   = 1,  S_RD2  = 2,  S_WR   = 3,  S_IND  = 4,  S_INDG = 5,  S_EXEC = 6,
        S_DISP = 7,  S_MRG2 = 8,  S_MRG3 = 9,  S_MRGD = 10, S_ISZ1 = 11, S_ISZ2 = 12, S_JSB1 = 13,
        S_EAU1 = 14, S_EA1  = 15, S_EA2  = 16, S_EA3  = 17, S_DLD1 = 18, S_DST1 = 19, S_FPM  = 20,
        S_FPX  = 21, S_IOW  = 22, S_IOD  = 23, S_DONE = 24, S_DIVW = 25, S_FPW = 26;

    reg [5:0]  state;
    reg [15:0] IR;
    reg [14:0] iaddr;
    reg [14:0] ma;
    reg [15:0] w;
    reg [10:0] guard;
    reg [14:0] rd_addr;
    reg [5:0]  rd_ret;
    reg [15:0] rd_data;
    reg [14:0] wr_addr;
    reg [15:0] wr_data;
    reg [5:0]  wr_ret;
    reg [5:0]  ind_ret;
    reg [15:0] opnd;                 // first word of a two-word operand
    reg        isz_zero;

    assign idle = (state == S_IDLE) && !halted;

    // ---------------------------------------------------------------- decode
    wire        irs     = IR[11];                         // A/B select (SRG, ASG, IOG, ADA/B ...)
    wire [3:0]  mrg_op  = IR[14:11];
    wire [14:0] ma_base = {IR[10] ? iaddr[14:10] : 5'b0, IR[9:0]};
    wire [4:0]  shcnt   = (IR[3:0] == 4'd0) ? 5'd16 : {1'b0, IR[3:0]};
    wire [7:0]  hi      = IR[15:8];
    wire [3:0]  sub     = IR[7:4];
    wire        grp0    = (IR[14:12] == 3'd0);
    wire        is_mrg  = !grp0;
    wire        is_iog  = grp0 && IR[15] && IR[10];
    wire        is_asg  = grp0 && !IR[15] && IR[10];
    wire        is_eau  = grp0 && IR[15] && !IR[10];
    wire        is_srg  = grp0 && !IR[15] && !IR[10];
    wire        eau_dws0 = (hi == 8'o200) && (sub == 4'd1 || sub == 4'd2 || sub == 4'd4);
    wire        eau_dws2 = (hi == 8'o202) && (sub == 4'd1 || sub == 4'd2 || sub == 4'd4);
    wire        eau_mpy  = (hi == 8'o200) && (sub == 4'd8);
    wire        eau_div  = (hi == 8'o201);
    wire        eau_dld  = (hi == 8'o210);
    wire        eau_dst  = (hi == 8'o211);
    wire        fp_any   = (IR[15:9] == 7'b1000101);
    wire        fp_mem   = fp_any && (IR[8:4] <= 5'd3);
    wire        fp_fix   = fp_any && (IR[8:4] == 5'd4);
    wire        fp_flt   = fp_any && (IR[8:4] == 5'd5);

    // ---------------------------------------------------------------- shift/rotate helper
    function [16:0] shift_op;        // returns {E_out, value}
        input [15:0] v;
        input        e;
        input [3:0]  op;             // bit 3 = enable, bits 2:0 = type
        reg   [15:0] r;
        reg          eo;
        begin
            r = v; eo = e;
            case (op[2:0])
              3'd0: if (op[3]) r = {v[15], v[13:0], 1'b0};
              3'd1: if (op[3]) r = {v[15], v[15:1]};
              3'd2: if (op[3]) r = {v[14:0], v[15]};
              3'd3: if (op[3]) r = {v[0], v[15:1]};
              3'd4: if (op[3]) r = {1'b0, v[13:0], 1'b0};
              3'd5: begin eo = v[0];  if (op[3]) r = {e, v[15:1]}; end
              3'd6: begin eo = v[15]; if (op[3]) r = {v[14:0], e}; end
              3'd7: if (op[3]) r = {v[11:0], v[15:12]};
            endcase
            shift_op = {eo, r};
        end
    endfunction

    reg [15:0] srg_v0, srg_v1, srg_v2;
    reg        srg_e1, srg_e2, srg_skip;
    reg [16:0] t17;
    always @* begin
        srg_v0 = irs ? B : A;
        t17 = shift_op(srg_v0, E, IR[9:6]);
        srg_v1 = t17[15:0]; srg_e1 = t17[16];
        if (IR[5]) srg_e1 = 1'b0;
        srg_skip = IR[3] && !srg_v1[0];
        t17 = shift_op(srg_v1, srg_e1, {IR[4], IR[2:0]});
        srg_v2 = t17[15:0]; srg_e2 = t17[16];
    end

    // ---------------------------------------------------------------- alter/skip group
    reg [15:0] asg_d;
    reg        asg_e, asg_o, asg_skip;
    always @* begin
        asg_d = irs ? B : A;
        asg_e = E; asg_o = O; asg_skip = 1'b0;
        if (IR[8]) asg_d = 16'h0000;
        if (IR[9]) asg_d = ~asg_d;
        if (IR[5] && ((E == 1'b0) ^ IR[0])) asg_skip = 1'b1;
        if (IR[6]) asg_e = 1'b0;
        if (IR[7]) asg_e = ~asg_e;
        if (IR[4] && IR[3] && IR[0]) begin
            if (asg_d[15] && asg_d[0]) asg_skip = 1'b1;
        end else begin
            if (IR[4] && ((!asg_d[15]) ^ IR[0])) asg_skip = 1'b1;
            if (IR[3] && ((!asg_d[0]) ^ IR[0])) asg_skip = 1'b1;
        end
        if (IR[2]) begin
            asg_d = asg_d + 16'd1;
            if (asg_d == 16'h0000) asg_e = 1'b1;
            else if (asg_d == 16'h8000) asg_o = 1'b1;
        end
        if (IR[1] && ((asg_d == 16'h0000) ^ IR[0])) asg_skip = 1'b1;
        if (!(IR[5] | IR[3] | IR[1] | IR[4]) && IR[0]) asg_skip = 1'b1;   // bare RSS
    end

    // ---------------------------------------------------------------- memory-reference ALU
    wire [15:0] mrg_reg = irs ? B : A;
    wire [16:0] add17   = {1'b0, mrg_reg} + {1'b0, rd_data};

    // ---------------------------------------------------------------- EAU arithmetic
    wire signed [15:0] sA   = A;
    wire signed [15:0] sOp  = rd_data;
    wire signed [31:0] mpy_p = sA * sOp;

    // DIV: B:A / M.  Magnitudes go to the shared iterative divider; signs and overflow are fixed up afterwards.
    reg [15:0] dv_a, dv_b, dv_v2, dv_qs, dv_rs, dv_Ao, dv_Bo, dv_q, dv_r;
    reg        dv_Oo, dv_ovf;
    always @* begin
        dv_a = A; dv_b = B;
        dv_rs = {B[15], 15'b0};
        dv_qs = dv_rs;
        if (dv_rs[15]) begin
            dv_a = ~A + 16'd1;
            dv_b = ~B + (((~A + 16'd1) == 16'd0) ? 16'd1 : 16'd0);
        end
        dv_v2 = rd_data;
        if (dv_v2[15]) begin dv_v2 = ~dv_v2 + 16'd1; dv_qs = dv_qs ^ 16'h8000; end
        dv_ovf = (dv_b >= dv_v2);
        dv_Oo = 1'b0; dv_Ao = dv_a; dv_Bo = dv_b;
        dv_q = div_q[15:0]; dv_r = div_r;
        if (dv_ovf) dv_Oo = 1'b1;
        else begin
            if (dv_q != 16'd0) begin
                if (dv_qs[15]) dv_q = ~dv_q + 16'd1;
                if (dv_q[15] != dv_qs[15]) dv_Oo = 1'b1;
            end
            if (dv_rs[15]) dv_r = ~dv_r + 16'd1;
            dv_Ao = dv_q; dv_Bo = dv_r;
        end
    end

    // shared divider: CPU DIV or the FP unit
    wire        fp_ds; wire [31:0] fp_dn; wire [15:0] fp_dd;
    reg         cpu_ds;
    wire        div_busy, div_done; wire [31:0] div_q; wire [15:0] div_r;
    hp_divu divu (.clk(clk), .rst(rst), .start(cpu_ds | fp_ds), .n(fp_ds ? fp_dn : {dv_b, dv_a}),
                  .d(fp_ds ? fp_dd : dv_v2), .busy(div_busy), .done(div_done), .q(div_q), .r(div_r));

    reg [31:0] dw, dw_o, dw_mask;
    reg        dw_O;
    always @* begin
        dw = {B, A};
        dw_o = dw; dw_O = O;
        dw_mask = 32'hFFFFFFFF << (6'd31 - {1'b0, shcnt});
        if (!IR[9]) begin                      // group 0: ASL / LSL / RRL
            case (sub)
              4'd1: begin
                  if (dw[31]) dw_O = ((~dw & dw_mask) != 32'd0); else dw_O = ((dw & dw_mask) != 32'd0);
                  dw_o = ((dw << shcnt) & 32'h7FFFFFFF) | (dw & 32'h80000000);
              end
              4'd2: dw_o = dw << shcnt;
              4'd4: dw_o = (dw << shcnt) | (dw >> (6'd32 - {1'b0, shcnt}));
              default: ;
            endcase
        end else begin                         // group 2: ASR / LSR / RRR
            case (sub)
              4'd1: begin dw_O = 1'b0; dw_o = $signed(dw) >>> shcnt; end
              4'd2: dw_o = dw >> shcnt;
              4'd4: dw_o = (dw >> shcnt) | (dw << (6'd32 - {1'b0, shcnt}));
              default: ;
            endcase
        end
    end

    // ---------------------------------------------------------------- floating point firmware
    wire [32:0] fp_res;                        // {overflow, A, B}
    wire        fp_done;
    reg         fp_go;
    hp_fp fpu (.clk(clk), .rst(rst), .start(fp_go), .A(A), .B(B), .op({opnd, rd_data}), .sel(IR[6:4]),
               .done(fp_done), .res_q(fp_res), .div_start(fp_ds), .div_n(fp_dn), .div_d(fp_dd),
               .div_done(div_done), .div_q(div_q), .div_r(div_r));

    // ---------------------------------------------------------------- memory port
    always @* begin
        mem_req = 1'b0; mem_we = 1'b0; mem_addr = 15'd0; mem_wdata = 16'd0;
        case (state)
          S_RD: if (rd_addr[14:1] != 14'd0) begin mem_req = 1'b1; mem_addr = rd_addr; end
          S_WR: if (wr_addr[14:1] != 14'd0) begin mem_req = 1'b1; mem_we = 1'b1; mem_addr = wr_addr; mem_wdata = wr_data; end
          default: ;
        endcase
    end

    // ---------------------------------------------------------------- I/O group helpers
    wire [5:0] iosc = IR[5:0];
    wire [2:0] ioop = IR[8:6];
    wire       ioh  = IR[9];
    wire       ior  = IR[11];

    // ---------------------------------------------------------------- main FSM
    always @(posedge clk) begin
        retire   <= 1'b0;
        io_start <= 1'b0;
        cpu_ds   <= 1'b0;
        fp_go    <= 1'b0;
        irq_ack  <= 1'b0;
        crs      <= 1'b0;
        if (rst) begin
            state <= S_IDLE; halted <= 1'b1; A <= 0; B <= 0; P <= 0; E <= 0; O <= 0; intsys <= 0;
            defer <= 0; IR <= 0; halt_ir <= 0; cir <= 0; guard <= 0;
        end else begin
            if (set_p_en) P <= set_p;
            if (ld_en) begin A <= ld_a; B <= ld_b; E <= ld_e; O <= ld_o; end
            if (run_req) halted <= 1'b0;
            case (state)
            // ------------------------------------------------ fetch, or trap-cell fetch on interrupt
            S_IDLE: if (!halted && !stall) begin
                if (!defer && intsys && irq_valid) begin
                    cir <= irq_sc; irq_ack <= 1'b1;
                    iaddr <= {9'b0, irq_sc};
                    rd_addr <= {9'b0, irq_sc};
                end else begin
                    defer <= 1'b0;
                    iaddr <= P; rd_addr <= P;
                    P <= P + 15'd1;
                end
                rd_ret <= S_EXEC; state <= S_RD;
            end
            // ------------------------------------------------ read / write micro-operations
            S_RD: begin
                if (rd_addr[14:1] == 14'd0) begin rd_data <= rd_addr[0] ? B : A; state <= rd_ret; end
                else if (mem_gnt) state <= S_RD2;
            end
            S_RD2: begin rd_data <= mem_rdata; state <= rd_ret; end
            S_WR: begin
                if (wr_addr[14:1] == 14'd0) begin
                    if (wr_addr[0]) B <= wr_data; else A <= wr_data;
                    state <= wr_ret;
                end else if (mem_gnt) state <= wr_ret;
            end
            // ------------------------------------------------ follow an indirect chain: w = current word, ma = its address field
            S_IND: begin
                if (w[15]) begin rd_addr <= ma; rd_ret <= S_INDG; state <= S_RD; end
                else state <= ind_ret;
            end
            S_INDG: begin
                w <= rd_data; ma <= rd_data[14:0];
                guard <= guard + 11'd1;
                state <= (guard + 11'd1 > 11'd1000) ? ind_ret : S_IND;
            end
            // ------------------------------------------------ latch IR, dispatch
            S_EXEC: begin IR <= rd_data; state <= S_DISP; end
            S_DISP: begin
                if (is_mrg) begin
                    if (IR[15]) begin rd_addr <= ma_base; rd_ret <= S_MRG2; state <= S_RD; end
                    else begin ma <= ma_base; state <= S_MRG3; end
                end else if (is_srg) begin
                    if (irs) B <= srg_v2; else A <= srg_v2;
                    E <= srg_e2;
                    if (srg_skip) P <= P + 15'd1;
                    state <= S_DONE;
                end else if (is_asg) begin
                    if (irs) B <= asg_d; else A <= asg_d;
                    E <= asg_e; O <= asg_o;
                    if (asg_skip) P <= P + 15'd1;
                    state <= S_DONE;
                end else if (is_iog) begin
                    state <= S_IOW;
                end else begin
                    state <= S_EAU1;
                end
            end
            // ------------------------------------------------ memory reference group
            S_MRG2: begin                                          // first indirect level read
                w <= rd_data; ma <= rd_data[14:0]; guard <= 11'd0; ind_ret <= S_MRG3; state <= S_IND;
            end
            S_MRG3: begin                                          // effective address resolved
                case (mrg_op)
                  4'd2, 4'd4, 4'd6, 4'd8, 4'd9, 4'd10, 4'd11, 4'd12, 4'd13: begin
                      rd_addr <= ma; rd_ret <= S_MRGD; state <= S_RD;
                  end
                  4'd3: begin wr_addr <= ma; wr_data <= {1'b0, P}; wr_ret <= S_JSB1; state <= S_WR; end
                  4'd5: begin P <= ma; if (IR[15]) defer <= 1'b1; state <= S_DONE; end
                  4'd7: begin rd_addr <= ma; rd_ret <= S_ISZ1; state <= S_RD; end
                  4'd14: begin wr_addr <= ma; wr_data <= A; wr_ret <= S_DONE; state <= S_WR; end
                  4'd15: begin wr_addr <= ma; wr_data <= B; wr_ret <= S_DONE; state <= S_WR; end
                  default: state <= S_DONE;
                endcase
            end
            S_MRGD: begin                                          // operand in rd_data
                case (mrg_op)
                  4'd2:  A <= A & rd_data;
                  4'd4:  A <= A ^ rd_data;
                  4'd6:  A <= A | rd_data;
                  4'd8, 4'd9: begin
                      if (irs) B <= add17[15:0]; else A <= add17[15:0];
                      if (add17[16]) E <= 1'b1;
                      if (~(mrg_reg[15] ^ rd_data[15]) & (mrg_reg[15] ^ add17[15])) O <= 1'b1;
                  end
                  4'd10: if (A != rd_data) P <= P + 15'd1;
                  4'd11: if (B != rd_data) P <= P + 15'd1;
                  4'd12: A <= rd_data;
                  4'd13: B <= rd_data;
                  default: ;
                endcase
                state <= S_DONE;
            end
            S_ISZ1: begin                                          // ISZ: write back incremented word
                wr_addr <= ma; wr_data <= rd_data + 16'd1; isz_zero <= (rd_data + 16'd1) == 16'd0;
                wr_ret <= S_ISZ2; state <= S_WR;
            end
            S_ISZ2: begin if (isz_zero) P <= P + 15'd1; state <= S_DONE; end
            S_JSB1: begin P <= ma + 15'd1; if (IR[15]) defer <= 1'b1; state <= S_DONE; end
            // ------------------------------------------------ EAU / floating point
            S_EAU1: begin
                if (eau_dws0 || eau_dws2) begin
                    B <= dw_o[31:16]; A <= dw_o[15:0];
                    if (sub == 4'd1) O <= dw_O;                    // ASL sets O; ASR clears it (dw_O = 0)
                    state <= S_DONE;
                end else if (eau_mpy || eau_div || eau_dld || eau_dst || fp_mem) begin
                    rd_addr <= P; P <= P + 15'd1; rd_ret <= S_EA1; state <= S_RD;   // operand address word
                end else if (fp_fix || fp_flt) begin
                    state <= S_FPX;                                // no operand
                end else state <= S_DONE;                          // undefined / NOP
            end
            S_EA1: begin w <= rd_data; ma <= rd_data[14:0]; guard <= 11'd0; ind_ret <= S_EA2; state <= S_IND; end
            S_EA2: begin
                if (eau_dst) begin wr_addr <= ma; wr_data <= A; wr_ret <= S_DST1; state <= S_WR; end
                else begin rd_addr <= ma; rd_ret <= S_EA3; state <= S_RD; end
            end
            S_EA3: begin
                if (eau_mpy) begin B <= mpy_p[31:16]; A <= mpy_p[15:0]; O <= 1'b0; state <= S_DONE; end
                else if (eau_div) begin
                    if (dv_ovf) begin A <= dv_a; B <= dv_b; O <= 1'b1; state <= S_DONE; end
                    else begin cpu_ds <= 1'b1; state <= S_DIVW; end
                end
                else begin                                         // DLD and FP memory ops: second word
                    opnd <= rd_data; rd_addr <= ma + 15'd1; rd_ret <= eau_dld ? S_DLD1 : S_FPM; state <= S_RD;
                end
            end
            S_DLD1: begin A <= opnd; B <= rd_data; state <= S_DONE; end
            S_DST1: begin wr_addr <= ma + 15'd1; wr_data <= B; wr_ret <= S_DONE; state <= S_WR; end
            S_FPM: begin fp_go <= 1'b1; state <= S_FPW; end
            S_FPX: begin fp_go <= 1'b1; state <= S_FPW; end
            S_FPW: if (fp_done) begin A <= fp_res[31:16]; B <= fp_res[15:0]; O <= fp_res[32]; state <= S_DONE; end
            S_DIVW: if (div_done) begin A <= dv_Ao; B <= dv_Bo; O <= dv_Oo; state <= S_DONE; end
            // ------------------------------------------------ I/O group
            S_IOW: begin
                // special select codes handled inside the CPU
                if (iosc == 6'd0 && ioop != 3'd0) begin
                    defer <= 1'b1;
                    case (ioop)
                      3'd1: intsys <= ioh ? 1'b0 : 1'b1;
                      3'd2, 3'd3: if ((ioop == 3'd3) == intsys) P <= P + 15'd1;
                      3'd7: if (ior) crs <= 1'b1;
                      default: ;
                    endcase
                    state <= S_DONE;
                end else if (iosc == 6'd1) begin
                    case (ioop)
                      3'd1: begin O <= ioh ? 1'b0 : 1'b1; defer <= 1'b1; end
                      3'd2: begin if (!O) P <= P + 15'd1; if (ioh) O <= 1'b0; end
                      3'd3: begin if (O) P <= P + 15'd1; if (ioh) O <= 1'b0; end
                      3'd4: if (ior) B <= B | sw; else A <= A | sw;
                      3'd5: if (ior) B <= sw; else A <= sw;
                      3'd7: if (!ior) defer <= 1'b1;
                      default: ;
                    endcase
                    state <= S_DONE;
                end else if (iosc == 6'd4 && (ioop == 3'd4 || ioop == 3'd5)) begin
                    if (ioop == 3'd5) begin if (ior) B <= {10'b0, cir}; else A <= {10'b0, cir}; end
                    else begin if (ior) B <= B | {10'b0, cir}; else A <= A | {10'b0, cir}; end
                    if (ioh) begin io_start <= 1'b1; io_sc <= 6'd4; io_op <= 3'd2; io_h <= 1'b1; io_r <= 1'b0; io_dout <= 16'd0; state <= S_IOD; end
                    else state <= S_DONE;
                end else begin
                    io_start <= 1'b1; io_sc <= iosc; io_op <= ioop; io_h <= ioh; io_r <= ior;
                    io_dout <= ior ? B : A;
                    state <= S_IOD;
                end
            end
            S_IOD: if (io_done) begin
                if (iosc != 6'd4 || (ioop != 3'd4 && ioop != 3'd5)) begin
                    case (ioop)
                      3'd0: begin halted <= 1'b1; halt_ir <= IR; defer <= 1'b1; end
                      3'd1: defer <= 1'b1;
                      3'd2, 3'd3: if (io_skip) P <= P + 15'd1;
                      3'd4: if (ior) B <= B | io_din; else A <= A | io_din;
                      3'd5: if (ior) B <= io_din; else A <= io_din;
                      3'd7: defer <= 1'b1;
                      default: ;
                    endcase
                end
                state <= S_DONE;
            end
            // ------------------------------------------------ instruction complete
            S_DONE: begin retire <= 1'b1; state <= S_IDLE; end
            default: state <= S_IDLE;
            endcase
        end
    end
endmodule
