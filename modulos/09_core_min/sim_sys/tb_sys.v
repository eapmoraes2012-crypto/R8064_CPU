`timescale 1ns/1ps
// tb_sys.v - directed test of the system group (user mode, JP USER, SCALL, privileged instruction, SYSRT): runs free and prints registers / CRs
module tb_sys;
    reg clk = 0, rst = 1; always #5 clk = ~clk;
    wire i_req, d_req, d_we; wire [63:0] i_addr, d_addr, d_wdata, dbg_pc; wire [1:0] d_size; wire [7:0] dbg_f, d_be; wire dbg_sig;
    reg i_ack = 0, d_ack = 0; reg [63:0] i_rdata = 0, d_rdata = 0; reg [7:0] mem [0:65535];
    r8064_core_min dut(.smc_miss(1'b0), .i_flt(1'b0), .d_flt(1'b0), .i_cs(3'd0), .d_cs(3'd0), .clk(clk), .rst(rst), .irq(1'b0),
        .i_req(i_req), .i_addr(i_addr), .i_ack(i_ack), .i_rdata(i_rdata),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_size(d_size), .d_wdata(d_wdata), .d_be(d_be), .d_ack(d_ack), .d_rdata(d_rdata),
        .dbg_pc(dbg_pc), .dbg_f(dbg_f), .dbg_sig(dbg_sig), .gov_go(1'b1), .gov_wait(1'b0), .port_c(8'd0), .gov_page(), .gov_op(), .gov_port(), .gov_cv(), .gov_alt_ev(), .gov_boundary(),
        .gov_pc(), .gov_len(), .gov_dev(), .gov_daddr(), .gov_dsize(), .gov_dwe(), .io_we(), .io_re(), .io_a(), .io_wd(), .io_rdata(8'h00));
    integer ic = 0, k;
    wire [15:0] ia = {i_addr[15:3], 3'b000}, da = {d_addr[15:3], 3'b000};
    always @(posedge clk) begin
        i_ack <= 0; d_ack <= 0;
        if (i_req && !i_ack) begin ic <= ic + 1; if (ic == 1) begin ic <= 0; i_ack <= 1; for (k = 0; k < 8; k = k + 1) i_rdata[8*k +: 8] <= mem[ia + k[15:0]]; end end else ic <= 0;
        if (d_req && !d_ack) begin d_ack <= 1;
            if (d_we) begin for (k = 0; k < 8; k = k + 1) if (d_be[k]) mem[da + k[15:0]] <= d_wdata[8*k +: 8]; end
            else for (k = 0; k < 8; k = k + 1) d_rdata[8*k +: 8] <= mem[da + k[15:0]];
        end
    end
    reg [1023:0] fhex; integer n;
    initial begin
        if (!$value$plusargs("hex=%s", fhex)) $finish;
        $readmemh(fhex, mem); repeat (4) @(posedge clk); rst = 0;
        repeat (6000) @(posedge clk);
        $display("USER=%0d  AX=%h BC=%h DE=%h HL=%h IX=%h IY=%h SP=%h F=%h", dut.c_user, dut.u_rf1.mem_a[0], dut.u_rf1.mem_a[1], dut.u_rf1.mem_a[2], dut.u_rf1.mem_a[3], dut.u_rf1.mem_a[9], dut.u_rf1.mem_a[10], dut.u_rf1.mem_a[11], dut.fl);
        $display("CR0=%h CR1=%h CR2=%h CR3=%h CR11=%h CR12=%h CR13=%h", dut.u_rf1.mem_a[32], dut.u_rf1.mem_a[33], dut.u_rf1.mem_a[34], dut.u_rf1.mem_a[35], dut.u_rf1.mem_a[43], dut.u_rf1.mem_a[44], dut.u_rf1.mem_a[45]);
        $finish;
    end
endmodule
