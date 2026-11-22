// r8064_sdtest_top.v - SDRAM PHASE TEST for the bare Tang Nano 20K (no CPU): the same sdram_ctrl as the SoC, the same 57.375 MHz clock,
// and the SDRAM clock (rPLL CLKOUTP) swept over the 16 phase steps (22.5 degrees each) with the rPLL dynamic phase input.
// For each phase: reset the controller (SDRAM init), write 8192 64-bit words with a pattern, read them back and count the wrong words.
// UART (pin 69, 115200 8N1), one line per phase:   "P=4 ERR=0000 BAD=00000 GOT=xxxxxxxxxxxxxxxx EXP=xxxxxxxxxxxxxxxx"
//   (BAD/GOT/EXP: the first wrong word). The sweep repeats forever. LEDs (active low): 0 = PLL locked, 1 = blink, 2..5 = phase.
// REV53b: -DR8064_SDT27 runs the same sweep at 27 MHz (rPLL x1, ODIV 32), the REV53 bench clock (one phase step = 2.31 ns).
`ifdef R8064_SDT27
`define SDT_IDIV 0
`define SDT_FBDIV 0
`define SDT_ODIV 32
`define SDT_BAUD 9'd233
`define SDT_REF 200
`else
`define SDT_IDIV 7
`define SDT_FBDIV 16
`define SDT_ODIV 16
`define SDT_BAUD 9'd497
`define SDT_REF 400
`endif
module r8064_sdtest_top (
    input  wire        clk27,
    input  wire        btn_rst,
    output wire        uart_tx,
    input  wire        uart_rx,
    output wire [5:0]  led,
    output wire        O_sdram_clk, O_sdram_cke, O_sdram_cs_n, O_sdram_ras_n, O_sdram_cas_n, O_sdram_wen_n,
    output wire [3:0]  O_sdram_dqm,
    output wire [10:0] O_sdram_addr,
    output wire [1:0]  O_sdram_ba,
    inout  wire [31:0] IO_sdram_dq
);
    reg [3:0] psda = 4'd0;
    wire clk, clkp, lock;
`ifdef SIM
    reg ck = 0; always #8.7 ck = ~ck; assign clk = ck; assign clkp = ck; assign lock = 1'b1;
`else
    rPLL #(
        .FCLKIN("27"), .DEVICE("GW2AR-18C"), .IDIV_SEL(`SDT_IDIV), .FBDIV_SEL(`SDT_FBDIV), .ODIV_SEL(`SDT_ODIV),
        .DYN_IDIV_SEL("false"), .DYN_FBDIV_SEL("false"), .DYN_ODIV_SEL("false"),
        .PSDA_SEL("0000"), .DYN_DA_EN("true"), .DUTYDA_SEL("1000"),
        .CLKOUT_FT_DIR(1'b1), .CLKOUTP_FT_DIR(1'b1), .CLKOUT_DLY_STEP(0), .CLKOUTP_DLY_STEP(0),
        .CLKFB_SEL("internal"), .CLKOUT_BYPASS("false"), .CLKOUTP_BYPASS("false"), .CLKOUTD_BYPASS("false"),
        .DYN_SDIV_SEL(2), .CLKOUTD_SRC("CLKOUT"), .CLKOUTD3_SRC("CLKOUT")
    ) u_pll (
        .CLKOUT(clk), .LOCK(lock), .CLKOUTP(clkp), .CLKOUTD(), .CLKOUTD3(),
        .RESET(1'b0), .RESET_P(1'b0), .CLKIN(clk27), .CLKFB(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0), .PSDA(psda), .DUTYDA(4'b1000), .FDLY(4'b0));
