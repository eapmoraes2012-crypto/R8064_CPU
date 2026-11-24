// tb_slot_full.v - aud_slot_full + r8064_audio driven by Z80-like slot cycles (3.58 MHz timing, 1 wait state):
// I/O write/read (PSG #1), subslot register FFFFh (write, inverted read-back), SCC #1 in subslot 0 at page 2,
// signature in subslot 2 at page 1, and no answer on an unclaimed port.
`timescale 1ns/1ps
module tb_slot_full;
    reg clk = 0, rst = 1; always #8.7297 clk = ~clk;
    reg sltsl_n = 1, mreq_n = 1, iorq_n = 1, rd_n = 1, wr_n = 1; reg [15:0] a = 0; reg [7:0] dout = 8'hFF;
    wire [7:0] d_o; wire d_oe;
    wire [7:0] bus = d_oe ? d_o : dout;
    wire io_we, io_re, m_we, m_re, io_hit, m_hit; wire [7:0] io_a, io_wd, io_rd, m_wd, m_rd; wire [15:0] m_a; wire [1:0] m_ss;
    aud_slot_full u_s(.clk(clk), .rst(rst), .slot_sltsl_n(sltsl_n), .slot_mreq_n(mreq_n), .slot_iorq_n(iorq_n), .slot_rd_n(rd_n), .slot_wr_n(wr_n),
        .slot_a(a), .slot_d_i(dout), .slot_d_o(d_o), .slot_d_oe(d_oe),
        .io_we(io_we), .io_re(io_re), .io_a(io_a), .io_wd(io_wd), .io_hit(io_hit), .io_rd(io_rd),
        .m_we(m_we), .m_re(m_re), .m_a(m_a), .m_wd(m_wd), .m_ss(m_ss), .m_hit(m_hit), .m_rd(m_rd));
    wire r_ack; wire [7:0] r_rd; wire bck, lrck, sd, oclk;
    r8064_audio dut(.clk(clk), .rst(rst), .io_we(io_we), .io_re(io_re), .io_a(io_a), .io_wd(io_wd), .io_hit(io_hit), .io_rd(io_rd),
        .m_we(m_we), .m_re(m_re), .m_a(m_a), .m_wd(m_wd), .m_ss(m_ss), .m_hit(m_hit), .m_rd(m_rd),
        .r_io_we(1'b0), .r_io_re(1'b0), .r_io_a(8'd0), .r_io_wd(8'd0), .r_m_we(1'b0), .r_m_re(1'b0), .r_m_a(16'd0), .r_m_wd(8'd0), .r_ss(2'd0),
        .r_ack(r_ack), .r_rd(r_rd), .i2s_bck(bck), .i2s_lrck(lrck), .i2s_data(sd), .opl_clk(oclk),
        .o1_sy(1'b0), .o1_doab(1'b0), .o1_docd(1'b0), .o1_smpac(1'b0), .o1_smpbd(1'b0), .o2_sy(1'b0), .o2_doab(1'b0), .o2_docd(1'b0), .o2_smpac(1'b0), .o2_smpbd(1'b0),
        .am_ack(1'b0), .am_rd(8'h00));
    localparam T = 279.4;   // Z80 T-state at 3.58 MHz
    integer errs = 0;
    task chk(input [255:0] what, input [31:0] got, input [31:0] exp); begin if (got !== exp) begin errs = errs + 1; $display("ERROR %0s: got %h expected %h", what, got, exp); end end endtask
    task iow(input [7:0] p, input [7:0] v); begin a = p; #(T); iorq_n = 0; dout = v; wr_n = 0; #(3*T); wr_n = 1; iorq_n = 1; #(T); dout = 8'hFF; end endtask
    task ior(input [7:0] p, output [7:0] v); begin a = p; #(T); iorq_n = 0; rd_n = 0; #(3*T); v = bus; rd_n = 1; iorq_n = 1; #(T); end endtask
    task mw(input [15:0] ad, input [7:0] v); begin a = ad; #(T/2); mreq_n = 0; sltsl_n = 0; dout = v; #(T); wr_n = 0; #(2*T); wr_n = 1; mreq_n = 1; sltsl_n = 1; #(T); dout = 8'hFF; end endtask
    task mr(input [15:0] ad, output [7:0] v, output oe); begin a = ad; #(T/2); mreq_n = 0; sltsl_n = 0; rd_n = 0; #(2*T); v = bus; oe = d_oe; rd_n = 1; mreq_n = 1; sltsl_n = 1; #(T); end endtask
    reg [7:0] v; reg oe;
    initial begin
        #200 rst = 0; #200;
        iow(8'h10, 8'd2); iow(8'h11, 8'h5A); ior(8'h12, v); chk("PSG R2 via slot", v, 8'h5A);
        ior(8'h33, v); chk("unclaimed port floats (no drive)", v, 8'hFF);
        mw(16'hFFFF, 8'b00_00_10_00);                       // page 1 -> subslot 2, page 2 -> subslot 0
        mr(16'hFFFF, v, oe); chk("subslot register reads inverted", v, 8'b11_11_01_11);
        mr(16'h4018, v, oe); chk("signature in subslot 2", v, 8'h41);
        mw(16'h9000, 8'h3F); mw(16'h9810, 8'h77); mr(16'h9810, v, oe); chk("SCC #1 wave via slot", v, 8'h77);
        mw(16'hFFFF, 8'b00_01_10_00);                       // page 2 -> subslot 1 (SCC #2 not enabled)
        mr(16'h9810, v, oe); chk("SCC #2 disabled: no drive", oe, 1'b0);
        if (errs == 0) $display("RESULT: SLOT INTERFACE OK"); else $display("RESULT: %0d ERRORS", errs);
        $finish;
    end
endmodule
