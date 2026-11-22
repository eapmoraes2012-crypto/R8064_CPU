#!/usr/bin/env python3
# gen_bench.py - builds the firmware image of the timing bench (r8064_bench_top) for the bare Tang Nano 20K.
# The cases are the same as sim/meas/gen_meas.py (every instruction measured in simulation). Each case is stored as a small descriptor;
# the firmware rebuilds the loop at BUILD (same address modulo 1 KB as in the simulation, so the caches see the same layout) and runs it.
# Output (in <out dir>, default ./out): bench.bin (16 KB), monitor_l0..7.hex (the boot image lanes read by r8064_xbuf), bench.map (cases)
# Usage: python3 gen_bench.py [<reference json from gen_meas, default ref_rev52.json>] [<out dir>]
import sys, os, json, tempfile
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.abspath(os.path.join(HERE, '..', '..', '..'))
REF = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, 'ref_rev52.json')
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, 'out')
os.makedirs(OUT, exist_ok=True)
TMP = tempfile.mkdtemp(prefix='bench_')
sys.argv = ['gen_meas', ROOT, os.path.join(TMP, 'w')]          # gen_meas reads its arguments at import time
sys.path.insert(0, os.path.join(HERE, '..', 'sim', 'meas'))
import gen_meas as G
from asmref import Asm

BUILD = 0x3C1E                     # = 001Eh (loop address in the simulation) modulo 400h (1 KB instruction cache)
PREFIX = ['ld sp,3000h', 'ldq bc,2000h', 'ldq de,2010h', 'ldq hl,2020h', 'ldq ix,2030h', 'ldq iy,2040h', 'ldq ax,2050h', 'xor a']
REGIONS = [(None, 0x2000), (0x2500, 0x2E00), (0x3100, 0x3C00)]   # firmware + tables; 2000h-23FFh and 2E00h-30FFh are the data of the loops

def asm(lines, org=BUILD, defs=None):
    p = os.path.join(TMP, 't.asm')
    txt = ['        org %d' % org] + ['%s equ %d' % (k, v) for k, v in (defs or {}).items()] + lines
    open(p, 'w').write('\n'.join(txt) + '\n')
    a = Asm(p); out = a.run()
    if a.errors: raise SystemExit('asm error: %s\n%s' % (a.errors[:3], '\n'.join(txt)))
    return bytes(out), a

def program(c, empty):          # the same text as gen_meas.program, at BUILD, without the mode switch
    L = ['loop:   ' + PREFIX[0]] + ['        ' + x for x in PREFIX[1:]] + ['        ' + x for x in c['init']]
    for _ in range(c.get('n_copies', c['n'])):
        for ln in c['src'].split('\n'):
            if ln.endswith(':'): L.append(ln)
            elif not empty: L.append('        ' + ln)
    L.append('        jp loop')
    L += [('        ' + x) if not x.startswith('sub:') else x for x in c['sub']]
    return L

PB, _ = asm(['        ' + x for x in PREFIX])
def descriptor(c):
    full, a = asm(program(c, False)); emp, _ = asm(program(c, True))
    nc = c.get('n_copies', c['n'])
    labels = {k: v[0] for k, v in a.sym.items() if k in ('AFTER', 'SUB')}
    eb, _ = asm(['        ' + x for x in PREFIX + c['init']], defs={k: BUILD for k in labels})
    E = full[len(PB):len(eb)]            # the extra initialisation as in the full loop (its AFTER/SUB values are the real ones)
    sb, _ = asm([('        ' + x) if not x.startswith('sub:') else x for x in c['sub']], defs={}) if c['sub'] else (b'', None)
    body = full[len(PB) + len(E): len(full) - 3 - len(sb)]
    assert len(body) % nc == 0, c['key']
    L = len(body) // nc; cp = [body[k * L:(k + 1) * L] for k in range(nc)]
    diff = sorted({i for k in range(nc) for i in range(L) if cp[k][i] != cp[0][i]})
    fix = 0xFF
    if diff:
        fix = diff[0] if all(i in (diff[0], diff[0] + 1) for i in diff) else None
        assert fix is not None, c['key']
    for k in range(nc):                       # the firmware writes the 16-bit field = address of the next instruction
        start = BUILD + len(PB) + len(E) + k * L
        if fix != 0xFF:
            v = cp[k][fix] | cp[k][fix + 1] << 8
            assert v == start + L, (c['key'], hex(v), hex(start + L))
            exp = cp[0][:fix] + bytes([(start + L) & 255, (start + L) >> 8]) + cp[0][fix + 2:]
        else: exp = cp[0]
        assert exp == cp[k], c['key']
    tail = bytes([0xC3, BUILD & 255, BUILD >> 8])
    assert full[len(full) - 3 - len(sb):len(full) - len(sb)] == tail and full[len(full) - len(sb):] == sb, c['key']
    # the empty loop as the firmware builds it: identical to the simulation except the values of AFTER/SUB inside E (not used there)
    eb2 = PB + E + tail + sb
    assert len(eb2) == len(emp) and all(x == y for i, (x, y) in enumerate(zip(eb2, emp)) if not (len(PB) <= i < len(PB) + len(E))), c['key']
    copy0 = cp[0] if fix == 0xFF else cp[0][:fix] + b'\0\0' + cp[0][fix + 2:]
    return dict(nc=nc, E=E, I=copy0, fix=fix, S=sb)

