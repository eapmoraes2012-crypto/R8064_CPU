`timescale 1ns/1ps
// Full cartridge top (r8064_cart_top: clkgen + SoC + SDRAM + r8064_slot_if) with an "MSX" that generates Z80 I/O cycles on ports 0Bh/0Ch/0Dh
// (+p2 = second part: INT and /RESET) and talks to the real monitor (fw/monitor_l0..7.hex): PING, HELLO, unknown OP, and checks the slot /RESET and INT. Compile with -DSIM (rPLL model).
module tb_cart_mon;
    reg x14 = 0; always #(1000.0/(2*14.31818)) x14 = ~x14;
    reg iorq_n = 1, rd_n = 1, wr_n = 1, reset_n = 0; reg [7:0] a = 8'hFF; reg [7:0] dv = 0; reg dv_oe = 0;
    wire [7:0] slot_d; assign slot_d = dv_oe ? dv : 8'bz;
    wire dir, wt, intr, oe_n, dbg_sig, dbg_hb;
    wire O_clk, O_cke, O_cs, O_ras, O_cas, O_we; wire [3:0] O_dqm; wire [10:0] O_a; wire [1:0] O_ba; wire [31:0] dq, mdq;
    r8064_cart_top #(.SRC(3), .BOOT(1)) dut(.clk27(1'b0), .clk14m(x14), .btn_rst(1'b0), .slot_reset_n(reset_n), .slot_iorq_n(iorq_n), .slot_rd_n(rd_n), .slot_wr_n(wr_n),
        .slot_a(a), .slot_d(slot_d), .slot_data_dir(dir), .slot_wait(wt), .slot_intr(intr), .oe_n(oe_n), .dbg_sig(dbg_sig), .dbg_hb(dbg_hb),
        .O_sdram_clk(O_clk), .O_sdram_cke(O_cke), .O_sdram_cs_n(O_cs), .O_sdram_ras_n(O_ras), .O_sdram_cas_n(O_cas), .O_sdram_wen_n(O_we), .O_sdram_dqm(O_dqm),
        .O_sdram_addr(O_a), .O_sdram_ba(O_ba), .IO_sdram_dq(dq));
    defparam dut.u_soc.u_xbuf.INIT_PFX = "../fw/monitor_l";
    defparam dut.u_soc.INIT_CYC = 2000;
    defparam dut.u_soc.BOOT_WORDS = 512;   // the monitor takes < 1.3 KB: copying 4 KB is enough and speeds up the simulation
    assign dq = dut.s_dq_oe ? 32'bz : mdq;
    sdram_model mdl(.clk(dut.clk), .cke(O_cke), .cs_n(O_cs), .ras_n(O_ras), .cas_n(O_cas), .we_n(O_we), .dqm(O_dqm), .ba(O_ba), .a(O_a), .dq_i(dq), .dq_oe(dut.s_dq_oe), .dq_o(mdq));
    integer errs = 0, nrst = 0, k; reg [7:0] v;
    task chk(input [255:0] nome, input [63:0] got, input [63:0] exp);
        if (got !== exp) begin errs = errs + 1; $display("ERROR %0s: got %h expected %h", nome, got, exp); end
    endtask
    // MSX Z80 cycles (T = 279 ns): write with the data "rising" at the start of /WR; read sampled at the end of the wait
    task zout(input [7:0] port, input [7:0] d); begin
        a = port; #40 iorq_n = 0; dv_oe = 1; dv = d ^ 8'h05; #100 wr_n = 0; #60 dv = d; #500 wr_n = 1; #20 iorq_n = 1; #30 dv_oe = 0; #150;
    end endtask
    task zin(input [7:0] port, output [7:0] d); begin
        a = port; #40 iorq_n = 0; #100 rd_n = 0; #660 d = slot_d; #10 rd_n = 1; #20 iorq_n = 1; #150;
    end endtask
    reg [7:0] msg [0:63]; reg [7:0] rsp [0:63]; integer rlen;
    task send(input integer len); integer i; begin
        for (i = 0; i < len; i = i + 1) zout(8'h0C, msg[i]);
        zout(8'h0D, len[7:0]); zout(8'h0D, 8'h00);
        zout(8'h0B, 8'h01);                       // INICIAR
    end endtask
    task waitdone(input integer maxpoll); integer c, i; reg [7:0] s, lo, hi; begin
        s = 0; c = 0;
        while (!s[3] && c < maxpoll) begin zin(8'h0B, s); c = c + 1; #2000; end
        if (!s[3]) begin errs = errs + 1; $display("ERROR: timeout waiting for DONE (STATUS=%h)", s); rlen = 0; end
        else begin
            zin(8'h0D, lo); zin(8'h0D, hi); rlen = {hi, lo};
            for (i = 0; i < rlen; i = i + 1) zin(8'h0C, rsp[i]);
            zout(8'h0B, 8'h80);                   // clears DONE
        end
    end endtask
    always @(negedge dut.rst) nrst = nrst + 1;
    initial begin
        #200 reset_n = 1;
        wait (dut.u_soc.init_done);
        wait (!dut.u_soc.boot_busy);
        #200000;
        zin(8'h0B, v); chk("initial STATUS: space + WINDOW", v & 8'hE3, 8'h22);
        if (!$test$plusargs("p2")) begin
        // 1. PING
        msg[0] = 8'h00; msg[1] = 8'h05; send(2); waitdone(2000);
        chk("PING len", rlen, 3); chk("PING op", rsp[0], 8'h80); chk("PING seq", rsp[1], 8'h05); chk("PING st", rsp[2], 0);
        $display("PING ok (t=%0t)", $time);
        // 2. HELLO
        msg[0] = 8'h01; msg[1] = 8'h06; msg[2] = 8'h01; send(3); waitdone(2000);
        chk("HELLO len", rlen, 14); chk("HELLO op", rsp[0], 8'h81); chk("HELLO 'R'", rsp[3], 8'h52); chk("HELLO '4'", rsp[7], 8'h34);
        chk("HELLO msgmax", {rsp[10], rsp[9]}, 16'h0800); chk("HELLO block", {rsp[12], rsp[11]}, 16'h4000);
        $display("HELLO ok");
        // 3. unknown OP
        msg[0] = 8'h55; msg[1] = 8'h07; send(2); waitdone(2000);
        chk("op desc st", rsp[2], 8'h01); chk("op desc seq", rsp[1], 8'h07);
        end else begin
        // 4. INT: enable (CMD.b2) and trigger a PING; INT must rise on completion and fall on clear
        msg[0] = 8'h00; msg[1] = 8'h09; zout(8'h0C, msg[0]); zout(8'h0C, msg[1]); zout(8'h0D, 8'h02); zout(8'h0D, 8'h00);
        zout(8'h0B, 8'h05);                       // START + enable IRQ (CMD.b2: each CMD write rewrites the bit)
        k = 0; while (intr !== 1'b1 && k < 3000) begin #1000; k = k + 1; end
        chk("INT active on completion", intr, 1);
        waitdone(2000); zout(8'h0B, 8'h00); #1000; chk("INT cleared (DONE cleared)", intr, 0);
        // 5. MSX /RESET: the SoC restarts and redoes the boot; the monitor answers again
        nrst = 0; reset_n = 0; #1000 reset_n = 1; #1000; chk("restart by slot /RESET", nrst >= 1, 1);
        wait (dut.u_soc.init_done); wait (!dut.u_soc.boot_busy); #200000;
        msg[0] = 8'h00; msg[1] = 8'h0A; send(2); waitdone(2000);
        chk("PING after /RESET: len", rlen, 3); chk("PING after /RESET: op", rsp[0], 8'h80); chk("PING after /RESET: seq", rsp[1], 8'h0A);
        chk("WAIT solto", wt, 0);
        end
        $display("errors=%0d", errs); if (errs == 0) $display("RESULT: CARTRIDGE + MONITOR OK"); else $display("RESULT: %0d ERRORS", errs);
        $finish;
    end
    initial begin #900000000; $display("RESULT: TIMEOUT GLOBAL"); $finish; end   // REV52: 42.95 MHz clock (slower boot)
endmodule
