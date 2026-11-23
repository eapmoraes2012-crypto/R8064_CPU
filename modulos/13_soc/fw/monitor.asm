; monitor.asm - R8064 monitor (v1, Z80 mode). Runs from SDRAM 0 (copied from the buffer at boot).
; Uses only instructions that the REV48 core already executes (no CB, HALT, RST, DAA, ADD HL,rr, PUSH/POP AF).
; MSX<->R8064 protocol: see the datasheet (format: OP, SEQ, parameters / response: OP|80, SEQ, ST, data).
; ST: 00 ok | 01 unknown OP | 02 invalid parameter | 03 misaligned / unsupported address | 04 DMA error | 05 unsupported EXEC mode
FDATA  equ 0E8h
FSTAT  equ 0E9h
FLENL  equ 0EAh
FLENH  equ 0EBh
FFLG   equ 0ECh
DSTAT  equ 0EEh
SCR_S  equ 2100h      ; 8 aligned bytes: physical source of the DMA (bytes 4..7 = 0)
SCR_D  equ 2108h      ; physical destination of the DMA
SCR_C  equ 2110h      ; DMA CTRL: [0..1] = words, [3] = 80h (START), rest 0
V_ADDR equ 2120h      ; 4 bytes
V_REM  equ 2124h      ; 4 bytes
V_CRC  equ 2128h
V_N    equ 212Ah
V_OFF  equ 212Ch
V_W    equ 212Eh
V_SIZE equ 2130h
V_LEN  equ 2132h
V_TMP  equ 2134h
V_EXIT equ 2138h      ; 8 aligned bytes
V_DMA  equ 2140h      ; 1 = DMA present (detected at start), 0 = copies by the CPU (R8064_NO_DMA builds)
MSGB   equ 2200h      ; received message (up to 2048 bytes)
STG    equ 3000h      ; DMA staging area (2 KB)
STACK  equ 2FF0h
TLO    equ 0800h      ; CRC table, low byte (256-aligned)
THI    equ 0900h      ; CRC table, high byte

        org 0
start:  ld sp,STACK
        ld a,04h
        call setmode          ; monitor in NATIVE64 (no Z80 timing governor)
        ld hl,SCR_S
        ld b,40h
        xor a
clr:    ld (hl),a
        inc hl
        djnz clr
        ld a,80h
        ld (SCR_C+3),a
        ld a,01h              ; DMA detection: the IE port (EFh) keeps bit 0 only when the DMA exists
        out (0EFh),a
        in a,(0EFh)
        and 01h
        ld (V_DMA),a
        xor a
        out (0EFh),a
main:   in a,(FFLG)
        and 01h
        jr z,main
        in a,(FLENL)
        ld c,a
        in a,(FLENH)
        ld b,a
        cp 08h
        jr c,lenok
        ld bc,0800h           ; limits to 2048 bytes
lenok:  ld a,c
        ld (V_LEN),a
        ld a,b
        ld (V_LEN+1),a
        ld hl,MSGB
rd:     ld a,b
        or c
        jr z,rdone
        in a,(FDATA)
        ld (hl),a
        inc hl
        dec bc
        jr rd
rdone:  ld a,03h
        out (FFLG),a          ; clears START (busy stays 1)
        ld a,(V_LEN+1)
        or a
        jp nz,haveop
        ld a,(V_LEN)
        cp 02h
        jp c,err_par
haveop: ld a,(MSGB)
        or a
        jp z,op_ping
        cp 01h
        jp z,op_hello
        cp 02h
        jp z,op_ping          ; RESET: the state is fully recreated on every message
        cp 10h
        jp z,op_wput
        cp 11h
        jp z,op_wget
        cp 12h
        jp z,op_poke
        cp 13h
        jp z,op_peek
        cp 20h
        jp z,op_exec
        cp 21h
        jp z,err_al           ; STOP: no running program listening to messages (v1)
        cp 30h
        jp z,op_crc
        ld a,01h
        jp reply_st
