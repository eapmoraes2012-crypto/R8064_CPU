#!/usr/bin/env python3
# mkdhry.py - makes the bare-metal Dhrystone 2.1 sources (dhry_p.h, dhry_1p.c, dhry_2p.c) from the original dhry.h/dhry_1.c/dhry_2.c:
# no OS: printf/scanf removed, timing by bm_start/bm_stop (I/O markers), the final values sent as result bytes instead of printed.
# The benchmark code itself (main loop, Proc_*, Func_*) is not changed.
import re, os
H = os.path.dirname(os.path.abspath(__file__))
h = open(os.path.join(H, 'dhry.h')).read()
h = h.replace('#include <stdio.h>', '#include "bm_rt.h"\n#define printf(...)\n#define scanf(...)\n#define malloc bm_alloc')
pass
open(os.path.join(H, 'dhry_p.h'), 'w').write(h)
def ansi(src):
    # K&R function definitions -> ANSI (SDCC does not accept parameter declarations after the header); Proc_* return void
    L = src.split('\n'); out = []; i = 0
    while i < len(L):
        m = re.match(r'^(\w+\s+)?((?:Proc|Func)_\d)\s*\(([^)]*)\)(.*)$', L[i])
        if not m: out.append(L[i]); i += 1; continue
        name = m.group(2); ret = m.group(1) or ('void ' if name.startswith('Proc') else '')
        params = [p.strip() for p in m.group(3).split(',') if p.strip()]; rest = m.group(4)
        j = i + 1; keep = []; decl = {}
        while not L[j].startswith('{'):
            t = re.sub(r'/\*.*?\*/', '', L[j]).strip()
            if t.endswith(';'):
                t = t[:-1].replace('REG ', '').strip()
                mm = re.match(r'^(\w+)\s+(.*)$', t); ty = mm.group(1)
                for v in mm.group(2).split(','):
                    v = v.strip(); nm = v.lstrip('*'); decl[nm] = '%s %s' % (ty, v)
            else: keep.append(L[j])
            j += 1
        hdr = '%s%s (%s)%s' % (ret, name, ', '.join(decl[p] for p in params) if params else 'void', rest)
        out += [hdr] + keep; i = j
    return '\n'.join(out)
PROTO = '''
void Proc_1 (Rec_Pointer); void Proc_2 (One_Fifty *); void Proc_3 (Rec_Pointer *); void Proc_4 (void); void Proc_5 (void);
void Proc_6 (Enumeration, Enumeration *); void Proc_7 (One_Fifty, One_Fifty, One_Fifty *); void Proc_8 (Arr_1_Dim, Arr_2_Dim, int, int);
Enumeration Func_1 (Capital_Letter, Capital_Letter); Boolean Func_2 (Str_30, Str_30); Boolean Func_3 (Enumeration);
'''
d1 = open(os.path.join(H, 'dhry_1.c')).read().replace('#include "dhry.h"', '#include "dhry_p.h"')
d1 = d1.replace('  Begin_Time = time ( (long *) 0);', '  bm_start(); Begin_Time = 0;')
d1 = d1.replace('  End_Time = time ( (long *) 0);', '  bm_stop(); End_Time = 1;')
i = d1.index('  printf ("Execution ends\\n");'); j = d1.index('Proc_1 (Ptr_Val_Par)')
k = d1.rindex('}', i, j)
rep = '''  /* results (expected: 5 1 'A' 'B' 7 runs+10 17 18 5 13 7 1 0 0) */
  bm_out16(Int_Glob); bm_out16(Bool_Glob); bm_out8(Ch_1_Glob); bm_out8(Ch_2_Glob); bm_out16(Arr_1_Glob[8]); bm_out16(Arr_2_Glob[8][7]);
  bm_out16(Ptr_Glob->variant.var_1.Int_Comp); bm_out16(Next_Ptr_Glob->variant.var_1.Int_Comp);
  bm_out16(Int_1_Loc); bm_out16(Int_2_Loc); bm_out16(Int_3_Loc); bm_out16(Enum_Loc);
  bm_out16(strcmp(Str_1_Loc, "DHRYSTONE PROGRAM, 1'ST STRING")); bm_out16(strcmp(Str_2_Loc, "DHRYSTONE PROGRAM, 2'ND STRING"));
'''
d1 = d1[:i] + rep + d1[k:]
d1 = d1.replace('Enumeration     Func_1 ();', '')
open(os.path.join(H, 'dhry_p.h'), 'a').write(PROTO)
open(os.path.join(H, 'dhry_1p.c'), 'w').write(ansi(d1))
d2 = open(os.path.join(H, 'dhry_2.c')).read().replace('#include "dhry.h"', '#include "dhry_p.h"')
open(os.path.join(H, 'dhry_2p.c'), 'w').write(ansi(d2))
