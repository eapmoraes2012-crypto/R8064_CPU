// r8064_core_min.v - SYNTHESIZABLE MINIMAL CORE of the R8064 (skeleton to measure area/Fmax of the lean budget).
// It is NOT the final core: it executes a subset of micro-operations driven by a micro-operation ROM (uop.mem, 106 bits).
// What is REAL (structure and width): 32 B prefetch queue + 13-byte aligner, real ED decoder (ROM_A/ROM_B/ctrl), main page ROM,
//   uop ROM in BSRAM, 64x64 register file (BSRAM, 3 reads), register mapping (EXX/EX AF), immediate extraction, forwarding (X2/M/W) with
//   load-use interlock, 2-stage ALU (alu_prep/alu_core of module 01), address adder, branch-target adder, 64-bit LSU with
//   alignment/extension, flags, branch resolved in X2 (flushes the queue), 64-bit timer + interrupt.
// (The header above is from the first skeleton; since then the uops, chains, I/O, MMU interface, FPU and partial-write interlock were added.)
// REV50: the decoder is two overlapped stages (A: capture + ROMs + length; B: decoded candidate + issue). Issue floor: 1 uop every 4 clocks
//   (5 after load/IN/MUL-DIV-FPU), between instructions as well as inside a chain; before REV50 an instruction was only captured after the
//   previous one was issued (>= 8 clocks per instruction).
// REV51: static branch prediction in stage A (JP/JR/CALL, RET with a return stack, backward conditional), verified in X2; refetch after
//   instructions that write CRs / privileged ones.
module r8064_core_min #(
    parameter UOP_FILE   = "uop.mem",
    parameter MAINC_FILE = "mainctrl.mem"
)(
    input  wire        clk, rst, irq,
    output wire        i_req,
    output wire [63:0] i_addr,
    input  wire        i_ack,
    input  wire [63:0] i_rdata,
    output wire        d_req,
    output wire        d_we,
    output wire [63:0] d_addr,
    output wire [1:0]  d_size,
    output wire [63:0] d_wdata, output wire [7:0] d_be,
    input  wire        d_ack,
    input  wire [63:0] d_rdata,
    // translation exceptions (pulse aligned to the ack) and MMU/cache control (CR46..49)
    input  wire        i_flt, d_flt, input wire [2:0] i_cs, d_cs,
    output wire        cr_mmu_en, cr_mmu_user, output wire [7:0] cr_asid, output wire [19:0] cr_root,
    output wire        cr_fl_all, cr_fl_va_en, cr_fl_asid_en, output wire [63:0] cr_fl_va, output wire [7:0] cr_fl_asid, output wire cr_cinv,
    output wire        dma_cr_we, output wire [3:0] dma_cr_idx, output wire [63:0] dma_cr_wd,   // writes (MTCR/LDCR) to CR19..CR30 (bank indices 51..62) -> DMA
    output wire [63:0] dbg_pc,
    output wire [7:0]  dbg_f,
    output wire        dbg_sig,
    // timing governor (Z80/R800 modes): gov_go holds the issue; gov_* describe the candidate instruction
    input  wire        gov_go,
    input  wire        gov_wait,        // 1 = governed modes (Z80/R800): an extra decode phase for the timing table
    input  wire [7:0]  port_c,          // register C (port of the IN r,(C) / OUT (C),r forms), supplied by the wrapper
    output wire [2:0]  gov_page,
    output wire [7:0]  gov_op,
    output wire [7:0]  gov_port,
    output wire        gov_cv,
    output wire        gov_alt_ev,
    output wire        gov_boundary,
    output wire        io_we, io_re, output wire [7:0] io_a, io_wd, input wire [7:0] io_rdata,   // 8-bit I/O (IN/OUT)
    output wire [15:0] gov_pc,          // address of the candidate instruction
    output wire [3:0]  gov_len,         // length (bytes) of the candidate
    output wire        gov_dev,         // data access completed
    output wire [15:0] gov_daddr,
    output wire [1:0]  gov_dsize,
    output wire        gov_dwe
);
    // ============ address width ============
    // REV47: implemented address width (PC, fetch address, effective addresses, branch targets). Architecturally addresses are 64-bit;
    // with R8064_AW32 (Tang Nano 20K builds) only the low 32 bits are implemented: address arithmetic wraps modulo 2^32 and the high bits
    // read as 0 (PC pushed by CALL/INT, EPC, address results). Without the macro the core is the full 64-bit version.
`ifdef R8064_AW32
    localparam AW = 32;
`else
    localparam AW = 64;
