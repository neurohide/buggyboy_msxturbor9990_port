; ASCII16 MegaROM bank 0: copies the memory images from ROM banks into
; memory mapper segments, then takes over the whole machine.

RSLREG:          equ $0138
ENASLT:          equ $0024
CHGCPU:          equ $0180           ; turbo R only
CHPUT:           equ $00A2
MSXVER:          equ $002D           ; 0 MSX1, 1 MSX2, 2 MSX2+, 3 turbo R
EXPTBL:          equ $FCC1
SLTTBL:          equ $FCC5
ASCII16_P2:      equ $7000           ; bank select for $8000-$BFFF
LD_VARS:         equ $E000           ; loader scratch in system RAM (page 3)
ld_romslot:      equ LD_VARS+0
ld_ramprim:      equ LD_VARS+1       ; primary slot of RAM
ld_ramsub:       equ LD_VARS+2       ; secondary slot of RAM ($FF = not expanded)
ld_best:         equ LD_VARS+3       ; segments of the biggest mapper found
ld_bestslot:     equ LD_VARS+4       ; its slot (ENASLT format)
ld_save:         equ LD_VARS+8       ; 32: bytes the mapper test overwrites
SEGS_NEEDED:     equ 14              ; SEG_SHADOW + 1
TRAMPOLINE:      equ $2700           ; free hole in SEG_C0

	org $4000
loader_start:
	db "AB"
	dw ld_init
	dw 0, 0, 0
	defs 6,0

ld_init:
	; turbo R: R800 ROM mode (keeps all mapper RAM for us)
	ld a,(MSXVER)
	cp 3
	jr c,ld_z80
	ld a,$81
	call CHGCPU
ld_z80:
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
	call ld_find_ram
	; our ROM in page 2 as well
	ld a,(ld_romslot)
	ld h,$80
	call ENASLT
	di
	; RAM in page 0
	ld a,(ld_ramprim)
	ld d,a
	ld a,(ld_ramsub)
	ld e,a
	call ld_page0
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

; the biggest memory mapper of all slots -> ld_ramprim, ld_ramsub
; (an MSX2+ usually has 64K inside: the game needs an external one)
ld_find_ram:
	xor a
	ld (ld_best),a
	ld c,0                      ; primary slot
lfr_prim:
	ld hl,EXPTBL
	ld a,l
	add a,c
	ld l,a
	ld a,(hl)
	and $80
	or c
	ld b,a                      ; slot id, sub-slot 0
lfr_sub:
	push bc
	ld a,b
	call ld_try
	pop bc
	ld hl,ld_best
	cp (hl)
	jr c,lfr_nb
	jr z,lfr_nb
	ld (hl),a
	ld a,b
	ld (ld_bestslot),a
lfr_nb:
	bit 7,b
	jr z,lfr_np                 ; not expanded
	ld a,b
	add a,4                     ; next sub-slot
	ld b,a
	and $0C
	jr nz,lfr_sub
lfr_np:
	inc c
	ld a,c
	cp 4
	jr nz,lfr_prim
	ld a,(ld_best)
	cp SEGS_NEEDED
	jr c,ld_noram
	ld a,(ld_bestslot)
	ld b,a
	and 3
	ld (ld_ramprim),a
	ld a,$FF
	bit 7,b
	jr z,lfr_ns
	ld a,b
	rrca
	rrca
	and 3
lfr_ns:
	ld (ld_ramsub),a
	ret
ld_noram:
	ld hl,ld_msg
lnr_l:
	ld a,(hl)
	or a
	jr z,lnr_h
	push hl
	call CHPUT
	pop hl
	inc hl
	jr lnr_l
lnr_h:
	di
	halt
ld_msg:
	db "Buggy Boy needs a 256K memory mapper.",13,10,0

; slot A in page 2 -> A = number of mapper segments there (0..32).  The first
; byte of each segment is saved and restored: this may be the system's RAM.
ld_try:
	ld h,$80
	call ENASLT
	di
	ld hl,ld_save+31
	ld c,31
lt_save:
	ld a,c
	out (PORT_P2),a
	ld a,($8000)
	ld (hl),a
	dec hl
	dec c
	jp p,lt_save
	ld c,31
lt_mark:
	ld a,c
	out (PORT_P2),a
	ld ($8000),a
	dec c
	jp p,lt_mark
	ld c,0                      ; segments n < size read back n
lt_count:
	ld a,c
	out (PORT_P2),a
	ld a,($8000)
	cp c
	jr nz,lt_counted
	inc c
	ld a,c
	cp 32
	jr nz,lt_count
lt_counted:
	ld b,c
	ld hl,ld_save+31            ; restore downwards: the last write to each
	ld c,31                     ; segment comes from its own number
lt_rest:
	ld a,c
	out (PORT_P2),a
	ld a,(hl)
	ld ($8000),a
	dec hl
	dec c
	jp p,lt_rest
	ld a,1
	out (PORT_P2),a
	ld a,b
	ret

; RAM slot D (primary), E (sub-slot, $FF none) in page 0.  The sub-slot
; register is reached by putting page 3 in that primary slot for a moment
; (no stack use meanwhile).  Interrupts are off.
ld_page0:
	in a,($A8)
	ld b,a
	ld a,e
	cp $FF
	jr z,lp0_prim
	ld a,d
	rrca
	rrca
	ld c,a                      ; primary slot in bits 7-6
	ld a,b
	and $3F
	or c
	out ($A8),a
	ld a,($FFFF)
	cpl
	and $FC
	or e
	ld ($FFFF),a
lp0_prim:
	ld a,b
	and $FC
	or d
	out ($A8),a
	ret

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
