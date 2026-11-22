`timescale 1ns/1ps
// tb_bench.v - simulation of the timing bench (r8064_bench = SoC + bench I/O, cartridge build macros) with the SDRAM model and the bench
// firmware (monitor_l0..7.hex of gen_bench.py in the working directory). Decodes the UART and prints what the PC terminal would show.
// +n=<number of cases> (stops when all runs are done and the UART is idle); +first=<case> +last=<case>: only cases first..last-1
// (the run counter is preset to 2*first; the simulation of all cases takes about 2 hours).
module tb_bench;
    reg clk = 0, rst = 1; always #5 clk = ~clk;
    localparam DIV = 8;
    wire tx, s_cke, s_cs_n, s_ras_n, s_cas_n, s_we_n, s_dq_oe; wire [3:0] s_dqm; wire [1:0] s_ba; wire [10:0] s_a; wire [31:0] s_dq_o, mdq;
    r8064_bench #(.BAUD_DIV(DIV), .INIT_CYC(2000), .TMO_BIT(20), .SIL_BIT(17), .CPT(8)) dut(.clk(clk), .rst(rst), .uart_tx(tx),   // REV53: CPT 8 = 27 MHz board bench
        .s_cke(s_cke), .s_cs_n(s_cs_n), .s_ras_n(s_ras_n), .s_cas_n(s_cas_n), .s_we_n(s_we_n), .s_dqm(s_dqm), .s_ba(s_ba), .s_a(s_a),
        .s_dq_o(s_dq_o), .s_dq_oe(s_dq_oe), .s_dq_i(mdq));
    sdram_model mdl(.clk(clk), .cke(s_cke), .cs_n(s_cs_n), .ras_n(s_ras_n), .cas_n(s_cas_n), .we_n(s_we_n), .dqm(s_dqm), .ba(s_ba), .a(s_a), .dq_i(s_dq_o), .dq_oe(s_dq_oe), .dq_o(mdq));
    // UART receiver
    integer k; reg [7:0] ch;
    initial forever begin
        @(negedge tx);
        repeat (DIV + DIV / 2) @(posedge clk);
        for (k = 0; k < 8; k = k + 1) begin ch[k] = tx; repeat (DIV) @(posedge clk); end
        if (ch != 8'd13) $write("%c", ch);
        $fflush;
    end
    integer n = 0, idle = 0, first = 0, last = -1;
    always @(posedge clk) idle <= dut.u_io.tbusy ? 0 : idle + 1;
    initial begin
        if (!$value$plusargs("n=%d", n)) n = 256;
        if (!$value$plusargs("first=%d", first)) first = 0;
        if (!$value$plusargs("last=%d", last)) last = n;
        repeat (8) @(posedge clk); rst = 0;
        @(posedge clk); #1 dut.u_io.run = 2 * first;
        wait (dut.u_io.run == 2 * last);
        wait (dut.u_io.tbusy);              // the report of the last case
        repeat (2) @(posedge clk);
        wait (idle > (last == n ? 200000 : 40000));
        $display("\nTB_END runs=%0d", dut.u_io.run);
        $finish;
    end
endmodule
