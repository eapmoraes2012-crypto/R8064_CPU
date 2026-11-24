// aud_mem_model.v - simulation memory for aud_mem (16 MB byte array, fixed latency LAT clocks, FFh initial content).
module aud_mem_model #(parameter LAT = 12)(
    input wire clk, input wire m_req, m_we, input wire [23:0] m_addr, input wire [7:0] m_wd,
    output reg m_ack = 0, output reg [7:0] m_rd = 0
);
    reg [7:0] mem [0:(1<<24)-1]; integer c = 0; reg act = 0;
    always @(posedge clk) begin
        m_ack <= 1'b0;
        if (m_req && !act && !m_ack) begin act <= 1'b1; c <= 0; end
        else if (act) begin
            if (c == LAT - 1) begin
                act <= 1'b0; m_ack <= 1'b1;
                if (m_we) mem[m_addr] <= m_wd; else m_rd <= (mem[m_addr] === 8'hxx) ? 8'hFF : mem[m_addr];
            end else c <= c + 1;
        end
    end
endmodule
