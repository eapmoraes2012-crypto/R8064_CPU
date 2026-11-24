# check_audio2.py - compares the tb_audio2 dumps with aud_ref.py: ADPCM output and the OPL3 #2 bank-0 image for the
# YM2413 #1 registers (A) and, after the owner switch, the YM2413 #2 registers (B).
import sys
sys.path.insert(0, __import__('os').path.dirname(__file__))
from aud_ref import adpcm_play, opll_image
ok = True
mem = [((k * 37 + 11) & 0xFF) for k in range(64)] + [0xFF] * 64
got = [int(l) for l in open('aud2_adpcm.txt')]
exp, eos = adpcm_play(mem, 0, 7, 0x6000, 200, len(got) + 8)
best = None
for off in range(-4, 5):
    e = exp[max(0, -off):]; g = got[max(0, off):]; n = min(len(e), len(g)) - 4
    if n > 300 and all(e[i] == g[i] for i in range(n)): best = off; break
print('ADPCM: %d samples, %s' % (len(got), ('exact match at offset %d' % best) if best is not None else 'MISMATCH'))
if best is None:
    ok = False
    print(' got', got[:24]); print(' exp', exp[:24])
print('ADPCM signal range %d..%d, EOS at sample %s' % (min(got), max(got), eos))
img = {'A': {}, 'B': {}}; sh = {'S1': [0] * 64, 'S2': [0] * 64}
for l in open('aud2_opl.txt'):
    t, a, v = l.split(); a, v = int(a), int(v)
    if t in img: img[t][a] = v
    else: sh[t][a] = v
for tag, s in (('A', 'S1'), ('B', 'S2')):
    e = opll_image(sh[s]); bad = [(r, img[tag].get(r), v) for r, v in sorted(e.items()) if img[tag].get(r) != v]
    print('OPL3 bank 0 image %s: %d registers, %d differences' % (tag, len(e), len(bad)))
    for r, g, v in bad[:10]: print('  reg %02X got %s expected %02X' % (r, g, v))
    if bad: ok = False
print('RESULT:', 'PHASE 2 MODELS OK' if ok else 'PHASE 2 MODELS ERROR')
