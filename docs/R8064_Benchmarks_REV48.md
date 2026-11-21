# R8064 — Benchmarks (REV48, 2026-11-21)

Same binary (SDCC 4.4.1, `-mz80 --opt-code-speed`) run in the three CPU modes of the R8064. Pipeline clock 57.2727 MHz.

| Benchmark | MSX Z80 3.58 MHz | turbo R R800 7.16 MHz (DRAM) | R8064 native 57.27 MHz | R8064 / Z80 | R8064 / R800 |
| --- | --- | --- | --- | --- | --- |
| Dhrystone 2.1 (Dhrystones/s) | 267.8 | 1 557 | 3 515 | 13.1× | 2.26× |
| DMIPS (÷ 1757) | 0.152 | 0.886 | 2.00 | | |
| DMIPS/MHz | 0.043 | 0.124 | 0.035 | | |
| BYTE Sieve, 8190 flags, 1 pass (s) | 2.215 | 0.399 | 0.115 | 19.3× | 3.48× |
| Software float, SDCC binary32 (FLOPS) | 217 | 1 172 | 3 758 | 17.3× | 3.21× |

Hardware FPU (80-bit, full core only, native mode; not in the cartridge build `R8064_NOFPU`):

| Kernel (dependent chain) | Clocks | MFLOPS @ 57.27 MHz |
| --- | --- | --- |
| FADD ST0,ST1 | 32.2 | 1.78 |
| FMUL ST0,ST1 | 152 | 0.38 |
| FDIV ST0,ST1 | 157 | 0.36 |
| FSQRT ST0 | 222 | 0.26 |
| SAXPY element (FLD32, FMUL, FADD, FSP32; 2 FLOP) | 250.9 | 0.46 |

## Method

- Sources: `modulos/13_soc/bench/bm/` (Dhrystone 2.1 from sifive/benchmark-dhrystone, BYTE Sieve, `flt.c`). `build.py` compiles them and writes
  one image per mode (mode byte at 0010h: 1 Z80, 3 R800, 4 native). Timing window: `OUT (0F0h)` … `OUT (0F1h)`; results go out on port 0F2h and
  are checked (Dhrystone final values, 1899 primes, float results 26.000 and 999.951).
- R8064 native: RTL simulation of the full SoC (`tb_bm.v`, caches, SDRAM controller and model) — the board matches simulation (bench 256/256).
- Z80 / R800: `mk_bmtime.py` — the module 12 Z80 reference model timed with the governor table `gov_rom.mem` (Z80: T-states + M1 wait;
  R800: cycles + 256-byte page crossing + refresh 25/210). Check: Dhrystone in Z80 mode on the RTL gave 4 277 104 clocks = 267 319 T × 16,
  exactly the model's value.
- Dhrystone: 20 runs (Z80, R800, native). Float: 5 × 10 × (2 FMUL + 1 FADD) + 50 FDIV = 200 FLOP.
- Hardware FPU: `fpu_meas.py` through `sim/tb_meas.v` (loop with 16 copies minus the empty loop).

## Notes

- The native figures use Z80 code. The R8064 runs it at about 12.8 clocks per instruction (8-clock decoder floor plus waits), so DMIPS/MHz is
  lower than the R800's. Code built for the 64-bit instructions (wider registers, MUL/DIV, FPU) would go faster; this table does not cover it.
- The R800 figures assume a program in internal RAM (no external-slot waits, no VDP pauses).
