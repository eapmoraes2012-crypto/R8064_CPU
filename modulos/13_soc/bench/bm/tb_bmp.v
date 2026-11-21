`timescale 1ns/1ps
// tb_bm.v - runs a benchmark image (+img=<hex file, 1 byte per line, up to 64 KB at address 0>) on the full SoC (real ROMs, caches, MMU
// bypass, SDRAM model) from reset, in the mode selected by the image (crt0.s). Prints the clocks between OUT (0F0h) and OUT (0F1h), the
// result bytes written to port 0F2h, and stops at OUT (0F3h).   +max=<clock limit, default 400000000>
module tb_bm;   // +prof: clock profile of the core in the timing window
    reg clk = 0, rst = 1; always #5 clk = ~clk;
    wire [7:0] io_rd; wire io_oe, iox_we, iox_re; wire [7:0] iox_a, iox_wd;
    wire nat, csel, z80, rom, mbusy, cv, dbg_sig, init_done, fifo_irq, fifo_rst, fbi, fbd, i_fault, d_fault, mmu_en_w, mmu_user_w;
    wire [2:0] ic, dc; wire [63:0] dbg_pc; wire [7:0] dbg_f, fm_rd;
    wire s_cke, s_cs_n, s_ras_n, s_cas_n, s_we_n, s_dq_oe; wire [3:0] s_dqm; wire [1:0] s_ba; wire [10:0] s_a; wire [31:0] s_dq_o, mdq;
    r8064_soc #(.INIT_CYC(2000)) dut(.clk(clk), .rst(rst), .irq(1'b1),
        .io_we(1'b0), .io_re(1'b0), .io_a(8'd0), .io_wd(8'd0), .io_rd(io_rd), .io_oe(io_oe), .io_x_we(iox_we), .io_x_re(iox_re), .io_x_a(iox_a), .io_x_wd(iox_wd), .io_x_rd(8'h5A), .port_c(8'd0),
        .sb_we(1'b0), .sb_re(1'b0), .sb_a(14'd0), .sb_wd(8'd0), .sb_rd(), .fm_we(1'b0), .fm_re(1'b0), .fm_a(2'd0), .fm_wd(8'd0), .fm_rd(fm_rd), .fifo_irq(fifo_irq), .fifo_rst(fifo_rst),
        .native64(nat), .clk_sel(csel), .is_z80(z80), .is_rom(rom), .mode_busy(mbusy), .dbg_pc(dbg_pc), .dbg_f(dbg_f), .dbg_sig(dbg_sig), .gov_cv(cv),
        .fl_busy_i(fbi), .fl_busy_d(fbd), .mmu_en(mmu_en_w), .mmu_user(mmu_user_w),
        .i_fault(i_fault), .d_fault(d_fault), .i_cause(ic), .d_cause(dc),
        .init_done(init_done), .s_cke(s_cke), .s_cs_n(s_cs_n), .s_ras_n(s_ras_n), .s_cas_n(s_cas_n), .s_we_n(s_we_n), .s_dqm(s_dqm), .s_ba(s_ba), .s_a(s_a),
        .s_dq_o(s_dq_o), .s_dq_oe(s_dq_oe), .s_dq_i(mdq));
    sdram_model mdl(.clk(clk), .cke(s_cke), .cs_n(s_cs_n), .ras_n(s_ras_n), .cas_n(s_cas_n), .we_n(s_we_n), .dqm(s_dqm), .ba(s_ba), .a(s_a), .dq_i(s_dq_o), .dq_oe(s_dq_oe), .dq_o(mdq));
    reg [7:0] img [0:65535]; reg [63:0] w; reg [8*256-1:0] fn; integer k, cyc = 0, t0 = -1, t1 = -1, nres = 0, mx;
    reg [7:0] res [0:255];
    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (iox_we && iox_a == 8'hF0) t0 <= cyc;
        if (iox_we && iox_a == 8'hF1) t1 <= cyc;
        if (iox_we && iox_a == 8'hF2) begin res[nres] <= iox_wd; nres <= nres + 1; end
    end

    // ---- profile (window F0h..F1h): why no issue in each clock
    `define CO dut.u_sys.u_cpu.u_core
    integer pc_[0:15]; integer pi; reg inw = 0;
    initial for (pi = 0; pi < 16; pi = pi + 1) pc_[pi] = 0;
    always @(posedge clk) begin
        if (iox_we && iox_a == 8'hF0) inw <= 1; if (iox_we && iox_a == 8'hF1) inw <= 0;
        if (inw) begin
            if (`CO.issue) pc_[0] = pc_[0] + 1;
            else if (`CO.flush) pc_[1] = pc_[1] + 1;
            else if (`CO.hold) pc_[2] = pc_[2] + 1;
            else if (`CO.dv) begin
                if (`CO.seqc != 0) pc_[3] = pc_[3] + 1;
                else if (!`CO.b_ready) pc_[4] = pc_[4] + 1;
                else if (`CO.hz_q) pc_[5] = pc_[5] + 1;
                else if (`CO.ser_q) pc_[6] = pc_[6] + 1;
                else pc_[7] = pc_[7] + 1;
            end else begin
                if (`CO.av) begin
                    if (!`CO.u_mine) pc_[8] = pc_[8] + 1;
                    else if (!`CO.acq) pc_[9] = pc_[9] + 1;
                    else pc_[10] = pc_[10] + 1;
                end else if (`CO.wq_v) pc_[11] = pc_[11] + 1;
                else pc_[12] = pc_[12] + 1;
            end
            if (`CO.consume) pc_[13] = pc_[13] + 1;
            if (`CO.flush_br) pc_[14] = pc_[14] + 1;
        end
    end
    task show; begin
        $display("PROF issue=%0d flush=%0d hold=%0d | B: seqc=%0d bs=%0d hz=%0d ser=%0d other=%0d | A: uop=%0d bytes=%0d as=%0d | dwa_load=%0d capture=%0d | instr=%0d taken_br=%0d",
            pc_[0], pc_[1], pc_[2], pc_[3], pc_[4], pc_[5], pc_[6], pc_[7], pc_[8], pc_[9], pc_[10], pc_[11], pc_[12], pc_[13], pc_[14]);
    end endtask
    initial begin
        if (!$value$plusargs("img=%s", fn)) fn = "img.hex";
        if (!$value$plusargs("max=%d", mx)) mx = 400000000;
        for (k = 0; k < 65536; k = k + 1) img[k] = 8'h00;
        $readmemh(fn, img);
        for (k = 0; k < 8192; k = k + 1) begin
            w = {img[8*k+7], img[8*k+6], img[8*k+5], img[8*k+4], img[8*k+3], img[8*k+2], img[8*k+1], img[8*k]};
            mdl.mem[2*k] = w[31:0]; mdl.mem[2*k + 1] = w[63:32];
        end
        repeat (4) @(posedge clk); rst = 0;
        k = 0;
        while (!(iox_we && iox_a == 8'hF3) && k < mx) begin @(posedge clk); k = k + 1; end
        @(posedge clk);
        $write("BM clocks=%0d native=%b z80=%b rom=%b end=%0d res=", t1 - t0, nat, z80, rom, k < mx);
        for (k = 0; k < nres; k = k + 1) $write("%02x", res[k]);
        $display("");
        if ($test$plusargs("prof")) show;
        $finish;
    end
endmodule