ref = json.load(open(REF))['cases']
recs = []
SKIP_CART = {13, 17, 24, 30}        # MLTSQ/MLTUQ/DIVSQ/DIVUQ: not in the cartridge build (R8064_NO_MD64), same RTL as this bench
for c in G.cases:
    if c['id'] in SKIP_CART: continue
    r = ref[c['key']]
    v = r['pair'] if c.get('derive') else r['clocks']
    name = c['name'].replace('’', "'")
    if c.get('derive'): name += ' +CALL'
    if c.get('per') == 'element': name += ' /elem'
    name = name.encode('ascii', 'replace').decode()[:31]
    d = descriptor(c)
    sh = 9 if c['n'] == 16 else 5
    assert c['n'] in (1, 16)
    d.update(key=c['key'], name=name, sim=int(v * 100 + 1e-6), shift=sh)
    recs.append(d)


# ---------------------------------------------------------------- self test printed at power-up / KEY1 (run 0), before anything else
# Straight-line code: the UART is driven with IN/OUT only, so a broken memory path or stack still shows which step fails.
#   expected line:  "selftest: M=5A W=1234 D=2000 C=31 S=ABCD R K X=1234 E=7788"
_ST = [0]
def _lbl():
    _ST[0] += 1; return 'tq%d' % _ST[0]      # not 'stN': ST0-ST7 are FPU registers
def st_putc(ch):                    # ch: assembler expression (character or register C already loaded when ch is None)
    l = _lbl(); r = [] if ch is None else ['        ld c,%s' % ch]
    return r + ['%s:    in a,(90h)' % l, '        and 1', '        jr nz,%s' % l, '        ld a,c', '        out (90h),a']
def st_puts(t): return sum((st_putc('%d' % ord(ch)) for ch in t), [])
def st_hexa():                      # prints A in hex (destroys A, B, C)
    r = ['        ld b,a', '        rrca', '        rrca', '        rrca', '        rrca']
    for first in (True, False):
        l = _lbl()
        if not first: r += ['        ld a,b']
        r += ['        and 0Fh', '        add a,30h', '        cp 3Ah', '        jr c,%s' % l, '        add a,7', '%s:    ld c,a' % l]
        r += st_putc(None)
    return r
def selftest():
    r = ['        in a,(P_GO)', '        ld c,a', '        in a,(P_RUNH)', '        or c', '        jp nz,st_end']
    r += st_puts('\r\nselftest: M=')
    r += ['        ld hl,2410h', '        ld a,5Ah', '        ld (hl),a', '        xor a', '        ld a,(hl)'] + st_hexa()
    r += st_puts(' W=') + ['        ld hl,1234h', '        ld (2412h),hl', '        ld hl,0', '        ld hl,(2412h)', '        ld a,h'] + st_hexa() + ['        ld hl,(2412h)', '        ld a,l'] + st_hexa()
    r += st_puts(' D=') + ['        ld a,(2001h)'] + st_hexa() + ['        ld a,(2000h)'] + st_hexa()
    r += st_puts(' C=') + ['        ld a,(0000h)'] + st_hexa()
    r += st_puts(' S=') + ['        ld sp,STK', '        ld de,0', '        ld bc,0ABCDh', '        push bc', '        pop de', '        ld a,d'] + st_hexa() + ['        ld a,e'] + st_hexa()
    r += st_puts(' R') + ['        ld sp,STK', '        call st_sub', '        jr st_ret', 'st_sub:'] + st_puts(' K') + ['        ret', 'st_ret:']
    # ED page last (a wrong decode derails the rest): Z80 ED instruction, then an R8064 extension (64-bit load)
    r += st_puts(' X=') + ['        ld de,0', '        ld de,(2412h)', '        ld a,d'] + st_hexa() + ['        ld de,(2412h)', '        ld a,e'] + st_hexa()
    r += st_puts(' E=') + ['        ldq hl,1122334455667788h', '        ld a,h'] + st_hexa() + ['        ld a,l'] + st_hexa() + st_puts('\r\n')
    r += ['st_end: ld sp,STK']
    return '\n'.join(r)

