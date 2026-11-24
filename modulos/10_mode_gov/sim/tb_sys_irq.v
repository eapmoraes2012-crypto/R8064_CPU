`timescale 1ns/1ps
// full MSX system executing the sequence program (LD SP/PUSH/POP/CALL/RET/OUT/IN) in Z80 ROM, R800 DRAM and native.
// program and stack stay in the mapper (slot 3, segment 1 -> physical 4000h); byte-by-byte memory only answers physical addresses.
module tb_sys_irq;
    wire [7:0] d_be; reg clk = 0, rst = 1, irq = 1; always #5 clk = ~clk;
    wire i_req, d_req, d_we, i_hit, d_hit, d_wr_ok; wire [63:0] i_paddr, d_paddr, d_wdata, dbg_pc; wire [1:0] d_size; wire [7:0] dbg_f; wire dbg_sig;
    reg i_ack = 0, d_ack = 0; reg [63:0] i_rdata = 0, d_rdata = 0; reg [7:0] mem [0:32767]; reg [63:0] pm [0:511];
    reg io_we = 0, io_re = 0; reg [7:0] io_a = 0, io_wd = 0; wire [7:0] io_rd; wire io_oe, iox_we, iox_re; wire [7:0] iox_a, iox_wd; wire nat, csel, z80, rom, mbusy, cv;
    reg go_mem = 0; parameter EXP_R = 560;
    r8064_msx_sys dut(.smc_miss(1'b0), .i_flt(1'b0), .d_flt(1'b0), .i_cs(3'd0), .d_cs(3'd0), .clk(clk), .rst(rst), .irq(irq), .i_req(i_req), .i_ack(i_ack), .i_paddr(i_paddr), .i_rdata(i_rdata),
        .d_req(d_req), .d_we(d_we), .d_paddr(d_paddr), .d_size(d_size), .d_wdata(d_wdata), .d_be(d_be), .d_ack(d_ack), .d_rdata(d_rdata), .i_hit(i_hit), .d_hit(d_hit), .d_wr_ok(d_wr_ok),
        .io_we(io_we), .io_re(io_re), .io_a(io_a), .io_wd(io_wd), .io_rd(io_rd), .io_oe(io_oe), .io_x_we(iox_we), .io_x_re(iox_re), .io_x_a(iox_a), .io_x_wd(iox_wd), .io_x_rd(8'h5A), .port_c(8'd0), .fm_we(1'b0), .fm_re(1'b0), .fm_a(2'd0), .fm_wd(8'd0), .fm_rd(), .fifo_irq(), .fifo_rst(),
        .native64(nat), .clk_sel(csel), .is_z80(z80), .is_rom(rom), .mode_busy(mbusy), .dbg_pc(dbg_pc), .dbg_f(dbg_f), .dbg_sig(dbg_sig), .gov_cv(cv));
    integer tc [0:63]; reg ie_c [0:63]; integer ki, kx = -1; integer ncv = 0; integer ic = 0, errs = 0, k, n_ow = 0, n_ir = 0, now = 0, tw = 0; reg [7:0] lw_a = 0, lw_d = 0;
    initial begin $readmemh("prog_irq3.mem", pm); for (k = 0; k < 4096; k = k + 1) mem[16'h4000 + k] = pm[k/8] >> (8*(k%8)); end
    always @(posedge clk) begin
        i_ack <= 0; d_ack <= 0; now <= now + 1;
        if (go_mem) begin
            if (i_req && !i_ack) begin ic <= ic + 1; if (ic == 2) begin ic <= 0; i_ack <= 1;
                for (k = 0; k < 8; k = k + 1) i_rdata[8*k +: 8] <= mem[{i_paddr[14:3], 3'b000} + k]; end end else ic <= 0;
            if (d_req && !d_ack) begin d_ack <= 1;
                if (d_we) begin for (k = 0; k < 8; k = k + 1) if (d_be[k]) mem[{d_paddr[14:3], 3'b000} + k] <= d_wdata[8*k +: 8]; end
                else for (k = 0; k < 8; k = k + 1) d_rdata[8*k +: 8] <= mem[{d_paddr[14:3], 3'b000} + k];
            end
        end
        if (iox_we) begin n_ow <= n_ow + 1; lw_a <= iox_a; lw_d <= iox_wd; end
        if (iox_re) n_ir <= n_ir + 1;
        if (cv && go_mem) begin tc[ncv] <= now; ie_c[ncv] <= dut.u_cpu.u_core.irq_ent; ncv <= ncv + 1; end
        if (dut.u_cpu.u_core.irq_take) irq <= 0;
    end
    task wio(input [7:0] ad, input [7:0] d); begin @(posedge clk); #1 io_a = ad; io_wd = d; io_we = 1; @(posedge clk); #1 io_we = 0; end endtask
    task chk(input [255:0] nome, input [63:0] got, input [63:0] exp);
        if (got !== exp) begin errs = errs + 1; $display("ERROR %0s: got %h expected %h", nome, got, exp); end
    endtask
    initial begin
        repeat (4) @(posedge clk); rst = 0;
        wio(8'hA8, 8'hFF); wio(8'hFC, 8'h01);
        if ($test$plusargs("r800")) begin wio(8'hE4, 8'h06); wio(8'hE5, 8'h00); end
        if ($test$plusargs("native")) begin wio(8'h3D, 8'hA5); wio(8'h3E, 8'h01); end
        go_mem = 1;
        repeat (8000) @(posedge clk);
        for (ki = 0; ki < 20; ki = ki + 1) if (ie_c[ki] === 1'b1 && kx < 0) kx = ki;
        $display("interrupt entry commit = #%0d ; time until the next commit = %0d clocks", kx, tc[kx+1]-tc[kx]);
        chk("interrupt time", tc[kx+1]-tc[kx], $test$plusargs("r800") ? 48 : 224);
        $display("native mode=%0d z80=%0d rom=%0d | final loop at %0d clocks | dbg_pc=%h", nat, z80, rom, tw, dbg_pc);
        if (errs == 0) $display("RESULT: IRQ TIMING OK"); else $display("RESULT: %0d ERRORS", errs);
        $finish;
    end
endmodule
