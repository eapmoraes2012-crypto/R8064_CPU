// aud_slot_full.v - full MSX slot interface (memory and I/O) for a cartridge board that wires the whole slot to the FPGA
// (A0-A15, D0-D7, /SLTSL, /MREQ, /IORQ, /RD, /WR, /RESET in; data direction, /WAIT, /INT out). The cartridge is an
// EXPANDED slot: the subslot register at FFFFh (read back inverted) selects one of four subslots per 16 KB page.
// The asynchronous slot signals are synchronized (2 flip-flops) and turned into single-clock pulses:
//   io_we / io_re : I/O write / read cycle on any port (io_a = A0-A7); the devices answer reads through io_hit/io_rd.
//                   Writes are seen for every port (snooping, e.g. the PPI click bit at AAh/ABh).
//   m_we / m_re   : memory cycle with /SLTSL active (m_a = A0-A15, m_ss = subslot of the page); answers through m_hit/m_rd.
// The write data is sampled WR_DLY clocks after /WR falls (bits still settling right after the edge on real machines).
// Reads: the pulse comes 2 synchronization clocks after /RD; the data is driven from the next clock until /RD rises.
module aud_slot_full #(parameter WR_DLY = 8)(
    input  wire        clk, rst,
    input  wire        slot_sltsl_n, slot_mreq_n, slot_iorq_n, slot_rd_n, slot_wr_n,
    input  wire [15:0] slot_a, input wire [7:0] slot_d_i,
    output reg  [7:0]  slot_d_o, output reg slot_d_oe,
    output reg         io_we, io_re, output reg [7:0] io_a, output reg [7:0] io_wd,
    input  wire        io_hit, input wire [7:0] io_rd,
    output reg         m_we, m_re, output reg [15:0] m_a, output reg [7:0] m_wd, output reg [1:0] m_ss,
    input  wire        m_hit, input wire [7:0] m_rd
);
    reg [1:0] s_sl = 2'b11, s_mq = 2'b11, s_io = 2'b11, s_rd = 2'b11, s_wr = 2'b11;
    reg [15:0] a1 = 0, a2 = 0; reg [7:0] d1 = 0, d2 = 0;
    always @(posedge clk) begin
        s_sl <= {s_sl[0], slot_sltsl_n}; s_mq <= {s_mq[0], slot_mreq_n}; s_io <= {s_io[0], slot_iorq_n};
        s_rd <= {s_rd[0], slot_rd_n}; s_wr <= {s_wr[0], slot_wr_n};
        a1 <= slot_a; a2 <= a1; d1 <= slot_d_i; d2 <= d1;
    end
    wire sl = ~s_sl[1], mq = ~s_mq[1], io = ~s_io[1], rd = ~s_rd[1], wr = ~s_wr[1];
    reg [7:0] ssr;                                   // subslot register (FFFFh)
    wire [1:0] ss_of = (a2[15:14] == 2'd0) ? ssr[1:0] : (a2[15:14] == 2'd1) ? ssr[3:2] : (a2[15:14] == 2'd2) ? ssr[5:4] : ssr[7:6];
    reg rd_seen, wr_seen; reg [3:0] wc; reg wr_mem, wr_io; reg drv_m, drv_io; reg ssr_rd;
    always @(posedge clk) begin
        io_we <= 1'b0; io_re <= 1'b0; m_we <= 1'b0; m_re <= 1'b0;
        if (rst) begin
            ssr <= 8'h00; rd_seen <= 0; wr_seen <= 0; wc <= 0; slot_d_oe <= 0; slot_d_o <= 8'hFF; drv_m <= 0; drv_io <= 0; ssr_rd <= 0;
        end else begin
            // ---- read cycles
            if (rd && (io || (mq && sl)) && !rd_seen) begin
                rd_seen <= 1'b1;
                if (io) begin io_re <= 1'b1; io_a <= a2[7:0]; drv_io <= 1'b1; end
                else begin
                    m_a <= a2; m_ss <= ss_of;
                    if (a2 == 16'hFFFF) ssr_rd <= 1'b1; else begin m_re <= 1'b1; drv_m <= 1'b1; end
                end
            end
            if (rd_seen && rd) begin
                // drive one clock after the pulse, with the answer of the decoded device
                if (ssr_rd) begin slot_d_o <= ~ssr; slot_d_oe <= 1'b1; end
                else if (drv_io) begin if (io_hit) begin slot_d_o <= io_rd; slot_d_oe <= 1'b1; end drv_io <= 1'b0; end
                else if (drv_m)  begin if (m_hit)  begin slot_d_o <= m_rd;  slot_d_oe <= 1'b1; end drv_m  <= 1'b0; end
            end
            if (!rd) begin rd_seen <= 1'b0; slot_d_oe <= 1'b0; drv_io <= 0; drv_m <= 0; ssr_rd <= 0; end
            // ---- write cycles (data sampled WR_DLY clocks after /WR)
            if (wr && (io || (mq && sl)) && !wr_seen) begin wr_seen <= 1'b1; wc <= 0; wr_io <= io; wr_mem <= !io; end
            else if (wr_seen && wc != 4'hF) begin
                wc <= wc + 4'd1;
                if (wc == WR_DLY - 1) begin
                    if (wr_io) begin io_we <= 1'b1; io_a <= a2[7:0]; io_wd <= d2; end
                    else if (a2 == 16'hFFFF) ssr <= d2;
                    else begin m_we <= 1'b1; m_a <= a2; m_wd <= d2; m_ss <= ss_of; end
                    wc <= 4'hF;
                end
            end
            if (!wr) wr_seen <= 1'b0;
        end
    end
endmodule
