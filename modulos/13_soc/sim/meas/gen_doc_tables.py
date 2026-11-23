#!/usr/bin/env python3
# gen_doc_tables.py - generates the instruction appendices of the datasheet from the sources of truth:
#   Appendix C (complete instruction list): modulos/13_soc/msx/asm/r8isa.py (the instruction set used by the assembler and checked
#              against the decode ROMs of the RTL and against sjasmplus), with encoding, length and the instruction id;
#   Appendix D (measured timing): modulos/13_soc/bench/ref_rev48.json (gen_meas.py, REV48 RTL, native mode, in cache), confirmed on
#              the Tang Nano 20K by the timing bench (docs/timings/bench_tang20k_REV48_2026-11-20.txt);
#   class summary for chapter 6.
# The tables are written between the markers <!-- BEGIN name --> / <!-- END name --> of docs/R8064_Datasheet_Appendix_C.md,
# docs/R8064_Datasheet_Appendix_D.md and (class summary) docs/R8064_Datasheet.md.
# Usage: python3 gen_doc_tables.py [<datasheet.md>]
import os, sys, re, json, csv, collections
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'modulos', '13_soc', 'msx', 'asm'))
import r8isa as R
DS = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'docs', 'R8064_Datasheet.md')
ref = json.load(open(os.path.join(ROOT, 'modulos', '13_soc', 'bench', 'ref_rev48.json')))
cases, skip = ref['cases'], ref['skip']
rows = list(csv.reader(open(os.path.join(ROOT, 'ref', 'expected_cycles.csv'), encoding='utf-8-sig'), delimiter=';'))[1:]
cls = {int(r[0]): r[19].replace('Z80 em modo R8064', 'Z80 ED instruction in native mode') for r in rows}
HW = open(os.path.join(ROOT, 'docs', 'timings', 'bench_tang20k_REV48_2026-11-20.txt')).read()
hw_ok = {l[:33].strip() for l in HW.splitlines() if l.rstrip().endswith(' OK')}
NO_CART = {13, 17, 24, 30}                      # MLTSQ MLTUQ DIVSQ DIVUQ (R8064_NO_MD64)

OPN = {'r': 'r', 'r-hl': 'r', 'xh': 'p', 'ss': 'ss', 'qq': 'qq', 'xy': 'xy', 'rr': 'rr', '(rr)': '(rr)', 'cc': 'cc', 'jcc': 'cc',
       'n': 'n', 'nn': 'nn', 'n32': 'nnnn', 'n64': 'nnnnnnnn', 'e': 'e', 'ee': 'ee', '(n)': '(n)', '(nn)': '(nn)', '(a64)': '(nnnnnnnn)',
       '(xy+d)': '(xy+d)', '(qxy+dd)': '(Qxy+dd)', 'b3': 'b', 'b4': 'b', 'b5': 'b', 'k5': 'k', 'st': 'STn', 'rst': 'p', 'u4': 'uu'}
def opstr(o):
    if o.startswith('='): return o[1:]
    return OPN.get(o, o)
def enc(t):
    out, nb = [], 0
    for it in t:
        if it == 'E': out.append('ED'); nb += 1
        elif re.fullmatch(r'P[12]', it): out.append('DD/FD'); nb += 1
        elif re.fullmatch(r'I[12]:\d', it):
            n = int(it[-1]); out.append({1: 'n', 2: 'nn', 4: 'nnnn', 8: 'n×8'}[n]); nb += n
        elif re.fullmatch(r'R[12]:\d', it):
            n = int(it[-1]); out.append({1: 'e', 2: 'ee'}[n]); nb += n
        elif re.fullmatch(r'D[12]:\d', it):
            n = int(it[-1]); out.append({1: 'd', 2: 'dd'}[n]); nb += n
        elif re.fullmatch(r'[0-9A-F]{2}', it): out.append(it); nb += 1
        else:
            m = re.fullmatch(r'([0-9A-F]{2})(\|.*)', it); assert m, it
            fl = m.group(2).replace('|', '+').replace('1<<3', 'a·8').replace('2<<3', 'b·8').replace('1<<4', 'a·16').replace('2<<4', 'b·16')
            fl = re.sub(r'\+1\b', '+a', fl); fl = re.sub(r'\+2\b', '+b', fl); fl = re.sub(r'\+3\b', '+c', fl)
            out.append(m.group(1) + fl); nb += 1
    return ' '.join(out), nb

def bname(v):                                   # the name as the bench firmware prints it (gen_bench.py)
    n = v['name'].replace('\u2019', "'")
    if v.get('pair') is not None: n += ' +CALL'
    if v.get('per') == 'element': n += ' /elem'
    return n.encode('ascii', 'replace').decode()[:31].strip()
