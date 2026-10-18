// I/O backplane: per-select-code flag, flag-buffer and control flip-flops, the interrupt priority
// chain, and the strobes devices need.  Mirrors the generic device model in the C reference core.
//
// Devices attach to the shared strobe/data bus (dev_*) and listen for their own select code;
// they raise their flag with dev_setflag[sc].  dev_noclf lets a device cancel the H/C flag clear
// of the STC/CLC executing this cycle (used for controller-clear style commands).
module hp_iobus (
    input             clk,
    input             rst,
    // CPU side
    input             io_start,
    input      [5:0]  io_sc,
    input      [2:0]  io_op,
    input             io_h,
    input             io_r,
    input      [15:0] io_dout,
    output reg        io_done,
    output reg [15:0] io_din,
    output reg        io_skip,
    input             intsys,
    input             crs,
    input             irq_ack,
    input      [5:0]  ack_sc,
    output reg        irq_valid,
    output reg [5:0]  irq_sc,
    // DMA master port (one cycle at a time, never concurrent with a CPU I/O operation)
    input             dma_start,
    input      [5:0]  dma_sc,
    input             dma_in,         // 1: device -> memory
    input             dma_stc_en,
    input             dma_clc_en,
    input             dma_last,
    input      [15:0] dma_dout,
    output reg [15:0] dma_din,
    output reg        dma_done,
    // device side
    output     [5:0]  dev_sc,         // select code being read (combinational: CPU op or DMA cycle); use for dev_din
    output reg [5:0]  dev_sc_s,       // select code accompanying the strobes below (valid the cycle after the op)
    output reg        dev_stc,
    output reg        dev_clc,
    output reg        dev_stf,
    output reg        dev_clf,
    output reg        dev_ot,
    output reg        dev_crs,
    output reg        dev_edt,
    output reg        dev_h,
    output reg        dev_dma,
    output reg        dev_rd,         // a LIA/MIA just read the device addressed by dev_sc_s (read side effects)        // the strobes belong to a DMA cycle
    output reg [15:0] dev_dout,
    input      [15:0] dev_din,        // data from the addressed device (LIA/MIA)
    input             dev_noclf,
    input      [63:0] dev_setflag,
    input      [63:0] dev_clrflag,    // devices clear their own flag (e.g. a status command)
    output     [63:0] flag_q,
    output     [63:0] flagbuf_q,
    output     [63:0] control_q
);
    reg [63:0] flg, fb, ctl;
    assign flag_q = flg; assign flagbuf_q = fb; assign control_q = ctl;
    assign dev_sc = dma_start ? dma_sc : io_sc;


    // interrupt priority chain: lowest select code first; a device with flag&control blocks lower priorities
    integer i;
    reg found, blocked;
    always @* begin
        irq_valid = 1'b0; irq_sc = 6'd0; found = 1'b0; blocked = 1'b0;
        for (i = 4; i < 64; i = i + 1) begin
            if (!found && !blocked) begin
                if (fb[i] && ctl[i]) begin found = 1'b1; irq_sc = i[5:0]; end
                else if (flg[i] && ctl[i]) blocked = 1'b1;
            end
        end
        irq_valid = found && intsys;
    end

    reg clr_flags;
    always @(posedge clk) begin
        io_done <= 1'b0;
        io_skip <= 1'b0;
        dma_done <= 1'b0;
        dev_sc_s <= dma_start ? dma_sc : io_sc;
        dev_dout <= dma_start ? dma_dout : io_dout;
        dev_h <= io_h;
        dev_dma <= dma_start;
        dev_rd <= io_start && (io_op == 3'd4 || io_op == 3'd5);
        dev_stc <= 1'b0; dev_clc <= 1'b0; dev_stf <= 1'b0; dev_clf <= 1'b0; dev_ot <= 1'b0; dev_crs <= 1'b0; dev_edt <= 1'b0;
        if (rst) begin
            flg <= 64'd0; fb <= 64'd0; ctl <= 64'd0; io_din <= 16'd0;
        end else begin
            // devices raise flags (events happen "before" the instruction in the C model)
            flg <= (flg | dev_setflag) & ~dev_clrflag;
            fb  <= (fb  | dev_setflag) & ~dev_clrflag;
            if (irq_ack) fb[ack_sc] <= 1'b0;
            if (crs) begin
                ctl[63:6] <= 58'd0;
                dev_crs <= 1'b1;
            end
            if (dma_start) begin
                dma_done <= 1'b1;
                if (dma_in) dma_din <= dev_din; else dev_ot <= 1'b1;
                flg[dma_sc] <= 1'b0; fb[dma_sc] <= 1'b0; dev_clf <= 1'b1;
                if (dma_in) begin
                    if (dma_stc_en && !dma_last) begin ctl[dma_sc] <= 1'b1; dev_stc <= 1'b1; end
                end else begin
                    if (dma_stc_en) begin ctl[dma_sc] <= 1'b1; dev_stc <= 1'b1; end
                end
                if (dma_last) begin
                    dev_edt <= 1'b1;
                    if (dma_clc_en) begin ctl[dma_sc] <= 1'b0; dev_clc <= 1'b1; end
                end
            end
            if (io_start) begin
                io_done <= 1'b1;
                clr_flags = 1'b0;
                case (io_op)
                  3'd0: clr_flags = io_h;
                  3'd1: begin
                      if (io_h) begin clr_flags = 1'b1; dev_clf <= 1'b1; end
                      else begin flg[io_sc] <= 1'b1; fb[io_sc] <= 1'b1; dev_stf <= 1'b1; end
                  end
                  3'd2: begin io_skip <= !flg[io_sc]; clr_flags = io_h; end
                  3'd3: begin io_skip <= flg[io_sc];  clr_flags = io_h; end
                  3'd4, 3'd5: begin io_din <= dev_din; clr_flags = io_h; end
                  3'd6: begin dev_ot <= 1'b1; clr_flags = io_h; end
                  3'd7: begin
                      if (io_r) begin ctl[io_sc] <= 1'b0; dev_clc <= 1'b1; end
                      else begin ctl[io_sc] <= 1'b1; dev_stc <= 1'b1; end
                      clr_flags = io_h && !dev_noclf;
                  end
                endcase
                if (clr_flags) begin flg[io_sc] <= 1'b0; fb[io_sc] <= 1'b0; end
            end
        end
    end
endmodule
