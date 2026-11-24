// r8064_memsys.v - SoC memory subsystem: MMU (I and D TLB) + 4 KB I cache + 8 KB D cache + 5-master arbiter (the 5th is the DMA) + SDRAM controller (8 MB).
//  Core side: the core's req/ack protocol (c_i_* and c_d_*). See r8064_soc.v for the path description.
module r8064_memsys #(parameter INIT_CYC = 20000, parameter REF_INT = 400)(
    input  wire        clk, rst,
    input  wire        c_i_req, output wire c_i_ack, input wire [63:0] c_i_pa, output wire [63:0] c_i_rd,
    input  wire        c_d_req, c_d_we, output reg c_d_ack, input wire [63:0] c_d_pa, input wire [63:0] c_d_wd, input wire [7:0] c_d_be, output reg [63:0] c_d_rd,
    input  wire        mmu_en, mmu_user, input wire [7:0] mmu_asid, input wire [19:0] mmu_root,
    input  wire        fl_all, fl_va_en, fl_asid_en, input wire [63:0] fl_va, input wire [7:0] fl_asid, output wire fl_busy_i, fl_busy_d,
    input  wire        cache_inv,
    input  wire        smc_en,    // REV56: governed modes (Z80/R800): every core store invalidates its I-cache line before the next fetch (self-modifying code)
    // 5th SDRAM master (DMA, lowest priority): protocol req until acc, then wait for done (rdata valid on the done clock)
    input  wire        x_req, x_we, input wire [19:0] x_addr, input wire [63:0] x_wd, input wire [7:0] x_be, output wire x_acc, x_done, output wire [63:0] x_rd,
    output reg         i_fault, d_fault, output reg [2:0] i_cause, d_cause,
    output wire        init_done,
    output wire        s_cke, s_cs_n, s_ras_n, s_cas_n, s_we_n, output wire [3:0] s_dqm, output wire [1:0] s_ba, output wire [10:0] s_a,
    output wire [31:0] s_dq_o, output wire s_dq_oe, input wire [31:0] s_dq_i
);
    // ---------------- instruction side ----------------
    wire iv_ready, iv_pvalid, iv_pfault; wire [31:0] iv_paddr; wire [2:0] iv_pcause;
    wire iw_req, iw_accept, iw_done; wire [19:0] iw_addr;
    wire ic_ready, ic_rvalid; wire [63:0] ic_rdata;
    wire ic_mreq, ic_mwe, ic_maccept, ic_mdone; wire [19:0] ic_maddr; wire [63:0] ic_mwd; wire [7:0] ic_mbe;
    wire [63:0] arbI_rdata;
    reg [1:0] ist; reg [31:0] ipa; reg i_ack_r; reg i_ic_sent; reg i_cancel;
    wire ican = i_cancel || !c_i_req;   // the core withdrew the request (front-end flush): the in-flight response is discarded
    localparam S_IDLE = 2'd0, S_XL = 2'd1, S_CREQ = 2'd2, S_WAIT = 2'd3;
    // REV48: with the MMU off (en = 0 is a pure pass-through of the low 32 bits) the request skips the 2 translation clocks: IDLE -> CREQ directly
    reg smc_pend, smc_full, ic_inv_ln, ic_inv_all; reg [6:0] smc_set; reg [10:0] smc_tag; wire dc_wb_idle;
    // REV56: while a store's I-line invalidation is pending, only fetches of THAT line wait (all fetches if two lines are pending); the
    // prefetch of other lines goes on, so the refetch after the store finds them in the cache as before
    wire smc_blk = (smc_pend && (smc_full || c_i_pa[22:5] == {smc_tag, smc_set})) || ic_inv_ln || ic_inv_all;
    wire i_new   = (ist == S_IDLE) && c_i_req && !i_ack_r && !smc_blk;   // !i_ack_r: on the fault-ack clock the core still holds the request (do not accept again)
    wire i_byp   = i_new && !mmu_en;
    wire iv_req  = i_new && mmu_en;
    // REV54: with the MMU off the request goes to the I-cache in the SAME clock (IDLE -> WAIT): 2 clocks per fetch instead of 3
    wire ic_req  = (ist == S_CREQ) || i_byp;
    wire [19:0] ic_addr = (ist == S_IDLE) ? c_i_pa[22:3] : ipa[22:3];
    wire i_acc_v = iv_req && iv_ready;
    always @(posedge clk) begin
        if (rst) begin i_cancel <= 1'b0; ist <= S_IDLE; i_fault <= 1'b0; i_cause <= 3'd0; i_ack_r <= 1'b0; ipa <= 32'd0; end
        else begin
            i_ack_r <= 1'b0; i_fault <= 1'b0;
            if (ist == S_IDLE) i_cancel <= 1'b0; else if (!c_i_req) i_cancel <= 1'b1;
            case (ist)
                S_IDLE: if (i_byp) begin ipa <= c_i_pa[31:0]; ist <= ic_ready ? S_WAIT : S_CREQ; end
                        else if (i_acc_v) ist <= S_XL;
                S_XL: if (iv_pvalid) begin
                          if (ican) ist <= S_IDLE;
                          else if (iv_pfault) begin i_fault <= 1'b1; i_cause <= iv_pcause; i_ack_r <= 1'b1; ist <= S_IDLE; end
                          else begin ipa <= iv_paddr; ist <= S_CREQ; end
                      end
                S_CREQ: if (ic_ready) ist <= S_WAIT;
                S_WAIT: if (ic_rvalid) ist <= S_IDLE;
                default: ist <= S_IDLE;
            endcase
        end
    end
    assign c_i_ack = (ist == S_WAIT && ic_rvalid && !ican) || i_ack_r;
    assign c_i_rd  = i_ack_r ? 64'd0 : ic_rdata;
    mmu #(.NENT(2), .STATS(0)) u_mmu_i(.clk(clk), .rst(rst), .en(mmu_en), .user(mmu_user), .asid(mmu_asid), .root_ppn(mmu_root),
        .fl_all(fl_all), .fl_va_en(fl_va_en), .fl_asid_en(fl_asid_en), .fl_va(fl_va), .fl_asid(fl_asid),
        .v_req(iv_req), .v_addr(c_i_pa), .v_acc(2'd2), .ready(iv_ready), .fl_busy(fl_busy_i), .p_valid(iv_pvalid), .p_addr(iv_paddr), .p_fault(iv_pfault), .p_cause(iv_pcause),
        .m_req(iw_req), .m_addr(iw_addr), .m_accept(iw_accept), .m_done(iw_done), .m_rdata(arbI_rdata), .st_hit(), .st_miss(), .st_walk(), .st_fault());
    cache_dm #(.WR(0), .IDX(7), .STATS(0), .B2B(0)) u_ic(.clk(clk), .rst(rst), .inv(cache_inv | ic_inv_all), .inv_ln(ic_inv_ln), .inv_set(smc_set), .inv_tag(smc_tag), .wb_idle(), .req(ic_req), .we(1'b0), .addr(ic_addr), .wdata(64'd0), .be(8'd0),
        .ready(ic_ready), .rvalid(ic_rvalid), .rdata(ic_rdata), .m_req(ic_mreq), .m_we(ic_mwe), .m_addr(ic_maddr), .m_wdata(ic_mwd), .m_be(ic_mbe),
        .m_accept(ic_maccept), .m_done(ic_mdone), .m_rdata(arbI_rdata), .st_rd_hit(), .st_rd_miss(), .st_wr(), .st_wr_hit());

    // ---------------- data side ----------------
    wire dv_ready, dv_pvalid, dv_pfault; wire [31:0] dv_paddr; wire [2:0] dv_pcause;
    wire dw_req, dw_accept, dw_done; wire [19:0] dw_addr;
    wire dc_ready, dc_rvalid; wire [63:0] dc_rdata;
    wire dc_mreq, dc_mwe, dc_maccept, dc_mdone; wire [19:0] dc_maddr; wire [63:0] dc_mwd; wire [7:0] dc_mbe;
    wire [63:0] arbD_rdata;
    reg [1:0] dst; reg [31:0] dpa; reg d_ack_r; reg d_fault_w; reg [2:0] d_cause_w; wire c_d_ack_w; wire [63:0] c_d_rd_w;
    wire d_new  = (dst == S_IDLE) && c_d_req && !d_ack_r && !c_d_ack;   // same: posted/fault ack with the core's request still in the air
    wire d_byp  = d_new && !mmu_en;                                     // REV48: MMU off -> straight to the cache
    wire dv_req = d_new && mmu_en;
    // REV55: with the MMU off the access goes to the D-cache in the SAME clock (IDLE -> WAIT, or the posted write acked at once): 1 clock less per access
    wire dc_req = (dst == S_CREQ) || d_byp;
    wire [19:0] dc_addr = (dst == S_IDLE) ? c_d_pa[22:3] : dpa[22:3];
    wire d_acc_v = dv_req && dv_ready;
    always @(posedge clk) begin
        if (rst) begin dst <= S_IDLE; d_fault_w <= 1'b0; d_cause_w <= 3'd0; d_ack_r <= 1'b0; dpa <= 32'd0; end
        else begin
            d_ack_r <= 1'b0; d_fault_w <= 1'b0;
            case (dst)
                S_IDLE: if (d_byp) begin
                            dpa <= c_d_pa[31:0];
                            if (!dc_ready) dst <= S_CREQ;
                            else if (c_d_we) d_ack_r <= 1'b1;           // posted write accepted now
                            else dst <= S_WAIT;
                        end
                        else if (d_acc_v) dst <= S_XL;
                S_XL: if (dv_pvalid) begin
                          if (dv_pfault) begin d_fault_w <= 1'b1; d_cause_w <= dv_pcause; d_ack_r <= 1'b1; dst <= S_IDLE; end
                          else begin dpa <= dv_paddr; dst <= S_CREQ; end
                      end
                S_CREQ: if (dc_ready) begin
                            if (c_d_we) begin d_ack_r <= 1'b1; dst <= S_IDLE; end      // posted write into the cache buffer: ack on the next clock
                            else dst <= S_WAIT;
                        end
                S_WAIT: if (dc_rvalid) dst <= S_IDLE;
                default: dst <= S_IDLE;
            endcase
        end
    end
    assign c_d_ack_w = (dst == S_WAIT && dc_rvalid) || d_ack_r;
    // REV56 self-modifying code (governed modes): a core store accepted by the D cache marks its line set; when the write buffer has drained
    // to the SDRAM the I-cache line of that set is invalidated (two different sets before the drain: whole I cache). Fetches wait meanwhile;
    // the core refetches after every store in these modes, so the bytes already in its queue are discarded too.
    wire dc_wacc = dc_req && c_d_we && dc_ready;
    always @(posedge clk) begin
        ic_inv_ln <= 1'b0; ic_inv_all <= 1'b0;
        if (rst) begin smc_pend <= 1'b0; smc_full <= 1'b0; smc_set <= 7'd0; end
        else if (smc_en && dc_wacc) begin
            if (smc_pend && (smc_set != dc_addr[8:2] || smc_tag != dc_addr[19:9])) smc_full <= 1'b1;
            smc_pend <= 1'b1; smc_set <= dc_addr[8:2]; smc_tag <= dc_addr[19:9];
        end else if (smc_pend && dc_wb_idle) begin
            ic_inv_ln <= !smc_full; ic_inv_all <= smc_full; smc_pend <= 1'b0; smc_full <= 1'b0;
        end
    end
    assign c_d_rd_w  = d_ack_r ? 64'd0 : dc_rdata;
    // ack, data and data fault registered before reaching the core (+1 clock per access): takes the cache hit logic off the core's stall/flush path
    always @(posedge clk) begin
        if (rst) begin c_d_ack <= 1'b0; d_fault <= 1'b0; d_cause <= 3'd0; end
        else begin c_d_ack <= c_d_ack_w; d_fault <= d_fault_w; d_cause <= d_cause_w; end
        c_d_rd <= c_d_rd_w;
    end
    mmu #(.NENT(2), .STATS(0)) u_mmu_d(.clk(clk), .rst(rst), .en(mmu_en), .user(mmu_user), .asid(mmu_asid), .root_ppn(mmu_root),
        .fl_all(fl_all), .fl_va_en(fl_va_en), .fl_asid_en(fl_asid_en), .fl_va(fl_va), .fl_asid(fl_asid),
        .v_req(dv_req), .v_addr(c_d_pa), .v_acc(c_d_we ? 2'd1 : 2'd0), .ready(dv_ready), .fl_busy(fl_busy_d), .p_valid(dv_pvalid), .p_addr(dv_paddr), .p_fault(dv_pfault), .p_cause(dv_pcause),
        .m_req(dw_req), .m_addr(dw_addr), .m_accept(dw_accept), .m_done(dw_done), .m_rdata(arbD_rdata), .st_hit(), .st_miss(), .st_walk(), .st_fault());
    cache_dm #(.WR(1), .IDX(7), .STATS(0), .B2B(0)) u_dc(.clk(clk), .rst(rst), .inv(cache_inv), .inv_ln(1'b0), .inv_set(7'd0), .inv_tag(11'd0), .wb_idle(dc_wb_idle), .req(dc_req), .we(c_d_we), .addr(dc_addr), .wdata(c_d_wd), .be(c_d_be),
        .ready(dc_ready), .rvalid(dc_rvalid), .rdata(dc_rdata), .m_req(dc_mreq), .m_we(dc_mwe), .m_addr(dc_maddr), .m_wdata(dc_mwd), .m_be(dc_mbe),
        .m_accept(dc_maccept), .m_done(dc_mdone), .m_rdata(arbD_rdata), .st_rd_hit(), .st_rd_miss(), .st_wr(), .st_wr_hit());

    // ---------------- 5-master arbiter (registered request) -> SDRAM ----------------
