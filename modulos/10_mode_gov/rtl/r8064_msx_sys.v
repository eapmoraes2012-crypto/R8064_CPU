// r8064_msx_sys.v - R8064 MSX system: CPU (core + mode + governor + classifier) + msx_mem (mapper/MegaRAM/A8h) + I/O decoder.
//  I/O:  3D,3E,E4,E5 -> mode registers   | A8,FC-FF,8E -> msx_mem   | the other ports go out through io_x_* (msx_if, VDP, PSG...).
//  Memory: 64-bit i_addr/d_addr; in Z80/R800 modes only [15:0] is used, translated by msx_mem (2 instances: fetch and data, same
//  registers written by the same I/O bus). Address without a hit (ROM/other slots) passes without translation. Native mode: registers always active; 64 KB window only with the MMU off and address < 64 KB (REV41), otherwise the MMU rules.
//  THE SKELETON CORE DOES NOT YET EXECUTE IN/OUT: io_we/io_re/io_a/io_wd come from outside (future core) or from the testbench.
module r8064_msx_sys #(parameter ROM_FILE = "gov_rom.mem", parameter FIFO_BASE = 8'hE8, parameter CPT = 16)(
    input  wire        clk, rst, irq,
    // physical memory (for the cache/SDRAM)
    output wire        i_req, input wire i_ack, output wire [63:0] i_paddr, input wire [63:0] i_rdata,
    output wire        d_req, d_we, output wire [63:0] d_paddr, output wire [1:0] d_size, output wire [63:0] d_wdata, output wire [7:0] d_be,
    input  wire        d_ack, input wire [63:0] d_rdata,
    output wire        i_hit, d_hit, d_wr_ok,
    // I/O bus
    input  wire        io_we, io_re, input wire [7:0] io_a, io_wd, output wire [7:0] io_rd, output wire io_oe,
    output wire        io_x_we, io_x_re, output wire [7:0] io_x_a, io_x_wd, input wire [7:0] io_x_rd,
    input  wire [7:0]  port_c,
    input  wire        i_flt, d_flt, input wire [2:0] i_cs, d_cs,
    output wire        cr_mmu_en, cr_mmu_user, output wire [7:0] cr_asid, output wire [19:0] cr_root,
    output wire        cr_fl_all, cr_fl_va_en, cr_fl_asid_en, output wire [63:0] cr_fl_va, output wire [7:0] cr_fl_asid, output wire cr_cinv,
    // DMA: writes to CR19..CR30 and FIFO device port (DMA modes 1 and 2); fifo_win = ownership of the 16 KB window (1 = MSX)
    output wire        dma_cr_we, output wire [3:0] dma_cr_idx, output wire [63:0] dma_cr_wd,
    input  wire        dma_pop, dma_push, input wire [7:0] dma_wd, output wire dma_a_avail, output wire [7:0] dma_a_q, output wire dma_b_space, output wire fifo_win,
    // MSX side of the FIFOs (slot I/O, already synchronized to clk)
    input  wire        fm_we, fm_re, input wire [1:0] fm_a, input wire [7:0] fm_wd, output wire [7:0] fm_rd,
    output wire        fifo_irq, fifo_rst,
    output wire        native64, clk_sel, is_z80, is_rom, mode_busy,
    output wire [63:0] dbg_pc, output wire [7:0] dbg_f, output wire dbg_sig, output wire gov_cv
);
    wire i_ack_c = i_ack;
    wire [63:0] i_addr, d_addr; wire [7:0] a8, md_rd, mi_rd; wire md_oe, mi_hit_io, md_hit_io;
    // single I/O bus: the core (IN/OUT) has priority over the external io_* ports (used by tests / another master)
    wire cio_we, cio_re; wire [7:0] cio_a, cio_wd;
    wire c_act = cio_we | cio_re;
    wire        b_we = io_we | cio_we, b_re = io_re | cio_re;
    wire [7:0]  b_a  = c_act ? cio_a : io_a;
    wire [7:0]  b_wd = cio_we ? cio_wd : io_wd;
    wire mode_port = (b_a == 8'h3D) || (b_a == 8'h3E) || (b_a == 8'hE4) || (b_a == 8'hE5);
    wire mem_port  = (b_a == 8'hA8) || (b_a[7:2] == 6'b111111) || (b_a == 8'h8E);
    wire fifo_hit;
    wire m_we = b_we && !mode_port, m_re = b_re && !mode_port;   // msx_mem sees only ports that are not mode ports
    // classifier / map: the region registers keep their defaults; map_* not used here (programmable by future firmware)
    wire [7:0] d_be_c; wire d_wblk;   // d_be_c = core byte-enable; d_be goes to zero when the write falls in the MegaRAM in ASCII8 mode (read-only)
    wire [2:0] lane_d = d_be_c[0] ? 3'd0 : d_be_c[1] ? 3'd1 : d_be_c[2] ? 3'd2 : d_be_c[3] ? 3'd3 : d_be_c[4] ? 3'd4 : d_be_c[5] ? 3'd5 : d_be_c[6] ? 3'd6 : 3'd7;
    wire [7:0] lane_wd = d_wdata >> {lane_d, 3'b000};
    r8064_cpu_gov #(.ROM_FILE(ROM_FILE), .CPT(CPT)) u_cpu(.clk(clk), .rst(rst), .irq(irq), .i_req(i_req), .i_ack(i_ack_c), .i_addr(i_addr), .i_rdata(i_rdata),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_size(d_size), .d_wdata(d_wdata), .d_be(d_be_c), .d_ack(d_ack), .d_rdata(d_rdata),
        .i_flt(i_flt), .d_flt(d_flt), .i_cs(i_cs), .d_cs(d_cs), .cr_mmu_en(cr_mmu_en), .cr_mmu_user(cr_mmu_user), .cr_asid(cr_asid), .cr_root(cr_root),
        .cr_fl_all(cr_fl_all), .cr_fl_va_en(cr_fl_va_en), .cr_fl_asid_en(cr_fl_asid_en), .cr_fl_va(cr_fl_va), .cr_fl_asid(cr_fl_asid), .cr_cinv(cr_cinv),
        .dma_cr_we(dma_cr_we), .dma_cr_idx(dma_cr_idx), .dma_cr_wd(dma_cr_wd),
        .io_we(b_we && mode_port), .io_re(b_re && mode_port), .io_a(b_a), .io_wd(b_wd), .io_rd(md_rd), .io_oe(md_oe), .port_c(port_c),
        .cio_we(cio_we), .cio_re(cio_re), .cio_a(cio_a), .cio_wd(cio_wd), .cio_rd(io_rd),
        .a8(a8), .map_we(1'b0), .map_idx(4'd0), .map_val(2'd0),
        .native64(native64), .clk_sel(clk_sel), .is_z80(is_z80), .is_rom(is_rom), .mode_busy(mode_busy),
        .dbg_pc(dbg_pc), .dbg_f(dbg_f), .dbg_sig(dbg_sig), .gov_cv(gov_cv));
    // Mapper and MegaRAM work in ALL modes. Registers (A8h, FCh-FFh, 8Eh) and ports always active. The 64 KB window (translation of the
    // 16-bit address) applies in Z80/R800 modes and, in native mode, with the MMU off and address < 64 KB; with the MMU on, the MMU rules.
    wire en_mm = 1'b1;
    wire i_win = !native64 || (!cr_mmu_en && (i_addr[63:16] == 48'd0));
    wire d_win = !native64 || (!cr_mmu_en && (d_addr[63:16] == 48'd0));
    wire i_hit_r, d_hit_r;
    wire [23:0] i_ph, d_ph; wire i_wr_ok_unused;
    msx_mem #(.MAP_BITS(8), .MEGA_BITS(8), .MEGA_BASE(24'h400000)) u_mmi(.clk(clk), .rst(rst), .en(en_mm), .io_wr(m_we), .io_rd(m_re), .io_addr(b_a), .io_wdata(b_wd), .io_rdata(mi_rd), .io_hit(mi_hit_io),
        .mem_rd(i_req && i_win), .mem_wr(1'b0), .mem_addr(i_addr[15:0]), .mem_wdata(8'd0), .hit(i_hit_r), .phys_addr(i_ph), .a8_o(a8), .wr_ok(i_wr_ok_unused));
    wire [7:0] dummy_rd; wire dummy_io_hit; wire [7:0] a8_d;
    msx_mem #(.MAP_BITS(8), .MEGA_BITS(8), .MEGA_BASE(24'h400000)) u_mmd(.clk(clk), .rst(rst), .en(en_mm), .io_wr(m_we), .io_rd(m_re), .io_addr(b_a), .io_wdata(b_wd), .io_rdata(dummy_rd), .io_hit(dummy_io_hit),
        .mem_rd(d_req && !d_we && d_win), .mem_wr(d_req && d_we && d_win), .mem_addr({d_addr[15:3], lane_d}), .mem_wdata(lane_wd), .hit(d_hit_r), .phys_addr(d_ph), .a8_o(a8_d), .wr_ok(d_wr_ok));
    // physical address: native = no translation; classic with hit = translated; without hit = original 16-bit address
    assign i_hit = i_hit_r && i_win; assign d_hit = d_hit_r && d_win;
    assign i_paddr = i_hit ? {40'd0, i_ph} : native64 ? i_addr : {48'd0, i_addr[15:0]};
    assign d_paddr = d_hit ? {40'd0, d_ph} : native64 ? d_addr : {48'd0, d_addr[15:0]};
    assign d_wblk = d_we && d_hit && !d_wr_ok;
    assign d_be   = d_wblk ? 8'h00 : d_be_c;
    // E/S
    assign io_x_a = b_a; assign io_x_wd = b_wd;
    assign io_x_we = b_we && !mode_port && !mem_port && !fifo_hit;
    assign io_x_re = b_re && !mode_port && !mem_port && !fifo_hit;
    assign io_oe = io_re;                             // the system always answers the read (external ports via io_x_rd)
    wire [7:0] ff_rd;
    r8064_fifo_if #(.BASE(FIFO_BASE)) u_fifo(.clk(clk), .rst(rst),
        .r_we(b_we && !mode_port && !mem_port), .r_re(b_re && !mode_port && !mem_port), .r_a(b_a), .r_wd(b_wd), .r_rd(ff_rd), .r_hit(fifo_hit),
        .m_we(fm_we), .m_re(fm_re), .m_a(fm_a), .m_wd(fm_wd), .m_rd(fm_rd), .m_irq(fifo_irq), .r8064_rst(fifo_rst), .win(fifo_win),
        .d_pop(dma_pop), .d_push(dma_push), .d_wd(dma_wd), .a_avail(dma_a_avail), .a_q(dma_a_q), .b_space(dma_b_space));
    assign io_rd = md_oe ? md_rd : mi_hit_io ? mi_rd : fifo_hit ? ff_rd : io_x_rd;
endmodule
