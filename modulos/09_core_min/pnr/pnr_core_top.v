// P&R wrapper of the minimal core: inputs from LFSR, output = registered parity (not the final design).
module pnr_core_top(input wire clk, input wire din, output wire dout);
    reg [127:0] l = 128'h1; reg [3:0] rc = 0; wire rstw = (rc != 15);
    always @(posedge clk) begin if (rc != 15) rc <= rc + 1; l <= {l[126:0], l[127]^l[126]^l[125]^l[120]^din}; end
    wire i_req, d_req, d_we, dbg_sig; wire [63:0] i_addr, d_addr, d_wdata, dbg_pc; wire [1:0] d_size; wire [7:0] dbg_f;
    r8064_core_min u(.smc_miss(1'b0), .clk(clk), .rst(rstw), .irq(l[9]), .i_req(i_req), .i_addr(i_addr), .i_ack(l[3] & i_req), .i_rdata(l[63:0]),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_size(d_size), .d_wdata(d_wdata), .d_ack(l[5] & d_req), .d_rdata({l[127:64]}),
        .dbg_pc(dbg_pc), .dbg_f(dbg_f), .dbg_sig(dbg_sig));
    reg p; always @(posedge clk) p <= ^{i_req, d_req, d_we, i_addr, d_addr, d_wdata, d_size, dbg_pc, dbg_f, dbg_sig};
    assign dout = p;
endmodule
