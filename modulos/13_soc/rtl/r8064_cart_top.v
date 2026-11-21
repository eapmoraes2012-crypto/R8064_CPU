// r8064_cart_top.v - MSX CARTRIDGE top for the V9968_Cartridge board (Tang Nano 20K): clkgen + SoC + embedded SDRAM + slot I/O interface (r8064_slot_if).
// The board connects only A0-A7, D0-D7, /IORQ, /RD, /WR, /RESET, WAIT, INT and DIR/BUSDIR to the FPGA: the R8064 is an MSX I/O peripheral (ports 0Bh/0Ch/0Dh, layer 1 of the protocol:
// FIFOs + state + length). Layer 2 (16 KB window at 8000h-BFFFh) requires /SLTSL, A8-A15 and /MREQ, which the board does NOT have; window accesses are disabled (sb_* = 0).
// Clock: the board's 14.31818 MHz crystal (pin 80) -> rPLL x CPT/4 (SRC = 3). REV52: 42.9545 MHz = 3.579545 x 12 (CPT = 12; macro R8064_CLK57 for the
// previous 57.2727 MHz = x16). The governor scales with CPT (Z80 T-state = CPT clocks, R800 cycle = CPT/2) and the SDRAM refresh with REF_INT.
// SoC reset = PLL + button + slot /RESET (synchronized) + "restart the R8064" command (CMD.b3 of the FIFO), stretched by 16 clocks. Any reset redoes the SDRAM and the boot (BOOT=1).
`ifdef R8064_CLK57
`define R8064_CART_CPT 16
`else
`define R8064_CART_CPT 12
`endif
module r8064_cart_top #(parameter SRC = 3, parameter [3:0] SDR_PSDA = 4'd12, parameter BOOT = 1, parameter CPT = `R8064_CART_CPT)(   // SDR_PSDA 12 = 270 degrees, measured with r8064_sdtest_top at 57.27 MHz
    input  wire        clk27,                 // Tang Nano 27 MHz crystal (pin 4), not used with SRC = 3
    input  wire        clk14m,                // board 14.31818 MHz oscillator (pin 80)
    input  wire        btn_rst,               // KEY1 button (pin 88): pressed = 1
    // slot MSX
    input  wire        slot_reset_n, slot_iorq_n, slot_rd_n, slot_wr_n,
    input  wire [7:0]  slot_a,
    inout  wire [7:0]  slot_d,
    output wire        slot_data_dir, slot_wait, slot_intr, oe_n,
    // observation (free pins on the board)
    output wire        dbg_sig, dbg_hb,
    // embedded SDRAM
    output wire        O_sdram_clk, O_sdram_cke, O_sdram_cs_n, O_sdram_ras_n, O_sdram_cas_n, O_sdram_wen_n,
    output wire [3:0]  O_sdram_dqm,
    output wire [10:0] O_sdram_addr,
    output wire [1:0]  O_sdram_ba,
    inout  wire [31:0] IO_sdram_dq
);
    wire clk_in = (SRC == 0) ? clk27 : clk14m;
    wire clk, clk_sd, locked, rst_pll;
    r8064_clkgen #(.SRC(SRC), .SDR_PSDA(SDR_PSDA), .MUL14(CPT / 4)) u_clk(.clk_in(clk_in), .rst_in(1'b0), .clk(clk), .clk_sdram(clk_sd), .locked(locked), .rst(rst_pll));
    assign oe_n = 1'b0;                       // level converters always enabled

    // resets: button, slot /RESET (2 FF), stretched FIFO pulse
    reg [1:0] bs = 2'b00, rs = 2'b00; reg [4:0] rst_str = 5'd0; wire fifo_rst;
    always @(posedge clk) begin
        bs <= {bs[0], btn_rst}; rs <= {rs[0], ~slot_reset_n};
        if (fifo_rst) rst_str <= 5'd16; else if (rst_str != 5'd0) rst_str <= rst_str - 5'd1;
    end
    wire rst = rst_pll | bs[1] | rs[1] | (rst_str != 5'd0);

    // interface do slot
    wire [7:0] d_o; wire d_oe, fm_we, fm_re; wire [1:0] fm_a; wire [7:0] fm_wd, fm_rd; wire fifo_irq;
    r8064_slot_if u_slot(.clk(clk), .rst(rst), .slot_iorq_n(slot_iorq_n), .slot_rd_n(slot_rd_n), .slot_wr_n(slot_wr_n), .slot_a(slot_a),
        .slot_d_i(slot_d), .slot_d_o(d_o), .slot_d_oe(d_oe), .slot_data_dir(slot_data_dir), .slot_wait(slot_wait), .slot_int(slot_intr),
        .fm_we(fm_we), .fm_re(fm_re), .fm_a(fm_a), .fm_wd(fm_wd), .fm_rd(fm_rd), .irq(fifo_irq));
    assign slot_d = d_oe ? d_o : 8'bz;

    wire io_oe, iox_we, iox_re, nat, cs, z8, ro, mb, dbg_s, gcv, fbi, fbd, mmu_en, mmu_user, i_fault, d_fault, init_done;
    wire [7:0] io_rd, iox_a, iox_wd, sb_rd, dbg_f; wire [63:0] dbg_pc; wire [2:0] ic, dc;
    wire s_cke, s_cs_n, s_ras_n, s_cas_n, s_we_n, s_dq_oe; wire [3:0] s_dqm; wire [1:0] s_ba; wire [10:0] s_a; wire [31:0] s_dq_o;
    r8064_soc #(.BOOT_WORDS(BOOT ? 2048 : 0), .INIT_IMG(BOOT), .CPT(CPT), .REF_INT(25 * CPT)) u_soc(.clk(clk), .rst(rst), .irq(1'b0),   // REF_INT: 400 (57.27 MHz) / 300 (42.95 MHz) = 6.98 us
        .io_we(1'b0), .io_re(1'b0), .io_a(8'd0), .io_wd(8'd0), .io_rd(io_rd), .io_oe(io_oe),
        .io_x_we(iox_we), .io_x_re(iox_re), .io_x_a(iox_a), .io_x_wd(iox_wd), .io_x_rd(8'd0), .port_c(8'd0),
        .fm_we(fm_we), .fm_re(fm_re), .fm_a(fm_a), .fm_wd(fm_wd), .fm_rd(fm_rd),
        .sb_we(1'b0), .sb_re(1'b0), .sb_a(14'd0), .sb_wd(8'd0), .sb_rd(sb_rd),
        .fifo_irq(fifo_irq), .fifo_rst(fifo_rst), .native64(nat), .clk_sel(cs), .is_z80(z8), .is_rom(ro), .mode_busy(mb),
        .dbg_pc(dbg_pc), .dbg_f(dbg_f), .dbg_sig(dbg_s), .gov_cv(gcv), .fl_busy_i(fbi), .fl_busy_d(fbd),
        .mmu_en(mmu_en), .mmu_user(mmu_user), .i_fault(i_fault), .d_fault(d_fault), .i_cause(ic), .d_cause(dc),
        .init_done(init_done), .s_cke(s_cke), .s_cs_n(s_cs_n), .s_ras_n(s_ras_n), .s_cas_n(s_cas_n), .s_we_n(s_we_n),
        .s_dqm(s_dqm), .s_ba(s_ba), .s_a(s_a), .s_dq_o(s_dq_o), .s_dq_oe(s_dq_oe), .s_dq_i(IO_sdram_dq));
    assign O_sdram_clk = clk_sd;
    assign O_sdram_cke = s_cke;   assign O_sdram_cs_n = s_cs_n;  assign O_sdram_ras_n = s_ras_n;
    assign O_sdram_cas_n = s_cas_n; assign O_sdram_wen_n = s_we_n;
    assign O_sdram_dqm = s_dqm;   assign O_sdram_addr = s_a;     assign O_sdram_ba = s_ba;
    assign IO_sdram_dq = s_dq_oe ? s_dq_o : 32'bz;

    reg [24:0] hb = 25'd0; always @(posedge clk) hb <= hb + 25'd1;
    reg sig_r = 1'b0;
    always @(posedge clk) sig_r <= dbg_s ^ i_fault ^ d_fault ^ (^dbg_pc[15:0]) ^ (^dbg_f) ^ io_oe ^ iox_we ^ iox_re ^ nat ^ cs ^ z8 ^ ro ^ mb ^ gcv ^ fbi ^ fbd ^ mmu_en ^ mmu_user ^ (^io_rd) ^ (^sb_rd) ^ (^iox_a) ^ (^iox_wd) ^ (^ic) ^ (^dc) ^ init_done ^ locked;
    assign dbg_sig = sig_r;
    assign dbg_hb  = hb[24];
endmodule
