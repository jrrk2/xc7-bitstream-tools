// Telegraph -- repeating bit-banged 8N1 UART emitting the fixed string
// "JRRK", continuously.  The walking 'A'..'Z' version needed an 8-bit
// incrementing `ch` register whose increment/CE network exposed a virtex7
// place/route bug (ch frozen).  Here the message is a 2-bit char index into
// a tiny combinational ROM -- no wide counter, no ch CE network -- so it
// sidesteps that path entirely.
//
// Imported from vc707-openflow-demos/telegraph, with CLK_HZ lifted to a
// parameter so the same core serves the VC707's 200 MHz sysclk and the
// Sonata's 25 MHz clk25.
module telegraph_core #(
    parameter integer CLK_HZ = 200_000_000,
    parameter integer BAUD   = 115_200
) (
    input        clk,
    input        rst,            // active-high (CPU_RESET button)
    output reg   ser_tx = 1'b1,
    output       led__0,
    output       led__1,
    output       led__2,
    output       led__3
);
  localparam integer CLKS_PER_BIT = CLK_HZ / BAUD;   // 1736 at 200 MHz
  localparam integer CNT_W        = $clog2(CLKS_PER_BIT);

  localparam S_START = 2'd0;
  localparam S_DATA  = 2'd1;
  localparam S_STOP  = 2'd2;

  reg [1:0]        state    = S_START;
  reg [1:0]        idx      = 2'd0;   // 0='J' 1='R' 2='R' 3='K'
  reg [2:0]        bit_idx  = 3'd0;
  reg [CNT_W-1:0]  baud_cnt = 0;

  // Combinational message ROM -- no register to increment.
  reg [7:0] ch_data;
  always @(*) begin
    case (idx)
      2'd0:    ch_data = "J";
      2'd1:    ch_data = "R";
      2'd2:    ch_data = "R";
      default: ch_data = "K";
    endcase
  end

  assign led__0 = idx[0];
  assign led__1 = ser_tx;
  assign led__2 = idx[1];
  assign led__3 = rst;

  always @(posedge clk) begin
    if (rst) begin
      state    <= S_START;
      idx      <= 2'd0;
      bit_idx  <= 3'd0;
      baud_cnt <= 0;
      ser_tx   <= 1'b1;
    end else begin
      case (state)
        S_START: begin
          ser_tx <= 1'b0;                        // start bit
          if (baud_cnt == CLKS_PER_BIT - 1) begin
            baud_cnt <= 0;
            bit_idx  <= 3'd0;
            state    <= S_DATA;
          end else baud_cnt <= baud_cnt + 1'b1;
        end
        S_DATA: begin
          ser_tx <= ch_data[bit_idx];            // LSB first
          if (baud_cnt == CLKS_PER_BIT - 1) begin
            baud_cnt <= 0;
            if (bit_idx == 3'd7) state <= S_STOP;
            else                 bit_idx <= bit_idx + 3'd1;
          end else baud_cnt <= baud_cnt + 1'b1;
        end
        S_STOP: begin
          ser_tx <= 1'b1;                         // stop bit, then next char
          if (baud_cnt == CLKS_PER_BIT - 1) begin
            baud_cnt <= 0;
            idx      <= idx + 2'd1;               // wraps 3->0
            state    <= S_START;
          end else baud_cnt <= baud_cnt + 1'b1;
        end
        default: state <= S_START;
      endcase
    end
  end
endmodule
