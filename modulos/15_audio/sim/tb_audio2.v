// tb_audio2.v - phase 2: Y8950 status/timer/IRQ, ADPCM RAM write/read through R0F, ADPCM playback (compared with aud_ref.py),
// YM2413 -> OPL3 #2 bank 0 translation and Y8950 FM -> bank 1 (OPL3 register image rebuilt from the bus), YM2413 owner switch,
// OPL3 serial capture. Files: aud2_adpcm.txt (ADPCM output per sample), aud2_opl.txt (OPL3 #2 register image),
// aud2_sh.txt (YM2413 shadows) -> sim/check_audio2.py.
`timescale 1ns/1ps
module tb_audio2;
    reg clk = 0, rst = 1; always #8.7297 clk = ~clk;
    reg io_we = 0, io_re = 0; reg [7:0] io_a = 0, io_wd = 0; wire io_hit, m_hit; wire [7:0] io_rd, m_rd;
    wire r_ack; wire [7:0] r_rd; wire bck, lrck, sd, oclk, irq;
    wire [1:0] o1a, o2a; wire [7:0] o1d, o2d; wire o1cs, o1wr, o1rd, o1ic, o2cs, o2wr, o2rd, o2ic;
    wire am_req, am_we, am_ack; wire [23:0] am_addr; wire [7:0] am_wd, am_rd;
    reg sy = 0, doab = 0, docd = 0, smpac = 1, smpbd = 1;
    r8064_audio #(.IDLE_FS(300)) dut(.clk(clk), .rst(rst), .io_we(io_we), .io_re(io_re), .io_a(io_a), .io_wd(io_wd), .io_hit(io_hit), .io_rd(io_rd),
        .m_we(1'b0), .m_re(1'b0), .m_a(16'd0), .m_wd(8'd0), .m_ss(2'd0), .m_hit(m_hit), .m_rd(m_rd),
        .r_io_we(1'b0), .r_io_re(1'b0), .r_io_a(8'd0), .r_io_wd(8'd0), .r_m_we(1'b0), .r_m_re(1'b0), .r_m_a(16'd0), .r_m_wd(8'd0), .r_ss(2'd0),
        .r_ack(r_ack), .r_rd(r_rd), .i2s_bck(bck), .i2s_lrck(lrck), .i2s_data(sd), .opl_clk(oclk), .irq(irq),
        .o1_a(o1a), .o1_d(o1d), .o1_cs_n(o1cs), .o1_wr_n(o1wr), .o1_rd_n(o1rd), .o1_ic_n(o1ic), .o1_sy(1'b0), .o1_doab(1'b0), .o1_docd(1'b0), .o1_smpac(1'b0), .o1_smpbd(1'b0),
        .o2_a(o2a), .o2_d(o2d), .o2_cs_n(o2cs), .o2_wr_n(o2wr), .o2_rd_n(o2rd), .o2_ic_n(o2ic), .o2_sy(sy), .o2_doab(doab), .o2_docd(docd), .o2_smpac(smpac), .o2_smpbd(smpbd),
        .am_req(am_req), .am_we(am_we), .am_addr(am_addr), .am_wd(am_wd), .am_ack(am_ack), .am_rd(am_rd));
    aud_mem_model #(.LAT(12)) mm(.clk(clk), .m_req(am_req), .m_we(am_we), .m_addr(am_addr), .m_wd(am_wd), .m_ack(am_ack), .m_rd(am_rd));
    integer errs = 0, k, f, nw = 0;
    task iow(input [7:0] a, input [7:0] d); begin @(negedge clk); io_a = a; io_wd = d; io_we = 1; @(negedge clk); io_we = 0; repeat (60) @(negedge clk); end endtask
    task ior(input [7:0] a, output [7:0] d); begin @(negedge clk); io_a = a; io_re = 1; #1 d = io_rd; @(negedge clk); io_re = 0; repeat (60) @(negedge clk); end endtask
    task yw(input [7:0] r, input [7:0] d); begin iow(8'hC0, r); iow(8'hC1, d); end endtask
    task ow(input [7:0] p, input [7:0] r, input [7:0] d); begin iow(p, r); iow(p + 8'd1, d); end endtask
    task chk(input [255:0] what, input [31:0] got, input [31:0] exp); begin if (got !== exp) begin errs = errs + 1; $display("ERROR %0s: got %h expected %h", what, got, exp); end end endtask
    task waitq; begin wait (dut.u_o2.wq_empty && dut.u_o2.s == 2 && dut.u_fm2.ts == 0 && dut.u_fm2.chd == 0 && !dut.u_fm2.rhd && !dut.u_fm2.rp_act); repeat (100) @(negedge clk);
                      wait (dut.u_o2.wq_empty && dut.u_o2.s == 2); repeat (10) @(negedge clk); end endtask
    // OPL3 #2 register image from the bus
    reg [7:0] img [0:511]; reg [511:0] imv = 0; reg [8:0] oaddr;
    always @(posedge o2wr) if (!o2cs || 1) begin if (o2a[0] == 1'b0) oaddr = {o2a[1], o2d}; else begin img[oaddr] = o2d; imv[oaddr] = 1'b1; nw = nw + 1; end end
    // ADPCM output capture
    reg cap = 0; integer fa;
    always @(posedge clk) if (cap && dut.ce_fs) $fwrite(fa, "%0d\n", dut.u_y1.out);
    reg [7:0] d; integer seed = 7;
    task dump_img(input [255:0] tag); integer j; begin
        for (j = 0; j < 512; j = j + 1) if (imv[j]) $fwrite(f, "%0s %0d %0d\n", tag, j, img[j]);
    end endtask
    task dump_sh(input [255:0] tag, input integer which); integer j; begin
        for (j = 0; j < 64; j = j + 1) $fwrite(f, "%0s %0d %0d\n", tag, j, which ? dut.u_fm2.sh1[j] : dut.u_fm2.sh0[j]);
    end endtask
    // OPL3 serial stream model: SY = fM/4, 16-bit words MSB first, SMPAC / SMPBD falling edge after A/C and B/D words
    reg [15:0] wa = 16'h1234, wb = 16'hFEDC, wc = 16'h0F0F, wdd = 16'h8001;
    initial begin : ser
        integer b; #200000;
        forever begin
            for (b = 15; b >= 0; b = b - 1) begin doab = wa[b]; docd = wc[b]; #70; sy = 1; #70; sy = 0; end
            smpac = 0; #140; smpac = 1;
            for (b = 15; b >= 0; b = b - 1) begin doab = wb[b]; docd = wdd[b]; #70; sy = 1; #70; sy = 0; end
            smpbd = 0; #140; smpbd = 1; #2000;
        end
    end
    initial begin
        f = $fopen("aud2_opl.txt", "w"); fa = $fopen("aud2_adpcm.txt", "w");
        repeat (20) @(negedge clk); rst = 0;
        // ---- Y8950 status, timer 1, IRQ
        ior(8'hC0, d); chk("Y8950 idle status", d, 8'h06);
        yw(8'h02, 8'hFE); yw(8'h04, 8'h01);                   // T1 = 2 x 80 us, start, all unmasked
        repeat (8 * 1152 + 2000) @(negedge clk);
        ior(8'hC0, d); chk("Y8950 T1 + BUF RDY + IRQ", d & 8'hF8, 8'hC8); chk("irq line", irq, 1'b1);
        yw(8'h04, 8'h80); ior(8'hC0, d); chk("flags reset", d & 8'hF8, 8'h00); yw(8'h04, 8'h00);
        // ---- ADPCM RAM write / read through R0F (start 0, stop unit 7 -> 64 bytes)
        yw(8'h07, 8'h01); yw(8'h08, 8'h00); yw(8'h09, 8'h00); yw(8'h0A, 8'h00); yw(8'h0B, 8'h07); yw(8'h0C, 8'h00);
        yw(8'h07, 8'h60); iow(8'hC0, 8'h0F);
        for (k = 0; k < 64; k = k + 1) iow(8'hC1, (k * 37 + 11) & 8'hFF);
        ior(8'hC0, d); chk("EOS after the last write", d & 8'h10, 8'h10);
        for (k = 0; k < 64; k = k + 1) chk("RAM byte", mm.mem[k], (k * 37 + 11) & 8'hFF);
        yw(8'h07, 8'h20); iow(8'hC0, 8'h0F);
        ior(8'hC1, d); ior(8'hC1, d);                         // two dummy reads
        for (k = 0; k < 64; k = k + 1) begin ior(8'hC1, d); chk("RAM read-back", d, (k * 37 + 11) & 8'hFF); end
        // ---- ADPCM playback: delta-N 6000h, volume 200, no repeat
        yw(8'h04, 8'h80); yw(8'h10, 8'h00); yw(8'h11, 8'h60); yw(8'h12, 8'd200);
        @(posedge dut.ce_fs); cap = 1; yw(8'h07, 8'hA0);
        repeat (400) @(posedge dut.ce_fs); cap = 0;
        ior(8'hC0, d); chk("EOS after playback", d & 8'h11, 8'h10);
        // ---- YM2413 #1: user instrument on ch 0, ROM violin on ch 1 (key on), rhythm mode with BD + HH
        waitq;
        ow(8'h7C, 8'h00, 8'h31); ow(8'h7C, 8'h01, 8'h21); ow(8'h7C, 8'h02, 8'h1A); ow(8'h7C, 8'h03, 8'h1D);
        ow(8'h7C, 8'h04, 8'hF2); ow(8'h7C, 8'h05, 8'hE3); ow(8'h7C, 8'h06, 8'h24); ow(8'h7C, 8'h07, 8'h46);
        ow(8'h7C, 8'h30, 8'h05); ow(8'h7C, 8'h10, 8'hAB); ow(8'h7C, 8'h20, 8'h3D);    // ch0: user, vol 5, key + sus, block 6, f8 = 1
        ow(8'h7C, 8'h31, 8'h13); ow(8'h7C, 8'h11, 8'h55); ow(8'h7C, 8'h21, 8'h08);    // ch1: violin, vol 3, key off, block 4
        ow(8'h7C, 8'h16, 8'h20); ow(8'h7C, 8'h26, 8'h05); ow(8'h7C, 8'h17, 8'h50); ow(8'h7C, 8'h27, 8'h05);
        ow(8'h7C, 8'h18, 8'hC0); ow(8'h7C, 8'h28, 8'h01); ow(8'h7C, 8'h36, 8'h02); ow(8'h7C, 8'h37, 8'h43); ow(8'h7C, 8'h38, 8'h21);
        ow(8'h7C, 8'h0E, 8'h31);                                                    // rhythm, BD + HH keyed
        // ---- Y8950 FM -> bank 1
        yw(8'h20, 8'h21); yw(8'hC0, 8'h05); yw(8'hA0, 8'h44); yw(8'hB0, 8'h32); yw(8'hBD, 8'hFF);
        waitq; dump_sh("S1", 0); dump_img("A");
        chk("Y8950 C0 -> bank 1 outputs A/B", img[9'h1C0], 8'h35); chk("Y8950 A0", img[9'h1A0], 8'h44); chk("Y8950 B0", img[9'h1B0], 8'h32);
        chk("Y8950 20", img[9'h120], 8'h21); chk("Y8950 BD not written to bank 1", imv[9'h1BD], 1'b0);
        // ---- owner switch: #1 keys off and goes idle, #2 keys a note
        ow(8'h7C, 8'h20, 8'h1C); ow(8'h7C, 8'h0E, 8'h20);
        ow(8'h78, 8'h30, 8'h72); ow(8'h78, 8'h10, 8'h81); ow(8'h78, 8'h20, 8'h17);
        repeat (400) @(posedge dut.ce_fs);
        ow(8'h78, 8'h21, 8'h12);                         // a later write to #2 (already owner)
        waitq; chk("YM2413 owner is #2", dut.own_o, 1'b1);
        dump_sh("S2", 1); dump_img("B");
        // ---- serial capture
        iow(8'h0E, 8'h29); iow(8'h0F, 8'h00);
        repeat (3000) @(negedge clk);
        chk("rx A", dut.x2a, 16'h1234); chk("rx B", dut.x2b, 16'hFEDC); chk("rx C", dut.x2c, 16'h0F0F); chk("rx D", dut.x2d, 16'h8001);
        $fclose(f); $fclose(fa);
        $display("OPL3 #2 writes %0d", nw);
        if (errs == 0) $display("RESULT: AUDIO PHASE 2 REGISTERS OK"); else $display("RESULT: %0d ERRORS", errs);
        $finish;
    end
endmodule
