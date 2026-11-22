`timescale 1ns/1ps
// tb_bmboard.v - simulation of the board benchmarks: r8064_bench (SoC + bench I/O, CPT = 12 as the 43.2 MHz board bench) with the SDRAM
// model and the image of build_board.py (monitor_l0..7.hex in the working directory, built with 'quick'). Prints the UART text; stops at "Done".
module tb_bmboard;
    reg clk = 0, rst = 1; always #5 clk = ~clk;
    localparam DIV = 8;
    wire tx, s_cke, s_cs_n, s_ras_n, s_cas_n, s_we_n, s_dq_oe; wire [3:0] s_dqm; wire [1:0] s_ba; wire [10:0] s_a; wire [31:0] s_dq_o, mdq;
    r8064_bench #(.BAUD_DIV(DIV), .INIT_CYC(2000), .TMO_BIT(20), .SIL_BIT(26), .CPT(12)) dut(.clk(clk), .rst(rst), .uart_tx(tx),
        .s_cke(s_cke), .s_cs_n(s_cs_n), .s_ras_n(s_ras_n), .s_cas_n(s_cas_n), .s_we_n(s_we_n), .s_dqm(s_dqm), .s_ba(s_ba), .s_a(s_a),
        .s_dq_o(s_dq_o), .s_dq_oe(s_dq_oe), .s_dq_i(mdq));
    sdram_model mdl(.clk(clk), .cke(s_cke), .cs_n(s_cs_n), .ras_n(s_ras_n), .cas_n(s_cas_n), .we_n(s_we_n), .dqm(s_dqm), .ba(s_ba), .a(s_a), .dq_i(s_dq_o), .dq_oe(s_dq_oe), .dq_o(mdq));
    integer k; reg [7:0] ch; reg [39:0] last5 = 0;
    initial forever begin
        @(negedge tx);
        repeat (DIV + DIV / 2) @(posedge clk);
        for (k = 0; k < 8; k = k + 1) begin ch[k] = tx; repeat (DIV) @(posedge clk); end
        if (ch != 8'd13) $write("%c", ch);
        $fflush;
        last5 = {last5[31:0], ch};
        if (last5 == "Done:") begin repeat (20000 * DIV) @(posedge clk); $display("\nTB_END"); $finish; end
    end
    initial begin repeat (8) @(posedge clk); rst = 0; #2000000000; $display("\nTB_TIMEOUT"); $finish; end
endmodule
