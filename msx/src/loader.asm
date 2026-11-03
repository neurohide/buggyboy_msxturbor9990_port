; ASCII16 MegaROM bank 0: copies the memory images from ROM banks into
; memory mapper segments, then takes over the whole machine.

RSLREG:          equ $0138
ENASLT:          equ $0024
CHGCPU:          equ $0180
EXPTBL:          equ $FCC1
SLTTBL:          equ $FCC5
ASCII16_P1:      equ $6000           ; bank select for $4000-$7FFF
ASCII16_P2:      equ $7000           ; bank select for $8000-$BFFF
INTRO_BANK:      equ 15              ; ../intro/intro.rom, placed by tools/build.py
INTRO_ENTRY:     equ $4010           ; returns after a key press
INTRO_STUB:      equ $C100           ; RAM the intro leaves alone
LD_VARS:         equ $E000           ; loader scratch in system RAM (page 3)
ld_romslot:      equ LD_VARS+0
ld_ramprim:      equ LD_VARS+1       ; primary slot of RAM
ld_ramsub:       equ LD_VARS+2       ; secondary slot of RAM ($FF = not expanded)
TRAMPOLINE:      equ $2700           ; free hole in SEG_C0

	org $4000
loader_start:
	db "AB"
	dw ld_init
	dw 0, 0, 0
	defs 6,0

ld_init:
	; R800 ROM mode (keeps all mapper RAM for us)
	ld a,$81
	call CHGCPU
	; slot of this cartridge (page 1)
	call RSLREG
	rrca
	rrca
	and 3
	ld c,a
	ld b,0
	ld hl,EXPTBL
	add hl,bc
	ld a,(hl)
	and $80
	or c
	ld c,a
	inc hl
	inc hl
	inc hl
	inc hl
	ld a,(hl)
	and $0C
	or c
	ld (ld_romslot),a
	; slot of RAM: whatever is in page 3 now
	call RSLREG
	rlca
	rlca
	and 3
	ld (ld_ramprim),a
	ld c,a
	ld b,0
	ld hl,EXPTBL
	add hl,bc
	ld a,(hl)
	and $80
	ld a,$FF
	jr z,ld_noexp
	ld a,($FFFF)
	cpl
	rlca
	rlca
	and 3
ld_noexp:
	ld (ld_ramsub),a
	; our ROM in page 2 as well
	ld a,(ld_romslot)
	ld h,$80
	call ENASLT
	di
	; RAM in page 0 (primary slot bits 1-0, secondary register bits 1-0)
	in a,($A8)
	and $FC
	ld b,a
	ld a,(ld_ramprim)
	or b
	out ($A8),a
	ld a,(ld_ramsub)
	cp $FF
	jr z,ld_p0done
	ld b,a
	ld a,($FFFF)
	cpl
	and $FC
	or b
	ld ($FFFF),a
ld_p0done:
	; copy every image
	ld hl,ld_table
ld_copy:
	ld a,(hl)
	or a
	jr z,ld_copied
	ld (ASCII16_P2),a
	inc hl
	ld a,(hl)
	inc hl
	out (PORT_P0),a
	push hl
	ld hl,$8000
	ld de,$0000
	ld bc,$4000
	ldir
	pop hl
	jr ld_copy
ld_copied:
	; page 0 = C64 block 0; install the hand-over code in a free hole
	ld a,SEG_C0
	out (PORT_P0),a
	ld hl,ld_tramp
	ld de,TRAMPOLINE
	ld bc,ld_tramp_end-ld_tramp
	ldir
	ld a,(ld_ramprim)
	ld b,a
	add a,a
	add a,a
	or b
	ld b,a
	add a,a
	add a,a
	add a,a
	add a,a
	or b
	ld (TRAMPOLINE+ld_t_prim-ld_tramp+1),a
	ld a,(ld_ramsub)
	ld (TRAMPOLINE+ld_t_sub-ld_tramp+1),a
	jp TRAMPOLINE

; copied to TRAMPOLINE and run from there (page 0 RAM)
ld_tramp:
	ld sp,STACK_TOP
ld_t_prim:
	ld a,0                      ; patched: RAM primary slot in all pages
	out ($A8),a
ld_t_sub:
	ld a,0                      ; patched: RAM secondary slot ($FF: none)
	cp $FF
	jr z,ld_t_nosub
	ld b,a
	add a,a
	add a,a
	or b
	ld b,a
	add a,a
	add a,a
	add a,a
	add a,a
	or b
	ld ($FFFF),a
ld_t_nosub:
	ld a,SEG_C2
	out (PORT_P2),a
	ld a,SEG_C3
	out (PORT_P3),a
	ld a,SEG_CODE
	out (PORT_P1),a
	jp k_init
ld_tramp_end:

; ROM bank, mapper segment
ld_table:
	db 1, SEG_C0
	db 2, SEG_VIC
	db 3, SEG_C2
	db 4, SEG_C3
	db 5, SEG_RENDER
	db 6, SEG_CODE+0
	db 7, SEG_CODE+1
	db 8, SEG_CODE+2
	db 9, SEG_CODE+3
	db 10, SEG_SHADOW
	db 0

loader_end:
	defs $8000-loader_end,$FF
