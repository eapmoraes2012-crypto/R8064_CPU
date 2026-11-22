#!/usr/bin/env python3
# gen_fpu_board.py - FPU test for the board (Tang Nano 20K, timing-bench bitstream r8064_bench_top): native-mode program that runs each FPU
# instruction on fixed operands, stores the 80-bit result (FST80) and times it with the bench timer (ports F0h/F1h, F4h-F7h), then prints
#   <name> <result, 20 hex digits> <clocks> <OK/DIFF>
# where OK = the 80-bit result AND the clocks are equal to the RTL simulation. The simulation values are obtained here: pass 1 builds the
# image without them and runs it on the RTL (tb_bmboard.v, cartridge build macros, CPT 8), pass 2 embeds them (and checks that the RTL
# prints all OK). Clocks = window [OUT F0h; instruction; FST80; OUT F1h] minus the same window without the instruction; each test runs twice
# and the second (warm) run is reported.
# Writes <out>/board.bin (16 KB boot image), <out>/monitor_l0..7.hex (boot buffer lanes) and <out>/fpu_ref.txt (RTL results).
# Usage: python3 gen_fpu_board.py <out dir>     (needs iverilog/vvp)
import os, sys, struct, subprocess, re, math
H = os.path.dirname(os.path.abspath(__file__)); B = os.path.dirname(H); S13 = os.path.dirname(B); P = os.path.join(S13, 'pnr')
sys.path.insert(0, os.path.join(S13, 'msx', 'asm')); from asmref import Asm
OUT = os.path.abspath(sys.argv[1]); os.makedirs(OUT, exist_ok=True)
d64 = lambda x: struct.pack('<d', x)
# (name, operand A or None, operand B or None, instruction lines). Loads: FLD64 A then FLD64 B -> ST0 = B, ST1 = A.
T = [('(none: timing base)', 1.0, None, [])]
for a, b in ((1.5, 2.25), (3.0, -7.0), (1e300, 1e300), (1.0, 3.0), (-0.1, 0.7)):
    T += [('FADD  %g+%g' % (b, a), a, b, ['fadd st0,st1']), ('FSUB  %g-%g' % (b, a), a, b, ['fsub st0,st1']),
          ('FMUL  %g*%g' % (b, a), a, b, ['fmul st0,st1']), ('FDIV  %g/%g' % (b, a), a, b, ['fdiv st0,st1'])]
T += [('FDIV  1/0', 0.0, 1.0, ['fdiv st0,st1']), ('FDIV  0/0', 0.0, 0.0, ['fdiv st0,st1'])]
for x in (2.0, 0.5, 1e-300, 12345.678, -1.0):
    T.append(('FSQRT %g' % x, None, x, ['fsqrt st0']))
for x in (0.5, 1.0, 3.0, -2.5, 100.0):
    T += [('FSIN  %g' % x, None, x, ['fsin st0']), ('FCOS  %g' % x, None, x, ['fcos st0']), ('FTAN  %g' % x, None, x, ['ftan st0'])]
for x in (2.0, 10.0, 0.001):
    T.append(('FLN   %g' % x, None, x, ['fln st0']))
T += [('FYL2X 3*log2(8)', 3.0, 8.0, ['fyl2x']), ('FYL2P 1*log2(1+0.5)', 1.0, 0.5, ['fyl2p']),
      ('FREM  10 rem 3', 3.0, 10.0, ['frem']), ('FREM1 10 rem1 3', 3.0, 10.0, ['frem1']),
      ('FABS  -2.5', None, -2.5, ['fabs']), ('FCHS  2.5', None, 2.5, ['fchs']), ('FRINT 2.5', None, 2.5, ['frint']), ('FRINT -3.7', None, -3.7, ['frint']),
      ('FLDPI', None, None, ['fldpi']), ('FLDL2 (log2 10)', None, None, ['fldl2']), ('FLDLG (log10 2)', None, None, ['fldlg']),
      ('FLDLN (ln 2)', None, None, ['fldln']), ('FLD1', None, None, ['fld1']), ('FLDZ', None, None, ['fldz'])]
