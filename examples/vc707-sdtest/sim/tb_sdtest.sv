// Testbench: the SD test design against the OpenCores card model.
//
// The point of simulating first is to establish that the FSM's command
// sequence is right BEFORE any bitstream exists.  If the sequence is wrong,
// both flows fail on hardware and the comparison says nothing.  Here the card
// is known-good by construction, so reaching the data transfer proves the
// stimulus and leaves the flows as the only remaining variable.
`timescale 1ns/1ps

module tb_sdtest;
    localparam CLK_NS = 20;   // 50 MHz, matching sys_clk_freq

    reg sys_clk = 0, sys_rst = 1;
    always #(CLK_NS/2) sys_clk = ~sys_clk;

    // The bus.  The design drives through its tristates; the model drives
    // through oe/out; pull-ups hold the lines high when nobody does, which is
    // what the real bus does and what the card's start-bit detection needs.
    wire sd_clk;
    wire sd_cmd;
    wire [3:0] sd_dat;
    pullup(sd_cmd);
    pullup(sd_dat[0]); pullup(sd_dat[1]); pullup(sd_dat[2]); pullup(sd_dat[3]);

    wire [7:0] led;

    vc707_sdtest_sim dut (
        .sim_trace    (1'b0),
        .sys_clk      (sys_clk),
        .sys_rst      (sys_rst),
        .sdcard_clk   (sd_clk),
        .sdcard_cmd   (sd_cmd),
        .sdcard_data  (sd_dat),
        .user_led0(led[0]), .user_led1(led[1]), .user_led2(led[2]), .user_led3(led[3]),
        .user_led4(led[4]), .user_led5(led[5]), .user_led6(led[6]), .user_led7(led[7])
    );

    wire cmd_out, oe_cmd, oe_dat;
    wire [3:0] dat_out;
    sd_verilator_model card (
        .sdClk  (sd_clk),
        .cmd    (sd_cmd),
        .cmdOut (cmd_out),
        .dat    (sd_dat),
        .datOut (dat_out),
        .oeCmd  (oe_cmd),
        .oeDat  (oe_dat)
    );
    assign sd_cmd = oe_cmd ? cmd_out : 1'bz;
    assign sd_dat = oe_dat ? dat_out : 4'bz;

    // Decode the LEDs the same way a person reading the board would.
    wire [3:0] step = led[3:0];
    wire [2:0] stop = led[6:4];
    reg  [3:0] step_seen = 0;

    always @(posedge sys_clk) begin
        if (step != step_seen) begin
            $display("[%8t] step %0d", $time, step);
            step_seen <= step;
        end
        if (stop != 3'd0) begin
            case (stop)
                3'd1: $display("[%8t] OK: reached the data transfer, step %0d", $time, step);
                3'd2: $display("[%8t] TIMEOUT at step %0d", $time, step);
                3'd3: $display("[%8t] CRC error at step %0d", $time, step);
                3'd4: $display("[%8t] DATA error at step %0d", $time, step);
            endcase
            $finish;
        end
    end

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("tb_sdtest.vcd");
            $dumpvars(0, tb_sdtest);
        end
        repeat (20) @(posedge sys_clk);
        sys_rst <= 0;
        // Periodic state dump: a silent run tells you nothing about whether
        // the FSM is stuck, the clock is dead, or the card never answers.
        fork
            forever begin
                #1_000_000;
                $display("[%8t] rst=%b led=%b beat=%0d fsm=%0d cmd=%b",
                         $time, sys_rst, led, dut.sdtest_beat, dut.fsm_state, sd_cmd);
            end
        join_none
        #20_000_000;                     // 20 ms: ACMD41 alone can take a while
        $display("[%8t] TIMED OUT with no verdict, last step %0d", $time, step_seen);
        $finish;
    end
endmodule
