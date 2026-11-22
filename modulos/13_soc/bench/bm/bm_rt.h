/* bm_rt.h - runtime of the benchmarks: no OS, timing and results through I/O ports (see crt0.s). */
#ifndef BM_RT_H
#define BM_RT_H
#include <string.h>
void bm_start(void);              /* OUT (0F0h): start of the timed part  */
void bm_stop(void);               /* OUT (0F1h): end of the timed part    */
void bm_out8(unsigned char v);    /* OUT (0F2h): one result byte           */
void bm_out16(unsigned int v);
char *bm_alloc(int n);            /* static allocator (no heap)           */
#ifdef BM_BOARD
/* board build (board/): the iteration counts are variables set by the board main; results are captured, not sent to port F2h */
extern unsigned int dhry_runs, sieve_runs, flt_runs;
void bm_alloc_reset(void);
#endif
#endif
