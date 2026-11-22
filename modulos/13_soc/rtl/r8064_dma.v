// r8064_dma.v - 4-channel DMA of the R8064. A single physical-memory master (64-bit words, 8 MB), serving the channels round-robin (one word at a time).
//
// Programming (control registers written by MTCR = ED 0C n, with AX; the core forwards the write to CR19..CR30):
//   channel 0: CR19 SRC | CR20 DST | CR21 CTRL     channel 1: CR22 SRC | CR23 DST | CR24 CTRL
//   channel 2: CR25 SRC | CR26 DST | CR27 CTRL     channel 3: CR28 SRC | CR29 DST | CR30 CTRL
//   (cr_idx = n - 19 = 0..11; MFCR returns the last value written, which stays in the core's register bank)
//   SRC / DST : PHYSICAL byte address (uses bits [22:3]: 64-bit word aligned, 8 MB); bit 23 = window buffer; bits [63:24] != 0 -> error on start
//   CTRL      : [18:0] COUNT in 64-bit words (0 = nothing to do) | [20:19] MODE | [31] START (only starts with the channel stopped)
//   MSX EXCHANGE WINDOW (REV46): SRC or DST with bit 23 = 1 (address 800000h..803FFFh) points to the 16 KB buffer of the 8000h-BFFFh window (2048 words; MODE 0 only).
//     Only one side may be the buffer; offset + COUNT <= 2048 words; otherwise ERROR. The DMA waits (stalls) while the window belongs to the MSX (b_ok = 0).
//     Buffer<->SDRAM transfers 1 64-bit word per memory transaction (without serializing bytes as in the FIFO modes).
//   MODE 0 = memory -> memory | 1 = memory -> FIFO R8064->MSX (SRC) | 2 = FIFO MSX->R8064 -> memory (DST) | 3 = reserved (error)
//   In modes 1 and 2 each word is transferred as 8 bytes, least significant byte first; the channel waits for the FIFO to have data/space.
//   Read-back (MFCR) returns the last value written, not the current pointer.
// PERFORMANCE (REV43): the engine does not go through idle states between words (the next channel of the round-robin is chosen on the clock where the word ends);
//   in MODE 0 with the source in the window the next word is read from the buffer while the SDRAM write is in progress (when only one channel is active);
//   with the destination in the window, the word read from the SDRAM is written to the buffer on the 'done' clock itself. The limit becomes the SDRAM (see teste_dma_win.txt).
// I/O ports (parameters): PORT_STAT (EEh, channels 0 and 1), PORT_IE (EFh), PORT_STAT2 (EDh, channels 2 and 3)
//   STAT  read : b0 ACTIVE0, b1 DONE0, b2 ERROR0, b3 IRQ pending (any channel), b4 ACTIVE1, b5 DONE1, b6 ERROR1
//   STAT2 read : the same for channels 2 (b0..b2) and 3 (b4..b6)
//   STAT/STAT2 write : b0 clears DONE/ERROR of the even channel | b1 aborts the even channel (DONE + ERROR) | b4 and b5: the same for the odd channel
//   IE read/write: b0..b3 enable the IRQ of channels 0..3 (irq = DONE & IE)
// Coherence: the data cache is write-through with no write-allocate and does not see DMA writes. At the end of a transfer that writes to memory
//   (modes 0 and 2) and when aborting an active channel, the DMA issues the 'inv' pulse (invalidates the caches). Before starting a read of data written by the core, use FENCE (ED A5).
module r8064_dma #(parameter PORT_STAT = 8'hEE, parameter PORT_IE = 8'hEF, parameter PORT_STAT2 = 8'hED)(
    input  wire        clk, rst,
    input  wire        cr_we, input wire [3:0] cr_idx, input wire [63:0] cr_wd,
    input  wire        io_we, io_re, input wire [7:0] io_a, io_wd, output wire [7:0] io_rd, output wire io_sel,
    // physical-memory master (64-bit word index; arbiter protocol: req until acc, then wait for done)
    output wire        m_req, m_we, output wire [19:0] m_addr, output wire [63:0] m_wd, output wire [7:0] m_be,
    input  wire        m_acc, m_done, input wire [63:0] m_rd,
    // FIFOs (device)
    input  wire        a_avail, input wire [7:0] a_q, input wire b_space,
    output wire        d_pop, d_push, output wire [7:0] d_wd,
    // MSX window buffer (DMA-side port; read with 1 clock of latency)
    input  wire        b_ok, output wire b_re, b_we, output wire [10:0] b_a, output wire [63:0] b_wd, input wire [63:0] b_q,
    output wire        irq,
    output reg         inv,
    // boot: loads channel 0 (buffer offset 0 -> SDRAM 0, boot_cnt words, MODE 0) without going through the core
    input  wire        boot_go, input wire [18:0] boot_cnt, output wire boot_done, input wire boot_clr
);
`ifdef R8064_NO_DMA
    // REV53c: build WITHOUT the DMA (saves ~1,100 LUTs for the FPU build): only the boot copy remains (window buffer word i -> SDRAM word i,
    // i = 0..boot_cnt-1, one word at a time), then the 'inv' pulse as at the end of a channel-0 transfer. MTCR CR19..CR30 and the ports are ignored
    // (they read 00h), no IRQ, no FIFO modes.
    localparam [2:0] B_IDLE = 0, B_RD = 1, B_LAT = 2, B_WR = 3, B_WT = 4;
    reg [2:0] bs; reg [18:0] bn; reg [10:0] ba; reg [19:0] bd; reg [63:0] bq; reg bdone;
    assign io_rd = 8'h00; assign io_sel = 1'b0; assign irq = 1'b0; assign d_pop = 1'b0; assign d_push = 1'b0; assign d_wd = 8'h00;
    assign b_re = (bs == B_RD) && b_ok; assign b_we = 1'b0; assign b_a = ba; assign b_wd = 64'd0;
    assign m_req = (bs == B_WR); assign m_we = 1'b1; assign m_addr = bd; assign m_wd = bq; assign m_be = 8'hFF;
    assign boot_done = bdone;
    always @(posedge clk) begin
        inv <= 1'b0;
        if (rst) begin bs <= B_IDLE; bdone <= 1'b0; end
        else begin
            if (boot_clr) bdone <= 1'b0;
            case (bs)
                B_IDLE: if (boot_go) begin bn <= boot_cnt; ba <= 11'd0; bd <= 20'd0; bdone <= 1'b0;
                                           if (boot_cnt == 19'd0) begin bdone <= 1'b1; inv <= 1'b1; end else bs <= B_RD; end
                B_RD:   if (b_ok) bs <= B_LAT;
                B_LAT:  begin bq <= b_q; bs <= B_WR; end                     // b_q: 1 clock after b_re
                B_WR:   if (m_acc) bs <= B_WT;
                B_WT:   if (m_done) begin
                            bn <= bn - 19'd1; ba <= ba + 11'd1; bd <= bd + 20'd1;
                            if (bn == 19'd1) begin bdone <= 1'b1; inv <= 1'b1; bs <= B_IDLE; end else bs <= B_RD;
                        end
                default: bs <= B_IDLE;
            endcase
        end
    end
`else
`ifdef R8064_DMA2
    localparam NCH = 2;   // REV47: per-channel state only for the 2 existing channels (the index never reaches 2/3: writes to CR25..CR30 are ignored)
`else
    localparam NCH = 4;
