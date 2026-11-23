`timescale 1ns/1ps
// Real monitor (fw/monitor_l0..7.hex) in the full SoC, with the MSX side simulated by tasks (FIFO/ports 0..3 and window).
// Tests: PING, HELLO, unknown OP, WIN_PUT (CRC), WIN_GET, unaligned POKE/PEEK, CRC, EXEC (+EVT 01), misalignment.
module tb_soc_mon;
    reg clk = 0, rst = 1; always #5 clk = ~clk;
    wire io_oe, iox_we, iox_re; wire [7:0] io_rd, iox_a, iox_wd;
    wire nat, csel, z80, rom, mbusy, cv, dbg_sig, init_done, fifo_irq, fifo_rst, fbi, fbd, i_fault, d_fault; wire [2:0] ic, dc; wire [63:0] dbg_pc; wire [7:0] dbg_f, fm_rd, sb_rd;
    wire s_cke, s_cs_n, s_ras_n, s_cas_n, s_we_n, s_dq_oe; wire [3:0] s_dqm; wire [1:0] s_ba; wire [10:0] s_a; wire [31:0] s_dq_o, mdq;
    reg fm_we = 0, fm_re = 0; reg [1:0] fm_a = 0; reg [7:0] fm_wd = 0;
    reg sb_we = 0, sb_re = 0; reg [13:0] sb_a = 0; reg [7:0] sb_wd = 0;
    reg [31:0] dq_in; always @* dq_in = mdq;
    r8064_soc #(.INIT_CYC(2000), .BOOT_WORDS(2048), .INIT_IMG(1)) dut(.clk(clk), .rst(rst), .irq(1'b0),
        .io_we(1'b0), .io_re(1'b0), .io_a(8'd0), .io_wd(8'd0), .io_rd(io_rd), .io_oe(io_oe), .io_x_we(iox_we), .io_x_re(iox_re), .io_x_a(iox_a), .io_x_wd(iox_wd), .io_x_rd(8'h00), .port_c(8'd0),
        .sb_we(sb_we), .sb_re(sb_re), .sb_a(sb_a), .sb_wd(sb_wd), .sb_rd(sb_rd), .fm_we(fm_we), .fm_re(fm_re), .fm_a(fm_a), .fm_wd(fm_wd), .fm_rd(fm_rd), .fifo_irq(fifo_irq), .fifo_rst(fifo_rst),
        .native64(nat), .clk_sel(csel), .is_z80(z80), .is_rom(rom), .mode_busy(mbusy), .dbg_pc(dbg_pc), .dbg_f(dbg_f), .dbg_sig(dbg_sig), .gov_cv(cv),
        .fl_busy_i(fbi), .fl_busy_d(fbd), .mmu_en(), .mmu_user(),
        .i_fault(i_fault), .d_fault(d_fault), .i_cause(ic), .d_cause(dc),
        .init_done(init_done), .s_cke(s_cke), .s_cs_n(s_cs_n), .s_ras_n(s_ras_n), .s_cas_n(s_cas_n), .s_we_n(s_we_n), .s_dqm(s_dqm), .s_ba(s_ba), .s_a(s_a),
        .s_dq_o(s_dq_o), .s_dq_oe(s_dq_oe), .s_dq_i(dq_in));
    defparam dut.u_xbuf.INIT_PFX = "../fw/monitor_l";
    sdram_model mdl(.clk(clk), .cke(s_cke), .cs_n(s_cs_n), .ras_n(s_ras_n), .cas_n(s_cas_n), .we_n(s_we_n), .dqm(s_dqm), .ba(s_ba), .a(s_a), .dq_i(s_dq_o), .dq_oe(s_dq_oe), .dq_o(mdq));
    integer errs = 0, k, n, psz;
    task chk(input [255:0] nome, input [63:0] got, input [63:0] exp);
        if (got !== exp) begin errs = errs + 1; $display("ERROR %0s: got %h expected %h", nome, got, exp); end
    endtask
    // ---- MSX side ----
    task fmw(input [1:0] a, input [7:0] d); begin @(posedge clk); #1 fm_a = a; fm_wd = d; fm_we = 1; @(posedge clk); #1 fm_we = 0; end endtask
    task fmr(input [1:0] a, output [7:0] d); begin @(posedge clk); #1 fm_a = a; fm_re = 1; #1 d = fm_rd; @(posedge clk); #1 fm_re = 0; end endtask
    task sbw(input [13:0] a, input [7:0] d); begin @(posedge clk); #1 sb_a = a; sb_wd = d; sb_we = 1; @(posedge clk); #1 sb_we = 0; end endtask
    task sbr(input [13:0] a, output [7:0] d); begin @(posedge clk); #1 sb_a = a; @(posedge clk); #1 sb_re = 1; #1 d = sb_rd; @(posedge clk); #1 sb_re = 0; end endtask
    reg [7:0] msg [0:2047]; reg [7:0] rsp [0:2047]; integer rlen; reg [7:0] t8;
    task send(input integer len); integer i; begin
        for (i = 0; i < len; i = i + 1) fmw(2'd0, msg[i]);
        fmw(2'd2, len[7:0]); fmw(2'd3, len[15:8]);
        fmw(2'd1, 8'h01);                       // INICIAR
    end endtask
    task waitdone(input integer maxclk); integer c, i; reg [7:0] s, lo, hi; begin
        s = 0; c = 0;
        while (!s[3] && c < maxclk) begin fmr(2'd1, s); c = c + 1; repeat (20) @(posedge clk); end
        if (!s[3]) begin errs = errs + 1; $display("ERROR: timeout waiting for DONE"); rlen = 0; end
        else begin
            fmr(2'd2, lo); fmr(2'd3, hi); rlen = {hi, lo};
            for (i = 0; i < rlen; i = i + 1) fmr(2'd0, rsp[i]);
            fmw(2'd1, 8'h80);                   // clears DONE
        end
    end endtask
    function [15:0] crcb(input [15:0] c, input [7:0] b); integer j; reg [15:0] x; begin
        x = c ^ {b, 8'h00};
        for (j = 0; j < 8; j = j + 1) x = x[15] ? ((x << 1) ^ 16'h1021) : (x << 1);
        crcb = x;
    end endfunction
    function [7:0] pat(input integer i); pat = (i * 7 + 3) & 255; endfunction
    function [7:0] pat2(input integer i); pat2 = (i * 13 + 5) & 255; endfunction
    reg [15:0] c; reg [7:0] b;
    function [7:0] sdb(input integer a); reg [31:0] w; begin w = mdl.mem[a >> 2]; sdb = w >> (8 * (a & 3)); end endfunction
    task req(input [7:0] op, input [7:0] seq); begin msg[0] = op; msg[1] = seq; end endtask
    task put32(input integer o, input [31:0] v); begin msg[o] = v[7:0]; msg[o+1] = v[15:8]; msg[o+2] = v[23:16]; msg[o+3] = v[31:24]; end endtask
    initial begin
        repeat (4) @(posedge clk); rst = 0;
        wait (init_done);
        wait (!dut.boot_busy);
        repeat (3000) @(posedge clk);
        // 1. PING
        req(8'h00, 8'h05); send(2); waitdone(4000);
        chk("PING len", rlen, 3); chk("PING op", rsp[0], 8'h80); chk("PING seq", rsp[1], 8'h05); chk("PING st", rsp[2], 8'h00);
        $display("PING ok (t=%0t)", $time);
        // 2. HELLO
        req(8'h01, 8'h06); msg[2] = 8'h01; send(3); waitdone(4000);
        chk("HELLO len", rlen, 14); chk("HELLO op", rsp[0], 8'h81); chk("HELLO 'R'", rsp[3], 8'h52); chk("HELLO '4'", rsp[7], 8'h34); chk("HELLO ver", rsp[8], 1);
        chk("HELLO msgmax", {rsp[10], rsp[9]}, 16'h0800); chk("HELLO block", {rsp[12], rsp[11]}, 16'h4000); `ifdef R8064_NO_DMA chk("HELLO rec (no window)", rsp[13], 8'h06); `else chk("HELLO rec", rsp[13], 8'h07); `endif
        $display("HELLO ok");
        // 3. unknown OP
        req(8'h55, 8'h07); send(2); waitdone(4000);
        chk("op desc st", rsp[2], 8'h01); chk("op desc seq", rsp[1], 8'h07);
`ifdef R8064_NO_DMA
        // 4/5. without the DMA the window buffer is not reachable: WIN_PUT / WIN_GET answer ST 04; the data for the CRC test comes by POKE
        req(8'h10, 8'h08); put32(2, 32'h0001_0000); msg[6] = 0; msg[7] = 8'h10; send(8); waitdone(60000);
        chk("PUT st (no DMA)", rsp[2], 8'h04);
        req(8'h11, 8'h09); put32(2, 32'h0001_0400); msg[6] = 8'h00; msg[7] = 8'h04; send(8); waitdone(60000);
        chk("GET st (no DMA)", rsp[2], 8'h04);
        req(8'h12, 8'h10); put32(2, 32'h0001_0000); for (k = 0; k < 2040; k = k + 1) msg[6 + k] = pat(k); send(2046); waitdone(400000);
        chk("POKE 2040 st", rsp[2], 0);
        n = 0; for (k = 0; k < 2040; k = k + 1) if (sdb(32'h10000 + k) !== pat(k)) n = n + 1;
        chk("POKE 2040 data in SDRAM (wrong bytes)", n, 0);
        $display("WIN_PUT/WIN_GET refused, POKE 2040 ok");
`else
        // 4. WIN_PUT -> 10000h (psz = 4096 by default; +big = full 16 KB block)
        psz = 4096; if ($test$plusargs("big")) psz = 16384;
        for (k = 0; k < 16384; k = k + 1) sbw(k[13:0], pat(k));
        req(8'h10, 8'h08); put32(2, 32'h0001_0000); msg[6] = psz[7:0]; msg[7] = psz[15:8]; if (psz == 16384) begin msg[6] = 0; msg[7] = 0; end send(8); waitdone(60000);
        c = 16'hFFFF; for (k = 0; k < psz; k = k + 1) c = crcb(c, pat(k));
        chk("PUT len", rlen, 5); chk("PUT op", rsp[0], 8'h90); chk("PUT st", rsp[2], 0); chk("PUT crc", {rsp[4], rsp[3]}, c);
        n = 0; for (k = 0; k < psz; k = k + 1) if (sdb(32'h10000 + k) !== pat(k)) n = n + 1;
        chk("PUT data in SDRAM (wrong bytes)", n, 0);
        $display("WIN_PUT ok crc=%h (t=%0t)", c, $time);
        // 5. WIN_GET: SDRAM[10000h .. +4096] -> window; the MSX reads the window
        req(8'h11, 8'h09); put32(2, 32'h0001_0400); msg[6] = 8'h00; msg[7] = 8'h04; send(8); waitdone(60000);
        c = 16'hFFFF; for (k = 0; k < 1024; k = k + 1) c = crcb(c, pat(1024 + k));
        chk("GET len", rlen, 5); chk("GET st", rsp[2], 0); chk("GET crc", {rsp[4], rsp[3]}, c);
        n = 0; for (k = 0; k < 1024; k = k + 1) begin sbr(k[13:0], t8); if (t8 !== pat(1024 + k)) n = n + 1; end
        chk("GET window (wrong bytes)", n, 0);
        $display("WIN_GET ok");
`endif
        // 6. unaligned POKE at 20003h (5 bytes) + PEEK of 20000h (16 bytes)
        req(8'h12, 8'h0A); put32(2, 32'h0002_0003); for (k = 0; k < 5; k = k + 1) msg[6 + k] = 8'hA0 + k; send(11); waitdone(60000);
        chk("POKE st", rsp[2], 0); chk("POKE len", rlen, 3);
        req(8'h13, 8'h0B); put32(2, 32'h0002_0000); msg[6] = 16; msg[7] = 0; send(8); waitdone(60000);
        chk("PEEK len", rlen, 19); chk("PEEK st", rsp[2], 0);
        for (k = 0; k < 16; k = k + 1) chk("PEEK byte", rsp[3 + k], (k >= 3 && k < 8) ? (8'hA0 + k - 3) : 8'h00);
        chk("SDRAM 20003h", sdb(32'h20003), 8'hA0); chk("SDRAM 20007h", sdb(32'h20007), 8'hA4); chk("SDRAM 20008h intact", sdb(32'h20008), 8'h00);
        $display("POKE/PEEK ok");
        // 7. CRC de 100 bytes em 10008h
        req(8'h30, 8'h0C); put32(2, 32'h0001_0008); put32(6, 32'd100); send(10); waitdone(60000);
        c = 16'hFFFF; for (k = 0; k < 100; k = k + 1) c = crcb(c, pat(8 + k));
        chk("CRC st", rsp[2], 0); chk("CRC value", {rsp[4], rsp[3]}, c);
        $display("CRC ok");
        // 8. errors: misaligned WIN_PUT, EXEC mode 1
        req(8'h10, 8'h0D); put32(2, 32'h0001_0004); msg[6] = 0; msg[7] = 0; send(8); waitdone(60000);
        chk("misaligned st", rsp[2], 8'h03);
        // 9. EXEC: program at 4000h (via WIN_PUT): LD A,77h; LD (5000h),A; LD HL,0ABCDh; RET
        msg[0] = 8'h3E; msg[1] = 8'h77; msg[2] = 8'h32; msg[3] = 8'h00; msg[4] = 8'h50; msg[5] = 8'h21; msg[6] = 8'hCD; msg[7] = 8'hAB; msg[8] = 8'hC9;
`ifdef R8064_NO_DMA
        for (k = 8; k >= 0; k = k - 1) msg[6 + k] = msg[k];
        req(8'h12, 8'h0E); put32(2, 32'h0000_4000); send(15); waitdone(60000);
`else
        for (k = 0; k < 16; k = k + 1) sbw(k[13:0], k < 9 ? msg[k] : 8'h00);
        req(8'h10, 8'h0E); put32(2, 32'h0000_4000); msg[6] = 16; msg[7] = 0; send(8); waitdone(60000);
`endif
        chk("PUT prog st", rsp[2], 0);
        req(8'h20, 8'h0F); for (k = 2; k < 19; k = k + 1) msg[k] = 0; msg[2] = 8'h00; msg[3] = 8'h40; send(19); waitdone(60000);
        chk("EXEC resp op", rsp[0], 8'hA0); chk("EXEC resp st", rsp[2], 0);
        waitdone(60000);
        chk("EVT len", rlen, 7); chk("EVT op", rsp[0], 8'hF0); chk("EVT seq", rsp[1], 0); chk("EVT cod", rsp[2], 8'h01);
        chk("EVT output", {rsp[4], rsp[3]}, 16'hABCD);
        chk("program wrote 5000h", sdb(32'h5000), 8'h77);
        $display("EXEC ok");
        // 10. the same address loaded again with another program (LD HL,1234h; RET) and run: the I cache must not keep the old code
        req(8'h12, 8'h11); put32(2, 32'h0000_4000); msg[6] = 8'h21; msg[7] = 8'h34; msg[8] = 8'h12; msg[9] = 8'hC9; send(10); waitdone(60000);
        chk("POKE prog 2 st", rsp[2], 0);
        req(8'h20, 8'h12); for (k = 2; k < 19; k = k + 1) msg[k] = 0; msg[3] = 8'h40; send(19); waitdone(60000);
        chk("EXEC 2 st", rsp[2], 0);
        waitdone(60000);
        chk("EVT 2 output (new code)", {rsp[4], rsp[3]}, 16'h1234);
        $display("EXEC of reloaded code ok");
        // 11. self-modifying Z80 code (EXEC mode 01, Z80 in DRAM): a loop patches the operand of an instruction it has already run, then
        //     the code patches the instruction right after the store. Expected HL = 1 + 2 + 4 + 8 + 20h = 2Fh (stale code would give 24h or less)
        req(8'h12, 8'h13); put32(2, 32'h0000_4000);
        msg[6]  = 8'h21; msg[7]  = 8'h00; msg[8]  = 8'h00; msg[9]  = 8'h06; msg[10] = 8'h04; msg[11] = 8'h11; msg[12] = 8'h01; msg[13] = 8'h00;
        msg[14] = 8'h19; msg[15] = 8'h3A; msg[16] = 8'h06; msg[17] = 8'h40; msg[18] = 8'h87; msg[19] = 8'h32; msg[20] = 8'h06; msg[21] = 8'h40;
        msg[22] = 8'h10; msg[23] = 8'hF3; msg[24] = 8'h3E; msg[25] = 8'h20; msg[26] = 8'h32; msg[27] = 8'h18; msg[28] = 8'h40; msg[29] = 8'h11;
        msg[30] = 8'h00; msg[31] = 8'h00; msg[32] = 8'h19; msg[33] = 8'hC9; send(34); waitdone(60000);
        chk("POKE smc st", rsp[2], 0);
        req(8'h20, 8'h14); for (k = 2; k < 19; k = k + 1) msg[k] = 0; msg[3] = 8'h40; msg[10] = 8'h01; send(19); waitdone(60000);
        chk("EXEC smc st", rsp[2], 0);
        waitdone(200000);
        chk("EVT smc output (self-modifying code)", {rsp[4], rsp[3]}, 16'h002F);
        $display("self-modifying Z80 code ok");
        $display("pc=%h", dbg_pc);
        if (errs == 0) $display("RESULT: MONITOR OK"); else $display("RESULT: %0d ERRORS", errs);
        $finish;
    end
    initial begin #400000000; $display("RESULT: TIMEOUT GLOBAL (pc=%h)", dbg_pc); $finish; end
endmodule
