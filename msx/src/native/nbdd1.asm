; Same copy from the second animation plane; its high source byte is patched
; by the C64 game at $BDD3, so reload the operand from C64 RAM each byte.
	push af
	ld hl,($BDD2)
	add hl,de
	ld a,(hl)
	ld hl,$7FFF
	call k_vwr
	dec e
	dec c
	call k_vic_on
NBDD1_loop:
	ld hl,($BDD2)
	add hl,de
	ld a,(hl)
	; Remaining bytes are $7FC0..$7FFE: one fixed dirty chunk.
	; Page 3 is mapped to VIC RAM; $FFFF was handled above.
	ld h,$FF
	ld l,c
	set 7,l
	set 6,l
	cp (hl)
	jr z,NBDD1_same
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
NBDD1_same:
	dec e
	dec c
	jp p,NBDD1_loop
	call k_c2
	pop hl
	ld h,a
	ld a,l
	rra
	ld a,h
	inc c
	dec c
	jp T_BDDB
