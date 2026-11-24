`timescale 1ns/1ps
// Differential test of the core's Z80 instructions: program (z80mem.hex, 4096 bytes), initial registers (z80regs.hex) and initial flags (z80fl.hex);
// runs +cyc=N clocks and dumps registers, flags and memory to z80out.txt (compared with the Python model by z80rand.py).
module tb_z80;
    wire [7:0] d_be; reg clk = 0, rst = 1, irq = 0; always #5 clk = ~clk;
    wire i_req, d_req, d_we; wire [63:0] i_addr, d_addr, d_wdata, dbg_pc; wire [1:0] d_size; wire [7:0] dbg_f; wire dbg_sig;
    reg i_ack = 0, d_ack = 0; reg [63:0] i_rdata = 0, d_rdata = 0; reg [7:0] mem [0:4095];
    wire io_we, io_re; wire [7:0] io_a, io_wd; reg [7:0] io_rdata = 0;
    r8064_core_min dut(.smc_miss(1'b0), .i_flt(1'b0), .d_flt(1'b0), .i_cs(3'd0), .d_cs(3'd0), .clk(clk), .rst(rst), .irq(irq), .i_req(i_req), .i_addr(i_addr), .i_ack(i_ack), .i_rdata(i_rdata),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_size(d_size), .d_wdata(d_wdata), .d_be(d_be), .d_ack(d_ack), .d_rdata(d_rdata),
        .dbg_pc(dbg_pc), .dbg_f(dbg_f), .dbg_sig(dbg_sig), .gov_go(1'b1), .gov_wait(1'b0), .port_c(8'd0), .gov_page(), .gov_op(), .gov_port(), .gov_cv(), .gov_alt_ev(), .gov_boundary(),
        .gov_pc(), .gov_len(), .gov_dev(), .gov_daddr(), .gov_dsize(), .gov_dwe(), .io_we(io_we), .io_re(io_re), .io_a(io_a), .io_wd(io_wd), .io_rdata(io_rdata));
    integer ic = 0, k, cyc, fo; reg [63:0] rg [0:15]; reg [7:0] fli [0:0];
    initial begin
        $readmemh("z80mem.hex", mem); $readmemh("z80regs.hex", rg); $readmemh("z80fl.hex", fli);
        if (!$value$plusargs("cyc=%d", cyc)) cyc = 20000;
        for (k = 0; k < 16; k = k + 1) begin dut.u_rf1.mem_a[k] = rg[k]; dut.u_rf1.mem_b[k] = rg[k]; dut.u_rf2.mem_a[k] = rg[k]; end
    end
    always @(posedge clk) begin
        i_ack <= 0; d_ack <= 0;
        if (i_req && !i_ack) begin ic <= ic + 1; if (ic == 2) begin ic <= 0; i_ack <= 1;
            for (k = 0; k < 8; k = k + 1) i_rdata[8*k +: 8] <= mem[{i_addr[11:3], 3'b000} + k]; end end else ic <= 0;
        if (d_req && !d_ack) begin d_ack <= 1;
            if (d_we) begin for (k = 0; k < 8; k = k + 1) if (d_be[k]) mem[{d_addr[11:3], 3'b000} + k] <= d_wdata[8*k +: 8]; end
            else for (k = 0; k < 8; k = k + 1) d_rdata[8*k +: 8] <= mem[{d_addr[11:3], 3'b000} + k];
        end
    end
    initial begin
        repeat (4) @(posedge clk); #1 rst = 0; dut.fl = fli[0];
        repeat (cyc) @(posedge clk);
        fo = $fopen("z80out.txt", "w");
        for (k = 0; k < 16; k = k + 1) $fwrite(fo, "R%0d %h\n", k, dut.u_rf1.mem_a[k]);
        $fwrite(fo, "F %h\nPC %h\n", dut.fl, dbg_pc);
        for (k = 0; k < 4096; k = k + 1) $fwrite(fo, "%h\n", mem[k]);
        $fclose(fo); $finish;
    end
endmodule
