/* bm_rt.c - runtime of the benchmarks (see bm_rt.h). */
#include "bm_rt.h"
__sfr __at 0xF0 p_start;
__sfr __at 0xF1 p_stop;
__sfr __at 0xF2 p_res;
void bm_start(void) { p_start = 1; }
void bm_stop(void)  { p_stop = 1; }
void bm_out8(unsigned char v) { p_res = v; }
void bm_out16(unsigned int v) { p_res = v & 0xFF; p_res = v >> 8; }
static char pool[256]; static int used;
char *bm_alloc(int n) { char *p = pool + used; used += (n + 1) & ~1; return p; }
