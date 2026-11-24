// r8064_cpu_gov.v - wrapper: core + mode register + timing governor + memory classifier.
module r8064_cpu_gov #(parameter ROM_FILE = "gov_rom.mem", parameter CPT = 16)(   // CPT: pipeline clocks per Z80 T-state (16 = 57.27 MHz, 12 = 42.95 MHz)
    input  wire        clk, rst, irq,
    output wire        i_req, input wire i_ack, output wire [63:0] i_addr, input wire [63:0] i_rdata,
    output wire        d_req, d_we, output wire [63:0] d_addr, output wire [1:0] d_size, output wire [63:0] d_wdata, output wire [7:0] d_be,
    input  wire        d_ack, input wire [63:0] d_rdata,
    input  wire        io_we, io_re, input wire [7:0] io_a, io_wd, output wire [7:0] io_rd, output wire io_oe,
    input  wire [7:0]  port_c,
    input  wire        i_flt, d_flt, input wire [2:0] i_cs, d_cs,
    output wire        cr_mmu_en, cr_mmu_user, output wire [7:0] cr_asid, output wire [19:0] cr_root,
    output wire        cr_fl_all, cr_fl_va_en, cr_fl_asid_en, output wire [63:0] cr_fl_va, output wire [7:0] cr_fl_asid, output wire cr_cinv,
    output wire        dma_cr_we, output wire [3:0] dma_cr_idx, output wire [63:0] dma_cr_wd,
    output wire        cio_we, cio_re, output wire [7:0] cio_a, cio_wd, input wire [7:0] cio_rd,   // I/O issued by the core (IN/OUT)
    input  wire [7:0]  a8,                       // primary slot (PPI A8H) coming from the MSX memory system
    input  wire        map_we, input wire [3:0] map_idx, input wire [1:0] map_val,   // region table (0 RAM, 1 ROM, 2 external)
    output wire        native64, clk_sel, is_z80, is_rom, mode_busy,
    output wire [63:0] dbg_pc, output wire [7:0] dbg_f, output wire dbg_sig, output wire gov_cv,
    input  wire        smc_miss, output wire smc_done   // REV56 (see r8064_core_min)
);
    wire go, alt_ev, bnd, ph, add_ev, d_ev, f_romw, dwe; wire [2:0] pg; wire [7:0] op, prt; wire [12:0] rem;
    wire [15:0] fpc, daddr; wire [3:0] flen, fx; wire [1:0] dsz; wire [4:0] add_n;
    r8064_mode u_mode(.clk(clk), .rst(rst), .io_we(io_we), .io_re(io_re), .io_a(io_a), .io_wd(io_wd), .io_rd(io_rd), .io_oe(io_oe),
        .boundary(bnd), .native64(native64), .clk_sel(clk_sel), .is_z80(is_z80), .is_rom(is_rom), .busy(mode_busy), .s1990_idx(), .s1990_other_we());
    mem_class u_mc(.clk(clk), .rst(rst), .active(!native64 && !is_z80), .is_rom(is_rom), .phase(ph), .a8(a8), .map_we(map_we), .map_idx(map_idx), .map_val(map_val),
        .f_pc(fpc), .f_len(flen), .f_xcyc(fx), .f_romw(f_romw), .d_ev(d_ev), .d_addr(daddr), .d_size(dsz), .d_we(dwe), .add_ev(add_ev), .add_n(add_n));
    timing_gov #(.ROM_FILE(ROM_FILE), .CPT(CPT)) u_gov(.clk(clk), .rst(rst), .native64(native64), .is_z80(is_z80), .is_rom(is_rom), .clk_sel(clk_sel),
        .c_page(pg), .c_op(op), .c_port(prt), .c_xcyc(fx), .c_romw(f_romw), .add_ev(add_ev), .add_n(add_n), .phase(ph),
        .cv(gov_cv), .alt_ev(alt_ev), .go(go), .dbg_rem(rem));
    r8064_core_min u_core(.clk(clk), .rst(rst), .irq(irq), .i_req(i_req), .i_addr(i_addr), .i_ack(i_ack), .i_rdata(i_rdata),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_size(d_size), .d_wdata(d_wdata), .d_be(d_be), .d_ack(d_ack), .d_rdata(d_rdata),
        .i_flt(i_flt), .d_flt(d_flt), .i_cs(i_cs), .d_cs(d_cs), .cr_mmu_en(cr_mmu_en), .cr_mmu_user(cr_mmu_user), .cr_asid(cr_asid), .cr_root(cr_root),
        .cr_fl_all(cr_fl_all), .cr_fl_va_en(cr_fl_va_en), .cr_fl_asid_en(cr_fl_asid_en), .cr_fl_va(cr_fl_va), .cr_fl_asid(cr_fl_asid), .cr_cinv(cr_cinv),
        .dma_cr_we(dma_cr_we), .dma_cr_idx(dma_cr_idx), .dma_cr_wd(dma_cr_wd),
        .dbg_pc(dbg_pc), .dbg_f(dbg_f), .dbg_sig(dbg_sig), .gov_go(go), .gov_wait(!native64), .smc_miss(smc_miss), .smc_done(smc_done), .port_c(port_c), .gov_page(pg), .gov_op(op), .gov_port(prt),
        .gov_cv(gov_cv), .gov_alt_ev(alt_ev), .gov_boundary(bnd), .gov_pc(fpc), .gov_len(flen), .gov_dev(d_ev), .gov_daddr(daddr), .gov_dsize(dsz), .gov_dwe(dwe), .io_we(cio_we), .io_re(cio_re), .io_a(cio_a), .io_wd(cio_wd), .io_rdata(cio_rd));
endmodule
