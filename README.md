# R8064 - 64-bit CPU derived from the Z80, on FPGA (Tang Nano 20K, GW2AR-18)

64-bit CPU derived from the Z80 (with Z80/R800 timing modes and a native mode), built module by module for an MSX slot.
Clock target: 57.28 MHz (3.58 MHz x 16).

**Preliminary 2026** (REV48, 20/11/2026). First run on the Tang Nano 20K on 20/11/2026: the core runs from the embedded SDRAM and 256 of 256 measured instruction timings equal the simulation (timing bench, `modulos/13_soc/bench`). The MSX cartridge has not been tested on hardware yet.

**Datasheet:** [R8064 - Datasheet (Preliminary) 2026](docs/R8064_Datasheet.md), with the complete instruction list (Appendix C) and the measured timing (Appendix D); Appendix B, instruction tables by group: [docs/R8064_Datasheet_Appendix_B.md](docs/R8064_Datasheet_Appendix_B.md). Timing spreadsheet: [docs/timings](docs/timings).

**MSX software:** user guide [docs/R8064_MSX_Software.md](docs/R8064_MSX_Software.md); files in [modulos/13_soc/msx](modulos/13_soc/msx/README.md) — `R8064.COM` (MSX-DOS) and the `r8064io.asm` Z80 driver to send and read data and programs to/from the R8064 through ports 0Bh–0Dh.

**Assembler for MSX:** `R8064AS.COM` assembles the full R8064 instruction set on the MSX itself — [docs/R8064_Assembler.md](docs/R8064_Assembler.md), files in [modulos/13_soc/msx/asm](modulos/13_soc/msx/asm/README.md).

## Current status (read before using)
- The SoC core (`09_core_min`) runs the **complete Z80**: main page, CB, DD/FD (IX/IY, IXH/IXL), DDCB/FDCB and the Z80 ED page.
  Checked instruction by instruction against the model `12_z80/ref/z80ref.c` (`09_core_min/sim_z80`: over 1.1 million instructions, X/Y flags included,
  and the start of ZEXDOC). Since REV36 this is the default ROM (`uop.mem`) of the SoC and of all tests; the old test encoding of the main page is gone.
- R8064's own instructions (ED page) with microcode: the 16/32/64-bit integer ones (ALU, INC/DEC, shifts, bits, LDx, stack, branches, calls and
  returns), multiply and divide (module 03 blocks wired to the core, with flags and divide error), LDCR/STCR, PGINV, XCHG, CAS and the system ones
  (JP USER, SYSRT, SCALL, PROT, RESET, STDBY, WAKE, SVCTX, LDCTX). Semantics INFERRED (`09_core_min/PREMISSAS_R8064.txt`),
  checked against a Python model written from those assumptions (`09_core_min/sim_r64`: random programs, no divergences).
- Privilege and exception model (REV40, `09_core_min/MODELO_PRIVILEGIO.txt`): supervisor / user modes (CR18), single exception entry through the CR9 vector
  with cause / auxiliary / EPC in CR11 / CR12 / CR13, return through SYSRT. It is a DEFINITION made in this revision, not something that already existed in the project: review it.
  MSX software always runs in supervisor mode and is not affected.
- FPU (REV41/42, `09_core_min/MODELO_FPU.txt`): 80-bit ST0-ST7 stack and the 45 FPU instructions of the table in the core, with a sequential arithmetic core
  (`08_fpu/rtl/fpu_seq.v`) and a program executor for transcendentals and remainders (`fpu_unit.v`). The transcendentals have an error of 1 to 2
  units in the last place (FLN up to 9) and FREM is not the exact x87 remainder. The unit costs about 4,400 LUTs: check the board occupancy
  (there is a switch to synthesize without it). Only the 16/32/64-bit I/O is missing.
- Known differences from a real Z80: R does not count fetches; HALT is a jump to itself; undocumented X/Y of BIT n,(HL) and of the block instructions; an ED opcode
  that is not a Z80 one is an R8064 instruction (only those with no instruction become a 2-byte NOP); code that modifies itself and then executes, with no branch in between, sees the old byte (fetch queue).
