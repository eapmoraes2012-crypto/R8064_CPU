;; crt0.s - startup for the benchmarks (SDCC z80): selects the CPU mode, initialises the C data and calls main.
;; Byte at 0010h = mode (patched by build.py): 1 = Z80 with MSX DRAM timing (3.58 MHz + M1 wait), 3 = R800 DRAM timing (turbo R),
;; 4 = R8064 native. Timing markers for the testbench / board: OUT (0F0h) start, OUT (0F1h) stop, OUT (0F2h) result bytes, OUT (0F3h) end.
        .module crt0
        .globl  _main
        .globl  l__INITIALIZER, s__INITIALIZED, s__INITIALIZER
        .area   _HEADER (ABS)
        .org    0x0000
        di
        ld      sp,#0xF000
        jp      init
        .org    0x0010
mode:   .db     4
init:   ld      a,(mode)
        cp      #4
        jr      z,nat
        ld      c,#0x20                 ; S1990 register 6: 20h = Z80 DRAM, 00h = R800 DRAM
        cp      #1
        jr      z,sel
        ld      c,#0x00
sel:    ld      a,#6
        out     (0xE4),a
        ld      a,c
        out     (0xE5),a
        ld      a,#0xA5
        out     (0x3D),a
        xor     a
        out     (0x3E),a
        jr      go
nat:    ld      a,#0xA5
        out     (0x3D),a
        ld      a,#1
        out     (0x3E),a
go:     nop
        nop
        nop
        nop
        call    gsinit
        call    _main
        ld      a,#0xAA
        out     (0xF3),a
stop:   jr      stop

        .area   _HOME
        .area   _CODE
        .area   _INITIALIZER
        .area   _GSINIT
        .area   _GSFINAL
        .area   _DATA
        .area   _INITIALIZED
        .area   _BSEG
        .area   _BSS
        .area   _HEAP

        .area   _GSINIT
gsinit::
        ld      bc,#l__INITIALIZER
        ld      a,b
        or      a,c
        jr      z,gsinit_next
        ld      de,#s__INITIALIZED
        ld      hl,#s__INITIALIZER
        ldir
gsinit_next:
        .area   _GSFINAL
        ret