err_par: ld a,02h
        jp reply_st
err_al: ld a,03h
        jp reply_st
err_dma: ld a,04h
        jp reply_st
err_mod: ld a,05h
        jp reply_st
op_ping: xor a
reply_st: call rsph
        ld bc,3
fin:    call finr
        jp main
rsph:   ld c,a                ; A = ST: writes OP|80, SEQ, ST into the R8064->MSX FIFO
        ld a,(MSGB)
        or 80h
        out (FDATA),a
        ld a,(MSGB+1)
        out (FDATA),a
        ld a,c
        out (FDATA),a
        ret
finr:   ld a,c                ; BC = total size: LEN and DONE (returns the window to the MSX)
        out (FLENL),a
        ld a,b
        out (FLENH),a
        ld a,05h
        out (FFLG),a
        ret
; ---------------------------------------------------------------- HELLO
op_hello: xor a
        call rsph
        ld hl,hello_d
        ld b,10
hl1:    ld a,(hl)
        out (FDATA),a
        inc hl
        djnz hl1
        ld a,(V_DMA)          ; features: window only with the DMA
        or a
        ld a,07h
        jr nz,hl2
        ld a,06h
hl2:    out (FDATA),a
        ld bc,14
        jp fin
hello_d: db 'R8064'
        db 01h,00h,08h,00h,40h       ; version 1, max msg 2048, block 16384 (features byte sent by op_hello)
; ---------------------------------------------------------------- utilities
chka:   inc hl                ; HL -> 4 bytes of physical address; Z = valid (8 MB: byte3 = 0, bit 23 = 0)
        inc hl
        ld a,(hl)
        and 80h
        ret nz
        inc hl
        ld a,(hl)
        or a
        ret
ceil8:  ld de,0               ; HL = bytes -> HL = ceil(bytes / 8)
c8l:    ld a,h
        or a
        jr nz,c8s
        ld a,l
        cp 08h
        jr c,c8e
c8s:    ld a,l
        sub 08h
        ld l,a
        ld a,h
        sbc a,0
        ld h,a
        inc de
        jr c8l
c8e:    ld a,l
        or a
        jr z,c8f
        inc de
c8f:    ex de,hl
        ret
dmarun: ld a,(V_DMA)          ; HL = words; SCR_S/SCR_D already filled. NZ on return = error
        or a
        jr nz,dmahw
        ld a,(SCR_S+2)        ; no DMA: copy by the CPU (native mode, MMU off: 32-bit physical addresses)
        ld c,a
        ld a,(SCR_D+2)
        or c
        and 80h               ; the window buffer (bit 23) is reachable only by the DMA
        ret nz
        ld b,h
        ld c,l
        ld a,b
        or c
        ret z
        ld hl,SCR_D
        db 0EDh,39h,14h       ; LDQ DE,(HL)
        ld hl,SCR_S
        db 0EDh,39h,24h       ; LDQ HL,(HL)
        db 0EDh,39h,59h,08h,00h,00h,00h,00h,00h,00h,00h   ; LDQ IY,8
cpl:    db 0EDh,39h,3Ch       ; LDQ AX,(HL)
        db 0EDh,39h,0D7h      ; LDQ (DE),AX
        db 0EDh,3Eh,0A3h      ; ADDQ HL,IY
        db 0EDh,3Eh,93h       ; ADDQ DE,IY
        dec bc
        ld a,b
        or c
        jr nz,cpl
        db 0EDh,39h,61h,00h,00h,00h,00h,00h,00h,00h,00h   ; LDQ HL,0 (the Z80 code of the monitor uses HL and DE as 16-bit
        db 0EDh,39h,51h,00h,00h,00h,00h,00h,00h,00h,00h   ; LDQ DE,0  addresses: in native mode their high bits must be 0)
        db 0EDh,39h,79h,04h,00h,00h,00h,00h,00h,00h,00h   ; LDQ AX,4
        db 0EDh,0Ch,17        ; MTCR 17: invalidates the I and D caches (as the DMA does at the end of a transfer)
        xor a
        ret