- Board-top PnR with the full Z80 (REV37): 52 % of the LUTs, 36 of 46 BSRAM; 3 of 4 seeds close at 57.28 MHz (59 to 74 MHz), with less slack than before.
- The SoC (`13_soc`) gathers core + governor + MSX memory + MMU + caches + SDRAM. It does not instantiate `msx_if` (04), the FPU (08/11) or the classic Z80 (12).
- The classic Z80 (`12_z80`) passes ZEXDOC, but the last measured Fmax (44-52 MHz) is below the 57.28 MHz clock.
- Nothing has been verified on hardware. The board top does not yet connect the MSX bus.
- **REV52 (2026-11-21): cartridge clock 42.9545 MHz (3.579545 × 12, rPLL ×3 from the board's 14.31818 MHz).** The clock is a parameter chain (`CPT` = clocks per Z80 T-state: cart top → SoC → system → governor; `MUL14` in `r8064_clkgen`; SDRAM `REF_INT` = 25 × CPT = 300 = 6.98 µs). The governed modes stay exact (Z80 Dhrystone on the RTL: 3,207,828 clocks = 267,319 T × 12); R800 cycle = 6 clocks. Macro `R8064_CLK57` restores 57.2727 MHz. The cartridge build is again without the FPU (REV51 with the FPU reached only 40.08 MHz in Gowin: the FPU sequencer path mir → X has 25 logic levels; REV51 without it: 57.50 MHz, 64 % logic). Native performance scales with the clock (Dhrystone ≈ 3,420/s = 1.95 DMIPS at 42.95 MHz). SDRAM clock phase SDR_PSDA = 12 was measured at 57.27 MHz and may need a new sweep (`r8064_sdtest_top`).
- **REV51 (2026-11-21): branch prediction in the decoder.** Stage A predicts JP nn (C3), JR e (18), CALL nn (CD) and RET (C9, 4-entry return stack), plus backward JR cc / DJNZ / JP cc, and restarts the fetch at the target immediately (the queue is rebased, the bytes of the instructions still in A/B stay counted before the target); the branch uop carries the prediction and X2 verifies it (taken to the same target: no flush; otherwise the normal flush, also to the next instruction when a predicted branch is not taken). Instructions that write CRs (except EI/DI/RETN/IM) or are privileged refetch the following instructions after they drain (MMU / mode changes). The fetch-fault distance is now full width. Gain over REV50: Dhrystone +9.6 % (2.60 DMIPS, 2.93× R800), Sieve +7 %, software float +7.6 %; Z80 mode unchanged; all regressions pass. Cost (yosys, cartridge): about +1,000 LUT4-eq (≈ 90 % of the GW2AR-18 estimated) — Gowin timing not yet run.
- **REV50 (2026-11-21): overlapped decoder.** The decoder is now two overlapped stages: A (window capture, prefix removal, ED decoder and main-page ROMs, first-uop read, length) and B (complete decoded candidate: register indices, interlocks, issue). A starts the next instruction as soon as the length of the current one is known, so the issue floor between instructions is the same as inside a uop chain (4 clocks, 5 after a load / IN / MUL-DIV-FPU) instead of ≥ 8. Instructions that change state read at decode/issue time (CR writes, I/O, EI/DI/RETN/IM, privileged, EXX/EX AF) still wait for an empty pipeline; interrupts stop the issue and discard the candidate; the PC travels with the uop to M for the EPC. The partial-write interlock no longer waits for W. Gain (same binaries): Dhrystone +18 % (2.37 DMIPS), Sieve 1.19×, software float +19 %; Z80/R800 modes keep the governed timing (Z80 Dhrystone identical). All regressions pass (modules 09, 10 and 13, incl. 100 random free-running Z80 programs). Cost (yosys, cartridge): about +180 LUT4-eq. The measured instruction timings of Appendix D and the board bench reference (`bench/ref_rev48.json`) are REV48 values and must be regenerated.
- **REV49c (2026-11-21): cartridge build = FPU, 2 DMA channels (`R8064_DMA2`), 32-bit addresses (`R8064_AW32`), without MLTSQ/MLTUQ/DIVSQ/DIVUQ (`R8064_NO_MD64`).** Yosys estimate (`synth_gowin`, cartridge top): LUT 15,318 + ALU 1,684 + 127 RAM16 ≈ 17,900 LUT4-eq (≈ 17,500 scaled to Gowin, ≈ 84 %) and 45 of 46 BSRAM — not yet run in Gowin. Measured steps: full core ≈ 19,600 (94 %); −AW32 −MD64 ≈ 18,050 (87 %); −DMA channels 2/3 ≈ 17,500 (84 %). The FPU itself is the large block (the REV48 build without it: 12,188). Regressions with these macros pass (SoC, SoC+DMA, exceptions, MMU 8 MB, native mapper, cartridge + monitor). `make_gowin_pkg.py --full` gives the full core, `--reduced-nofpu` the REV48 cartridge.
- **REV49 (2026-11-21, superseded by REV49c): the cartridge build was the full core** (FPU, 64-bit MUL/DIV, 4 DMA channels, 64-bit addresses; no build macros). To make room for the FPU step ROM, the third register-file read port (`regfile64_d`, port D) moved from BSRAM to LUT RAM (frees 2 BSRAM). Yosys estimate (`synth_gowin`, cartridge top): about 20,060 LUT4-eq (LUT 17,222 + ALU 1,916 + 127 RAM16) and 45 of 46 BSRAM, against 12,469 and 46 for REV48; scaled to the REV48 Gowin result this is about 19,600 (≈ 94 %) — **not yet run in Gowin; timing at 57.27 MHz unknown**. If it does not fit or does not close timing: `make_gowin_pkg.py --reduced` (FPU kept; `R8064_DMA2 R8064_AW32 R8064_NO_MD64`, ≈ 14,900, 72 %) or `--reduced-nofpu` (the REV48 cartridge). Simulation regressions pass with the full core (SoC, exceptions, DMA, MMU, native mapper, cartridge + monitor); the timing bench (`bench/`) still uses the reduced macros.
- **Tang Nano 20K builds (REV47/REV48, now the `--reduced-nofpu` option)**: the cartridge (`13_soc/rtl/r8064_cart_top.v`) is built with `R8064_NOFPU` (no FPU), `R8064_DMA2`
  (2 DMA channels), `R8064_AW32` (32-bit implemented addresses: PC, fetch and effective addresses wrap modulo 2^32, the high bits read as 0)
  and `R8064_NO_MD64` (MLTSQ/MLTUQ and DIVSQ/DIVUQ are not implemented: unimplemented-instruction exception, cause 7, if CR14.TE = 1).
  Without these macros the core is the full 64-bit version (simulation). REV47 also rewrote some structures with the same function
  (load/store rotators, immediate extraction, multiplier accumulator, DMA state, divider registers) and fixed a hold and two timing paths.
- **Place and route**: with yosys + nextpnr the cartridge does not route reliably (68 % of the LUTs, BSRAM 46/46). With **Gowin EDA**
  (Education edition) it closes: 59 % of the logic, Fmax 59.94 MHz at 57.27 MHz, no setup/hold violations, bitstream generated
  (`13_soc/gowin/LEIA-ME_gowin.txt`). The SDRAM interface timing is not analysed (adjust `SDR_PSDA` in hardware).
- **REV48, fewer memory waits** (measured in simulation with `13_soc/sim/tb_wait.v`, native mode, code and data in the caches):
  with the MMU off the instruction fetch and the data access skip the 2 translation clocks (fetch 5 -> 3 clocks, load wait 4.7 -> 2.8),
  the fetch requests go back to back, and decoding starts as soon as the opcode bytes are in the queue (before: 13 bytes = 2 fetches after
  every branch; the window is refreshed until the whole instruction has arrived). Clocks per instruction, before -> after:
  simple ALU/NOP 8.95 -> 8.46; LDQ rr,(rr') 13.6 -> 11.3; LDQ rr,imm64 10.9 -> 8.9; PUSH+POP 17.6 -> 15.5 each; CALL(L)+RET(L) 38-39 -> 27.6 each.
  The rest of a simple instruction is the 4-phase decoder (about 6 clocks). The Z80/R800 modes keep their governed MSX timing.
  All regressions pass (core, SoC, cartridge + monitor, also with the cartridge macros); +165 LUT (+1.5 %) in yosys. **Not yet run in Gowin** (timing to be checked).
  The cycle table of the datasheet (`ref/expected_cycles.csv`) is a model and does not match these measurements.
- Pending items and history: `modulos/13_soc/resultado_soc.txt` (REV33 lists what is still open).

## Modules (`modulos/`)
| Folder | Contents | Used in the SoC |
|---|---|---|
| `01_alu_regfile` | 64-bit ALU and register file | yes (via 09) |
| `02_pipeline` | pipeline timing model (study, not synthesizable) | no |
| `03_muldiv` | multiplier and divider | yes (since REV39) |
| `04_msx_if` | MSX interface + FIFO (first version) | no |
| `05_sdram` | SDRAM controller and simulation model | yes |
| `05b_cache` | cache sizing study (Python) | - |
| `06_cache` | `cache8k` (2 ways, study) and `cache_dm` (direct mapped, the one used) | `cache_dm` |
| `07_mmu` | MMU Sv39 | sim |
| `08_fpu` | FPU: `fpu_unit.v` + `fpu_seq.v` (compact) | yes (since REV41) |
| `08_fpu/rtl/fpu_alu.v`, `11_fpu_stk` | old large FPU and standalone stack (superseded) | no |
| `09_core_min` | minimal core (uop-ROM decoder) and ROM generators | yes |
| `10_mode_gov` | timing governor + modes (Z80 ROM, R800 DRAM, native) + MSX system | yes |
| `10_msx_mem` | MSX memory mapper + MegaRAM | yes |
| `12_z80` | independent classic Z80 (reference) | no |
| `13_soc` | SoC: core + MMU + caches + SDRAM; board top and PnR flow | - |
| `14_vec3d` | 3D unit (archived; outside the core) | no |

## How to run
In the OSS CAD Suite terminal:
- Core/governor/system regression: `modulos\10_mode_gov\rodar_tudo.bat`
- SoC (exceptions, basic SoC, clock generator): `modulos\13_soc\rodar_exc.bat`
- Core in Z80 mode against the reference model: `modulos\09_core_min\sim_z80\rodar_z80core.bat`
- R8064 16/32/64-bit instructions, system and FPU against the model: `modulos\09_core_min\sim_r64\rodar_r64.bat`
- FPU arithmetic core against 39,000 vectors: `modulos\08_fpu\rodar_seq.bat`
- Place-and-route of the board top (4 seeds): `modulos\13_soc\pnr\rodar_pnr_board.bat`
- Bitstream: `modulos\13_soc\pnr\gerar_bitstream_board.bat 0 <seed>`
- Cartridge with Gowin EDA (recommended): `python3 modulos/13_soc/gowin/make_gowin_pkg.py <out_dir> <absolute path of out_dir/src>`, then `rodar_gowin.bat` or the Gowin GUI (`modulos/13_soc/gowin/LEIA-ME_gowin.txt`)

## `.mem` files (they are the project's SOURCE)
Keep the copies of `sim/` and `pnr/` in modules 09, 10 and 13 identical.
| File | Where it comes from |
|---|---|
| `uop.mem`, `mainctrl.mem`, `prog*.mem` | `09_core_min/sim/gen_roms.py` (uses `gen_z80_rom.py`, the Z80 microcode) |
| `ctrl_b.mem` | `09_core_min/sim/gen_bank.py instr_ids.csv ctrl.mem` |
| `r8064_decode_rom.v` | `09_core_min/sim/gen_decode_rom.py` (from `rom_ed_a.mem` and `amb_idx.mem`) |
| `gov_rom.mem` | `10_mode_gov/sim/gen_gov_rom.py ref/z80_classico_tstates.csv` |
| `ctrl.mem`, `rom_ed_a.mem`, `rom_ed_b.mem`, `amb_idx.mem` | **no generator in the repository**: they came from the instruction spreadsheet and were edited by hand afterwards (ids 291-295) |

The core RTL exists in two copies (`09_core_min/rtl` for simulation, `10_mode_gov/rtl` for synthesis): keep them identical (`rodar_tudo.bat` warns if they diverge).

Not versioned (`.gitignore`): `bak/` folders and PnR logs (`*.log`) cited in the result texts, and the instruction spreadsheets.

---

# Historical package (`rom/`, `rtl/`, `sim/`, `ref/`, `pnr/`, `gowin_mi/` folders at the root): decode ROM, testbench and expected cycles

> This is the first package of the project (isolated ED decoder, spreadsheet rev5, 290 instructions, 100 MHz target at the time).
> The ROMs and `r8064_decode.v` here are **older** than those of modules 09/10/13 (which have ids 291-295 and the recoded ED family 26): do not mix them.
> The text below describes the state of that time; the testbench here still passes with the ROMs here.

Generated from `Planilha_instrucoes_R8064_rev5.xlsx`. Covers ONLY the ED prefix page:
the 210 R8064 instructions (all start with ED) and the 80 Z80 ED instructions (R8064 Z80 mode).
The Z80 pages without ED (main, CB, DD, FD, DDCB, FDCB) have no ROM here; their T-states are in `ref/z80_classico_tstates.csv`.

## What was and was NOT verified
- VERIFIED (Python, `ref/verify_roms.py`): the ROMs reproduce the 65,536 expected (b2, b3) combinations, and the control words reproduce Clocks, Waits and Penalty of the spreadsheet for the 290 instructions (0 divergences).
- VERIFIED (RTL simulation): the testbench passes (PASS) in Icarus Verilog and Verilator: 65,536 vectors, 0 id errors, 0 cycle errors. Details in `ref/resultados_simulacao.txt`.
- VERIFIED (Yosys synthesis, `synth_gowin`): the module synthesizes; 6 BSRAM blocks (SPX9) and ~164 LUT4 plus 71 MUX2.
- VERIFIED (netlist): gate-level simulation of the synthesis without BSRAM: PASS. With BSRAM it cannot be simulated with the Yosys models (BSRAM has no behavioral model).
- VERIFIED (place-and-route): GW2AR-LV18QN88C8/I7, 111 MHz Fmax (target 100 MHz) for the isolated decoder, in a test wrapper (`pnr/`). 36 nextpnr hold warnings not analyzed.
- NOT COMPLETED: timing of the full design (ALU, FPU, MMU, SDRAM) and the real MSX slot pins.
- NOT VERIFIED: the format of the `.mi` files (Gowin) follows what I remember of the IP Core Generator; import one and check it.

## Files
| File | Contents |
|---|---|
| `rom/rom_ed_a.mem` | 256 × 12 bits, indexed by b2. Bit 10 = "ambiguous page" (look up ROM_B); bits 9:0 = instruction id (direct access) |
| `rom/amb_idx.mem` | 256 × 8 bits: ROM_B page number for each b2 (only valid if bit 10 of ROM_A = 1). Becomes combinational logic (LUT) |
| `rom/rom_ed_b.mem` | 33 pages × 256 × 10 bits, indexed by {page, b3}: instruction id (0 = illegal) |
| `rom/ctrl.mem` | 512 × 32 bits, indexed by id (control word below) |
| `gowin_mi/*.mi` | The same ROMs in the initialization format of Gowin's memory IP (to be checked) |
| `rtl/r8064_decode.v` | Decoder: ROM_A and ROM_B in parallel (+1 clock), control ROM in series (+2 clocks) |
| `rtl/tb_r8064_decode.v` | Exhaustive testbench (65,536 vectors) + cycle check |
| `ref/expected_id.mem` | expected id for each (b2, b3), generated directly from the bit patterns (independent of the ROMs) |
| `ref/expected_clock.mem`, `expected_wait.mem`, `expected_pen.mem` | Clocks, Waits (typical) and branch penalty per id |
| `ref/expected_cycles.csv` | Everything from the spreadsheet per instruction (semicolon, UTF-8) |
| `ref/instr_ids.csv` | id ↔ mnemonic ↔ hex |
| `ref/z80_classico_tstates.csv` | Classic Z80 T-states, 1,270 opcodes |
| `ref/verify_roms.py` | Python check, no simulator |

## Control word (32 bits)
`[3:0]` instruction bytes · `[8:4]` reads (NR) · `[13:9]` writes (NW) · `[15:14]` I/O accesses (NIO) · `[23:16]` X-stage occupancy (EX) · `[25:24]` penalty: 0 none, 1 BR_D, 2 BR_X, 3 BR_M · `[26]` a "false condition" variant exists · `[27]` Z80 ED instruction · `[31:28]` reserved.
Formulas (same as the spreadsheet, with HIT_I = HIT_D = 0): fetch accesses = ⌈bytes/8⌉; Clocks = MAX(1, fetch+NR+NW, NIO, EX); Waits = (fetch+NR)·W_RD_HIT + NW·W_WR_HIT + NIO·W_IO; total = clock + wait + penalty.

## How to run
- Icarus Verilog (from a working folder): `cp rom/*.mem ref/*.mem rtl/*.v . && iverilog -g2012 -o sim tb_r8064_decode.v r8064_decode.v && vvp sim` → must print `PASS`.
- Without a simulator: `python3 ref/verify_roms.py`.
- Everything at once (simulation, synthesis, place-and-route): `bash scripts/simular_e_sintetizar.sh`.
- Gowin EDA: add `r8064_decode.v` and the `.mem` files to the project. Confirm that synthesis infers BSRAM from `$readmemh`; if not, generate the ROMs with the IP Core Generator using the `.mi` files.

## Points of attention
1. The two serial reads (decode + control) may not fit in the 1-clock D stage of the pipeline. Possible decisions: split D into 2 clocks (the cycle model needs +1 latency and +1 branch penalty) or read the control ROM in the R stage.
2. Measured size: ROM_A 3 Kbit, ROM_B ≈ 84 Kbit, control 16 Kbit. Yosys synthesis mapped the module to 6 BSRAM blocks (SPX9) and about 164 LUT4; the spreadsheet predicted 3 blocks. The Occupancy tab was corrected with these numbers.
3. Illegal ED bytes: `id = 0`. On the independent classic Z80 they execute as an 8 T-state NOP; on the R8064 they should raise an exception (your decision).
4. The "false cond." column of the spreadsheet is NOT in the ROM (only the `has_cond` bit).
