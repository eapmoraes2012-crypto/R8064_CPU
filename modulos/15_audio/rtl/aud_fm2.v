// aud_fm2.v - front-end of OPL3 #2: plays the two YM2413 (MSX-MUSIC) and the FM part of the two Y8950 (MSX-AUDIO) on one
// external OPL3, fixed split: YM2413 -> bank 0 (channels 0-8, hardware rhythm, outputs C/D), Y8950 FM -> bank 1 (outputs A/B).
// Only one chip of each kind sounds at a time (the "owner"). In automatic mode (cfg = 0) the owner changes when it has had no
// key-on for IDLE_FS samples and the other chip keys a note; the new owner's registers are then rewritten to the OPL3
// (YM2413: every channel retranslated; Y8950: registers 20h-F5h replayed). cfg = 1 / 2 forces chip #1 / #2.
//
// YM2413 -> OPL3 translation (per channel; only values that differ from what the OPL3 already holds are written):
//   instrument = R3x[7:4] (0 = user R00-R07, 1-15 = ROM, rhythm mode: ch 6/7/8 = rhythm patches 16/17/18; ROM data as in
//   openMSX YM2413Okazaki). Operator registers: 20h = patch byte 0/1, 40h = KSL + TL (modulator: patch TL; carrier: volume x 4,
//   i.e. 3 dB steps), 60h = AR/DR, 80h = SL/RR with the OPLL release rules (key on: RR; key off: sustain ? 5 : EG-type ? RR : 7),
//   E0h = half-sine when DM/DC, C0h = feedback + outputs C/D, A0h/B0h = F-number x 2 (9 -> 10 bits, same block), key.
//   Rhythm: BDh = C0h | R0E[5:0] (AM 4.8 dB, vibrato 14 cents; bit 5 rhythm, bits 4-0 BD SD TOM CYM HH as on the OPL3);
//   HH/TOM (modulator slots of ch 7/8) take their volume from R37/R38 bits 7-4, SD/CYM and BD from bits 3-0.
//   Differences from a real YM2413 remain (envelope and AM/vibrato rates of the OPL3, no OPLL-specific rounding).
// Y8950 FM -> OPL3 bank 1: registers 20h-F5h except BDh, with C0h-C8h forced to outputs A/B (bits 5-4). The Y8950 rhythm mode,
// the note-select bit and the AM/vibrato depth (BDh) are not reproduced (bank 1 has no rhythm; BDh belongs to the YM2413).
module aud_fm2 #(parameter IDLE_FS = 49716)(
    input  wire clk, rst, ce_fs,
    input  wire [1:0] cfg_o, cfg_y,                     // owner mode YM2413 / Y8950 (0 auto, 1 force #1, 2 force #2)
    output reg  own_o, own_y,                           // current owners (0 = #1, 1 = #2)
    // YM2413 #1/#2 register ports (address latch inside)
    input  wire [1:0] o_awe, o_dwe, input wire [7:0] o_wd,
    // Y8950 #1/#2 FM register writes and shadow read ports
    input  wire [1:0] y_we, input wire [15:0] y_reg, y_d,
    output reg  [7:0] y_sha, input wire [15:0] y_shd,
    // OPL3 #2 write queue
    output reg  wq_we, output reg [16:0] wq_d, input wire wq_full
);
    // ---------------- YM2413 shadows (64 registers per chip)
    reg [7:0] sh0 [0:63]; reg [7:0] sh1 [0:63]; reg [5:0] oa0, oa1; reg oa0_ok, oa1_ok;
    integer i;
    always @(posedge clk) begin
        if (rst) begin oa0 <= 0; oa1 <= 0; oa0_ok <= 0; oa1_ok <= 0; for (i = 0; i < 64; i = i + 1) begin sh0[i] <= 0; sh1[i] <= 0; end end
        else begin
            if (o_awe[0]) begin oa0 <= o_wd[5:0]; oa0_ok <= (o_wd < 8'h39); end
            if (o_awe[1]) begin oa1 <= o_wd[5:0]; oa1_ok <= (o_wd < 8'h39); end
            if (o_dwe[0] && oa0_ok) sh0[oa0] <= o_wd;
            if (o_dwe[1] && oa1_ok) sh1[oa1] <= o_wd;
        end
    end
    // key-on activity per chip (any melodic key or rhythm key)
    function act_o(input [8:0] keys, input [7:0] r0e); act_o = (|keys) || (r0e[5] && |r0e[4:0]); endfunction
    wire [8:0] k0, k1; genvar g;
    generate for (g = 0; g < 9; g = g + 1) begin : kk assign k0[g] = sh0[8'h20 + g][4]; assign k1[g] = sh1[8'h20 + g][4]; end endgenerate
    wire ao0 = act_o(k0, sh0[14]), ao1 = act_o(k1, sh1[14]);
    // Y8950 activity: key bits of B0h-B8h (from the forwarded writes)
    reg [8:0] yk0, yk1;
    always @(posedge clk) begin
        if (rst) begin yk0 <= 0; yk1 <= 0; end
        else begin
            if (y_we[0] && y_reg[7:0] >= 8'hB0 && y_reg[7:0] <= 8'hB8) yk0[y_reg[3:0]] <= y_d[5];
            if (y_we[1] && y_reg[15:8] >= 8'hB0 && y_reg[15:8] <= 8'hB8) yk1[y_reg[11:8]] <= y_d[13];
        end
    end
    wire ay0 = |yk0, ay1 = |yk1;
    // idle counters and owner selection
    reg [16:0] io_c, iy_c; reg o_sw, y_sw;
    always @(posedge clk) begin
        o_sw <= 1'b0; y_sw <= 1'b0;
        if (rst) begin own_o <= 0; own_y <= 0; io_c <= 0; iy_c <= 0; end
        else begin
            if (ce_fs) begin
                io_c <= ((own_o ? ao1 : ao0)) ? 17'd0 : (io_c == IDLE_FS ? io_c : io_c + 17'd1);
                iy_c <= ((own_y ? ay1 : ay0)) ? 17'd0 : (iy_c == IDLE_FS ? iy_c : iy_c + 17'd1);
            end
            if (cfg_o == 2'd1 && own_o) begin own_o <= 0; o_sw <= 1'b1; end
            else if (cfg_o == 2'd2 && !own_o) begin own_o <= 1; o_sw <= 1'b1; end
            else if (cfg_o == 2'd0 && io_c == IDLE_FS && (own_o ? ao0 : ao1)) begin own_o <= ~own_o; o_sw <= 1'b1; io_c <= 0; end
            if (cfg_y == 2'd1 && own_y) begin own_y <= 0; y_sw <= 1'b1; end
            else if (cfg_y == 2'd2 && !own_y) begin own_y <= 1; y_sw <= 1'b1; end
            else if (cfg_y == 2'd0 && iy_c == IDLE_FS && (own_y ? ay0 : ay1)) begin own_y <= ~own_y; y_sw <= 1'b1; iy_c <= 0; end
        end
    end

    // ---------------- YM2413 translator
    // patch ROM (openMSX YM2413Okazaki inst_data, instruments 1-15 and rhythm 16-18)
    function [63:0] prom(input [4:0] n);
        case (n)
            5'd1:  prom = 64'h61611e17f07f0017;  5'd2:  prom = 64'h1341160efdf42323;  5'd3:  prom = 64'h03019a04f3f313f3;
            5'd4:  prom = 64'h11610e07fa647017;  5'd5:  prom = 64'h22211e06f0760028;  5'd6:  prom = 64'h21221605f0710018;
            5'd7:  prom = 64'h21611d0782801717;  5'd8:  prom = 64'h23212d1690900007;  5'd9:  prom = 64'h21211b0664651017;
            5'd10: prom = 64'h21210b1a85a07007;  5'd11: prom = 64'h23018310ffb410f4;  5'd12: prom = 64'h97c12007fff42222;
            5'd13: prom = 64'h61000c05c2f64044;  5'd14: prom = 64'h0101560394c20312;  5'd15: prom = 64'h21018903f1e4f023;
            5'd16: prom = 64'h07211400eef8fff8;  5'd17: prom = 64'h01310000f8f7f8f7;  5'd18: prom = 64'h25110000f8faf855;
            default: prom = 64'h0;
        endcase
    endfunction
    // the owner's register c, read by index
    function [7:0] osh(input [5:0] a); osh = own_o ? sh1[a] : sh0[a]; endfunction
    reg [8:0] chd; reg rhd;                         // dirty channels / rhythm register
    reg [3:0] t_ch; reg [3:0] it; reg t_busy, t_rhy, t_clr, t_rclr;
    // dirty marking (writes to the owner, or owner switch)
    always @(posedge clk) begin
        if (rst) begin chd <= 9'h1FF; rhd <= 1'b1; end
        else begin
            if (t_clr) chd[t_ch] <= 1'b0;
            if (t_rclr) rhd <= 1'b0;
            if (o_sw) begin chd <= 9'h1FF; rhd <= 1'b1; end
            else if (o_dwe[own_o] && (own_o ? oa1_ok : oa0_ok)) begin : mk
                reg [5:0] a; a = own_o ? oa1 : oa0;
                if (a < 6'h08) chd <= 9'h1FF;
                else if (a == 6'h0E) begin rhd <= 1'b1; chd[8:6] <= 3'b111; end
                else if (a[3:0] <= 4'd8 && (a[5:4] == 2'd1 || a[5:4] == 2'd2 || a[5:4] == 2'd3)) chd[a[3:0]] <= 1'b1;
            end
        end
    end
    // translation of item it of channel t_ch
    function [4:0] opoff(input [3:0] c); case (c) 0: opoff = 0; 1: opoff = 1; 2: opoff = 2; 3: opoff = 8; 4: opoff = 9; 5: opoff = 10; 6: opoff = 16; 7: opoff = 17; default: opoff = 18; endcase endfunction
    wire [7:0] r0e = osh(6'h0E);
    wire rm = r0e[5] && t_ch >= 4'd6;
    wire [7:0] r1x = osh({2'd1, t_ch}), r2x = osh({2'd2, t_ch}), r3x = osh({2'd3, t_ch});
    wire [4:0] pn = rm ? (5'd10 + t_ch) : {1'b0, r3x[7:4]};
    wire [63:0] P = (pn == 5'd0) ? {osh(0), osh(1), osh(2), osh(3), osh(4), osh(5), osh(6), osh(7)} : prom(pn);
    wire [7:0] P0 = P[63:56], P1 = P[55:48], P2 = P[47:40], P3 = P[39:32], P4 = P[31:24], P5 = P[23:16], P6 = P[15:8], P7 = P[7:0];
    wire [7:0] rv36 = osh(6'h36), rv37 = osh(6'h37), rv38 = osh(6'h38);
    wire [3:0] vol_c = !rm ? r3x[3:0] : (t_ch == 4'd6) ? rv36[3:0] : (t_ch == 4'd7) ? rv37[3:0] : rv38[3:0];
    wire [5:0] tl_m  = (rm && t_ch != 4'd6) ? {((t_ch == 4'd7) ? rv37[7:4] : rv38[7:4]), 2'b00} : P2[5:0];
    wire key_mel = r2x[4] && !rm;
    wire key_m = rm ? ((t_ch == 4'd6) ? r0e[4] : (t_ch == 4'd7) ? r0e[0] : r0e[2]) : key_mel;
    wire key_c = rm ? ((t_ch == 4'd6) ? r0e[4] : (t_ch == 4'd7) ? r0e[3] : r0e[1]) : key_mel;
    wire sus_c = r2x[5], sus_m = r2x[5] && rm && t_ch != 4'd6;
    wire [3:0] rr_m = key_m ? P6[3:0] : (sus_m ? 4'd5 : (P0[5] ? P6[3:0] : 4'd7));
    wire [3:0] rr_c = key_c ? P7[3:0] : (sus_c ? 4'd5 : (P1[5] ? P7[3:0] : 4'd7));
    wire [4:0] om = opoff(t_ch), oc = opoff(t_ch) + 5'd3;
    wire [8:0] f9 = {r2x[0], r1x};
    reg [7:0] ireg, ival;
    always @* begin
        case (it)
            4'd0:  begin ireg = 8'h20 + om; ival = P0; end
            4'd1:  begin ireg = 8'h20 + oc; ival = P1; end
            4'd2:  begin ireg = 8'h40 + om; ival = {P2[7:6], tl_m}; end
            4'd3:  begin ireg = 8'h40 + oc; ival = {P3[7:6], vol_c, 2'b00}; end
            4'd4:  begin ireg = 8'h60 + om; ival = P4; end
            4'd5:  begin ireg = 8'h60 + oc; ival = P5; end
            4'd6:  begin ireg = 8'h80 + om; ival = {P6[7:4], rr_m}; end
            4'd7:  begin ireg = 8'h80 + oc; ival = {P7[7:4], rr_c}; end
            4'd8:  begin ireg = 8'hE0 + om; ival = {7'd0, P3[3]}; end
            4'd9:  begin ireg = 8'hE0 + oc; ival = {7'd0, P3[4]}; end
            4'd10: begin ireg = 8'hC0 + t_ch; ival = {4'hC, P3[2:0], 1'b0}; end
            4'd11: begin ireg = 8'hA0 + t_ch; ival = {f9[6:0], 1'b0}; end
            default: begin ireg = 8'hB0 + t_ch; ival = {2'b00, key_mel, r2x[3:1], f9[8:7]}; end
        endcase
        if (t_rhy) begin ireg = 8'hBD; ival = {2'b11, r0e[5:0]}; end
    end
    // OPL3 bank 0 mirror (what the chip holds)
    reg [7:0] mir [0:255]; reg [255:0] mir_v;
    wire need_w = !mir_v[ireg] || mir[ireg] != ival;

    // ---------------- Y8950 path: small FIFO of forwarded writes + replay
    reg [15:0] yq [0:15]; reg [4:0] ywp, yrp;
    wire y_in = y_we[own_y];
    wire [7:0] y_r = own_y ? y_reg[15:8] : y_reg[7:0], y_v = own_y ? y_d[15:8] : y_d[7:0];
    reg rp_act; reg [7:0] rp_a; reg rp_st;           // replay of the new owner's registers
    function [7:0] yfix(input [7:0] r, input [7:0] v); yfix = (r >= 8'hC0 && r <= 8'hC8) ? ((v & 8'h0F) | 8'h30) : v; endfunction
    function yok(input [7:0] r); yok = (r >= 8'h20 && r <= 8'hF5 && r != 8'hBD); endfunction

    // ---------------- queue writer: translator first, then the Y8950 FIFO / replay
    localparam T_IDLE = 0, T_ITEM = 1, T_PUSH = 2;
    reg [1:0] ts;
    always @(posedge clk) begin
        wq_we <= 1'b0; t_clr <= 1'b0; t_rclr <= 1'b0;
        if (rst) begin ts <= T_IDLE; t_busy <= 0; t_rhy <= 0; mir_v <= 0; ywp <= 0; yrp <= 0; rp_act <= 0; rp_st <= 0; t_ch <= 0; it <= 0; end
        else begin
            // Y8950 FIFO input
            if (y_in && yok(y_r) && !rp_act && (ywp - yrp) != 5'd16) begin yq[ywp[3:0]] <= {y_r, y_v}; ywp <= ywp + 5'd1; end
            if (y_sw) begin rp_act <= 1'b1; rp_a <= 8'h20; yrp <= ywp; end
            // translator state machine and queue pushes (one write per clock at most)
            case (ts)
                T_IDLE: begin
                    if (rhd && !t_busy) begin t_rhy <= 1'b1; t_rclr <= 1'b1; it <= 0; ts <= T_ITEM; end
                    else if (|chd) begin : pick
                        integer c; reg [3:0] sel; sel = 0;
                        for (c = 8; c >= 0; c = c - 1) if (chd[c]) sel = c;
                        t_ch <= sel; t_rhy <= 1'b0; it <= 0; t_clr <= 1'b1; ts <= T_ITEM;
                    end else if (!wq_full) begin
                        if (rp_act) begin
                            y_sha <= rp_a; rp_st <= ~rp_st;
                            if (rp_st) begin
                                if (yok(rp_a)) begin wq_we <= 1'b1; wq_d <= {1'b1, rp_a, yfix(rp_a, own_y ? y_shd[15:8] : y_shd[7:0])}; end
                                if (rp_a == 8'hF5) rp_act <= 1'b0; else rp_a <= rp_a + 8'd1;
                            end
                        end else if (ywp != yrp) begin
                            wq_we <= 1'b1; wq_d <= {1'b1, yq[yrp[3:0]][15:8], yfix(yq[yrp[3:0]][15:8], yq[yrp[3:0]][7:0])}; yrp <= yrp + 5'd1;
                        end
                    end
                end
                T_ITEM: begin
                    if (need_w) begin
                        if (!wq_full) begin wq_we <= 1'b1; wq_d <= {1'b0, ireg, ival}; mir[ireg] <= ival; mir_v[ireg] <= 1'b1; ts <= T_PUSH; end
                    end else ts <= T_PUSH;
                end
                T_PUSH: begin
                    if (t_rhy || it == 4'd12) ts <= T_IDLE;
                    else begin it <= it + 4'd1; ts <= T_ITEM; end
                end
                default: ts <= T_IDLE;
            endcase
        end
    end
endmodule