dmahw:  ld a,l
        ld (SCR_C),a
        ld a,h
        ld (SCR_C+1),a
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ld hl,SCR_S
        db 0EDh,39h,3Ch       ; LDQ AX,(HL)
        db 0EDh,0Ch,19        ; MTCR 19 (SRC0)
        ld hl,SCR_D
        db 0EDh,39h,3Ch
        db 0EDh,0Ch,20        ; MTCR 20 (DST0)
        ld hl,SCR_C
        db 0EDh,39h,3Ch
        db 0EDh,0Ch,21        ; MTCR 21 (CTRL0: START)
dwait:  in a,(DSTAT)
        and 06h
        jr z,dwait
        ld c,a
        ld a,01h
        out (DSTAT),a
        ld a,c
        and 04h
        ret
crcrng: ld hl,0FFFFh          ; CRC-16 CCITT-FALSE of V_REM bytes starting at the physical address V_ADDR (aligned to 8). Result in V_CRC; NZ = error
        ld (V_CRC),hl
cr_l:   ld hl,V_REM
        ld a,(hl)
        inc hl
        or (hl)
        inc hl
        or (hl)
        inc hl
        or (hl)
        jp z,cr_end
        ld a,(V_REM+2)
        ld hl,V_REM+3
        or (hl)
        jp nz,cr_full
        ld a,(V_REM+1)
        cp 08h
        jp nc,cr_full
        ld a,(V_REM)
        ld l,a
        ld a,(V_REM+1)
        ld h,a
        jr cr_n
cr_full: ld hl,0800h
cr_n:   ld (V_N),hl
        call ceil8
        push hl
        ld hl,V_ADDR
        ld de,SCR_S
        ldi
        ldi
        ldi
        ldi
        xor a
        ld (SCR_D),a
        ld (SCR_D+2),a
        ld (SCR_D+3),a
        ld a,30h
        ld (SCR_D+1),a
        pop hl
        call dmarun
        jp nz,cr_err
        ld hl,(V_CRC)
        push hl
        exx
        pop bc                ; BC' = crc
        exx
        ld de,STG
        ld hl,(V_N)
        ld b,h
        ld c,l
cr_b:   ld a,(de)
        inc de
        exx
        xor b
        ld l,a
        ld h,08h
        ld e,(hl)             ; E' = TLO[idx]
        inc h
        ld a,(hl)             ; THI[idx]
        xor c
        ld b,a
        ld c,e
        exx
        dec bc
        ld a,b
        or c
        jr nz,cr_b
        exx
        push bc
        exx
        pop hl
        ld (V_CRC),hl
        ld hl,(V_N)
        ld a,(V_ADDR)
        add a,l
        ld (V_ADDR),a
        ld a,(V_ADDR+1)
        adc a,h
        ld (V_ADDR+1),a
        ld a,(V_ADDR+2)
        adc a,0
        ld (V_ADDR+2),a
        ld a,(V_ADDR+3)
        adc a,0
        ld (V_ADDR+3),a
        ld a,(V_REM)
        sub l
        ld (V_REM),a
        ld a,(V_REM+1)
        sbc a,h
        ld (V_REM+1),a
        ld a,(V_REM+2)
        sbc a,0
        ld (V_REM+2),a
        ld a,(V_REM+3)
        sbc a,0
        ld (V_REM+3),a
        jp cr_l
cr_end: xor a
        ret
cr_err: ld a,01h
        or a
        ret
sendcrc: xor a                ; reply with ST=0 + CRC (V_CRC)
        call rsph
        ld a,(V_CRC)
        out (FDATA),a
        ld a,(V_CRC+1)
        out (FDATA),a
        ld bc,5
        jp fin
