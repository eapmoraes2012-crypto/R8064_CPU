`timescale 1ns/1ps
module tb_core;
    reg clk = 0, rst = 1, irq = 0; always #5 clk = ~clk;
    wire i_req, d_req, d_we; wire [63:0] i_addr, d_addr, d_wdata, dbg_pc; wire [1:0] d_size; wire [7:0] dbg_f, d_be; wire dbg_sig;
    reg i_ack = 0, d_ack = 0; reg [63:0] i_rdata = 0, d_rdata = 0;
    reg [63:0] mem [0:511];
    r8064_core_min dut(.smc_miss(1'b0), .i_flt(1'b0), .d_flt(1'b0), .i_cs(3'd0), .d_cs(3'd0), .clk(clk), .rst(rst), .irq(irq), .i_req(i_req), .i_addr(i_addr), .i_ack(i_ack), .i_rdata(i_rdata),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_size(d_size), .d_wdata(d_wdata), .d_be(d_be), .d_ack(d_ack), .d_rdata(d_rdata),
        .dbg_pc(dbg_pc), .dbg_f(dbg_f), .dbg_sig(dbg_sig), .gov_go(1'b1), .gov_wait(1'b0), .port_c(8'd0), .gov_page(), .gov_op(), .gov_port(), .gov_cv(), .gov_alt_ev(), .gov_boundary(), .gov_pc(), .gov_len(), .gov_dev(), .gov_daddr(), .gov_dsize(), .gov_dwe(), .io_we(), .io_re(), .io_a(), .io_wd(), .io_rdata(8'h00));
    integer ic = 0, dc = 0, k, errs = 0;
    initial $readmemh("prog.mem", mem);
    always @(posedge clk) begin
        i_ack <= 0; d_ack <= 0;
        if (i_req && !i_ack) begin ic <= ic + 1; if (ic == 2) begin ic <= 0; i_ack <= 1; i_rdata <= mem[i_addr[11:3]]; end end else ic <= 0;
        if (d_req && !d_ack) begin dc <= dc + 1; if (dc == 3) begin dc <= 0; d_ack <= 1;
            if (d_we) begin : wbe integer q; for (q = 0; q < 8; q = q + 1) if (d_be[q]) mem[d_addr[11:3]][8*q +: 8] <= d_wdata[8*q +: 8]; end else d_rdata <= mem[d_addr[11:3]]; end end else dc <= 0;
    end
    task chk(input [255:0] nome, input [63:0] got, input [63:0] exp);
        if (got !== exp) begin errs = errs + 1; $display("ERROR %0s: got %h expected %h", nome, got, exp); end
    endtask
    initial begin
        repeat (4) @(posedge clk); rst = 0;
        repeat (1500) @(posedge clk);
        chk("AX",  dut.u_rf1.mem_a[0], 64'd15);
        chk("BC",  dut.u_rf1.mem_a[1], 64'd0);
        chk("DE",  dut.u_rf1.mem_a[2], 64'd15);
        chk("HL",  dut.u_rf1.mem_a[3], 64'h68);
        chk("m40", mem[9'h40/8], 5);  chk("m48", mem[9'h48/8], 9);  chk("m50", mem[9'h50/8], 12);
        chk("m58", mem[9'h58/8], 14); chk("m60", mem[9'h60/8], 15);
        $display("pc=%h flags=%h  errors=%0d", dbg_pc, dbg_f, errs);
        if (errs == 0) $display("RESULT: TEST PROGRAM OK"); else $display("RESULT: %0d ERRORS", errs);
        $finish;
    end
endmodule
