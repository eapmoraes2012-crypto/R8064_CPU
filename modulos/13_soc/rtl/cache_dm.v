// cache8k.v - 8 KB cache, 2 ways, 32 B line (4 64-bit words), in BSRAM; write-through with write buffer, no write allocate.
//   WR=0: instruction cache (read only).  WR=1: data cache (writes by byte-enable).
// CPU interface: req/ready (accepted when req && ready); read: rvalid+rdata on the SAME clock after acceptance if it hits (hit latency = 1 clock; 1 access per clock);
//   write: posted into the buffer (WBD entries), 1 bubble after each write. Read miss: fills the line (4 64-bit reads) and repeats the access.
// Memory interface (via arbiter): m_req held until m_accept; then waits for m_done (rvalid or wdone).
// Address: 64-bit word index (20 bits = 8 MB): tag [19:9], set [8:2], word in line [1:0].
module cache_dm #(parameter WR = 1, parameter WBD = 4, parameter IDX = 8, parameter STATS = 1, parameter B2B = 1)(
    input  wire        clk, rst, inv,
    input  wire        req, we,
    input  wire [19:0] addr,
    input  wire [63:0] wdata,
    input  wire [7:0]  be,
    output wire        ready,
    output wire        rvalid,
    output wire [63:0] rdata,
    output reg         m_req, m_we,
    output reg  [19:0] m_addr,
    output reg  [63:0] m_wdata,
    output reg  [7:0]  m_be,
    input  wire        m_accept, m_done,
    input  wire [63:0] m_rdata,
    output reg  [31:0] st_rd_hit, st_rd_miss, st_wr, st_wr_hit,
    // REV56: invalidation of ONE line (inv_ln pulse, set inv_set; I cache, self-modifying code) and 'write buffer empty' (D cache)
    input  wire        inv_ln, input wire [IDX-1:0] inv_set, input wire [17-IDX:0] inv_tag,
    output wire        wb_idle,
    // REV56: line lookup (I cache): lk_hit = the line {lk_tag, lk_set} is valid, being filled, or a one-line invalidation is pending
    input  wire [IDX-1:0] lk_set, input wire [17-IDX:0] lk_tag, output wire lk_hit
);
    // ---------------- arrays
    localparam TB = 18 - IDX;   // tag bits
    reg [63:0] d0 [0:(1<<(IDX+2))-1];
    // tags with valid bit (bit 10), in 2 copies (A: read with the new address, B: read with that of stage 1) so there is no mux dependent on 'accept'
    reg [TB:0] tA0 [0:(1<<IDX)-1]; reg [TB:0] tB0 [0:(1<<IDX)-1];
    reg [TB:0] tC0 [0:(1<<IDX)-1];   // REV56: third copy, read with the set of a one-line invalidation (only a line holding that tag is invalidated)
    reg [TB-1:0] ln_tag;
    reg inv_pend, sweeping; reg [IDX-1:0] sw;
    reg ln_pend, fill_poison; reg [IDX-1:0] ln_set;   // REV56: one-line invalidation pending; a fill in progress during it ends invalid
    // stage 1
    reg        s1_valid, s1_ok, s1_we; reg [19:0] s1_addr; reg [63:0] s1_wd; reg [7:0] s1_be;
    wire [TB-1:0] s1_tag = s1_addr[19:IDX+2]; wire [IDX-1:0] s1_set = s1_addr[IDX+1:2];
    wire       accept;
    wire [IDX+1:0] ra = accept ? addr[IDX+1:0] : s1_addr[IDX+1:0];
    wire [IDX-1:0] sa = addr[IDX+1:2], sb = s1_addr[IDX+1:2];
    wire [TB:0] t0_a = tA0[sa], t0_b = tB0[sb];
    reg [63:0] qd0; reg hit0;
    always @(posedge clk) begin
        qd0 <= d0[ra];
        // tags and valids: read BOTH candidates (new address and that of stage 1) and choose afterwards, to take ready->accept off the 128:1 mux path
        // the tag compare is also done before the register: stage 1 only receives already-registered hit0/hit1 (ready stays shallow)
        hit0 <= accept ? (t0_a[TB] && t0_a[TB-1:0] == addr[19:IDX+2]) : (t0_b[TB] && t0_b[TB-1:0] == s1_tag);
    end
    wire hit = hit0;
    wire [63:0] hword = qd0;
    // write buffer
    reg [19:0] wb_a [0:WBD-1]; reg [63:0] wb_d [0:WBD-1]; reg [7:0] wb_b [0:WBD-1]; reg [3:0] wb_cnt; reg [1:0] wb_rp, wb_wp;
    wire wb_space = (WR != 0) && (wb_cnt < WBD);
    // miss state
    localparam [2:0] F_NORMAL = 0, F_WAIT = 1, F_REQ = 2, F_RD = 3, F_TAG = 4;
    reg [2:0] fs; reg [1:0] fk;
    reg ds; // 0 = drain idle, 1 = write in progress (waiting for accept/completion)
    reg ds_acc;
    wire evalu = s1_valid && s1_ok && (fs == F_NORMAL) && !sweeping;
    wire rd_hit  = evalu && !s1_we && hit;
    wire rd_miss = evalu && !s1_we && !hit;
    wire wr_done = evalu && s1_we && wb_space;
    // B2B=1: accepts a new access in the same clock in which the stage-1 read hit ends (1 access/clock).
    // B2B=0: only accepts with stage 1 empty; takes hit0 (and all the hit logic) off the ready -> accept -> BSRAM address path.
    //        Valid when the client never presents req while the previous read has not yet been answered (memsys: dst/ist only return to S_CREQ >= 3 clocks after rvalid).
    assign ready  = !sweeping && !ln_pend && (!s1_valid || (B2B != 0 && rd_hit));
    assign accept = req && ready;
    assign rvalid = rd_hit;
    assign rdata  = hword;
    // word merged for write with byte-enable
    wire [63:0] mrg = {be_m(s1_be[7], hword[63:56], s1_wd[63:56]), be_m(s1_be[6], hword[55:48], s1_wd[55:48]), be_m(s1_be[5], hword[47:40], s1_wd[47:40]), be_m(s1_be[4], hword[39:32], s1_wd[39:32]),
                       be_m(s1_be[3], hword[31:24], s1_wd[31:24]), be_m(s1_be[2], hword[23:16], s1_wd[23:16]), be_m(s1_be[1], hword[15:8],  s1_wd[15:8]),  be_m(s1_be[0], hword[7:0],   s1_wd[7:0])};
    function [7:0] be_m(input b, input [7:0] o, input [7:0] n); be_m = b ? n : o; endfunction
    // write into the arrays (single port per array)
    wire        wr_hit_upd = wr_done && hit;
    wire        fill_wr    = (fs == F_RD) && m_done;
    wire        d0_we = wr_hit_upd || fill_wr;
    wire [IDX+1:0] d_wa = fill_wr ? {s1_set, fk} : s1_addr[IDX+1:0];
    wire [63:0] d_wd = fill_wr ? m_rdata : mrg;
    wire [TB:0] t0_c = tC0[ln_pend ? ln_set : lk_set];
    assign lk_hit = ln_pend || (t0_c[TB] && t0_c[TB-1:0] == lk_tag) || ((fs != F_NORMAL) && s1_addr[19:2] == {lk_tag, lk_set});
    wire        ln_hit = t0_c[TB] && (t0_c[TB-1:0] == ln_tag);
    wire        ln_wr  = ln_pend && !sweeping && (fs != F_TAG) && ln_hit;
    wire        ln_done = ln_pend && !sweeping && (fs != F_TAG);
    wire        tg_we0 = sweeping || (fs == F_TAG) || ln_wr;
    wire [IDX-1:0] tg_wa  = sweeping ? sw : (fs == F_TAG) ? s1_set : ln_set;
    wire [TB:0] tg_wd  = (sweeping || fs != F_TAG) ? {(TB+1){1'b0}} : {!fill_poison, s1_tag};
    assign wb_idle = (wb_cnt == 0) && (ds == 0) && !(s1_valid && s1_we);
    always @(posedge clk) begin
        if (d0_we) d0[d_wa] <= d_wd;
        if (tg_we0) begin tA0[tg_wa] <= tg_wd; tB0[tg_wa] <= tg_wd; tC0[tg_wa] <= tg_wd; end
    end
    integer i;
    always @(posedge clk) begin
        m_req <= m_req & ~m_accept;
        if (rst) begin
            s1_valid <= 0; s1_ok <= 0; fs <= F_NORMAL; ds <= 0; ds_acc <= 0; wb_cnt <= 0; wb_rp <= 0; wb_wp <= 0; inv_pend <= 1; sweeping <= 0; sw <= 0; m_req <= 0; m_we <= 0; ln_pend <= 0; fill_poison <= 0;
            st_rd_hit <= 0; st_rd_miss <= 0; st_wr <= 0; st_wr_hit <= 0; fk <= 0;
        end else begin
            // ---- stage 1
            if (accept) begin s1_valid <= 1; s1_ok <= 1; s1_we <= we; s1_addr <= addr; s1_wd <= wdata; s1_be <= be; end
            else if (rd_hit || wr_done) s1_valid <= 0;
            if (rd_hit && STATS) st_rd_hit <= st_rd_hit + 1;
            if (wr_done) begin
                if (STATS) begin st_wr <= st_wr + 1; if (hit) st_wr_hit <= st_wr_hit + 1; end
                wb_a[wb_wp] <= s1_addr; wb_d[wb_wp] <= s1_wd; wb_b[wb_wp] <= s1_be; wb_wp <= wb_wp + 1;
            end
            // ---- read miss: fill
            case (fs)
                F_NORMAL: if (rd_miss) begin if (STATS) st_rd_miss <= st_rd_miss + 1; s1_ok <= 0; fs <= F_WAIT; fk <= 0; end
                F_WAIT: if (wb_cnt == 0 && ds == 0 && !m_req) begin
                    m_req <= 1; m_we <= 0; m_addr <= {s1_addr[19:2], fk}; fs <= F_RD;
                end
                F_RD: if (m_done) begin
                    if (fk == 2'd3) fs <= F_TAG;
                    else begin fk <= fk + 1; m_req <= 1; m_we <= 0; m_addr <= {s1_addr[19:2], fk + 2'd1}; end
                end
                F_TAG: begin
                    fs <= F_NORMAL; s1_ok <= 0;   // one wait clock: re-read s1_addr
                    fill_poison <= 1'b0;
                end
                default: fs <= F_NORMAL;
            endcase
            if (fs == F_NORMAL && s1_valid && !s1_ok && !rd_miss && !wr_done) s1_ok <= 1;   // data re-read
            // REV56: one-line invalidation (written on a clock without a fill tag write or sweep; a fill in progress is poisoned)
            if (inv_ln) begin ln_pend <= 1'b1; ln_set <= inv_set; ln_tag <= inv_tag; if (fs != F_NORMAL) fill_poison <= 1'b1; end
            else if (ln_done) begin ln_pend <= 1'b0; if (ln_hit) s1_ok <= 1'b0; end
            // invalidation: 128-clock sweep clearing the valid bit (cache unavailable during the sweep)
            if (inv) inv_pend <= 1;
            if (!sweeping && inv_pend && fs == F_NORMAL && !rd_miss) begin sweeping <= 1; sw <= 0; if (!inv) inv_pend <= 0; end
            if (sweeping) begin sw <= sw + 1; if (sw == {IDX{1'b1}}) begin sweeping <= 0; s1_ok <= 0; end end
            // ---- write buffer drain (only when no fill is in progress)
            if (WR != 0) begin
                if (ds == 0 && wb_cnt != 0 && !m_req && (fs == F_NORMAL || fs == F_WAIT)) begin
                    m_req <= 1; m_we <= 1; m_addr <= wb_a[wb_rp]; m_wdata <= wb_d[wb_rp]; m_be <= wb_b[wb_rp]; ds <= 1;
                end else if (ds == 1 && m_done) begin
                    ds <= 0; wb_rp <= wb_rp + 1;
                end
                wb_cnt <= wb_cnt + (wr_done ? 1 : 0) - ((ds == 1 && m_done) ? 1 : 0);
            end
        end
    end
endmodule
