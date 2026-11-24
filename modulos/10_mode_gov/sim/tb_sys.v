`timescale 1ns/1ps
// MSX system: test program in the mapper (slot 3, segment 1 -> physical 4000h), mode and A8/FC configured by I/O. Memory only answers PHYSICAL addresses.
module tb_sys;
    reg clk = 0, rst = 1, irq = 0; always #5 clk = ~clk;
    wire i_req, d_req, d_we, i_hit, d_hit, d_wr_ok; wire [63:0] i_paddr, d_paddr, d_wdata, dbg_pc; wire [1:0] d_size; wire [7:0] dbg_f, d_be; wire dbg_sig;
    reg i_ack = 0, d_ack = 0; reg [63:0] i_rdata = 0, d_rdata = 0; reg [63:0] mem [0:4095];
    reg io_we = 0, io_re = 0; reg [7:0] io_a = 0, io_wd = 0; wire [7:0] io_rd; wire io_oe, iox_we, iox_re; wire [7:0] iox_a, iox_wd; wire nat, csel, z80, rom, mbusy, cv;
    reg go_mem = 0;
    r8064_msx_sys dut(.smc_miss(1'b0), .i_flt(1'b0), .d_flt(1'b0), .i_cs(3'd0), .d_cs(3'd0), .clk(clk), .rst(rst), .irq(irq), .i_req(i_req), .i_ack(i_ack), .i_paddr(i_paddr), .i_rdata(i_rdata),
        .d_req(d_req), .d_we(d_we), .d_paddr(d_paddr), .d_size(d_size), .d_wdata(d_wdata), .d_be(d_be), .d_ack(d_ack), .d_rdata(d_rdata), .i_hit(i_hit), .d_hit(d_hit), .d_wr_ok(d_wr_ok),
        .io_we(io_we), .io_re(io_re), .io_a(io_a), .io_wd(io_wd), .io_rd(io_rd), .io_oe(io_oe), .io_x_we(iox_we), .io_x_re(iox_re), .io_x_a(iox_a), .io_x_wd(iox_wd), .io_x_rd(8'h5A), .port_c(8'd0), .fm_we(1'b0), .fm_re(1'b0), .fm_a(2'd0), .fm_wd(8'd0), .fm_rd(), .fifo_irq(), .fifo_rst(),
        .native64(nat), .clk_sel(csel), .is_z80(z80), .is_rom(rom), .mode_busy(mbusy), .dbg_pc(dbg_pc), .dbg_f(dbg_f), .dbg_sig(dbg_sig), .gov_cv(cv));
    integer ic = 0, errs = 0, bad_i = 0, bad_d = 0, n_iss = 0, tfin = 0, now = 0;
    initial $readmemh("prog.mem", mem, 2048, 2559);                     // program at 4000h..4FFFh (word 2048 = 4000h/8)
    always @(posedge clk) begin
        i_ack <= 0; d_ack <= 0; now <= now + 1;
        if (go_mem) begin
            if (i_req && !i_ack) begin ic <= ic + 1; if (ic == 2) begin ic <= 0; i_ack <= 1; i_rdata <= mem[i_paddr[14:3]];
                if (i_paddr[15:12] != 4'h4) bad_i <= bad_i + 1; end end else ic <= 0;
            if (d_req && !d_ack) begin d_ack <= 1; if (d_paddr[15:12] != 4'h4) bad_d <= bad_d + 1;
                if (d_we) begin : wbe integer q; for (q = 0; q < 8; q = q + 1) if (d_be[q]) mem[d_paddr[14:3]][8*q +: 8] <= d_wdata[8*q +: 8]; end else d_rdata <= mem[d_paddr[14:3]]; end
        end
        if (cv) n_iss <= n_iss + 1;
        if (tfin == 0 && go_mem && dbg_pc == 64'h17 && n_iss > 10) tfin <= now;
    end
    task wio(input [7:0] ad, input [7:0] d); begin @(posedge clk); #1 io_a = ad; io_wd = d; io_we = 1; @(posedge clk); #1 io_we = 0; end endtask
    task rio(input [7:0] ad, output [7:0] d); begin @(posedge clk); #1 io_a = ad; io_re = 1; #1 d = io_rd; @(posedge clk); #1 io_re = 0; end endtask
    task chk(input [255:0] nome, input [63:0] got, input [63:0] exp);
        if (got !== exp) begin errs = errs + 1; $display("ERROR %0s: got %h expected %h", nome, got, exp); end
    endtask
    reg [7:0] v;
    initial begin
        repeat (4) @(posedge clk); rst = 0;
        rio(8'h3D, v); chk("ID 3DH", v, 8'h64);
        rio(8'h77, v); chk("external port", v, 8'h5A);
        wio(8'hA8, 8'hFF); wio(8'hFC, 8'h01); rio(8'hFC, v); chk("FCH read back (8-bit mapper: all valid)", v, 8'h01); rio(8'hA8, v); chk("A8H read back", v, 8'hFF);
        if ($test$plusargs("r800")) begin wio(8'hE4, 8'h06); wio(8'hE5, 8'h00); end
        go_mem = 1;
        repeat (60000) @(posedge clk);
        chk("AX", dut.u_cpu.u_core.u_rf1.mem_a[0], 64'd15); chk("DE", dut.u_cpu.u_core.u_rf1.mem_a[2], 64'd15); chk("HL", dut.u_cpu.u_core.u_rf1.mem_a[3], 64'h68);
        chk("m40 (physical 4040h)", mem[(16'h4040)/8 & 4095], 5); chk("m60 (physical 4060h)", mem[(16'h4060)/8 & 4095], 15);
        chk("fetches outside physical 4xxx", bad_i, 0); chk("data outside physical 4xxx", bad_d, 0);
        $display("mode z80=%0d rom=%0d | instructions=%0d | final loop at %0d clocks | dbg_pc=%h", z80, rom, n_iss, tfin, dbg_pc);
        if (errs == 0) $display("RESULT: MSX SYSTEM OK"); else $display("RESULT: %0d ERRORS", errs);
        $finish;
    end
endmodule
