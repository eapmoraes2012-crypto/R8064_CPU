`timescale 1ns/1ps
// Z80 block instructions: LDIR, LDDR, CPIR, INIR, OTIR (isolated core; byte-by-byte memory)
module tb_irq3;
    wire [7:0] d_be; reg clk = 0, rst = 1, irq = 1; integer n_take = 0; reg [7:0] f1 = 0, f2 = 0; reg [63:0] a1 = 0; always #5 clk = ~clk;
    wire i_req, d_req, d_we; wire [63:0] i_addr, d_addr, d_wdata, dbg_pc; wire [1:0] d_size; wire [7:0] dbg_f; wire dbg_sig;
    reg i_ack = 0, d_ack = 0; reg [63:0] i_rdata = 0, d_rdata = 0; reg [7:0] mem [0:4095]; reg [63:0] pm [0:511];
    wire io_we, io_re; wire [7:0] io_a, io_wd; reg [7:0] io_rdata = 0;
    r8064_core_min dut(.smc_miss(1'b0), .i_flt(1'b0), .d_flt(1'b0), .i_cs(3'd0), .d_cs(3'd0), .clk(clk), .rst(rst), .irq(irq), .i_req(i_req), .i_addr(i_addr), .i_ack(i_ack), .i_rdata(i_rdata),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_size(d_size), .d_wdata(d_wdata), .d_be(d_be), .d_ack(d_ack), .d_rdata(d_rdata),
        .dbg_pc(dbg_pc), .dbg_f(dbg_f), .dbg_sig(dbg_sig), .gov_go(1'b1), .gov_wait(1'b0), .port_c(8'd0), .gov_page(), .gov_op(), .gov_port(), .gov_cv(), .gov_alt_ev(), .gov_boundary(),
        .gov_pc(), .gov_len(), .gov_dev(), .gov_daddr(), .gov_dsize(), .gov_dwe(), .io_we(io_we), .io_re(io_re), .io_a(io_a), .io_wd(io_wd), .io_rdata(io_rdata));
    integer ic = 0, k, errs = 0, n_ow = 0, n_ir = 0; reg [7:0] ow_a [0:15]; reg [7:0] ow_d [0:15];
    initial begin $readmemh("prog_irq3.mem", pm); for (k = 0; k < 4096; k = k + 1) mem[k] = pm[k/8] >> (8*(k%8)); end
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
    always @(posedge clk) if (dut.irq_take) begin n_take <= n_take + 1; irq <= 0; end
    initial begin
        repeat (4) @(posedge clk); rst = 0;
        repeat (6000) @(posedge clk);
        chk("1 interrupt", n_take, 1); chk("OUT executed", n_ow, 1);
        chk("A=55 already executed before the interrupt (EI delay)", ow_d[0], 8'h55);
        chk("return pushed = 8 (after LD A)", mem[16'hEFE], 8'h08);
        $display("take=%0d out=%h ret=%h errors=%0d", n_take, ow_d[0], mem[16'hEFE], errs);
        if (errs == 0) $display("RESULT: EI DELAY OK"); else $display("RESULT: %0d ERRORS", errs);
        $finish;
    end
endmodule
