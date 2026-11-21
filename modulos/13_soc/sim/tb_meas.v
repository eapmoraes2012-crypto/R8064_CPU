`timescale 1ns/1ps
// tb_meas.v - clocks per loop iteration in NATIVE mode for an arbitrary program image (+img=<hex file, 1 byte per line>, +loop=<hex addr>), full SoC (real uop/main ROMs), program in SDRAM through MMU (bypass) + caches + arbiters.
// +k=<kind> selects the loop body (see below); prints clocks/instruction and where the clocks go (fetch starvation, decode phases, holds).
module tb_meas;
    wire mmu_en_w, mmu_user_w; integer sc = 1; integer nfi = 0, nfd = 0; reg clk = 0, rst = 1; always #5 clk = ~clk;
    reg io_we = 0, io_re = 0; reg [7:0] io_a = 0, io_wd = 0; wire [7:0] io_rd; wire io_oe, iox_we, iox_re; wire [7:0] iox_a, iox_wd;
    wire nat, csel, z80, rom, mbusy, cv, dbg_sig, init_done, fifo_irq, fifo_rst, fbi, fbd, i_fault, d_fault; wire [2:0] ic, dc; wire [63:0] dbg_pc; wire [7:0] dbg_f, fm_rd;
    wire s_cke, s_cs_n, s_ras_n, s_cas_n, s_we_n, s_dq_oe; wire [3:0] s_dqm; wire [1:0] s_ba; wire [10:0] s_a; wire [31:0] s_dq_o, mdq;
    reg [31:0] dq_in; always @* dq_in = mdq;
    r8064_soc #(.INIT_CYC(2000)) dut(.clk(clk), .rst(rst), .irq(1'b1),
        .io_we(io_we), .io_re(io_re), .io_a(io_a), .io_wd(io_wd), .io_rd(io_rd), .io_oe(io_oe), .io_x_we(iox_we), .io_x_re(iox_re), .io_x_a(iox_a), .io_x_wd(iox_wd), .io_x_rd(8'h5A), .port_c(8'd0),
        .sb_we(1'b0), .sb_re(1'b0), .sb_a(14'd0), .sb_wd(8'd0), .sb_rd(), .fm_we(1'b0), .fm_re(1'b0), .fm_a(2'd0), .fm_wd(8'd0), .fm_rd(fm_rd), .fifo_irq(fifo_irq), .fifo_rst(fifo_rst),
        .native64(nat), .clk_sel(csel), .is_z80(z80), .is_rom(rom), .mode_busy(mbusy), .dbg_pc(dbg_pc), .dbg_f(dbg_f), .dbg_sig(dbg_sig), .gov_cv(cv),
        .fl_busy_i(fbi), .fl_busy_d(fbd), .mmu_en(mmu_en_w), .mmu_user(mmu_user_w),
        .i_fault(i_fault), .d_fault(d_fault), .i_cause(ic), .d_cause(dc),
        .init_done(init_done), .s_cke(s_cke), .s_cs_n(s_cs_n), .s_ras_n(s_ras_n), .s_cas_n(s_cas_n), .s_we_n(s_we_n), .s_dqm(s_dqm), .s_ba(s_ba), .s_a(s_a),
        .s_dq_o(s_dq_o), .s_dq_oe(s_dq_oe), .s_dq_i(dq_in));
    sdram_model mdl(.clk(clk), .cke(s_cke), .cs_n(s_cs_n), .ras_n(s_ras_n), .cas_n(s_cas_n), .we_n(s_we_n), .dqm(s_dqm), .ba(s_ba), .a(s_a), .dq_i(s_dq_o), .dq_oe(s_dq_oe), .dq_o(mdq));
    integer nwi = 0, nwd = 0; always @(posedge clk) begin if (dut.u_mem.iw_accept) nwi <= nwi + 1; if (dut.u_mem.dw_accept) nwd <= nwd + 1; end
    integer MIX = 8, j, loop0, errs = 0, k, n_ow = 0, n_ir = 0; reg [63:0] ppc = 0; integer it=0, it0, cyc=0, c0; always @(posedge clk) begin cyc <= cyc + 1; ppc <= dbg_pc; if (dbg_pc == loop0 && ppc != loop0) it <= it + 1; end
    reg [15:0] retpc = 0; reg [7:0] lw_a = 0, lw_d = 0; reg [63:0] pm [0:511];
    always @(posedge clk) begin if (iox_we) begin n_ow <= n_ow + 1; lw_a <= iox_a; lw_d <= iox_wd; end if (iox_re) n_ir <= n_ir + 1; end
    function [7:0] pb(input [23:0] pa); reg [31:0] q; begin q = mdl.mem[2*(pa>>3) + ((pa>>2)&1)]; pb = q >> (8*(pa&3)); end endfunction
    task wio(input [7:0] ad, input [7:0] d); begin @(posedge clk); #1 io_a = ad; io_wd = d; io_we = 1; @(posedge clk); #1 io_we = 0; end endtask
    task chk(input [255:0] nome, input [63:0] got, input [63:0] exp);
        if (got !== exp) begin errs = errs + 1; $display("ERROR %0s: got %h expected %h", nome, got, exp); end
    endtask
    reg [7:0] by [0:511]; reg [63:0] w; integer p;
    task emit(input [7:0] x); begin by[p] = x; p = p + 1; end endtask
    task ldrr(input [2:0] rr, input [15:0] v); begin emit(8'hED); emit(8'h3B); emit(8'h40 | (rr << 3) | 8'h01); emit(v[7:0]); emit(v[15:8]); end endtask
    task mtcr(input [4:0] n); begin emit(8'hED); emit(8'h0C); emit(n); end endtask
    task mfcr(input [4:0] n); begin emit(8'hED); emit(8'h0A); emit(n); end endtask
    function [63:0] rf(input integer n); rf = dut.u_sys.u_cpu.u_core.u_rf1.mem_a[n]; endfunction
    always @(posedge clk) begin if (i_fault) nfi <= nfi + 1; if (d_fault) nfd <= nfd + 1; end
    wire [63:0] r43 = dut.u_sys.u_cpu.u_core.u_rf1.mem_a[43], r44 = dut.u_sys.u_cpu.u_core.u_rf1.mem_a[44], r45 = dut.u_sys.u_cpu.u_core.u_rf1.mem_a[45];


    reg [7:0] img [0:16383]; reg [63:0] w2; integer nit = 0, cfirst = 0, clast = 0, lp = 0, NW = 2048; reg [8*256-1:0] fn;
    reg seen = 0;
    // wait clocks: the core stands still because of memory.
    //  data wait : a load/store in M without its acknowledge (hold caused by the data bus, not by MLT/DIV)
    //  fetch wait: no candidate in stage B and stage A waits for instruction bytes (fewer than 4 at the aligner, or A's trailing bytes) (REV50)
    wire w_mm = dut.u_sys.u_cpu.u_core.m_mem, w_ack = dut.u_sys.u_cpu.u_core.d_ack, w_xing = dut.u_sys.u_cpu.u_core.xing, w_beat = dut.u_sys.u_cpu.u_core.beat;
    wire w_dv = dut.u_sys.u_cpu.u_core.dv, w_wq = dut.u_sys.u_cpu.u_core.wq_v, w_av = dut.u_sys.u_cpu.u_core.av, w_look = dut.u_sys.u_cpu.u_core.look;
    wire w_lok = dut.u_sys.u_cpu.u_core.len_ok, w_cmp = dut.u_sys.u_cpu.u_core.a_cmpl_now; wire signed [7:0] w_avl = dut.u_sys.u_cpu.u_core.avl;
    wire w_seq = dut.u_sys.u_cpu.u_core.seq;
    wire dwait = w_mm && !(w_ack && (!w_xing || w_beat));
    wire fwait = !dwait && !w_seq && !w_dv && ((!w_av && !w_wq && w_avl < 8'sd4) || (w_av && !w_look && w_lok && !w_cmp));
    integer cw = 0, cwd = 0, wfirst = 0, wlast = 0, wdfirst = 0, wdlast = 0;
    always @(posedge clk) if (!rst) begin cw <= cw + ((dwait === 1'b1) || (fwait === 1'b1)); cwd <= cwd + (dwait === 1'b1); end
    always @(posedge clk) if (dbg_pc == lp && ppc != lp) begin
        if (nit == 4) begin wfirst <= cw; wdfirst <= cwd; end
        wlast <= cw; wdlast <= cwd;
    end
    always @(posedge clk) if (dbg_pc == lp && ppc != lp) begin
        nit <= nit + 1;
        if (nit == 4) cfirst <= cyc;
        clast <= cyc;
    end
    initial begin
        if (!$value$plusargs("img=%s", fn)) fn = "img.hex";
        if (!$value$plusargs("loop=%h", lp)) lp = 0;
        for (k = 0; k < 16384; k = k + 1) img[k] = 8'h00;
        $readmemh(fn, img);
        for (k = 0; k < NW; k = k + 1) begin
            w2 = {img[8*k+7], img[8*k+6], img[8*k+5], img[8*k+4], img[8*k+3], img[8*k+2], img[8*k+1], img[8*k]};
            mdl.mem[2*k] = w2[31:0]; mdl.mem[2*k + 1] = w2[63:32];
        end
        repeat (4) @(posedge clk); rst = 0;
        wait (init_done);
        k = 0;
        while (nit < 4 + 24 && k < 400000) begin @(posedge clk); k = k + 1; end
        if (nit >= 4 + 24) $display("TITER %0.3f native=%b wait=%0.3f dwait=%0.3f", 1.0 * (clast - cfirst) / (nit - 1 - 4), nat, 1.0 * (wlast - wfirst) / (nit - 1 - 4), 1.0 * (wdlast - wdfirst) / (nit - 1 - 4));
        else $display("TITER NA native=%b nit=%0d pc=%h", nat, nit, dbg_pc);
        $finish;
    end
endmodule
