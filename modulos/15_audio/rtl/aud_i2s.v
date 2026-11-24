// aud_i2s.v - I2S transmitter (Philips format) for a DAC with internal PLL (e.g. PCM5102A, SCK tied low):
// 64 BCK per frame (32-bit slots, 24-bit data MSB first, one BCK after the LRCK edge; LRCK low = left).
// The frame lasts CPS = 288 x CPOM system clocks and starts on ce_fs; BCK slot = CPS / 64 clocks (18 at 57.27 MHz, 27 at 85.91 MHz).
// The samples are captured at the start of the frame (the mixer output of the previous sample).
module aud_i2s #(parameter CPOM = 4)(
    input  wire clk, rst, ce_fs,
    input  wire signed [23:0] in_l, in_r,
    output reg  bck, lrck, sdata
);
    localparam CPS = 288 * CPOM, SLOT = CPS / 64;
    reg [11:0] c; reg [5:0] n; reg [4:0] sc; reg [23:0] sl, sr;
    wire [4:0] m = n[4:0];
    always @(posedge clk) begin
        if (rst) begin c <= 0; n <= 0; sc <= 0; bck <= 0; lrck <= 0; sdata <= 0; sl <= 0; sr <= 0; end
        else begin
            if (ce_fs) begin n <= 0; sc <= 0; sl <= in_l; sr <= in_r; end
            else if (sc == SLOT - 1) begin sc <= 0; n <= n + 6'd1; end
            else sc <= sc + 5'd1;
            // BCK low in the first half of the slot (data and LRCK change at the falling edge), high in the second half
            bck <= (sc >= SLOT / 2) && !ce_fs;
            if (ce_fs || sc == SLOT - 1) begin : nx
                reg [5:0] nn; reg [4:0] mm;
                nn = ce_fs ? 6'd0 : n + 6'd1; mm = nn[4:0];
                lrck  <= nn[5];
                sdata <= (mm >= 5'd1 && mm <= 5'd24) ? (nn[5] ? (ce_fs ? in_r : sr) : (ce_fs ? in_l : sl)) >> (5'd24 - mm) : 1'b0;
            end
        end
    end
endmodule
