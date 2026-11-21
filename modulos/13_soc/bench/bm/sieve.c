/* sieve.c - BYTE magazine Sieve of Eratosthenes (Gilbreath, 1981): 8190 flags, primes up to 16381. Expected count: 1899 primes. */
#include "bm_rt.h"
#define SIZE 8190
static char flags[SIZE + 1];
void main(void)
{
    unsigned int i, prime, k, count, iter;
    bm_start();
    for (iter = 0; iter < SIEVE_ITERS; iter++) {
        count = 0;
        for (i = 0; i <= SIZE; i++) flags[i] = 1;
        for (i = 0; i <= SIZE; i++) {
            if (flags[i]) {
                prime = i + i + 3;
                for (k = i + prime; k <= SIZE; k += prime) flags[k] = 0;
                count++;
            }
        }
    }
    bm_stop();
    bm_out16(count);
}
