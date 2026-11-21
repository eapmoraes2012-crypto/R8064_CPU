// r8064_soc.v - integration: MSX system (core+mode+governor+msx_mem+FIFOs) + MMU (I and D TLB) + 4 KB I cache + 8 KB D cache + arbiters + SDRAM controller.
// Instruction path : core i_req/i_paddr -> MMU-I (v_req) -> I cache -> I arbiter (I cache > I walker) -+
//                                                                                                          +-> top arbiter (D > I) -> sdram_ctrl -> pins
// Data path        : core d_req/d_paddr -> MMU-D (v_req) -> D cache -> D arbiter (D cache > D walker) -+
// Each side has an FSM that adapts the core's ack protocol to the cache's req/ready/rvalid protocol (see comments). Translation faults are signaled on
// i_fault/d_fault (+cause); the core receives them as an exception (CR43 cause, CR44 address, CR45 EPC; jumps to CR41); MMU control in the core's CR46-49. With mmu_en=0 the address passes straight through (low 32 bits).
// Physical memory = 8 MB (20-bit 64-bit word index = p_addr[22:3]).
// 4-channel DMA (r8064_dma): registers CR19..CR30 (MTCR), status/IE on ports EDh/EEh/EFh, 5th master of the SDRAM arbiter; 16 KB exchange buffer (r8064_xbuf, MSX window).
// BOOT (BOOT_WORDS > 0): after SDRAM initialization DMA channel 0 copies BOOT_WORDS words from the window buffer (offset 0; initial content = INIT_IMG=1: 8 files
//   <INIT_PFX><lane>.hex) to SDRAM 0; the core stays in reset (boot_busy=1) until the end and the window belongs to the DMA during the copy. BOOT_WORDS=0: no boot (the core starts directly).
module r8064_soc #(parameter FIFO_BASE = 8'hE8, parameter INIT_CYC = 20000, parameter REF_INT = 400, parameter BOOT_WORDS = 0, parameter INIT_IMG = 0,
                   parameter CPT = 16)(   // CPT: clocks per Z80 T-state (16 = 57.27 MHz, 12 = 42.95 MHz); REF_INT must follow the clock (SDRAM refresh <= 7.8 us)
    input  wire        clk, rst, irq,
    // E/S
    input  wire        io_we, io_re, input wire [7:0] io_a, io_wd, output wire [7:0] io_rd, output wire io_oe,
    output wire        io_x_we, io_x_re, output wire [7:0] io_x_a, io_x_wd, input wire [7:0] io_x_rd,
    input  wire [7:0]  port_c,
    input  wire        fm_we, fm_re, input wire [1:0] fm_a, input wire [7:0] fm_wd, output wire [7:0] fm_rd,
    // MSX exchange window (page 2, 16 KB): slot access to the buffer (address A[13:0], synchronized; s_a stable >= 1 clock before sb_re)
    input  wire        sb_we, sb_re, input wire [13:0] sb_a, input wire [7:0] sb_wd, output wire [7:0] sb_rd,
    output wire        fifo_irq, fifo_rst,
    output wire        native64, clk_sel, is_z80, is_rom, mode_busy,
    output wire [63:0] dbg_pc, output wire [7:0] dbg_f, output wire dbg_sig, output wire gov_cv,
    output wire        fl_busy_i, fl_busy_d,     // TLB flush sweep in progress (informational)
    output wire        mmu_en, mmu_user, output wire i_fault, d_fault, output wire [2:0] i_cause, d_cause,   // MMU state / fault pulses (observation)
    // SDRAM
    output wire        init_done,
    output wire        s_cke, s_cs_n, s_ras_n, s_cas_n, s_we_n, output wire [3:0] s_dqm, output wire [1:0] s_ba, output wire [10:0] s_a,
    output wire [31:0] s_dq_o, output wire s_dq_oe, input wire [31:0] s_dq_i
);
    // ---------------- 4-channel DMA (r8064_dma): registers in CR19..CR30, status/IE on ports EDh/EEh/EFh, 5th SDRAM master ----------------
    wire dma_cr_we; wire [3:0] dma_cr_idx; wire [63:0] dma_cr_wd;
    wire dma_pop, dma_push; wire [7:0] dma_wd; wire dma_a_avail, dma_b_space; wire [7:0] dma_a_q;
    wire dma_irq, dma_inv, dma_io_sel; wire [7:0] dma_io_rd;
    wire fifo_win, xb_re, xb_we; wire [10:0] xb_a; wire [63:0] xb_wd, xb_q;
    wire sx_we, sx_re; wire [7:0] sx_a, sx_wd;
    assign io_x_we = sx_we && !dma_io_sel; assign io_x_re = sx_re && !dma_io_sel; assign io_x_a = sx_a; assign io_x_wd = sx_wd;   // the DMA ports do not leave the SoC
    wire x_req, x_we, x_acc, x_done; wire [19:0] x_addr; wire [63:0] x_wd, x_rd; wire [7:0] x_be;
    // boot sequencer: 0 waits init_done | 1 boot_go pulse | 2 waits 1 clock | 3 waits for channel 0 to finish | 4 boot_clr pulse and releases the core
    reg boot_busy; reg [2:0] bst; wire boot_done; wire boot_go = (bst == 3'd1); wire boot_clr = (bst == 3'd4);   // separate declarations (Gowin synthesis: EX3436)
    always @(posedge clk) begin
        if (rst) begin boot_busy <= (BOOT_WORDS != 0); bst <= (BOOT_WORDS != 0) ? 3'd0 : 3'd5; end
        else case (bst)
            3'd0: if (init_done) bst <= 3'd1;
            3'd1: bst <= 3'd2;
            3'd2: bst <= 3'd3;
            3'd3: if (boot_done) bst <= 3'd4;
            3'd4: begin boot_busy <= 1'b0; bst <= 3'd5; end
            default: ;
        endcase
    end
    r8064_dma u_dma(.clk(clk), .rst(rst), .cr_we(dma_cr_we), .cr_idx(dma_cr_idx), .cr_wd(dma_cr_wd),
        .io_we(sx_we), .io_re(sx_re), .io_a(sx_a), .io_wd(sx_wd), .io_rd(dma_io_rd), .io_sel(dma_io_sel),
        .m_req(x_req), .m_we(x_we), .m_addr(x_addr), .m_wd(x_wd), .m_be(x_be), .m_acc(x_acc), .m_done(x_done), .m_rd(x_rd),
        .a_avail(dma_a_avail), .a_q(dma_a_q), .b_space(dma_b_space), .d_pop(dma_pop), .d_push(dma_push), .d_wd(dma_wd),
        .b_ok(!fifo_win || boot_busy), .b_re(xb_re), .b_we(xb_we), .b_a(xb_a), .b_wd(xb_wd), .b_q(xb_q),
        .irq(dma_irq), .inv(dma_inv), .boot_go(boot_go), .boot_cnt(BOOT_WORDS[18:0]), .boot_done(boot_done), .boot_clr(boot_clr));
    r8064_xbuf #(.INIT_IMG(INIT_IMG)) u_xbuf(.clk(clk), .win(fifo_win && !boot_busy), .s_we(sb_we), .s_re(sb_re), .s_a(sb_a), .s_wd(sb_wd), .s_rd(sb_rd),
        .d_re(xb_re), .d_we(xb_we), .d_a(xb_a), .d_wd(xb_wd), .d_q(xb_q));
    // ---------------- MSX system + core ----------------
    wire [7:0] mmu_asid, fl_asid; wire [19:0] mmu_root; wire fl_all, fl_va_en, fl_asid_en, cache_inv; wire [63:0] fl_va;
    wire c_i_req, c_i_ack, c_d_req, c_d_we, c_d_ack; wire [63:0] c_i_pa, c_i_rd, c_d_pa, c_d_wd, c_d_rd; wire [1:0] c_d_sz; wire [7:0] c_d_be; wire hit_i, hit_d, wr_ok;
    // REV47: registered reset of the CPU system (rst | boot_busy goes into the clock-enable of the whole pipeline: was a critical path
    // with long routing). Releases the core 1 clock later.
    reg sys_rst_q; always @(posedge clk) sys_rst_q <= rst | boot_busy;
    r8064_msx_sys #(.FIFO_BASE(FIFO_BASE), .CPT(CPT)) u_sys(.clk(clk), .rst(sys_rst_q), .irq(irq & ~dma_irq),
        .i_req(c_i_req), .i_ack(c_i_ack), .i_paddr(c_i_pa), .i_rdata(c_i_rd),
        .d_req(c_d_req), .d_we(c_d_we), .d_paddr(c_d_pa), .d_size(c_d_sz), .d_wdata(c_d_wd), .d_be(c_d_be), .d_ack(c_d_ack), .d_rdata(c_d_rd),
        .i_hit(hit_i), .d_hit(hit_d), .d_wr_ok(wr_ok),
        .i_flt(i_fault), .d_flt(d_fault), .i_cs(i_cause), .d_cs(d_cause), .cr_mmu_en(mmu_en), .cr_mmu_user(mmu_user), .cr_asid(mmu_asid), .cr_root(mmu_root),
        .cr_fl_all(fl_all), .cr_fl_va_en(fl_va_en), .cr_fl_asid_en(fl_asid_en), .cr_fl_va(fl_va), .cr_fl_asid(fl_asid), .cr_cinv(cache_inv),
        .io_we(io_we), .io_re(io_re), .io_a(io_a), .io_wd(io_wd), .io_rd(io_rd), .io_oe(io_oe),
        .io_x_we(sx_we), .io_x_re(sx_re), .io_x_a(sx_a), .io_x_wd(sx_wd), .io_x_rd(dma_io_sel ? dma_io_rd : io_x_rd), .port_c(port_c),
        .dma_cr_we(dma_cr_we), .dma_cr_idx(dma_cr_idx), .dma_cr_wd(dma_cr_wd), .dma_pop(dma_pop), .dma_push(dma_push), .dma_wd(dma_wd),
        .dma_a_avail(dma_a_avail), .dma_a_q(dma_a_q), .dma_b_space(dma_b_space),
        .fm_we(fm_we), .fm_re(fm_re), .fm_a(fm_a), .fm_wd(fm_wd), .fm_rd(fm_rd), .fifo_irq(fifo_irq), .fifo_rst(fifo_rst), .fifo_win(fifo_win),
        .native64(native64), .clk_sel(clk_sel), .is_z80(is_z80), .is_rom(is_rom), .mode_busy(mode_busy),
        .dbg_pc(dbg_pc), .dbg_f(dbg_f), .dbg_sig(dbg_sig), .gov_cv(gov_cv));

    // ---------------- memory subsystem ----------------
    r8064_memsys #(.INIT_CYC(INIT_CYC), .REF_INT(REF_INT)) u_mem(.clk(clk), .rst(rst),
        .c_i_req(c_i_req), .c_i_ack(c_i_ack), .c_i_pa(c_i_pa), .c_i_rd(c_i_rd),
        .c_d_req(c_d_req), .c_d_we(c_d_we), .c_d_ack(c_d_ack), .c_d_pa(c_d_pa), .c_d_wd(c_d_wd), .c_d_be(c_d_be), .c_d_rd(c_d_rd),
        .mmu_en(mmu_en), .mmu_user(mmu_user), .mmu_asid(mmu_asid), .mmu_root(mmu_root),
        .fl_all(fl_all), .fl_va_en(fl_va_en), .fl_asid_en(fl_asid_en), .fl_va(fl_va), .fl_asid(fl_asid), .fl_busy_i(fl_busy_i), .fl_busy_d(fl_busy_d),
        .cache_inv(cache_inv | dma_inv),
        .x_req(x_req), .x_we(x_we), .x_addr(x_addr), .x_wd(x_wd), .x_be(x_be), .x_acc(x_acc), .x_done(x_done), .x_rd(x_rd), .i_fault(i_fault), .d_fault(d_fault), .i_cause(i_cause), .d_cause(d_cause),
        .init_done(init_done), .s_cke(s_cke), .s_cs_n(s_cs_n), .s_ras_n(s_ras_n), .s_cas_n(s_cas_n), .s_we_n(s_we_n), .s_dqm(s_dqm), .s_ba(s_ba), .s_a(s_a),
        .s_dq_o(s_dq_o), .s_dq_oe(s_dq_oe), .s_dq_i(s_dq_i));
endmodule
