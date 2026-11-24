`timescale 1ns/1ps
// FIFOs inside the system: ports E8h-EC served internally (they do not leak into io_x_*), F3h/F4h remain free for the MSX2+.
module tb_sys_fifo;
    reg clk = 0, rst = 1; always #5 clk = ~clk;
    reg io_we = 0, io_re = 0; reg [7:0] io_a = 0, io_wd = 0; wire [7:0] io_rd; wire io_oe, iox_we, iox_re; wire [7:0] iox_a, iox_wd;
    reg fm_we = 0, fm_re = 0; reg [1:0] fm_a = 0; reg [7:0] fm_wd = 0; wire [7:0] fm_rd; wire fifo_irq, fifo_rst;
    wire [63:0] i_paddr, d_paddr, d_wdata, dbg_pc; wire [1:0] d_size; wire [7:0] d_be, dbg_f; wire i_req, d_req, d_we, i_hit, d_hit, d_wr_ok, dbg_sig, nat, csel, z80, rom, mbusy, cv;
    r8064_msx_sys dut(.smc_miss(1'b0), .i_flt(1'b0), .d_flt(1'b0), .i_cs(3'd0), .d_cs(3'd0), .clk(clk), .rst(rst), .irq(1'b1), .i_req(i_req), .i_ack(1'b0), .i_paddr(i_paddr), .i_rdata(64'd0),
        .d_req(d_req), .d_we(d_we), .d_paddr(d_paddr), .d_size(d_size), .d_wdata(d_wdata), .d_be(d_be), .d_ack(1'b0), .d_rdata(64'd0), .i_hit(i_hit), .d_hit(d_hit), .d_wr_ok(d_wr_ok),
        .io_we(io_we), .io_re(io_re), .io_a(io_a), .io_wd(io_wd), .io_rd(io_rd), .io_oe(io_oe), .io_x_we(iox_we), .io_x_re(iox_re), .io_x_a(iox_a), .io_x_wd(iox_wd), .io_x_rd(8'h5A), .port_c(8'd0),
        .fm_we(fm_we), .fm_re(fm_re), .fm_a(fm_a), .fm_wd(fm_wd), .fm_rd(fm_rd), .fifo_irq(fifo_irq), .fifo_rst(fifo_rst),
        .native64(nat), .clk_sel(csel), .is_z80(z80), .is_rom(rom), .mode_busy(mbusy), .dbg_pc(dbg_pc), .dbg_f(dbg_f), .dbg_sig(dbg_sig), .gov_cv(cv), .dma_pop(1'b0), .dma_push(1'b0), .dma_wd(8'h00), .dma_a_avail(), .dma_a_q(), .dma_b_space(), .fifo_win());
    integer errs = 0, leak = 0, ext = 0; reg [7:0] v;
    always @(posedge clk) begin if ((iox_we || iox_re) && iox_a >= 8'hE8 && iox_a <= 8'hEC) leak = leak + 1; if ((iox_we || iox_re) && (iox_a == 8'hF3 || iox_a == 8'hF4)) ext = ext + 1; end
    task chk(input [255:0] n, input [31:0] g, input [31:0] e); if (g !== e) begin errs = errs + 1; $display("ERROR %0s: got %h expected %h", n, g, e); end endtask
    task mw(input [1:0] a, input [7:0] d); begin @(posedge clk); #1 fm_a = a; fm_wd = d; fm_we = 1; @(posedge clk); #1 fm_we = 0; end endtask
    task iw(input [7:0] a, input [7:0] d); begin @(posedge clk); #1 io_a = a; io_wd = d; io_we = 1; @(posedge clk); #1 io_we = 0; end endtask
    task ir(input [7:0] a, output [7:0] d); begin @(posedge clk); #1 io_a = a; io_re = 1; #1 d = io_rd; @(posedge clk); #1 io_re = 0; end endtask
    initial begin
        repeat (4) @(posedge clk); rst = 0; repeat (4) @(posedge clk);
        mw(2, 8'd2); mw(0, 8'h5C); mw(0, 8'hC5); mw(1, 8'h05); repeat (3) @(posedge clk);
        ir(8'hEC, v); chk("FLAGS INICIAR", v[0], 1); ir(8'hEA, v); chk("LEN_L", v, 2);
        ir(8'hE8, v); chk("byte0", v, 8'h5C); ir(8'hE8, v); chk("byte1", v, 8'hC5);
        iw(8'hE8, 8'h99); repeat (3) @(posedge clk); iw(8'hEC, 8'h04);
        chk("slot IRQ", fifo_irq, 1); @(posedge clk); #1 fm_a = 0; fm_re = 1; #1 chk("MSX reads result", fm_rd, 8'h99); @(posedge clk); #1 fm_re = 0;
        chk("nothing leaked to io_x at E8-EC", leak, 0);
        ir(8'hF3, v); chk("F3h goes outside (MSX2+)", v, 8'h5A); iw(8'hF4, 8'h01); ir(8'hE4, v);
        chk("F3/F4 reached io_x", ext >= 2, 1);
        $display("errors=%0d", errs); if (errs == 0) $display("RESULT: SYSTEM+FIFO OK"); else $display("RESULT: %0d ERRORS", errs); $finish;
    end
endmodule
