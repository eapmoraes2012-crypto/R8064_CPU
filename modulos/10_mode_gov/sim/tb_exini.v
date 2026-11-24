`timescale 1ns/1ps
// EXINI (ED 09): returns the main group to the reset state (EXX undone), and also AF/AF' (undoes EX AF,AF')
module tb_exini;
    reg clk = 0, rst = 1, irq = 0; always #5 clk = ~clk;
    wire i_req, d_req, d_we; wire [63:0] i_addr, d_addr, d_wdata, dbg_pc; wire [1:0] d_size; wire [7:0] dbg_f; wire dbg_sig;
    reg i_ack = 0, d_ack = 0; reg [63:0] i_rdata = 0, d_rdata = 0; reg [63:0] mem [0:511];
    r8064_core_min dut(.smc_miss(1'b0), .i_flt(1'b0), .d_flt(1'b0), .i_cs(3'd0), .d_cs(3'd0), .clk(clk), .rst(rst), .irq(irq), .i_req(i_req), .i_addr(i_addr), .i_ack(i_ack), .i_rdata(i_rdata),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_size(d_size), .d_wdata(d_wdata), .d_ack(d_ack), .d_rdata(d_rdata),
        .dbg_pc(dbg_pc), .dbg_f(dbg_f), .dbg_sig(dbg_sig), .gov_go(1'b1), .gov_wait(1'b0), .port_c(8'd0), .gov_page(), .gov_op(), .gov_port(), .gov_cv(), .gov_alt_ev(), .gov_boundary(), .gov_pc(), .gov_len(), .gov_dev(), .gov_daddr(), .gov_dsize(), .gov_dwe(), .io_we(), .io_re(), .io_a(), .io_wd(), .io_rdata(8'h00));
    integer ic = 0, errs = 0, k;
    initial $readmemh("prog_exini.mem", mem);
    always @(posedge clk) begin
        i_ack <= 0; d_ack <= 0;
        if (i_req && !i_ack) begin ic <= ic + 1; if (ic == 2) begin ic <= 0; i_ack <= 1; i_rdata <= mem[i_addr[11:3]]; end end else ic <= 0;
        if (d_req && !d_ack) d_ack <= 1;
    end
    task chk(input [255:0] nome, input [63:0] got, input [63:0] exp);
        if (got !== exp) begin errs = errs + 1; $display("ERROR %0s: got %h expected %h", nome, got, exp); end
    endtask
    initial begin
        repeat (4) @(posedge clk); rst = 0; repeat (1500) @(posedge clk);
        chk("main BC = 3333 (EXINI returned to the main set)", dut.u_rf1.mem_a[1], 64'h3333);
        chk("shadow BC   = 2222 (written after EXX)",           dut.u_rf1.mem_a[6], 64'h2222);
        chk("DE main = 4444 (EXINI has no effect)",          dut.u_rf1.mem_a[2], 64'h4444);
        for (k = 0; k < 24; k = k + 1) if (dut.u_rf1.mem_a[k] == 64'h5555) $display("AX written (after EX AF,AF' + EXINI) at physical index %0d", k);
        chk("main AX = 5555 (EXINI returned AF'->AF)",     dut.u_rf1.mem_a[0], 64'h5555);
        $display("pc=%h errors=%0d", dbg_pc, errs);
        if (errs == 0) $display("RESULT: EXINI OK"); else $display("RESULT: %0d ERRORS", errs);
        $finish;
    end
endmodule