`endif
    reg [7:0] rcnt = 8'd0; wire rst = !rcnt[7];
    always @(posedge clk) if (!lock) rcnt <= 8'd0; else if (!rcnt[7]) rcnt <= rcnt + 8'd1;

    // ---- controller under test
    reg  c_rst = 1'b1, req = 1'b0, we = 1'b0; reg [19:0] addr = 20'd0; reg [63:0] wdata = 64'd0;
    wire ready, rvalid, wdone, init_done; wire [63:0] rdata;
    wire s_dq_oe; wire [31:0] s_dq_o;
    sdram_ctrl #(.INIT_CYC(20000), .REF_INT(`SDT_REF)) u_sd(.clk(clk), .rst(c_rst), .req(req), .we(we), .addr(addr), .wdata(wdata), .be(8'hFF),
        .ready(ready), .rvalid(rvalid), .rdata(rdata), .wdone(wdone), .init_done(init_done),
        .s_cke(O_sdram_cke), .s_cs_n(O_sdram_cs_n), .s_ras_n(O_sdram_ras_n), .s_cas_n(O_sdram_cas_n), .s_we_n(O_sdram_wen_n),
        .s_dqm(O_sdram_dqm), .s_ba(O_sdram_ba), .s_a(O_sdram_addr), .s_dq_o(s_dq_o), .s_dq_oe(s_dq_oe), .s_dq_i(IO_sdram_dq));
    assign IO_sdram_dq = s_dq_oe ? s_dq_o : 32'bz;
    assign O_sdram_clk = clkp;
    // pattern: different in every bit and every word (address spread over the rows and banks)
    localparam NW = 14'd8191;
    function [63:0] pat(input [12:0] a);
        pat = {~{a, 3'b101, a[12:0], 3'b010}, {a[7:0], a[12:0], 11'h4A5} ^ 32'hC3A55A3C};
    endfunction
    wire [19:0] amap = {addr[12:0], 7'd0} ^ {7'd0, addr[12:0]};   // spread: rows, banks and columns change

    // ---- UART TX
    reg [9:0] tsh = 10'h3FF; reg [3:0] tbit = 4'd0; reg [8:0] tdiv = 9'd0; reg tbusy = 1'b0; reg tgo = 1'b0; reg [7:0] tch = 8'd0;
    always @(posedge clk) begin
        if (!tbusy) begin if (tgo) begin tsh <= {1'b1, tch, 1'b0}; tbit <= 4'd0; tdiv <= 9'd0; tbusy <= 1'b1; end end
        else if (tdiv == `SDT_BAUD) begin tdiv <= 9'd0; tsh <= {1'b1, tsh[9:1]}; if (tbit == 4'd9) tbusy <= 1'b0; else tbit <= tbit + 4'd1; end
        else tdiv <= tdiv + 9'd1;
    end
    assign uart_tx = tsh[0];

    // ---- test sequencer
    localparam S_PH = 0, S_WAITPLL = 1, S_RST = 2, S_INIT = 3, S_WR = 4, S_WRW = 5, S_RD = 6, S_RDW = 7, S_PRINT = 8, S_GAP = 9;
    reg [3:0] st = S_PH; reg [23:0] tmr = 24'd0; reg [15:0] errs = 16'd0; reg [19:0] bad_a = 20'd0; reg [63:0] bad_g = 64'd0, bad_e = 64'd0; reg seen = 1'b0;
    reg [6:0] pi = 7'd0;   // character index of the line
    function [7:0] hx(input [3:0] v); hx = (v < 4'd10) ? 8'h30 + v : 8'h37 + v; endfunction
    reg [7:0] lc;
    always @* begin
        case (pi)
            0: lc = "P"; 1: lc = "="; 2: lc = hx(psda); 3: lc = " "; 4: lc = "E"; 5: lc = "R"; 6: lc = "R"; 7: lc = "=";
            8: lc = hx(errs[15:12]); 9: lc = hx(errs[11:8]); 10: lc = hx(errs[7:4]); 11: lc = hx(errs[3:0]);
            12: lc = " "; 13: lc = "B"; 14: lc = "A"; 15: lc = "D"; 16: lc = "=";
            17: lc = hx(bad_a[19:16]); 18: lc = hx(bad_a[15:12]); 19: lc = hx(bad_a[11:8]); 20: lc = hx(bad_a[7:4]); 21: lc = hx(bad_a[3:0]);
            22: lc = " "; 23: lc = "G"; 24: lc = "O"; 25: lc = "T"; 26: lc = "=";
            27: lc = hx(bad_g[63:60]); 28: lc = hx(bad_g[59:56]); 29: lc = hx(bad_g[55:52]); 30: lc = hx(bad_g[51:48]);
            31: lc = hx(bad_g[47:44]); 32: lc = hx(bad_g[43:40]); 33: lc = hx(bad_g[39:36]); 34: lc = hx(bad_g[35:32]);
            35: lc = hx(bad_g[31:28]); 36: lc = hx(bad_g[27:24]); 37: lc = hx(bad_g[23:20]); 38: lc = hx(bad_g[19:16]);
            39: lc = hx(bad_g[15:12]); 40: lc = hx(bad_g[11:8]); 41: lc = hx(bad_g[7:4]); 42: lc = hx(bad_g[3:0]);
            43: lc = " "; 44: lc = "E"; 45: lc = "X"; 46: lc = "P"; 47: lc = "=";
            48: lc = hx(bad_e[63:60]); 49: lc = hx(bad_e[59:56]); 50: lc = hx(bad_e[55:52]); 51: lc = hx(bad_e[51:48]);
            52: lc = hx(bad_e[47:44]); 53: lc = hx(bad_e[43:40]); 54: lc = hx(bad_e[39:36]); 55: lc = hx(bad_e[35:32]);
            56: lc = hx(bad_e[31:28]); 57: lc = hx(bad_e[27:24]); 58: lc = hx(bad_e[23:20]); 59: lc = hx(bad_e[19:16]);
            60: lc = hx(bad_e[15:12]); 61: lc = hx(bad_e[11:8]); 62: lc = hx(bad_e[7:4]); 63: lc = hx(bad_e[3:0]);
            64: lc = 8'h0D; 65: lc = 8'h0A; default: lc = 8'h00;
        endcase
    end
    reg [12:0] wa = 13'd0;    // word index
    always @(posedge clk) begin
        tgo <= 1'b0;
        if (rst) begin st <= S_PH; psda <= 4'd0; c_rst <= 1'b1; req <= 1'b0; end
        else case (st)
            S_PH:      begin tmr <= 24'd0; c_rst <= 1'b1; st <= S_WAITPLL; end
            S_WAITPLL: begin tmr <= tmr + 24'd1; if (tmr[16]) begin tmr <= 24'd0; st <= S_RST; end end   // 1.1 ms after the phase change
            S_RST:     begin tmr <= tmr + 24'd1; if (tmr[4]) begin c_rst <= 1'b0; st <= S_INIT; end end
            S_INIT:    if (init_done) begin wa <= 13'd0; errs <= 16'd0; seen <= 1'b0; bad_a <= 20'd0; bad_g <= 64'd0; bad_e <= 64'd0; st <= S_WR; end
            S_WR:      if (ready && !req) begin req <= 1'b1; we <= 1'b1; addr <= {7'd0, wa}; wdata <= pat(wa); st <= S_WRW; end
            S_WRW:     begin if (req && ready) req <= 1'b0;
                             if (wdone) begin if (wa == NW[12:0]) begin wa <= 13'd0; st <= S_RD; end else begin wa <= wa + 13'd1; st <= S_WR; end end end
            S_RD:      if (ready && !req) begin req <= 1'b1; we <= 1'b0; addr <= {7'd0, wa}; st <= S_RDW; end
            S_RDW:     begin if (req && ready) req <= 1'b0;
                             if (rvalid) begin
                                 if (rdata != pat(wa)) begin
                                     if (errs != 16'hFFFF) errs <= errs + 16'd1;
                                     if (!seen) begin seen <= 1'b1; bad_a <= {7'd0, wa}; bad_g <= rdata; bad_e <= pat(wa); end
                                 end
                                 if (wa == NW[12:0]) begin pi <= 7'd0; st <= S_PRINT; end else begin wa <= wa + 13'd1; st <= S_RD; end
                             end end
            S_PRINT:   if (!tbusy && !tgo) begin
                           if (lc == 8'h00) begin tmr <= 24'd0; st <= S_GAP; end
                           else begin tch <= lc; tgo <= 1'b1; pi <= pi + 7'd1; end
                       end
            S_GAP:     begin tmr <= tmr + 24'd1; if (tmr[22]) begin psda <= psda + 4'd1; st <= S_PH; end end      // 0.15 s between phases
            default:   st <= S_PH;
        endcase
    end
    reg [24:0] hb = 25'd0; always @(posedge clk) hb <= hb + 25'd1;
    assign led = ~{psda, hb[24], lock};
endmodule
