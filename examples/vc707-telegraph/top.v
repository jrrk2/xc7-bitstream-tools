// Telegraph on the VC707 (xc7vx485tffg1761-2).
//
// The simplest thing that produces BOTH a UART byte stream and a visible LED,
// with no CPU, no BRAM, no PLL and no MMCM.  The LiteX SoC builds and
// configures through this flow but prints nothing, and because that SoC drives
// no LED there is no way to tell "clock dead" from "clock fine, output path
// dead".  Telegraph answers both at once:
//
//   led[0] blinks   -> sysclk reaches the fabric and flops toggle
//   "JRRK" on UART  -> the AU36 TX pin path works end to end
//
// The clock, reset and LED pins are the ones vc707-johnson already drives
// correctly on this board; uart_tx is the pin the LiteX SoC uses.  Buffers are
// instantiated explicitly, as in vc707-johnson, rather than left to inference.
module top (
    input  wire       sysclk_p,
    input  wire       sysclk_n,
    input  wire       rst,
    output wire       uart_tx,
    output wire [3:0] led
);
    wire clk_raw;
    wire clk;
    wire rst_buf;

    IBUFDS #(.DIFF_TERM("TRUE"), .IBUF_LOW_PWR("FALSE"), .IOSTANDARD("LVDS"))
        ibufds (.I(sysclk_p), .IB(sysclk_n), .O(clk_raw));
    BUFG bufg (.I(clk_raw), .O(clk));
    IBUF ibuf_rst (.I(rst), .O(rst_buf));

    // The core's own LEDs are all far too fast to read by eye: idx advances
    // once per character (~11.5 kHz) and ser_tx moves at the baud rate, so
    // they show as a steady glow rather than a blink.  Drive led[0] from a
    // plain ripple counter instead -- 2^27 cycles at 200 MHz is a ~0.75 Hz
    // toggle, unambiguous across the room.  This is the liveness signal: if it
    // blinks, sysclk reaches the fabric and flops are toggling, whatever the
    // UART does.
    reg [27:0] heartbeat = 28'd0;
    always @(posedge clk) heartbeat <= heartbeat + 28'd1;

    wire ser_tx, led_idx0, led_idx1, led_rst;

    telegraph_core #(.CLK_HZ(200_000_000)) u_core (
        .clk    (clk),
        .rst    (rst_buf),
        .ser_tx (ser_tx),
        .led__0 (led_idx0),
        .led__1 (),            // ser_tx mirror, unused: it is on led[3] below
        .led__2 (led_idx1),
        .led__3 (led_rst)
    );

    OBUF obuf_tx  (.I(ser_tx),          .O(uart_tx));
    OBUF obuf_l0  (.I(heartbeat[27]),   .O(led[0]));  // ~0.75 Hz: fabric alive
    OBUF obuf_l1  (.I(led_idx0),        .O(led[1]));  // char index, dim glow
    OBUF obuf_l2  (.I(led_idx1),        .O(led[2]));
    OBUF obuf_l3  (.I(ser_tx),          .O(led[3]));  // TX mirror, mostly high
endmodule
