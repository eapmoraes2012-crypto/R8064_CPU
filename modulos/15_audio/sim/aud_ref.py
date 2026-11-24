# aud_ref.py - reference models for the audio tests: YM2413 -> OPL3 translation (same rules as aud_fm2.v) and the Y8950 ADPCM
# playback (same arithmetic as aud_y8950.v, which follows openMSX Y8950Adpcm).
PROM = [0x0000000000000000, 0x61611e17f07f0017, 0x1341160efdf42323, 0x03019a04f3f313f3, 0x11610e07fa647017, 0x22211e06f0760028,
        0x21221605f0710018, 0x21611d0782801717, 0x23212d1690900007, 0x21211b0664651017, 0x21210b1a85a07007, 0x23018310ffb410f4,
        0x97c12007fff42222, 0x61000c05c2f64044, 0x0101560394c20312, 0x21018903f1e4f023, 0x07211400eef8fff8, 0x01310000f8f7f8f7,
        0x25110000f8faf855]
OPOFF = [0, 1, 2, 8, 9, 10, 16, 17, 18]

def opll_items(sh, c):
    r0e = sh[0x0E]; rm = (r0e >> 5) & 1 and c >= 6
    r1, r2, r3 = sh[0x10 + c], sh[0x20 + c], sh[0x30 + c]
    pn = (10 + c) if rm else (r3 >> 4)
    P = [sh[i] for i in range(8)] if pn == 0 else [(PROM[pn] >> (56 - 8 * i)) & 0xFF for i in range(8)]
    vol_c = (r3 & 15) if not rm else [sh[0x36], sh[0x37], sh[0x38]][c - 6] & 15
    tl_m = ([0, sh[0x37] >> 4, sh[0x38] >> 4][c - 6] << 2) if (rm and c != 6) else (P[2] & 0x3F)
    key_mel = (r2 >> 4) & 1 and not rm
    if rm:
        key_m = [(r0e >> 4) & 1, r0e & 1, (r0e >> 2) & 1][c - 6]; key_c = [(r0e >> 4) & 1, (r0e >> 3) & 1, (r0e >> 1) & 1][c - 6]
    else:
        key_m = key_c = key_mel
    sus_c = (r2 >> 5) & 1; sus_m = sus_c and rm and c != 6
    rr_m = (P[6] & 15) if key_m else (5 if sus_m else ((P[6] & 15) if (P[0] >> 5) & 1 else 7))
    rr_c = (P[7] & 15) if key_c else (5 if sus_c else ((P[7] & 15) if (P[1] >> 5) & 1 else 7))
    om, oc = OPOFF[c], OPOFF[c] + 3
    f9 = ((r2 & 1) << 8) | r1
    return [(0x20 + om, P[0]), (0x20 + oc, P[1]), (0x40 + om, (P[2] & 0xC0) | tl_m), (0x40 + oc, (P[3] & 0xC0) | (vol_c << 2)),
            (0x60 + om, P[4]), (0x60 + oc, P[5]), (0x80 + om, (P[6] & 0xF0) | rr_m), (0x80 + oc, (P[7] & 0xF0) | rr_c),
            (0xE0 + om, (P[3] >> 3) & 1), (0xE0 + oc, (P[3] >> 4) & 1), (0xC0 + c, 0xC0 | ((P[3] & 7) << 1)),
            (0xA0 + c, (f9 << 1) & 0xFF), (0xB0 + c, (int(key_mel) << 5) | (((r2 >> 1) & 7) << 2) | (f9 >> 7))]

def opll_image(sh):
    img = {0xBD: 0xC0 | (sh[0x0E] & 0x3F)}
    for c in range(9):
        for r, v in opll_items(sh, c): img[r] = v
    return img

F2 = [57, 57, 57, 57, 77, 102, 128, 153]
def tdiv(v, sh): return -((-v) >> sh) if v < 0 else v >> sh
def adpcm_play(mem, sa_reg, sp_reg, delta, vol, nsamp, repeat=False):
    sa, sp = sa_reg << 3, (sp_reg << 3) | 7
    ptr, nstep, aout, diff, lp, ln, adata = sa, (0x10000 - delta), 0, 127, 0, 0, 0
    playing, out, res, eos_at = True, 0, [], None
    for n in range(nsamp):
        if playing:
            s = (nstep & 0xFFFF) + delta
            if s < 0x10000: nstep = s
            else:
                nstep = s & 0xFFFF
                if not (ptr & 1): adata = mem[(ptr >> 1) & 0x3FFFF]; nib = adata >> 4
                else: nib = adata & 15
                f1 = (2 * (nib & 7) + 1) * (-1 if nib & 8 else 1)
                onew = max(-32768, min(32767, aout + tdiv(diff * f1, 3)))
                d2 = (diff * F2[nib & 7]) >> 6; diff = max(127, min(24576, d2))
                lv = tdiv(aout + onew, 1); aout = onew; lp, ln = ln, lv
                if ptr + 1 > sp:
                    if eos_at is None: eos_at = n
                    if repeat: ptr, nstep, aout, diff, lp, ln = sa, (0x10000 - delta), 0, 127, 0, 0
                    else: playing = False; ptr += 1
                else: ptr += 1
            out = ((lp * vol + (ln - lp) * ((vol * (nstep & 0xFFFF)) >> 16)) >> 8) if playing else 0
        else: out = 0
        res.append(out)
    return res, eos_at
