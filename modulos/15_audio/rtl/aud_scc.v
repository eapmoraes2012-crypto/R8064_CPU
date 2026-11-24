// aud_scc.v - Konami SCC / SCC-I (SCC+) sound chip, as seen in a Konami Sound Cartridge without ROM/RAM.
// Memory interface of its subslot (pulses m_we / m_re with the 16-bit address; m_hit = this chip answers the read):
//   9000h-97FFh write: bank 2 register; value 3Fh enables the SCC registers at 9800h-98FFh (SCC mode, mode bit 5 = 0).
//   B000h-B7FFh write: bank 3 register; bit 7 = 1 enables the SCC+ registers at B800h-B8FFh (SCC+ mode, mode bit 5 = 1).
//   BFFEh-BFFFh write: mode register (bit 5 = SCC+ mode). Other bits are kept but have no effect (no RAM).
//   SCC  window 9800h: 00-7F waveforms ch1-4 (ch5 plays ch4's), 80-89 frequencies (LSB, MSB[3:0]) ch1-5, 8A-8E volumes,
//                      8F enable bits, 90-9F mirror of 80-8F, C0-DF deformation register.
//   SCC+ window B800h: 00-9F waveforms ch1-5, A0-AF registers, B0-BF mirror, C0-DF deformation.
//   Waveforms read back; the other registers read FFh. Deformation: bit 5 = a frequency write restarts that channel's
//   waveform; the rotation bits (6, 7) and the frequency-scale bits (0, 1) are not implemented.
// Sound: clock ce_scc = 3.579545 MHz; channel k steps its 32-byte waveform every (freq + 1) clocks (silent below 9, as the
//   chip); sample = wave (signed 8 bits) x volume (4 bits). Output: signed 16 bits per ce_fs = (sum over the 72 clocks of
//   one sample of the five channels) / 32.
module aud_scc(
    input  wire        clk, rst, ce_scc, ce_fs,
    input  wire        m_we, m_re, input wire [15:0] m_a, input wire [7:0] m_wd,
    output reg  [7:0]  m_rd, output reg m_hit,
    output reg  signed [15:0] out
);
    reg [7:0] wv [0:159];      // waveform RAM (5 x 32)
    reg [11:0] fq [0:4]; reg [3:0] vol [0:4]; reg [4:0] en; reg [7:0] def;
    reg [7:0] bank2, bank3, mode;
    wire scc_on  = (bank2[5:0] == 6'h3F) && !mode[5];
    wire sccp_on = bank3[7] && mode[5];
    wire in_scc  = scc_on  && (m_a[15:8] == 8'h98);
    wire in_sccp = sccp_on && (m_a[15:8] == 8'hB8);
    wire [7:0] lo = m_a[7:0];
    // register index in a common form: wave area, register area, deformation
    wire w_scc  = in_scc  && (lo[7] == 1'b0);                 // 00-7F
    wire w_sccp = in_sccp && (lo < 8'hA0);                    // 00-9F
    wire r_scc  = in_scc  && (lo[7:5] == 3'b100);             // 80-9F
    wire r_sccp = in_sccp && (lo[7:5] == 3'b101);             // A0-BF
    wire d_any  = (in_scc || in_sccp) && (lo[7:5] == 3'b110); // C0-DF
    wire [7:0] widx = in_scc ? {1'b0, lo[6:0]} : lo;
    wire [3:0] rreg = lo[3:0];
    reg [4:0] rstq;            // frequency write -> restart (deformation bit 5)
    reg eng_ack; reg [4:0] eng_ackm;
    integer i;

    // CPU side
    always @(posedge clk) begin
        if (rst) begin
            bank2 <= 0; bank3 <= 0; mode <= 0; def <= 0; en <= 0; rstq <= 0;
            for (i = 0; i < 5; i = i + 1) begin fq[i] <= 0; vol[i] <= 0; end
        end else begin
            if (eng_ack) rstq <= rstq & ~eng_ackm;
            if (m_we) begin
                if (m_a[15:11] == 5'b10010) bank2 <= m_wd;            // 9000h-97FFh
                if (m_a[15:11] == 5'b10110) bank3 <= m_wd;            // B000h-B7FFh
                if (m_a[15:1] == 15'h5FFF) mode <= m_wd;              // BFFEh-BFFFh
                if (w_scc || w_sccp) begin
                    wv[widx] <= m_wd;
                    if (w_scc && widx[6:5] == 2'd3) wv[{3'b100, widx[4:0]}] <= m_wd;   // SCC: ch4 waveform also ch5's
                end
                if (r_scc || r_sccp) begin
                    if (rreg <= 4'd9) begin
                        if (!rreg[0]) fq[rreg[3:1]][7:0] <= m_wd; else fq[rreg[3:1]][11:8] <= m_wd[3:0];
                        if (def[5]) rstq[rreg[3:1]] <= 1'b1;
                    end else if (rreg <= 4'd14) vol[rreg - 4'd10] <= m_wd[3:0];
                    else en <= m_wd[4:0];
                end
                if (d_any) def <= m_wd;
            end
        end
    end
    always @* begin
        m_hit = 1'b0; m_rd = 8'hFF;
        if (w_scc || w_sccp) begin m_hit = 1'b1; m_rd = wv[widx]; end
        else if (in_scc || in_sccp) m_hit = 1'b1;
    end

    // sound engine: after each ce_scc, channels 0..4 are processed one per clock
    reg [11:0] cnt [0:4]; reg [4:0] idx [0:4];
    reg [2:0] s; reg busy; reg signed [17:0] tacc; reg signed [23:0] facc;
    wire [2:0] k = s;
    wire [7:0] wsel = {((k == 3'd4) && !mode[5]) ? 3'd3 : k, idx[k]};
    wire signed [7:0] smp = wv[wsel];
    wire signed [12:0] contrib = en[k] ? smp * $signed({1'b0, vol[k]}) : 13'sd0;
    always @(posedge clk) begin
        eng_ack <= 1'b0;
        if (rst) begin
            busy <= 0; s <= 0; tacc <= 0; facc <= 0; out <= 0;
            for (i = 0; i < 5; i = i + 1) begin cnt[i] <= 0; idx[i] <= 0; end
        end else begin
            if (ce_fs) begin out <= facc >>> 5; facc <= 0; end
            if (ce_scc) begin busy <= 1'b1; s <= 0; tacc <= 0; end
            else if (busy) begin
                if (rstq[k]) begin idx[k] <= 0; cnt[k] <= fq[k]; eng_ack <= 1'b1; eng_ackm <= 5'd1 << k; end
                else if (fq[k] > 12'd8) begin
                    if (cnt[k] == 0) begin cnt[k] <= fq[k]; idx[k] <= idx[k] + 5'd1; end
                    else cnt[k] <= cnt[k] - 12'd1;
                end
                if (s == 3'd4) begin
                    busy <= 1'b0;
                    if (!ce_fs) facc <= facc + tacc + contrib;
                end else begin
                    tacc <= tacc + contrib; s <= s + 3'd1;
                end
            end
        end
    end
endmodule
