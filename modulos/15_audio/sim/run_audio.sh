#!/bin/bash
# run_audio.sh - audio subsystem regression (iverilog). Usage: sim/run_audio.sh [work dir]
set -e
export PATH=/opt/oss/oss-cad-suite/bin:$PATH
cd "$(dirname "$0")"; W=${1:-/tmp/aud_sim}; mkdir -p $W
RTL=$(ls ../rtl/*.v)
for t in tb_slot_full tb_audio1; do iverilog -g2012 -o $W/$t.vvp $t.v $RTL; done
vvp -n $W/tb_slot_full.vvp | grep RESULT
(cd $W && vvp -n $W/tb_audio1.vvp | grep RESULT && python3 $OLDPWD/check_audio1.py aud1_out.txt | grep RESULT)
