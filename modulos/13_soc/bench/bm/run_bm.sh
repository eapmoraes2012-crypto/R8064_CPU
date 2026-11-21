#!/bin/sh
# run_bm.sh - compiles tb_bm.v with the full SoC (FPU included) and runs every <bench>_m<mode>.hex of <img dir>.
# Usage: sh run_bm.sh <img dir> [bench ...]   Prints one line per image: bench, mode, clocks start->stop, result bytes.
set -e
H=$(cd "$(dirname "$0")" && pwd); D=$(cd "$1" && pwd); shift; SIM=$H/../../sim
R=../../10_mode_gov/rtl; C=../../09_core_min/rtl; S=../rtl
cp "$H/tb_bm.v" "$SIM/tb_bm.v"
cd "$SIM" && iverilog -g2012 -o "$D/tb_bm.vvp" tb_bm.v $S/r8064_soc.v $S/r8064_memsys.v $S/mem_arb5.v $S/r8064_dma.v $S/r8064_xbuf.v $S/cache_dm.v $S/mmu.v $S/sdram_ctrl.v sdram_model.v \
  $R/r8064_cpu_gov.v $R/r8064_msx_sys.v $R/r8064_fifo_if.v $R/r8064_mode.v $R/timing_gov.v $R/mem_class.v ../../10_msx_mem/rtl/msx_mem.v \
  $C/r8064_core_min.v $C/r8064_decode.v $C/r8064_decode_rom.v $C/regfile64.v $C/regmap_b.v $C/regmerge.v $C/alu_prep.v $C/alu_core_s.v \
  ../../03_muldiv/rtl/mul_unit.v ../../03_muldiv/rtl/div_unit.v ../../08_fpu/rtl/fpu_unit.v ../../08_fpu/rtl/fpu_seq.v
rm -f "$SIM/tb_bm.v"
for b in ${@:-dhry sieve flt}; do for m in 1 3 4; do
  printf '%-6s m%d ' $b $m; (cd "$SIM" && vvp -n "$D/tb_bm.vvp" +img="$D/${b}_m$m.hex" | grep '^BM')
done; done
