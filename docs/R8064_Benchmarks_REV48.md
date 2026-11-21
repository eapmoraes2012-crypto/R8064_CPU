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

## REV50 — overlapped decoder (2026-11-21)

The decoder became two overlapped stages (A: capture, ROMs, length; B: decoded candidate and issue), and the partial-write interlock no
longer waits for the producer to leave W (the register file bypass gives the merged value). Same binaries, same testbench (RTL, native mode):

| Benchmark | REV48 | REV50 | Gain | REV50 vs R800 | REV50 vs Z80 |
| --- | --- | --- | --- | --- | --- |
| Dhrystone 2.1 (Dhrystones/s) | 3 515 | 4 162 | +18 % | 2.67× | 15.5× |
| DMIPS | 2.00 | 2.37 | | | |
| Sieve, 1 pass (s) | 0.115 | 0.0965 | 1.19× | 4.13× | 23.0× |
| Software float (FLOPS) | 3 758 | 4 472 | +19 % | 3.81× | 20.6× |

Clocks per instruction in Dhrystone: 13.0 → 11.0. Where the clocks go now (Dhrystone, 275,216 clocks, 24,980 instructions, 37,428 uops):
issue 14 %, uop spacing (4 clocks, 5 after a load) 33 %, partial-write interlock 11 %, data waits 13 %, stage B load-to-issue 4 %,
stage A not ready (after taken branches and chains) 23 %, flush 1 %. The next limits are the fixed uop spacing (forwarding only from M
and W) and the taken-branch refill. Z80 mode is unchanged (Dhrystone on the RTL: 4,277,104 clocks, the same as REV48 and the model).
The hardware FPU kernels are not affected (they are limited by the FPU latency).

## REV51 — branch prediction in the decoder (2026-11-21)

Stage A predicts JP nn, JR e, CALL nn, RET (4-entry return stack) and backward JR cc / DJNZ / JP cc, and restarts the fetch at the
target at once; X2 verifies (a wrong prediction costs the old flush). Instructions that write CRs / privileged ones now also refetch the
following instructions after they complete (the prefetch may have run ahead of an MMU or mode change).

| Benchmark | REV48 | REV50 | REV51 | REV51 vs R800 | REV51 vs Z80 |
| --- | --- | --- | --- | --- | --- |
| Dhrystone 2.1 (Dhrystones/s) | 3 515 | 4 162 | 4 563 | 2.93× | 17.0× |
| DMIPS | 2.00 | 2.37 | 2.60 | | |
| Sieve, 1 pass (s) | 0.115 | 0.0965 | 0.0899 | 4.44× | 24.6× |
| Software float (FLOPS) | 3 758 | 4 472 | 4 812 | 4.11× | 22.1× |

Dhrystone: 3,664 taken branches, 1,542 still flush (58 % predicted); 10.0 clocks per instruction. Z80 mode unchanged (4,277,104 clocks).

Dependency-based issue with X3 forwarding (the other proposed step) was evaluated first with an upper-bound experiment: removing the
spacing between instructions altogether (unsafe, only to measure) saved 1.3 % in Dhrystone (275,216 -> 271,563 clocks), because the
4-clock floor is set by the decode/issue loop itself (uop ROM read -> register indices -> interlock, all registered: B issues at most every
4 clocks, and a chain uop every 4 clocks). It was not implemented: the gain needs that loop restructured first (indices computed in A,
B reloaded in the issue clock, next chain uop prefetched), and X3 forwarding puts the 64-bit adder in the operand path (Fmax risk).
