`timescale 1ns/1ps
// uop sequencer and I/O test: LD SP, PUSH, POP, CALL, RET, OUT (n),A, IN A,(n)
module tb_seq;
    wire [7:0] d_be; reg clk = 0, rst = 1, irq = 0; always #5 clk = ~clk;
    wire i_req, d_req, d_we; wire [63:0] i_addr, d_addr, d_wdata, dbg_pc; wire [1:0] d_size; wire [7:0] dbg_f; wire dbg_sig;
    reg i_ack = 0, d_ack = 0; reg [63:0] i_rdata = 0, d_rdata = 0; reg [7:0] mem [0:4095];
    wire io_we, io_re; wire [7:0] io_a, io_wd; reg [7:0] io_rdata = 0;
    r8064_core_min dut(.smc_miss(1'b0), .i_flt(1'b0), .d_flt(1'b0), .i_cs(3'd0), .d_cs(3'd0), .clk(clk), .rst(rst), .irq(irq), .i_req(i_req), .i_addr(i_addr), .i_ack(i_ack), .i_rdata(i_rdata),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_size(d_size), .d_wdata(d_wdata), .d_be(d_be), .d_ack(d_ack), .d_rdata(d_rdata),
        .dbg_pc(dbg_pc), .dbg_f(dbg_f), .dbg_sig(dbg_sig), .gov_go(1'b1), .gov_wait(1'b0), .port_c(8'd0), .gov_page(), .gov_op(), .gov_port(), .gov_cv(), .gov_alt_ev(), .gov_boundary(),
        .gov_pc(), .gov_len(), .gov_dev(), .gov_daddr(), .gov_dsize(), .gov_dwe(), .io_we(io_we), .io_re(io_re), .io_a(io_a), .io_wd(io_wd), .io_rdata(io_rdata));
    integer ic = 0, dc = 0, errs = 0, k, n_ow = 0, n_ir = 0; reg [7:0] last_ow_a = 0, last_ow_d = 0; reg [63:0] w; reg [63:0] pm [0:511];
    initial begin $readmemh("prog_seq.mem", pm); for (k = 0; k < 4096; k = k + 1) mem[k] = pm[k/8] >> (8*(k%8)); end
    always @(posedge clk) begin
        i_ack <= 0; d_ack <= 0;
        if (i_req && !i_ack) begin ic <= ic + 1; if (ic == 2) begin ic <= 0; i_ack <= 1;
            for (k = 0; k < 8; k = k + 1) i_rdata[8*k +: 8] <= mem[{i_addr[11:3], 3'b000} + k]; end end else ic <= 0;
        if (d_req && !d_ack) begin d_ack <= 1;
            if (d_we) begin for (k = 0; k < 8; k = k + 1) if (d_be[k]) mem[{d_addr[11:3], 3'b000} + k] <= d_wdata[8*k +: 8]; end
            else for (k = 0; k < 8; k = k + 1) d_rdata[8*k +: 8] <= mem[{d_addr[11:3], 3'b000} + k];
        end
        if (io_we) begin n_ow <= n_ow + 1; last_ow_a <= io_a; last_ow_d <= io_wd; end
        if (io_re) n_ir <= n_ir + 1;
    end
    always @* io_rdata = (io_a == 8'h78) ? 8'h5A : 8'hFF;
    task chk(input [255:0] nome, input [63:0] got, input [63:0] exp);
        if (got !== exp) begin errs = errs + 1; $display("ERROR %0s: got %h expected %h", nome, got, exp); end
    endtask
    initial begin
        repeat (4) @(posedge clk); rst = 0;
        repeat (3000) @(posedge clk);
        chk("BC (POP BC)", dut.u_rf1.mem_a[1], 64'h33);
        chk("DE", dut.u_rf1.mem_a[2], 64'h22);
        chk("HL (POP HL)", dut.u_rf1.mem_a[3], 64'h22);
        chk("AX (IN A,(78h))", dut.u_rf1.mem_a[0], 64'h5A);
        chk("final SP (after RET)", dut.u_rf1.mem_a[11], 64'h0F00);
        chk("stack EFE = return address", {mem[12'hEFF], mem[12'hEFE]}, 64'h0008);
        chk("stack EFC = DE", {mem[12'hEFD], mem[12'hEFC]}, 64'h0022);
        chk("stack EFA = HL", {mem[12'hEFB], mem[12'hEFA]}, 64'h0033);
        chk("OUT: port", last_ow_a, 64'h77); chk("OUT: data", last_ow_d, 64'h41);
        chk("OUT: 1 write", n_ow, 1); chk("IN: 1 read", n_ir, 1);
        chk("PC in the final loop (8 or 0A depending on the phase)", (dbg_pc == 64'h08) ? 64'h0A : dbg_pc, 64'h0A);
        $display("pc=%h I/O writes=%0d I/O reads=%0d errors=%0d", dbg_pc, n_ow, n_ir, errs);
        if (errs == 0) $display("RESULT: SEQUENCER OK"); else $display("RESULT: %0d ERRORS", errs);
        $finish;
    end
endmodule
