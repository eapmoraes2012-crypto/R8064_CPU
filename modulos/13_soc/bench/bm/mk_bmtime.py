#!/usr/bin/env python3
# mk_bmtime.py - builds bmtime.c: the module 12 Z80 reference model (via msx/sim/mk_core.py) timed with the SAME table the timing
# governor uses (gov_rom.mem), i.e. the original MSX machines the governed modes reproduce:
#   Z80  (MSX, 3.579545 MHz): T-states + 1 wait per M1 (2 for prefixed opcodes)
#   R800 (turbo R DRAM, 7.15909 MHz): table cycles (taken / alternative path) + 1 per 256-byte page crossed by the fetch or a 16-bit
#        data access + refresh (25 cycles every 210, inserted after the instruction, as timing_gov.v)
# Usage: python3 mk_bmtime.py <out dir>  -> <out>/bmtime (gcc -O2).   Run: bmtime <image.hex> -> clocks between OUT F0h / F1h in
# Z80 T-states and R800 cycles, plus the result bytes (port F2h), so the numbers can be compared with the RTL run in native mode.
import os, sys, subprocess
H = os.path.dirname(os.path.abspath(__file__)); M = os.path.join(H, '..', '..', '..')
OUT = os.path.abspath(sys.argv[1]); os.makedirs(OUT, exist_ok=True)
core = os.path.join(OUT, 'z80core.c')
subprocess.run([sys.executable, os.path.join(M, '13_soc', 'msx', 'sim', 'mk_core.py'), os.path.join(M, '12_z80', 'ref', 'z80ref.c'), core], check=True)
s = open(core).read()
for a, b in [("static u8 rd(u16 a){return mem[a];}", "static int xing; static u8 rd(u16 a){return mem[a];}"),
             ("static u16 rd16(u16 a){return rd(a)|rd(a+1)<<8;}", "static u16 rd16(u16 a){xing+=((a&255)==255);return rd(a)|rd(a+1)<<8;}"),
             ("static void w16(u16 a,u16 v){", "static void w16(u16 a,u16 v){xing+=((a&255)==255);"),
             ("static u16 fetch16(){u16 v=rd16(z.pc);", "static u16 fetch16(){u16 v=rd(z.pc)|rd(z.pc+1)<<8;")]:
    assert s.count(a) == 1, a; s = s.replace(a, b)
open(core, 'w').write(s)
gov = [int(l, 16) for l in open(os.path.join(M, '13_soc', 'sim', 'gov_rom.mem')) if l.strip()]
src = '#include "z80core.c"\nstatic const unsigned gov[2048] = {' + ','.join('0x%x' % v for v in gov) + '};\n' + r'''
static int t0 = -1, done; static u64 tz, tr, tz0, tr0, tz1, tr1; static u8 res[256]; static int nres;
static u8 io_in(u8 p){ return 0xFF; }
static void io_out(u8 p, u8 v){
    if (p == 0xF0) { tz0 = tz; tr0 = tr; } else if (p == 0xF1) { tz1 = tz; tr1 = tr; } else if (p == 0xF2) res[nres++] = v; else if (p == 0xF3) done = 1;
}
int main(int argc, char **argv){
    FILE *f = fopen(argv[1], "r"); unsigned v; int a = 0; while (a < 65536 && fscanf(f, "%x", &v) == 1) mem[a++] = v; fclose(f);
    for (int i = 0; i < 256; i++) { int p = i, n = 0; while (p) { n += p & 1; p >>= 1; } szp[i] = (i & 0xA8) | (i ? 0 : FZ) | (n & 1 ? 0 : FP); }
    memset(&z, 0, sizeof z); u64 n = 0; int rfc = 0;
    mem[0x10] = 1;                                   /* Z80 mode in the image: the model has no mode switch (same code path) */
    while (!done && n < 4000000000ULL) {
        u16 pc0 = z.pc; u8 b0 = mem[pc0]; int pg = 0; u8 op = b0;
        if (b0 == 0xDD || b0 == 0xFD) { u8 b1 = mem[(u16)(pc0 + 1)];
            if (b1 == 0xCB) { pg = b0 == 0xDD ? 5 : 6; op = mem[(u16)(pc0 + 3)]; } else { pg = b0 == 0xDD ? 3 : 4; op = b1; } }
        else if (b0 == 0xED) { pg = 2; op = mem[(u16)(pc0 + 1)]; } else if (b0 == 0xCB) { pg = 1; op = mem[(u16)(pc0 + 1)]; }
        unsigned w = gov[pg * 256 + op]; int zt = w & 63, za = (w >> 6) & 63, rt = (w >> 12) & 63, ra = (w >> 18) & 63, m1x2 = (w >> 24) & 1;
        xing = 0; u8 r0 = z.r; int t = step(); n++;
        int len = (pc0 <= z.pc && z.pc - pc0 <= 4) ? z.pc - pc0 : 0;   /* jumps: length unknown -> no fetch crossing counted */
        int alt = za && za != zt && t == za;
        tz += t + (m1x2 ? 2 : 1);
        int c = (alt ? ra : rt) + ((pc0 & 255) + len > 256) + xing;
        tr += c; rfc += c; if (rfc >= 210) { tr += 25; rfc = 25; }
        (void)r0;
    }
    printf("BMT z80_T=%llu r800_cyc=%llu instr=%llu end=%d res=", (unsigned long long)(tz1 - tz0), (unsigned long long)(tr1 - tr0), (unsigned long long)n, done);
    for (int i = 0; i < nres; i++) printf("%02x", res[i]);
    printf("\n"); return 0;
}
'''
open(os.path.join(OUT, 'bmtime.c'), 'w').write(src)
subprocess.run(['gcc', '-O2', '-w', '-o', os.path.join(OUT, 'bmtime'), os.path.join(OUT, 'bmtime.c')], cwd=OUT, check=True)
