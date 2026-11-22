;; crt0_board.s - startup of the board benchmarks: native mode, clears the C variables (_DATA.._BSS), copies the initialised data,
;; calls main; set_mode(m) switches the CPU mode at run time (1 = Z80 with MSX DRAM timing, 4 = R8064 native).
        .module crt0_board
        .globl  _main
        .globl  l__INITIALIZER, s__INITIALIZED, s__INITIALIZER, s__DATA, l__DATA
        .area   _HEADER (ABS)
        .org    0x0000
        di
        ld      sp,#0xF000
        jp      init
        .org    0x0010
init:   ld      a,#4
        call    _set_mode
        ld      hl,#s__DATA             ; clear the uninitialised variables (the SDRAM is not cleared at power-up)
        ld      bc,#l__DATA
        ld      a,b
        or      a,c
        jr      z,cl_done
cl:     ld      (hl),#0
        inc     hl
        dec     bc
        ld      a,b
        or      a,c
        jr      nz,cl
cl_done:
        call    gsinit
        call    _main
stop:   jr      stop

;; set_mode(m): A = m (sdcccall(1))
_set_mode::
        cp      #4
        jr      z,sm_nat
        ld      c,#0x20                 ; S1990 register 6: 20h = Z80 DRAM, 00h = R800 DRAM
        cp      #1
        jr      z,sm_sel
        ld      c,#0x00
sm_sel: ld      a,#6
        out     (0xE4),a
        ld      a,c
        out     (0xE5),a
        ld      a,#0xA5
        out     (0x3D),a
        xor     a
        out     (0x3E),a
        jr      sm_go
sm_nat: ld      a,#0xA5
        out     (0x3D),a
        ld      a,#1
        out     (0x3E),a
sm_go:  nop
        nop
        nop
        nop
        ret

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
