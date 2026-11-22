// fpu_seq.v - arithmetic core of the R8064 80-bit FPU (extended x87), made to take little area. Same interface and same results as fpu_alu.v
// (bit by bit, fpref.py vectors). Datapath: working register X (68 bits) that only receives 8 things (MA, MB, the sum, X shifted by 4 or 1 to
// each side, the quotient/root), ONE adder (X or MA) +/- (X, MA or the root trial), and two 66-bit registers (MA, MB). Multiplication, division and
// square root are bit by bit in this adder (2 to 3 clocks per bit), except multiplication (REV54): 16 multiplier bits per step with a 64 x 16
// product (DSP blocks) and its own 84-bit adder, 2 clocks per step (8 clocks instead of 128); same result bit by bit (X = sticky shift of the sum).
// Operations (op): 0 ADD, 1 SUB, 2 MUL, 3 DIV, 4 SQRT, 5 CMP, 6 FILD(int64), 7 FIST(int64), 8 RNDINT, 9 LD32, 10 LD64, 11 ST32, 12 ST64.
// a = ST0 (or memory data), b = second operand; a, b, op, rc and pc must stay STABLE from 'start' until the next 'start'.
// rc: 0 nearest/even, 1 -inf, 2 +inf, 3 zero. pc: 0 = 24, 2 = 53, others = 64 bits (ADD/SUB/MUL/DIV/SQRT only).
// Outputs (valid from 'done' until the next 'start'): res, flags {PE,UE,OE,ZE,DE,IE}, up (rounded up = C1), cc {c3,c2,c0} (CMP only).
// X: [67] carry, [66:3] significand (bit 66 = integer bit), [2] guard, [1] rounding, [0] "sticky".
module fpu_seq(
    input  wire        clk, rst, start,
    input  wire [3:0]  op,
    input  wire [1:0]  rc, pc,
    input  wire [79:0] a, b,
    output wire        busy,
    output reg         done,
    output wire [79:0] res,
    output reg  [5:0]  flags,
    output reg         up,
    output reg  [2:0]  cc
);
    localparam OP_ADD = 0, OP_SUB = 1, OP_MUL = 2, OP_DIV = 3, OP_SQRT = 4, OP_CMP = 5, OP_FILD = 6, OP_FIST = 7, OP_RND = 8, OP_LD32 = 9, OP_LD64 = 10, OP_ST32 = 11, OP_ST64 = 12;
    localparam [5:0] S_IDLE = 0, S_LD = 1, S_C0 = 2, S_C = 3, S_DEC = 4, S_UA = 5, S_UA2 = 6, S_UB = 7, S_UB2 = 8, S_OP = 9, S_SHR = 10, S_NRM = 11, S_AD0 = 12, S_AD0B = 13,
                     S_AD1 = 14, S_AD2 = 15, S_ML1 = 16, S_ML2 = 17, S_DV0 = 18, S_DV1 = 19, S_DV2 = 20, S_DV3 = 21, S_SQ0 = 22, S_SQ0B = 23, S_SQA = 24, S_SQB = 25,
                     S_SQC = 26, S_SQD = 27, S_SQE = 28, S_RI = 29, S_RI2 = 30, S_NEG = 31, S_RP0 = 32, S_RP1 = 33, S_RP2 = 34, S_RP3 = 35, S_FIN = 36;
    localparam [67:0] XIND = {1'b0, 64'hC000_0000_0000_0000, 3'd0}, XINF = {1'b0, 64'h8000_0000_0000_0000, 3'd0};
    reg [5:0] st, ret;
    reg [67:0] X; reg [65:0] MA, MB; reg [79:0] PR; reg signed [17:0] EA, EB; reg [6:0] cn;
    reg sr, nb, subr, tiny, mlt, meq, odd, sk; reg [1:0] emode;      // emode: 0 exponent = EA (or 0 if denormal/zero), 1 all-ones exponent, 2 raw integer
    assign busy = (st != S_IDLE);
    // ---- classification (combinational over the stable inputs) ----
    wire sa = a[79], sb = b[79]; wire [14:0] xa = a[78:64], xb = b[78:64]; wire [63:0] ma = a[63:0], mb = b[63:0];
    wire xa0 = (xa == 0), xb0 = (xb == 0), xa1 = (xa == 15'h7FFF), xb1 = (xb == 15'h7FFF), fa0 = (ma[62:0] == 0), fb0 = (mb[62:0] == 0);
    wire za = xa0 && !ma[63] && fa0, zb = xb0 && !mb[63] && fb0;
    wire da = xa0 && !ma[63] && !fa0, db = xb0 && !mb[63] && !fb0;
    wire ua = xa0 ? ma[63] : !ma[63], ub = xb0 ? mb[63] : !mb[63];
    wire ia = xa1 && ma[63] && fa0, ib = xb1 && mb[63] && fb0;
    wire na = xa1 && ma[63] && !fa0, nbn = xb1 && mb[63] && !fb0;
    wire two = (op == OP_ADD) || (op == OP_SUB) || (op == OP_MUL) || (op == OP_DIV) || (op == OP_CMP);
    wire one = (op == OP_SQRT) || (op == OP_FIST) || (op == OP_RND) || (op == OP_ST32) || (op == OP_ST64);
    wire ari = (op == OP_ADD) || (op == OP_SUB) || (op == OP_MUL) || (op == OP_DIV) || (op == OP_SQRT) || (op == OP_RND);
    wire st32 = (op == OP_ST32), st64 = (op == OP_ST64), isld = (op == OP_LD32) || (op == OP_LD64), l64 = (op == OP_LD64);
    wire fde = (one && da) || (two && (da || db));
    wire sbe = sb ^ (op == OP_SUB);
    wire u_any = ua || (two && ub), n_any = na || (two && nbn);
    wire ls = l64 ? a[63] : a[31]; wire [10:0] le = l64 ? a[62:52] : {3'd0, a[30:23]}; wire [51:0] lf = l64 ? a[51:0] : {a[22:0], 29'd0};
    wire le_max = l64 ? (le == 11'h7FF) : (le[7:0] == 8'hFF), le_z = (le == 0), lf_z = (lf == 0);
    wire nq = (ari && n_any) || ((st32 || st64) && na) || (isld && le_max);      // links the "quiet" bit when copying / comparing a NaN
    wire pick_b = two && nbn && (!na || mlt);
    wire nan_ie = (na && !ma[62]) || (two && nbn && !mb[62]);
    wire xlt = xa < xb, xeq = (xa == xb);
    wire mag_gt = xeq ? (!mlt && !meq) : !xlt, mag_eq = xeq && meq;
    // ---- rounding parameters ----
    wire [1:0] psel = st32 ? 2'd0 : st64 ? 2'd1 : (op == OP_FIST || op == OP_RND) ? 2'd2 : (pc == 2'd0) ? 2'd0 : (pc == 2'd2) ? 2'd1 : 2'd2;
    wire signed [17:0] emin = st32 ? -18'sd126 : st64 ? -18'sd1022 : -18'sd16382;
    wire signed [17:0] emax = st32 ? 18'sd127 : st64 ? 18'sd1023 : 18'sd16383;
    wire rb  = (psel == 2'd0) ? X[42] : (psel == 2'd1) ? X[13] : X[2];
    wire stk = (psel == 2'd0) ? |X[41:0] : (psel == 2'd1) ? |X[12:0] : |X[1:0];
    wire lsb = (psel == 2'd0) ? X[43] : (psel == 2'd1) ? X[14] : X[3];
    wire inex = rb | stk;
    wire inc = (rc == 2'd0) ? (rb && (stk || lsb)) : (rc == 2'd1) ? (inex && sr) : (rc == 2'd2) ? (inex && !sr) : 1'b0;
    wire [67:0] one_l = (psel == 2'd0) ? (68'd1 << 43) : (psel == 2'd1) ? (68'd1 << 14) : (68'd1 << 3);
    wire [67:0] msk_l = (psel == 2'd0) ? {25'h1FFFFFF, 43'd0} : (psel == 2'd1) ? {54'h3FFFFFFFFFFFFF, 14'd0} : {65'h1FFFFFFFFFFFFFFFF, 3'd0};
    wire [63:0] maxm = (psel == 2'd0) ? {24'hFFFFFF, 40'd0} : (psel == 2'd1) ? {53'h1FFFFFFFFFFFFF, 11'd0} : 64'hFFFF_FFFF_FFFF_FFFF;
    wire inf_r = (rc == 2'd0) || (rc == 2'd2 && !sr) || (rc == 2'd1 && sr);
    wire signed [17:0] dexp = EA - EB;
    wire [17:0] dabs = dexp[17] ? -dexp : dexp;
    wire signed [17:0] dmin = emin - EA;
    wire bbig = dexp[17] || (dexp == 0 && mlt);
    // ---- as 8 fontes de X ----
    wire [67:0] xma = {1'b0, MA[63], MA[62] | nq, MA[61:0], 3'd0}, xmb = {1'b0, MB[63], MB[62] | nq, MB[61:0], 3'd0};
    wire [67:0] shr4 = {4'd0, X[67:5], |X[4:0]}, shr1 = {1'b0, X[67:2], |X[1:0]};
    wire [67:0] shl4 = {X[63:0], 4'd0}, shl1 = {X[66:0], (st == S_SQA || st == S_SQB) && MB[65]};
    wire [67:0] qf = {1'b0, MB[65:0], sk};
    // ---- the single adder: SUM = L +/- R (in subtraction SUM[68] = 1 when L >= R) ----
    reg [67:0] L, R; reg sub; reg [67:0] smk;
    always @* begin
        L = X; R = xma; sub = 1'b1; smk = {68{1'b1}};
        case (st)
            S_AD1: begin L = xma; R = X; sub = subr; end
            S_ML1: sub = 1'b0;
            S_SQC: R = {1'b0, MA[64:0], 2'b01};
            S_NEG: begin L = 68'd0; R = X; smk = {1'b0, {67{1'b1}}}; end
            S_RI, S_RP2: begin R = inc ? one_l : 68'd0; sub = 1'b0; smk = msk_l; end
            default: ;                                                          // S_C, S_DV1: X - MA
        endcase
    end
    wire [68:0] SUM = {1'b0, L} + {1'b0, sub ? ~R : R} + {68'd0, sub};
    wire ge = SUM[68]; wire sz = (SUM[67:0] == 68'd0); wire [67:0] sumk = SUM[67:0] & smk;
    wire xz = (X == 68'd0);
    // ---- REV54 multiplication step: X <- sticky shift by 16 of (X + (MA x MB[15:0]) << 3) ----
    wire [63:0] ama = {MA[63], MA[62] | nq, MA[61:0]};              // the significand that xma puts in X[66:3]
    wire [83:0] msum = {16'd0, X} + {1'b0, PR, 3'd0};
    // ---- result: assembled from the registers (X, EA, sr, emode) ----
    wire [17:0] eb80 = EA + 18'd16383, eb64 = EA + 18'd1023, eb32 = EA + 18'd127;
    wire [14:0] ef = (emode == 2'd1) ? 15'h7FFF : X[66] ? (st32 ? {7'd0, eb32[7:0]} : st64 ? {4'd0, eb64[10:0]} : eb80[14:0]) : 15'd0;
    assign res = (emode == 2'd2) ? {16'd0, X[66:3]} : st32 ? {48'd0, sr, ef[7:0], X[65:43]} : st64 ? {16'd0, sr, ef[10:0], X[65:14]} : {sr, ef, X[66:3]};
    // special-case decision (S_DEC): 0 follows the general path, 1 zero, 2 infinity, 3 indefinite (+IE), 4 chosen NaN, 5 copy MA (NaN/LD), 6 integer 8000..
    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin st <= S_IDLE; flags <= 0; up <= 0; cc <= 0; emode <= 0; X <= 0; sr <= 0; EA <= 0; end
        else case (st)
            S_IDLE: if (start) begin st <= S_LD; up <= 1'b0; cc <= 3'd0; flags <= 6'd0; tiny <= 1'b0; nb <= 1'b0; emode <= 2'd0; sk <= 1'b0; end
            S_LD: begin MA <= isld ? {2'b00, !le_z, lf, 11'd0} : {2'b00, ma}; MB <= {2'b00, mb}; EA <= {3'd0, xa}; EB <= {3'd0, xb}; ret <= S_DEC; st <= S_C0; end
            S_C0: begin X <= xmb; st <= S_C; end
            S_C: begin mlt <= ge && !sz; meq <= sz; st <= ret; end                // X = MB against MA
            S_DEC: begin
                flags <= {4'd0, fde, 1'b0}; sr <= sa; st <= S_UA; X <= 68'd0;
                if (ari && u_any) begin sr <= 1'b1; X <= XIND; emode <= 2'd1; flags <= {4'd0, fde, 1'b1}; st <= S_FIN; end
                else if (ari && n_any) begin sr <= pick_b ? sb : sa; X <= pick_b ? xmb : xma; emode <= 2'd1; flags <= {4'd0, fde, nan_ie}; st <= S_FIN; end
                else case (op)
                    OP_ADD, OP_SUB: begin
                        if (ia || ib) begin
                            st <= S_FIN; emode <= 2'd1; X <= XINF; sr <= ia ? sa : sbe;
                            if (ia && ib && sa != sbe) begin sr <= 1'b1; X <= XIND; flags <= {4'd0, fde, 1'b1}; end
                        end else if (za && zb) begin sr <= (sa == sbe) ? sa : (rc == 2'd1); st <= S_FIN; end
                        else if (za) begin sr <= sbe; st <= S_UB; end
                    end
                    OP_MUL: begin
                        sr <= sa ^ sb;
                        if ((ia && zb) || (za && ib)) begin sr <= 1'b1; X <= XIND; emode <= 2'd1; flags <= {4'd0, fde, 1'b1}; st <= S_FIN; end
                        else if (ia || ib) begin X <= XINF; emode <= 2'd1; st <= S_FIN; end
                        else if (za || zb) st <= S_FIN;
                    end
                    OP_DIV: begin
                        sr <= sa ^ sb;
                        if ((ia && ib) || (za && zb)) begin sr <= 1'b1; X <= XIND; emode <= 2'd1; flags <= {4'd0, fde, 1'b1}; st <= S_FIN; end
                        else if (zb) begin X <= XINF; emode <= 2'd1; flags <= {3'd0, 1'b1, fde, 1'b0}; st <= S_FIN; end
                        else if (ia) begin X <= XINF; emode <= 2'd1; st <= S_FIN; end
                        else if (ib || za) st <= S_FIN;
                    end
                    OP_SQRT: begin
                        sr <= 1'b0;
                        if (za) begin sr <= sa; st <= S_FIN; end
                        else if (sa) begin sr <= 1'b1; X <= XIND; emode <= 2'd1; flags <= {4'd0, fde, 1'b1}; st <= S_FIN; end
                        else if (ia) begin X <= XINF; emode <= 2'd1; st <= S_FIN; end
                    end
                    OP_CMP: begin
                        st <= S_FIN; sr <= 1'b0;                                       // res = 0 (only cc matters)
                        if (ua || ub || na || nbn) begin cc <= 3'd7; flags <= {4'd0, fde, 1'b1}; end
                        else cc <= ((za && zb) || (sa == sb && mag_eq)) ? 3'd4 : (sa != sb) ? {2'b00, sa} : {2'b00, mag_gt ? sa : !sa};
                    end
                    OP_FILD: begin
                        flags <= 6'd0; sr <= a[63] && (ma != 64'd0); X <= xma; EA <= 18'sd63; ret <= S_FIN; st <= (ma == 64'd0) ? S_FIN : a[63] ? S_NEG : S_NRM;
                    end
                    OP_FIST: begin
                        if (ua || na || ia) begin X <= XINF; emode <= 2'd2; flags <= {4'd0, fde, 1'b1}; st <= S_FIN; end
                        else if (za) begin emode <= 2'd2; st <= S_FIN; end
                    end
                    OP_RND: begin
                        if (ia) begin X <= XINF; emode <= 2'd1; st <= S_FIN; end
                        else if (za) st <= S_FIN;
                    end
                    OP_LD32, OP_LD64: begin
                        flags <= 6'd0; sr <= ls; st <= S_FIN; X <= xma;
                        EA <= le_z ? (l64 ? -18'sd1022 : -18'sd126) : $signed({7'd0, le}) - (l64 ? 18'sd1023 : 18'sd127);
                        if (le_max) begin emode <= 2'd1; if (lf_z) X <= XINF; else flags <= {5'd0, !lf[51]}; end
                        else if (le_z && lf_z) X <= 68'd0;
                        else if (le_z) begin flags <= 6'b000010; ret <= S_FIN; st <= S_NRM; end
                    end
                    OP_ST32, OP_ST64: begin
                        if (ua) begin sr <= 1'b1; X <= XIND; emode <= 2'd1; flags <= {4'd0, fde, 1'b1}; st <= S_FIN; end
                        else if (na) begin X <= xma; emode <= 2'd1; flags <= {4'd0, fde, !ma[62]}; st <= S_FIN; end
                        else if (ia) begin X <= XINF; emode <= 2'd1; st <= S_FIN; end
                        else if (za) st <= S_FIN;
                    end
                    default: begin sr <= 1'b1; X <= XIND; emode <= 2'd1; flags <= 6'd1; st <= S_FIN; end
                endcase
            end
            // ---- unpack (normalizing the denormals) ----
            S_UA: begin
                EA <= da ? -18'sd16382 : EA - 18'sd16383; X <= xma; nb <= 1'b0; ret <= S_UA2;
                st <= da ? S_NRM : (two && !zb) ? S_UB : S_OP;
            end
            S_UA2: begin MA <= {2'b00, X[66:3]}; st <= (two && !zb) ? S_UB : S_OP; end
            S_UB: begin
                EB <= db ? -18'sd16382 : EB - 18'sd16383; X <= xmb; nb <= 1'b1; ret <= S_UB2;
                st <= db ? S_NRM : S_OP;
            end
            S_UB2: begin MB <= {2'b00, X[66:3]}; nb <= 1'b0; st <= S_OP; end
            S_OP: begin
                nb <= 1'b0;
                case (op)
                    OP_ADD, OP_SUB: begin
                        if (za) begin X <= xmb; EA <= EB; st <= S_RP0; end
                        else if (zb) begin X <= xma; st <= S_RP0; end
                        else begin ret <= S_AD0; st <= S_C0; end
                    end
                    OP_MUL: begin X <= 68'd0; cn <= 7'd4; EA <= EA + EB + 18'sd1; st <= S_ML1; end
                    OP_DIV: begin X <= xma; EA <= EA - EB; st <= S_DV0; end
                    OP_SQRT: begin MB <= MA; MA <= 66'd0; X <= 68'd0; odd <= EA[0]; EA <= {EA[17], EA[17:1]}; cn <= 7'd66; st <= S_SQ0; end
                    OP_FIST, OP_RND: begin
                        X <= xma;
                        if (EA >= 18'sd63) begin
                            st <= S_FIN;
                            if (op == OP_FIST) begin
                                X <= XINF; emode <= 2'd2;
                                if (!(EA == 18'sd63 && sa && MA[63:0] == 64'h8000_0000_0000_0000)) flags <= flags | 6'd1;
                            end
                        end else begin cn <= ((18'sd63 - EA) > 18'sd68) ? 7'd68 : (7'd63 - EA[6:0]); ret <= S_RI; st <= S_SHR; end
                    end
                    default: begin X <= xma; st <= S_RP0; end
                endcase
            end
            // ---- routines: X >> cn (with sticky) and left normalization ----
            S_SHR: begin
                if (cn >= 7'd4) begin X <= shr4; cn <= cn - 7'd4; end
                else if (cn != 7'd0) begin X <= shr1; cn <= cn - 7'd1; end
                else st <= ret;
            end
            S_NRM: begin
                if (X[66] || X[66:0] == 67'd0) st <= ret;
                else if (X[66:63] == 4'd0) begin X <= shl4; if (nb) EB <= EB - 18'sd4; else EA <= EA - 18'sd4; end
                else begin X <= shl1; if (nb) EB <= EB - 18'sd1; else EA <= EA - 18'sd1; end
            end
            // ---- add / subtract: the larger goes in MA, the smaller goes to X and is aligned ----
            S_AD0: begin
                subr <= (sa != sbe); sr <= bbig ? sbe : sa; cn <= (dabs > 18'd68) ? 7'd68 : dabs[6:0];
                if (bbig) begin MA <= MB; MB <= MA; EA <= EB; end
                st <= S_AD0B;
            end
            S_AD0B: begin X <= xmb; ret <= S_AD1; st <= S_SHR; end
            S_AD1: begin X <= sumk; st <= S_AD2; end
            S_AD2: begin
                if (subr && xz) begin sr <= (rc == 2'd1); st <= S_FIN; end
                else begin ret <= S_RP1; st <= X[67] ? S_RP0 : S_NRM; end
            end
            // ---- multiplication: add (if the multiplier bit = 1) and shift; 2 clocks per bit ----
            S_ML1: begin PR <= ama * MB[15:0]; st <= S_ML2; end
            S_ML2: begin
                X <= {msum[83:17], |msum[16:0]}; MB <= {16'd0, MB[65:16]}; cn <= cn - 7'd1;
                if (cn == 7'd1) begin ret <= S_RP1; st <= S_NRM; end else st <= S_ML1;
            end
            // ---- division: X = remainder, MA = divisor, MB = quotient (66 bits); 2 clocks per bit ----
            S_DV0: begin MA <= MB; MB <= 66'd0; cn <= 7'd66; st <= S_DV1; end
            S_DV1: begin if (ge) X <= sumk; MB <= {MB[64:0], ge}; st <= S_DV2; end
            S_DV2: begin
                cn <= cn - 7'd1;
                if (cn == 7'd1) begin sk <= !xz; st <= S_DV3; end else begin X <= shl1; st <= S_DV1; end
            end
            S_DV3: begin X <= qf; ret <= S_RP1; st <= S_NRM; end
            // ---- root: X = remainder, MA = root, MB = radicand (1 bit per clock comes out at the top); 3 clocks per bit ----
            S_SQ0: begin MB <= {MB[64:0], 1'b0}; st <= odd ? S_SQ0B : S_SQA; end
            S_SQ0B: begin MB <= {MB[64:0], 1'b0}; st <= S_SQA; end
            S_SQA: begin X <= shl1; MB <= {MB[64:0], 1'b0}; st <= S_SQB; end
            S_SQB: begin X <= shl1; MB <= {MB[64:0], 1'b0}; st <= S_SQC; end
            S_SQC: begin
                if (ge) X <= sumk; MA <= {MA[64:0], ge}; cn <= cn - 7'd1;
                st <= (cn == 7'd1) ? S_SQD : S_SQA;
            end
            S_SQD: begin MB <= MA; sk <= !xz; st <= S_SQE; end
            S_SQE: begin X <= qf; st <= S_RP1; end
            // ---- FIST / RNDINT: rounds to integer ----
            S_RI: begin X <= sumk; if (inex) flags <= flags | 6'b100000; up <= inc && inex; st <= S_RI2; end
            S_RI2: begin
                st <= S_FIN;
                if (op == OP_FIST) begin
                    emode <= 2'd2; ret <= S_FIN;
                    if (!sa && X[66]) begin up <= 1'b0; X <= XINF; flags <= {4'd0, fde, 1'b1}; end
                    else if (sa) st <= S_NEG;
                end else if (X[66:3] != 64'd0) begin EA <= 18'sd63; ret <= S_FIN; st <= S_NRM; end
            end
            S_NEG: begin X <= sumk; st <= (op == OP_FILD) ? S_NRM : S_FIN; end                                 // X := -X (64 bits); used by FIST and FILD
            // ---- round and pack ----
            S_RP0: begin if (X[67]) begin X <= shr1; EA <= EA + 18'sd1; end st <= S_RP1; end
            S_RP1: begin
                if (EA < emin) begin tiny <= 1'b1; cn <= (dmin > 18'sd68) ? 7'd68 : dmin[6:0]; EA <= emin; ret <= S_RP2; st <= S_SHR; end
                else st <= S_RP2;
            end
            S_RP2: begin X <= sumk; flags <= flags | {inex, tiny && inex, 4'd0}; up <= inc && inex; st <= S_RP3; end
            S_RP3: begin
                if (X[67]) begin X <= shr1; EA <= EA + 18'sd1; end
                else if (X[66] && EA > emax) begin
                    up <= inf_r; flags <= flags | 6'b101000; st <= S_FIN;
                    if (inf_r) begin X <= XINF; emode <= 2'd1; end else begin X <= {1'b0, maxm, 3'd0}; EA <= emax; end
                end else st <= S_FIN;
            end
            S_FIN: begin done <= 1'b1; st <= S_IDLE; end
            default: st <= S_IDLE;
        endcase
    end
endmodule