`endif
    localparam [63:0] AMASK = (AW >= 64) ? 64'hFFFF_FFFF_FFFF_FFFF : ((64'd1 << AW) - 64'd1);
    // ============ global control ============
    wire hold;                    // M waiting for the data bus
    wire flush_br;                // taken branch (X2)
    wire irq_take;                // interrupt accepted
    reg iff2; reg [1:0] im; reg [7:0] ireg; reg irq_ent;   // im: 0/1 = RST 38h, 2 = vectored by I, 3 = legacy (jumps to 'vec', without pushing)
    wire irq_new = (im != 2'd3);
    reg [63:0] npc, epc;   // epc: PC saved on interrupt acceptance; only the testbenches read it (synthesis discards it)
    // REGISTERED flush (cuts flags -> condition -> flush -> reset of the whole front-end): a taken branch costs +1 clock
    // (REV50: pc_last removed - an younger instruction may already be issued when one faults in M; the PC travels with the uop: pc_x1..pc_m)
    reg c_en, c_user, c_te; wire ex_take_m; reg md_q, mdu_done; wire [7:0] mdu_f;   // declared here because they are used before the blocks that define them
    reg trap_q;                   // the candidate raises an exception instead of executing (privileged in user mode, not implemented, SCALL)
    reg [63:0] ex_pcd;            // PC of the instruction that faulted in M (EPC)
    wire ex_take, ex_take_d; reg ex_act; reg [1:0] exk; reg ex_isd, ex_we; reg [2:0] ex_cs;
    wire br_fl;
    wire redir; wire [5:0] r_pend; wire [63:0] p_tgt;   // REV51: predicted branch in stage A (defined with stage A)
    reg  serf_q; wire serf_fl;   // REV51: CR write / privileged instruction drained: refetch from the next instruction (translation, mode, ...)
    wire flush_raw = br_fl | (irq_take & ~irq_new) | ex_take | serf_fl;
    reg  flush_q; reg [63:0] flush_tgt_q;
    wire flush = flush_q;
    wire [63:0] flush_tgt = flush_tgt_q;
    wire [63:0] flush_tgt_raw;
    always @(posedge clk) begin
        if (rst) flush_q <= 1'b0; else flush_q <= flush_raw;
        flush_tgt_q <= flush_tgt_raw & AMASK;
    end
    reg  [63:0] dpc_q;
    reg  [7:0]  fl;
    wire [63:0] ldval;
    reg  [63:0] tmr, tcmp, vec; reg ie, irq_pend;

    // ============ F: fetch + 32-byte queue ============
    reg [63:0] qw0, qw1, qw2, qw3;
    reg [1:0]  wp;
    reg [5:0]  qcnt;
    reg [4:0]  qoff;
    reg [2:0]  skip;
    reg        drop, ireq_r;
    reg        ifp; reg [63:0] ifa; reg [2:0] ifc;     // pending fetch fault: word address and cause
    reg [63:0] fa;
    assign i_req  = ireq_r;
    assign i_addr = fa;
    wire consume; wire [3:0] clen;
    wire got = i_ack && ireq_r && !drop;
    wire [5:0] addn = got ? (6'd8 - {3'd0, skip}) : 6'd0;
    wire [5:0] subn = consume ? {2'd0, clen} : 6'd0;
    always @(posedge clk) begin
        if (rst) begin wp <= 0; qcnt <= 0; qoff <= 0; skip <= 0; drop <= 0; ireq_r <= 0; fa <= 64'd0; ifp <= 1'b0; ifa <= 64'd0; ifc <= 3'd0; end
        else if (flush) begin
            wp <= 0; qcnt <= 0; qoff <= {2'b00, flush_tgt[2:0]}; skip <= flush_tgt[2:0]; fa <= {flush_tgt[63:3], 3'b000};
            drop <= 1'b0; ireq_r <= 1'b0; ifp <= 1'b0;   // request may be withdrawn before the ack (the cache fetch interface accepts cancellation)
        end else if (redir) begin
            // REV51: predicted branch: fetch restarts at the target; the r_pend bytes of B/A stay counted just before it (never read again)
            wp <= 0; qcnt <= r_pend; qoff <= {2'b00, p_tgt[2:0]} - r_pend[4:0]; skip <= p_tgt[2:0]; fa <= {p_tgt[63:3], 3'b000} & AMASK;
            drop <= 1'b0; ireq_r <= 1'b0;
        end else begin
            if (i_ack && ireq_r) begin
                // REV48: back-to-back fetch: keep the request up if the queue will still have room for 8 more bytes (saves the re-request clock)
                ireq_r <= !drop && !i_flt && (qcnt + addn - subn <= 6'd24);
                if (drop) drop <= 1'b0;
                else begin
                    case (wp) 2'd0: qw0 <= i_rdata; 2'd1: qw1 <= i_rdata; 2'd2: qw2 <= i_rdata; default: qw3 <= i_rdata; endcase
                    wp <= wp + 2'd1; fa <= (fa + 64'd8) & AMASK; skip <= 3'd0;
                    if (i_flt && !ifp) begin ifp <= 1'b1; ifa <= fa; ifc <= i_cs; end
                end
            end else if (!ireq_r && !drop && qcnt <= 6'd24) ireq_r <= 1'b1;
            qcnt <= qcnt + addn - subn;
            if (consume) qoff <= qoff + {1'b0, clen};
        end
    end
    // aligner: 3 consecutive words starting at alo[4:3], then byte shift (alo[2:0]) -> 13-byte window.
    // REV50: alo = decode offset of stage A (the instruction being decoded, or the next one once its length is known); qoff = queue head
    // (first byte of the instruction in stage B). The bytes between qoff and alo stay in the queue until B consumes them.
    reg [4:0] alo;
    reg [191:0] rot;
    always @* case (alo[4:3])
        2'd0: rot = {qw2, qw1, qw0};
        2'd1: rot = {qw3, qw2, qw1};
        2'd2: rot = {qw0, qw3, qw2};
        default: rot = {qw1, qw0, qw3};
    endcase
    wire [191:0] shf = rot >> {alo[2:0], 3'b000};
    wire [103:0] win = shf[103:0];

    // ============ D: decoder in two overlapped stages (REV50) ============
    // Stage A (decode): capture of the window (win_q), prefix removal (dwa), ED decoder ROMs, main-page ROM, uop ROM read, length.
    // Stage B (issue): holds a COMPLETE decoded instruction (window, first uop, ED fields, PC, length); register indices, interlocks, issue.
    // A works on instruction N+1 while B waits to issue N: as soon as the length of A's instruction is known, the aligner moves to the
    // next one (alo), so the decode of consecutive instructions overlaps. Before REV50 the next instruction was only captured after the
    // last one was issued (>= 8 clocks per instruction); now the floor is set by B (4 clocks, 5 after a load / IN / MUL-DIV-FPU uop,
    // the same spacing as the uops of a chain, which the back end already handles).
    // Governed modes (Z80/R800): B waits >= 4 clocks with the candidate stable before the issue (timing table + classifier latency).
    reg         av;               // stage A holds an instruction (dwa)
    reg [2:0]   as;               // clocks since dwa was loaded (saturates at 7)
    reg         look;             // A's length is known and all its bytes are in dwa: the aligner points to the next instruction
    reg [103:0] dwa;              // A window, prefixes removed
    reg [103:0] win_q; reg wq_v;  // window snapshot (cuts the queue -> aligner -> decoder ROM path); wq_v: captured, waiting for dwa
    reg [4:0]   apos, cpos;       // queue offsets of A's instruction and of the captured one
    reg [63:0]  pca, cpc, npca;   // PCs: A's instruction, captured instruction, next one to capture
    reg [1:0]   xya, banka; reg is_eda, is_cba, irq_enta;
    reg         dv;               // stage B valid (candidate instruction)
    reg [2:0]   bs;               // clocks since B was loaded (saturates at 7)
    reg [103:0] dwin;             // B window
    reg [63:0]  dpc;              // address of the instruction in B
    reg [106:0] uB;               // first uop of the instruction in B
    reg         edb_ill, edb_bk, edb_l12, edb_md;   // ED decoder fields of B's instruction
    reg         pred_b; reg [63:0] ptgt_b;           // REV51: B's instruction was predicted taken to ptgt_b (fetch already redirected)
    // bank prefix: ED 0B (shadow) / ED 0E (N0-N3) / ED 0D (N4-N7) before an instruction of the ED page
    reg [1:0]   bank;             // 0 none, 1 shadow, 2 N0-N3, 3 N4-N7 (B)
    wire pfx_w = (win_q[7:0] == 8'hED) && (win_q[15:8] == 8'h0B || win_q[15:8] == 8'h0E || win_q[15:8] == 8'h0D);
    wire bank_on = (bank != 2'd0);
    wire banka_on = (banka != 2'd0);
    wire [7:0] b1 = dwin[7:0], b2 = dwin[15:8], b3 = dwin[23:16];          // B
    wire [7:0] a1 = dwa[7:0],  a2 = dwa[15:8],  a3 = dwa[23:16];           // A
    reg is_cb;                    // CB prefix: the uop comes from region 768 + second byte (B)
    // DD / FD prefix (IX / IY): removed from the window on capture, like the bank prefix. The instruction uses the SAME uop as the main page:
    // the HL index (3) becomes IX/IY (9/10), except in the marked operands (u[90]: D and B; u[91]: A), and the uops with u[92] add the displacement d to the address.
    // DD/FD followed by DD, FD or ED is not treated as a prefix (executes as a 1-byte NOP and the next byte starts another instruction).
    reg [1:0]   xy;               // 0 none, 1 IX, 2 IY (B)
    wire xy_on = (xy != 2'd0);
    wire xya_on = (xya != 2'd0);
    wire pfx_xy = (win_q[7:0] == 8'hDD || win_q[7:0] == 8'hFD) && !(win_q[15:8] == 8'hDD || win_q[15:8] == 8'hFD || win_q[15:8] == 8'hED);
    wire [103:0] dwin_n = pfx_w ? {8'h00, win_q[103:16], 8'hED} : pfx_xy ? {8'h00, win_q[103:8]} : win_q;
    reg is_ed;                    // B
    wire [9:0] ed_id; wire ed_ill; wire [3:0] ed_len; wire [4:0] ed_nr, ed_nw; wire [1:0] ed_nio; wire [7:0] ed_ex; wire [1:0] ed_pen; wire ed_hc, ed_z80, ed_bk;
    r8064_decode u_dec(.clk(clk), .b2(a2), .b3(a3), .id(ed_id), .illegal(ed_ill), .len(ed_len), .nr(ed_nr), .nw(ed_nw), .nio(ed_nio), .ex(ed_ex), .pen_code(ed_pen), .has_cond(ed_hc), .is_z80(ed_z80), .bankable(ed_bk));
    reg [31:0] mainc [0:255];
    reg [106:0] uopm  [0:2047];
    initial begin $readmemh(MAINC_FILE, mainc); $readmemh(UOP_FILE, uopm); end
    reg [31:0] mainc_q; reg [106:0] uop_q;
    // micro-operation sequencer: u[49]=more uops, u[62:52]=address of the next one. Space: main 0-255, ED 256+id, CB 768-1023, DDCB/FDCB 1792-2047, chains 1024-1791
    // The uop ROM has one port: B's chain (seq) has priority; A's first-uop read is repeated after the chain (u_mine says uop_q is A's).
    reg seq; reg [10:0] nxt_r; reg [2:0] seqc;
    wire [10:0] base_a = irq_enta ? (im == 2'd2 ? 11'd601 : 11'd600) : is_eda ? (11'd256 + {1'b0, ed_id}) : is_cba ? (xya_on ? {3'b111, a3} : {3'b011, a2}) : {3'b000, a1};   // DD CB d op: region 1792 + op
    wire [10:0] uaddr = seq ? nxt_r : base_a;
    always @(posedge clk) begin mainc_q <= mainc[a1]; uop_q <= uopm[uaddr]; end
    // A length: main page valid 1 clock after dwa (mainc_q), ED page 2 clocks after (control ROM); registered for B (clen)
    wire [3:0] clen_rawa = irq_enta ? 4'd0 : (is_eda ? (ed_ill ? 4'd2 : ed_len) : mainc_q[3:0]) + {3'd0, banka_on} + {3'd0, xya_on} + {3'd0, xya_on && mainc_q[4]};   // mainc[4]: operand (HL) -> +1 byte (d) with DD/FD
    reg [3:0] clen_ra; always @(posedge clk) clen_ra <= clen_rawa;
    wire len_ok = av && (irq_enta || (is_eda ? (as >= 3'd2) : (as >= 3'd1)));
    wire base_ok = av && (irq_enta || !is_eda || (as >= 3'd2));
    reg u_mine;                   // uop_q holds the first uop of A's instruction (A was not reloaded and the port was not used by a chain)
    wire a_load;
    reg [3:0] clen_r;
    assign clen = clen_r;
    reg ifx_q; reg [63:0] ifd_q; reg ifxa_q; reg [63:0] ifda_q;
    reg hz_q;   // partial-write interlock (see below)
    // bytes available in the queue from the aligner position (alo) and from A's instruction (apos); the dwa window lags 2 clocks (win -> win_q -> dwa)
    wire [4:0] adist = alo - qoff;
    wire signed [7:0] avl = $signed({2'b00, qcnt}) - $signed({3'b000, adist});
    wire [4:0] pdist = apos - qoff;
    wire signed [7:0] avp = $signed({2'b00, qcnt}) - $signed({3'b000, pdist});
    reg signed [7:0] avp1; always @(posedge clk) avp1 <= avp;
    // A complete: length known and all its bytes already in dwa (or a fetch fault near it: B then takes it and raises the exception)
    wire a_cmpl_now = len_ok && (avp1 >= $signed({4'd0, clen_rawa}));
    reg  acq;
    wire look_set = av && !look && a_cmpl_now;
    wire [106:0] u = seq ? uop_q : uB;      // the current uop: B's first, then the chain's (ROM output)
    wire b_ready = dv && (bs >= (gov_wait ? 3'd4 : 3'd2));
    reg  pipe_empty_q, issue_q;   // registered: empty pipeline / issue in the previous clock (defined with the X2 stage)
    reg [5:0] iA_q, iB_q, iD_q;   // registered register-file indices (defined with the issue fields)
    reg  ser_q;                   // the last issued instruction changes state read by later decode/issue (CR, mode, I/O, EI/DI/IM, EXX): wait for an empty pipeline
    reg  irq_arm_q;
    wire issue = b_ready && !hold && !flush && !(serf_q && !seq) && (gov_go || seq) && (seqc == 3'd0) && !hz_q && !(ifx_q && !seq) && !trap_q &&
                 !(!seq && (irq_arm_q || (ser_q && !(pipe_empty_q && !issue_q)))) && !((u[45] || u[46]) && !(pipe_empty_q && !issue_q));
    // EXX / EX AF,AF' switch the register map AT the issue: they wait until no older instruction can still fault (a fault restarts the older one)
    wire u_last = !u[49];
    assign consume = issue && u_last;
    wire xfer = av && u_mine && (acq || ifxa_q) && (irq_enta ? (as >= 3'd1) : is_eda ? (as >= 3'd3) : (as >= 3'd2)) && !dv;   // A -> B
    assign a_load = (irq_take && irq_new) || (wq_v && (!av || xfer));
    always @(posedge clk) u_mine <= !rst && !flush && base_ok && !seq && !a_load;
    always @(posedge clk) begin
        if (rst || flush) begin seq <= 1'b0; seqc <= 3'd0; end
        else begin
            if (seqc != 3'd0 && !hold) seqc <= seqc - 3'd1;   // only counts when the pipeline advances (a hold freezes the producers)
            // REV50: the same spacing applies between instructions: 4 clocks (X3/M forwarding); 5 after load/IN/MUL-DIV: the aligned data is only forwarded from W
            if (issue) seqc <= (u[10] && (u[8] || u[50] || u[98])) ? 3'd4 : 3'd3;
            if (issue && !u_last) begin seq <= 1'b1; nxt_r <= u[62:52]; end
            else if (issue) seq <= 1'b0;
        end
    end
    // ser_q: set by an instruction whose effect is read at decode/issue time by the next ones (CR writes, I/O incl. the mode port, EI/DI/RETN/IM,
    // privileged): the next instruction waits for an empty pipeline (as before REV50, when every instruction waited for the previous one)
    always @(posedge clk) begin
        if (rst || flush) ser_q <= 1'b0;
        else if (issue) ser_q <= (u[10] && iD_q[5]) || u[77] || (u[76:74] != 3'd0) || u[50] || u[51] || u[102] || u[104] || u[105];
        else if (pipe_empty_q && !issue_q) ser_q <= 1'b0;
    end
    // serf_q: the instruction may change how the next ones are fetched (MMU, privilege, mode): when it has left the pipeline, the front end
    // (prefetched bytes, stage A, B, predicted targets) is discarded and the fetch restarts at the next instruction (npc)
    always @(posedge clk) begin
        if (rst || flush) serf_q <= 1'b0;
        else if (issue && ((u[10] && iD_q[5]) || u[77] || u[102] || u[105]) && (u[76:74] == 3'd0)) serf_q <= 1'b1;   // (EI/DI/RETN/IM do not affect the fetch)
    end
    assign serf_fl = serf_q && !seq && pipe_empty_q && !issue_q && !flush_q && !ex_act;
    // ---- REV51: branch prediction in stage A (static) with verification in X2
    // Unprefixed Z80 opcodes, once A's bytes are complete: JP nn (C3), JR e (18), CALL nn (CD) always; RET (C9) from a 4-entry return stack;
    // JR cc,e / DJNZ e backward (e < 0) and JP cc,nn backward (nn <= PC) predicted taken. The fetch restarts at the predicted target at once
    // (the queue is rebased; the bytes of the instructions still in A/B stay counted as 'virtual' bytes before the target, consumed as usual).
    // The branch uop carries the prediction; X2 compares: taken to the same target = no flush, otherwise the normal flush (to the computed
    // target, or to the next instruction when a predicted branch is not taken). A wrong prediction therefore only costs the old penalty.
    wire        pfx_none = !is_eda && !is_cba && !xya_on && !banka_on && !irq_enta;
    wire [63:0] a_nx = (pca + {60'd0, clen_rawa}) & AMASK;                         // next sequential address of A's instruction
    wire [63:0] a_jr = (a_nx + {{56{a2[7]}}, a2}) & AMASK;                         // relative target
    wire [63:0] a_jp = {pca[63:16], a3, a2} & AMASK;                               // absolute 16-bit target (upper bits of the PC kept)
    reg  [63:0] ras [0:3]; reg [1:0] rsp; reg [2:0] rcnt;                         // return stack (prediction only)
    wire [63:0] ras_top = ras[rsp - 2'd1];
    wire p_jp  = pfx_none && (a1 == 8'hC3);
    wire p_jr  = pfx_none && (a1 == 8'h18);
    wire p_cl  = pfx_none && (a1 == 8'hCD);
    wire p_rt  = pfx_none && (a1 == 8'hC9) && (rcnt != 3'd0);
    wire p_jrc = pfx_none && (a1 == 8'h10 || a1 == 8'h20 || a1 == 8'h28 || a1 == 8'h30 || a1 == 8'h38) && a2[7];
    wire p_jpc = pfx_none && (a1[7:6] == 2'b11) && (a1[2:0] == 3'b010) && ({a3, a2} <= pca[15:0]);
    wire p_any = p_jp || p_jr || p_cl || p_rt || p_jrc || p_jpc;
    assign p_tgt = (p_jr || p_jrc) ? a_jr : p_rt ? ras_top : a_jp;
    assign redir = look_set && p_any && !ifp && !(irq_take && irq_new);                                          // (a pending fetch fault keeps the sequential path)
    reg  pred_a; reg [63:0] ptgt_a;
    // bytes of the instructions in B (not consumed in this clock) and in A that stay counted in the queue after the redirect
    assign r_pend = ((dv && !consume) ? {2'd0, clen} : 6'd0) + {2'd0, clen_rawa};
    always @(posedge clk) begin
        if (rst) begin rsp <= 2'd0; rcnt <= 3'd0; end
        else if (redir && p_cl) begin ras[rsp] <= a_nx; rsp <= rsp + 2'd1; if (rcnt != 3'd4) rcnt <= rcnt + 3'd1; end
        else if (redir && p_rt) begin rsp <= rsp - 2'd1; rcnt <= rcnt - 3'd1; end
    end
    // ---- stage A
    always @(posedge clk) begin
        if (rst || flush) begin
            av <= 1'b0; wq_v <= 1'b0; look <= 1'b0; acq <= 1'b0; irq_enta <= 1'b0; xya <= 2'd0; banka <= 2'd0; is_eda <= 1'b0; is_cba <= 1'b0;
            alo <= rst ? 5'd0 : {2'b00, flush_tgt[2:0]}; npca <= rst ? 64'd0 : flush_tgt;
        end else if (irq_take && irq_new) begin
            // interrupt entry: pseudo-instruction (opcode FF for the governor) that pushes the PC and jumps (IM0/1: 0038h; IM2: [I:FF]).
            // The candidate in B (not issued) is discarded; A restarts at the queue head (B's instruction, PC = npc).
            irq_enta <= 1'b1; av <= 1'b1; as <= 3'd0; wq_v <= 1'b0; look <= 1'b0; acq <= 1'b1; pca <= npc; npca <= npc; pred_a <= 1'b0; is_eda <= 1'b0; is_cba <= 1'b0; banka <= 2'd0; xya <= 2'd0;
            apos <= qoff; alo <= qoff;
            dwa <= (im == 2'd2) ? {72'd0, ireg, 8'hFF, 8'hFF} : {80'd0, 16'h0038, 8'hFF};   // IM2: bytes 1..2 = [I:FF]
        end else begin
            if (av && as != 3'd7) as <= as + 3'd1;
            // capture: the opcode bytes are in (4: prefix + ED/CB + 2 bytes); with A busy, only after A's length is known (look)
            if (!wq_v && (!av || look) && avl >= 8'sd4) begin win_q <= win; wq_v <= 1'b1; cpos <= alo; cpc <= npca; end
            else if (av && !look && !irq_enta) win_q <= win;     // window refresh while A's trailing bytes are still arriving
            if (av && !look && !irq_enta) dwa <= dwin_n;
            if (redir) begin alo <= {2'b00, p_tgt[2:0]}; npca <= p_tgt; look <= 1'b1; pred_a <= 1'b1; ptgt_a <= p_tgt; end
            else if (look_set) begin alo <= apos + {1'b0, clen_rawa}; npca <= a_nx; look <= 1'b1; end
            acq <= av && (acq || a_cmpl_now);
            if (wq_v && (!av || xfer)) begin
                dwa <= dwin_n;   // removes the bank prefix (ED <pfx> op ... -> ED op ...) or the DD/FD
                xya <= !pfx_xy ? 2'd0 : (win_q[7:0] == 8'hDD) ? 2'd1 : 2'd2;
                banka <= pfx_w ? ((win_q[15:8] == 8'h0B) ? 2'd1 : (win_q[15:8] == 8'h0E) ? 2'd2 : 2'd3) : 2'd0;
                is_eda <= (win_q[7:0] == 8'hED);
                is_cba <= pfx_xy ? (win_q[15:8] == 8'hCB) : (win_q[7:0] == 8'hCB);
                irq_enta <= 1'b0; wq_v <= 1'b0; av <= 1'b1; as <= 3'd0; look <= 1'b0; acq <= 1'b0; apos <= cpos; pca <= cpc; pred_a <= 1'b0;
            end else if (xfer) begin av <= 1'b0; look <= 1'b0; acq <= 1'b0; irq_enta <= 1'b0; end
        end
    end
    // ---- stage B
    always @(posedge clk) begin
        if (rst || flush || (irq_take && irq_new)) begin dv <= 1'b0; irq_ent <= 1'b0; xy <= 2'd0; end
        else if (xfer) begin
            dv <= 1'b1; bs <= 3'd0; dwin <= dwa; uB <= uop_q; dpc <= pca; clen_r <= clen_ra; pred_b <= pred_a; ptgt_b <= ptgt_a;
            is_ed <= is_eda; is_cb <= is_cba; xy <= xya; bank <= banka; irq_ent <= irq_enta;
            edb_ill <= ed_ill; edb_bk <= ed_bk; edb_l12 <= (ed_len > 4'd12); edb_md <= (ed_id == 10'd13) || (ed_id == 10'd17) || (ed_id == 10'd24) || (ed_id == 10'd30);
        end else begin
            if (dv && bs != 3'd7) bs <= bs + 3'd1;
            if (consume) begin dv <= 1'b0; irq_ent <= 1'b0; end
        end
    end
    // PC counter (address of the next instruction)
    always @(posedge clk) begin
        if (rst) dpc_q <= 64'd0;
        else if (flush) dpc_q <= flush_tgt;
        else if (consume) dpc_q <= pred_b ? ptgt_b : (dpc + {60'd0, clen}) & AMASK;
    end

    // ============ issue: fields, registers, immediate ============
    reg sw_main, sw_af;
    wire f_pos = u[20];
    wire [7:0] fb = is_ed ? b3 : b1;          // ED page: register fields come from the modifier byte (b3)
    wire [2:0] rrD = f_pos ? fb[5:3] : fb[2:0];
    wire [2:0] rrA = f_pos ? fb[2:0] : fb[5:3];
    wire [2:0] rrB = u[100] ? b2[5:3] : is_ed ? b3[2:0] : b2[2:0];   // u[100]: field in the 2nd byte (MLTUB A,r do R800: ED C1..F9; PGINV)
    wire [5:0] mD, mA, mB; wire vD, vA, vB;
    regmap_b u_md(.rr(rrD), .swap_main(sw_main), .swap_af(sw_af), .bank(bank), .idx(mD), .valid(vD));
    regmap_b u_ma(.rr(rrA), .swap_main(sw_main), .swap_af(sw_af), .bank(bank), .idx(mA), .valid(vA));
    regmap_b u_mb(.rr(rrB), .swap_main(sw_main), .swap_af(sw_af), .bank(bank), .idx(mB), .valid(vB));
    // illegal banked instruction: illegal id, no bankable operand, 8-bit operand in bank N, IX/IY in bank, or prefix + 13 bytes
    wire bank_ill = bank_on && (edb_ill || !edb_bk || (bank[1] && u[6:5] == 2'd0) || edb_l12 ||
                                (u[17] && !vD) || (u[18] && !vA) || (u[19] && !vB));
    // REV47: R8064_NO_MD64 (Tang Nano 20K builds): DIVSQ (13), DIVUQ (17), MLTSQ (24), MLTUQ (30) are not implemented -> treated as illegal
    // (unimplemented-instruction exception, cause 7, if CR14.TE = 1; otherwise skipped like a NOP of the instruction's own length)
`ifdef R8064_NO_MD64
    wire md64_ill = edb_md;
