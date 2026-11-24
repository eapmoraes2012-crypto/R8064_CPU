// r8064_audio.v - MSX audio subsystem of the R8064 (Tang Mega 60K design):
//   key click (PPI port C bit 7 snooped at AAh/ABh), two PSGs, two SCCs (subslots 0 and 1), the MSX-MUSIC detection
//   signature (subslot 2), two YM2413 and the FM part of two Y8950 played on external OPL3 #2 (aud_fm2), the ADPCM of the
//   two Y8950 (sample RAM in the audio memory), mixer and I2S output. Phases 3-4 add the OPL4 (FM on OPL3 #1, PCM) and
//   the wavetable synthesizer (their mixer inputs are already reserved).
// Two request buses reach the devices: the MSX slot (from aud_slot_full; priority) and the R8064 (r_*; r_ack marks the
// clock its access was executed, r_rd is valid at r_ack for reads). Memory accesses carry the subslot (m_ss / r_ss).
// I/O map on the MSX side (defaults; the PSG bases are configurable):
//   0Eh index / 0Fh data : audio configuration registers (below)
//   10h-12h PSG #1 (address, data write, data read)   14h-16h PSG #2
//   7Ch/7Dh YM2413 #1 (address, data)   78h/79h YM2413 #2
//   C0h/C1h Y8950 #1 (address+status, data)   C2h/C3h Y8950 #2
//   AAh, ABh             : snooped (writes only) for the click bit
// Configuration registers (index at 0Eh):
//   00h-19h volume L/R of mixer source 0..12 (even = L, odd = R; 64 = unity)   1Fh master volume (64 = unity)
//   20h PSG #1 base port   21h PSG #2 base port   22h YM2413 #1 base   23h YM2413 #2 base   24h Y8950 #1 base   25h Y8950 #2 base
//   28h/29h OPL3 #1/#2 serial capture format (see aud_opl3_rx)   30h owners: bits 1-0 YM2413, 3-2 Y8950 (0 auto, 1 #1, 2 #2)
//   31h (read) current owners: bit 0 YM2413, bit 1 Y8950 (0 = #1)
// Mixer sources: 0 click, 1 PSG #1, 2 PSG #2, 3 SCC #1, 4 SCC #2, 5 Y8950 #1 ADPCM, 6 Y8950 #2 ADPCM, 7 OPL4 PCM,
//   8 wavetable, 9 OPL3 #1 A/B, 10 OPL3 #1 C/D, 11 OPL3 #2 A/B (Y8950 FM), 12 OPL3 #2 C/D (YM2413).
module r8064_audio #(parameter CPOM = 4, parameter IDLE_FS = 49716)(
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
    output wire        i2s_bck, i2s_lrck, i2s_data, output wire opl_clk,
    output wire        irq,                                  // to the slot /INT (Y8950 timers/ADPCM)
    // external OPL3 #1 and #2 (bus out, serial DAC stream in)
    output wire [1:0]  o1_a, output wire [7:0] o1_d, output wire o1_cs_n, o1_wr_n, o1_rd_n, o1_ic_n,
    input  wire        o1_sy, o1_doab, o1_docd, o1_smpac, o1_smpbd,
    output wire [1:0]  o2_a, output wire [7:0] o2_d, output wire o2_cs_n, o2_wr_n, o2_rd_n, o2_ic_n,
    input  wire        o2_sy, o2_doab, o2_docd, o2_smpac, o2_smpbd,
    // audio memory (to the SoC memory system)
    output wire        am_req, am_we, output wire [23:0] am_addr, output wire [7:0] am_wd, input wire am_ack, input wire [7:0] am_rd
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
    wire own_o, own_y;
    reg [7:0] cfg_idx; reg [7:0] cvol [0:2*NSRC-1]; reg [7:0] master, psg1_p, psg2_p, opl1_p, opl2_p, y1_p, y2_p, fmt1, fmt2, own_cfg;
    integer i;
    always @(posedge clk) begin
        if (rst) begin
            cfg_idx <= 0; master <= 8'd64; psg1_p <= 8'h10; psg2_p <= 8'h14; opl1_p <= 8'h7C; opl2_p <= 8'h78; y1_p <= 8'hC0; y2_p <= 8'hC2;
            fmt1 <= 8'h00; fmt2 <= 8'h00; own_cfg <= 8'h00;
            for (i = 0; i < 2*NSRC; i = i + 1) cvol[i] <= 8'd64;
        end else if (b_iowe) begin
            if (b_ioa == 8'h0E) cfg_idx <= b_wd;
            if (b_ioa == 8'h0F) begin
                if (cfg_idx < 2*NSRC) cvol[cfg_idx] <= b_wd;
                if (cfg_idx == 8'h1F) master <= b_wd;
                if (cfg_idx == 8'h20) psg1_p <= b_wd;
                if (cfg_idx == 8'h21) psg2_p <= b_wd;
                if (cfg_idx == 8'h22) opl1_p <= b_wd;  if (cfg_idx == 8'h23) opl2_p <= b_wd;
                if (cfg_idx == 8'h24) y1_p <= b_wd;    if (cfg_idx == 8'h25) y2_p <= b_wd;
                if (cfg_idx == 8'h28) fmt1 <= b_wd;    if (cfg_idx == 8'h29) fmt2 <= b_wd;
                if (cfg_idx == 8'h30) own_cfg <= b_wd;
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
        else if (cfg_idx == 8'h22) cfg_rd = opl1_p;  else if (cfg_idx == 8'h23) cfg_rd = opl2_p;
        else if (cfg_idx == 8'h24) cfg_rd = y1_p;    else if (cfg_idx == 8'h25) cfg_rd = y2_p;
        else if (cfg_idx == 8'h28) cfg_rd = fmt1;    else if (cfg_idx == 8'h29) cfg_rd = fmt2;
        else if (cfg_idx == 8'h30) cfg_rd = own_cfg; else if (cfg_idx == 8'h31) cfg_rd = {6'd0, own_y, own_o};
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

    // ---------------- Y8950 #1/#2 (ADPCM, timers, status; FM to aud_fm2)
    wire [7:0] y1_st, y2_st, y1_rd, y2_rd; wire y1_fwe, y2_fwe, y1_irq, y2_irq; wire [7:0] y1_fr, y1_fd, y2_fr, y2_fd;
    wire signed [15:0] y1_o, y2_o; wire [7:0] y_sha; wire [7:0] y1_shd, y2_shd;
    wire [3:0] mc_req, mc_we, mc_ack; wire [95:0] mc_addr; wire [31:0] mc_wd; wire [7:0] mc_rd;
    wire [17:0] y1_ma, y2_ma;
    aud_y8950 u_y1(.clk(clk), .rst(rst), .ce_fs(ce_fs), .a_we(b_iowe && b_ioa == y1_p), .d_we(b_iowe && b_ioa == y1_p + 8'd1),
        .d_re(b_iore && b_ioa == y1_p + 8'd1), .wd(b_wd), .st(y1_st), .drd(y1_rd), .fm_we(y1_fwe), .fm_reg(y1_fr), .fm_d(y1_fd), .irq(y1_irq),
        .mreq(mc_req[0]), .mwe(mc_we[0]), .maddr(y1_ma), .mwd(mc_wd[7:0]), .mack(mc_ack[0]), .mrd(mc_rd), .out(y1_o), .sh_a(y_sha), .sh_d(y1_shd));
    aud_y8950 u_y2(.clk(clk), .rst(rst), .ce_fs(ce_fs), .a_we(b_iowe && b_ioa == y2_p), .d_we(b_iowe && b_ioa == y2_p + 8'd1),
        .d_re(b_iore && b_ioa == y2_p + 8'd1), .wd(b_wd), .st(y2_st), .drd(y2_rd), .fm_we(y2_fwe), .fm_reg(y2_fr), .fm_d(y2_fd), .irq(y2_irq),
        .mreq(mc_req[1]), .mwe(mc_we[1]), .maddr(y2_ma), .mwd(mc_wd[15:8]), .mack(mc_ack[1]), .mrd(mc_rd), .out(y2_o), .sh_a(y_sha), .sh_d(y2_shd));
    assign mc_addr[23:0] = {6'h00, y1_ma}; assign mc_addr[47:24] = {6'h01, y2_ma};
    assign mc_req[3:2] = 2'b00; assign mc_we[3:2] = 2'b00; assign mc_addr[95:48] = 0; assign mc_wd[31:16] = 0;   // OPL4 PCM, wavetable (phases 3-4)
    aud_mem #(.NC(4)) u_mem(.clk(clk), .rst(rst), .c_req(mc_req), .c_we(mc_we), .c_addr(mc_addr), .c_wd(mc_wd), .c_ack(mc_ack), .c_rd(mc_rd),
        .m_req(am_req), .m_we(am_we), .m_addr(am_addr), .m_wd(am_wd), .m_ack(am_ack), .m_rd(am_rd));
    assign irq = y1_irq | y2_irq;

    // ---------------- OPL3 #2 front-end (YM2413 x 2 -> bank 0, Y8950 FM x 2 -> bank 1) and the two OPL3 buses
    wire q2_we, q2_full, q2_empty; wire [16:0] q2_d;
    aud_fm2 #(.IDLE_FS(IDLE_FS)) u_fm2(.clk(clk), .rst(rst), .ce_fs(ce_fs), .cfg_o(own_cfg[1:0]), .cfg_y(own_cfg[3:2]), .own_o(own_o), .own_y(own_y),
        .o_awe({b_iowe && b_ioa == opl2_p, b_iowe && b_ioa == opl1_p}), .o_dwe({b_iowe && b_ioa == opl2_p + 8'd1, b_iowe && b_ioa == opl1_p + 8'd1}), .o_wd(b_wd),
        .y_we({y2_fwe, y1_fwe}), .y_reg({y2_fr, y1_fr}), .y_d({y2_fd, y1_fd}), .y_sha(y_sha), .y_shd({y2_shd, y1_shd}),
        .wq_we(q2_we), .wq_d(q2_d), .wq_full(q2_full));
    wire q1_full, q1_empty;
    aud_opl3_if #(.CPOM(CPOM), .INIT_NEW(0)) u_o1(.clk(clk), .rst(rst), .ce_fm(ce_fm), .wq_we(1'b0), .wq_d(17'd0), .wq_full(q1_full), .wq_empty(q1_empty),
        .opl_a(o1_a), .opl_d(o1_d), .opl_cs_n(o1_cs_n), .opl_wr_n(o1_wr_n), .opl_rd_n(o1_rd_n), .opl_ic_n(o1_ic_n));
    aud_opl3_if #(.CPOM(CPOM), .INIT_NEW(1)) u_o2(.clk(clk), .rst(rst), .ce_fm(ce_fm), .wq_we(q2_we), .wq_d(q2_d), .wq_full(q2_full), .wq_empty(q2_empty),
        .opl_a(o2_a), .opl_d(o2_d), .opl_cs_n(o2_cs_n), .opl_wr_n(o2_wr_n), .opl_rd_n(o2_rd_n), .opl_ic_n(o2_ic_n));
    wire signed [15:0] x1a, x1b, x1c, x1d, x2a, x2b, x2c, x2d;
    aud_opl3_rx u_r1(.clk(clk), .rst(rst), .ce_fs(ce_fs), .fmt(fmt1[3:0]), .sy(o1_sy), .doab(o1_doab), .docd(o1_docd), .smpac(o1_smpac), .smpbd(o1_smpbd),
        .a(x1a), .b(x1b), .c(x1c), .d(x1d));
    aud_opl3_rx u_r2(.clk(clk), .rst(rst), .ce_fs(ce_fs), .fmt(fmt2[3:0]), .sy(o2_sy), .doab(o2_doab), .docd(o2_docd), .smpac(o2_smpac), .smpbd(o2_smpbd),
        .a(x2a), .b(x2b), .c(x2c), .d(x2d));

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
        else if (b_ioa == y1_p) rd_io = y1_st;   else if (b_ioa == y1_p + 8'd1) rd_io = y1_rd;
        else if (b_ioa == y2_p) rd_io = y2_st;   else if (b_ioa == y2_p + 8'd1) rd_io = y2_rd;
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
    wire [NSRC*16-1:0] sl = {x2c, x2a, x1c, x1a, 16'd0, 16'd0, y2_o, y1_o, c2_o, c1_o, p2_o, p1_o, s_click};
    wire [NSRC*16-1:0] sr = {x2d, x2b, x1d, x1b, 16'd0, 16'd0, y2_o, y1_o, c2_o, c1_o, p2_o, p1_o, s_click};
    wire [NSRC*8-1:0] vl, vr;
    genvar g;
    generate for (g = 0; g < NSRC; g = g + 1) begin : vv
        assign vl[g*8 +: 8] = cvol[2*g]; assign vr[g*8 +: 8] = cvol[2*g + 1];
    end endgenerate
    wire signed [23:0] mo_l, mo_r;
    aud_mix #(.NSRC(NSRC)) u_mix(.clk(clk), .rst(rst), .ce_fs(ce_fs), .src_l(sl), .src_r(sr), .vol_l(vl), .vol_r(vr),
        .master(master), .out_l(mo_l), .out_r(mo_r));
    aud_i2s #(.CPOM(CPOM)) u_i2s(.clk(clk), .rst(rst), .ce_fs(ce_fs), .in_l(mo_l), .in_r(mo_r), .bck(i2s_bck), .lrck(i2s_lrck), .sdata(i2s_data));
endmodule
