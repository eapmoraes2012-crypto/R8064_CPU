module pnr_gov_top(input wire clk, input wire din, output wire dout);
    reg [159:0] l = 160'h1; reg [3:0] rc = 0; wire rstw = (rc != 15);
    always @(posedge clk) begin if (rc != 15) rc <= rc + 1; l <= {l[158:0], l[159]^l[158]^l[157]^l[152]^din}; end
    wire c0,c1,c4,c5,c6,c9; wire [7:0] c2,c8; wire [19:0] c3; wire [63:0] c7;
    wire i_req, d_req, d_we, dbg_sig, gcv, nat, cs, z8, ro, mb, ioo, cw, cr; wire [7:0] ca, cwd; wire [63:0] i_addr, d_addr, d_wdata, dbg_pc; wire [1:0] d_size; wire [7:0] dbg_f, iord, dbe;
    r8064_cpu_gov u(.smc_miss(1'b0), .i_flt(l[11]), .d_flt(l[12]), .i_cs(l[15:13]), .d_cs(l[18:16]), .cr_mmu_en(c0), .cr_mmu_user(c1), .cr_asid(c2), .cr_root(c3), .cr_fl_all(c4), .cr_fl_va_en(c5), .cr_fl_asid_en(c6), .cr_fl_va(c7), .cr_fl_asid(c8), .cr_cinv(c9), .clk(clk), .rst(rstw), .irq(l[9]), .i_req(i_req), .i_ack(l[3] & i_req), .i_addr(i_addr), .i_rdata(l[63:0]),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_size(d_size), .d_wdata(d_wdata), .d_be(dbe), .d_ack(l[5] & d_req), .d_rdata(l[127:64]),
        .io_we(l[130]), .io_re(l[131]), .io_a(l[139:132]), .io_wd(l[147:140]), .io_rd(iord), .io_oe(ioo), .port_c(l[155:148]), .cio_we(cw), .cio_re(cr), .cio_a(ca), .cio_wd(cwd), .cio_rd(l[7:0]), .a8(l[7:0]), .map_we(l[100]), .map_idx(l[104:101]), .map_val(l[106:105]),
        .native64(nat), .clk_sel(cs), .is_z80(z8), .is_rom(ro), .mode_busy(mb), .dbg_pc(dbg_pc), .dbg_f(dbg_f), .dbg_sig(dbg_sig), .gov_cv(gcv));
    // observation in 2 registered stages (no long XOR tree as an artificial critical path)
    reg [13:0] pp; reg p;
    always @(posedge clk) begin
        pp <= {^{c0,c1,c2,c3,c4,c5,c6,c9,c8}, ^c7[63:32], ^c7[31:0], ^{i_req, d_req, d_we, d_size, gcv, nat, cs, z8, ro, mb, ioo, cw, cr, dbg_sig}, ^i_addr[63:32], ^i_addr[31:0], ^d_addr[63:32], ^d_addr[31:0], ^d_wdata[63:32], ^d_wdata[31:0],
               ^dbg_pc[63:32], ^dbg_pc[31:0], ^{dbe, dbg_f}, ^{iord, ca, cwd}};
        p <= ^pp;
    end
    assign dout = p;
endmodule
