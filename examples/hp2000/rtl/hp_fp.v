// HP 2100 floating-point firmware (FAD FSB FMP FDV FIX FLT), combinational.
// Direct port of the C reference (emu/cpu.c) which was validated against SIMH.
// sel: 0 FAD, 1 FSB, 2 FMP, 3 FDV, 4 FIX, 5 FLT.   res = {overflow, A, B}.
module hp_fp (
    input         clk,
    input         rst,
    input         start,
    input  [15:0] A,
    input  [15:0] B,
    input  [31:0] op,
    input  [2:0]  sel,
    output reg    done,
    output reg [32:0] res_q,             // {overflow, A, B}, valid when done
    // shared 32/16 divider (FDV only)
    output reg        div_start,
    output reg [31:0] div_n,
    output reg [15:0] div_d,
    input             div_done,
    input      [31:0] div_q,
    input      [15:0] div_r
);
    reg [32:0] res;
    // packed unpacked-float: {exp[31:0] (signed), fr[31:0]}
    function [63:0] f_unpack;
        input [31:0] w;
        reg signed [31:0] e;
        begin
            e = {25'b0, w[7:1]};
            if (w[0]) e = e - 32'sd128;                    // C: exp |= ~0x7F
            f_unpack = {e, w[31:8], 8'b0};
        end
    endfunction

    function [63:0] f_norm;
        input signed [31:0] e;
        input        [31:0] f;
        integer i;
        reg signed [31:0] ee;
        reg        [31:0] ff;
        begin
            ee = e; ff = f;
            if (ff != 32'd0) begin
                for (i = 0; i < 32; i = i + 1)
                    if (ff[30] == ff[31]) begin ee = ee - 32'sd1; ff = ff << 1; end
            end else ee = 32'sd0;
            f_norm = {ee, ff};
        end
    endfunction

    function [32:0] f_store;                           // returns {ov, hi32}
        input signed [31:0] e;
        input        [31:0] f;
        reg [63:0] n;
        reg signed [31:0] ee;
        reg [31:0] ff, svfr, rnd;
        reg ov;
        reg [31:0] hi;
        begin
            n = f_norm(e, f);
            ee = n[63:32]; ff = n[31:0];
            svfr = ff;
            rnd = ff[31] ? 32'h0000007F : 32'h00000080;
            ff = (ff + rnd) & 32'hFFFFFF00;
            if ((ff ^ svfr) & 32'h80000000) begin
                ff = ff >> 1; ee = ee + 32'sd1;
            end else begin
                n = f_norm(ee, ff); ee = n[63:32]; ff = n[31:0];
            end
            ov = 1'b0; hi = 32'd0;
            if (ff == 32'd0) hi = 32'd0;
            else if (ee < -32'sd128) begin hi = 32'd0; ov = 1'b1; end
            else if (ee > 32'sd127) begin hi = 32'h7FFFFFFE; ov = 1'b1; end
            else hi = (ff & 32'hFFFFFF00) | ({25'b0, ee[6:0]} << 1) | {31'b0, (ee < 0)};
            f_store = {ov, hi};
        end
    endfunction

    function [31:0] f_ars;                             // arithmetic right shift, 0 < s < 32
        input [31:0] v;
        input [5:0]  s;
        begin
            f_ars = $signed(v) >>> s;
        end
    endfunction

    reg signed [31:0] e1, e2, et, ediff;
    reg        [31:0] fr1, fr2, ft;
    reg        [63:0] u;
    reg        [32:0] st;
    reg        [31:0] ab;
    // multiply temporaries
    reg signed [31:0] shi1, shi2, t1, t2, t3, t4, t5;
    // divide temporaries
    reg        [31:0] ba, q0, q1, q2, dvrh, qfr;
    reg        [47:0] dx;
    reg signed [31:0] qexp;
    reg        [31:0] res_fr;
    reg        [31:0] fix_res;
    reg        [15:0] fA, fB;
    reg               fov;

    always @* begin
        ab = {A, B};
        res = {1'b0, A, B};
        u = 64'd0; e1 = 0; e2 = 0; et = 0; ediff = 0; fr1 = 0; fr2 = 0; ft = 0; st = 33'd0;
        shi1 = 0; shi2 = 0; t1 = 0; t2 = 0; t3 = 0; t4 = 0; t5 = 0;
        ba = 0; q0 = 0; q1 = 0; q2 = 0; dvrh = 0; qfr = 0; dx = 0; qexp = 0; res_fr = 0;
        fix_res = 0; fA = A; fB = B; fov = 1'b0;
        case (sel)
          3'd4: begin                                  // FIX
              u = f_unpack(ab); e1 = u[63:32]; fr1 = u[31:0];
              fA = A; fB = B; fov = 1'b0; fix_res = 32'd0;
              if (e1 < 0) begin fA = 16'd0; end
              else if (e1 > 15) begin fB = A; fA = 16'h7FFF; fov = 1'b1; end
              else begin
                  if (e1 < 15) begin fix_res = f_ars(fr1, 6'd15 - e1[5:0]); fA = fix_res[31:16]; end
                  fB = fA;
                  if (fA[15] && ((fr1 | fix_res) & 32'hFFFF) != 32'd0) fA = fA + 16'd1;
              end
              res = {fov, fA, fB};
          end
          3'd5: begin                                  // FLT
              st = f_store(32'sd15, {A, 16'b0});
              res = {st[32], st[31:0]};
          end
          3'd0, 3'd1: begin                            // FAD / FSB
              u = f_unpack(ab);  e1 = u[63:32]; fr1 = u[31:0];
              u = f_unpack(op);  e2 = u[63:32]; fr2 = u[31:0];
              if (sel == 3'd1) begin
                  fr2 = -fr2;
                  if (fr2 == 32'h80000000) begin fr2 = fr2 >> 1; e2 = e2 + 32'sd1; end
              end
              if (fr1 == 32'd0) begin e1 = e2; fr1 = fr2; end
              else if (fr2 != 32'd0) begin
                  if (e1 < e2) begin et = e2; ft = fr2; e2 = e1; fr2 = fr1; e1 = et; fr1 = ft; end
                  ediff = e1 - e2;
                  if (ediff <= 32'sd24) begin
                      if (ediff != 0) fr2 = f_ars(fr2, ediff[5:0]);
                      if ((fr1 ^ fr2) & 32'h80000000) fr1 = fr1 + fr2;
                      else begin
                          fr1 = fr1 + fr2;
                          if (fr2[31]) begin
                              if (!fr1[31]) begin fr1 = 32'h80000000 | (fr1 >> 1); e1 = e1 + 32'sd1; end
                          end else if (fr1[31]) begin fr1 = fr1 >> 1; e1 = e1 + 32'sd1; end
                      end
                  end
              end
              st = f_store(e1, fr1);
              res = {st[32], st[31:0]};
          end
          3'd2: begin                                  // FMP
              u = f_unpack(ab);  e1 = u[63:32]; fr1 = u[31:0];
              u = f_unpack(op);  e2 = u[63:32]; fr2 = u[31:0];
              qexp = 32'sd0; res_fr = 32'd0;
              if (fr1 != 32'd0 && fr2 != 32'd0) begin
                  qexp = e1 + e2 + 32'sd1;
                  shi1 = {{16{fr1[31]}}, fr1[31:16]};
                  shi2 = {{16{fr2[31]}}, fr2[31:16]};
                  t1 = shi2 * $signed({17'b0, fr1[15:1]} & 32'h00007F80);
                  t2 = shi1 * $signed({17'b0, fr2[15:1]} & 32'h00007F80);
                  t3 = t1 + t2;
                  t4 = (shi1 * shi2) & ~32'sd1;
                  t5 = $signed({{16{t3[31]}}, t3[31:16]}) <<< 1;
                  res_fr = t4 + t5;
              end
              st = f_store(qexp, res_fr);
              res = {st[32], st[31:0]};
          end
          3'd3: begin                                  // FDV, divide results come from the sequencer
              u = f_unpack(ab);  e1 = u[63:32]; fr1 = u[31:0];
              u = f_unpack(op);  e2 = u[63:32]; fr2 = u[31:0];
              dvrh = {16'b0, fr2[31:16]};
              qexp = 32'sd0; qfr = 32'd0;
              if (dvrh == 32'd0) res = {1'b1, 16'h7FFF, 16'hFFFE};
              else begin
                  if (fr1 != 32'd0) begin
                      qexp = e1 - e2 + 32'sd1;
                      q0 = Q0; q1 = Q1; q2 = Q2;
                      t1 = -($signed({{16{q2[15]}}, q2[15:0]}) * $signed({{16{q0[15]}}, q0[15:0]}));
                      ba = (t1 >> 16) & 32'h0000FFFF;
                      if (q1[15]) qfr = qfr - 32'h00010000;
                      if (ba[15]) qfr = qfr - 32'h00010000;
                      qfr = qfr + ((ba << 2) & 32'h0000FFFF) + q1;
                      qfr = qfr << 1;
                      qfr = qfr + (q0 << 16);
                  end
                  st = f_store(qexp, qfr);
                  res = {st[32], st[31:0]};
              end
          end
          default: ;
        endcase
    end

    // ---------------------------------------------------------------- sequencer
    // FDV: Q0 = ba/dvrh with ba = fr1>>2; Q1 from the remainder; Q2 from dvrl.  Three divides in series.
    reg [31:0] Q0, Q1, Q2;
    reg [3:0]  st_s;
    localparam [3:0] F_IDLE = 0, F_D0 = 1, F_W0 = 2, F_D1 = 3, F_W1 = 4, F_D2 = 5, F_W2 = 6, F_FIN = 7;
    reg        sdvd_q, sdvr_q;
    wire [31:0] fr1_c = {A, B} & 32'hFFFFFF00;
    wire [31:0] fr2_c = op & 32'hFFFFFF00;
    wire [31:0] dvrh_c = {16'b0, fr2_c[31:16]};
    function [31:0] absv; input [31:0] v; begin absv = v[31] ? -v : v; end endfunction
    function [31:0] qfix; input sd; input sr; input [31:0] q; begin qfix = (sd ^ sr) ? ((-q) & 32'hFFFF) : q; end endfunction
    reg [31:0] ba_n;
    wire [15:0] dabs = dvrh_c[15] ? (-dvrh_c[15:0]) : dvrh_c[15:0];
    wire        sdvr_c = dvrh_c[15];
    wire [31:0] ba0 = $signed(fr1_c) >>> 2;
    reg [15:0] rem_q;

    always @(posedge clk) begin
        done <= 1'b0; div_start <= 1'b0;
        if (rst) st_s <= F_IDLE;
        else case (st_s)
          F_IDLE: if (start) begin
              if (sel == 3'd3 && dvrh_c != 32'd0 && fr1_c != 32'd0) begin
                  ba_n <= ba0; st_s <= F_D0;
              end else st_s <= F_FIN;
          end
          F_D0: begin div_n <= absv(ba_n); div_d <= dabs; div_start <= 1'b1; sdvd_q <= ba_n[31]; st_s <= F_W0; end
          F_W0: if (div_done) begin
              Q0 <= qfix(sdvd_q, sdvr_c, div_q);
              rem_q <= sdvd_q ? (-div_r) : div_r;
              st_s <= F_D1;
          end
          F_D1: begin
              ba_n <= $signed({rem_q[15:1], 1'b0, 16'd0}) >>> 1;
              st_s <= 4'd8;
          end
          4'd8: begin div_n <= absv(ba_n); div_d <= dabs; div_start <= 1'b1; sdvd_q <= ba_n[31]; st_s <= F_W1; end
          F_W1: if (div_done) begin Q1 <= qfix(sdvd_q, sdvr_c, div_q); ba_n <= (fr2_c & 32'h0000FF00) << 13; st_s <= 4'd9; end
          4'd9: begin div_n <= absv(ba_n); div_d <= dabs; div_start <= 1'b1; sdvd_q <= ba_n[31]; st_s <= F_W2; end
          F_W2: if (div_done) begin Q2 <= qfix(sdvd_q, sdvr_c, div_q); st_s <= F_FIN; end
          F_FIN: begin res_q <= res; done <= 1'b1; st_s <= F_IDLE; end
          default: st_s <= F_IDLE;
        endcase
    end
endmodule
