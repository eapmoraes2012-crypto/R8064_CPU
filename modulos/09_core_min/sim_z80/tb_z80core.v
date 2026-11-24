`timescale 1ns/1ps
// tb_z80core.v - R8064 core (r8064_core_min, uop.mem) against the Z80 reference model, instruction by instruction.
// The testbench releases ONE instruction at a time (gov_go), waits for the pipeline to drain and compares PC, AF, BC, DE, HL, IX, IY, SP and the alternate set
// with the corresponding trace line (z80trace). At the end it compares the 64 KB of memory. The last column of the trace is the F mask of that instruction.
// Plusargs: +hex=<mem.hex> +trace=<trace.txt> +fim=<mem.bin.fim> [+fmask=<hex>: F bits compared, default FF] [+v: prints each instruction]
module tb_z80core;
    reg clk = 0, rst = 1, go = 0; always #5 clk = ~clk;
    wire i_req, d_req, d_we; wire [63:0] i_addr, d_addr, d_wdata, dbg_pc; wire [1:0] d_size; wire [7:0] dbg_f, d_be; wire dbg_sig;
    reg i_ack = 0, d_ack = 0; reg [63:0] i_rdata = 0, d_rdata = 0; reg [7:0] mem [0:65535]; reg [7:0] fim [0:65535];
    wire io_we, io_re; wire [7:0] io_a, io_wd;
    r8064_core_min dut(.smc_miss(1'b0), .i_flt(1'b0), .d_flt(1'b0), .i_cs(3'd0), .d_cs(3'd0), .clk(clk), .rst(rst), .irq(1'b0),
        .i_req(i_req), .i_addr(i_addr), .i_ack(i_ack), .i_rdata(i_rdata),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_size(d_size), .d_wdata(d_wdata), .d_be(d_be), .d_ack(d_ack), .d_rdata(d_rdata),
        .dbg_pc(dbg_pc), .dbg_f(dbg_f), .dbg_sig(dbg_sig), .gov_go(go), .gov_wait(1'b0), .port_c(8'd0), .gov_page(), .gov_op(), .gov_port(), .gov_cv(), .gov_alt_ev(), .gov_boundary(),
        .gov_pc(), .gov_len(), .gov_dev(), .gov_daddr(), .gov_dsize(), .gov_dwe(), .io_we(io_we), .io_re(io_re), .io_a(io_a), .io_wd(io_wd), .io_rdata(8'hFF));
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
    // architectural state (the active group depends on EXX / EX AF,AF')
    wire sm = dut.sw_main, sa = dut.sw_af;
    wire [63:0] rA = dut.u_rf1.mem_a[sa ? 5 : 0], rA2 = dut.u_rf1.mem_a[sa ? 0 : 5];
    wire [15:0] rBC = dut.u_rf1.mem_a[sm ? 6 : 1], rDE = dut.u_rf1.mem_a[sm ? 7 : 2], rHL = dut.u_rf1.mem_a[sm ? 8 : 3];
    wire [15:0] rBC2 = dut.u_rf1.mem_a[sm ? 1 : 6], rDE2 = dut.u_rf1.mem_a[sm ? 2 : 7], rHL2 = dut.u_rf1.mem_a[sm ? 3 : 8];
    wire [15:0] rIX = dut.u_rf1.mem_a[9], rIY = dut.u_rf1.mem_a[10], rSP = dut.u_rf1.mem_a[11];
    wire busy = dut.v_xr | dut.v_x1 | dut.v_x2 | dut.v_x3 | dut.v_m | dut.v_w | dut.flush_q | dut.flush_raw | dut.seq;
    reg [1023:0] fhex, ftrace, ffim; integer fd, rc, n = 0, errs = 0, idle, tmo, merr = 0; reg [7:0] fmask, lmask; reg verb;
    reg [15:0] e_pc, e_af, e_bc, e_de, e_hl, e_ix, e_iy, e_sp, e_af2, e_bc2, e_de2, e_hl2, pc0;
    wire [15:0] g_af = {rA[7:0], dut.fl}, g_af2 = {rA2[7:0], dut.fl2};
    initial begin
        if (!$value$plusargs("hex=%s", fhex) || !$value$plusargs("trace=%s", ftrace)) begin $display("missing +hex= and +trace="); $finish; end
        if (!$value$plusargs("fmask=%h", fmask)) fmask = 8'hFF; verb = $test$plusargs("v");
        $readmemh(fhex, mem); fd = $fopen(ftrace, "r");
        repeat (4) @(posedge clk); rst = 0;
        begin : laco
            forever begin
                rc = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h %h %h", e_pc, e_af, e_bc, e_de, e_hl, e_ix, e_iy, e_sp, e_af2, e_bc2, e_de2, e_hl2, lmask);
                if (rc != 13) disable laco;
                pc0 = dut.npc[15:0];
                go = 1; tmo = 0; @(posedge clk);
                // end of the instruction: last uop issued (consume) or branch taken in an intermediate uop (CALL cc / RET cc with a false condition skip the rest of the chain)
                while (!dut.consume && !dut.flush_br) begin @(posedge clk); tmo = tmo + 1; if (tmo > 5000) begin $display("ERROR: instruction %0d (pc=%h) was not issued", n, pc0); errs = errs + 1; disable laco; end end
                #1 go = 0; idle = 0; tmo = 0;
                while (idle < 3) begin @(posedge clk); #1; idle = busy ? 0 : idle + 1; tmo = tmo + 1; if (tmo > 5000) begin $display("ERROR: instruction %0d (pc=%h) did not finish", n, pc0); errs = errs + 1; disable laco; end end
                n = n + 1;
                if (verb) $display("#%0d pc=%h op=%h%h%h%h -> pc=%h af=%h bc=%h de=%h hl=%h sp=%h", n, pc0, mem[pc0], mem[pc0+16'd1], mem[pc0+16'd2], mem[pc0+16'd3], dut.npc[15:0], g_af, rBC, rDE, rHL, rSP);
                if (dut.npc[15:0] !== e_pc || ((g_af ^ e_af) & {8'hFF, fmask & lmask}) !== 16'd0 || rBC !== e_bc || rDE !== e_de || rHL !== e_hl || rIX !== e_ix || rIY !== e_iy || rSP !== e_sp ||
                    ((g_af2 ^ e_af2) & {8'hFF, fmask}) !== 16'd0 || rBC2 !== e_bc2 || rDE2 !== e_de2 || rHL2 !== e_hl2) begin
                    errs = errs + 1;
                    $display("DIVERGENCE at instruction %0d: pc=%h opcode %h %h %h %h", n, pc0, mem[pc0], mem[pc0+16'd1], mem[pc0+16'd2], mem[pc0+16'd3]);
                    $display("  core: pc=%h af=%h bc=%h de=%h hl=%h ix=%h iy=%h sp=%h | af'=%h bc'=%h de'=%h hl'=%h", dut.npc[15:0], g_af, rBC, rDE, rHL, rIX, rIY, rSP, g_af2, rBC2, rDE2, rHL2);
                    $display("  model: pc=%h af=%h bc=%h de=%h hl=%h ix=%h iy=%h sp=%h | af'=%h bc'=%h de'=%h hl'=%h", e_pc, e_af, e_bc, e_de, e_hl, e_ix, e_iy, e_sp, e_af2, e_bc2, e_de2, e_hl2);
                    disable laco;
                end
                if (lmask != 8'hFF) dut.fl = e_af[7:0];   // undocumented flags ignored in this instruction: realign F with the model
            end
        end
        if (errs == 0 && $value$plusargs("fim=%s", ffim)) begin
            $readmemh(ffim, fim);
            for (k = 0; k < 65536; k = k + 1) if (mem[k] !== fim[k]) begin merr = merr + 1; if (merr <= 5) $display("MEMORY differs at %h: core %h model %h", k[15:0], mem[k], fim[k]); end
            errs = errs + merr;
        end
        $display("%0d instructions compared, %0d memory bytes different", n, merr);
        if (errs == 0) $display("RESULT: Z80 IN CORE OK"); else $display("RESULT: %0d ERRORS", errs);
        $finish;
    end
endmodule
