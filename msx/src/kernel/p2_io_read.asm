; C64 memory-mapped I/O reads, raster clock reads, and random numbers.
; Routines: k_iord, get_raster, k_random.

; I/O reads: HL = $D000-$DFFF -> L.  Preserves A, F, BC, DE.
; ============================================================================
k_iord:
	push af
	ld a,h
	cp $D4
	jr c,iord_vic
	cp $D8
	jr c,iord_sid
	cp $DC
	jr c,iord_col
	jr z,iord_cia1
	cp $DD
	jr z,iord_cia2
	ld l,$FF
	pop af
	ret
iord_col:
	and 3
	add a,COLOR_RAM/256
	ld h,a
	ld a,(hl)
	or $F0
	ld l,a
	pop af
	ret
iord_sid:
	ld a,l
	and $1F
	cp $1B
	jr c,iord_sid_0
	call k_random
	ld l,a
	pop af
	ret
iord_sid_0:
	ld l,0
	pop af
	ret
iord_cia2:
	ld a,l
	and $0F
	ld l,$FF
	jr nz,iord_cia2_x
	ld a,(cia2_pra)
	ld l,a
iord_cia2_x:
	pop af
	ret
iord_cia1:
	ld a,l
	and $0F
	jr z,iord_pra
	dec a
	jr z,iord_prb
	ld l,0
	pop af
	ret
iord_pra:
	; port A pins = joystick 2 AND the keyboard column bits the game drives
	ld a,(cia1_pra)
	ld l,a
	ld a,(joy_state)
	and l
	ld l,a
	pop af
	ret
iord_prb:
	; AND the rows of every selected (low) column
	push bc
	ld a,(cia1_pra)
	ld c,a
	ld hl,key_rows
	ld a,$FF
	ld b,8
iprb_l:
	rr c
	jr c,iprb_n
	and (hl)
iprb_n:
	inc hl
	djnz iprb_l
	ld l,a
	pop bc
	pop af
	ret
iord_vic:
	ld a,l
	and $3F
	cp $11
	jr z,iord_d011
	cp $12
	jr z,iord_d012
	cp $19
	jr z,iord_d019
	cp $1A
	jr z,iord_d01a
	cp $1E
	jr z,iord_d01e
	cp $1F
	jr z,iord_d01f
	cp $2F
	jr nc,iord_ff
	ld l,a
	ld h,VIC_REGS/256
	ld a,(hl)
	ld l,a
	pop af
	ret
iord_ff:
	ld l,$FF
	pop af
	ret
iord_d011:
	call mt_poll
	call get_raster
	ld a,h
	rrca
	and $80
	ld l,a
	ld a,(VIC_REGS+$11)
	and $7F
	or l
	ld l,a
	pop af
	ret
iord_d012:
	call mt_poll
	call get_raster
	pop af
	ret
iord_d019:
	ld a,(vic_irr)
	ld l,a
	ld a,(vic_imr)
	and l
	jr z,i19
	ld a,$80
i19:
	or l
	or $70
	ld l,a
	pop af
	ret
iord_d01a:
	ld a,(vic_imr)
	or $F0
	ld l,a
	pop af
	ret
iord_d01e:
	ld hl,coll_ss
	ld a,(hl)
	ld (hl),0
	ld l,a
	pop af
	ret
iord_d01f:
	ld hl,coll_sb
	ld a,(hl)
	ld (hl),0
	ld l,a
	pop af
	ret

; current C64 raster line -> HL (0..311).  Clobbers A.
get_raster:
	push de
	in a,(TIMER_HI)
	ld h,a
	in a,(TIMER_LO)
	ld l,a
	in a,(TIMER_HI)
	cp h
	jr z,gr_ok
	ld h,a
	in a,(TIMER_LO)
	ld l,a
gr_ok:
	; lines = t/16 - t/1024 (3.911us ticks, 63.7us lines)
	ld a,h
	rrca
	rrca
	and $3F
	ld e,a
	ld d,0
	srl h
	rr l
	srl h
	rr l
	srl h
	rr l
	srl h
	rr l
	or a
	sbc hl,de
	ld de,(raster_base)
	add hl,de
	ld de,312
gr_wrap:
	or a
	sbc hl,de
	jr nc,gr_wrap
	add hl,de
	pop de
	ret

; 16-bit Galois LFSR -> A
k_random:
	push hl
	ld hl,(rnd_state)
	srl h
	rr l
	jr nc,kr_n
	ld a,h
	xor $B4
	ld h,a
kr_n:
	ld (rnd_state),hl
	ld a,l
	pop hl
	ret

; ============================================================================
