`timescale 1ns/1ps
// tb_r64_fumaca.v - smoke test of the R8064 16/32/64-bit instructions: runs r64_mem.hex and compares with r64_esperado.hex (gen_r64_fumaca.py)
module tb_r64_fumaca; reg clk=0,rst=1; always #5 clk=~clk;
 wire i_req,d_req,d_we; wire [63:0] i_addr,d_addr,d_wdata,dbg_pc; wire [1:0] d_size; wire [7:0] dbg_f,d_be; wire dbg_sig; reg i_ack=0,d_ack=0; reg [63:0] i_rdata=0,d_rdata=0; reg [7:0] mem[0:65535]; integer k;
 r8064_core_min dut(.smc_miss(1'b0), .i_flt(1'b0),.d_flt(1'b0),.i_cs(3'd0),.d_cs(3'd0),.clk(clk),.rst(rst),.irq(1'b0),.i_req(i_req),.i_addr(i_addr),.i_ack(i_ack),.i_rdata(i_rdata),.d_req(d_req),.d_we(d_we),.d_addr(d_addr),.d_size(d_size),.d_wdata(d_wdata),.d_be(d_be),.d_ack(d_ack),.d_rdata(d_rdata),.dbg_pc(dbg_pc),.dbg_f(dbg_f),.dbg_sig(dbg_sig),.gov_go(1'b1),.gov_wait(1'b0),.port_c(8'd0),.io_rdata(8'hFF));
 wire [15:0] ia={i_addr[15:3],3'b0}, da={d_addr[15:3],3'b0};
 always @(posedge clk) begin i_ack<=0; d_ack<=0;
  if (i_req&&!i_ack) begin i_ack<=1; for(k=0;k<8;k=k+1) i_rdata[8*k+:8]<=mem[ia+k[15:0]]; end
  if (d_req&&!d_ack) begin d_ack<=1; if (d_we) begin for(k=0;k<8;k=k+1) if(d_be[k]) mem[da+k[15:0]]<=d_wdata[8*k+:8]; end else for(k=0;k<8;k=k+1) d_rdata[8*k+:8]<=mem[da+k[15:0]]; end end
 `define R(i) dut.u_rf1.mem_a[i]
 reg [63:0] e[0:8], g[0:8]; integer errs=0;
 initial begin $readmemh("r64_mem.hex",mem); $readmemh("r64_esperado.hex",e); repeat(4)@(posedge clk); rst=0; repeat(3000)@(posedge clk);
  g[0]=`R(0); g[1]=`R(1); g[2]=`R(2); g[3]=`R(3); g[4]=`R(9); g[5]=`R(10); g[6]=`R(11);
  for(k=0;k<8;k=k+1) begin g[7][8*k+:8]=mem[16'h9000+k[15:0]]; g[8][8*k+:8]=mem[16'h9008+k[15:0]]; end
  for(k=0;k<9;k=k+1) if (g[k]!==e[k]) begin errs=errs+1; $display("ERROR item %0d (AX BC DE HL IX IY SP m9000 m9008): got %h expected %h",k,g[k],e[k]); end
  $display("pc=%h errors=%0d", dut.npc, errs);
  if (errs==0) $display("RESULT: R8064 16/32/64 SMOKE OK"); else $display("RESULT: %0d ERRORS", errs);
  $finish; end
endmodule
