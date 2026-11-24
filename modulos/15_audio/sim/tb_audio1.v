// tb_audio1.v - phase 1: PSG #1 tone (left), SCC #1 waveform (right), register read-back, click, MSX-MUSIC signature.
// The I2S stream is decoded and the samples are written to aud1_out.txt (L R per line) for sim/check_audio1.py.
`timescale 1ns/1ps
module tb_audio1;
    reg clk = 0, rst = 1; always #8.7297 clk = ~clk;   // 57.2727 MHz
    reg io_we = 0, io_re = 0, m_we = 0, m_re = 0; reg [7:0] io_a = 0, io_wd = 0, m_wd = 0; reg [15:0] m_a = 0; reg [1:0] m_ss = 0;
    wire io_hit, m_hit; wire [7:0] io_rd, m_rd; wire r_ack; wire [7:0] r_rd; wire bck, lrck, sd, oclk;
    r8064_audio dut(.clk(clk), .rst(rst), .io_we(io_we), .io_re(io_re), .io_a(io_a), .io_wd(io_wd), .io_hit(io_hit), .io_rd(io_rd),
        .m_we(m_we), .m_re(m_re), .m_a(m_a), .m_wd(m_wd), .m_ss(m_ss), .m_hit(m_hit), .m_rd(m_rd),
        .r_io_we(1'b0), .r_io_re(1'b0), .r_io_a(8'd0), .r_io_wd(8'd0), .r_m_we(1'b0), .r_m_re(1'b0), .r_m_a(16'd0), .r_m_wd(8'd0), .r_ss(2'd0),
        .r_ack(r_ack), .r_rd(r_rd), .i2s_bck(bck), .i2s_lrck(lrck), .i2s_data(sd), .opl_clk(oclk),
        .o1_sy(1'b0), .o1_doab(1'b0), .o1_docd(1'b0), .o1_smpac(1'b0), .o1_smpbd(1'b0), .o2_sy(1'b0), .o2_doab(1'b0), .o2_docd(1'b0), .o2_smpac(1'b0), .o2_smpbd(1'b0),
        .am_ack(1'b0), .am_rd(8'h00));
    integer errs = 0, k, f;
    task iow(input [7:0] a, input [7:0] d); begin @(negedge clk); io_a = a; io_wd = d; io_we = 1; @(negedge clk); io_we = 0; repeat (4) @(negedge clk); end endtask
    task ior(input [7:0] a, output [7:0] d); begin @(negedge clk); io_a = a; io_re = 1; #1 d = io_rd; @(negedge clk); io_re = 0; repeat (4) @(negedge clk); end endtask
    task mw(input [1:0] s, input [15:0] a, input [7:0] d); begin @(negedge clk); m_ss = s; m_a = a; m_wd = d; m_we = 1; @(negedge clk); m_we = 0; repeat (4) @(negedge clk); end endtask
    task mr(input [1:0] s, input [15:0] a, output [7:0] d, output h); begin @(negedge clk); m_ss = s; m_a = a; m_re = 1; #1 d = m_rd; h = m_hit; @(negedge clk); m_re = 0; repeat (4) @(negedge clk); end endtask
    task chk(input [255:0] what, input [31:0] got, input [31:0] exp); begin if (got !== exp) begin errs = errs + 1; $display("ERROR %0s: got %h expected %h", what, got, exp); end end endtask
    // I2S decoder
    reg [5:0] bitn = 0; reg lr_d = 0; reg [31:0] sh = 0; reg signed [23:0] L = 0, R = 0; integer ns = 0; reg cap = 0;
    always @(posedge bck) begin
        if (lrck != lr_d) begin
            // the bit after the edge is the MSB; the previous 24 bits ended one slot before
            if (lr_d == 1'b0) L = sh[23:0]; else begin R = sh[23:0]; if (cap) begin $fwrite(f, "%0d %0d\n", L, R); ns = ns + 1; end end
            bitn = 0; sh = 0;
        end
        lr_d = lrck;
        if (bitn >= 1 && bitn <= 24) sh = {sh[30:0], sd};   // Philips: the MSB is one BCK after the LRCK edge
        bitn = bitn + 1;
    end
    reg [7:0] d; reg h;
    initial begin
        f = $fopen("aud1_out.txt", "w");
        repeat (20) @(negedge clk); rst = 0; repeat (20) @(negedge clk);
        // mixer: PSG #1 left only, SCC #1 right only, everything else off
        for (k = 0; k < 26; k = k + 1) begin iow(8'h0E, k); iow(8'h0F, 8'd0); end
        iow(8'h0E, 8'd2); iow(8'h0F, 8'd64); iow(8'h0E, 8'd7); iow(8'h0F, 8'd64);
        iow(8'h0E, 8'd7); ior(8'h0F, d); chk("config read", d, 8'd64);
        // PSG #1: channel A 440 Hz (TP = 254), volume 15, tone A only
        iow(8'h10, 8'd0); iow(8'h11, 8'd254); iow(8'h10, 8'd1); iow(8'h11, 8'd0);
        iow(8'h10, 8'd7); iow(8'h11, 8'hBE); iow(8'h10, 8'd8); iow(8'h11, 8'd15);
        iow(8'h10, 8'd0); ior(8'h12, d); chk("PSG R0 read", d, 8'd254);
        iow(8'h10, 8'd1); iow(8'h11, 8'hF0); ior(8'h12, d); chk("PSG R1 read mask", d, 8'h00);
        // SCC #1 (subslot 0): enable, square waveform on channel 1, 880 Hz (F = 126), volume 15
        mw(2'd0, 16'h9000, 8'h3F);
        for (k = 0; k < 32; k = k + 1) mw(2'd0, 16'h9800 + k, k < 16 ? 8'd100 : -8'sd100);
        mw(2'd0, 16'h9880, 8'd126); mw(2'd0, 16'h9881, 8'd0); mw(2'd0, 16'h988A, 8'd15); mw(2'd0, 16'h988F, 8'h01);
        mr(2'd0, 16'h9805, d, h); chk("SCC wave read", {h, d}, {1'b1, 8'd100});
        mr(2'd0, 16'h9880, d, h); chk("SCC freq reads FF", {h, d}, {1'b1, 8'hFF});
        mr(2'd1, 16'h9805, d, h); chk("SCC #2 disabled: no answer", h, 1'b0);
        mr(2'd2, 16'h4018, d, h); chk("signature A", {h, d}, {1'b1, 8'h41});
        mr(2'd2, 16'h401F, d, h); chk("signature L", {h, d}, {1'b1, 8'h4C});
        // capture 0.1 s
        repeat (2) @(posedge lrck); cap = 1;
        repeat (4972) @(posedge lrck);
        cap = 0; $fclose(f);
        $display("samples %0d", ns);
        if (errs == 0) $display("RESULT: AUDIO PHASE 1 REGISTERS OK"); else $display("RESULT: %0d ERRORS", errs);
        $finish;
    end
endmodule
