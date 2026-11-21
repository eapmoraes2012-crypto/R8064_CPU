#!/usr/bin/env python3
# fpu_meas.py - hardware FPU throughput on the full core (fpu_unit, 80-bit), native mode, through sim/tb_meas.v (clocks per loop
# iteration; loop with the kernel minus the same loop without it, / N copies). Kernels: dependent FADD/FMUL/FDIV/FSQRT chains and a
# SAXPY-like element y = a*x + a with binary32 load/store (2 FLOP).  Usage: python3 fpu_meas.py <work dir>  (needs iverilog/vvp)
import os, sys, re, subprocess
from concurrent.futures import ThreadPoolExecutor
H = os.path.dirname(os.path.abspath(__file__)); SIM = os.path.abspath(os.path.join(H, '..', '..', 'sim'))
sys.path.insert(0, os.path.join(H, '..', '..', 'msx', 'asm')); from asmref import Asm
W = os.path.abspath(sys.argv[1]); os.makedirs(W, exist_ok=True)
N = 16
K = [('FADD ST0,ST1', ['fadd st0,st1'], 1), ('FMUL ST0,ST1', ['fmul st0,st1'], 1), ('FDIV ST0,ST1', ['fdiv st0,st1'], 1),
     ('FSQRT ST0', ['fsqrt st0'], 1), ('SAXPY element (FLD32, FMUL, FADD, FSP32)', ['fld32 (qhl)', 'fmul st0,st1', 'fadd st0,st1', 'fsp32 (qhl)'], 2)]
def prog(body, empty):
    L = ['        org 0', '        ldw ax,0A5h', '        out (3Dh),a', '        ldw ax,1', '        out (3Eh),a', '        ds 16',
         'loop:   ld sp,3000h', '        ldq hl,2000h', '        finit', '        fld1', '        fld1']
    if not empty: L += ['        ' + x for _ in range(N) for x in body]
    L += ['        jp loop', '        org 2000h'] + ['        dd 3F800000h'] * 64
    return '\n'.join(L) + '\n'
R, C = '../../10_mode_gov/rtl', '../../09_core_min/rtl'; S = '../rtl'
soc = [f'{S}/r8064_soc.v', f'{S}/r8064_memsys.v', f'{S}/mem_arb5.v', f'{S}/r8064_dma.v', f'{S}/r8064_xbuf.v', f'{S}/cache_dm.v', f'{S}/mmu.v', f'{S}/sdram_ctrl.v', 'sdram_model.v',
       f'{R}/r8064_cpu_gov.v', f'{R}/r8064_msx_sys.v', f'{R}/r8064_fifo_if.v', f'{R}/r8064_mode.v', f'{R}/timing_gov.v', f'{R}/mem_class.v', '../../10_msx_mem/rtl/msx_mem.v',
       f'{C}/r8064_core_min.v', f'{C}/r8064_decode.v', f'{C}/r8064_decode_rom.v', f'{C}/regfile64.v', f'{C}/regmap_b.v', f'{C}/regmerge.v', f'{C}/alu_prep.v', f'{C}/alu_core_s.v',
       '../../03_muldiv/rtl/mul_unit.v', '../../03_muldiv/rtl/div_unit.v', '../../08_fpu/rtl/fpu_unit.v', '../../08_fpu/rtl/fpu_seq.v']
vvp = os.path.join(W, 'meas.vvp')
r = subprocess.run(['iverilog', '-g2012', '-o', vvp, 'tb_meas.v'] + soc, cwd=SIM, capture_output=True, text=True)
if r.returncode: raise SystemExit(r.stdout + r.stderr)
def one(name, body, empty):
    p = os.path.join(W, re.sub(r'\W', '_', name) + ('_E' if empty else '') + '.asm'); open(p, 'w').write(prog(body, empty))
    a = Asm(p); out = a.run()
    if a.errors: raise SystemExit('%s: %s' % (name, a.errors[:3]))
    hx = p[:-4] + '.hex'; open(hx, 'w').write('\n'.join('%02x' % b for b in out) + '\n')
    o = subprocess.run(['vvp', '-n', vvp, '+img=' + hx, '+loop=%x' % a.sym['LOOP'][0]], cwd=SIM, capture_output=True, text=True, timeout=1200).stdout
    m = re.search(r'TITER (\S+) native=(\d)', o)
    return float(m.group(1)) if m and m.group(1) != 'NA' else None
with ThreadPoolExecutor(max_workers=2) as ex:
    e = ex.submit(one, 'empty', [], True); fs = [(n, fl, ex.submit(one, n, b, False)) for n, b, fl in K]
    te = e.result()
    for n, fl, f in fs:
        t = f.result(); c = None if t is None or te is None else (t - te) / N
        print('FPU %-44s %7.2f clocks  %6.2f MFLOPS @57.27 MHz' % (n, c, 57.2727 * fl / c) if c else 'FPU %s n/a' % n)
