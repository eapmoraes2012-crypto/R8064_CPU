# gen_meas.py - measures the clocks of every R8064 instruction (ref/expected_cycles.csv) on the SoC RTL, native mode, code and data in the caches.
# Each case is a loop: register init + N copies of the instruction + JP back. clocks/instruction = (T_loop - T_loop_without_the_instruction) / N.
# Usage: python3 gen_meas.py <repo root> <work dir> <out.json> [<repo root 2> <out2.json>]   (several roots = before/after)
import sys, os, csv, json, subprocess, re, itertools
from concurrent.futures import ThreadPoolExecutor
HERE = os.path.dirname(os.path.abspath(__file__))
ASMDIR = os.path.join(HERE, '..', '..', 'msx', 'asm')
sys.path.insert(0, ASMDIR)
from isacore import COMPILED, C_KW, C_IND, C_R8, C_XH, C_SS, C_QQ, C_XY, C_RR, C_INDRR, C_U4, C_CC, C_IMM, C_MEM, C_REL, C_IDX8, C_IDXQ, C_BIT, C_ST, C_RST, C_VAL, KWNUM
from asmref import Asm

ROOT = os.path.abspath(sys.argv[1]); W = os.path.abspath(sys.argv[2]); os.makedirs(W, exist_ok=True)
NAME = {v: k for k, v in KWNUM.items()}
RRN = {0: 'BC', 2: 'DE', 3: 'IY', 4: 'HL', 5: 'IX', 7: 'AX'}
R8N = 'B C D E H L ? A'.split()

def pick(mask, pref):
    for c in pref:
        if mask >> c & 1: return c
    return None

# ---------------------------------------------------------------- cases
# case = dict(key, id, name, src (body line, '$' allowed), n (copies), init (extra lines), sub (lines after the loop), derive)
SKIP = {}
cases = []
rows = list(csv.reader(open(os.path.join(ROOT, 'ref', 'expected_cycles.csv'), encoding='utf-8-sig'), delimiter=';'))
hdr, rows = rows[0], rows[1:]
for r in rows:
    i = int(r[0]); cls = r[19]
    if 'FPU' in cls or 40 <= i <= 66: SKIP[i] = 'FPU: not in the cartridge build (R8064_NOFPU)'
    elif i in (175, 176, 177, 178, 179, 180, 182, 183): SKIP[i] = 'system/privileged: changes mode, CRs or resets (not measured in a loop)'
    elif i == 192: SKIP[i] = 'LDCTX loads the whole register context (not measured in a loop)'
    elif i in (155, 159): SKIP[i] = 'removed from the core'
JUMPLEN = {137: 7, 138: 6, 141: 11, 142: 10, 118: 6, 121: 10}

def ext_case(i, cc=None):
    if i == 26: return 'MLTUW HL,BC'
    if i == 27: return 'MLTUW HL,SP'
    fs = [f for f in COMPILED if f.id == i]
    if not fs: return None
    # prefer the explicit form without implicit operands
    fs.sort(key=lambda f: (any(p[0] == C_KW for p in f.pats), len(f.pats)))
    f = fs[0]
    ops = []; first_rr = True
    for k, (c, a) in enumerate(f.pats, 1):
        if c == C_KW: ops.append(NAME[a])
        elif c == C_RR:
            code = pick(a, [4, 7, 2, 0] if first_rr else [0, 2, 7, 4]); first_rr = False; ops.append(RRN[code])
        elif c == C_INDRR: ops.append('(%s)' % RRN[pick(a, [2, 0, 4, 7])])
        elif c == C_U4: ops.append('(DE)')
        elif c == C_R8: ops.append(R8N[pick(a, [1, 0, 2, 3, 7])])
        elif c == C_CC: ops.append(cc)
        elif c == C_IMM: ops.append(('$+%d' % JUMPLEN[i]) if i in JUMPLEN else {1: '5', 2: '1234h', 4: '12345678h', 8: '1122334455667788h'}[a])
        elif c == C_REL: ops.append('$+%d' % f.len)
        elif c == C_MEM: ops.append('(2000h)')
        elif c == C_IDXQ: ops.append('(QIX+8)')
        elif c == C_BIT: ops.append('3' if a > 31 or i not in (181, 292) else '0')
        elif c == C_VAL: ops.append(str(a))
        else: return None
    return '%s %s' % (f.mn, ','.join(ops))