; ---------------------------------------------------------------- WIN_PUT / WIN_GET (10h / 11h): physical address (4), size (2; 0 = 16384)
op_wput: ld hl,MSGB+2
        ld de,SCR_D
        ld a,80h
        ld (SCR_S+2),a
        xor a
        ld (SCR_S),a
        ld (SCR_S+1),a
        ld (SCR_S+3),a
        jr wcommon
op_wget: ld hl,MSGB+2
        ld de,SCR_S
        ld a,80h
        ld (SCR_D+2),a
        xor a
        ld (SCR_D),a
        ld (SCR_D+1),a
        ld (SCR_D+3),a
wcommon: ld a,(V_LEN+1)
        or a
        jp nz,err_par
        ld a,(V_LEN)
        cp 08h
        jp nz,err_par
        push hl
        push de
        call chka
        pop de
        pop hl
        jp nz,err_par
        ld a,(MSGB+2)
        and 07h
        jp nz,err_al
        ldi
        ldi
        ldi
        ldi
        ld hl,(MSGB+6)
        ld a,h
        or l
        jr nz,wp1
        ld hl,4000h
wp1:    ld a,h
        cp 40h
        jr c,wp2
        jp nz,err_par
        ld a,l
        or a
        jp nz,err_par
wp2:    ld (V_SIZE),hl
        call ceil8
        call dmarun
        jp nz,err_dma
        ld hl,MSGB+2
        ld de,V_ADDR
        ldi
        ldi
        ldi
        ldi
        ld hl,(V_SIZE)
        ld (V_REM),hl
        xor a
        ld (V_REM+2),a
        ld (V_REM+3),a
        call crcrng
        jp nz,err_dma
        jp sendcrc
; ---------------------------------------------------------------- CRC (30h): address (4, 8-aligned), size (4)
op_crc: ld a,(V_LEN+1)
        or a
        jp nz,err_par
        ld a,(V_LEN)
        cp 0Ah
        jp nz,err_par
        ld hl,MSGB+2
        call chka
        jp nz,err_par
        ld a,(MSGB+2)
        and 07h
        jp nz,err_al
        ld hl,MSGB+2
        ld de,V_ADDR
        ldi
        ldi
        ldi
        ldi
        ld hl,MSGB+6
        ld de,V_REM
        ldi
        ldi
        ldi
        ldi
        call crcrng
        jp nz,err_dma
        jp sendcrc
; ---------------------------------------------------------------- POKE (12h) / PEEK (13h)
stage:  ld a,(MSGB+2)         ; reads into STG the aligned region that covers [address, address + V_SIZE). Z = ok
        and 07h
        ld (V_OFF),a
        ld c,a
        ld hl,(V_SIZE)
        ld a,l
        add a,c
        ld l,a
        ld a,h
        adc a,0
        ld h,a
        call ceil8
        ld (V_W),hl
        ld hl,MSGB+2
        ld de,V_ADDR
        ldi
        ldi
        ldi
        ldi
        ld a,(V_ADDR)
        and 0F8h
        ld (V_ADDR),a
        ld hl,V_ADDR
        ld de,SCR_S
        ldi
        ldi
        ldi
        ldi
        xor a
        ld (SCR_D),a
        ld (SCR_D+2),a
        ld (SCR_D+3),a
        ld a,30h
        ld (SCR_D+1),a
        ld hl,(V_W)
        call dmarun
        ret
op_poke: ld a,(V_LEN)
        sub 06h
        ld l,a
        ld a,(V_LEN+1)
        sbc a,0
        ld h,a
        jp c,err_par
        or l
        jp z,err_par
        ld a,h
        cp 08h
        jp nc,err_par
        ld (V_SIZE),hl
        ld hl,MSGB+2
        call chka
        jp nz,err_par
        call stage
        jp nz,err_dma
        ld a,(V_OFF)
        ld e,a
        ld d,30h
        ld hl,(V_SIZE)
        ld b,h
        ld c,l
        ld hl,MSGB+6
        ldir
        ld hl,V_ADDR
        ld de,SCR_D
        ldi
        ldi
        ldi
        ldi
        xor a
        ld (SCR_S),a
        ld (SCR_S+2),a
        ld (SCR_S+3),a
        ld a,30h
        ld (SCR_S+1),a
        ld hl,(V_W)
        call dmarun
        jp nz,err_dma
        xor a
        jp reply_st
