`timescale 1ns/1ps
// Z80 block instructions: LDIR, LDDR, CPIR, INIR, OTIR (isolated core; byte-by-byte memory)
module tb_blk;
    `include "prog_blk_pcs.vh"
    wire [7:0] d_be; reg clk = 0, rst = 1, irq = 0; always #5 clk = ~clk;
    wire i_req, d_req, d_we; wire [63:0] i_addr, d_addr, d_wdata, dbg_pc; wire [1:0] d_size; wire [7:0] dbg_f; wire dbg_sig;
    reg i_ack = 0, d_ack = 0; reg [63:0] i_rdata = 0, d_rdata = 0; reg [7:0] mem [0:4095]; reg [63:0] pm [0:511];
    wire io_we, io_re; wire [7:0] io_a, io_wd; reg [7:0] io_rdata = 0;
    r8064_core_min dut(.smc_miss(1'b0), .i_flt(1'b0), .d_flt(1'b0), .i_cs(3'd0), .d_cs(3'd0), .clk(clk), .rst(rst), .irq(irq), .i_req(i_req), .i_addr(i_addr), .i_ack(i_ack), .i_rdata(i_rdata),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_size(d_size), .d_wdata(d_wdata), .d_be(d_be), .d_ack(d_ack), .d_rdata(d_rdata),
        .dbg_pc(dbg_pc), .dbg_f(dbg_f), .dbg_sig(dbg_sig), .gov_go(1'b1), .gov_wait(1'b0), .port_c(8'd0), .gov_page(), .gov_op(), .gov_port(), .gov_cv(), .gov_alt_ev(), .gov_boundary(),
        .gov_pc(), .gov_len(), .gov_dev(), .gov_daddr(), .gov_dsize(), .gov_dwe(), .io_we(io_we), .io_re(io_re), .io_a(io_a), .io_wd(io_wd), .io_rdata(io_rdata));
    integer ic = 0, k, errs = 0, n_ow = 0, n_ir = 0; reg [7:0] ow_a [0:15]; reg [7:0] ow_d [0:15];
    initial begin $readmemh("prog_blk.mem", pm); for (k = 0; k < 4096; k = k + 1) mem[k] = pm[k/8] >> (8*(k%8)); end
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
    // snapshots of the registers right after each block
    reg [63:0] s_hl[1:5], s_de[1:5], s_bc[1:5], s_ax[1:5]; reg [7:0] s_f[1:5]; reg [4:0] got_s = 0; integer nio_at_otir = 0;
    `define SNAP(N, PCX) always @(posedge clk) if (dut.issue && !dut.seq && dut.dpc[15:0] == PCX && !got_s[N-1]) begin got_s[N-1] <= 1; #1; \
        s_hl[N] = dut.u_rf1.mem_a[3]; s_de[N] = dut.u_rf1.mem_a[2]; s_bc[N] = dut.u_rf1.mem_a[1]; s_ax[N] = dut.u_rf1.mem_a[0]; s_f[N] = dut.fl; end
    `SNAP(1, PC_AFTER_LDIR) `SNAP(2, PC_AFTER_LDDR) `SNAP(3, PC_AFTER_CPIR) `SNAP(4, PC_AFTER_INIR) `SNAP(5, PC_AFTER_OTIR)
    initial begin
        repeat (4) @(posedge clk); rst = 0;
        repeat (40000) @(posedge clk);
        chk("LDIR: HL", s_hl[1], 64'h0105); chk("LDIR: DE", s_de[1], 64'h0205); chk("LDIR: BC", s_bc[1], 64'h0); chk("LDIR: PV=0", s_f[1][2], 0);
        chk("LDIR: [200]", mem[16'h200], 8'h41); chk("LDIR: [204]", mem[16'h204], 8'h45); chk("LDIR: [205] intact", mem[16'h205], 8'h00);
        chk("LDDR: HL", s_hl[2], 64'h0121); chk("LDDR: DE", s_de[2], 64'h0221); chk("LDDR: BC", s_bc[2], 64'h0);
        chk("LDDR: [224]", mem[16'h224], 8'h63); chk("LDDR: [222]", mem[16'h222], 8'h61); chk("LDDR: [221] intact", mem[16'h221], 8'h00);
        chk("CPIR: HL (after the match)", s_hl[3], 64'h0103); chk("CPIR: BC", s_bc[3], 64'h2); chk("CPIR: Z=1", s_f[3][6], 1); chk("CPIR: PV=1 (BC!=0)", s_f[3][2], 1); chk("CPIR: A", s_ax[3], 64'h43);
        chk("INIR: HL", s_hl[4], 64'h0303); chk("INIR: BC (B=0, C=78)", s_bc[4][15:0], 16'h0078); chk("INIR: Z=1", s_f[4][6], 1);
        chk("INIR: [300]", mem[16'h300], 8'h5A); chk("INIR: [302]", mem[16'h302], 8'h5A); chk("INIR: [303] intact", mem[16'h303], 8'h00);
        chk("OTIR: HL", s_hl[5], 64'h0103); chk("OTIR: B=0", s_bc[5][15:8], 8'h00); chk("OTIR: 3 writes", n_ow, 3);
        chk("OTIR: port", ow_a[0], 8'h77); chk("OTIR: data0", ow_d[0], 8'h41); chk("OTIR: data1", ow_d[1], 8'h42); chk("OTIR: data2", ow_d[2], 8'h43);
        chk("INIR: 3 reads", n_ir, 3); chk("final PC (JR $ loop: sampling phase)", (dbg_pc == PC_END || dbg_pc == PC_END + 2) ? PC_END : dbg_pc, PC_END);
        $display("pc=%h errors=%0d", dbg_pc, errs);
        if (errs == 0) $display("RESULT: BLOCKS OK"); else $display("RESULT: %0d ERRORS", errs);
        $finish;
    end
endmodule
