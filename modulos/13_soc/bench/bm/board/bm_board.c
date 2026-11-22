/* bm_board.c - benchmarks on the bare Tang Nano 20K (timing-bench bitstream with this image in the boot buffer): Dhrystone 2.1,
   BYTE Sieve and SDCC software float, first in R8064 native mode, then in Z80 mode (governor, MSX timing), with the clocks counted
   by the bench hardware and the results checked. Output on the USB serial (115200 8N1). F = clock of the bench (43.2 MHz). */
#include "../bm_rt.h"
#include "bm_board.h"
#ifndef BM_FCLK
#define BM_FCLK 27000000UL
#endif
#define F_CLK BM_FCLK            /* clock of the bench: 27 MHz (REV53), -DBM_FCLK=43200000UL for the REV52 build */
unsigned int dhry_runs, sieve_runs, flt_runs;
void dhry_main(void); void sieve_main(void); void flt_main(void);
static unsigned char errs;
static void chk(const char *what, unsigned char n, const unsigned int *exp) {
    unsigned char i, ok = (bm_nres == n);
    for (i = 0; ok && i < n; i++) if (bm_res[i] != exp[i]) ok = 0;
    bm_puts(ok ? "  results OK" : "  results WRONG:");
    if (!ok) { errs++; for (i = 0; i < bm_nres; i++) { bm_putc(' '); bm_putu(bm_res[i]); } }
    bm_puts("\n"); (void)what;
}
static void rate(const char *unit, unsigned long ops, unsigned long clk, unsigned char dec) {
    /* ops per second with 'dec' decimals = ops * F / clk, without 32-bit overflow: (F * 10^dec) / (clk / ops) */
    unsigned long cpo = clk / ops, p = 1; unsigned char k;
    for (k = 0; k < dec; k++) p *= 10;
    bm_putfix((F_CLK / cpo) * p + ((F_CLK % cpo) * p) / cpo, dec); bm_puts(unit);
}
static void run_all(const char *mname, unsigned int druns, unsigned char all) {
    unsigned long c; unsigned int e[14];
    bm_puts("\n== "); bm_puts(mname); bm_puts(" ==\n");
    /* Dhrystone */
    dhry_runs = druns; bm_alloc_reset(); dhry_main(); c = bm_clocks();
    bm_puts("Dhrystone 2.1, "); bm_putu(druns); bm_puts(" runs: "); bm_putu(c); bm_puts(" clocks = ");
    bm_putu(c / druns); bm_puts(" clocks/run, "); rate(" Dhrystones/s, ", druns, c, 1);
    { unsigned long cpr = c / druns, dm = (F_CLK / cpr) * 1000UL / 1757UL; bm_putfix(dm, 3); bm_puts(" DMIPS\n"); }
    e[0] = 5; e[1] = 1; e[2] = 'A'; e[3] = 'B'; e[4] = 7; e[5] = druns + 10; e[6] = 17; e[7] = 18; e[8] = 5; e[9] = 13; e[10] = 7; e[11] = 1; e[12] = 0; e[13] = 0;
    chk("dhry", 14, e);
    if (!all) return;
    /* Sieve */
    sieve_runs = 1; sieve_main(); c = bm_clocks();
    bm_puts("Sieve (8190 flags, 1 pass): "); bm_putu(c); bm_puts(" clocks = "); bm_putfix(c / (F_CLK / 100000UL), 2); bm_puts(" ms\n");
    e[0] = 1899; chk("sieve", 1, e);
    /* software float */
    flt_runs = 5; flt_main(); c = bm_clocks();
    bm_puts("Float (SDCC soft, 200 FLOP): "); bm_putu(c); bm_puts(" clocks = "); rate(" FLOPS\n", 200, c, 0);
    e[0] = 26000; e[1] = 0; e[2] = 0x420F; e[3] = 0x000F; chk("flt", 4, e);
}
void main(void) {
    errs = 0;
    bm_puts("\nR8064 board benchmarks (REV53, bench clock "); bm_putfix(F_CLK / 10000UL, 2); bm_puts(" MHz; Z80 mode = "); bm_putfix(F_CLK / 80000UL, 3); bm_puts(" MHz, CPT 8)\n");
#ifdef BM_QUICK   /* simulation: short runs, Z80 mode Dhrystone only */
    set_mode(4); run_all("R8064 native", 20, 1);
    set_mode(1); run_all("Z80 mode (MSX timing)", 5, 0);
#else
    set_mode(4); run_all("R8064 native", 2000, 1);
    set_mode(1); run_all("Z80 mode (MSX timing)", 200, 1);
#endif
    set_mode(4);
    bm_puts("\nDone: "); bm_putu(errs); bm_puts(errs ? " WRONG result(s)\n" : " errors. Press KEY1 to run again.\n");
}