N = len(T)

def program(ref):
    L = ['        org 0', 'start:  ld sp,7F00h', '        ld a,0A5h', '        out (3Dh),a', '        ld a,1', '        out (3Eh),a', '        ds 16',
         '        xor a', '        ld (V_OK),a', '        ld (V_OK+1),a', '        ld (V_DF),a', '        ld (V_DF+1),a', '        ld (V_COL),a', '        ld (V_BASE),a', '        ld (V_BASE+1),a',
         '        ld hl,S_HEAD', '        call puts']
    for i, (name, a, b, ins) in enumerate(T):
        L += ['        ld a,2', '        ld (V_CNT),a', 't%d:    finit' % i]
        if a is not None: L += ['        ldq hl,OA%d' % i, '        fld64 (qhl)']
        if b is not None: L += ['        ldq hl,OB%d' % i, '        fld64 (qhl)']
        L += ['        ldq hl,RES', '        out (0F0h),a'] + ['        ' + x for x in ins] + ['        fst80 (qhl)', '        out (0F1h),a',
              '        ld a,(V_CNT)', '        dec a', '        ld (V_CNT),a', '        jr nz,t%d' % i,
              '        ld hl,NM%d' % i, '        ld de,EX%d' % i, '        call report']
        if i == 0: L += ['        ld hl,(V_CK)', '        ld (V_BASE),hl']
    L += ['        ld hl,S_DONE1', '        call puts', '        ld hl,(V_OK)', '        call putd', '        ld hl,S_DONE2', '        call puts',
          '        ld hl,(V_DF)', '        call putd', '        ld hl,S_DONE3', '        call puts', 'halt_:  jr halt_',
          # report: HL = name, DE = expected record (10 result bytes + 2 clocks). Prints the line, updates the counters.
          'report: push de', '        call puts', '        ld a,(V_COL)', 'rp_pad: cp 24', '        jr nc,rp_pd2', '        push af', '        ld a,32', '        call putc',
          '        pop af', '        inc a', '        jr rp_pad', 'rp_pd2: ld hl,RES+9', '        ld b,10', 'rp_hx:  ld a,(hl)', '        call puth', '        dec hl', '        djnz rp_hx',
          '        ld a,32', '        call putc',
          '        in a,(0F4h)', '        ld l,a', '        in a,(0F5h)', '        ld h,a', '        ld (V_CK),hl', '        ld de,(V_BASE)', '        or a', '        sbc hl,de',
          '        ld (V_NET),hl', '        call putd6', '        pop de', '        ld hl,RES', '        ld b,10', '        ld c,0',
          'rp_cmp: ld a,(de)', '        cp (hl)', '        jr z,rp_c2', '        inc c', 'rp_c2:  inc hl', '        inc de', '        djnz rp_cmp',
          '        ld hl,(V_NET)', '        ld a,(de)', '        cp l', '        jr z,rp_c3', '        inc c', 'rp_c3:  inc de', '        ld a,(de)', '        cp h', '        jr z,rp_c4', '        inc c',
          'rp_c4:  ld a,c', '        or a', '        jr nz,rp_df', '        ld hl,S_OK', '        call puts', '        ld hl,(V_OK)', '        inc hl', '        ld (V_OK),hl', '        ret',
          'rp_df:  ld hl,S_DF', '        call puts', '        ld hl,(V_DF)', '        inc hl', '        ld (V_DF),hl', '        ret',
          # putd6: HL decimal right-aligned in 6 columns; putd: HL decimal
          'putd6:  push hl', '        ld b,0', '        ld de,10000', '        call pd_cnt', '        ld de,1000', '        call pd_cnt', '        ld de,100', '        call pd_cnt',
          '        ld de,10', '        call pd_cnt', '        pop hl', '        ld a,5', '        sub b', '        ld b,a', 'pd_sp:  ld a,32', '        call putc', '        djnz pd_sp',
          '        jr putd',
          'pd_cnt: or a', '        sbc hl,de', '        add hl,de', '        ret c', '        inc b', '        ret',
          'putd:   ld c,0', '        ld de,10000', '        call pd_dig', '        ld de,1000', '        call pd_dig', '        ld de,100', '        call pd_dig',
          '        ld de,10', '        call pd_dig', '        ld a,l', '        add a,30h', '        jr putc',
          'pd_dig: ld a,0', 'pd_d1:  or a', '        sbc hl,de', '        jr c,pd_d2', '        inc a', '        jr pd_d1', 'pd_d2:  add hl,de', '        ld b,a', '        or c',
          '        ret z', '        ld c,1', '        ld a,b', '        add a,30h', '        jr putc',
          'puth:   push af', '        rrca', '        rrca', '        rrca', '        rrca', '        call puth1', '        pop af',
          'puth1:  and 0Fh', '        add a,30h', '        cp 3Ah', '        jr c,putc', '        add a,7', '        jr putc',
          'puts:   ld a,(hl)', '        or a', '        ret z', '        call putc', '        inc hl', '        jr puts',
          'putc:   push af', 'pc_w:   in a,(90h)', '        and 1', '        jr nz,pc_w', '        pop af', '        out (90h),a',
          '        cp 10', '        jr nz,pc_c', '        xor a', '        ld (V_COL),a', '        ret', 'pc_c:   push af', '        ld a,(V_COL)', '        inc a', '        ld (V_COL),a',
          '        pop af', '        ret',
          'S_HEAD: db 13,10,"R8064 FPU test (REV54, 80-bit FPU, native mode) - result: ST0 after the instruction (FST80, 20 hex digits)",13,10',
          '        db "clocks: instruction latency up to the result in memory; OK = result and clocks equal to the RTL simulation",13,10,13,10',
          '        db "instruction             result (80-bit)       clocks",13,10,0',
          'S_OK:   db "  OK",13,10,0', 'S_DF:   db "  DIFF",13,10,0',
          'S_DONE1: db 13,10,"Done: ",0', 'S_DONE2: db " OK, ",0', 'S_DONE3: db " different. Press KEY1 to run again.",13,10,0']
    for i, (name, a, b, ins) in enumerate(T):
        L.append('NM%d:   db "%s",0' % (i, name))
        if a is not None: L.append('OA%d:   db ' % i + ','.join('%d' % x for x in d64(a)))
        if b is not None: L.append('OB%d:   db ' % i + ','.join('%d' % x for x in d64(b)))
        r, c = ref[i] if ref else (bytes(10), 0)
        L.append('EX%d:   db ' % i + ','.join('%d' % x for x in r) + ',%d,%d' % (c & 255, c >> 8))
    L += ['        org 7F00h', 'RES:    ds 16', 'V_CNT:  ds 1', 'V_COL:  ds 1', 'V_CK:   ds 2', 'V_BASE: ds 2', 'V_NET:  ds 2', 'V_OK:   ds 2', 'V_DF:   ds 2']
    return '\n'.join(L) + '\n'

