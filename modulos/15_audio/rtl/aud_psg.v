// aud_psg.v - AY-3-8910 compatible PSG (the MSX PSG), one instance per chip.
//   Clock: ce_psg = 1.789773 MHz (fM/8). Tone counters tick at ce_psg/8 and toggle the square wave every TP ticks
//   (f = 1.789773 MHz / (16 TP)); noise LFSR (17 bits, taps 0 and 3) shifts every NP ticks of ce_psg/16;
//   the envelope (16 steps, R13 shapes) steps every EP ticks of ce_psg/256. Period 0 behaves as 1.
//   Mixer R7: bits 0-2 tone off A-C, bits 3-5 noise off A-C (a disabled source counts as 1: tone and noise off = DC
//   level, used by sample players). Level: R8-R10 bits 3-0, bit 4 = envelope.
//   Output: 16-bit unipolar sample per ce_fs = sum over the 36 PSG ticks of one sample of the three channel levels
//   (AY logarithmic DAC table, 0..8191 per channel) / 32 -> 0..27644. The mixer removes the DC.
// Bus: a_we writes the register address (ignored unless bits 7-4 = 0, as on the AY), d_we writes the data,
//   rd = the selected register (unused bits read 0; R14/R15 read the written value).
module aud_psg(
    input  wire        clk, rst, ce_psg, ce_fs,
    input  wire        a_we, d_we, input wire [7:0] wd,
    output wire [7:0]  rd,
    output reg  [15:0] out
);
    reg [7:0] r [0:15]; reg [3:0] ra; reg ra_ok;
    integer i;
    // read masks
    reg [7:0] rmask;
    always @* case (ra)
        4'd1, 4'd3, 4'd5, 4'd13: rmask = 8'h0F;
        4'd6, 4'd8, 4'd9, 4'd10: rmask = 8'h1F;
        4'd7, 4'd14, 4'd15, 4'd0, 4'd2, 4'd4, 4'd11, 4'd12: rmask = 8'hFF;
        default: rmask = 8'hFF;
    endcase
    assign rd = ra_ok ? (r[ra] & rmask) : 8'hFF;

    // AY DAC (normalized to 8191)
    function [12:0] lvl(input [3:0] v);
        case (v)
            4'd0: lvl = 0;    4'd1: lvl = 82;   4'd2: lvl = 118;  4'd3: lvl = 172;
            4'd4: lvl = 251;  4'd5: lvl = 373;  4'd6: lvl = 528;  4'd7: lvl = 879;
            4'd8: lvl = 1037; 4'd9: lvl = 1679; 4'd10: lvl = 2394; 4'd11: lvl = 3054;
            4'd12: lvl = 4034; 4'd13: lvl = 5204; 4'd14: lvl = 6598; default: lvl = 8191;
        endcase
    endfunction

    reg [7:0]  pre;                       // ce_psg prescaler
    reg [11:0] tc0, tc1, tc2; reg [2:0] tq;   // tone counters / outputs
    reg [4:0]  nc; reg [16:0] lfsr;       // noise
    reg [15:0] ec; reg [3:0] epos; reg eatt, ehold; reg e_rst;   // envelope
    reg [19:0] acc;
    wire t8 = (pre[2:0] == 3'd7), t16 = (pre[3:0] == 4'd15), t256 = (pre == 8'd255);
    wire [11:0] tp0 = {r[1][3:0], r[0]}, tp1 = {r[3][3:0], r[2]}, tp2 = {r[5][3:0], r[4]};
    wire [4:0]  np = r[6][4:0];
    wire [15:0] ep = {r[12], r[11]};
    wire [3:0]  elev = eatt ? epos : ~epos;
    wire [3:0] m0 = r[8][4]  ? elev : r[8][3:0];
    wire [3:0] m1 = r[9][4]  ? elev : r[9][3:0];
    wire [3:0] m2 = r[10][4] ? elev : r[10][3:0];
    wire on0 = (tq[0] | r[7][0]) & (lfsr[0] | r[7][3]);
    wire on1 = (tq[1] | r[7][1]) & (lfsr[0] | r[7][4]);
    wire on2 = (tq[2] | r[7][2]) & (lfsr[0] | r[7][5]);
    wire [14:0] tick_sum = (on0 ? lvl(m0) : 13'd0) + (on1 ? lvl(m1) : 13'd0) + (on2 ? lvl(m2) : 13'd0);

    always @(posedge clk) begin
        e_rst <= 1'b0;
        if (rst) begin
            for (i = 0; i < 16; i = i + 1) r[i] <= 8'h00;
            r[7] <= 8'hFF; ra <= 0; ra_ok <= 1'b1;
        end else begin
            if (a_we) begin ra <= wd[3:0]; ra_ok <= (wd[7:4] == 4'd0); end
            if (d_we && ra_ok) begin r[ra] <= wd; if (ra == 4'd13) e_rst <= 1'b1; end
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            pre <= 0; tc0 <= 0; tc1 <= 0; tc2 <= 0; tq <= 3'b000; nc <= 0; lfsr <= 17'h1;
            ec <= 0; epos <= 4'd15; eatt <= 1'b0; ehold <= 1'b1; acc <= 0; out <= 0;
        end else begin
            if (e_rst) begin ec <= 0; epos <= 0; eatt <= r[13][2]; ehold <= 1'b0; end
            else if (ce_psg && t256) begin
                if (ec + 16'd1 >= ep) begin
                    ec <= 0;
                    if (!ehold) begin
                        if (epos != 4'd15) epos <= epos + 4'd1;
                        else if (!r[13][3]) begin ehold <= 1'b1; eatt <= 1'b0; end          // CONT = 0: end at 0
                        else if (r[13][0]) begin ehold <= 1'b1; if (r[13][1]) eatt <= ~eatt; end  // HOLD
                        else begin epos <= 4'd0; if (r[13][1]) eatt <= ~eatt; end            // repeat / alternate
                    end
                end else ec <= ec + 16'd1;
            end
            if (ce_psg) begin
                pre <= pre + 8'd1;
                if (t8) begin
                    if (tc0 + 12'd1 >= tp0) begin tc0 <= 0; tq[0] <= ~tq[0]; end else tc0 <= tc0 + 12'd1;
                    if (tc1 + 12'd1 >= tp1) begin tc1 <= 0; tq[1] <= ~tq[1]; end else tc1 <= tc1 + 12'd1;
                    if (tc2 + 12'd1 >= tp2) begin tc2 <= 0; tq[2] <= ~tq[2]; end else tc2 <= tc2 + 12'd1;
                end
                if (t16) begin
                    if (nc + 5'd1 >= np) begin nc <= 0; lfsr <= {lfsr[0] ^ lfsr[3], lfsr[16:1]}; end
                    else nc <= nc + 5'd1;
                end
            end
            if (ce_fs) begin
                out <= (acc + (ce_psg ? tick_sum : 20'd0)) >> 5; acc <= 0;
            end else if (ce_psg) acc <= acc + tick_sum;
        end
    end
endmodule