`else
    wire md64_ill = 1'b0;
`endif
    wire en_ill = is_ed && (edb_ill || bank_ill || md64_ill);   // illegal (exception: in this skeleton it becomes a NOP without write)
    wire [5:0] crn = u[101] ? {1'b1, b3[7:3]} : {1'b1, b3[4:0]};   // u[101]: LDCR/STCR (CR in b3[7:3], register in b3[2:0])
    //         // MTCR/MFCR: CR n = register-file index 32+n (ED 0A n = MFCR, ED 0C n = MTCR)
    // EXPLICIT uop indices (0 AX, 1 BC, 2 DE, 3 HL) also obey EXX / EX AF,AF' (before only the rr fields obeyed: LDIR after EXX used the wrong group)
    function [5:0] xsw(input [5:0] i, input sm, input sa, input [1:0] ix);   // sm/sa/ix as arguments: the function is re-evaluated when the swap changes
        xsw = (i == 6'd3 && ix != 2'd0) ? (ix == 2'd1 ? 6'd9 : 6'd10) :
              (i == 6'd0) ? (sa ? 6'd5 : 6'd0) : (i >= 6'd1 && i <= 6'd3 && sm) ? (i + 6'd5) : i;
    endfunction
    wire [1:0] xy_db = u[90] ? 2'd0 : xy, xy_a = u[91] ? 2'd0 : xy;
    // u[95]: the destination field is an 8-bit register with the Z80 r code (B C D E H L - A): pair BC/DE/HL/AX + high byte for B, D, H (SARB/SHLB/SHRB u)
    wire [5:0] r8i = (rrD == 3'd7) ? 6'd0 : {4'd0, rrD[2:1]} + 6'd1;
    wire       r8h = u[95] && (rrD != 3'd7) && !rrD[0];
    wire [5:0] iD = u[77] ? crn : u[95] ? xsw(r8i, sw_main, sw_af, 2'd0) : u[17] ? mD : xsw(u[26:21], sw_main, sw_af, xy_db);
    wire [5:0] jui = (b2[1:0] == 2'd3) ? 6'd0 : {4'd0, b2[1:0]} + 6'd1;      // u[105]: JP USER,(uu): ED B4 BC, B5 DE, B6 HL, B7 AX
    wire [5:0] iA = u[47] ? iD : u[78] ? crn : u[105] ? xsw(jui, sw_main, sw_af, 2'd0) : (u[18] ? mA : xsw(u[32:27], sw_main, sw_af, xy_a));   // u[47]: source A = destination (2 operands)
    // u[99]: source B is an 8-bit register with the Z80 r code (MLTxB, DIVxB)
    wire [5:0] r8bi = (rrB == 3'd7) ? 6'd0 : {4'd0, rrB[2:1]} + 6'd1;
    wire       r8bh = u[99] && (rrB != 3'd7) && !rrB[0];
    wire [5:0] iB = u[99] ? xsw(r8bi, sw_main, sw_af, 2'd0) : u[19] ? mB : xsw(u[38:33], sw_main, sw_af, xy_db);
    // registered indices (stable >= 1 clock before issue): takes uop ROM -> regmap -> register file address off the same cycle
    // u[96]: the branch condition comes from the Z80 cc field in b3[5:3] (NZ Z NC C PO PE P M); u[97]: uses the OPPOSITE condition (skip branch of CALL cc / RET cc)
    wire [2:0] ccf = fb[5:3] ^ {2'b00, u[97]};                    // opposite = swaps bit 0 of the code
    wire [3:0] ccm = (ccf == 3'd0) ? 4'b0010 : (ccf == 3'd1) ? 4'b0001 : (ccf == 3'd2) ? 4'b0100 : (ccf == 3'd3) ? 4'b0011 :
                     (ccf == 3'd4) ? 4'b0110 : (ccf == 3'd5) ? 4'b0101 : (ccf == 3'd6) ? 4'b1000 : 4'b0111;   // {condx, cond}
    reg [106:0] u_iss;
    always @* begin
        u_iss = u;
        if (u[96]) begin u_iss[14:12] = ccm[2:0]; u_iss[81] = ccm[3]; end
        if (r8h)   begin u_iss[48] = 1'b1; u_iss[72] = 1'b1; end
        if (r8bh)  u_iss[80] = 1'b1;
    end
    always @(posedge clk) begin iA_q <= iA; iB_q <= iB; iD_q <= iD; end
    // REV47: a single shift amount (2 bytes with DD/FD + u[93]) and one shifter (before: two 104-bit shifters and a mux)
    wire [2:0] isa = (xy_on && u[93]) ? 3'd2 : u[41:39];
    wire [103:0] ishw = dwin >> {isa, 3'b000}; wire [63:0] ish = ishw[63:0];   // u[93]: with DD/FD the immediate comes after the displacement (LD (IX+d),n)
    reg [63:0] immv;
    always @* case (u[43:42])
        2'd0: immv = u[44] ? {{56{ish[7]}},  ish[7:0]}  : {56'd0, ish[7:0]};
        2'd1: immv = u[44] ? {{48{ish[15]}}, ish[15:0]} : {48'd0, ish[15:0]};
        2'd2: immv = u[44] ? {{32{ish[31]}}, ish[31:0]} : {32'd0, ish[31:0]};
        default: immv = ish[63:0];
    endcase
    always @(posedge clk) begin
        if (rst) begin sw_main <= 0; sw_af <= 0; end
        else if (issue) begin
            if (u[45] && u[46]) begin sw_main <= 1'b0; sw_af <= 1'b0; end  // EXINI (exx+exaf together): back to the reset state: main group AND AF (undoes EXX and EX AF,AF')
            else begin if (u[45]) sw_main <= ~sw_main; if (u[46]) sw_af <= ~sw_af; end
        end
    end

    // ============ register file (3 reads: A, B and the old destination value) ============
    reg         pr_xr, pr_x1, pr_x2; reg [63:0] pt_xr, pt_x1, pt_x2, pcn_x2;   // REV51: predicted branch and its target
    reg         v_xr; reg [106:0] u_xr; reg [63:0] pcn_xr, imm_xr, pc_xr; reg [5:0] a_xr, b_xr, d_xr; reg [4:0] ob3_xr; reg xyd_xr; reg [7:0] dsp_xr;
    // under hold the XR stage stays stalled: the read address becomes its own (a_xr/b_xr/d_xr), otherwise the synchronous register file output would follow the next candidate
    wire [63:0] rf_a, rf_b, rf_d;
    wire        w_we; wire [5:0] w_addr; wire [63:0] w_data;
    regfile64 u_rf1(.clk(clk), .we(w_we), .waddr(w_addr), .wdata(w_data), .raddr_a(hold ? a_xr : iA_q), .raddr_b(hold ? b_xr : iB_q), .rdata_a(rf_a), .rdata_b(rf_b));
    regfile64_d u_rf2(.clk(clk), .we(w_we), .waddr(w_addr), .wdata(w_data), .raddr_a(hold ? d_xr : iD_q), .rdata_a(rf_d));   // REV49: 3rd read port in LUT RAM (frees 2 BSRAM)

    // ============ XR: read + forwarding ============
    wire        flush_x = flush;
    always @(posedge clk) begin
        if (rst || flush_x) v_xr <= 0;
        else if (!hold) begin
            v_xr <= issue && !en_ill; u_xr <= u_iss; pr_xr <= pred_b && u[11]; pt_xr <= ptgt_b; imm_xr <= u[63] ? 64'd0 : immv; pcn_xr <= (dpc + {60'd0, clen}) & AMASK; pc_xr <= dpc; a_xr <= iA_q; b_xr <= iB_q; d_xr <= iD_q; ob3_xr <= (u[43:42] == 2'd0) ? {2'b00, ish[5:3]} : (u[43:42] == 2'd1) ? {1'b0, ish[6:3]} : ish[7:3]; xyd_xr <= xy_on && u[92]; dsp_xr <= dwin[15:8];
        end
    end
    // X2 / M / W produce the values to forward
    reg [63:0] st_x1, old_x1;   // write data / old destination value accompany the instruction in X1 (before they were overwritten every clock)
    reg         v_x1; reg [106:0] u_x1; reg [63:0] opa_x1, opb_x1, imm_x1, pcn_x1, pc_x1; reg [5:0] d_x1;
    reg [63:0]  pc_x2, pc_x3, pc_m;   // REV50: PC of the instruction in each stage (EPC of a fault in M)
        reg         v_x2; reg [106:0] u_x2; reg [63:0] xa_x2, yb_x2, yy_x2, addr_x2, tgt_x2, st_x2, old_x2; reg ci_x2; reg [21:0] ctl_x2; reg [5:0] d_x2;
    reg         v_m;  reg [106:0] u_m;  reg [63:0] res_m, addr_m, st_m, old_m; reg [5:0] d_m; reg dn_m;
    reg         v_w;  reg [106:0] u_w;  reg [63:0] res_w; reg [5:0] d_w;
    // 2-stage ALU: A in X2 (low 32-bit sum), B in X3 (high 32-bit sum + flags). Result/flags valid in stage X3.
    reg         v_x3; reg [106:0] u_x3; reg [63:0] addr_x3, st_x3, old_x3; reg [5:0] d_x3;
    wire [63:0] x3_res; wire [7:0] x3_f; wire x3_hc12; wire [1:0] x3_xa53;
    alu_core_s u_core(.clk(clk), .en(!hold), .xa(xa_x2), .yb(yb_x2), .yy(yy_x2), .ci(ci_x2), .ctl(ctl_x2), .sz(u_x2[6:5]), .fin(fl), .res(x3_res), .fout(x3_f), .xa53(x3_xa53), .hc12(x3_hc12));
    // forwarding: X3 (ALU) > M (ALU result/address: res_m) > W (res_w, already with the aligned load data).
    // LOAD/IN data is never forwarded from M (the 64-bit aligner + sign extension was in the middle of the path): the hz interlock waits for the load to arrive in W.
    // forwarding selectors PRE-COMPUTED in the previous clock (comparators off the critical XR -> X1 path).
    // Since instructions are issued >=4 clocks apart, the producer in X3 never coincides with the consumer in XR: the X3 branch was removed.
    wire [5:0]  nx_a = (rst || flush_x || hold) ? a_xr : iA_q;
    wire [5:0]  nx_b = (rst || flush_x || hold) ? b_xr : iB_q;
    wire        nx_vm  = rst ? 1'b0 : ex_take_d ? 1'b0 : hold ? v_m : v_x3;
    wire        nx_m_wr = nx_vm && (hold ? u_m[10] : u_x3[10]);
    wire [5:0]  nx_dm  = hold ? d_m : d_x3;
    wire        nx_vw  = rst ? 1'b0 : ex_act ? 1'b1 : (v_m && !hold && !ex_take_d);
    wire        nx_w_wr = nx_vw && (ex_act ? 1'b1 : u_m[10]);
    wire [5:0]  nx_dw  = ex_act ? ((exk == 2'd0) ? 6'd44 : (exk == 2'd1) ? 6'd43 : (exk == 2'd2) ? 6'd45 : 6'd50) : d_m;
    reg sm_a, sw_a, sm_b, sw_b;
    always @(posedge clk) begin
        sm_a <= nx_m_wr && (nx_dm == nx_a);
        sw_a <= nx_w_wr && (nx_dw == nx_a) && !(nx_m_wr && (nx_dm == nx_a));
        sm_b <= nx_m_wr && (nx_dm == nx_b);
        sw_b <= nx_w_wr && (nx_dw == nx_b) && !(nx_m_wr && (nx_dm == nx_b));
    end
    wire [63:0] fa_a = sm_a ? res_m : sw_a ? res_w : rf_a;
    wire [63:0] fa_b = sm_b ? res_m : sw_b ? res_w : rf_b;
    // load-use interlock: instruction in XR depends on a load in X1/X2/M -> hold in XR
    wire ld_dep = v_xr && ((v_x3 && u_x3[8] && u_x3[10] && (d_x3 == a_xr || d_x3 == b_xr)) ||
                           (v_x1 && u_x1[8] && u_x1[10] && (d_x1 == a_xr || d_x1 == b_xr)) ||
                           (v_x2 && u_x2[8] && u_x2[10] && (d_x2 == a_xr || d_x2 == b_xr)) ||
                           (v_m  && u_m[8]  && u_m[10]  && (d_m  == a_xr || d_m  == b_xr)));
    // (ld_dep is not used to stall in this 1-instruction-every-4-clocks skeleton, but the comparator is counted in the area)
    reg ld_dep_q; always @(posedge clk) ld_dep_q <= ld_dep;

    // ============ X1: selects B operands/immediate; AGU and branch target ============
    // constant immediate -(1<<isz) (uop[79], PUSH/CALL/INT): chosen here, from the registered u_xr, and not at the uop ROM output (BSRAM -> imm_xr path was the critical one)
    // u[88:87] = immediate derived from the byte pointed to by ioff: 1 = RST vector (n*8) | 2 = bit mask (1<<n) | 3 = inverted mask.
    // n = bits [5:3] (isz = 0: Z80), [6:3] (isz = 1: BITW/RESW/SETW) ou [7:3] (isz = 2: BITL/RESL/SETL)
    wire [63:0] bitm_xr = 64'd1 << ob3_xr;
    wire [63:0] immk_xr = xyd_xr ? {{56{dsp_xr[7]}}, dsp_xr} :      // (IX+d) / (IY+d)
                          u_xr[79] ? (64'hFFFF_FFFF_FFFF_FFFF << u_xr[43:42]) :
                          (u_xr[88:87] == 2'd1) ? {58'd0, ob3_xr[2:0], 3'b000} : (u_xr[88:87] == 2'd2) ? bitm_xr : (u_xr[88:87] == 2'd3) ? ~bitm_xr : imm_xr;
    // operand B: u[89] = flags (F) | u[80] = register >> 8 (high byte: B, D, H)
    wire [63:0] fb_b = u_xr[89] ? {56'd0, fl} : u_xr[80] ? (fa_b >> 8) : fa_b;
    always @(posedge clk) begin
        if (rst || flush) v_x1 <= 0;
        else if (!hold) begin
            v_x1 <= v_xr; u_x1 <= u_xr; opa_x1 <= u_xr[72] ? (fa_a >> 8) : fa_a; opb_x1 <= u_xr[7] ? immk_xr : fb_b; imm_x1 <= immk_xr; pcn_x1 <= pcn_xr; pc_x1 <= pc_xr; d_x1 <= d_xr; pr_x1 <= pr_xr; pt_x1 <= pt_xr;
            st_x1 <= u_xr[65] ? pcn_xr : fb_b; old_x1 <= rf_d;
        end
    end
    wire [63:0] xa, yb, yy; wire ci; wire [21:0] ctl;
    alu_prep u_prep(.a(opa_x1), .b(opb_x1), .op(u_x1[4:0]), .sz(u_x1[6:5]), .fin(fl), .xa(xa), .yb(yb), .yy(yy), .ci(ci), .ctl(ctl));
    always @(posedge clk) begin
        if (rst || flush) v_x2 <= 0;
        else if (!hold) begin
            v_x2 <= v_x1; u_x2 <= u_x1; xa_x2 <= xa; yb_x2 <= yb; yy_x2 <= yy; ci_x2 <= ci; ctl_x2 <= ctl; d_x2 <= d_x1;
            st_x2 <= st_x1; old_x2 <= old_x1; pc_x2 <= pc_x1; pr_x2 <= pr_x1; pt_x2 <= pt_x1; pcn_x2 <= pcn_x1;
            addr_x2 <= (opa_x1 + imm_x1) & AMASK;
            tgt_x2 <= (u_x1[70] ? pc_x1 : u_x1[66] ? (opa_x1 + imm_x1) : u_x1[15] ? (pcn_x1 + imm_x1) : opa_x1) & AMASK;
        end
    end

    // flag fusion of block instructions: u[69:68] = 0 normal ALU | 1 only PV := (res != 0) | 2 S,Z,H,N from the ALU (keeps PV and C) | 3 PV := (res != 0), H = N = 0
    wire [63:0] szm = (u_x3[6:5] == 2'd0) ? 64'hFF : (u_x3[6:5] == 2'd1) ? 64'hFFFF : (u_x3[6:5] == 2'd2) ? 64'hFFFF_FFFF : 64'hFFFF_FFFF_FFFF_FFFF;
    wire nzres = |(x3_res & szm);
    reg [7:0] f_new0; wire [7:0] f_leg = {f_new0[7:3], (u_x3[76:74] == 3'd7) ? iff2 : f_new0[2], f_new0[1], u_x3[73] ? fl[0] : f_new0[0]};   // u[73]: keeps C (IN r,(C))
    // u[85:82] = fop: Z80 flag rules that do not come directly from the ALU (0 = previous behavior)
    reg [7:0] f_new;
    always @* case (u_x3[84:82])
        4'd1: f_new = {fl[7:6], x3_res[5], 1'b0, x3_res[3], fl[2], 1'b0, x3_f[0]};                 // RLCA/RRCA/RLA/RRA: only C, H=N=0, X/Y of the result
        4'd2: f_new = {fl[7:6], x3_res[13], x3_hc12, x3_res[11], fl[2], 1'b0, x3_f[0]};            // ADD HL,rr: C, H (bit 11), N=0, X/Y of the high byte
        4'd3: f_new = {x3_f[7:6], x3_res[13], x3_hc12, x3_res[11], x3_f[2:0]};                     // ADC/SBC HL,rr: all of them, H and X/Y from the high byte
        4'd4: f_new = {fl[7:6], x3_res[5], 1'b0, x3_res[3], fl[2], 1'b0, 1'b1};                    // SCF (result = A)
        4'd5: f_new = {fl[7:6], x3_res[5], fl[0], x3_res[3], fl[2], 1'b0, ~fl[0]};                 // CCF (result = A)
        4'd7: f_new = {x3_f[7:6], x3_xa53[1], 1'b1, x3_xa53[0], x3_f[6], 1'b0, fl[0]};               // BIT n,r (AND with the mask): S/Z of the result, PV = Z, X/Y of the operand
        4'd6: f_new = x3_res[7:0];                                                                 // F := result (POP AF)
        default: f_new = f_leg;
    endcase
    always @* case (u_x3[69:68])
        2'd0: f_new0 = x3_f;
        2'd1: f_new0 = {fl[7:3], nzres, fl[1:0]};
        2'd2: f_new0 = {x3_f[7:3], fl[2], x3_f[1], fl[0]};
        default: f_new0 = {fl[7:5], 1'b0, fl[3], nzres, 1'b0, fl[0]};
    endcase
    // ============ X2: ALU (core), flags, branch ============
    wire [7:0] f = fl;
    reg cond_ok0;
    always @* case (u_x2[14:12])
        3'd0: cond_ok0 = 1'b1;
        3'd1: cond_ok0 = f[6];
        3'd2: cond_ok0 = !f[6];
        3'd3: cond_ok0 = f[0];
        3'd4: cond_ok0 = !f[0];
        3'd5: cond_ok0 = f[2];
        3'd6: cond_ok0 = !f[2];
        default: cond_ok0 = f[7];
    endcase
    // u[81] = extended conditions: 0 = P (S=0) | 1 = tz (zero result of the uop marked with u[86]; DJNZ does not change flags) | 2 = not-tz
    reg tz;
    wire cond_x = (u_x2[14:12] == 3'd0) ? !f[7] : (u_x2[14:12] == 3'd1) ? tz : !tz;
    wire cond_ok = u_x2[81] ? cond_x : u_x2[71] ? (f[2] && !f[6]) : cond_ok0;     // u[71]: PV and not-Z (CPIR/CPDR)
    // REV51: flush_br = taken branch (also when predicted, for the testbenches); br_fl = the front-end must be redirected (not predicted and
    // taken, or predicted and not taken / other target)
    wire br_x2 = v_x2 && !flush_q && u_x2[11] && !hold;
    assign flush_br = br_x2 && cond_ok;
    assign br_fl = br_x2 && (pr_x2 ? (!cond_ok || (tgt_x2 != pt_x2)) : cond_ok);
    // empty pipeline and 'issue' of the previous cycle registered (takes the conjunction of the v_* off the interrupt path); the issue_q term covers the cycle in which the registered empty is still late
    always @(posedge clk) begin pipe_empty_q <= !v_xr && !v_x1 && !v_x2 && !v_x3 && !v_m && !v_w; issue_q <= issue; end
    // EI only takes effect after the following instruction: ei_cnt = 1 after the EI leaves the decoder; any other completed instruction clears it
    reg ei_cnt;
    reg serf_fq; always @(posedge clk) serf_fq <= serf_fl && !ex_take;   // the flush of this clock is a refetch (keeps the EI delay)
    always @(posedge clk) begin
        if (rst || (flush && !serf_fq)) ei_cnt <= 1'b0;
        else if (consume) ei_cnt <= (u[76:74] == 3'd1) && !irq_ent;
    end
    // irq_arm_q: slow part of the condition (pending INT, IE, EI delay) registered; the 1-clock delay is covered by flush_q / dv (INT and exception entry) and by the pipeline being empty
    always @(posedge clk) irq_arm_q <= rst ? 1'b0 : (irq_pend && ie && !ei_cnt);
    // REV50: B may hold a candidate (discarded; the issue stops while irq_arm_q). irq_enta / irq_ent: the entry already started (irq_arm_q is 1 clock late)
    assign irq_take = irq_arm_q && !flush_q && pipe_empty_q && !issue_q && !seq && !c_user && !irq_enta && !irq_ent && !serf_q;   // hold implies v_m (pipe_empty_q = 0)
    assign flush_tgt_raw = (br_x2 && !ex_take) ? (cond_ok ? tgt_x2 : pcn_x2) : (serf_fl && !ex_take) ? npc : vec;
    // PC of the next instruction (architectural) and PC saved on interrupt. In a repeated block (LDIR...) the branch to its own PC
    // leaves npc = PC of the instruction, so the interrupt between iterations resumes exactly the repeat (BC/HL/DE already updated).
    always @(posedge clk) begin
        if (rst) begin npc <= 64'd0; epc <= 64'd0; end
        else begin
            if (irq_take) epc <= npc;
            if (flush_q) npc <= flush_tgt; else if (consume) npc <= pred_b ? ptgt_b : (dpc + {60'd0, clen}) & AMASK;
        end
    end
    // F' (EX AF,AF' also swaps the flags; EXINI = exx+exaf together goes back to the main F). The swap travels in the pipeline (X3), in order with the flag writes.
    reg [7:0] fl2; reg sw_f;
    always @(posedge clk) begin
        if (rst) begin fl <= 8'd0; fl2 <= 8'd0; sw_f <= 1'b0; tz <= 1'b0; end
        else if (v_x3 && !hold) begin
            if (u_x3[46] && (!u_x3[45] || sw_f)) begin fl <= fl2; fl2 <= fl; sw_f <= u_x3[45] ? 1'b0 : ~sw_f; end
            else if (u_x3[16] && !u_x3[98]) fl <= f_new;   // u[98] (MLT/DIV): the flags come from the unit, further below
            if (md_q && mdu_done && u_m[16] && !ex_take_m) fl <= mdu_f;      // MLT/DIV: flags when the uop that triggered leaves M (hold = 0 in this clock)
            if (u_x3[86]) tz <= !nzres;
        end
        else if (!rst && md_q && mdu_done && u_m[16] && !ex_take_m) fl <= mdu_f;
    end
    // X3: second half of the ALU (the data below only crosses the stage)
    always @(posedge clk) begin
        if (rst) v_x3 <= 0;
        else if (!hold) begin
            v_x3 <= v_x2 && !flush_q && !ex_take; u_x3 <= u_x2; d_x3 <= d_x2; pc_x3 <= pc_x2; addr_x3 <= addr_x2; st_x3 <= st_x2; old_x3 <= old_x2;
        end
    end

    // partial-write interlock: an in-flight uop that PARTIALLY writes a register (8/16/32 bits without zero-extension, or high byte) leaves the
    // complete value only in W; the consumer (read of A/B, or merge of the old destination) would wait for an incomplete/old value. Blocks issue while there is a
    // partial producer for the same register, and also any in-flight producer when the new uop is partial to the same destination (WAW). Registered: consecutive
    // uops are >= 4 clocks apart, so the 1-clock delay does not let a hazard through.
    function pw(input [106:0] uu); pw = uu[10] && (uu[48] || (uu[6:5] != 2'd3 && !uu[67])); endfunction
    function wr_(input [106:0] uu); wr_ = uu[10]; endfunction
    wire new_part = pw(u);
    wire [5:0] ra_ = iA_q, rb_ = iB_q, rd_ = iD_q;
    wire hz = (v_xr && ((pw(u_xr) && (d_xr == ra_ || d_xr == rb_ || d_xr == rd_)) || (new_part && wr_(u_xr) && d_xr == rd_))) ||
              (v_x1 && ((pw(u_x1) && (d_x1 == ra_ || d_x1 == rb_ || d_x1 == rd_)) || (new_part && wr_(u_x1) && d_x1 == rd_))) ||
              (v_x2 && ((pw(u_x2) && (d_x2 == ra_ || d_x2 == rb_ || d_x2 == rd_)) || (new_part && wr_(u_x2) && d_x2 == rd_))) ||
              (v_x3 && ((pw(u_x3) && (d_x3 == ra_ || d_x3 == rb_ || d_x3 == rd_)) || (new_part && wr_(u_x3) && d_x3 == rd_))) ||
              (v_m  && ((pw(u_m)  && (d_m  == ra_ || d_m  == rb_ || d_m  == rd_)) || (new_part && wr_(u_m)  && d_m  == rd_)));
    // REV50: no W term - a consumer issued while the producer is in W reads the register file, whose read-first bypass returns the MERGED value
    // being written (regfile64/regfile64_d: wq_d = w_data); with hz registered, the issue happens 1 clock after the producer reached W.
    always @(posedge clk) hz_q <= rst ? 1'b0 : (hz && !issue);

    // ============ M: data access ============
    reg mm_q;                    // registered m_mem (same priority/enable as v_m/u_m): takes 1 LUT level off hold and ex_take_d (c_d_ack -> hold/flush path)
    wire m_mem = mm_q;           // = v_m && (u_m[8] || u_m[9])
    reg  dreq_r;
    always @(posedge clk) begin
        if (rst) dreq_r <= 0;
        else if (m_mem && !dreq_r && !d_ack) dreq_r <= 1'b1;
        else if (d_ack) dreq_r <= 1'b0;
    end
    // Data interface with byte enables: d_addr is always aligned to 8 bytes, d_wdata already comes positioned in the lane and d_be marks the valid bytes.
    // An access that crosses the 8-byte word (offset + size > 8) becomes TWO transactions (beat 0: word A, beat 1: word A+8).
    // crosses the word: computed in X3 and registered with the uop (off the hold path)
    reg xing;
    wire [2:0] off_x3 = addr_x3[2:0];
    wire xing_x3 = (u_x3[6:5] == 2'd1 && off_x3 == 3'd7) || (u_x3[6:5] == 2'd2 && off_x3 >= 3'd5) || (u_x3[6:5] == 2'd3 && off_x3 != 3'd0);
    reg beat; reg [63:0] rd0;
    wire [7:0] bmask = (u_m[6:5] == 2'd0) ? 8'h01 : (u_m[6:5] == 2'd1) ? 8'h03 : (u_m[6:5] == 2'd2) ? 8'h0F : 8'hFF;
    wire [15:0] bme = {8'h00, bmask} << addr_m[2:0];       // byte mask in the 16-byte window {word A+8, word A}
    // a single 64-bit rotator serves both beats: lane L receives byte (L - offset) mod 8; d_be selects the valid lanes
    // REV47: byte rotations written as explicit 8:1 byte multiplexers (before: two opposite 64-bit shifters ORed, ~4 barrel shifters in yosys)
    function [63:0] rotl8(input [63:0] v, input [2:0] n);   // rotate left by n bytes: byte L of the result = byte (L - n) mod 8 of v
        reg [63:0] r1, r2;
        begin   // 3 levels of 2:1 multiplexers (1, 2, 4 bytes)
            r1 = n[0] ? {v[55:0], v[63:56]} : v;
            r2 = n[1] ? {r1[47:0], r1[63:48]} : r1;
            rotl8 = n[2] ? {r2[31:0], r2[63:32]} : r2;
        end
    endfunction
    wire [63:0] strot = rotl8(st_m, addr_m[2:0]);
    assign d_req   = m_mem && !dn_m;
    assign d_we    = u_m[9];
    reg [63:0] addr8_m;   // address of the next word, added in X3 and registered (no adder on the output path)
    assign d_addr  = beat ? addr8_m : {addr_m[63:3], 3'b000};
    assign d_size  = u_m[6:5];
    assign d_be    = beat ? bme[15:8] : bme[7:0];
    assign d_wdata = strot;
    wire [63:0] ldrot  = rotl8(d_rdata, 3'd0 - addr_m[2:0]);   // byte j = word[(j + shift) mod 8]
    wire [63:0] lomask = 64'hFFFF_FFFF_FFFF_FFFF >> {addr_m[2:0], 3'b000};                                    // bytes j < 8 - offset come from beat 0
    wire [63:0] ldsh   = xing ? ((ldrot & ~lomask) | (rd0 & lomask)) : ldrot;
    always @(posedge clk) begin
        if (rst) beat <= 1'b0;
        else if (m_mem && d_ack) begin
            if (xing && !beat && !d_flt) begin beat <= 1'b1; rd0 <= ldrot; end else beat <= 1'b0;
        end
    end
    reg [63:0] ldval_r;
    always @* case (u_m[6:5])
        2'd0: ldval_r = u_m[44] ? {{56{ldsh[7]}},  ldsh[7:0]}  : {56'd0, ldsh[7:0]};
        2'd1: ldval_r = u_m[44] ? {{48{ldsh[15]}}, ldsh[15:0]} : {48'd0, ldsh[15:0]};
        2'd2: ldval_r = u_m[44] ? {{32{ldsh[31]}}, ldsh[31:0]} : {32'd0, ldsh[31:0]};
        default: ldval_r = ldsh;
    endcase
    assign io_we = v_m && u_m[51] && !hold;
    assign io_re = v_m && u_m[50] && !hold;
    assign io_a  = addr_m[7:0];
    wire [2:0] iolane = u_m[63] ? u_m[41:39] : 3'd0;                  // byte lane (INW/OUTW...: successive bytes on the same port)
    assign io_wd = (st_m >> {iolane, 3'b000});
    // ---- multiplication and division (u[98]): mul_unit / div_unit of module 03. uop alu field: [4] = keeps the high part of the dividend (operand A);
    //      [3] = reads an already-ready result ([1:0]: 0 low/quotient, 1 high/remainder, 2 product[31:16], 3 {remainder32, quotient32});
    //      otherwise TRIGGERS: [1] division, [0] signed; size = sz. The uop that triggers does not write: it waits in M (hold) until the unit finishes.
    reg  [63:0] mdu_a, mdu_b, mdu_hi, mdu_r0, mdu_r1; reg [1:0] mdu_sz; reg mdu_sgn, mdu_isdiv, mul_go, div_go;
    wire mul_rdy, mul_ov, div_busy, div_dn, div_err; wire [127:0] mul_p; wire [63:0] div_q, div_r;
    // FPU (u[106], always together with u[98]: uses the same wait in M and the same read selectors). The unit (08_fpu/rtl/fpu_unit.v) has the ST0-ST7 stack and
    // the compact arithmetic core (mdu_fp = 1 while the operation in progress is the FPU's). See MODELO_FPU.txt.
    //   alu[4] = 1: keeps the high 16 bits of an 80-bit value (operand A) | alu[3] = 1: reads the result (0 = r0, 1 = r1) | otherwise TRIGGERS: command = dI field
    //   of the uop, n = low 3 bits of operand B (instruction byte), memory data = operand A.
    reg mdu_err; reg ex_ovr; reg [63:0] ex_aux, ex_epcv; reg [4:0] ex_cau; reg ex_pu;   // (declared here: used before the declaration)
    reg mdu_fp, fp_go; reg [5:0] fp_op; reg [2:0] fp_n; reg [63:0] fp_din; reg [15:0] fp_dhi;
    wire fp_done; wire [63:0] fp_r0; wire [15:0] fp_r1, fp_sw; wire [7:0] fp_emp;
`ifdef R8064_NOFPU
    // Build for the Tang Nano 20K: the FPU (~5 thousand LUTs) does not fit in the GW2AR-18 together with the rest. Without the FPU: the operation finishes at once with result 0.
    assign fp_done = fp_go | mdu_fp; assign fp_r0 = 64'd0; assign fp_r1 = 16'd0; assign fp_sw = 16'd0; assign fp_emp = 8'hFF;
`else
    fpu_unit u_fpu(.clk(clk), .rst(rst), .go(fp_go), .fop(fp_op), .n(fp_n), .din(fp_din), .dhi(fp_dhi), .done(fp_done), .r0(fp_r0), .r1(fp_r1), .sw(fp_sw), .empty(fp_emp));
`endif
    mul_unit u_mul(.clk(clk), .rst(rst), .in_valid(mul_go), .sz(mdu_sz), .sgn(mdu_sgn), .a(mdu_a), .b(mdu_b), .ready(mul_rdy), .out_valid(mul_ov), .prod(mul_p));
    div_unit u_div(.clk(clk), .rst(rst), .start(div_go), .sz(mdu_sz), .sgn(mdu_sgn), .hi(mdu_hi), .lo(mdu_a), .d(mdu_b), .busy(div_busy), .done(div_dn), .q(div_q), .r(div_r), .err(div_err));
    always @(posedge clk) begin
        mul_go <= 1'b0; div_go <= 1'b0; fp_go <= 1'b0;
        if (rst) begin mdu_done <= 1'b0; mdu_fp <= 1'b0; end
        else begin
            if (!hold && !flush && v_x1 && u_x1[98] && u_x1[106]) begin
                if (u_x1[4]) fp_dhi <= opa_x1[15:0];
                else if (!u_x1[3]) begin fp_go <= 1'b1; fp_op <= u_x1[26:21]; fp_n <= opb_x1[2:0]; fp_din <= opa_x1; mdu_fp <= 1'b1; mdu_isdiv <= 1'b0; mdu_done <= 1'b0; end
            end else
            if (!hold && !flush && v_x1 && u_x1[98]) begin
                if (u_x1[4]) mdu_hi <= (u_x1[6:5] == 2'd2) ? {32'd0, opa_x1[63:32]} : opa_x1;
                else if (!u_x1[3]) begin
                    mdu_a <= opa_x1; mdu_b <= opb_x1; mdu_sz <= u_x1[6:5]; mdu_sgn <= u_x1[0]; mdu_isdiv <= u_x1[1]; mdu_done <= 1'b0; mdu_fp <= 1'b0;
                    if (u_x1[1]) div_go <= 1'b1; else mul_go <= 1'b1;
                end
            end
            if (mdu_fp) begin if (fp_done) begin mdu_done <= 1'b1; mdu_err <= 1'b0; mdu_r0 <= fp_r0; mdu_r1 <= {48'd0, fp_r1}; end end
            else if (mdu_isdiv ? div_dn : mul_ov) begin
                mdu_done <= 1'b1; mdu_err <= mdu_isdiv && div_err;
                // divide error (zero divisor or out-of-range quotient): quotient = all ones, remainder = low part of the dividend (used only if the exception is disabled)
                mdu_r0 <= !mdu_isdiv ? mul_p[63:0] : div_err ? 64'hFFFF_FFFF_FFFF_FFFF : div_q;
                mdu_r1 <= !mdu_isdiv ? mul_p[127:64] : div_err ? mdu_a : div_r;
            end
            if (md_q && mdu_done) mdu_done <= 1'b0;      // the uop that started it leaves M on this clock
        end
    end
    // MLT/DIV flags (written if the triggering uop has fwe): Z = zero product/quotient; C = MLT: the high half is significant (unsigned: != 0, as on the R800;
    // signed: != sign extension of the low) | DIV: error; S = sign of the result (signed forms only); PV = C in the signed forms and in division; H and N kept; X = Y = 0.
    wire [63:0] mdu_m  = (mdu_sz == 2'd0) ? 64'hFF : (mdu_sz == 2'd1) ? 64'hFFFF : (mdu_sz == 2'd2) ? 64'hFFFF_FFFF : 64'hFFFF_FFFF_FFFF_FFFF;
    wire [63:0] mdu_lo = mdu_r0 & mdu_m;
    wire [63:0] mdu_hi2 = (mdu_sz == 2'd0) ? {56'd0, mdu_r0[15:8]} : (mdu_sz == 2'd1) ? {48'd0, mdu_r0[31:16]} : (mdu_sz == 2'd2) ? {32'd0, mdu_r0[63:32]} : mdu_r1;
    wire mdu_los = (mdu_sz == 2'd0) ? mdu_r0[7] : (mdu_sz == 2'd1) ? mdu_r0[15] : (mdu_sz == 2'd2) ? mdu_r0[31] : mdu_r0[63];
    wire mdu_his = (mdu_sz == 2'd0) ? mdu_r0[15] : (mdu_sz == 2'd1) ? mdu_r0[31] : (mdu_sz == 2'd2) ? mdu_r0[63] : mdu_r1[63];
    wire mdu_c = mdu_isdiv ? mdu_err : mdu_sgn ? (mdu_hi2 != (mdu_los ? mdu_m : 64'd0)) : (mdu_hi2 != 64'd0);
    wire mdu_z = mdu_isdiv ? (!mdu_err && mdu_lo == 64'd0) : (mdu_lo == 64'd0 && mdu_hi2 == 64'd0);
    wire mdu_s = mdu_sgn && (mdu_isdiv ? (!mdu_err && mdu_los) : mdu_his);
    assign mdu_f = {mdu_s, mdu_z, 1'b0, fl[4], 1'b0, (mdu_sgn | mdu_isdiv) & mdu_c, fl[1], mdu_c};
    assign ex_take_m = md_q && mdu_done && mdu_err && c_te;      // divide error with the exception enabled (CR14 bit 2): the instruction is aborted, cause 6
    wire [63:0] mdu_out = (u_m[1:0] == 2'd0) ? mdu_r0 : (u_m[1:0] == 2'd1) ? mdu_r1 : (u_m[1:0] == 2'd2) ? {48'd0, mdu_r0[31:16]} : {mdu_r1[31:0], mdu_r0[31:0]};
    assign ldval = u_m[8] ? ldval_r : u_m[50] ? ({56'd0, io_rdata} << {iolane, 3'b000}) : u_m[98] ? mdu_out : res_m;
    assign hold = (m_mem && !(d_ack && (!xing || beat))) || (md_q && !mdu_done);
    always @(posedge clk) begin
        if (rst) begin v_m <= 0; dn_m <= 0; mm_q <= 0; md_q <= 0; end
        else if (ex_take_d) begin v_m <= 1'b0; mm_q <= 1'b0; md_q <= 1'b0; end
        else if (!hold) begin
            md_q <= v_x3 && u_x3[98] && !u_x3[4] && !u_x3[3];
            v_m <= v_x3; mm_q <= v_x3 && (u_x3[8] || u_x3[9]); u_m <= u_x3; d_m <= d_x3; dn_m <= 1'b0;
            res_m <= (u_x3[8] || u_x3[9]) ? addr_x3 : x3_res; addr_m <= addr_x3; pc_m <= pc_x3; st_m <= st_x3; old_m <= old_x3; xing <= xing_x3; addr8_m <= ({addr_x3[63:3], 3'b000} + 64'd8) & AMASK;
        end
    end

    // ============ W: partial write + bank ============
    wire [63:0] merged;
    // write size and zeroing of the old value computed in M and registered (takes the adder and muxes off the W -> register file path)
    reg [2:0] wsz_w; reg [63:0] oldz_w;
    wire [2:0] wsz_m = u_m[48] ? 3'd1 : (u_m[6:5] == 2'd0) ? 3'd0 : (u_m[6:5] == 2'd1) ? 3'd2 : (u_m[6:5] == 2'd2) ? 3'd3 : 3'd4;
    regmerge u_mrg(.old(oldz_w), .newv(res_w), .wsz(wsz_w), .out(merged));   // sz 0..3 = 8/16/32/64 bits; u[48] = high byte; u[67] = zero-extends
    assign w_we   = v_w && u_w[10];
    assign w_addr = d_w;
    assign w_data = merged;
    always @(posedge clk) begin
        if (rst) v_w <= 0;
        else if (ex_act) begin   // injection of the exception CRs (43 cause, 44 address, 45 EPC) by stage W; the pipeline is empty
            v_w <= 1'b1; u_w <= 107'h400; d_w <= (exk == 2'd0) ? 6'd44 : (exk == 2'd1) ? 6'd43 : (exk == 2'd2) ? 6'd45 : 6'd50;   // k0: address (addr_m still holds in this clock), k1: cause, k2: EPC (ex_pcd/dpc stay stable)
            res_w <= (exk == 2'd3) ? {62'd0, ex_pu, 1'b0} :
                     ex_ovr ? ((exk == 2'd0) ? ex_aux : (exk == 2'd1) ? {59'd0, ex_cau} : ex_epcv) :
                     (exk == 2'd0) ? (ex_isd ? addr_m : ifa) : (exk == 2'd1) ? {59'd0, ex_we, ex_isd, ex_cs} : (ex_isd ? ex_pcd : dpc); wsz_w <= 3'd4; oldz_w <= 64'd0;
        end else begin
            v_w <= v_m && !hold && !ex_take_d; u_w <= u_m; d_w <= d_m; res_w <= ldval; wsz_w <= wsz_m; oldz_w <= u_m[67] ? 64'd0 : old_m;
        end
    end

    // ============ translation exceptions ============
    // D: the access in M finished with d_flt (ack with data 0, write discarded by the memory): kills M/W/X3, flushes the front-end, jumps to 'vec'. EPC = PC of the instruction
    //    (pc_m, REV50); the restart executes the whole instruction again. RESTARTABLE (rev22): the uop that accesses memory is the FIRST with a visible effect: PUSH/CALL/INT entry write to [SP-2]
    //    (constant immediate immc) and only then update SP; POP/RET/LDIR/CPIR/OUTI (and IM2) read before altering registers (TMP is not visible). NOT restartable: INI/INIR/IND/INDR (the port read already happened).
    //    Fault during INT entry: IFF2 := 1 and the INT is requested again (RETN restores IFF1 and the INT is accepted again).
    // I: the fetched word faulted; the exception is taken at the instruction boundary (empty pipeline) when the candidate instruction is <= 12 bytes from the word (EPC = dpc).
    assign ex_take_d = (m_mem && d_ack && d_flt) || ex_take_m;
    wire ex_take_i = dv && !seq && ifx_q && !serf_q && !ex_act && pipe_empty_q && !issue_q && !m_mem && !ex_take_d;
    // TRAPS taken at the instruction boundary, instead of executing the candidate (the candidate in B is stable >= 2 clocks before the issue):
    //   u[102] privileged instruction in user mode (cause 7, aux 2) | illegal ED, if CR14 bit 2 = 1 (cause 7, aux 0) | u[104] SCALL (cause 5, aux = n)
    wire t_priv = u[102] && c_user, t_unimp = en_ill && c_te, t_scall = u[104];
    always @(posedge clk) trap_q <= !rst && !flush && dv && !seq && !irq_ent && (t_priv || t_unimp || t_scall);
    wire ex_take_t = trap_q && b_ready && !seq && gov_go && !serf_q && !ex_act && pipe_empty_q && !issue_q && !m_mem && !md_q && !ex_take_d && !ex_take_i;
    // interrupt accepted in USER MODE: enters as an exception (cause 0, EPC = next instruction), so the handler runs in supervisor mode and returns with SYSRT
    wire irq_trap = irq_arm_q && !ex_act && !serf_q && !flush_q && pipe_empty_q && !issue_q && !seq && c_user && !ex_take_d;
    assign ex_take = ex_take_d | ex_take_i | ex_take_t | irq_trap;
    // values written to the CRs by the entry: k0 CR12 (address/auxiliary), k1 CR11 (cause), k2 CR13 (EPC), k3 CR18 (mode: {previous user, 0})
    always @(posedge clk) begin
        // REV51: full-width distance (after a predicted branch the faulting word may be far from the instructions still in A/B)
        ifd_q <= (ifa - dpc) & AMASK;   // fault word within -7..+12 bytes of the candidate (negative = candidate already inside the word)
        ifx_q <= ifp && (ifd_q <= 64'd12 || ifd_q >= (AMASK - 64'd7));
        ifda_q <= (ifa - pca) & AMASK;  // the same for A's instruction: B takes it even if incomplete, to raise the exception at the boundary
        ifxa_q <= ifp && av && (ifda_q <= 64'd12 || ifda_q >= (AMASK - 64'd7));
        if (rst) begin ex_act <= 1'b0; exk <= 2'd0; end
        else if (ex_take) begin
            ex_act <= 1'b1; exk <= 2'd0; ex_isd <= ex_take_d; ex_we <= u_m[9]; ex_cs <= ex_take_d ? d_cs : ifc; ex_pu <= c_user;
            ex_ovr <= ex_take_m || (!ex_take_d && !ex_take_i);
            ex_pcd <= pc_m;
            if (ex_take_m)                   begin ex_cau <= 5'd6; ex_aux <= 64'd0; ex_epcv <= pc_m; end
            else if (!ex_take_d && !ex_take_i && ex_take_t) begin
                ex_cau  <= t_scall && !t_priv && !t_unimp ? 5'd5 : 5'd7;
                ex_aux  <= t_priv ? 64'd2 : t_unimp ? 64'd0 : {56'd0, b3};
                ex_epcv <= (t_scall && !t_priv && !t_unimp) ? ((dpc + {60'd0, clen}) & AMASK) : dpc;
            end else                         begin ex_cau <= 5'd0; ex_aux <= 64'd0; ex_epcv <= npc; end
        end else if (ex_act) begin exk <= exk + 2'd1; if (exk == 2'd3) ex_act <= 1'b0; end
    end
    // CR46 = {asid[15:8], user[1], en[0]} | CR47 = root (PPN, 20 b) | CR48 = write -> TLB flush by VA | CR49 = write: b0 all, b1 by ASID ([15:8]), b2 invalidates caches
    // MODE (see MODELO_PRIVILEGIO.txt): CR18 (index 50) = {previous user [1], user [0]}. Entry into any exception makes previous := current, current := supervisor
    // (already in the exception clock, so the handler fetch uses supervisor permissions); SYSRT shifts CR18 one bit to the right.
    // CR14 bit 2 = TE: enables the unimplemented / illegal instruction and divide error exceptions. CR14 bit 1 (user) is still accepted on write, for compatibility.
    reg [7:0] c_asid; reg [19:0] c_root;
    wire cw = v_w && u_w[10];
    always @(posedge clk) begin
        if (rst) begin c_en <= 1'b0; c_user <= 1'b0; c_te <= 1'b0; c_asid <= 8'd0; c_root <= 20'd0; end
        else begin
            if (cw && d_w == 6'd46) begin c_en <= res_w[0]; c_user <= res_w[1]; c_te <= res_w[2]; c_asid <= res_w[15:8]; end
            if (cw && d_w == 6'd47) c_root <= res_w[19:0];
            if (cw && d_w == 6'd50) c_user <= res_w[0];
            if (ex_take) c_user <= 1'b0;
        end
    end
    assign cr_mmu_en = c_en; assign cr_mmu_user = c_user; assign cr_asid = c_asid; assign cr_root = c_root;
    // combinational pulses in the clock in which the write is in W (res_w valid in that clock)
    assign cr_fl_va_en = cw && d_w == 6'd48; assign cr_fl_va = res_w;
    assign cr_fl_all = cw && d_w == 6'd49 && res_w[0]; assign cr_fl_asid_en = cw && d_w == 6'd49 && res_w[1]; assign cr_fl_asid = res_w[15:8]; assign cr_cinv = cw && d_w == 6'd49 && res_w[2];
    wire [5:0] dma_dm = d_w - 6'd51;
    assign dma_cr_we = cw && d_w >= 6'd51 && d_w <= 6'd62; assign dma_cr_idx = dma_dm[3:0]; assign dma_cr_wd = res_w;

    // ============ 64-bit timer + interrupt ============
    always @(posedge clk) begin
        if (rst) begin tmr <= 0; tcmp <= 64'hFFFF_FFFF_FFFF_FFFF; vec <= 64'h0000_0000_0000_0040; ie <= 0; iff2 <= 0; im <= 2'd3; ireg <= 8'd0; irq_pend <= 0; end
        else begin
            tmr <= tmr + 64'd1;
            if (v_w && u_w[10] && d_w == 6'd40) tcmp <= res_w;
            if (v_w && u_w[10] && d_w == 6'd41) vec  <= res_w;
            if (v_w && u_w[10] && d_w == 6'd42) begin ie <= res_w[0]; iff2 <= res_w[0]; end
            if (v_w && u_w[10] && d_w == 6'd14) ireg <= res_w[7:0];       // register I (index 14 of the bank)
            // u[76:74] = misc: 1 EI | 2 DI | 3 RETN/RETI (IFF1 := IFF2) | 4,5,6 IM 0,1,2 | 7 flags de LD A,I (PV := IFF2)
            if (v_w && u_w[76:74] == 3'd1) begin ie <= 1'b1; iff2 <= 1'b1; end
            if (v_w && u_w[76:74] == 3'd2) begin ie <= 1'b0; iff2 <= 1'b0; end
            if (v_w && u_w[76:74] == 3'd3) ie <= iff2;
            if (v_w && u_w[76:74] == 3'd4) im <= 2'd0;
            if (v_w && u_w[76:74] == 3'd5) im <= 2'd1;
            if (v_w && u_w[76:74] == 3'd6) im <= 2'd2;
            if (irq_take || irq_trap) irq_pend <= 1'b0;
            else if (irq || (tmr == tcmp)) irq_pend <= 1'b1;   // INT is level-sensitive: if it stays active, it requests again as soon as IFF1 allows
            if (ex_take_d && irq_ent) irq_pend <= 1'b1;         // the INT entry was aborted by a fault: request again (it is accepted again after RETN)
            if (ex_take) begin iff2 <= (ex_take_d && irq_ent) ? 1'b1 : ie; ie <= 1'b0; end   // fault on INT entry (pushing PC/reading vector): the program had IFF1=1, RETN restores it      // exception: IFF1 saved in IFF2 (RETN restores), interrupts disabled
            if (irq_take) begin ie <= 1'b0; iff2 <= 1'b0; end   // interrupt entry disables new ones (the handler re-enables by writing CR42)
        end
    end

    // description of the candidate instruction for the governor (Z80 pages: 0 main, 1 CB, 2 ED, 3 DD, 4 FD, 5 DDCB, 6 FDCB)
    // the DD/FD prefix was already removed from the window (xy): b1 = opcode; with CB, b2 = d and b3 = opcode
    wire pfx_dd = (xy == 2'd1), pfx_fd = (xy == 2'd2);
    wire dfcb = xy_on && is_cb;
    assign gov_page = irq_ent ? 3'd7 : dfcb ? (pfx_dd ? 3'd5 : 3'd6) : is_cb ? 3'd1 : is_ed ? 3'd2 : pfx_dd ? 3'd3 : pfx_fd ? 3'd4 : 3'd0;
    assign gov_op   = irq_ent ? 8'd0 : dfcb ? b3 : (is_cb || is_ed) ? b2 : b1;
    wire io_n = (b1 == 8'hD3) || (b1 == 8'hDB);
    assign gov_port = io_n ? b2 : port_c;
    assign gov_cv   = issue && !seq;
    // NOT-TAKEN conditional branch: uses the alternate timing. u[94]: 'skip' branch (CALL cc / RET cc skip the rest of the chain when the Z80 condition is FALSE):
    // there the alternative time applies when the jump IS taken
    assign gov_alt_ev = v_x2 && u_x2[11] && (u_x2[94] ? cond_ok : !cond_ok) && !hold;
    assign gov_boundary = !v_xr && !v_x1 && !v_x2 && !v_x3 && !v_m && !v_w;   // empty pipeline
    assign gov_pc = dpc[15:0]; assign gov_len = clen;
    assign gov_dev = m_mem && d_ack; assign gov_daddr = addr_m[15:0]; assign gov_dsize = u_m[6:5]; assign gov_dwe = u_m[9];
    assign dbg_pc  = dpc_q;
    assign dbg_f   = fl;
    // observation signal (keeps the logic alive in synthesis): parity tree in 2 registered stages, so it does not become an artificial critical path
    reg [15:0] dbg_p; reg dbg_s;
    always @(posedge clk) begin
        dbg_p <= {^w_data[63:48], ^w_data[47:32], ^w_data[31:16], ^w_data[15:0], ^d_wdata[63:48], ^d_wdata[47:32], ^d_wdata[31:16], ^d_wdata[15:0],
                  ^d_addr[63:32], ^d_addr[31:0], ^i_addr[63:32], ^i_addr[31:0], ^{w_addr, w_we, i_req, d_req, d_we, d_size}, ^{tmr[63], ld_dep_q, merged[0]}, 2'b00};
        dbg_s <= ^dbg_p;
    end
    assign dbg_sig = dbg_s;
endmodule
