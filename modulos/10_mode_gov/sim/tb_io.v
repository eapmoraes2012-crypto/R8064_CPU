`timescale 1ns/1ps
// Z80 block instructions: LDIR, LDDR, CPIR, INIR, OTIR (isolated core; byte-by-byte memory)
module tb_io;
    wire [7:0] d_be; reg clk = 0, rst = 1, irq = 0; always #5 clk = ~clk;
    wire i_req, d_req, d_we; wire [63:0] i_addr, d_addr, d_wdata, dbg_pc; wire [1:0] d_size; wire [7:0] dbg_f; wire dbg_sig;
    reg i_ack = 0, d_ack = 0; reg [63:0] i_rdata = 0, d_rdata = 0; reg [7:0] mem [0:4095]; reg [63:0] pm [0:511];
    wire io_we, io_re; wire [7:0] io_a, io_wd; reg [7:0] io_rdata = 0;
    r8064_core_min dut(.smc_miss(1'b0), .i_flt(1'b0), .d_flt(1'b0), .i_cs(3'd0), .d_cs(3'd0), .clk(clk), .rst(rst), .irq(irq), .i_req(i_req), .i_addr(i_addr), .i_ack(i_ack), .i_rdata(i_rdata),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_size(d_size), .d_wdata(d_wdata), .d_be(d_be), .d_ack(d_ack), .d_rdata(d_rdata),
        .dbg_pc(dbg_pc), .dbg_f(dbg_f), .dbg_sig(dbg_sig), .gov_go(1'b1), .gov_wait(1'b0), .port_c(8'd0), .gov_page(), .gov_op(), .gov_port(), .gov_cv(), .gov_alt_ev(), .gov_boundary(),
        .gov_pc(), .gov_len(), .gov_dev(), .gov_daddr(), .gov_dsize(), .gov_dwe(), .io_we(io_we), .io_re(io_re), .io_a(io_a), .io_wd(io_wd), .io_rdata(io_rdata));
    integer ic = 0, k, errs = 0, n_ow = 0, n_ir = 0; reg [7:0] ow_a [0:15]; reg [7:0] ow_d [0:15];
    initial begin $readmemh("prog_io.mem", pm); for (k = 0; k < 4096; k = k + 1) mem[k] = pm[k/8] >> (8*(k%8)); end
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
    always @* io_rdata = (io_a == 8'h78) ? ((n_ir==0)?8'h00 : (n_ir==1)?8'h80 : (n_ir==2)?8'h07 : (n_ir==4)?8'h00 : 8'hFF) : 8'hFF;
    task chk(input [255:0] nome, input [63:0] got, input [63:0] exp);
        if (got !== exp) begin errs = errs + 1; $display("ERROR %0s: got %h expected %h", nome, got, exp); end
    endtask
    reg [7:0] sf [0:3]; reg [3:0] gs = 0;
    `define SNAPF(N, PCX) always @(posedge clk) if (dut.issue && !dut.seq && dut.dpc[15:0] == PCX && !gs[N]) begin gs[N] <= 1; sf[N] <= dut.fl; end
    `SNAPF(0, 16'd29) `SNAPF(1, 16'd31) `SNAPF(2, 16'd33) `SNAPF(3, 16'd35)
    initial begin
        repeat (4) @(posedge clk); rst = 0; @(posedge clk); #1 dut.fl = 8'h01;
        repeat (12000) @(posedge clk);
        chk("6 OUT", n_ow, 6); chk("OUT (C),0", ow_d[5], 8'h00); chk("OUT H", ow_d[0], 8'h12); chk("OUT L", ow_d[1], 8'h34); chk("OUT D", ow_d[2], 8'hAB); chk("OUT E", ow_d[3], 8'hCD); chk("OUT A", ow_d[4], 8'h41);
        chk("port (C)", ow_a[0], 8'h78); chk("port (C) last", ow_a[4], 8'h78); chk("5 IN", n_ir, 5); chk("fl IN F,(C) (00): Z PV C", dut.fl & 8'hD7, 8'h45);
        chk("D (IN D)", dut.u_rf1.mem_a[2][15:8], 8'h00); chk("E (IN E)", dut.u_rf1.mem_a[2][7:0], 8'h07); chk("A (IN A)", dut.u_rf1.mem_a[0][7:0], 8'h80); chk("BC (IN B)", dut.u_rf1.mem_a[1][15:0], 16'hFF78);
        chk("fl IN D (00): Z PV C", sf[0] & 8'hD7, 8'h45); chk("fl IN A (80): S C", sf[1] & 8'hD7, 8'h81); chk("fl IN E (07): C (PV=0)", sf[2] & 8'hD7, 8'h01); chk("fl IN B (FF): S PV C", sf[3] & 8'hD7, 8'h85);
        chk("HL intact", dut.u_rf1.mem_a[3][15:0], 16'h1234);
        $display("pc=%h errors=%0d", dbg_pc, errs);
        if (errs == 0) $display("RESULT: IO(C) OK"); else $display("RESULT: %0d ERRORS", errs);
        $finish;
    end
endmodule
