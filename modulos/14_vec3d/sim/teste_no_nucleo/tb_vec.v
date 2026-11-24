`timescale 1ns/1ps
// 3D instructions integrated into the core: random program (LDQ + VOP/VSHUF/VOP1, with and without bank prefixes ED 0E/0D) checked against the Python model
module tb_vec;
    `include "nvec.vh"
    reg clk = 0, rst = 1, irq = 0; always #5 clk = ~clk;
    wire i_req, d_req, d_we; wire [63:0] i_addr, d_addr, d_wdata, dbg_pc; wire [1:0] d_size; wire [7:0] dbg_f; wire dbg_sig;
    reg i_ack = 0, d_ack = 0; reg [63:0] i_rdata = 0, d_rdata = 0;
    reg [63:0] mem [0:1023]; reg [63:0] exp [0:NEXP-1];
    r8064_core_min dut(.smc_miss(1'b0), .i_flt(1'b0), .d_flt(1'b0), .i_cs(3'd0), .d_cs(3'd0), .clk(clk), .rst(rst), .irq(irq), .i_req(i_req), .i_addr(i_addr), .i_ack(i_ack), .i_rdata(i_rdata),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_size(d_size), .d_wdata(d_wdata), .d_ack(d_ack), .d_rdata(d_rdata),
        .dbg_pc(dbg_pc), .dbg_f(dbg_f), .dbg_sig(dbg_sig), .gov_go(1'b1), .gov_wait(1'b0), .port_c(8'd0), .gov_page(), .gov_op(), .gov_port(), .gov_cv(), .gov_alt_ev(), .gov_boundary(), .gov_pc(), .gov_len(), .gov_dev(), .gov_daddr(), .gov_dsize(), .gov_dwe(), .io_we(), .io_re(), .io_a(), .io_wd(), .io_rdata(8'h00));
    integer ic = 0, errs = 0, n = 0, cyc = 0;
    initial begin $readmemh("prog_vec.mem", mem); $readmemh("exp_vec.mem", exp); end
    always @(posedge clk) begin
        i_ack <= 0; d_ack <= 0; cyc <= cyc + 1;
        if (i_req && !i_ack) begin ic <= ic + 1; if (ic == 2) begin ic <= 0; i_ack <= 1; i_rdata <= mem[i_addr[12:3]]; end end else ic <= 0;
        if (d_req && !d_ack) d_ack <= 1;
        if (!rst && dut.v_w && dut.u_w[80] && dut.u_w[10]) begin
            if (n < NEXP) begin
                if (dut.w_data !== exp[n]) begin errs = errs + 1; if (errs < 10) $display("ERROR vec #%0d: got %h expected %h (uop %h)", n, dut.w_data, exp[n], dut.u_w[4:0]); end
            end
            n = n + 1;
        end
    end
    initial begin
        repeat (4) @(posedge clk); rst = 0;
        while (n < NEXP && cyc < 400000) @(posedge clk);
        repeat (50) @(posedge clk);
        $display("3D operations completed: %0d of %0d, %0d cycles, errors=%0d", n, NEXP, cyc, errs);
        if (errs == 0 && n == NEXP) $display("RESULT: VEC3D IN THE CORE OK"); else $display("RESULT: FAILURE");
        $finish;
    end
endmodule
