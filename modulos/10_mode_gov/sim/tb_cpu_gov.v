`timescale 1ns/1ps
// core test program under the governor: Z80 ROM mode (default) or native (+native). Measures the time until the final loop.
module tb_cpu_gov;
    reg clk = 0, rst = 1, irq = 0; always #5 clk = ~clk;
    wire i_req, d_req, d_we; wire [63:0] i_addr, d_addr, d_wdata, dbg_pc; wire [1:0] d_size; wire [7:0] dbg_f, d_be; wire dbg_sig;
    reg i_ack = 0, d_ack = 0; reg [63:0] i_rdata = 0, d_rdata = 0; reg [63:0] mem [0:511];
    reg map_we = 0; reg [3:0] map_idx = 0; reg [1:0] map_val = 0; reg io_we = 0; reg [7:0] io_a = 0, io_wd = 0; wire [7:0] io_rd; wire io_oe; wire nat, csel, z80, rom, mbusy, cv;
    r8064_cpu_gov dut(.smc_miss(1'b0), .i_flt(1'b0), .d_flt(1'b0), .i_cs(3'd0), .d_cs(3'd0), .clk(clk), .rst(rst), .irq(irq), .i_req(i_req), .i_ack(i_ack), .i_addr(i_addr), .i_rdata(i_rdata),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_size(d_size), .d_wdata(d_wdata), .d_be(d_be), .d_ack(d_ack), .d_rdata(d_rdata),
        .io_we(io_we), .io_re(1'b0), .io_a(io_a), .io_wd(io_wd), .io_rd(io_rd), .io_oe(io_oe), .port_c(8'd0), .cio_we(), .cio_re(), .cio_a(), .cio_wd(), .cio_rd(8'hFF), .a8(8'd0), .map_we(map_we), .map_idx(map_idx), .map_val(map_val),
        .native64(nat), .clk_sel(csel), .is_z80(z80), .is_rom(rom), .mode_busy(mbusy), .dbg_pc(dbg_pc), .dbg_f(dbg_f), .dbg_sig(dbg_sig), .gov_cv(cv));
    integer ic = 0, errs = 0, n_iss = 0, tfin = 0, now = 0, tlast = 0, min_sp = 1000000;
    initial $readmemh("prog.mem", mem);
    always @(posedge clk) begin
        i_ack <= 0; d_ack <= 0; now <= now + 1;
        if (i_req && !i_ack) begin ic <= ic + 1; if (ic == 2) begin ic <= 0; i_ack <= 1; i_rdata <= mem[i_addr[11:3]]; end end else ic <= 0;
        if (d_req && !d_ack) begin d_ack <= 1; if (d_we) begin : wbe integer q; for (q = 0; q < 8; q = q + 1) if (d_be[q]) mem[d_addr[11:3]][8*q +: 8] <= d_wdata[8*q +: 8]; end else d_rdata <= mem[d_addr[11:3]]; end
        if (cv) begin n_iss <= n_iss + 1; if (n_iss > 0 && now - tlast < min_sp) min_sp <= now - tlast; tlast <= now; end
        if (tfin == 0 && dbg_pc == 64'h17 && n_iss > 10) tfin <= now;
    end
    task wio(input [7:0] ad, input [7:0] d); begin @(posedge clk); #1 io_a = ad; io_wd = d; io_we = 1; @(posedge clk); #1 io_we = 0; end endtask
    task chk(input [255:0] nome, input [63:0] got, input [63:0] exp);
        if (got !== exp) begin errs = errs + 1; $display("ERROR %0s: got %h expected %h", nome, got, exp); end
    endtask
    initial begin
        repeat (4) @(posedge clk); rst = 0;
        if ($test$plusargs("native")) begin wio(8'h3D, 8'hA5); wio(8'h3E, 8'h01); end
        if ($test$plusargs("r800")) begin wio(8'hE4, 8'h06); wio(8'hE5, 8'h00); end
        if ($test$plusargs("ram")) begin @(posedge clk); #1 map_idx = 0; map_val = 0; map_we = 1; @(posedge clk); #1 map_we = 0; end
        if ($test$plusargs("ext")) begin @(posedge clk); #1 map_idx = 0; map_val = 2; map_we = 1; @(posedge clk); #1 map_we = 0; end
        repeat (200000) @(posedge clk);
        chk("AX", dut.u_core.u_rf1.mem_a[0], 64'd15); chk("BC", dut.u_core.u_rf1.mem_a[1], 64'd0);
        chk("DE", dut.u_core.u_rf1.mem_a[2], 64'd15); chk("HL", dut.u_core.u_rf1.mem_a[3], 64'h68);
        chk("m40", mem[9'h40/8], 5); chk("m60", mem[9'h60/8], 15);
        $display("mode: native=%0d z80=%0d rom=%0d | instructions=%0d | time to the final loop = %0d clocks | smallest gap between issues = %0d clocks", nat, z80, rom, n_iss, tfin, min_sp);
        if (errs == 0) $display("RESULT: PROGRAM OK UNDER THE GOVERNOR"); else $display("RESULT: %0d ERRORS", errs);
        $finish;
    end
endmodule
