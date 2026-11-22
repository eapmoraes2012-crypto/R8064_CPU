/* bm_rt_board.c - runtime of the benchmarks on the board (r8064_bench_top, bare Tang Nano 20K): timer through the bench ports
   F0h (start) / F1h (stop) / F4h..F7h (clocks), text through the bench UART (port 90h, 115200 8N1), results captured in bm_res[]. */
#include "../bm_rt.h"
#include "bm_board.h"
__sfr __at 0x90 p_uart;
__sfr __at 0xF0 p_start;
__sfr __at 0xF1 p_stop;
__sfr __at 0xF4 p_t0;
__sfr __at 0xF5 p_t1;
__sfr __at 0xF6 p_t2;
__sfr __at 0xF7 p_t3;
unsigned int bm_res[32]; unsigned char bm_nres;
void bm_start(void) { bm_nres = 0; p_start = 1; }
void bm_stop(void)  { p_stop = 1; }
void bm_out8(unsigned char v) { if (bm_nres < 32) bm_res[bm_nres++] = v; }
void bm_out16(unsigned int v) { if (bm_nres < 32) bm_res[bm_nres++] = v; }
static char pool[256]; static int used;
char *bm_alloc(int n) { char *p = pool + used; used += (n + 1) & ~1; return p; }
void bm_alloc_reset(void) { used = 0; }
unsigned long bm_clocks(void) {
    unsigned long v = p_t0; v |= (unsigned long)p_t1 << 8; v |= (unsigned long)p_t2 << 16; v |= (unsigned long)p_t3 << 24; return v;
}
void bm_putc(char c) { while (p_uart & 1) ; p_uart = c; }
void bm_puts(const char *s) { while (*s) { if (*s == '\n') bm_putc('\r'); bm_putc(*s++); } }
void bm_putu(unsigned long v) {        /* decimal */
    char b[11]; unsigned char i = 0;
    do { b[i++] = '0' + (char)(v % 10); v /= 10; } while (v);
    while (i) bm_putc(b[--i]);
}
void bm_putfix(unsigned long v, unsigned char dec) {   /* v / 10^dec with dec decimals */
    unsigned long p = 1; unsigned char k;
    if (dec == 0) { bm_putu(v); return; }
    for (k = 0; k < dec; k++) p *= 10;
    bm_putu(v / p); bm_putc('.');
    v %= p;
    for (k = dec; k > 0; k--) { p /= 10; bm_putc('0' + (char)(v / p)); v %= p; }
}
