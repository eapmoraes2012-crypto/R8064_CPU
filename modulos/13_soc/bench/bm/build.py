#!/usr/bin/env python3
# build.py - compiles the benchmarks with SDCC (z80 port) and writes one image per benchmark and CPU mode:
#   <out>/<bench>_m<mode>.hex   (1 byte per line, loaded at 0 by tb_bm.v; mode byte at 0010h: 1 Z80, 3 R800, 4 native)
# Benchmarks: dhry (Dhrystone 2.1, DHRY_ITERS runs), sieve (BYTE sieve, 8190 flags), flt (single-precision float: multiply-add, divide)
# Needs: SDCC with the z80 port and its z80.lib (SDCC=<dir with bin/ and lib/z80>), the SDCC float library sources (SDCC_LIB=<sdcc
# device/lib directory>) and include files (SDCC_INC=<sdcc device/include>).  Usage: python3 build.py <out dir> [iters per bench=dhry:N,..]
import os, sys, subprocess, re
H = os.path.dirname(os.path.abspath(__file__))
SDCC = os.environ.get('SDCC', '/opt/sdcc'); LIB = os.environ['SDCC_LIB']; INC = os.environ['SDCC_INC']
OUT = os.path.abspath(sys.argv[1]); os.makedirs(OUT, exist_ok=True)
IT = dict(dhry=20, sieve=1, flt=5)
if len(sys.argv) > 2:
    for kv in sys.argv[2].split(','): k, v = kv.split(':'); IT[k] = int(v)
def run(*a):
    r = subprocess.run(a, capture_output=True, text=True)
    err = [l for l in (r.stdout + r.stderr).splitlines() if 'error' in l.lower()]
    if r.returncode or err: raise SystemExit(' '.join(a) + '\n' + r.stdout + r.stderr)
def cc(src, rel, *d):
    run(SDCC + '/bin/sdcc', '-mz80', '-c', '--opt-code-speed', '--nostdinc', '-I' + INC, '-I' + H, *d, src, '-o', rel)
subprocess.run([sys.executable, os.path.join(H, 'mkdhry.py')], check=True)
run(SDCC + '/bin/sdasz80', '-o', os.path.join(OUT, 'crt0.rel'), os.path.join(H, 'crt0.s'))
cc(os.path.join(H, 'bm_rt.c'), os.path.join(OUT, 'bm_rt.rel'))
# SDCC single-precision float library (C sources of the SDCC distribution)
FL = ['_fsadd', '_fssub', '_fsmul', '_fsdiv', '_fscmp', '_fslt', '_fseq', '_fsneq', '_fs2sint', '_fs2uint', '_fs2slong', '_fs2ulong',
      '_sint2fs', '_uint2fs', '_slong2fs', '_ulong2fs', '_fsnormalize', '_fsrshift', '_fsswapargs', '_fsget1arg', '_fsget2args', '_fsreturnval']
flrel = [os.path.join(OUT, '__mulsint2slong.rel')]
# 16x16->32 multiply used by _fsmul (sdcccall(1) register ABI, the same as this compiler emits; only the module option tag differs)
ms = os.path.join(OUT, '__mulsint2slong.s')
open(ms, 'w').write(open(os.path.join(LIB, 'z80', '__mulsint2slong.s')).read().replace('.optsdcc -mz80 sdcccall(1)', '.optsdcc -mz80'))
run(SDCC + '/bin/sdasz80', '-o', flrel[0], ms)
for f in FL:
    p = os.path.join(LIB, f + '.c')
    if os.path.exists(p): cc(p, os.path.join(OUT, f + '.rel')); flrel.append(os.path.join(OUT, f + '.rel'))
BENCH = {'dhry': (['dhry_1p.c', 'dhry_2p.c'], ['-DTIME', '-DHZ=1', '-DNOENUM', '-DDHRY_ITERS=%d' % IT['dhry']], []),
         'sieve': (['sieve.c'], ['-DSIEVE_ITERS=%d' % IT['sieve']], []),
         'flt': (['flt.c'], ['-DFLT_ITERS=%d' % IT['flt']], flrel)}
for b, (srcs, d, extra) in BENCH.items():
    rels = []
    for s in srcs:
        r = os.path.join(OUT, s.replace('.c', '.rel')); cc(os.path.join(H, s), r, *d); rels.append(r)
    ihx = os.path.join(OUT, b + '.ihx')
    run(SDCC + '/bin/sdcc', '-mz80', '--no-std-crt0', '--code-loc', '0x0100', '--data-loc', '0x8000', '-L' + SDCC + '/lib/z80',
        '-o', ihx, os.path.join(OUT, 'crt0.rel'), *rels, os.path.join(OUT, 'bm_rt.rel'), *extra, 'z80.lib')
    mem = bytearray(65536)
    for l in open(ihx):
        l = l.strip()
        if not l.startswith(':'): continue
        n = int(l[1:3], 16); a = int(l[3:7], 16); t = int(l[7:9], 16)
        if t == 0: mem[a:a + n] = bytes.fromhex(l[9:9 + 2 * n])
    top = max(i for i in range(0x8000) if mem[i]) + 1
    for m in (1, 3, 4):
        mem[0x10] = m
        open(os.path.join(OUT, '%s_m%d.hex' % (b, m)), 'w').write('\n'.join('%02X' % x for x in mem[:0x8000]) + '\n')
    print('%-6s code+data image %5d bytes (0000-%04X), iterations %d' % (b, top, top - 1, IT[b]))
