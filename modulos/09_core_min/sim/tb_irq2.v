`timescale 1ns/1ps
// Z80 block instructions: LDIR, LDDR, CPIR, INIR, OTIR (isolated core; byte-by-byte memory)
module tb_irq2;
    `include "prog_irq_pcs.vh"
    wire [7:0] d_be; reg clk = 0, rst = 1, irq = 0; reg im2 = 0; integer n_take = 0, n_ow2 = 0; reg [63:0] bc_take = 0; always #5 clk = ~clk;
    wire i_req, d_req, d_we; wire [63:0] i_addr, d_addr, d_wdata, dbg_pc; wire [1:0] d_size; wire [7:0] dbg_f; wire dbg_sig;
    reg i_ack = 0, d_ack = 0; reg [63:0] i_rdata = 0, d_rdata = 0; reg [7:0] mem [0:4095]; reg [63:0] pm [0:511];
    wire io_we, io_re; wire [7:0] io_a, io_wd; reg [7:0] io_rdata = 0;
    r8064_core_min dut(.smc_miss(1'b0), .i_flt(1'b0), .d_flt(1'b0), .i_cs(3'd0), .d_cs(3'd0), .clk(clk), .rst(rst), .irq(irq), .i_req(i_req), .i_addr(i_addr), .i_ack(i_ack), .i_rdata(i_rdata),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_size(d_size), .d_wdata(d_wdata), .d_be(d_be), .d_ack(d_ack), .d_rdata(d_rdata),
        .dbg_pc(dbg_pc), .dbg_f(dbg_f), .dbg_sig(dbg_sig), .gov_go(1'b1), .gov_wait(1'b0), .port_c(8'd0), .gov_page(), .gov_op(), .gov_port(), .gov_cv(), .gov_alt_ev(), .gov_boundary(),
        .gov_pc(), .gov_len(), .gov_dev(), .gov_daddr(), .gov_dsize(), .gov_dwe(), .io_we(io_we), .io_re(io_re), .io_a(io_a), .io_wd(io_wd), .io_rdata(io_rdata));
    initial im2 = $test$plusargs("im2");
    integer ic = 0, k, errs = 0, n_ow = 0, n_ir = 0; reg [7:0] ow_a [0:15]; reg [7:0] ow_d [0:15];
    initial begin $readmemh(im2 ? "prog_irq2.mem" : "prog_irq1.mem", pm); for (k = 0; k < 4096; k = k + 1) mem[k] = pm[k/8] >> (8*(k%8)); end
    always @(posedge clk) begin
        i_ack <= 0; d_ack <= 0;
        if (i_req && !i_ack) begin ic <= ic + 1; if (ic == 2) begin ic <= 0; i_ack <= 1;
            for (k = 0; k < 8; k = k + 1) i_rdata[8*k +: 8] <= mem[{i_addr[11:3], 3'b000} + k]; end end else ic <= 0;
        if (d_req && !d_ack) begin d_ack <= 1;
            if (d_we) begin for (k = 0; k < 8; k = k + 1) if (d_be[k]) mem[{d_addr[11:3], 3'b000} + k] <= d_wdata[8*k +: 8]; end
            else for (k = 0; k < 8; k = k + 1) d_rdata[8*k +: 8] <= mem[{d_addr[11:3], 3'b000} + k];
        end
        if (io_we) begin ow_a[n_ow] <= io_a; ow_d[n_ow] <= io_wd; n_ow <= n_ow + 1; end
        if (io_re) n_ir <= n_ir + 1;
    end
    always @* io_rdata = (io_a == 8'h78) ? 8'h5A : 8'hFF;
    task chk(input [255:0] nome, input [63:0] got, input [63:0] exp);
        if (got !== exp) begin errs = errs + 1; $display("ERROR %0s: got %h expected %h", nome, got, exp); end
    endtask
    always @(posedge clk) if (dut.irq_take) begin n_take <= n_take + 1; bc_take <= dut.u_rf1.mem_a[1]; end
    initial begin
        repeat (4) @(posedge clk); rst = 0;
        wait (mem[16'h201] == 8'h42);
        @(posedge clk); irq = 1;
        wait (dut.irq_take); @(posedge clk); irq = 0;
        repeat (30000) @(posedge clk);
        chk("1 interrupt accepted", n_take, 1);
        if (!(bc_take > 0 && bc_take < 5)) begin errs = errs + 1; $display("ERROR: was not in the middle of the repeat (BC=%0d)", bc_take); end
        chk("handler executed 1 OUT", n_ow, 1); chk("OUT data", ow_d[0], 8'h41); chk("OUT port", ow_a[0], 8'h77);
        chk("pushed return address (lo)", mem[16'hEFE], im2 ? PC_IM2[7:0] : PC_IM1[7:0]); chk("return address (hi)", mem[16'hEFF], 8'h00);
        chk("SP restored", dut.u_rf1.mem_a[11], 64'h0F00);
        chk("IFF1 restored (RETI)", dut.ie, 1); chk("IM", dut.im, im2 ? 2 : 1);
        chk("BC final 0", dut.u_rf1.mem_a[1], 0); chk("HL final", dut.u_rf1.mem_a[3], 64'h105); chk("DE final", dut.u_rf1.mem_a[2], 64'h205);
        chk("[200]", mem[16'h200], 8'h41); chk("[202]", mem[16'h202], 8'h43); chk("[204]", mem[16'h204], 8'h45); chk("[205] intact", mem[16'h205], 0);
        $display("im2=%0d take=%0d BC_at_int=%0d pc=%h errors=%0d", im2, n_take, bc_take, dbg_pc, errs);
        if (errs == 0) $display("RESULT: INTERRUPT %s OK", im2 ? "IM2" : "IM1"); else $display("RESULT: %0d ERRORS", errs);
        $finish;
    end
endmodule