def f2(x): return '%.2f' % x if x is not None else '–'
def clocks_for_id(i):
    vs = [v for k, v in cases.items() if v['id'] == i and not v.get('z80') and not v.get('helper') and v['clocks'] is not None]
    if not vs: return '–'
    if len(vs) == 1: return f2(vs[0]['clocks'])
    parts = []
    for v in vs:
        tag = 'taken' if '(taken)' in v['name'] else 'not taken' if '(not taken)' in v['name'] else ''
        parts.append(f2(v['clocks']) + (' ' + tag if tag else ''))
    return ' / '.join(parts)

# ---------------- Appendix C
ext, base = [], []
for m, ops, t, a in R.FORMS:
    e, nb = enc(t)
    syn = m + (' ' + ', '.join(opstr(o) for o in ops) if ops else '')
    (ext if 'id' in a else base).append((m, syn, e, nb, a.get('id')))
C = ['Generated from `modulos/13_soc/msx/asm/r8isa.py` by `modulos/13_soc/sim/meas/gen_doc_tables.py`: %d mnemonics, %d operand forms '
     '(%d Z80/R800 base forms and %d R8064 extension forms). This is the set accepted by the R8064AS assembler; the extension forms are '
     'checked against the decode ROMs of the RTL (`verify_rom.py`) and the base set against sjasmplus (`verify_z80.py`).'
     % (len({f[0] for f in R.FORMS}), len(R.FORMS), len(base), len(ext)), '',
     'Operand codes in the encoding: **a** = code of the 1st operand, **b** = of the 2nd, **c** = of the 3rd (`a·8` = shifted 3 bits). '
     'Register codes: r = B 0, C 1, D 2, E 3, H 4, L 5, A 7; ss = BC 0, DE 1, HL 2, SP 3; qq = BC, DE, HL, AF; rr (R8064) = BC 0, DE 2, '
     'IY 3, HL 4, IX 5, AX 7 (and N0–N7, BC\', DE\', HL\', AX\' through the bank prefixes, section 4.2); p = IXH/IXL/IYH/IYL; '
     'xy = IX (DD) or IY (FD); cc = NZ 0, Z 1, NC 2, C 3, PO 4, PE 5, P 6, M 7; uu = BC, DE, HL, AX (0–3). '
     '`n×8` = 8-byte immediate or address, little-endian. Bytes = length without a bank prefix (ED 0B/0D/0E adds 2).', '',
     '**Native clocks** = measured clocks per instruction in native mode with code and data in the caches (REV48, Appendix D); '
     'a value marked † was measured in simulation only (not in the cartridge build). "–" = not measured (system, FPU and removed '
     'instructions; see Appendix D).', '',
     '### C.1 R8064 extensions', '', '| Mnemonic | Syntax | Encoding (hex) | Bytes | id | Native clocks |', '| --- | --- | --- | --- | --- | --- |']
for m, syn, e, nb, i in sorted(ext, key=lambda x: (x[0], x[4] or 0, x[1])):
    ck = clocks_for_id(i)
    if i in NO_CART and ck != '–': ck += ' †'
    C.append('| %s | `%s` | %s | %d | %d | %s |' % (m, syn, e, nb, i, ck))
C += ['', '### C.2 Z80 and R800 base set', '',
      'Same encodings as the Z80 (including the undocumented instructions) and the R800 multiplications. In the Z80/R800 modes their time '
      'is set by the timing governor (chapter 6); measured native-mode examples are in D.2.', '',
      '| Mnemonic | Syntax | Encoding (hex) | Bytes |', '| --- | --- | --- | --- |']
for m, syn, e, nb, i in sorted(base, key=lambda x: (x[0], x[1])):
    C.append('| %s | `%s` | %s | %d |' % (m, syn, e, nb))

# ---------------- Appendix D
D = ['Generated from `modulos/13_soc/bench/ref_rev48.json` (simulation of the REV48 RTL by `sim/meas/gen_meas.py`) by '
     '`sim/meas/gen_doc_tables.py`. Native mode, MMU off, code and data in the caches; each value is the average over 16 copies of the '
     'instruction in a loop, minus the same loop without it. Total = execution + wait. **Wait** = clocks in which the core stands still '
     'waiting for memory: *fetch* (the decoder lacks instruction bytes) or *data* (a load/store waits for the cache). '
     'Column **Board**: ✓ = the same value was measured on the Tang Nano 20K by the timing bench (256 of 256 cases, 2026-11-20). '
     'ns at 57.375 MHz (board crystal; × 1.0018 for 57.2727 MHz).', '',
     '### D.1 R8064 instructions', '', '| id | Instruction | Total | Execution | Fetch wait | Data wait | ns | Class | Board | Note |',
     '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |']