op_peek: ld a,(V_LEN+1)
        or a
        jp nz,err_par
        ld a,(V_LEN)
        cp 08h
        jp nz,err_par
        ld hl,(MSGB+6)
        ld a,h
        or l
        jp z,err_par
        ld a,h
        cp 08h
        jp nc,err_par
        ld (V_SIZE),hl
        ld hl,MSGB+2
        call chka
        jp nz,err_par
        call stage
        jp nz,err_dma
        xor a
        call rsph
        ld hl,(V_SIZE)
        ld b,h
        ld c,l
        ld a,(V_OFF)
        ld l,a
        ld h,30h
pe_l:   ld a,(hl)
        out (FDATA),a
        inc hl
        dec bc
        ld a,b
        or c
        jr nz,pe_l
        ld hl,(V_SIZE)
        inc hl
        inc hl
        inc hl
        ld b,h
        ld c,l
        jp fin
; ---------------------------------------------------------------- EXEC (20h): entry (8), mode (1), argument (8)
op_exec: ld a,(V_LEN+1)
        or a
        jp nz,err_par
        ld a,(V_LEN)
        cp 13h
        jp nz,err_par
        ld a,(MSGB+10)
        cp 05h
        jp nc,err_par         ; modes 00h..04h
        ld hl,MSGB+4
        ld b,6
        xor a
ex1:    or (hl)
        inc hl
        djnz ex1
        jp nz,err_par         ; v1: entry < 10000h
        ld hl,(MSGB+2)
        ld (V_TMP),hl
        xor a
        call rsph
        ld bc,3
        call finr
        ld a,(MSGB+10)
        call setmode
        ld hl,ret_a
        push hl
        ld hl,(V_TMP)
        push hl
        ld a,(MSGB+10)
        cp 04h
        jr z,ex64
        ld hl,(MSGB+11)       ; argument (16 bits)
        ret                   ; "calls" the entry; the program returns at ret_a
ex64:   ld de,MSGB+11
        db 0EDh,39h,22h       ; LDQ HL,(DE): 64-bit argument
        ret
ret_a:  ld de,V_EXIT
        db 0EDh,39h,0D4h      ; LDQ (DE),HL: exit code (HL)
        ld a,04h
        call setmode
ew:     in a,(FFLG)
        and 04h
        jr nz,ew              ; waits for the MSX to read the previous response (DONE = 0)
        ld a,0F0h
        out (FDATA),a
        xor a
        out (FDATA),a
        ld a,01h
        out (FDATA),a         ; EVT 01: program finished
        ld a,(V_EXIT)
        out (FDATA),a
        ld a,(V_EXIT+1)
        out (FDATA),a
        ld a,(V_EXIT+2)
        out (FDATA),a
        ld a,(V_EXIT+3)
        out (FDATA),a
        ld bc,7
        jp fin
setmode: cp 04h               ; A = mode (00h Z80 ROM, 01h Z80 DRAM, 02h R800 ROM, 03h R800 DRAM, 04h native) -> S1990 reg 6 e NATIVE64
        jr z,sm_n
        or a
        ld c,60h
        jr z,sm_w
        cp 01h
        ld c,20h
        jr z,sm_w
        cp 02h
        ld c,40h
        jr z,sm_w
        ld c,00h
sm_w:   ld a,06h
        out (0E4h),a
        ld a,c
        out (0E5h),a
        ld a,0A5h
        out (3Dh),a
        xor a
        out (3Eh),a
        ret
sm_n:   ld a,0A5h
        out (3Dh),a
        ld a,01h
        out (3Eh),a
        ret
codeend:
        org TLO
;@CRCTAB@
