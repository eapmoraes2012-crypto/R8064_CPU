#!/bin/sh
# run_board_sim.sh - builds the quick board image and simulates it on r8064_bench (cartridge build macros, CPT 8). Needs SDCC (see build_board.py).
# Usage: sh run_board_sim.sh <work dir>
set -e
H=$(cd "$(dirname "$0")" && pwd); W=$(mkdir -p "$1" && cd "$1" && pwd); P=$H/../../../pnr
python3 "$H/build_board.py" "$W" quick
cp "$P"/*.mem "$W"/
FILES=$(head -1 "$P/ys_cart.ys" | tr ' ' '\n' | grep '\.v$' | grep -v 'r8064_cart_top\|r8064_slot_if\|r8064_slot_dec' | sed "s#^#$P/#")
DEFS=$(head -1 "$P/ys_cart.ys" | tr ' ' '\n' | grep '^-D')
iverilog -g2012 -s tb_bmboard $DEFS -o "$W/tb.vvp" "$H/tb_bmboard.v" "$H/../../../rtl/r8064_bench_top.v" "$H/../../../sim/sdram_model.v" $FILES
cd "$W" && vvp -n tb.vvp | grep -v VIOLATION | tee "$W/sim_out.txt"
