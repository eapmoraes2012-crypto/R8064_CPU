/* bm_board.h - board benchmark runtime (bm_rt_board.c, crt0_board.s) */
#ifndef BM_BOARD_H
#define BM_BOARD_H
extern unsigned int bm_res[32]; extern unsigned char bm_nres;
unsigned long bm_clocks(void);
void bm_putc(char c); void bm_puts(const char *s); void bm_putu(unsigned long v); void bm_putfix(unsigned long v, unsigned char dec);
void set_mode(unsigned char m);        /* crt0_board.s: 1 = Z80 (MSX DRAM timing), 4 = R8064 native */
#endif