// m0 = D cache, m1 = MMU-D walker, m2 = I cache, m3 = MMU-I walker, m4 = DMA
    wire t_req, t_we, t_ready, t_rvalid, t_wdone; wire [19:0] t_addr; wire [63:0] t_wd, top_rdata, sd_rdata; wire [7:0] t_be;
    wire [4:0] a_acc, a_done;
    mem_arb5 u_arb(.clk(clk), .rst(rst),
        .req({x_req, iw_req, ic_mreq, dw_req, dc_mreq}), .we({x_we, 1'b0, ic_mwe, 1'b0, dc_mwe}),
        .addr({x_addr, iw_addr, ic_maddr, dw_addr, dc_maddr}), .wdata({x_wd, 64'd0, ic_mwd, 64'd0, dc_mwd}), .be({x_be, 8'd0, ic_mbe, 8'd0, dc_mbe}),
        .acc(a_acc), .done(a_done), .rdata(top_rdata),
        .c_req(t_req), .c_we(t_we), .c_addr(t_addr), .c_wdata(t_wd), .c_be(t_be), .c_ready(t_ready), .c_rvalid(t_rvalid), .c_rdata(sd_rdata), .c_wdone(t_wdone));
    assign dc_maccept = a_acc[0]; assign dc_mdone = a_done[0];
    assign dw_accept  = a_acc[1]; assign dw_done  = a_done[1];
    assign ic_maccept = a_acc[2]; assign ic_mdone = a_done[2];
    assign iw_accept  = a_acc[3]; assign iw_done  = a_done[3];
    assign x_acc = a_acc[4]; assign x_done = a_done[4]; assign x_rd = top_rdata;
    assign arbD_rdata = top_rdata; assign arbI_rdata = top_rdata;
    sdram_ctrl #(.INIT_CYC(INIT_CYC), .REF_INT(REF_INT)) u_sdram(.clk(clk), .rst(rst), .req(t_req), .we(t_we), .addr(t_addr), .wdata(t_wd), .be(t_be),
        .ready(t_ready), .rvalid(t_rvalid), .rdata(sd_rdata), .wdone(t_wdone), .init_done(init_done),
        .s_cke(s_cke), .s_cs_n(s_cs_n), .s_ras_n(s_ras_n), .s_cas_n(s_cas_n), .s_we_n(s_we_n), .s_dqm(s_dqm), .s_ba(s_ba), .s_a(s_a), .s_dq_o(s_dq_o), .s_dq_oe(s_dq_oe), .s_dq_i(s_dq_i));
endmodule