# ---------------------------------------------------------------- firmware
FW = r'''
P_TX    equ 90h
P_LP    equ 91h
P_GO    equ 92h
P_RL    equ 93h
P_RH    equ 94h
P_ST    equ 95h
P_OKL   equ 96h
P_OKH   equ 97h
P_DFL   equ 98h
P_DFH   equ 99h
P_RUNH  equ 9Ah
BUILD   equ %(BUILD)d
NCASE   equ %(NCASE)d
V       equ 2400h
V_R     equ V+0
V_FULL  equ V+2
V_FL    equ V+3
V_NC    equ V+4
V_IL    equ V+5
V_IP    equ V+6
V_FX    equ V+8
V_SB    equ V+10
V_K     equ V+12
V_DST   equ V+14
V_SIM   equ V+16
V_HW    equ V+18
V_SH    equ V+20
V_D     equ V+24
STK     equ 2500h
        org 0
start:  ld sp,STK
        ld a,0A5h
        out (3Dh),a
        ld a,1
        out (3Eh),a           ; NATIVE64 = 1 (takes effect at an instruction boundary)
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ld bc,0
        ld de,0
        ld hl,0
        ld ix,0
        ld iy,0
        xor a
%(SELFTEST)s
        ldq bc,0              ; the register file is not reset with the SoC: clear the upper bits left by the previous loop
        ldq de,0
        ldq hl,0
        ldq ix,0
        ldq iy,0
        ldq ax,0
        in a,(P_GO)
        ld l,a
        in a,(P_RUNH)
        ld h,a
        ld (V_R),hl
        ld a,h
        or l
        call z,banner
        ld hl,(V_R)
        ld a,l
        and 1
        jr nz,odd
        ld a,h
        or l
        jr z,even0
        srl h
        rr l
        dec hl
        call recp
        call report           ; the last two runs were the empty loop and the loop of case (run/2 - 1)
even0:  ld hl,(V_R)
        srl h
        rr l
        ld de,NCASE
        or a
        sbc hl,de
        jp nc,finish
        add hl,de
        xor a                 ; empty loop of case run/2
        jr go
odd:    srl h
        rr l
        ld a,1                ; loop with the instruction, case (run-1)/2
go:     ld (V_FULL),a
        call recp
        push hl
        call mkloop
        pop hl
        ld a,(hl)
        ld (V_SH),a
        ld a,BUILD & 0FFh
        out (P_LP),a
        ld a,BUILD >> 8
        out (P_LP),a
        xor a
        out (P_LP),a
        out (P_LP),a
        fence
        isync
        ld a,(V_SH)
        out (P_GO),a          ; arm the counter (data = divider shift)
        jp BUILD              ; the bench resets the SoC after 37 passes through BUILD

recp:   add hl,hl             ; HL = case number -> HL = descriptor
        ld de,PTAB
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ex de,hl
        ret

; descriptor: +0 shift, +1 copies, +2 sim value (hundredths), +4 name, +6 len E, E..., len I, I..., fix offset (FFh none), len S, S...
mkloop: inc hl
        ld a,(hl)
        ld (V_NC),a
        inc hl
        inc hl
        inc hl
        inc hl
        inc hl
        ld de,BUILD
        push hl
        ld hl,PREFIX
        ld bc,PRELEN
        ldir
        pop hl
        ld c,(hl)
        inc hl
        ld b,0
        ld a,c
        or a
        jr z,b_noe
        ldir                  ; extra initialisation
b_noe:  ld a,(hl)
        ld (V_IL),a
        inc hl
        ld (V_IP),hl
        ld c,a
        ld b,0
        add hl,bc
        ld a,(hl)
        ld (V_FX),a
        inc hl
        ld (V_SB),hl
        ld a,(V_FULL)
        or a
        jr z,b_tail
        ld a,(V_NC)
        ld (V_K),a
b_copy: ld (V_DST),de
        ld hl,(V_IP)
        ld a,(V_IL)
        ld c,a
        ld b,0
        ldir                  ; one copy of the instruction
        ld a,(V_FX)
        cp 0FFh
        jr z,b_nofx
        ld hl,(V_DST)         ; absolute target = address of the next instruction (DE)
        ld c,a
        ld b,0
        add hl,bc
        ld (hl),e
        inc hl
        ld (hl),d
b_nofx: ld a,(V_K)
        dec a
        ld (V_K),a
        jr nz,b_copy
b_tail: ex de,hl
        ld (hl),0C3h          ; JP BUILD
        inc hl
        ld (hl),BUILD & 0FFh
        inc hl
        ld (hl),BUILD >> 8
        inc hl
        ex de,hl
        ld hl,(V_SB)
        ld c,(hl)
        inc hl
        ld b,0
        ld a,c
        or a
        ret z
        ldir                  ; subroutine of the CALL cases
        ret

report: inc hl
        inc hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld (V_SIM),de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ex de,hl
        ld c,33
r_nm:   ld a,(hl)
        or a
        jr z,r_pad
        call putc
        inc hl
        dec c
        jr r_nm
r_pad:  ld a,' '
        call putc
        dec c
        jr nz,r_pad
        in a,(P_RL)
        ld l,a
        in a,(P_RH)
        ld h,a
        ld (V_HW),hl
        call pdec
        ld a,' '
        call putc
        ld hl,(V_SIM)
        call pdec
        ld a,' '
        call putc
        ld a,' '
        call putc
        in a,(P_ST)
        or a
        jr z,r_cmp
        ld hl,s_tmo
        and 1
        jr nz,r_bad
        ld hl,s_neg
        jr r_bad
r_cmp:  ld hl,(V_HW)
        ld de,(V_SIM)
        or a
        sbc hl,de
        inc hl                ; OK when |hardware - simulation| <= 0.01
        ld a,h
        or a
        jr nz,r_dif
        ld a,l
        cp 3
        jr nc,r_dif
        ld hl,s_ok
        call puts
        in a,(P_OKL)
        ld l,a
        in a,(P_OKH)
        ld h,a
        inc hl
        ld a,l
        out (P_OKL),a
        ld a,h
        out (P_OKH),a
        ret
r_dif:  ld hl,s_dif
r_bad:  call puts
        in a,(P_DFL)
        ld l,a
        in a,(P_DFH)
        ld h,a
        inc hl
        ld a,l
        out (P_DFL),a
        ld a,h
        out (P_DFH),a
        ret

finish: ld hl,s_end1
        call puts
        in a,(P_OKL)
        ld l,a
        in a,(P_OKH)
        ld h,a
        call pint
        ld hl,s_end2
        call puts
        in a,(P_DFL)
        ld l,a
        in a,(P_DFH)
        ld h,a
        call pint
        ld hl,s_end3
        call puts
f_stop: jr f_stop

banner: ld hl,s_ban
puts:   ld a,(hl)
        or a
        ret z
        call putc
        inc hl
        jr puts

putc:   push bc
        ld b,a
p_w:    in a,(P_TX)
        and 1
        jr nz,p_w
        ld a,b
        out (P_TX),a
        pop bc
        ret

digits: ld de,10000           ; HL -> V_D+0..4 (decimal digits)
        call dig
        ld (V_D),a
        ld de,1000
        call dig
        ld (V_D+1),a
        ld de,100
        call dig
        ld (V_D+2),a
        ld de,10
        call dig
        ld (V_D+3),a
        ld a,l
        ld (V_D+4),a
        ret
dig:    ld b,0
d_l:    or a
        sbc hl,de
        jr c,d_d
        inc b
        jr d_l
d_d:    add hl,de
        ld a,b
        ret

pdec:   call digits           ; HL = hundredths -> "ddd.dd" (6 characters)
        ld hl,V_D
        ld b,2
        ld c,0
pd_l:   ld a,(hl)
        or c
        jr nz,pd_n
        ld a,' '
        call putc
        jr pd_x
pd_n:   ld c,1
        ld a,(hl)
        add a,'0'
        call putc
pd_x:   inc hl
        djnz pd_l
        ld a,(hl)
        add a,'0'
        call putc
        inc hl
        ld a,'.'
        call putc
        ld a,(hl)
        add a,'0'
        call putc
        inc hl
        ld a,(hl)
        add a,'0'
        call putc
        ret

pint:   call digits           ; HL = integer, no leading zeros
        ld hl,V_D
        ld b,4
        ld c,0
pi_l:   ld a,(hl)
        or c
        jr z,pi_x
        ld c,1
        ld a,(hl)
        add a,'0'
        call putc
pi_x:   inc hl
        djnz pi_l
        ld a,(hl)
        add a,'0'
        call putc
        ret

s_ban:  db 13,10,13,10,"R8064 REV48 timing bench - Tang Nano 20K, native mode, code and data in cache",13,10
        db "clocks per instruction: hardware (this board) and simulation (RTL)",13,10,13,10
        db "instruction                       hardware  simul.  result",13,10
        db "--------------------------------- -------- ------- ------",13,10,0
s_ok:   db "OK",13,10,0
s_dif:  db "DIFF",13,10,0
s_tmo:  db "TIMEOUT",13,10,0
s_neg:  db "ERROR",13,10,0
s_end1: db 13,10,"Done: ",0
s_end2: db " OK, ",0
s_end3: db " different. Press KEY1 to run again.",13,10,0
PREFIX: db %(PREFIX)s
PRELEN  equ $-PREFIX
fw_end:
'''

