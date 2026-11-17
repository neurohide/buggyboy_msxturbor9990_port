; Native race raster handler $134C; IRQ context, C64 blocks 2/3 mapped.
; @call targets are resolved against the translator segment placement.
	push af
	push de
	push bc
	ld hl,$033A
	ld e,(hl)
	ld hl,$F00F
	add hl,de
	ld a,(hl)
	call iowf_D021
	ld a,$0B
	call iowf_D022
	ld a,$0C
	call iowf_D023
	ld a,$13
	call iowf_D011
	ld a,($004B)
	or a
	jp z,T_137F
	ld a,($02BC)
	or a
	jp nz,T_137F
	ld a,($02B9)
	or a
	jp nz,T_137F
	ld a,($24FC)
	or a
	jp z,T_1382
T_137F:
	jp T_13FD
T_1382:
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
	push bc                     ; preserve translated Y
	ld de,VDIRTY+$18
	ld c,2
	ld hl,$C608
	call NIRQ_track_right
	ld hl,$C630
	call NIRQ_track_right
	ld hl,$C658
	call NIRQ_track_right

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
	push bc                     ; preserve translated Y
	ld de,VDIRTY+$18
	ld c,2
	ld hl,$C608
	call NIRQ_track_left
	ld hl,$C630
	call NIRQ_track_left
	ld hl,$C658
	call NIRQ_track_left

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
	call k_c2
	jp T_13FD
T_13FD:
	ld a,($006F)
	call k_c2
	call iowf_D016
	ld a,$14
	ld (vec_ffff),a
	ld a,$1A
	ld ($FFFE),a
	ld a,($02DF)
	call iowf_D012
	ld a,$01
	call iowf_D019
	jp NIRQ_return

; A shifted eight-character group changes iff its nine participating old
; characters are not all equal. Skip groups already dirty, then move each
; row with LDIR/LDDR. The wrap byte follows the translated order (old 38
; at the right edge, old 1 at the left edge).
NIRQ_track_right:
	ld a,(de)
	and c
	jr nz,NIRQ_track_rfirst
	push hl
	ld a,l
	add a,38
	ld l,a
	ld a,(hl)
	pop hl
	call NIRQ_compare_group
NIRQ_track_rfirst:
	call NIRQ_dirty_next
	ld b,4
NIRQ_track_rloop:
	ld a,(de)
	and c
	jr nz,NIRQ_track_rnext
	dec l
	ld a,(hl)
	inc l
	call NIRQ_compare_group
NIRQ_track_rnext:
	ld a,l
	add a,8
	ld l,a
	rlc c
	jr nc,NIRQ_track_rkeep
	inc e
NIRQ_track_rkeep:
	djnz NIRQ_track_rloop
	ret
NIRQ_track_left:
	inc l
	ld a,(hl)
	ex af,af'                   ; wrap source survives the four linear groups
	dec l
	ld b,4
NIRQ_track_lloop:
	ld a,(de)
	and c
	jr nz,NIRQ_track_lnext
	ld a,(hl)
	inc l
	call NIRQ_compare_group
	dec l
NIRQ_track_lnext:
	ld a,l
	add a,8
	ld l,a
	rlc c
	jr nc,NIRQ_track_lkeep
	inc e
NIRQ_track_lkeep:
	djnz NIRQ_track_lloop
	ld a,(de)
	and c
	jr nz,NIRQ_dirty_next
	ex af,af'
	call NIRQ_compare_group
	jp NIRQ_dirty_next
NIRQ_compare_group:
	push hl
	call NIRQ_uniform8
	pop hl
	ret z
	ld a,(de)
	or c
	ld (de),a
	ret
NIRQ_dirty_next:
	ld a,l
	add a,8
	ld l,a
	rlc c
	ret nc
	inc e
	ret
NIRQ_uniform8:
	cp (hl)
	ret nz
	inc l
	cp (hl)
	ret nz
	inc l
	cp (hl)
	ret nz
	inc l
	cp (hl)
	ret nz
	inc l
	cp (hl)
	ret nz
	inc l
	cp (hl)
	ret nz
	inc l
	cp (hl)
	ret nz
	inc l
	cp (hl)
	ret
