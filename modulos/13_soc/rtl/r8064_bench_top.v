// r8064_bench_top.v - TIMING BENCH for the bare Tang Nano 20K (no MSX): clkgen (27 MHz crystal -> 43.2 MHz, REV52; macro R8064_CLK57: 57.375 MHz) + SoC + embedded SDRAM
// + r8064_bench_io (UART to the PC through the board's USB serial, pin 69, 115200 8N1; clock counter driven by the core PC).
// The firmware (modulos/13_soc/bench, image monitor_l0..7.hex) runs every instruction case in a loop, exactly as tb_meas.v does in simulation:
//   per run: the firmware builds the loop at BUILD, writes its address to the bench, arms it (GO) and jumps to it. The bench counts the clocks
//   between the 5th and the 37th arrival of the PC at the loop address (32 loop iterations), stores the count and resets the SoC.
//   Each case takes 2 runs: the loop without the instruction (empty) and with it; clocks/instruction = (T_case - T_empty) * 100 / (32 * copies).
//   After a reset the firmware reads the run number and the result from the bench, prints a line and builds the next run.
// Only the SoC is reset between runs (the bench registers, the PLL and the UART keep running); the KEY1 button (pin 88) restarts everything.
`ifdef R8064_CLK57
`define R8064_B_SRC 0
`define R8064_B_CPT 16
`define R8064_B_BAUD 498
`else
`define R8064_B_SRC 4
`define R8064_B_CPT 12
`define R8064_B_BAUD 375
`endif
module r8064_bench_top #(parameter [3:0] SDR_PSDA = 4'd12)(   // 12 = 270 degrees: measured on the board (r8064_sdtest_top: phases 10..13 without errors, 4 = 100% errors)
    input  wire        clk27,        // board crystal (pin 4)
    input  wire        btn_rst,      // KEY1 (pin 88), pressed = 1
    output wire        uart_tx,      // pin 69 -> BL616 -> USB serial on the PC
    input  wire        uart_rx,      // pin 70 (not used)
    output wire [5:0]  led,          // pins 15..20, active low: 0 PLL locked, 1 blink (57 MHz clock), 2 UART activity, 3 SDRAM init + boot done,
                                     // 4 KEY1 level, 5 blink straight from the 27 MHz crystal
    // embedded SDRAM (fixed GW2AR names)
    output wire        O_sdram_clk, O_sdram_cke, O_sdram_cs_n, O_sdram_ras_n, O_sdram_cas_n, O_sdram_wen_n,
    output wire [3:0]  O_sdram_dqm,
    output wire [10:0] O_sdram_addr,
    output wire [1:0]  O_sdram_ba,
    inout  wire [31:0] IO_sdram_dq
);
    wire clk, clk_sd, locked, rst_pll;
    r8064_clkgen #(.SRC(`R8064_B_SRC), .SDR_PSDA(SDR_PSDA)) u_clk(.clk_in(clk27), .rst_in(1'b0), .clk(clk), .clk_sdram(clk_sd), .locked(locked), .rst(rst_pll));
    // KEY1: a change of its level (press or release) restarts the bench, so it works whatever the active level of the button
    reg [2:0] bs = 3'b000; reg [4:0] bst = 5'd0;
    always @(posedge clk) begin bs <= {bs[1:0], btn_rst}; if (bs[2] != bs[1]) bst <= 5'd16; else if (bst != 5'd0) bst <= bst - 5'd1; end
    wire s_cke, s_cs_n, s_ras_n, s_cas_n, s_we_n, s_dq_oe; wire [3:0] s_dqm; wire [1:0] s_ba; wire [10:0] s_a; wire [31:0] s_dq_o;
    wire init_done;
    r8064_bench #(.BAUD_DIV(`R8064_B_BAUD), .CPT(`R8064_B_CPT)) u_b(.clk(clk), .rst(rst_pll | (bst != 5'd0)), .uart_tx(uart_tx), .init_done(init_done),   // BAUD: 43.2 MHz / 115200 = 375
        .s_cke(s_cke), .s_cs_n(s_cs_n), .s_ras_n(s_ras_n), .s_cas_n(s_cas_n), .s_we_n(s_we_n), .s_dqm(s_dqm), .s_ba(s_ba), .s_a(s_a),
        .s_dq_o(s_dq_o), .s_dq_oe(s_dq_oe), .s_dq_i(IO_sdram_dq));
    assign O_sdram_clk = clk_sd;
    assign O_sdram_cke = s_cke;   assign O_sdram_cs_n = s_cs_n;  assign O_sdram_ras_n = s_ras_n;
    assign O_sdram_cas_n = s_cas_n; assign O_sdram_wen_n = s_we_n;
    assign O_sdram_dqm = s_dqm;   assign O_sdram_addr = s_a;     assign O_sdram_ba = s_ba;
    assign IO_sdram_dq = s_dq_oe ? s_dq_o : 32'bz;
    // LEDs (on = 0)
    reg [24:0] hb = 25'd0, hb27 = 25'd0; reg [21:0] act = 22'd0;
    always @(posedge clk) begin hb <= hb + 25'd1; if (!uart_tx) act <= {22{1'b1}}; else if (act != 22'd0) act <= act - 22'd1; end
    always @(posedge clk27) hb27 <= hb27 + 25'd1;
    assign led = ~{hb27[24], bs[1], init_done, act != 22'd0, hb[24], locked};
endmodule

// r8064_bench: SoC + bench I/O (no clock generator: the simulation instantiates this module directly).
module r8064_bench #(parameter BAUD_DIV = 498, parameter INIT_CYC = 20000, parameter TMO_BIT = 22, parameter SIL_BIT = 27, parameter CPT = 16)(
    input  wire        clk, rst,
    output wire        uart_tx, output wire init_done,
    output wire        s_cke, s_cs_n, s_ras_n, s_cas_n, s_we_n, s_dq_oe,
    output wire [3:0]  s_dqm, output wire [1:0] s_ba, output wire [10:0] s_a, output wire [31:0] s_dq_o, input wire [31:0] s_dq_i
);
    wire soc_rst_req;
    reg  [4:0] rq = 5'd0;                                  // SoC reset pulse after each run (16 clocks)
    always @(posedge clk) if (rst) rq <= 5'd0; else if (soc_rst_req) rq <= 5'd16; else if (rq != 5'd0) rq <= rq - 5'd1;
    wire soc_rst = rst | (rq != 5'd0);

    wire io_oe, iox_we, iox_re, nat, cs, z8, ro, mb, dbg_s, gcv, fbi, fbd, mmu_en, mmu_user, i_fault, d_fault, fifo_irq, fifo_rst;
    wire [7:0] io_rd, iox_a, iox_wd, iox_rd, fm_rd, sb_rd, dbg_f; wire [63:0] dbg_pc; wire [2:0] ic, dc;
    r8064_soc #(.BOOT_WORDS(2048), .INIT_IMG(1), .INIT_CYC(INIT_CYC), .CPT(CPT), .REF_INT(25 * CPT)) u_soc(.clk(clk), .rst(soc_rst), .irq(1'b1),
        .io_we(1'b0), .io_re(1'b0), .io_a(8'd0), .io_wd(8'd0), .io_rd(io_rd), .io_oe(io_oe),
        .io_x_we(iox_we), .io_x_re(iox_re), .io_x_a(iox_a), .io_x_wd(iox_wd), .io_x_rd(iox_rd), .port_c(8'd0),
        .fm_we(1'b0), .fm_re(1'b0), .fm_a(2'd0), .fm_wd(8'd0), .fm_rd(fm_rd),
        .sb_we(1'b0), .sb_re(1'b0), .sb_a(14'd0), .sb_wd(8'd0), .sb_rd(sb_rd),
        .fifo_irq(fifo_irq), .fifo_rst(fifo_rst), .native64(nat), .clk_sel(cs), .is_z80(z8), .is_rom(ro), .mode_busy(mb),
        .dbg_pc(dbg_pc), .dbg_f(dbg_f), .dbg_sig(dbg_s), .gov_cv(gcv), .fl_busy_i(fbi), .fl_busy_d(fbd),
        .mmu_en(mmu_en), .mmu_user(mmu_user), .i_fault(i_fault), .d_fault(d_fault), .i_cause(ic), .d_cause(dc),
        .init_done(init_done), .s_cke(s_cke), .s_cs_n(s_cs_n), .s_ras_n(s_ras_n), .s_cas_n(s_cas_n), .s_we_n(s_we_n),
        .s_dqm(s_dqm), .s_ba(s_ba), .s_a(s_a), .s_dq_o(s_dq_o), .s_dq_oe(s_dq_oe), .s_dq_i(s_dq_i));
    r8064_bench_io #(.BAUD_DIV(BAUD_DIV), .TMO_BIT(TMO_BIT), .SIL_BIT(SIL_BIT)) u_io(.clk(clk), .rst(rst), .we(iox_we), .a(iox_a), .wd(iox_wd), .rd(iox_rd),
        .pc(dbg_pc[31:0]), .init_done(init_done), .flt({i_fault, d_fault}), .soc_rst_req(soc_rst_req), .uart_tx(uart_tx));
endmodule

// r8064_bench_io: I/O ports of the bench (external ports of the SoC, io_x_*):
//   90h  OUT: byte to the UART            IN: b0 = UART busy
//   91h  OUT: loop address, one byte per write, low byte first (4 writes)
//   92h  OUT: GO (arms the counter; data = divider shift: 9 = 32 iterations x 16 copies, 5 = 32 x 1)    IN: run number, low byte
//   9Ah  IN : run number, high byte
//   93h/94h IN: result of the last two runs = (T_last - T_previous) * 100 >> shift, saturated to 0..FFFFh (hundredths of a clock)
//   95h  IN : b0 = one of the last two runs timed out, b1 = T_last < T_previous
//   96h..99h IN/OUT: free scratch bytes kept across the SoC reset (the firmware keeps its OK / DIF counters there)
//   F0h OUT: benchmark timer start, F1h OUT: stop; F4h..F7h IN: clocks between them (32 bits, low byte first) - REV52, board benchmarks
//   other ports: IN = 5Ah (as tb_meas), OUT ignored (the IN/OUT instructions under test use port 00h)
// Hardware messages (no CPU needed, to tell a board/UART problem from a CPU/SDRAM problem):
//   after the reset (power-up, KEY1):            "R8064 bench: FPGA up"
//   every 2.3 s without output from the CPU: "UART idle : pc=xxxxxxxx run=xxxx init=x flt=xx"  (init = SDRAM initialised and
//   boot copy done, flt = instruction/data fault seen since the reset; all values in hex). After the bench ends (run = 2 x cases)
//   these lines keep coming, so a terminal opened late still shows that the board is alive.
//   Every 4th of these lines (the first one too) is instead "T xxxx xxxx ...": the low 16 bits of the first 48 values of the core PC
//   after the reset (the bitstream load is a reset too).
module r8064_bench_io #(parameter BAUD_DIV = 498, parameter TMO_BIT = 22, parameter SIL_BIT = 27)(
    input  wire        clk, rst,
    input  wire        we, input wire [7:0] a, input wire [7:0] wd, output reg [7:0] rd,
    input  wire [31:0] pc,
    input  wire        init_done, input wire [1:0] flt,
    output reg         soc_rst_req,
    output wire        uart_tx
);
    // ---- hardware messages
    reg hm_on = 1'b0, hm_m = 1'b0, spoke = 1'b0; reg [5:0] hm_i = 6'd0; reg [SIL_BIT:0] sil = 0; reg [31:0] hm_pc = 32'd0; reg [15:0] hm_run = 16'd0;
    reg hm_init = 1'b0; reg [1:0] flt_s = 2'b00; reg [7:0] hm_c; wire [15:0] run_w;
    // PC trace of the first boot after the reset: the low 16 bits of the first 48 PC values, printed once ("T xxxx xxxx ...")
    reg [15:0] trc [0:47]; reg [5:0] tn = 6'd0, tk = 6'd0; reg [2:0] tr = 3'd0; reg hm_t = 1'b0; reg [1:0] tsel = 2'd0; reg [15:0] tpc = 16'd0;
    wire [15:0] tv = trc[tk];
    function [7:0] hx(input [3:0] v); hx = (v < 4'd10) ? 8'h30 + v : 8'h37 + v; endfunction
    always @* begin
        hm_c = 8'h00;
        if (hm_t) begin
            if (tk == 6'd48) hm_c = (tr == 3'd0) ? 8'h0D : (tr == 3'd1) ? 8'h0A : 8'h00;
            else case (tr)
                3'd0: hm_c = (tk == 6'd0) ? "T" : " ";
                3'd1: hm_c = hx(tv[15:12]); 3'd2: hm_c = hx(tv[11:8]); 3'd3: hm_c = hx(tv[7:4]); default: hm_c = hx(tv[3:0]);
            endcase
        end
        else if (!hm_m) case (hm_i)                      // "\r\nR8064 bench: FPGA up\r\n"
            0: hm_c = 8'h0D; 1: hm_c = 8'h0A; 2: hm_c = "R"; 3: hm_c = "8"; 4: hm_c = "0"; 5: hm_c = "6"; 6: hm_c = "4"; 7: hm_c = " ";
            8: hm_c = "b"; 9: hm_c = "e"; 10: hm_c = "n"; 11: hm_c = "c"; 12: hm_c = "h"; 13: hm_c = ":"; 14: hm_c = " "; 15: hm_c = "F";
            16: hm_c = "P"; 17: hm_c = "G"; 18: hm_c = "A"; 19: hm_c = " "; 20: hm_c = "u"; 21: hm_c = "p"; 22: hm_c = 8'h0D; 23: hm_c = 8'h0A;
            default: hm_c = 8'h00;
        endcase else case (hm_i)                    // "CPU silent: pc=xxxxxxxx run=xxxx init=x flt=xx\r\n"
            0: hm_c = "U"; 1: hm_c = "A"; 2: hm_c = "R"; 3: hm_c = "T"; 4: hm_c = " "; 5: hm_c = "i"; 6: hm_c = "d"; 7: hm_c = "l"; 8: hm_c = "e";
            9: hm_c = " "; 10: hm_c = ":"; 11: hm_c = " "; 12: hm_c = "p"; 13: hm_c = "c"; 14: hm_c = "=";
            15: hm_c = hx(hm_pc[31:28]); 16: hm_c = hx(hm_pc[27:24]); 17: hm_c = hx(hm_pc[23:20]); 18: hm_c = hx(hm_pc[19:16]);
            19: hm_c = hx(hm_pc[15:12]); 20: hm_c = hx(hm_pc[11:8]); 21: hm_c = hx(hm_pc[7:4]); 22: hm_c = hx(hm_pc[3:0]);
            23: hm_c = " "; 24: hm_c = "r"; 25: hm_c = "u"; 26: hm_c = "n"; 27: hm_c = "=";
            28: hm_c = hx(hm_run[15:12]); 29: hm_c = hx(hm_run[11:8]); 30: hm_c = hx(hm_run[7:4]); 31: hm_c = hx(hm_run[3:0]);
            32: hm_c = " "; 33: hm_c = "i"; 34: hm_c = "n"; 35: hm_c = "i"; 36: hm_c = "t"; 37: hm_c = "="; 38: hm_c = hm_init ? "1" : "0";
            39: hm_c = " "; 40: hm_c = "f"; 41: hm_c = "l"; 42: hm_c = "t"; 43: hm_c = "="; 44: hm_c = flt_s[1] ? "1" : "0"; 45: hm_c = flt_s[0] ? "1" : "0";
            46: hm_c = 8'h0D; 47: hm_c = 8'h0A;
            default: hm_c = 8'h00;
        endcase
    end
    wire cpu_tx = we && a == 8'h90;
    wire hm_go = hm_on && !cpu_tx && (hm_c != 8'h00);
    // ---- UART TX 8N1 (the CPU has priority; the hardware messages only use the idle line)
    reg [9:0] tsh = 10'h3FF; reg [3:0] tbit = 4'd0; reg [15:0] tdiv = 16'd0; reg tbusy = 1'b0;
    always @(posedge clk) begin
        if (rst) begin hm_on <= 1'b1; hm_m <= 1'b0; hm_i <= 6'd0; spoke <= 1'b0; sil <= 0; flt_s <= 2'b00;
                       tn <= 6'd0; tk <= 6'd0; tr <= 3'd0; hm_t <= 1'b0; tsel <= 2'd0; tpc <= 16'd0; end
        else begin
            if (tn != 6'd48 && pc[15:0] != tpc) begin trc[tn] <= pc[15:0]; tn <= tn + 6'd1; tpc <= pc[15:0]; end
            flt_s <= flt_s | flt;
            if (cpu_tx) begin spoke <= 1'b1; sil <= 0; end else if (!hm_on) sil <= sil + 1'b1;
            if (hm_on && !tbusy && !cpu_tx) begin
                if (hm_c == 8'h00) begin hm_on <= 1'b0; hm_t <= 1'b0; end
                else if (hm_t) begin if (tr == 3'd4 && tk != 6'd48) begin tr <= 3'd0; tk <= tk + 6'd1; end else tr <= tr + 3'd1; end
                else hm_i <= hm_i + 6'd1;
            end
            if (!hm_on && sil[SIL_BIT]) begin
                hm_on <= 1'b1; sil <= 0; hm_i <= 6'd0;
                tsel <= tsel + 2'd1;
                if (tsel == 2'd0) begin hm_t <= 1'b1; tk <= 6'd0; tr <= 3'd0; end
                else begin hm_m <= 1'b1; hm_pc <= pc; hm_run <= run_w; hm_init <= init_done; end
            end
        end
    end
    always @(posedge clk) begin
        if (rst) begin tsh <= 10'h3FF; tbit <= 4'd0; tdiv <= 16'd0; tbusy <= 1'b0; end
        else if (!tbusy) begin
            if (cpu_tx) begin tsh <= {1'b1, wd, 1'b0}; tbit <= 4'd0; tdiv <= 16'd0; tbusy <= 1'b1; end
            else if (hm_go) begin tsh <= {1'b1, hm_c, 1'b0}; tbit <= 4'd0; tdiv <= 16'd0; tbusy <= 1'b1; end
        end else if (tdiv == BAUD_DIV - 1) begin
            tdiv <= 16'd0; tsh <= {1'b1, tsh[9:1]};
            if (tbit == 4'd9) tbusy <= 1'b0; else tbit <= tbit + 4'd1;
        end else tdiv <= tdiv + 16'd1;
    end
    assign uart_tx = tsh[0];

    // ---- measurement
    reg [31:0] lp = 32'd0, ppc = 32'd0, cyc = 32'd0, t0 = 32'd0, tl = 32'd0, tp = 32'd0, tcnt = 32'd0;
    reg [5:0] nit = 6'd0; reg armed = 1'b0; reg [3:0] sh = 4'd9, shl = 4'd9; reg tmo_l = 1'b0, tmo_p = 1'b0; reg [15:0] run = 16'd0;
    reg [7:0] scr [0:3];
    reg [31:0] bm0 = 32'd0, bmt = 32'd0;   // benchmark timer (F0h start, F1h stop)
    assign run_w = run;
    wire hit = armed && (pc == lp) && (ppc != lp);
    always @(posedge clk) begin
        cyc <= cyc + 32'd1; ppc <= pc; soc_rst_req <= 1'b0;
        if (rst) begin armed <= 1'b0; run <= 16'd0; tl <= 32'd0; tp <= 32'd0; tmo_l <= 1'b0; tmo_p <= 1'b0;
                       scr[0] <= 8'd0; scr[1] <= 8'd0; scr[2] <= 8'd0; scr[3] <= 8'd0; end
        else begin
            if (we && a == 8'h91) lp <= {wd, lp[31:8]};
            if (we && a == 8'h92) begin armed <= 1'b1; nit <= 6'd0; tcnt <= 32'd0; sh <= wd[3:0]; end
            if (we && a >= 8'h96 && a <= 8'h99) scr[a[1:0] - 2'd2] <= wd;
            if (we && a == 8'hF0) bm0 <= cyc;
            if (we && a == 8'hF1) bmt <= cyc - bm0;
            if (armed) begin
                tcnt <= tcnt + 32'd1;
                if (hit) begin nit <= nit + 6'd1; if (nit == 6'd4) t0 <= cyc; end
                if ((hit && nit == 6'd36) || tcnt[TMO_BIT]) begin
                    armed <= 1'b0; soc_rst_req <= 1'b1; run <= run + 16'd1;
                    tp <= tl; tl <= tcnt[TMO_BIT] ? 32'hFFFFFFFF : cyc - t0; tmo_p <= tmo_l; tmo_l <= tcnt[TMO_BIT]; shl <= sh;
                end
            end
        end
    end
    // result, pipelined (read long after the run): (tl - tp) * 100 >> shl, saturated
    reg [31:0] dl; reg neg; reg [39:0] m100; reg [15:0] res;
    always @(posedge clk) begin
        dl <= tl - tp; neg <= (tl < tp);
        m100 <= {dl, 6'd0} + {1'b0, dl, 5'd0} + {4'd0, dl, 2'd0};
        if (neg) res <= 16'd0;
        else if (shl == 4'd5) res <= (|m100[39:21]) ? 16'hFFFF : m100[20:5];
        else res <= (|m100[39:25]) ? 16'hFFFF : m100[24:9];
    end
    always @* begin
        case (a)
            8'h90: rd = {7'd0, tbusy | hm_on};     // busy also while a hardware message is being sent
            8'h92: rd = run[7:0];
            8'h9A: rd = run[15:8];
            8'h93: rd = res[7:0];
            8'h94: rd = res[15:8];
            8'h95: rd = {6'd0, neg, tmo_l | tmo_p};
            8'h96, 8'h97, 8'h98, 8'h99: rd = scr[a[1:0] - 2'd2];
            8'hF4: rd = bmt[7:0]; 8'hF5: rd = bmt[15:8]; 8'hF6: rd = bmt[23:16]; 8'hF7: rd = bmt[31:24];
            default: rd = 8'h5A;
        endcase
    end
endmodule