`endif
    reg [20:0] s_r [0:NCH-1]; reg [20:0] d_r [0:NCH-1]; reg [3:0] s_bad, d_bad;
    reg [20:0] w_src [0:NCH-1]; reg [20:0] w_dst [0:NCH-1]; reg [18:0] cnt [0:NCH-1]; reg [1:0] md_r [0:NCH-1];
    reg [3:0] act, done, err, ie;
    reg [1:0] cur, last; reg lp; reg [3:0] st; reg [2:0] k; reg [63:0] dbuf;
    localparam E_IDLE = 4'd0, E_RRQ = 4'd1, E_RWT = 4'd2, E_WRQ = 4'd3, E_WWT = 4'd4, E_PUSH = 4'd5, E_POP = 4'd6, E_NEXT = 4'd7, E_RWB = 4'd8;
    wire [1:0]  md    = md_r[cur];
    wire [20:0] c_src = w_src[cur], c_dst = w_dst[cur];
    wire sbuf = c_src[20] && (md == 2'd0), dbuf_b = c_dst[20] && (md == 2'd0);
    wire [18:0] c_cnt = cnt[cur];   // sbuf/dbuf_b: access to the window buffer (MODE 0 only)
    wire       last_w = (c_cnt == 19'd1);                       // the current word is the last of the block
    // destination in the window with the word read from the SDRAM: writes to the buffer on the 'done' clock (without going through dbuf/E_WRQ)
    wire       direct_bw = (st == E_RWT) && m_done && dbuf_b && b_ok && act[cur];
    // source in the window: the SDRAM write is requested already on the clock where b_q arrives (E_RWB), without going through E_WRQ
    wire       rwb_w  = (st == E_RWB) && act[cur] && !dbuf_b;
    assign m_req  = ((st == E_RRQ) && !sbuf) || ((st == E_WRQ) && !dbuf_b) || rwb_w;
    assign m_we   = (st == E_WRQ) || (st == E_RWB);
    assign m_addr = (st == E_WRQ || st == E_RWB) ? c_dst[19:0] : c_src[19:0];
    assign b_re   = (st == E_RRQ) && sbuf && b_ok;
    assign b_we   = direct_bw || ((st == E_WRQ) && dbuf_b && b_ok);
    assign b_a    = ((st == E_WRQ) || (st == E_RWT)) ? c_dst[10:0] : c_src[10:0];
    assign b_wd   = (st == E_RWT) ? m_rd : dbuf;
    assign m_wd   = (st == E_RWB) ? b_q : dbuf; assign m_be = 8'hFF;
    assign d_push = (st == E_PUSH) && b_space && act[cur];
    assign d_pop  = (st == E_POP) && a_avail && act[cur] && !lp;   // at most 1 byte every 2 clocks (the FIFO reads the next byte with 1 clock of delay)
    assign d_wd   = dbuf[7:0];
    assign boot_done = done[0];
    assign irq    = |(done & ie);
    assign io_sel = (io_a == PORT_STAT) || (io_a == PORT_IE) || (io_a == PORT_STAT2);
    wire irqp = |(done & ie);
    assign io_rd  = (io_a == PORT_IE)    ? {4'd0, ie} :
                    (io_a == PORT_STAT2) ? {1'b0, err[3], done[3], act[3], irqp, err[2], done[2], act[2]} :
                                           {1'b0, err[1], done[1], act[1], irqp, err[0], done[0], act[0]};
    function bad_f(input [1:0] m, input sb, input db, input sbf, input dbf);
        bad_f = (m == 2'd3) | ((m == 2'd0) & (sb | db)) | ((m == 2'd1) & sb) | ((m == 2'd2) & db)
              | ((m != 2'd0) & (sbf | dbf)) | (sbf & dbf);
    endfunction
    // CR index decoding: channel = idx/3, field = idx%3 (0 SRC, 1 DST, 2 CTRL)
    reg [1:0] cch; reg [1:0] cfd;
    always @* case (cr_idx)
        4'd0: begin cch = 0; cfd = 0; end 4'd1: begin cch = 0; cfd = 1; end 4'd2: begin cch = 0; cfd = 2; end
        4'd3: begin cch = 1; cfd = 0; end 4'd4: begin cch = 1; cfd = 1; end 4'd5: begin cch = 1; cfd = 2; end
        4'd6: begin cch = 2; cfd = 0; end 4'd7: begin cch = 2; cfd = 1; end 4'd8: begin cch = 2; cfd = 2; end
        4'd9: begin cch = 3; cfd = 0; end 4'd10: begin cch = 3; cfd = 1; end default: begin cch = 3; cfd = 2; end
    endcase
`ifdef R8064_DMA2
    // Tang Nano 20K build (does not fit with 4 channels): only channels 0 and 1 (CR19..CR24) exist; writes to CR25..CR30 are ignored and yosys removes channels 2 and 3.
    wire cr_ok = cr_we && cr_idx <= 4'd5;
