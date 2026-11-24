// aud_opl3_if.v - bus driver for one external YMF262 (OPL3): write FIFO and pacing.
// Requests: wq_we with {bank, reg, data} (wq_full stops the writer). Each write is: address (A0 = 0, A1 = bank, D = reg),
// wait 32 fM periods, data (A0 = 1, A1 = bank), wait 32 fM periods (YMF262 datasheet minimums). /WR and /CS are held low for
// WPW system clocks with address and data stable one clock before and after. /IC is held low for 512 fM periods after reset;
// then the INIT list is written first (INIT_NEW = 1: 105h = 01h, NEW mode; 104h = 00h; 0BDh = C0h).
// The bus is output only (/RD is tied high): status reads of the emulated chips are answered by the FPGA.
module aud_opl3_if #(parameter CPOM = 4, parameter WPW = 8, parameter INIT_NEW = 1)(
    input  wire clk, rst, ce_fm,
    input  wire wq_we, input wire [16:0] wq_d, output wire wq_full, output wire wq_empty,
    output reg  [1:0] opl_a, output reg [7:0] opl_d, output reg opl_cs_n, opl_wr_n, output wire opl_rd_n, output reg opl_ic_n
);
    assign opl_rd_n = 1'b1;
    // FIFO 512 x 17
    reg [16:0] fq [0:511]; reg [8:0] wp, rp; reg [9:0] cnt;
    assign wq_full = (cnt >= 10'd508); assign wq_empty = (cnt == 0);
    reg pop; reg [16:0] cur;
    always @(posedge clk) begin
        if (rst) begin wp <= 0; rp <= 0; cnt <= 0; end
        else begin
            if (wq_we && cnt != 10'd512) begin fq[wp] <= wq_d; wp <= wp + 9'd1; end
            if (pop) rp <= rp + 9'd1;
            cnt <= cnt + ((wq_we && cnt != 10'd512) ? 10'd1 : 10'd0) - (pop ? 10'd1 : 10'd0);
        end
    end
    // init list
    function [16:0] init_w(input [1:0] k);
        case (k) 2'd0: init_w = {1'b1, 8'h05, 8'h01}; 2'd1: init_w = {1'b1, 8'h04, 8'h00}; default: init_w = {1'b0, 8'hBD, 8'hC0}; endcase
    endfunction
    localparam S_RST = 0, S_INIT = 1, S_IDLE = 2, S_AS = 3, S_AW = 4, S_AH = 5, S_W1 = 6, S_DS = 7, S_DW = 8, S_DH = 9, S_W2 = 10;
    reg [3:0] s; reg [9:0] fmc; reg [4:0] wc; reg [1:0] ik; reg from_init;
    always @(posedge clk) begin
        pop <= 1'b0;
        if (rst) begin s <= S_RST; fmc <= 0; opl_ic_n <= 1'b0; opl_cs_n <= 1'b1; opl_wr_n <= 1'b1; opl_a <= 0; opl_d <= 0; ik <= 0; end
        else case (s)
            S_RST:  if (ce_fm) begin if (fmc == 10'd511) begin opl_ic_n <= 1'b1; fmc <= 0; s <= S_INIT; end else fmc <= fmc + 10'd1; end
            S_INIT: if (ce_fm) begin if (fmc == 10'd63) begin fmc <= 0; if (INIT_NEW) begin cur <= init_w(0); ik <= 1; from_init <= 1; s <= S_AS; end else s <= S_IDLE; end else fmc <= fmc + 10'd1; end
            S_IDLE: if (cnt != 0 && !pop) begin cur <= fq[rp]; pop <= 1'b1; from_init <= 0; s <= S_AS; end
            S_AS:   begin opl_a <= {cur[16], 1'b0}; opl_d <= cur[15:8]; wc <= 0; s <= S_AW; end
            S_AW:   begin opl_cs_n <= 1'b0; opl_wr_n <= 1'b0; if (wc == WPW - 1) begin wc <= 0; s <= S_AH; end else wc <= wc + 5'd1; end
            S_AH:   begin opl_cs_n <= 1'b1; opl_wr_n <= 1'b1; fmc <= 0; s <= S_W1; end
            S_W1:   if (ce_fm) begin if (fmc == 10'd33) begin fmc <= 0; s <= S_DS; end else fmc <= fmc + 10'd1; end
            S_DS:   begin opl_a <= {cur[16], 1'b1}; opl_d <= cur[7:0]; wc <= 0; s <= S_DW; end
            S_DW:   begin opl_cs_n <= 1'b0; opl_wr_n <= 1'b0; if (wc == WPW - 1) begin wc <= 0; s <= S_DH; end else wc <= wc + 5'd1; end
            S_DH:   begin opl_cs_n <= 1'b1; opl_wr_n <= 1'b1; fmc <= 0; s <= S_W2; end
            S_W2:   if (ce_fm) begin
                        if (fmc == 10'd33) begin
                            fmc <= 0;
                            if (from_init && ik != 2'd3) begin cur <= init_w(ik); ik <= ik + 2'd1; s <= S_AS; end
                            else s <= S_IDLE;
                        end else fmc <= fmc + 10'd1;
                    end
            default: s <= S_IDLE;
        endcase
    end
endmodule
