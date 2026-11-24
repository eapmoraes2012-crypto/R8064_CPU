`timescale 1ns/1ps
// Z80 block instructions: LDIR, LDDR, CPIR, INIR, OTIR (isolated core; byte-by-byte memory)
module tb_xing;
    wire [7:0] d_be; reg clk = 0, rst = 1, irq = 0; always #5 clk = ~clk;
    wire i_req, d_req, d_we; wire [63:0] i_addr, d_addr, d_wdata, dbg_pc; wire [1:0] d_size; wire [7:0] dbg_f; wire dbg_sig;
    reg i_ack = 0, d_ack = 0; reg [63:0] i_rdata = 0, d_rdata = 0; reg [7:0] mem [0:4095]; reg [63:0] pm [0:511];
    wire io_we, io_re; wire [7:0] io_a, io_wd; reg [7:0] io_rdata = 0;
    r8064_core_min dut(.smc_miss(1'b0), .i_flt(1'b0), .d_flt(1'b0), .i_cs(3'd0), .d_cs(3'd0), .clk(clk), .rst(rst), .irq(irq), .i_req(i_req), .i_addr(i_addr), .i_ack(i_ack), .i_rdata(i_rdata),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_size(d_size), .d_wdata(d_wdata), .d_be(d_be), .d_ack(d_ack), .d_rdata(d_rdata),
        .dbg_pc(dbg_pc), .dbg_f(dbg_f), .dbg_sig(dbg_sig), .gov_go(1'b1), .gov_wait(1'b0), .port_c(8'd0), .gov_page(), .gov_op(), .gov_port(), .gov_cv(), .gov_alt_ev(), .gov_boundary(),
        .gov_pc(), .gov_len(), .gov_dev(), .gov_daddr(), .gov_dsize(), .gov_dwe(), .io_we(io_we), .io_re(io_re), .io_a(io_a), .io_wd(io_wd), .io_rdata(io_rdata));
    integer n_cross = 0, ic = 0, k, errs = 0, n_ow = 0, n_ir = 0; reg [7:0] ow_a [0:15]; reg [7:0] ow_d [0:15];
    initial begin $readmemh("prog_xing.mem", pm); for (k = 0; k < 4096; k = k + 1) mem[k] = pm[k/8] >> (8*(k%8)); end
    always @(posedge clk) begin
        i_ack <= 0; d_ack <= 0;
        if (i_req && !i_ack) begin ic <= ic + 1; if (ic == 2) begin ic <= 0; i_ack <= 1;
            for (k = 0; k < 8; k = k + 1) i_rdata[8*k +: 8] <= mem[{i_addr[11:3], 3'b000} + k]; end end else ic <= 0;
        if (d_req && !d_ack) begin d_ack <= 1;
            if (d_we && d_addr[3]) n_cross = n_cross + 0;
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
    reg [7:0] be_log [0:15]; reg [63:0] ad_log [0:15]; reg [63:0] wd_log [0:15]; integer nw = 0;
    always @(posedge clk) if (d_req && d_ack && d_we) begin be_log[nw] <= d_be; ad_log[nw] <= d_addr; wd_log[nw] <= d_wdata; nw <= nw + 1; end
    initial begin
        repeat (4) @(posedge clk); rst = 0;
        repeat (6000) @(posedge clk);
        chk("PUSH: byte 7 of the 1st transaction = 34", wd_log[0][63:56], 8'h34); chk("PUSH: byte 0 of the 2nd transaction = 12", wd_log[1][7:0], 8'h12);
        chk("PUSH: neighbouring bytes intact [EFE]", mem[16'h0EFE], 8'h00); chk("[F01] intact", mem[16'h0F01], 8'h00);
        chk("POP DE crossing the word", dut.u_rf1.mem_a[2][15:0], 16'h1234);
        chk("1st PUSH transaction: be = 80 (only byte 7)", be_log[0], 8'h80); chk("1st transaction: address EF8", ad_log[0], 64'h0EF8);
        chk("2nd PUSH transaction: be = 01", be_log[1], 8'h01); chk("2nd transaction: address F00", ad_log[1], 64'h0F00);
        chk("CALL: return address [EFF]", mem[16'h0EFF], 8'h0D); chk("CALL: [F00]", mem[16'h0F00], 8'h00);
        chk("RET returned to the loop (PC)", dbg_pc == 64'h0D || dbg_pc == 64'h0F, 1); chk("final SP", dut.u_rf1.mem_a[11], 64'h0F01);
        $display("pc=%h errors=%0d", dbg_pc, errs);
        if (errs == 0) $display("RESULT: WORD CROSSING OK"); else $display("RESULT: %0d ERRORS", errs);
        $finish;
    end
endmodule