`else
    wire cr_ok = cr_we && cr_idx <= 4'd11;
`endif
    wire go  = cr_ok && cfd == 2'd2 && cr_wd[31] && !act[cch];
    wire rsv = cr_wd[21] | (|cr_wd[62:32]);  // VIRT and high COUNT: reserved for 64 bits
    // offset + COUNT > 2048 words (16 KB): checked ONE CLOCK AFTER START, with registers only (off the cr_wd path, which arrives late from the core)
    reg        ovf_p; reg [1:0] ovf_c;
    wire [11:0] boff = w_src[ovf_c][20] ? {1'b0, w_src[ovf_c][10:0]} : {1'b0, w_dst[ovf_c][10:0]};
    wire        bovf = (w_src[ovf_c][20] | w_dst[ovf_c][20]) && (({1'b0, boff} + {1'b0, cnt[ovf_c]}) > 20'd2048);
    wire bad = rsv | bad_f(cr_wd[20:19], s_bad[cch], d_bad[cch], s_r[cch][20], d_r[cch][20]);
    wire z   = (cr_wd[18:0] == 19'd0);
    // next active channel in round-robin, starting from last+1
    wire [1:0] c1 = last + 2'd1, c2 = last + 2'd2, c3 = last + 2'd3;
    wire [1:0] nxt = act[c1] ? c1 : act[c2] ? c2 : act[c3] ? c3 : last;
    wire [1:0] mdn = md_r[nxt];
    // word completed on this clock: advances pointers and already chooses the next channel (without idle states)
    wire       fin = ((st == E_WWT) && m_done) || ((st == E_WRQ) && dbuf_b && b_ok) || direct_bw || ((st == E_PUSH) && act[cur] && b_space && k == 3'd7);
    wire [3:0] actf = last_w ? (act & ~(4'b0001 << cur)) : act;
    wire [1:0] f1 = cur + 2'd1, f2 = cur + 2'd2, f3 = cur + 2'd3;
    wire [1:0] fn = actf[f1] ? f1 : actf[f2] ? f2 : actf[f3] ? f3 : cur;
    wire       fany = |actf;
    wire [1:0] fmd = md_r[fn];
    wire [1:0] ioch = {(io_a == PORT_STAT2), 1'b0};     // base of the channel pair of the STAT port
    // REV47: dbuf in its own block, enabled only by the state (no longer behind 'fin', which depends on m_done/b_ok through the arbiter):
    // the 64-bit load enable was the critical path. Where 'fin' used to block the load (last word of E_RWT with direct_bw, last byte of E_PUSH),
    // loading anyway is harmless: the word is finished and dbuf is fully rewritten before its next use.
    always @(posedge clk) begin
        if (rst) dbuf <= 64'd0;
        else case (st)
            E_RWB:  dbuf <= b_q;
            E_RWT:  if (m_done) dbuf <= m_rd;
            E_PUSH: if (act[cur] && b_space) dbuf <= {8'd0, dbuf[63:8]};
            E_POP:  if (act[cur] && a_avail && !lp) dbuf <= {a_q, dbuf[63:8]};
            default: ;
        endcase
    end
    integer i;
    always @(posedge clk) begin
        if (rst) begin
            ovf_p <= 1'b0; ovf_c <= 2'd0; act <= 4'd0; done <= 4'd0; err <= 4'd0; ie <= 4'd0; st <= E_IDLE; cur <= 2'd0; last <= 2'd3; lp <= 1'b0; k <= 3'd0; inv <= 1'b0;
            s_bad <= 4'd0; d_bad <= 4'd0;
            for (i = 0; i < NCH; i = i + 1) begin s_r[i] <= 21'd0; d_r[i] <= 21'd0; w_src[i] <= 21'd0; w_dst[i] <= 21'd0; cnt[i] <= 19'd0; md_r[i] <= 2'd0; end
        end else begin
            inv <= 1'b0; lp <= d_pop;
            ovf_p <= go && !bad && !z; ovf_c <= cch;
            if (ovf_p && bovf && act[ovf_c]) begin act[ovf_c] <= 1'b0; done[ovf_c] <= 1'b1; err[ovf_c] <= 1'b1; end
            // ---- control register writes ----
            if (cr_ok && cfd == 2'd0) begin s_r[cch] <= {cr_wd[23], cr_wd[22:3]}; s_bad[cch] <= (|cr_wd[63:24]) | (cr_wd[23] & (|cr_wd[22:14])) | (cr_wd[23] & (|cr_wd[2:0])); end
            if (cr_ok && cfd == 2'd1) begin d_r[cch] <= {cr_wd[23], cr_wd[22:3]}; d_bad[cch] <= (|cr_wd[63:24]) | (cr_wd[23] & (|cr_wd[22:14])) | (cr_wd[23] & (|cr_wd[2:0])); end
            if (go) begin
                w_src[cch] <= s_r[cch]; w_dst[cch] <= d_r[cch]; cnt[cch] <= cr_wd[18:0]; md_r[cch] <= cr_wd[20:19]; done[cch] <= 1'b0; err[cch] <= 1'b0;
                if (bad) begin err[cch] <= 1'b1; done[cch] <= 1'b1; end
                else if (z) done[cch] <= 1'b1;
                else act[cch] <= 1'b1;
            end
            if (boot_clr) begin done[0] <= 1'b0; err[0] <= 1'b0; end
            if (boot_go) begin w_src[0] <= 21'h100000; w_dst[0] <= 21'd0; cnt[0] <= boot_cnt; md_r[0] <= 2'd0; done[0] <= 1'b0; err[0] <= 1'b0; act[0] <= 1'b1; end
            // ---- I/O ports ----
            if (io_we && io_a == PORT_IE) ie <= io_wd[3:0];
            if (io_we && (io_a == PORT_STAT || io_a == PORT_STAT2)) begin
                if (io_wd[0]) begin done[ioch] <= 1'b0; err[ioch] <= 1'b0; end
                if (io_wd[4]) begin done[ioch | 2'd1] <= 1'b0; err[ioch | 2'd1] <= 1'b0; end
                if (io_wd[1] && act[ioch]) begin act[ioch] <= 1'b0; done[ioch] <= 1'b1; err[ioch] <= 1'b1; inv <= 1'b1; end
                if (io_wd[5] && act[ioch | 2'd1]) begin act[ioch | 2'd1] <= 1'b0; done[ioch | 2'd1] <= 1'b1; err[ioch | 2'd1] <= 1'b1; inv <= 1'b1; end
            end
            // ---- transfer engine ----
            if (fin && act[cur]) begin
                if (md != 2'd2) w_src[cur] <= w_src[cur] + 21'd1;
                if (md != 2'd1) w_dst[cur] <= w_dst[cur] + 21'd1;
                cnt[cur] <= cnt[cur] - 19'd1;
                if (last_w) begin act[cur] <= 1'b0; done[cur] <= 1'b1; if (md != 2'd1) inv <= 1'b1; end
                last <= cur; k <= 3'd0;
                if (fany) begin cur <= fn; st <= (fmd == 2'd2) ? E_POP : E_RRQ; end else st <= E_IDLE;
            end else case (st)
                E_IDLE: if (act != 4'd0) begin cur <= nxt; k <= 3'd0; st <= (mdn == 2'd2) ? E_POP : E_RRQ; end
                E_RRQ: if (sbuf) begin if (b_ok) st <= E_RWB; end else if (m_acc) st <= E_RWT;
                E_RWB: begin k <= 3'd0; st <= !act[cur] ? E_NEXT : (rwb_w && m_acc) ? E_WWT : E_WRQ; end   // so MODO 0
                E_RWT: if (m_done) begin
                           k <= 3'd0;
                           st <= !act[cur] ? E_NEXT : (md == 2'd0) ? E_WRQ : E_PUSH;
                       end
                E_WRQ: if (!dbuf_b && m_acc) st <= E_WWT;
                E_WWT: if (m_done) st <= E_NEXT;   // only gets here with the channel aborted (otherwise 'fin')
                E_PUSH: if (!act[cur]) st <= E_NEXT;
                        else if (b_space) k <= k + 3'd1;
                E_POP:  if (!act[cur]) st <= E_NEXT;
                        else if (a_avail && !lp) begin k <= k + 3'd1; if (k == 3'd7) st <= E_WRQ; end
                E_NEXT: begin last <= cur; st <= E_IDLE; end   // only aborts (channel already inactive)
                default: st <= E_IDLE;
            endcase
        end
    end
`endif   // R8064_NO_DMA
endmodule