seen_ids = set()
for k, v in cases.items():
    if v.get('z80') or v.get('helper'): continue
    i = v['id']; seen_ids.add(i)
    nm = v['name'] + (' +CALL' if v.get('pair') is not None else '') + (' /elem' if v.get('per') == 'element' else '')
    note = []
    if v.get('pair') is not None: note.append('return alone (CALL+RET pair minus CALL)')
    if v.get('per') == 'element': note.append('per element (16 elements)')
    if i in NO_CART: note.append('not in the cartridge build (R8064_NO_MD64)')
    hw = '✓' if bname(v) in hw_ok else ('n/a' if i in NO_CART else '')
    tot = v['clocks']
    D.append('| %d | %s | %s | %s | %s | %s | %.0f | %s | %s | %s |' % (i, v['name'], f2(tot), f2(v['exec']), f2(v['fwait']), f2(v['dwait']),
             tot * 1000 / 57.375, cls.get(i, ''), hw, '; '.join(note)))
D += ['', '### D.2 Z80 base instructions in native mode (examples)', '',
      '| Instruction | Total | Execution | Fetch wait | Data wait | ns | Board | Note |', '| --- | --- | --- | --- | --- | --- | --- | --- |']
for k, v in cases.items():
    if not (v.get('z80') or v.get('helper')): continue
    note = 'return alone (CALL+RET pair minus CALL)' if v.get('pair') is not None else ('call without return (helper)' if v.get('helper') else '')
    hw = '✓' if bname(v) in hw_ok else ''
    D.append('| %s | %s | %s | %s | %s | %.0f | %s | %s |' % (v['name'], f2(v['clocks']), f2(v['exec']), f2(v['fwait']), f2(v['dwait']),
             v['clocks'] * 1000 / 57.375, hw, note))
D += ['', '### D.3 Not measured', '', '| ids | Reason |', '| --- | --- |']
byr = collections.defaultdict(list)
for i, r in skip.items(): byr[r].append(int(i))
def rng(l):
    l = sorted(l); out = []; s = p = l[0]
    for x in l[1:] + [None]:
        if x is not None and x == p + 1: p = x; continue
        out.append('%d' % s if s == p else '%d–%d' % (s, p))
        if x is not None: s = p = x
    return ', '.join(out)
for r, l in byr.items(): D.append('| %s | %s |' % (rng(l), r.replace('no operand form', 'no separate operand form (encoded by another id)')))

# ---------------- class summary (chapter 6)
S = ['| Class | Cases | Total (avg) | Execution (avg) | Wait (avg) | Fastest | Slowest |', '| --- | --- | --- | --- | --- | --- | --- |']
g = collections.defaultdict(list)
for v in cases.values():
    if v.get('z80') or v.get('helper') or v['clocks'] is None or v['id'] in NO_CART: continue
    g[cls.get(v['id'], '?')].append(v)
for c in sorted(g, key=lambda c: sum(v['clocks'] for v in g[c]) / len(g[c])):
    l = g[c]; a = lambda f: sum(f(v) for v in l) / len(l)
    S.append('| %s | %d | %.2f | %.2f | %.2f | %.2f | %.2f |' % (c, len(l), a(lambda v: v['clocks']), a(lambda v: v['exec']), a(lambda v: v['wait']),
             min(v['clocks'] for v in l), max(v['clocks'] for v in l)))

DOCS = os.path.dirname(DS)
for fn, name, block in (('R8064_Datasheet_Appendix_C.md', 'APPENDIX_C', C), ('R8064_Datasheet_Appendix_D.md', 'APPENDIX_D', D),
                        (os.path.basename(DS), 'TIMING_SUMMARY', S)):
    f = os.path.join(DOCS, fn); txt = open(f, encoding='utf-8').read()
    b, e = '<!-- BEGIN %s -->' % name, '<!-- END %s -->' % name
    if name == 'TIMING_SUMMARY' and b not in txt: continue   # datasheet edition 1.0: the class summary moves to the timing edition
    assert b in txt and e in txt, (fn, name)
    txt = txt[:txt.index(b) + len(b)] + '\n' + '\n'.join(block) + '\n' + txt[txt.index(e):]
    open(f, 'w', encoding='utf-8').write(txt)
print('C: %d ext + %d base forms; D: %d rows; summary %d classes' % (len(ext), len(base), len(D), len(S) - 2))
