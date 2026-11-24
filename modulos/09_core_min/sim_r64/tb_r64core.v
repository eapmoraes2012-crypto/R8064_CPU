`timescale 1ns/1ps
// tb_r64core.v - R8064 integer instructions (16/32/64 bits) in the core against the Python model (gen_r64_prog.py), instruction by instruction.
// Releases ONE instruction at a time (gov_go), waits for the pipeline to drain and compares PC, AX, BC, DE, HL, IX, IY, SP (64 bits) and F; at the end it compares the 64 KB of memory.
// With +livre the core runs FREE (gov_go = 1, instructions glued into the pipeline) and only the final state (registers, F, memory) is compared:
// it catches dependencies between neighboring instructions (forwarding, mode switch, exception vector written right before the exception) that step-by-step hides.
// Plusargs: +hex=<prefix>_mem.hex +trace=<prefix>_trace.txt +fim=<prefix>_fim.hex [+fpu=<prefix>_fpu.hex] [+v] [+livre]
module tb_r64core;
    reg clk = 0, rst = 1, go = 0; always #5 clk = ~clk;
    wire i_req, d_req, d_we; wire [63:0] i_addr, d_addr, d_wdata, dbg_pc; wire [1:0] d_size; wire [7:0] dbg_f, d_be; wire dbg_sig;
    reg i_ack = 0, d_ack = 0; reg [63:0] i_rdata = 0, d_rdata = 0; reg [7:0] mem [0:65535]; reg [7:0] fim [0:65535];
    wire io_we, io_re; wire [7:0] io_a, io_wd;
    reg [7:0] io_n = 0, io_chk = 0; wire [7:0] io_rd = io_a + 8'd37 * io_n + io_chk;   // test port: read = C + 37*n + chk; write updates chk
    always @(posedge clk) begin if (io_re) io_n <= io_n + 8'd1; if (io_we) io_chk <= {io_chk[6:0], io_chk[7]} ^ io_wd ^ io_a; end
    r8064_core_min dut(.smc_miss(1'b0), .i_flt(1'b0), .d_flt(1'b0), .i_cs(3'd0), .d_cs(3'd0), .clk(clk), .rst(rst), .irq(1'b0),
        .i_req(i_req), .i_addr(i_addr), .i_ack(i_ack), .i_rdata(i_rdata),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_size(d_size), .d_wdata(d_wdata), .d_be(d_be), .d_ack(d_ack), .d_rdata(d_rdata),
        .dbg_pc(dbg_pc), .dbg_f(dbg_f), .dbg_sig(dbg_sig), .gov_go(go), .gov_wait(1'b0), .port_c(8'd0), .gov_page(), .gov_op(), .gov_port(), .gov_cv(), .gov_alt_ev(), .gov_boundary(),
        .gov_pc(), .gov_len(), .gov_dev(), .gov_daddr(), .gov_dsize(), .gov_dwe(), .io_we(io_we), .io_re(io_re), .io_a(io_a), .io_wd(io_wd), .io_rdata(io_rd));
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
    wire busy = dut.v_xr | dut.v_x1 | dut.v_x2 | dut.v_x3 | dut.v_m | dut.v_w | dut.flush_q | dut.flush_raw | dut.seq | dut.ex_act;
    reg [79:0] fpe [0:9]; reg [1023:0] ffpu;
    reg [1023:0] fhex, ftrace, ffim; integer fd, rc, n = 0, errs = 0, idle, tmo, merr = 0, q; reg verb;
    reg [63:0] e [0:7], g [0:7], pc0; reg [7:0] e_f, e_em; reg [15:0] e_sw;
    initial begin
        if (!$value$plusargs("hex=%s", fhex) || !$value$plusargs("trace=%s", ftrace)) begin $display("missing +hex= and +trace="); $finish; end
        verb = $test$plusargs("v");
        $readmemh(fhex, mem); fd = $fopen(ftrace, "r");
        repeat (4) @(posedge clk); rst = 0;
        if ($test$plusargs("livre")) begin : solto
            rc = 11; while (rc == 11) begin rc = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h", g[0], g[1], g[2], g[3], g[4], g[5], g[6], g[7], pc0[7:0], e_sw, e_em); if (rc == 11) begin n = n + 1; for (k = 0; k < 8; k = k + 1) e[k] = g[k]; e_f = pc0[7:0]; end end
            go = 1; tmo = 0;
            while (!(dut.flush_br && dut.flush_tgt_raw == e[0])) begin @(posedge clk); tmo = tmo + 1; if (tmo > 30000000) begin $display("ERROR: the program did not reach the end (pc=%h)", dut.npc); errs = errs + 1; disable solto; end end
            repeat (40) @(posedge clk);                    // the last branch (or the final JR $) was already taken: the state no longer changes
            g[0] = e[0]; g[1] = dut.u_rf1.mem_a[0]; g[2] = dut.u_rf1.mem_a[1]; g[3] = dut.u_rf1.mem_a[2]; g[4] = dut.u_rf1.mem_a[3]; g[5] = dut.u_rf1.mem_a[9]; g[6] = dut.u_rf1.mem_a[10]; g[7] = dut.u_rf1.mem_a[11];
            for (k = 1; k < 8; k = k + 1) if (g[k] !== e[k]) begin errs = errs + 1; $display("DIVERGENCE in final state, register %0d: core %h model %h", k, g[k], e[k]); end
            if (dut.fl !== e_f) begin errs = errs + 1; $display("DIVERGENCE in final state, F: core %h model %h", dut.fl, e_f); end
        end else
        begin : laco
            forever begin
                rc = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h", e[0], e[1], e[2], e[3], e[4], e[5], e[6], e[7], e_f, e_sw, e_em);
                if (rc != 11) disable laco;
                pc0 = dut.npc;
                go = 1; tmo = 0; @(posedge clk);
                while (!dut.consume && !dut.flush_br && !dut.ex_take) begin @(posedge clk); tmo = tmo + 1; if (tmo > 60000) begin $display("ERROR: instruction %0d (pc=%h) was not issued", n, pc0); errs = errs + 1; disable laco; end end
                #1 go = 0; idle = 0; tmo = 0;
                while (idle < 3) begin @(posedge clk); #1; idle = busy ? 0 : idle + 1; tmo = tmo + 1; if (tmo > 60000) begin $display("ERROR: instruction %0d (pc=%h) did not finish", n, pc0); errs = errs + 1; disable laco; end end
                n = n + 1;
                g[0] = dut.npc; g[1] = dut.u_rf1.mem_a[0]; g[2] = dut.u_rf1.mem_a[1]; g[3] = dut.u_rf1.mem_a[2]; g[4] = dut.u_rf1.mem_a[3];
                g[5] = dut.u_rf1.mem_a[9]; g[6] = dut.u_rf1.mem_a[10]; g[7] = dut.u_rf1.mem_a[11];
                if (verb) $display("#%0d pc=%h op=%h %h %h %h -> pc=%h ax=%h bc=%h f=%h", n, pc0[15:0], mem[pc0[15:0]], mem[pc0[15:0]+16'd1], mem[pc0[15:0]+16'd2], mem[pc0[15:0]+16'd3], g[0], g[1], g[2], dut.fl);
                q = 0; for (k = 0; k < 8; k = k + 1) if (g[k] !== e[k]) q = 1;
                if (dut.u_fpu.sw !== e_sw || dut.u_fpu.emp !== e_em) begin q = 1; $display("  FPU: state %h empties %b; model: state %h empties %b", dut.u_fpu.sw, dut.u_fpu.emp, e_sw, e_em); end
                if (q || dut.fl !== e_f) begin
                    errs = errs + 1;
                    $display("DIVERGENCE at instruction %0d: pc=%h opcode %h %h %h %h %h", n, pc0, mem[pc0[15:0]], mem[pc0[15:0]+16'd1], mem[pc0[15:0]+16'd2], mem[pc0[15:0]+16'd3], mem[pc0[15:0]+16'd4]);
                    $display("  core: pc=%h ax=%h bc=%h de=%h hl=%h ix=%h iy=%h sp=%h f=%h", g[0], g[1], g[2], g[3], g[4], g[5], g[6], g[7], dut.fl);
                    $display("  model: pc=%h ax=%h bc=%h de=%h hl=%h ix=%h iy=%h sp=%h f=%h", e[0], e[1], e[2], e[3], e[4], e[5], e[6], e[7], e_f);
                    disable laco;
                end
            end
        end
        if (errs == 0 && $value$plusargs("fim=%s", ffim)) begin
            $readmemh(ffim, fim);
            for (k = 0; k < 65536; k = k + 1) if (mem[k] !== fim[k]) begin merr = merr + 1; if (merr <= 5) $display("MEMORY differs at %h: core %h model %h", k[15:0], mem[k], fim[k]); end
            errs = errs + merr;
        end
        if (errs == 0 && $value$plusargs("fpu=%s", ffpu)) begin                 // final FPU state: status word, empties and the physical registers written
            $readmemh(ffpu, fpe);
            if (dut.u_fpu.sw !== fpe[0][15:0]) begin errs = errs + 1; $display("FPU: status word %h, model %h", dut.u_fpu.sw, fpe[0][15:0]); end
            if (dut.u_fpu.emp !== fpe[1][7:0]) begin errs = errs + 1; $display("FPU: empties %b, model %b", dut.u_fpu.emp, fpe[1][7:0]); end
            for (k = 0; k < 8; k = k + 1) if (fpe[2 + k] !== 80'hx && dut.u_fpu.stk[k] !== fpe[2 + k]) begin errs = errs + 1; $display("FPU: physical register %0d = %h, model %h", k, dut.u_fpu.stk[k], fpe[2 + k]); end
        end
        $display("%0d instructions compared, %0d memory bytes different", n, merr);
        if (errs == 0) $display("RESULT: R8064 16/32/64 IN CORE OK"); else $display("RESULT: %0d ERRORS", errs);
        $finish;
    end
endmodule