for r in rows:
    i = int(r[0]); name = r[1]
    if i in SKIP: continue
    if i <= 210 or i >= 291:
        has_cc = any(p[0] == C_CC for f in COMPILED if f.id == i for p in f.pats)
        variants = [('Z', ' (taken)'), ('NZ', ' (not taken)')] if has_cc else [(None, '')]
        for cc, suf in variants:
            src = ext_case(i, cc)
            if src is None: SKIP[i] = 'no operand form'; continue
            c = dict(key='%d%s' % (i, '_' + cc if cc else ''), id=i, name=name + suf, src=src, n=16, init=[], sub=[])
            if i in (135, 136, 139, 140, 116, 117, 119, 120):   # jump/call through a register: 1 copy, register = address after it
                reg = re.search(r'\((\w+)\)', src).group(1)
                c.update(n=1, init=['ldq %s,after' % reg], src=src + '\nafter:')
            if i in (122, 123, 124, 125):         # returns: CALL + RET pairs, minus the call alone
                call = 'CALLL' if i in (122, 124) else 'CALLQ'
                ret = src
                c.update(src='%s sub' % call, sub=['sub: ' + ret] + (['        %s' % ('RETL' if call == 'CALLL' else 'RETQ')] if cc == 'NZ' else []),
                         derive=('minus', ['%s_alone' % call] + ([{'CALLL': '124', 'CALLQ': '125'}[call]] if cc == 'NZ' else [])))
            cases.append(c)
    else:
        hx = r[2].replace('nl nh', '00 20').split()
        src = 'db ' + ','.join('0%sh' % b for b in hx)
        c = dict(key=str(i), id=i, name=name, src=src, n=16, init=[], sub=[])
        if i in (216, 224, 232, 240, 248, 256, 264, 272):     # RETN/RETI: pair with the Z80 CALL
            c.update(src='call sub', sub=['sub: ' + src], derive=('minus', ['CALL_alone']))
        if i in (283, 284, 285, 286, 287, 288, 289, 290):     # block repeats: 16 elements
            c.update(n=16, init=['ld bc,1000h' if i in (285, 286, 289, 290) else 'ld bc,16', 'ld a,0FFh'], src=src, per='element')
            c['n_copies'] = 1
        if i in (276, 280): c['init'] = ['ld a,0FFh']
        cases.append(c)
# helper cases (for the derived returns) and Z80 main page sample
cases += [dict(key='CALLL_alone', id=None, name='CALLL nnnn (no return)', src='CALLL $+6', n=16, init=[], sub=[], helper=1),
          dict(key='CALLQ_alone', id=None, name='CALLQ nnnnnnnn (no return)', src='CALLQ $+10', n=16, init=[], sub=[], helper=1),
          dict(key='CALL_alone', id=None, name='CALL nn (no return)', src='CALL $+3', n=16, init=[], sub=[], helper=1)]