def build(ref):
    p = os.path.join(OUT, 'fpu_board.asm'); open(p, 'w').write(program(ref))
    a = Asm(p); out = a.run()
    if a.errors: raise SystemExit('asm: %s' % a.errors[:5])
    img = bytearray(16384); code = bytes(out[:0x7F00]).rstrip(b'\0')
    assert len(code) <= 16384, 'image beyond 16 KB: %d' % len(code)
    img[:len(code)] = code
    open(os.path.join(OUT, 'board.bin'), 'wb').write(img)
    for g in range(8):
        with open(os.path.join(OUT, 'monitor_l%d.hex' % g), 'w') as f:
            for k in range(2048): f.write('%02X\n' % img[8 * k + g])
    return len(code)

def sim():
    W = os.path.join(OUT, 'sim'); os.makedirs(W, exist_ok=True)
    for f in os.listdir(OUT):
        if f.startswith('monitor_l'): open(os.path.join(W, f), 'w').write(open(os.path.join(OUT, f)).read())
    for f in os.listdir(P):
        if f.endswith('.mem'): open(os.path.join(W, f), 'w').write(open(os.path.join(P, f)).read())
    first = open(os.path.join(P, 'ys_cart.ys')).read().split('\n')[0].split()
    files = [os.path.join(P, f) for f in first if f.endswith('.v') and not re.search(r'r8064_cart_top|r8064_slot_if|r8064_slot_dec', f)]
    defs = [f for f in first if f.startswith('-D')]
    vvp = os.path.join(W, 'tb.vvp')
    if not os.path.exists(vvp):
        r = subprocess.run(['iverilog', '-g2012', '-s', 'tb_bmboard', *defs, '-o', vvp, os.path.join(B, 'bm', 'board', 'tb_bmboard.v'),
                            os.path.join(S13, 'rtl', 'r8064_bench_top.v'), os.path.join(S13, 'sim', 'sdram_model.v'), *files], capture_output=True, text=True)
        if r.returncode: raise SystemExit(r.stdout + r.stderr)
    o = subprocess.run(['vvp', '-n', vvp], cwd=W, capture_output=True, text=True, timeout=7200).stdout
    o = '\n'.join(l for l in o.split('\n') if 'VIOLATION' not in l)
    open(os.path.join(OUT, 'sim_out.txt'), 'w').write(o)
    res = []
    for l in o.split('\n'):
        m = re.match(r'(.{24})([0-9A-F]{20}) +(-?\d+) +(OK|DIFF)', l)
        if m: res.append((bytes.fromhex(m.group(2))[::-1], int(m.group(3)) & 0xFFFF, m.group(1).rstrip(), m.group(4)))
    return o, res

