#!/usr/bin/env python3
# build_board.py - compiles the board benchmarks (bm_board.c + Dhrystone 2.1 + Sieve + SDCC soft float) with SDCC (z80) and writes the
# boot image for the timing-bench bitstream: <out>/board.bin (16 KB) and <out>/monitor_l0..7.hex (lanes of the boot buffer, as gen_bench.py).
# Needs SDCC (SDCC=<dir with bin/ and lib/z80>), SDCC_LIB (sdcc device/lib) and SDCC_INC (sdcc device/include), like ../build.py.
# Usage: python3 build_board.py <out dir> [quick]   (quick = -DBM_QUICK: short runs for the simulation, tb_bmboard.v)
import os, sys, subprocess
H = os.path.dirname(os.path.abspath(__file__)); B = os.path.dirname(H)
SDCC = os.environ.get('SDCC', '/opt/sdcc'); LIB = os.environ['SDCC_LIB']; INC = os.environ['SDCC_INC']
OUT = os.path.abspath(sys.argv[1]); os.makedirs(OUT, exist_ok=True)
Q = ['-DBM_QUICK'] if len(sys.argv) > 2 and sys.argv[2] == 'quick' else []
def run(*a):
    r = subprocess.run(a, capture_output=True, text=True)
    err = [l for l in (r.stdout + r.stderr).splitlines() if 'error' in l.lower()]
    if r.returncode or err: raise SystemExit(' '.join(a) + '\n' + r.stdout + r.stderr)
    return r.stdout + r.stderr
def cc(src, *d):
    rel = os.path.join(OUT, os.path.basename(src).replace('.c', '.rel'))
    run(SDCC + '/bin/sdcc', '-mz80', '-c', '--opt-code-speed', '--nostdinc', '-I' + INC, '-I' + B, '-I' + H, '-DBM_BOARD', *d, src, '-o', rel)
    return rel
subprocess.run([sys.executable, os.path.join(B, 'mkdhry.py')], check=True)
run(SDCC + '/bin/sdasz80', '-o', os.path.join(OUT, 'crt0_board.rel'), os.path.join(H, 'crt0_board.s'))
rels = [os.path.join(OUT, 'crt0_board.rel'), cc(os.path.join(H, 'bm_board.c'), *Q), cc(os.path.join(H, 'bm_rt_board.c')),
        cc(os.path.join(B, 'dhry_1p.c'), '-DTIME', '-DHZ=1', '-DNOENUM', '-DDHRY_ITERS=dhry_runs', '-Dmain=dhry_main'),
        cc(os.path.join(B, 'dhry_2p.c'), '-DTIME', '-DHZ=1', '-DNOENUM', '-DDHRY_ITERS=dhry_runs'),
        cc(os.path.join(B, 'sieve.c'), '-DSIEVE_ITERS=sieve_runs', '-Dmain=sieve_main'),
        cc(os.path.join(B, 'flt.c'), '-DFLT_ITERS=flt_runs', '-Dmain=flt_main')]
ms = os.path.join(OUT, '__mulsint2slong.s')
open(ms, 'w').write(open(os.path.join(LIB, 'z80', '__mulsint2slong.s')).read().replace('.optsdcc -mz80 sdcccall(1)', '.optsdcc -mz80'))
run(SDCC + '/bin/sdasz80', '-o', os.path.join(OUT, '__mulsint2slong.rel'), ms); rels.append(os.path.join(OUT, '__mulsint2slong.rel'))
for f in ['_fsadd', '_fssub', '_fsmul', '_fsdiv', '_fscmp', '_fslt', '_fseq', '_fsneq', '_fs2sint', '_fs2uint', '_fs2slong', '_fs2ulong',
          '_sint2fs', '_uint2fs', '_slong2fs', '_ulong2fs', '_fsnormalize', '_fsrshift', '_fsswapargs', '_fsget1arg', '_fsget2args', '_fsreturnval']:
    p = os.path.join(LIB, f + '.c')
    if os.path.exists(p): rels.append(cc(p))
ihx = os.path.join(OUT, 'board.ihx')
run(SDCC + '/bin/sdcc', '-mz80', '--no-std-crt0', '--code-loc', '0x0100', '--data-loc', '0x8000', '-L' + SDCC + '/lib/z80', '-o', ihx, *rels, 'z80.lib')
img = bytearray(16384)
for l in open(ihx):
    l = l.strip()
    if not l.startswith(':'): continue
    n = int(l[1:3], 16); a = int(l[3:7], 16); t = int(l[7:9], 16)
    if t == 0:
        assert a + n <= 16384, 'code/initialised data beyond the 16 KB boot image: %04X' % a
        img[a:a + n] = bytes.fromhex(l[9:9 + 2 * n])
open(os.path.join(OUT, 'board.bin'), 'wb').write(img)
for g in range(8):
    with open(os.path.join(OUT, 'monitor_l%d.hex' % g), 'w') as f:
        for k in range(2048): f.write('%02X\n' % img[8 * k + g])
top = max(i for i in range(16384) if img[i]) + 1
print('board image: %d bytes used (0000-%04X)' % (top, top - 1))
