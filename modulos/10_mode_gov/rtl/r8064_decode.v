// r8064_decode.v - R8064 ED page decoder (GENERATED from spreadsheet rev. 5).
// WAS NOT COMPILED OR SIMULATED in the environment where it was generated (no Icarus/Verilator/Yosys).
//
// Latencies (from the cycle in which b2/b3 are stable before the clock edge):
//   +1 clock : id and illegal valid      (ROM_A and ROM_B read in parallel; amb_idx is combinational logic)
//   +2 clocks: control fields valid (control ROM read with the id)
// ATTENTION: these two serial reads may not fit in the D stage of the 7-stage pipeline
// (the spreadsheet cycle model assumes D in 1 clock). Decide between splitting D, or reading the
// control in stage R. See the README.
module r8064_decode #(
    parameter ROM_A_FILE = "rom_ed_a.mem",
    parameter ROM_B_FILE = "rom_ed_b.mem",
    parameter AMB_FILE   = "amb_idx.mem",
    parameter CTRL_FILE  = "ctrl_b.mem"   // ctrl.mem + bit 28 (accepts bank prefix; gen_bank.py)
)(
    input  wire       clk,
    input  wire [7:0] b2,        // second byte (after the ED prefix)
    input  wire [7:0] b3,        // third byte (only counts on the ambiguous pages)
    output wire [9:0] id,        // instruction number (0 = illegal)
    output wire       illegal,
    output wire [3:0] len,       // instruction bytes
    output wire [4:0] nr,        // data reads (64-bit accesses)
    output wire [4:0] nw,        // data writes
    output wire [1:0] nio,       // I/O accesses
    output wire [7:0] ex,        // occupancy of the X stage (clocks)
    output wire [1:0] pen_code,  // 0 none, 1 BR_D, 2 BR_X, 3 BR_M
    output wire       has_cond,  // a "false condition" variant exists
    output wire       is_z80,    // Z80 ED instruction (Z80 mode)
    output wire       bankable   // accepts bank prefix (ED 0B/0E/0D)
);
    localparam NPAGES = 33;
    localparam PW     = 6;

    // REV53c: the BSRAM ROM_B holds pages 0..31 (exactly 8192 x 10 = 5 blocks); page 32 is logic (r8064_rom_b32). With 33 pages in the
    // array the last 256 entries took a 6th block, and the full REV53 build (with the FPU) ran out of BSRAM.
    reg [9:0]  rom_b [0:8191];
    reg [31:0] ctrl  [0:511];
    initial begin
        $readmemh(ROM_B_FILE, rom_b, 0, 8191);     // the file still has the 33 pages (page 32 is read by gen_decode_rom.py)
        $readmemh(CTRL_FILE,  ctrl);
    end

    // ROM_B page: combinational logic from b2 (256 x PW bits)
    wire [7:0]    amb_w; r8064_rom_amb u_amb(.a(b2), .d(amb_w));
    wire [11:0]   rom_a_w; r8064_rom_a u_roma(.a(b2), .d(rom_a_w));
    wire [PW-1:0] page  = amb_w[PW-1:0];

    wire [9:0]    b32_w; r8064_rom_b32 u_rb32(.a(b3), .d(b32_w));
    reg [11:0] a_q;
    reg [9:0]  b0_q, b32_q; reg p32_q;
    always @(posedge clk) begin
        a_q <= rom_a_w;
        b0_q <= rom_b[{page[4:0], b3}];
        b32_q <= b32_w; p32_q <= page[5];
    end
    wire [9:0] b_q = p32_q ? b32_q : b0_q;

    // registered id (+2 clocks, aligned with the control ROM fields): takes the BSRAM ROM_B output + mux off the uop ROM address
    reg [9:0] id_q;
    always @(posedge clk) id_q <= a_q[10] ? b_q : a_q[9:0];
    assign id      = id_q;
    assign illegal = (id_q == 10'd0);

    // the control ROM is read with BOTH id candidates (A and B) in parallel and the choice is made after the register:
    // takes the id = a_q[10] ? b_q : a_q multiplexer off the path to the ROM address (same latency: +2 clocks)
    reg [31:0] ca_q, cb_q; reg sel_q;
    // REV47: port A of the control ROM is addressed by ROM_A (LUT logic) one clock earlier and its output is re-registered (ca_q = same
    // value and latency as before). Before, the address came straight from the a_q flip-flop with no logic in between: hold violation
    // (-0.12 ns) at the BSRAM address input in nextpnr.
    reg [31:0] ca0;
    always @(posedge clk) begin ca0 <= ctrl[rom_a_w[8:0]]; ca_q <= ca0; cb_q <= ctrl[b_q[8:0]]; sel_q <= a_q[10]; end
    wire [31:0] c_q = sel_q ? cb_q : ca_q;

    assign len      = c_q[3:0];
    assign nr       = c_q[8:4];
    assign nw       = c_q[13:9];
    assign nio      = c_q[15:14];
    assign ex       = c_q[23:16];
    assign pen_code = c_q[25:24];
    assign has_cond = c_q[26];
    assign is_z80   = c_q[27];
    assign bankable = c_q[28];
endmodule
