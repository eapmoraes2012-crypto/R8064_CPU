// r8064_audio.v - MSX audio subsystem of the R8064 (Tang Mega 60K design), phase 1:
//   key click (PPI port C bit 7 snooped at AAh/ABh), two PSGs, two SCCs (subslots 0 and 1), the MSX-MUSIC detection
//   signature (subslot 2), mixer and I2S output. Later phases add the OPL3 bridge (YM2413, Y8950 FM, OPL4 FM),
//   the Y8950 ADPCM, the OPL4 PCM and the wavetable synthesizer (their mixer inputs are already reserved).
// Two request buses reach the devices: the MSX slot (from aud_slot_full; priority) and the R8064 (r_*; r_ack marks the
// clock its access was executed, r_rd is valid at r_ack for reads). Memory accesses carry the subslot (m_ss / r_ss).
// I/O map on the MSX side (defaults; the PSG bases are configurable):
//   0Eh index / 0Fh data : audio configuration registers (below)
//   10h-12h PSG #1 (address, data write, data read)   14h-16h PSG #2
//   AAh, ABh             : snooped (writes only) for the click bit
// Configuration registers (index at 0Eh):
//   00h-19h volume L/R of mixer source 0..12 (even = L, odd = R; 64 = unity)   1Fh master volume (64 = unity)
//   20h PSG #1 base port   21h PSG #2 base port
// Mixer sources: 0 click, 1 PSG #1, 2 PSG #2, 3 SCC #1, 4 SCC #2, 5 Y8950 #1 ADPCM, 6 Y8950 #2 ADPCM, 7 OPL4 PCM,
//   8 wavetable, 9 OPL3 #1 A/B, 10 OPL3 #1 C/D, 11 OPL3 #2 A/B (Y8950 FM), 12 OPL3 #2 C/D (YM2413).
module r8064_audio #(parameter CPOM = 4)(
    input  wire        clk, rst,
    // MSX side (aud_slot_full)
    input  wire        io_we, io_re, input wire [7:0] io_a, io_wd, output reg io_hit, output reg [7:0] io_rd,
    input  wire        m_we, m_re, input wire [15:0] m_a, input wire [7:0] m_wd, input wire [1:0] m_ss,
    output reg         m_hit, output reg [7:0] m_rd,
    // R8064 side
    input  wire        r_io_we, r_io_re, input wire [7:0] r_io_a, r_io_wd,
    input  wire        r_m_we, r_m_re, input wire [15:0] r_m_a, input wire [7:0] r_m_wd, input wire [1:0] r_ss,
    output reg         r_ack, output reg [7:0] r_rd,
    // outputs
    output wire        i2s_bck, i2s_lrck, i2s_data, output wire opl_clk
);
    localparam NSRC = 13;
    wire ce_fm, ce_scc, ce_psg, ce_fs;
    aud_tick #(.CPOM(CPOM)) u_tick(.clk(clk), .rst(rst), .ce_fm(ce_fm), .ce_scc(ce_scc), .ce_psg(ce_psg), .ce_fs(ce_fs), .opl_clk(opl_clk));

    // ---------------- request arbitration (MSX first; one R8064 request held while the MSX uses the clock)
    wire msx_busy = io_we || io_re || m_we || m_re;
    reg rq_v; reg rq_io, rq_we; reg [15:0] rq_a; reg [7:0] rq_wd; reg [1:0] rq_ss;
    always @(posedge clk) begin
        if (rst) rq_v <= 1'b0;
        else if ((r_io_we || r_io_re || r_m_we || r_m_re) && !rq_v) begin
            rq_v <= 1'b1; rq_io <= r_io_we || r_io_re; rq_we <= r_io_we || r_m_we;
            rq_a <= (r_io_we || r_io_re) ? {8'h00, r_io_a} : r_m_a; rq_wd <= (r_io_we || r_io_re) ? r_io_wd : r_m_wd; rq_ss <= r_ss;
        end else if (rq_v && !msx_busy) rq_v <= 1'b0;
    end
    wire r_go = rq_v && !msx_busy;
    // internal bus
    wire        b_iowe = io_we || (r_go && rq_io && rq_we);
    wire        b_iore = io_re || (r_go && rq_io && !rq_we);
    wire        b_mwe  = m_we  || (r_go && !rq_io && rq_we);
    wire        b_mre  = m_re  || (r_go && !rq_io && !rq_we);
    wire [7:0]  b_ioa  = msx_busy ? io_a : rq_a[7:0];
    wire [15:0] b_ma   = msx_busy ? m_a : rq_a;
    wire [7:0]  b_wd   = msx_busy ? (io_we ? io_wd : m_wd) : rq_wd;
    wire [1:0]  b_ss   = msx_busy ? m_ss : rq_ss;

    // ---------------- configuration registers
    reg [7:0] cfg_idx; reg [7:0] cvol [0:2*NSRC-1]; reg [7:0] master, psg1_p, psg2_p;
    integer i;
    always @(posedge clk) begin
        if (rst) begin
            cfg_idx <= 0; master <= 8'd64; psg1_p <= 8'h10; psg2_p <= 8'h14;
            for (i = 0; i < 2*NSRC; i = i + 1) cvol[i] <= 8'd64;
        end else if (b_iowe) begin
            if (b_ioa == 8'h0E) cfg_idx <= b_wd;
            if (b_ioa == 8'h0F) begin
                if (cfg_idx < 2*NSRC) cvol[cfg_idx] <= b_wd;
                if (cfg_idx == 8'h1F) master <= b_wd;
                if (cfg_idx == 8'h20) psg1_p <= b_wd;
                if (cfg_idx == 8'h21) psg2_p <= b_wd;
            end
        end
    end
    reg [7:0] cfg_rd;
    always @* begin
        cfg_rd = 8'hFF;
        if (cfg_idx < 2*NSRC) cfg_rd = cvol[cfg_idx];
        else if (cfg_idx == 8'h1F) cfg_rd = master;
        else if (cfg_idx == 8'h20) cfg_rd = psg1_p;
        else if (cfg_idx == 8'h21) cfg_rd = psg2_p;
    end

    // ---------------- click (PPI port C bit 7: write to AAh, or bit set/reset command 0Fh/0Eh to ABh)
    reg click;
    always @(posedge clk) begin
        if (rst) click <= 1'b0;
        else if (io_we && io_a == 8'hAA) click <= io_wd[7];
        else if (io_we && io_a == 8'hAB && !io_wd[7] && io_wd[3:1] == 3'd7) click <= io_wd[0];
    end
    wire [15:0] s_click = click ? 16'd8192 : 16'd0;

    // ---------------- PSGs
    wire [7:0] p1_rd, p2_rd; wire [15:0] p1_o, p2_o;
    aud_psg u_psg1(.clk(clk), .rst(rst), .ce_psg(ce_psg), .ce_fs(ce_fs),
        .a_we(b_iowe && b_ioa == psg1_p), .d_we(b_iowe && b_ioa == psg1_p + 8'd1), .wd(b_wd), .rd(p1_rd), .out(p1_o));
    aud_psg u_psg2(.clk(clk), .rst(rst), .ce_psg(ce_psg), .ce_fs(ce_fs),
        .a_we(b_iowe && b_ioa == psg2_p), .d_we(b_iowe && b_ioa == psg2_p + 8'd1), .wd(b_wd), .rd(p2_rd), .out(p2_o));

    // ---------------- SCCs (subslots 0 and 1)
    wire [7:0] c1_rd, c2_rd; wire c1_hit, c2_hit; wire signed [15:0] c1_o, c2_o;
    aud_scc u_scc1(.clk(clk), .rst(rst), .ce_scc(ce_scc), .ce_fs(ce_fs), .m_we(b_mwe && b_ss == 2'd0), .m_re(b_mre && b_ss == 2'd0),
        .m_a(b_ma), .m_wd(b_wd), .m_rd(c1_rd), .m_hit(c1_hit), .out(c1_o));
    aud_scc u_scc2(.clk(clk), .rst(rst), .ce_scc(ce_scc), .ce_fs(ce_fs), .m_we(b_mwe && b_ss == 2'd1), .m_re(b_mre && b_ss == 2'd1),
        .m_a(b_ma), .m_wd(b_wd), .m_rd(c2_rd), .m_hit(c2_hit), .out(c2_o));

    // ---------------- MSX-MUSIC detection signature (subslot 2): "APRLOPLL" at 4018h, FFh elsewhere in 4000h-7FFFh
    reg [7:0] sig;
    always @* case (b_ma[2:0])
        3'd0: sig = "A"; 3'd1: sig = "P"; 3'd2: sig = "R"; 3'd3: sig = "L";
        3'd4: sig = "O"; 3'd5: sig = "P"; 3'd6: sig = "L"; default: sig = "L";
    endcase
    wire sig_hit = (b_ss == 2'd2) && (b_ma[15:14] == 2'd1);
    wire [7:0] sig_rd = (b_ma[15:3] == 13'h0803) ? sig : 8'hFF;

    // ---------------- read multiplexers
    reg hit_io; reg [7:0] rd_io;
    always @* begin
        hit_io = 1'b1; rd_io = 8'hFF;
        if (b_ioa == 8'h0E) rd_io = cfg_idx;
        else if (b_ioa == 8'h0F) rd_io = cfg_rd;
        else if (b_ioa == psg1_p + 8'd2) rd_io = p1_rd;
        else if (b_ioa == psg2_p + 8'd2) rd_io = p2_rd;
        else hit_io = 1'b0;
    end
    reg hit_m; reg [7:0] rd_m;
    always @* begin
        hit_m = 1'b0; rd_m = 8'hFF;
        if (b_ss == 2'd0 && c1_hit) begin hit_m = 1'b1; rd_m = c1_rd; end
        else if (b_ss == 2'd1 && c2_hit) begin hit_m = 1'b1; rd_m = c2_rd; end
        else if (sig_hit) begin hit_m = 1'b1; rd_m = sig_rd; end
    end
    always @* begin io_hit = hit_io; io_rd = rd_io; m_hit = hit_m; m_rd = rd_m; end
    always @(posedge clk) begin
        r_ack <= r_go; if (r_go) r_rd <= rq_io ? rd_io : rd_m;
    end

    // ---------------- mixer and I2S
    wire [NSRC*16-1:0] sl = {16'd0, 16'd0, 16'd0, 16'd0, 16'd0, 16'd0, 16'd0, 16'd0, c2_o, c1_o, p2_o, p1_o, s_click};
    wire [NSRC*8-1:0] vl, vr;
    genvar g;
    generate for (g = 0; g < NSRC; g = g + 1) begin : vv
        assign vl[g*8 +: 8] = cvol[2*g]; assign vr[g*8 +: 8] = cvol[2*g + 1];
    end endgenerate
    wire signed [23:0] mo_l, mo_r;
    aud_mix #(.NSRC(NSRC)) u_mix(.clk(clk), .rst(rst), .ce_fs(ce_fs), .src_l(sl), .src_r(sl), .vol_l(vl), .vol_r(vr),
        .master(master), .out_l(mo_l), .out_r(mo_r));
    aud_i2s #(.CPOM(CPOM)) u_i2s(.clk(clk), .rst(rst), .ce_fs(ce_fs), .in_l(mo_l), .in_r(mo_r), .bck(i2s_bck), .lrck(i2s_lrck), .sdata(i2s_data));
endmodule
