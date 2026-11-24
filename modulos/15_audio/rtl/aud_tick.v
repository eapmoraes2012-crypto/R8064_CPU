// aud_tick.v - audio time base. All audio runs in the system clock domain with clock enables derived from the
// OPL3 master clock fM = 14.31818 MHz = clk / CPOM (CPOM = 4 at 57.27 MHz, 6 at 85.91 MHz):
//   ce_fm  : every CPOM clocks (one fM period); opl_clk is the OPL3 master clock pin (clk / CPOM, ~50 % duty)
//   ce_scc : fM / 4   = 3.579545 MHz  (SCC, Y8950/OPLL reference)
//   ce_psg : fM / 8   = 1.789773 MHz  (AY-3-8910 / YM2149 clock of the MSX)
//   ce_fs  : fM / 288 = 49.716 kHz    (sample rate of the OPL3 and of the whole mix)
module aud_tick #(parameter CPOM = 4)(
    input  wire clk, rst,
    output reg  ce_fm, ce_scc, ce_psg, ce_fs,
    output reg  opl_clk
);
    reg [3:0] c0 = 0; reg [8:0] cf = 0;
    always @(posedge clk) begin
        ce_fm <= 1'b0; ce_scc <= 1'b0; ce_psg <= 1'b0; ce_fs <= 1'b0;
        if (rst) begin c0 <= 0; cf <= 0; opl_clk <= 1'b0; end
        else begin
            c0 <= (c0 == CPOM - 1) ? 4'd0 : c0 + 4'd1;
            opl_clk <= (c0 < CPOM / 2) ? 1'b0 : 1'b1;
            if (c0 == CPOM - 1) begin
                ce_fm <= 1'b1;
                cf <= (cf == 9'd287) ? 9'd0 : cf + 9'd1;
                if (cf[1:0] == 2'd3) ce_scc <= 1'b1;
                if (cf[2:0] == 3'd7) ce_psg <= 1'b1;
                if (cf == 9'd287) ce_fs <= 1'b1;
            end
        end
    end
endmodule
