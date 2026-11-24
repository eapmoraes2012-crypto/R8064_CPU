// aud_mix.v - digital mixer: NSRC stereo sources (signed 16 bits, updated on ce_fs), one volume per source and side
// (8 bits, 64 = unity, up to 4x), sequential multiply-accumulate (one 16x8 multiplier per side, NSRC clocks after ce_fs),
// master volume (64 = unity), a DC blocker per side (one-pole high-pass, about 7.7 Hz at 49.716 kHz) and saturation.
// Output: signed 24 bits per side, held until the next sample; one source at full scale and unity gain = -12 dBFS.
module aud_mix #(parameter NSRC = 13)(
    input  wire clk, rst, ce_fs,
    input  wire [NSRC*16-1:0] src_l, src_r,
    input  wire [NSRC*8-1:0]  vol_l, vol_r,
    input  wire [7:0] master,
    output reg  signed [23:0] out_l, out_r
);
    reg [4:0] j; reg run; reg fin;
    reg signed [27:0] al, ar;
    wire signed [15:0] xl = src_l[j*16 +: 16], xr = src_r[j*16 +: 16];
    wire signed [24:0] pl = xl * $signed({1'b0, vol_l[j*8 +: 8]});
    wire signed [24:0] pr = xr * $signed({1'b0, vol_r[j*8 +: 8]});
    // master and DC blocker
    reg signed [27:0] xm_l, xm_r, x1_l, x1_r; reg signed [31:0] y_l, y_r;
    wire signed [35:0] ml = al * $signed({1'b0, master});
    wire signed [35:0] mr = ar * $signed({1'b0, master});
    function signed [23:0] sat(input signed [31:0] v);
        sat = (v > 32'sd8388607) ? 24'sd8388607 : (v < -32'sd8388608) ? -24'sd8388608 : v[23:0];
    endfunction
    always @(posedge clk) begin
        fin <= 1'b0;
        if (rst) begin run <= 0; j <= 0; al <= 0; ar <= 0; out_l <= 0; out_r <= 0; x1_l <= 0; x1_r <= 0; y_l <= 0; y_r <= 0; end
        else begin
            if (ce_fs) begin run <= 1'b1; j <= 0; al <= 0; ar <= 0; end
            else if (run) begin
                al <= al + (pl >>> 2); ar <= ar + (pr >>> 2);           // (x * vol / 64) << 4
                if (j == NSRC - 1) begin run <= 1'b0; fin <= 1'b1; end else j <= j + 5'd1;
            end
            if (fin) begin
                // master volume (64 = unity), then DC blocker: y = x - x1 + y1 - y1/2^10
                xm_l = ml >>> 6; xm_r = mr >>> 6;
                y_l <= xm_l - x1_l + y_l - (y_l >>> 10); x1_l <= xm_l;
                y_r <= xm_r - x1_r + y_r - (y_r >>> 10); x1_r <= xm_r;
                out_l <= sat(xm_l - x1_l + y_l - (y_l >>> 10));
                out_r <= sat(xm_r - x1_r + y_r - (y_r >>> 10));
            end
        end
    end
endmodule
