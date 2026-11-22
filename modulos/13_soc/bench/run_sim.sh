#!/bin/sh
# run_sim.sh - builds the bench firmware and simulates the whole bench (r8064_bench + SDRAM model) with the cartridge build macros.
# Prints the text the PC terminal would show. Needs python3 and iverilog. Usage: sh run_sim.sh [<work dir> [<vvp plusargs: +first=i +last=j>]]
set -e
H=$(cd "$(dirname "$0")" && pwd); W=${1:-$H/simwork}; P=$H/../pnr; shift 2>/dev/null || true
mkdir -p "$W"
python3 "$H/gen_bench.py" "$H/ref_rev53.json" "$W" > "$W/gen.log"
N=$(grep -c ' sim ' "$W/bench.map")
cp "$P"/*.mem "$W"/
FILES=$(head -1 "$P/ys_cart.ys" | tr ' ' '\n' | grep '\.v$' | grep -v 'r8064_cart_top\|r8064_slot_if\|r8064_slot_dec' | sed "s#^#$P/#")
iverilog -g2012 -s tb_bench -DR8064_DMA2 -DR8064_NO_DMA -DR8064_AW32 -DR8064_NO_MD64 -o "$W/tb_bench.vvp" "$H/tb_bench.v" "$H/../rtl/r8064_bench_top.v" "$H/../sim/sdram_model.v" $FILES
cd "$W" && vvp -n tb_bench.vvp +n=$N "$@" | grep -v VIOLATION | tee "$W/sim_out.txt"