Z80 = [('NOP', 'nop'), ('LD A,B', 'ld a,b'), ('LD A,n', 'ld a,5'), ('LD BC,nn', 'ld bc,2000h'), ('ADD A,B', 'add a,b'), ('INC B', 'inc b'), ('ADD HL,BC', 'add hl,bc'),
       ('INC BC', 'inc bc'), ('LD A,(HL)', 'ld a,(hl)'), ('LD (HL),A', 'ld (hl),a'), ('LD A,(nn)', 'ld a,(2000h)'), ('LD HL,(nn)', 'ld hl,(2000h)'),
       ('LD A,(IX+d)', 'ld a,(ix+5)'), ('LD (IX+d),A', 'ld (ix+5),a'), ('PUSH BC', 'push bc'), ('POP DE', 'pop de'), ('EX DE,HL', 'ex de,hl'), ('EXX', 'exx'),
       ('EX (SP),HL', 'ex (sp),hl'), ('RLCA', 'rlca'), ('BIT 3,A', 'bit 3,a'), ('SET 3,(HL)', 'set 3,(hl)'), ('JR e (taken)', 'jr $+2'),
       ('JR NZ,e (not taken)', 'jr nz,$+2'), ('JR Z,e (taken)', 'jr z,$+2'), ('JP nn', 'jp $+3'), ('DJNZ e (taken)', 'djnz $+2'),
       ('CALL nn + RET (pair)', 'call sub'), ('RET', 'call sub')]
for nm, s in Z80:
    c = dict(key='z80_' + nm, id=None, name=nm, src=s, n=16, init=[], sub=['sub: ret'] if 'call' in s else [], z80=1)
    if nm == 'RET': c['derive'] = ('minus', ['CALL_alone'])
    cases.append(c)

# ---------------------------------------------------------------- programs
PRE = '''        org 0
        ldw ax,0A5h
        out (3Dh),a
        ldw ax,1
        out (3Eh),a
        ds 16
loop:   ld sp,3000h
        ldq bc,2000h
        ldq de,2010h
        ldq hl,2020h
        ldq ix,2030h
        ldq iy,2040h
        ldq ax,2050h
        xor a
'''
POST = '''        jp loop
'''
DATA = '''        org 2000h
        rept_data
'''
def program(c, empty):
    L = [PRE] + ['        ' + x for x in c['init']]
    ncop = c.get('n_copies', c['n'])
    for _ in range(ncop):
        for ln in c['src'].split('\n'):
            if ln.endswith(':'): L.append(ln)
            elif not empty: L.append('        ' + ln)
    L.append(POST)
    L += [('        ' + x) if not x.startswith('sub:') else x for x in c['sub']]
    L.append('        org 2000h')
    L += ['        dq 2000h'] * 1024
    return '\n'.join(L) + '\n'
def build(c, empty, tag):
    d = os.path.join(W, 'img'); os.makedirs(d, exist_ok=True)
    nm = re.sub(r'[^A-Za-z0-9_]', '_', c['key']) + ('_E' if empty else '')
    p = os.path.join(d, nm + '.asm'); open(p, 'w').write(program(c, empty))
    a = Asm(p); out = a.run()
    if a.errors: raise SystemExit('asm error %s: %s' % (c['key'], a.errors[:3]))
    open(os.path.join(d, nm + '.hex'), 'w').write('\n'.join('%02x' % b for b in out) + '\n')
    loop = a.sym['LOOP'][0]
    return os.path.join(d, nm + '.hex'), loop

def compile_tb(root, tag):
    sim = os.path.join(root, 'modulos', '13_soc', 'sim')
    R = '../../10_mode_gov/rtl'; C = '../../09_core_min/rtl'; S = '../rtl'
    core = [f'{R}/r8064_cpu_gov.v', f'{R}/r8064_msx_sys.v', f'{R}/r8064_fifo_if.v', f'{R}/r8064_mode.v', f'{R}/timing_gov.v', f'{R}/mem_class.v', '../../10_msx_mem/rtl/msx_mem.v',
            f'{C}/r8064_core_min.v', f'{C}/r8064_decode.v', f'{C}/r8064_decode_rom.v', f'{C}/regfile64.v', f'{C}/regmap_b.v', f'{C}/regmerge.v', f'{C}/alu_prep.v', f'{C}/alu_core_s.v',
            '../../03_muldiv/rtl/mul_unit.v', '../../03_muldiv/rtl/div_unit.v', '../../08_fpu/rtl/fpu_unit.v', '../../08_fpu/rtl/fpu_seq.v']
    soc = [f'{S}/r8064_soc.v', f'{S}/r8064_memsys.v', f'{S}/mem_arb5.v', f'{S}/r8064_dma.v', f'{S}/r8064_xbuf.v', f'{S}/cache_dm.v', f'{S}/mmu.v', f'{S}/sdram_ctrl.v', 'sdram_model.v'] + core
    import shutil
    if not os.path.samefile(os.path.join(HERE, '..'), sim): shutil.copy(os.path.join(HERE, '..', 'tb_meas.v'), os.path.join(sim, 'tb_meas.v'))
    vvp = os.path.join(W, 'meas_%s.vvp' % tag)
    defs = os.environ.get('MEAS_DEFS', '').split()   # REV52: e.g. MEAS_DEFS='-DMEAS_CPT=12 -DMEAS_REF=300' (board bench clock)
    r = subprocess.run(['iverilog', '-g2012'] + defs + ['-o', vvp, 'tb_meas.v'] + soc, cwd=sim, capture_output=True, text=True)
    if r.returncode: raise SystemExit(r.stdout + r.stderr)
    return sim, vvp

