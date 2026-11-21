/* flt.c - single-precision floating point throughput with the SDCC software float library (IEEE 754 binary32).
   Part 1: FLT_ITERS x 10 x (2 multiplies + 1 add); part 2: FLT_ITERS x 10 divisions. Both parts are inside one timing window
   (FLT_ITERS = 5 -> 200 FLOP). Result: x*1000 and y*1000 as 32-bit integers (26000 and 999951). */
#include "bm_rt.h"
volatile float a = 1.000001f, b = 0.999999f, c = 0.5f;
void main(void)
{
    unsigned int it; unsigned char j; float x = 1.0f, y = 1000.0f; long r;
    bm_start();
    for (it = 0; it < FLT_ITERS; it++)
        for (j = 0; j < 10; j++) x = x * a + c * b;              /* 2 multiplies + 1 add = 3 FLOP */
    for (it = 0; it < FLT_ITERS; it++)
        for (j = 0; j < 10; j++) y = y / a;                      /* 1 divide */
    bm_stop();
    r = (long)(x * 1000.0f); bm_out16((unsigned int)r); bm_out16((unsigned int)(r >> 16));
    r = (long)(y * 1000.0f); bm_out16((unsigned int)r); bm_out16((unsigned int)(r >> 16));
}