def dbs(b): return ','.join('%d' % x for x in b)
def record(d):
    b = bytes([d['shift'], d['nc'], d['sim'] & 255, d['sim'] >> 8, 0, 0, len(d['E'])]) + d['E'] + bytes([len(d['I'])]) + d['I'] + bytes([d['fix'], len(d['S'])]) + d['S']
    return b

fw_src = FW % dict(BUILD=BUILD, NCASE=len(recs), PREFIX=dbs(PB), SELFTEST=selftest())
fw_probe, a = asm(fw_src.split('\n') + ['PTAB:'], org=0)
fw_end = a.sym['FW_END'][0]
ptab = fw_end; pos = ptab + 2 * len(recs)
# place each record + name in the free regions
regions = [[pos, REGIONS[0][1]]] + [list(r) for r in REGIONS[1:]]
img = bytearray(16384); place = []
for d in recs:
    blob = record(d); nm = d['name'].encode() + b'\0'
    for r in regions:
        if r[0] + len(blob) + len(nm) <= r[1]:
            at = r[0]; r[0] += len(blob) + len(nm); break
    else: raise SystemExit('the descriptors do not fit in the free regions')
    n_at = at + len(blob); blob = blob[:4] + bytes([n_at & 255, n_at >> 8]) + blob[6:]
    img[at:at + len(blob)] = blob; img[n_at:n_at + len(nm)] = nm; place.append(at)
