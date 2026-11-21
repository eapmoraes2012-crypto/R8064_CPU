// regfile64.v - 64-bit register file: 64 entries, 2 synchronous reads, 1 write.
// The memory reads "read-first" (reading and writing the same address in the same clock -> OLD value). Forwarding is done AFTER the read:
// the last write is registered (wq_*) and, if it matches the read address, replaces the memory output. It covers the consumer that reads
// exactly when the producer is in the W stage; the other cases are forwarded by the pipeline. (It is not in the w_data -> read path.)
// Two copies to infer BSRAM (2 read ports).
// Indices: 0 QAX,1 QBC,2 QDE,3 QHL,4 QWX,5 QAX',6 QBC',7 QDE',8 QHL',9 QIX,10 QIY,11 QSP,12 QPC,13 temporary; 16..23 = N0..N7; 32..63 = CR00..CR31 (CR18 = mode; see MODELO_PRIVILEGIO.txt).
module regfile64(
    input  wire        clk,
    input  wire        we,
    input  wire [5:0]  waddr,
    input  wire [63:0] wdata,
    input  wire [5:0]  raddr_a,
    input  wire [5:0]  raddr_b,
    output wire [63:0] rdata_a,
    output wire [63:0] rdata_b
);
    reg [63:0] mem_a [0:63];
    reg [63:0] mem_b [0:63];
    integer i;
    initial for (i = 0; i < 64; i = i + 1) begin mem_a[i] = 64'd0; mem_b[i] = 64'd0; end
    reg [63:0] ra_raw, rb_raw, wq_d; reg byp_a, byp_b;
    always @(posedge clk) begin
        if (we) begin mem_a[waddr] <= wdata; mem_b[waddr] <= wdata; end
        ra_raw <= mem_a[raddr_a];
        rb_raw <= mem_b[raddr_b];
        byp_a <= we && (waddr == raddr_a); byp_b <= we && (waddr == raddr_b);
        wq_d <= wdata;
    end
    assign rdata_a = byp_a ? wq_d : ra_raw;
    assign rdata_b = byp_b ? wq_d : rb_raw;
endmodule

// regfile64_d - copy of the register file with ONE read port, in distributed RAM (LUT RAM) instead of BSRAM (REV49: frees the 2 BSRAM
// that a 64 x 64 array takes, for the FPU ROM in the Tang Nano 20K cartridge build). Same behaviour as regfile64 port A (read-first + bypass).
module regfile64_d(
    input  wire        clk,
    input  wire        we,
    input  wire [5:0]  waddr,
    input  wire [63:0] wdata,
    input  wire [5:0]  raddr_a,
    output wire [63:0] rdata_a
);
    (* ram_style = "distributed", syn_ramstyle = "distributed_ram" *) reg [63:0] mem_a [0:63] /* synthesis syn_ramstyle = "distributed_ram" */;
    integer i;
    initial for (i = 0; i < 64; i = i + 1) mem_a[i] = 64'd0;
    reg [63:0] ra_raw, wq_d; reg byp_a;
    always @(posedge clk) begin
        if (we) mem_a[waddr] <= wdata;
        ra_raw <= mem_a[raddr_a];
        byp_a <= we && (waddr == raddr_a);
        wq_d <= wdata;
    end
    assign rdata_a = byp_a ? wq_d : ra_raw;
endmodule
