// aud_opl3_rx.v - capture of the YMF262 serial DAC outputs (the stream it sends to the YAC512): bit clock SY, data DOAB (channels
// A/B) and DOCD (C/D), latch strobes SMPAC (A and C) and SMPBD (B and D). The bits are shifted in on the SY rising edge
// (fmt[2] = 1: falling edge); a strobe edge (fmt[3] = 0: falling, 1: rising) latches the last 16 bits of each line.
// fmt[0] = 1: LSB first (default MSB first); fmt[1] = 1: offset binary (MSB inverted). The YMF262 datasheet describes a
// 16-bit serial output but not its exact timing, so the format is a run-time setting (audio configuration register 28h/29h);
// it must be confirmed on the board with a logic analyser. The OPL3 runs from the FPGA's fM, so its sample rate equals ce_fs.
module aud_opl3_rx(
    input  wire clk, rst, ce_fs, input wire [3:0] fmt,
    input  wire sy, doab, docd, smpac, smpbd,
    output reg  signed [15:0] a, b, c, d
);
    reg [2:0] s_sy, s_ab, s_cd, s_ac, s_bd;
    always @(posedge clk) begin s_sy <= {s_sy[1:0], sy}; s_ab <= {s_ab[1:0], doab}; s_cd <= {s_cd[1:0], docd}; s_ac <= {s_ac[1:0], smpac}; s_bd <= {s_bd[1:0], smpbd}; end
    wire sy_e = fmt[2] ? (s_sy[2] & ~s_sy[1]) : (~s_sy[2] & s_sy[1]);
    wire ac_e = fmt[3] ? (~s_ac[2] & s_ac[1]) : (s_ac[2] & ~s_ac[1]);
    wire bd_e = fmt[3] ? (~s_bd[2] & s_bd[1]) : (s_bd[2] & ~s_bd[1]);
    reg [15:0] sh_ab, sh_cd; reg signed [15:0] la, lb, lc, ld;
    function [15:0] conv(input [15:0] v, input lsbf, input offb);
        reg [15:0] r; integer k;
        begin for (k = 0; k < 16; k = k + 1) r[k] = lsbf ? v[15-k] : v[k]; conv = offb ? (r ^ 16'h8000) : r; end
    endfunction
    always @(posedge clk) begin
        if (rst) begin sh_ab <= 0; sh_cd <= 0; la <= 0; lb <= 0; lc <= 0; ld <= 0; a <= 0; b <= 0; c <= 0; d <= 0; end
        else begin
            if (sy_e) begin sh_ab <= {sh_ab[14:0], s_ab[1]}; sh_cd <= {sh_cd[14:0], s_cd[1]}; end
            if (ac_e) begin la <= conv(sh_ab, fmt[0], fmt[1]); lc <= conv(sh_cd, fmt[0], fmt[1]); end
            if (bd_e) begin lb <= conv(sh_ab, fmt[0], fmt[1]); ld <= conv(sh_cd, fmt[0], fmt[1]); end
            if (ce_fs) begin a <= la; b <= lb; c <= lc; d <= ld; end
        end
    end
endmodule