def run(sim, vvp, hexf, loop):
    r = subprocess.run(['vvp', '-n', vvp, '+img=' + hexf, '+loop=%x' % loop], cwd=sim, capture_output=True, text=True, timeout=600)
    m = re.search(r'TITER (\S+) native=(\d)(?: wait=(\S+) dwait=(\S+))?', r.stdout)
    if not m or m.group(1) == 'NA' or m.group(2) != '1': return None
    return (float(m.group(1)), float(m.group(3) or 0), float(m.group(4) or 0))   # total, wait (fetch + data), data wait

if __name__ == '__main__':
    targets = [(sys.argv[1], sys.argv[3])] + ([(sys.argv[4], sys.argv[5])] if len(sys.argv) > 5 else [])
    imgs = {}
    for c in cases:
        imgs[(c['key'], 0)] = build(c, False, ''); imgs[(c['key'], 1)] = build(c, True, '')
    for root, outj in targets:
        sim, vvp = compile_tb(os.path.abspath(root), os.path.basename(outj))
        jobs = {}
        with ThreadPoolExecutor(max_workers=2) as ex:
            empties = {}
            for c in cases:
                ek = tuple(c['init']) + tuple(c['sub'])   # empty loop with the same init (and sub, which does not run)
                if ek not in empties: empties[ek] = ex.submit(run, sim, vvp, *imgs[(c['key'], 1)])
                jobs[c['key']] = (ex.submit(run, sim, vvp, *imgs[(c['key'], 0)]), empties[ek])
            res = {}
            for c in cases:
                t, e = jobs[c['key']][0].result(), jobs[c['key']][1].result()
                res[c['key']] = None if t is None or e is None else tuple((a - b) / c['n'] for a, b in zip(t, e))
        # derived values (returns = pair - call)
        out = {}; byk = {c['key']: c for c in cases}
        def val(k, j):
            v = res.get(k); c = byk[k]
            if v is None: return None
            v = v[j]
            if c.get('derive'):
                for k2 in c['derive'][1]:
                    w = val(k2, j)
                    if w is None: return None
                    v -= w
            return v
        for c in cases:
            v = val(c['key'], 0); wt = val(c['key'], 1); wd = val(c['key'], 2)
            out[c['key']] = dict(id=c['id'], name=c['name'], src=c['src'].replace('\n', ' ; '), n=c['n'], clocks=v, wait=wt, dwait=wd,
                                 fwait=None if wt is None else wt - wd, exec=None if v is None else v - wt,
                                 pair=res[c['key']][0] if c.get('derive') and res[c['key']] else None, z80=c.get('z80', 0), helper=c.get('helper', 0), per=c.get('per', 'instruction'))
        json.dump(dict(cases=out, skip=SKIP), open(outj, 'w'), indent=1)
        print('done', root, sum(1 for v in out.values() if v['clocks'] is not None), 'measured of', len(out))
