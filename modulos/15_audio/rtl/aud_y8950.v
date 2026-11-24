// aud_y8950.v - Y8950 (MSX-AUDIO) without the FM generator: register file, status/IRQ, timers, ADPCM-B with its sample RAM
// (256 KB in the audio memory) and the CPU memory access path. The FM registers (20h-FFh) are kept here (read-back, replay)
// and forwarded on fm_we/fm_reg/fm_d to the OPL3 front-end, which plays them on an external OPL3 (aud_fm2).
// Behaviour follows openMSX (Y8950.cc, Y8950Adpcm.cc):
//   status = (flags & (87h | mask)) | 06h (bits 1-2 read 1); mask = ~R04 & 78h (0 until R04 is written); bit 7 = IRQ.
//   R04 bit 7 clears T1/T2/EOS/BUF RDY; otherwise it sets the mask and starts the timers (bit 0 T1, bit 1 T2).
//   Timers: period (256 - R02) x 80.4 us and (256 - R03) x 321.8 us (4 and 16 samples of 49.716 kHz).
//   ADPCM: nibble pointer, start = R0A:R09 << 3, stop = (R0C:R0B << 3) | 7, R07 = START/REC/MEMORY/REPEAT/SP-OFF/-/-/RESET,
//   R08 bit 0 = ROM (reads 0, writes ignored), bit 1 = 64K (16-bit address mask); delta-N R11:R10 per 49.716 kHz sample;
//   Yamaha ADPCM-B decoding (step table 57,57,57,57,77,102,128,153), linear leveling between samples, volume R12.
//   CPU memory: R07 = 60h writes bytes through R0F, R07 = 20h reads them (two dummy reads first); EOS at the stop address.
//   R07 = 80h (START without MEMORY) plays bytes written to R0F (BUF RDY asks for the next byte).
// Not implemented: CSM, keyboard (R05 reads FFh), DA/AD conversion (R15-R17 stored only), I/O port pins (R19 reads back R19).
module aud_y8950(
    input  wire        clk, rst, ce_fs,
    input  wire        a_we, d_we, d_re, input wire [7:0] wd,
    output wire [7:0]  st, output reg [7:0] drd,
    output reg         fm_we, output reg [7:0] fm_reg, output reg [7:0] fm_d,
    output wire        irq,
    output reg         mreq, output reg mwe, output reg [17:0] maddr, output reg [7:0] mwd, input wire mack, input wire [7:0] mrd,
    output reg  signed [15:0] out,
    // replay port for the OPL3 front-end (reads the shadow of the FM registers)
    input  wire [7:0]  sh_a, output wire [7:0] sh_d
);
    reg [7:0] rg [0:255]; reg [7:0] ra;
    assign sh_d = rg[sh_a];
    // ---------------- status / IRQ
    reg [6:0] flags;            // bit 6 T1, 5 T2, 4 EOS, 3 BUF RDY, 0 PCM BSY (positions as in the status byte)
    reg [6:0] smask;            // 78h & ~R04
    wire irq_i = |(flags & smask);
    assign irq = irq_i;
    assign st = {irq_i, flags & ({7'h07} | smask)} | 8'h06;
    // ---------------- ADPCM state
    reg [7:0]  r7, r15; reg rom, m64; reg [18:0] sa, sp; reg [15:0] delta; reg [7:0] vol; reg [1:0] rdelay;
    reg [18:0] ptr; reg [16:0] nstep; reg signed [15:0] aout; reg [15:0] diff; reg signed [15:0] lv_p, lv_n; reg [7:0] adata;
    wire playing = (r7[7:6] == 2'b10);
    wire memory  = r7[5];
    wire [17:0] amask = m64 ? 18'h0FFFF : 18'h3FFFF;
    // memory: one pending operation; rbuf = byte at ptr>>1 (CPU read path and playback prefetch)
    reg rbuf_v; reg [7:0] rbuf; reg [17:0] rbuf_a; reg fetch_need; reg wr_need; reg [17:0] wr_a; reg [7:0] wr_d;
    wire [17:0] ptr_byte = (ptr >> 1) & amask;
    // timers
    reg [7:0] t1c, t2c; reg t1on, t2on; reg [3:0] tpre;
    // engine step pending (one sample)
    reg step_pend, upd;
    integer i;
    // ADPCM-B tables
    function signed [4:0] f1(input [3:0] v); f1 = v[3] ? -$signed({1'b0, v[2:0], 1'b1}) : $signed({1'b0, v[2:0], 1'b1}); endfunction
    function [7:0] f2(input [2:0] v); case (v) 3'd4: f2 = 77; 3'd5: f2 = 102; 3'd6: f2 = 128; 3'd7: f2 = 153; default: f2 = 57; endcase endfunction
    function signed [15:0] clip16(input signed [17:0] v); clip16 = (v > 18'sd32767) ? 16'sd32767 : (v < -18'sd32768) ? -16'sd32768 : v[15:0]; endfunction
    function signed [16:0] tdiv(input signed [16:0] v, input integer sh);   // C division by 2^sh (rounds toward zero)
        tdiv = (v < 0) ? -((-v) >>> sh) : (v >>> sh);
    endfunction
    // decode of one nibble (combinational on the current state)
    wire        need_byte = !ptr[0];
    wire [7:0]  cur_byte  = memory ? rbuf : r15;
    wire [3:0]  nib       = need_byte ? cur_byte[7:4] : adata[3:0];
    wire signed [21:0] dprod = $signed({1'b0, diff}) * f1(nib);
    wire signed [21:0] dq    = (dprod < 0) ? -((-dprod) >>> 3) : (dprod >>> 3);
    wire signed [17:0] o_new = clip16(aout + dq);
    wire [23:0] d2 = diff * f2(nib[2:0]);
    wire [17:0] d2s = d2[23:6];
    wire [15:0] diff_new = (d2s < 18'd127) ? 16'd127 : (d2s > 18'd24576) ? 16'd24576 : d2s[15:0];
    wire signed [16:0] lsum = aout + $signed(o_new[15:0]);
    wire signed [15:0] lv_new = (lsum < 0) ? -((-lsum) >>> 1) : (lsum >>> 1);
    // output (leveling): prev * vol + (next - prev) * ((vol * nstep) >> 16), then >> 8 -> signed 16
    wire signed [16:0] ldiff = lv_n - lv_p;
    wire [23:0] vstep = vol * nstep[15:0];
    wire signed [25:0] lmul = ldiff * $signed({1'b0, vstep[23:16]});
    wire signed [24:0] lbase = lv_p * $signed({1'b0, vol});
    wire signed [25:0] lout = lbase + lmul;

    task restart; begin ptr <= sa; nstep <= 17'h10000 - delta; aout <= 0; diff <= 16'd127; lv_p <= 0; lv_n <= 0; end endtask

    always @(posedge clk) begin
        fm_we <= 1'b0; upd <= 1'b0;
        if (rst) begin
            for (i = 0; i < 256; i = i + 1) rg[i] <= 8'h00;
            ra <= 0; flags <= 7'h08; smask <= 7'h00; r7 <= 0; r15 <= 0; rom <= 0; m64 <= 0; sa <= 0; sp <= 19'd7; delta <= 0; vol <= 8'd255;
            rdelay <= 0; ptr <= 0; nstep <= 0; aout <= 0; diff <= 16'd127; lv_p <= 0; lv_n <= 0; adata <= 0;
            rbuf_v <= 0; fetch_need <= 0; wr_need <= 0; mreq <= 0; t1on <= 0; t2on <= 0; tpre <= 0; t1c <= 0; t2c <= 0; step_pend <= 0; out <= 0;
        end else begin
            // ---------- bus
            if (a_we) ra <= wd;
            if (d_we) begin
                rg[ra] <= wd;
                if (ra >= 8'h20) begin fm_we <= 1'b1; fm_reg <= ra; fm_d <= wd; end
                case (ra)
                    8'h02: t1c <= wd;
                    8'h03: t2c <= wd;
                    8'h04: begin
                        if (wd[7]) flags[6:3] <= 4'b0000;
                        else begin
                            smask <= {~wd[6:3], 3'b000};
                            flags[6:3] <= flags[6:3] & ~wd[6:3];          // masked flags are cleared (changeStatusMask)
                            if (wd[0] && !t1on) t1c <= rg[2]; if (wd[1] && !t2on) t2c <= rg[3];
                            t1on <= wd[0]; t2on <= wd[1];
                        end
                        if ((r7[7:5] & 3'b101) == 3'b001 || r7[7:5] == 3'b000) flags[3] <= 1'b1;   // adpcm.resetStatus()
                    end
                    8'h07: begin
                        r7 <= wd[0] ? 8'h00 : wd;
                        flags[0] <= wd[7] && !wd[0];
                        if (wd[7] && !wd[0]) restart;
                        if (wd[5] && !wd[0]) begin ptr <= sa; rdelay <= 2'd2; rbuf_v <= 1'b0; fetch_need <= 1'b1;
                                                 if (wd[7:5] == 3'b001) flags[3] <= 1'b1; end
                        else ptr <= 0;
                    end
                    8'h08: begin rom <= wd[0]; m64 <= wd[1]; end
                    8'h09: sa[10:3] <= wd;   8'h0A: sa[18:11] <= wd;
                    8'h0B: sp[10:3] <= wd;   8'h0C: sp[18:11] <= wd;
                    8'h0F: begin
                        r15 <= wd;
                        if (r7[7:5] == 3'b011) begin                       // CPU write to the sample RAM
                            if (ptr <= sp) begin
                                if (!rom) begin wr_need <= 1'b1; wr_a <= ptr_byte; wr_d <= wd; end
                                ptr <= ptr + 19'd2; flags[3] <= 1'b1;
                                if (ptr + 19'd2 > sp) begin flags[4] <= 1'b1; ptr <= sa; end
                            end
                        end else if (r7[7:5] == 3'b100) flags[3] <= 1'b0;   // CPU-fed playback: byte taken
                    end
                    8'h10: delta[7:0] <= wd; 8'h11: delta[15:8] <= wd;
                    8'h12: vol <= wd;
                    default: ;
                endcase
            end
            if (d_re && ra == 8'h0F && r7[7:5] == 3'b001) begin            // CPU read of the sample RAM
                if (rdelay != 0) begin rdelay <= rdelay - 2'd1; ptr <= sa; flags[3] <= 1'b1; end
                else if (ptr > sp) flags[4] <= 1'b1;
                else begin ptr <= ptr + 19'd2; flags[3] <= 1'b1; rbuf_v <= 1'b0; fetch_need <= 1'b1; end
            end
            // ---------- memory port (writes first)
            if (!mreq) begin
                if (wr_need) begin mreq <= 1'b1; mwe <= 1'b1; maddr <= wr_a; mwd <= wr_d; wr_need <= 1'b0; end
                else if (fetch_need) begin mreq <= 1'b1; mwe <= 1'b0; maddr <= ptr_byte; rbuf_a <= ptr_byte; fetch_need <= 1'b0; end
            end else if (mack) begin
                mreq <= 1'b0;
                if (!mwe) begin rbuf <= rom ? 8'h00 : mrd; rbuf_v <= 1'b1; end
            end
            // ---------- timers (tick on ce_fs: T1 every 4 samples, T2 every 16)
            if (ce_fs) begin
                tpre <= tpre + 4'd1;
                if (t1on && tpre[1:0] == 2'd3) begin if (t1c == 8'hFF) begin t1c <= rg[2]; flags[6] <= 1'b1; end else t1c <= t1c + 8'd1; end
                if (t2on && tpre == 4'd15)     begin if (t2c == 8'hFF) begin t2c <= rg[3]; flags[5] <= 1'b1; end else t2c <= t2c + 8'd1; end
                step_pend <= 1'b1;
            end
            // ---------- ADPCM engine: one step per sample, when the byte it may need is present
            if (step_pend && !(d_we && ra == 8'h07)) begin
                if (!playing) begin step_pend <= 1'b0; end
                else if (nstep[15:0] + delta < 17'h10000) begin       // no new nibble: only the output moves
                    nstep <= nstep[15:0] + delta; step_pend <= 1'b0; upd <= 1'b1;
                end else if (!(need_byte && memory && !rbuf_v)) begin
                    nstep <= (nstep[15:0] + delta) & 17'h0FFFF; step_pend <= 1'b0; upd <= 1'b1;
                    if (need_byte) begin adata <= cur_byte; if (!memory) flags[3] <= 1'b1; end
                    aout <= o_new[15:0]; diff <= diff_new; lv_p <= lv_n; lv_n <= lv_new;
                    if (memory && ptr + 19'd1 > sp) begin
                        flags[4] <= 1'b1;
                        if (r7[4]) begin restart; fetch_need <= 1'b1; rbuf_v <= 1'b0; end
                        else begin r7 <= 8'h00; flags[0] <= 1'b0; ptr <= ptr + 19'd1; end
                    end else begin
                        ptr <= ptr + 19'd1;
                        if (ptr[0] && memory) begin rbuf_v <= 1'b0; fetch_need <= 1'b1; end   // next byte
                    end
                end
            end
            if (upd) out <= (!playing || r7[3]) ? 16'sd0 : lout[23:8];
            else if (!playing) out <= 16'sd0;
        end
    end
    // data port read value (peek)
    always @* begin
        case (ra)
            8'h05: drd = 8'hFF;
            8'h0F: drd = (r7[7:5] == 3'b001) ? (rdelay != 0 ? r15 : (ptr > sp ? 8'h00 : rbuf)) : 8'h00;
            8'h13: drd = aout[7:0];   8'h14: drd = aout[15:8];
            8'h19: drd = (rg[8'h19] & rg[8'h18]) | (8'hFF & ~rg[8'h18]) | 8'hF0;
            8'h1A: drd = 8'h00;
            default: drd = rg[ra];
        endcase
    end
endmodule