if os.environ.get('FPU_REUSE') and os.path.exists(os.path.join(OUT, 'sim_out.txt')):   # debugging: reuse the last pass-2 output
    r2 = [(bytes.fromhex(m.group(2))[::-1], int(m.group(3)) & 0xFFFF, m.group(1).rstrip(), m.group(4)) for m in
          (re.match(r'(.{24})([0-9A-F]{20}) +(-?\d+) +(OK|DIFF)', l) for l in open(os.path.join(OUT, 'sim_out.txt'))) if m]
else:
  n = build(None); print('pass 1: image %d bytes, %d tests; RTL simulation...' % (n, N))
  o, r1 = sim()
  if len(r1) != N: raise SystemExit('pass 1: %d of %d results\n%s' % (len(r1), N, o[-2000:]))
  ref = [(r, c) for r, c, _, _ in r1]
  build(ref); print('pass 2: RTL simulation with the reference values...')
  o, r2 = sim()
  bad = [x for x in r2 if x[3] != 'OK']
  if len(r2) != N or bad: raise SystemExit('pass 2: %d results, %d not OK\n%s' % (len(r2), len(bad), o[-3000:]))
def f80(b):
    m = int.from_bytes(b[:8], 'little'); se = int.from_bytes(b[8:], 'little'); s = -1 if se >> 15 else 1; e = se & 0x7FFF
    if e == 0x7FFF: return 'nan' if m & ((1 << 63) - 1) else ('-inf' if s < 0 else 'inf')
    from decimal import Decimal, getcontext; getcontext().prec = 40
    v = Decimal(m) * (Decimal(2) ** (e - 16383 - 63)) if e else Decimal(0)
    return ('-' if s < 0 else '') + ('%.17g' % float(v) if abs(v) < Decimal('1e308') else '{:.16E}'.format(v))
with open(os.path.join(OUT, 'fpu_ref.txt'), 'w') as f:
    for (name, a, b, ins), (r, c, _, _) in zip(T, r2): f.write('%-24s %s %6d  = %s\n' % (name, r[::-1].hex().upper(), c - (1 << 16 if c >= 1 << 15 else 0), f80(r)))
print('pass 2: %d/%d OK on the RTL; reference in %s' % (len(r2), N, os.path.join(OUT, 'fpu_ref.txt')))
