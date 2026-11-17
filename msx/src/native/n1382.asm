; Native $1382-$13FC: rotate three 40-character parallax rows on the race IRQ.
; The source overlaps the destination; copy backwards when shifting right and
; forwards when shifting left.  The original duplicates the newly shifted end
; character at the opposite end.  Leave X as $FF/$00 after a shift.
	ld a,($0070)
	ld l,a
	or a
	jp m,N1382_left
	ld a,($006F)
	add a,l
	ld ($006F),a
	cp $18
	jp c,T_13FD
	sub 8
	ld ($006F),a
	call k_vic_on
	push bc                     ; preserve translated Y across LDDR
	ld hl,$C62E
	ld de,$C62F
	ld bc,39
	lddr
	ld a,($C62F)
	ld ($C608),a
	ld hl,$C656
	ld de,$C657
	ld bc,39
	lddr
	ld a,($C657)
	ld ($C630),a
	ld hl,$C67E
	ld de,$C67F
	ld bc,39
	lddr
	ld a,($C67F)
	ld ($C658),a
	pop bc
	ld d,0
	ld e,$FF
	jr N1382_dirty
N1382_left:
	ld a,($006F)
	add a,l
	ld ($006F),a
	cp $10
	jp nc,T_13FD
	add a,8
	ld ($006F),a
	call k_vic_on
	push bc                     ; preserve translated Y across LDIR
	ld hl,$C609
	ld de,$C608
	ld bc,39
	ldir
	ld a,($C608)
	ld ($C62F),a
	ld hl,$C631
	ld de,$C630
	ld bc,39
	ldir
	ld a,($C630)
	ld ($C657),a
	ld hl,$C659
	ld de,$C658
	ld bc,39
	ldir
	ld a,($C658)
	ld ($C67F),a
	pop bc
	ld d,0
	ld e,0
N1382_dirty:
	; $4608-$467F covers bits 1-7 of dirty byte $18 and all of $19.
	ld hl,VDIRTY+$18
	ld a,(hl)
	or $FE
	ld (hl),a
	inc hl
	ld (hl),$FF
	call k_c2
	jp T_13FD
