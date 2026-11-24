// aud_mem.v - byte-wide memory arbiter for the audio engines (Y8950 ADPCM RAM, OPL4 wave memory, wavetable samples).
// NC clients, round robin, one transaction at a time. Client k: c_req[k] (level, held until c_ack[k]), c_we[k], c_addr, c_wd;
// c_ack[k] is a one-clock pulse when the write is done / the read data c_rd is valid.
// Memory side (to the SoC memory system, e.g. the DDR3 controller): m_req (level until m_ack), m_we, m_addr (byte), m_wd;
// m_ack one-clock pulse, with m_rd valid for reads. Audio RAM map (16 MB): 000000h Y8950 #1 (256 KB), 040000h Y8950 #2,
// 200000h-5FFFFFh OPL4 wave memory (2 MB ROM image + 2 MB RAM), 800000h-FFFFFFh wavetable samples.
module aud_mem #(parameter NC = 4)(
    input  wire clk, rst,
    input  wire [NC-1:0] c_req, c_we, input wire [NC*24-1:0] c_addr, input wire [NC*8-1:0] c_wd,
    output reg  [NC-1:0] c_ack, output reg [7:0] c_rd,
    output reg  m_req, output reg m_we, output reg [23:0] m_addr, output reg [7:0] m_wd,
    input  wire m_ack, input wire [7:0] m_rd
);
    reg [2:0] cur, nxt; reg busy; integer i;
    always @* begin
        nxt = cur;
        for (i = NC; i >= 1; i = i - 1) if (c_req[(cur + i) % NC]) nxt = (cur + i) % NC;
    end
    always @(posedge clk) begin
        c_ack <= 0;
        if (rst) begin busy <= 0; m_req <= 0; cur <= 0; end
        else if (!busy) begin
            if (|c_req) begin
                cur <= nxt; busy <= 1'b1; m_req <= 1'b1; m_we <= c_we[nxt];
                m_addr <= c_addr[nxt*24 +: 24]; m_wd <= c_wd[nxt*8 +: 8];
            end
        end else if (m_ack) begin
            m_req <= 1'b0; busy <= 1'b0; c_ack[cur] <= 1'b1; c_rd <= m_rd;
        end
    end
endmodule
