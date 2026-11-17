; Copy the animated sprite bytes to VIC RAM with one page-3 mapping.
; The final $7FFF byte needs the page-2 VIC writer: Z80 $FFFF is the
; subslot register. Preserve the incoming 6502 carry across dirty writes.
	push af
	ld hl,($BDC7)
	add hl,de
	ld a,(hl)
	ld hl,$7FFF
	call k_vwr
	dec e
	dec c
	call k_vic_on
NBDC6_loop:
	ld hl,($BDC7)
	add hl,de
	ld a,(hl)
	; Remaining bytes are $7FC0..$7FFE: one fixed dirty chunk.
	; Page 3 is mapped to VIC RAM; $FFFF was handled above.
	ld h,$FF
	ld l,c
	set 7,l
	set 6,l
	cp (hl)
	jr z,NBDC6_same
	ld (hl),a
	push af
	ld a,c
	rrca
	rrca
	rrca
	and 7
	ld l,a
	ld h,bittab/256
	ld a,(hl)
	ld hl,VDIRTY+$FF
	or (hl)
	ld (hl),a
	pop af
NBDC6_same:
	dec e
	dec c
	jp p,NBDC6_loop
	call k_c2
	pop hl
	ld h,a
	ld a,l
	rra
	ld a,h
	inc c
	dec c
	jp T_BDD0
