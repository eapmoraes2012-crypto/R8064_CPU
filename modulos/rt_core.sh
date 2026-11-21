#!/bin/bash
# rt_core.sh - Linux regression of the core (modules 09 and 10) and of the SoC (module 13). Needs iverilog/vvp and python3.
# Usage: bash rt_core.sh <out dir> [quick]   -> one .txt per test in <out dir> and a summary (summary.txt: RESULT/ERROR lines per test).
# "quick" skips the random Z80 test (z80t, 100 seeds) and the long SoC tests.
M=$(cd "$(dirname "$0")" && pwd); O=$(mkdir -p "$1" && cd "$1" && pwd); Q=$2
C9=$M/09_core_min; R=$C9/rtl
CORE="$R/r8064_core_min.v $R/r8064_decode.v $R/r8064_decode_rom.v $R/regfile64.v $R/regmap_b.v $R/regmerge.v $R/alu_prep.v $R/alu_core_s.v $M/03_muldiv/rtl/mul_unit.v $M/03_muldiv/rtl/div_unit.v $M/08_fpu/rtl/fpu_unit.v $M/08_fpu/rtl/fpu_seq.v"
run() { local n=$1; shift; ( "$@" ) > "$O/$n.txt" 2>&1; }
cmp -s $R/r8064_core_min.v $M/10_mode_gov/rtl/r8064_core_min.v || echo "ERROR: r8064_core_min.v differs between 09_core_min/rtl and 10_mode_gov/rtl" > "$O/copies.txt"
# ---- module 09: unit programs
cd $C9/sim
(cd $M/01_alu_regfile/ref 2>/dev/null && iverilog -g2012 -o $O/m09_alu_s.vvp $C9/sim/tb_alu_s.v $R/alu_core_s.v $R/alu_prep.v && run m09_alu_s vvp -n $O/m09_alu_s.vvp)
for t in core bank seq blk io irq irq3 ldai xing exini; do iverilog -g2012 -o $O/m09_$t.vvp tb_$t.v $CORE && run m09_$t vvp -n $O/m09_$t.vvp; done
iverilog -g2012 -o $O/m09_irq2.vvp tb_irq2.v $CORE && run m09_irq2 sh -c "vvp -n $O/m09_irq2.vvp; vvp -n $O/m09_irq2.vvp +im2"
# ---- module 09: Z80 against the reference model (step by step) and R8064 programs (step by step and free-running)
cd $C9/sim_z80; for f in uop.mem mainctrl.mem rom_ed_a.mem rom_ed_b.mem amb_idx.mem ctrl.mem ctrl_b.mem; do cp -f ../sim/$f .; done
iverilog -g2012 -o $O/z80core.vvp tb_z80core.v $CORE && run m09_z80core sh -c "for v in r53 r56 zex; do echo --- \$v; vvp -n $O/z80core.vvp +hex=vec/\${v}_mem.hex +trace=vec/\${v}_trace.txt +fim=vec/\${v}_fim.hex; done"
cd $C9/sim_r64; for f in uop.mem mainctrl.mem rom_ed_a.mem rom_ed_b.mem amb_idx.mem ctrl.mem ctrl_b.mem; do cp -f ../sim/$f .; done
iverilog -g2012 -o $O/r64f.vvp tb_r64_fumaca.v $CORE && run m09_r64_smoke vvp -n $O/r64f.vvp
iverilog -g2012 -o $O/r64c.vvp tb_r64core.v $CORE && run m09_r64 sh -c "for v in q1 q2; do vvp -n $O/r64c.vvp +hex=vec/\${v}_mem.hex +trace=vec/\${v}_trace.txt +fim=vec/\${v}_fim.hex +fpu=vec/\${v}_fpu.hex; vvp -n $O/r64c.vvp +hex=vec/\${v}_mem.hex +trace=vec/\${v}_trace.txt +fim=vec/\${v}_fim.hex +fpu=vec/\${v}_fpu.hex +livre; done"
# ---- module 09: random Z80 programs, free-running, against the Python model
[ "$Q" = quick ] || (cd $C9/sim/z80t && run m09_z80rand python3 z80rand.py 1 100)
# ---- module 10: governor, system, timing
cd $M/10_mode_gov/sim; cp -f $C9/sim/*.mem . ; R10=../rtl
CG="$R10/r8064_cpu_gov.v $R10/r8064_mode.v $R10/timing_gov.v $R10/mem_class.v $CORE"
SYS="$R10/r8064_msx_sys.v $R10/r8064_fifo_if.v $M/10_msx_mem/rtl/msx_mem.v $CG"
iverilog -g2012 -o $O/m10_mode.vvp tb_mode.v $R10/r8064_mode.v && run m10_mode vvp -n $O/m10_mode.vvp
iverilog -g2012 -o $O/m10_mem.vvp tb_mem.v $R10/mem_class.v && run m10_mem vvp -n $O/m10_mem.vvp
iverilog -g2012 -o $O/m10_gov.vvp tb_gov.v $R10/timing_gov.v && run m10_gov vvp -n $O/m10_gov.vvp
iverilog -g2012 -o $O/m10_cg.vvp tb_cpu_gov.v $CG && run m10_cpu_gov sh -c "vvp -n $O/m10_cg.vvp +native; vvp -n $O/m10_cg.vvp; vvp -n $O/m10_cg.vvp +r800; vvp -n $O/m10_cg.vvp +r800 +ext"
for t in sys sys_seq sys_ldir sys_irq; do iverilog -g2012 -o $O/m10_$t.vvp tb_$t.v $SYS && run m10_$t sh -c "vvp -n $O/m10_$t.vvp; vvp -n $O/m10_$t.vvp +r800"; done
iverilog -g2012 -o $O/m10_xing.vvp tb_xing.v $CG && run m10_xing vvp -n $O/m10_xing.vvp
iverilog -g2012 -o $O/m10_fifo.vvp tb_fifo.v $R10/r8064_fifo_if.v && run m10_fifo vvp -n $O/m10_fifo.vvp
iverilog -g2012 -o $O/m10_sfifo.vvp tb_sys_fifo.v $SYS && run m10_sys_fifo vvp -n $O/m10_sfifo.vvp
for t in exini cplneg blk io irq irq3 ldai seq; do iverilog -g2012 -o $O/m10_$t.vvp tb_$t.v $CG && run m10_$t vvp -n $O/m10_$t.vvp; done
iverilog -g2012 -o $O/m10_irq2.vvp tb_irq2.v $CG && run m10_irq2 sh -c "vvp -n $O/m10_irq2.vvp; vvp -n $O/m10_irq2.vvp +im2"
# ---- module 13: SoC
cd $M/13_soc/sim; S=../rtl; R10=../../10_mode_gov/rtl
SOC="$S/r8064_soc.v $S/r8064_memsys.v $S/mem_arb5.v $S/r8064_dma.v $S/r8064_xbuf.v $S/cache_dm.v $S/mmu.v $S/sdram_ctrl.v sdram_model.v $R10/r8064_cpu_gov.v $R10/r8064_msx_sys.v $R10/r8064_fifo_if.v $R10/r8064_mode.v $R10/timing_gov.v $R10/mem_class.v ../../10_msx_mem/rtl/msx_mem.v $CORE"
for t in soc soc_nat soc_hi soc_dma soc_dma3; do iverilog -g2012 -o $O/s_$t.vvp tb_$t.v $SOC && run s_$t vvp -n $O/s_$t.vvp; done
iverilog -g2012 -o $O/s_exc.vvp tb_soc_exc.v $SOC && run s_exc sh -c "for i in 1 2 3 4 5 6 7 8 9 10 11 12; do vvp -n $O/s_exc.vvp +sc=\$i; done"
iverilog -g2012 -DSIM -o $O/s_cart.vvp tb_cart_mon.v $S/r8064_cart_top.v $S/r8064_clkgen.v $S/r8064_slot_if.v $S/r8064_slot_dec.v $SOC && run s_cart_mon sh -c "vvp -n $O/s_cart.vvp; vvp -n $O/s_cart.vvp +p2"
# ---- summary
cd $O; for f in *.txt; do [ "$f" = summary.txt ] && continue; echo "== $f"; grep -aiE "RESULT|ERROR|FAIL|mismatch|diverg" "$f" | grep -v "^WARNING" | sort | uniq -c | head -12; done > summary.txt
echo done
