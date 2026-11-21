// r8064_clkgen.v - system clock generator (target 57.2727 MHz = 3.579545 MHz x 16) for the Tang Nano 20K (GW2AR-18).
// Sources (parameter SRC, chosen at synthesis):
//   SRC=0  clk_in = board crystal, 27 MHz        -> rPLL 27 x 17 / 8       = 57.375 MHz   (error +0.18 %; exact ratio 70/33 infeasible: PFD < 3 MHz)
//   SRC=1  clk_in = 3.579545 MHz (external crystal/oscillator or MSX slot CLOCK) -> rPLL x 16 = 57.2727 MHz (exact, synchronous with the MSX)
//   SRC=2  clk_in = 57.2727 MHz active oscillator directly (no PLL; locked = 1; clk_sdram = clk)
//   SRC=3  clk_in = 14.31818 MHz (4 x 3.579545; e.g.: clk14m pin of the cartridge board) -> rPLL x MUL14: 4 = 57.2727 MHz, 3 = 42.9545 MHz (exact)
// A "bare" 3.579545 MHz crystal needs an external oscillator (e.g. Pierce with 74HC04, or an oscillator module); the FPGA receives the already-square wave on clk_in.
// VCO (SRC=0): 27/8*17*16 = 918 MHz ; (SRC=1): 3.579545*16*16 = 916.4 MHz - both within the GW2A's 500-1250 MHz.
// rst: active high; stays at 1 until the PLL locks + 16 cycles of the generated clock (synchronous release).
// Simulation (-DSIM): behavioral model that measures the period of clk_in and generates clk = clk_in * MUL / DIV.
module r8064_clkgen #(parameter SRC = 1, parameter [3:0] SDR_PSDA = 4'd4, parameter MUL14 = 4)(   // SDR_PSDA: phase of clk_sdram in 22.5-degree steps (4 = 90 degrees); adjust in hardware
    input  wire clk_in,
    input  wire rst_in,      // external asynchronous reset (active high), optional (0 if unused)
    output wire clk,
    output wire clk_sdram,   // clock sent to the SDRAM (O_sdram_clk): CLKOUTP do PLL with SDR_PSDA phase shift
    output wire locked,
    output wire rst
);
    wire pll_lock, pll_clk, pll_clkp;
    generate
    if (SRC == 2) begin : g_direct
        assign pll_clk  = clk_in;
        assign pll_clkp = clk_in;
        assign pll_lock = 1'b1;
    end else begin : g_pll
`ifdef SIM
        localparam MUL = (SRC == 0) ? 17 : (SRC == 3) ? MUL14 : 16;
        localparam DIV = (SRC == 0) ? 8  : 1;
        real per, half, t_last; integer n; reg ck, lk;
        initial begin ck = 0; lk = 0; n = 0; t_last = 0; per = 0; half = 1; end
        always @(posedge clk_in) begin
            if (n >= 1) per = $realtime - t_last;
            t_last = $realtime;
            if (n < 20) n = n + 1;
            if (n == 20) begin lk <= 1'b1; half = per * DIV / (2.0 * MUL); end
        end
        always begin #(half) if (n == 20) ck = ~ck; end
        assign pll_clk = ck; assign pll_lock = lk;
        reg ckp = 1'b0;
        always @(ck) ckp <= #(half * SDR_PSDA / 8.0) ck;   // phase shift = SDR_PSDA/16 of the period
        assign pll_clkp = ckp;
`else
        // IDIV_SEL = IDIV-1 ; FBDIV_SEL = FBDIV-1 ; fout = fin*FBDIV/IDIV ; VCO = fout*ODIV
        // PSDA_SEL as a literal string (Gowin synthesis does not accept the string built by arithmetic: EX0205 -> "0000")
        localparam [4*8-1:0] SDR_PSDA_S = (SDR_PSDA == 4'd0) ? "0000" : (SDR_PSDA == 4'd1) ? "0001" : (SDR_PSDA == 4'd2) ? "0010" : (SDR_PSDA == 4'd3) ? "0011" : (SDR_PSDA == 4'd4) ? "0100" : (SDR_PSDA == 4'd5) ? "0101" : (SDR_PSDA == 4'd6) ? "0110" : (SDR_PSDA == 4'd7) ? "0111" : (SDR_PSDA == 4'd8) ? "1000" : (SDR_PSDA == 4'd9) ? "1001" : (SDR_PSDA == 4'd10) ? "1010" : (SDR_PSDA == 4'd11) ? "1011" : (SDR_PSDA == 4'd12) ? "1100" : (SDR_PSDA == 4'd13) ? "1101" : (SDR_PSDA == 4'd14) ? "1110" : "1111";
        rPLL #(
            .FCLKIN       ((SRC == 0) ? "27" : (SRC == 3) ? "14.31818" : "3.579545"),
            .DEVICE       ("GW2AR-18C"),
            .IDIV_SEL     ((SRC == 0) ? 7  : 0),
            .FBDIV_SEL    ((SRC == 0) ? 16 : (SRC == 3) ? (MUL14 - 1) : 15),   // VCO = fout x 16: 916 MHz (x4) / 687 MHz (x3), within 500-1250 MHz
            .ODIV_SEL     (16),
            .DYN_IDIV_SEL ("false"), .DYN_FBDIV_SEL ("false"), .DYN_ODIV_SEL ("false"),
            .PSDA_SEL     (SDR_PSDA_S), .DYN_DA_EN ("false"), .DUTYDA_SEL ("1000"),
            .CLKOUT_FT_DIR(1'b1), .CLKOUTP_FT_DIR(1'b1), .CLKOUT_DLY_STEP(0), .CLKOUTP_DLY_STEP(0),
            .CLKFB_SEL    ("internal"), .CLKOUT_BYPASS("false"), .CLKOUTP_BYPASS("false"), .CLKOUTD_BYPASS("false"),
            .DYN_SDIV_SEL (2), .CLKOUTD_SRC("CLKOUT"), .CLKOUTD3_SRC("CLKOUT")
        ) u_pll (
            .CLKOUT(pll_clk), .LOCK(pll_lock), .CLKOUTP(pll_clkp), .CLKOUTD(), .CLKOUTD3(),
            .RESET(rst_in), .RESET_P(1'b0), .CLKIN(clk_in), .CLKFB(1'b0),
            .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0), .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0));
`endif
    end
    endgenerate

    assign clk    = pll_clk;
    assign clk_sdram = pll_clkp;
    assign locked = pll_lock;
    // synchronous reset release: only leaves reset 16 cycles after lock
    reg [4:0] cnt = 5'd0; reg rst_r = 1'b1;
    always @(posedge pll_clk or negedge pll_lock) begin
        if (!pll_lock) begin cnt <= 5'd0; rst_r <= 1'b1; end
        else begin
            if (!cnt[4]) cnt <= cnt + 5'd1;
            rst_r <= !cnt[4];
        end
    end
    assign rst = rst_r;
endmodule