fw, a = asm(fw_src.split('\n') + ['PTAB:'] + ['        dw %d' % p for p in place], org=0)
assert a.sym['FW_END'][0] == fw_end
img[:len(fw)] = fw
for lo, hi in ((0x2000, 0x2400), (0x2E00, 0x3100)):     # data of the loops: qwords 2000h, as in the simulation
    for x in range(lo, hi, 8): img[x:x + 8] = (0x2000).to_bytes(8, 'little')
open(os.path.join(OUT, 'bench.bin'), 'wb').write(img)
for g in range(8):
    with open(os.path.join(OUT, 'monitor_l%d.hex' % g), 'w') as f:
        for k in range(2048): f.write('%02X\n' % img[8 * k + g])
with open(os.path.join(OUT, 'bench.map'), 'w') as f:
    f.write('firmware 0000-%04X, pointer table %04X, free: %s\n' % (fw_end, ptab, ', '.join('%04X-%04X' % tuple(r) for r in regions)))
    for d, p in zip(recs, place): f.write('%04X %-34s sim %7.2f  shift %d copies %d fix %s\n' % (p, d['name'], d['sim'] / 100, d['shift'], d['nc'], d['fix']))
print('%d cases, firmware %d bytes, free after placement: %s' % (len(recs), fw_end, ', '.join('%04X-%04X' % tuple(r) for r in regions)))
