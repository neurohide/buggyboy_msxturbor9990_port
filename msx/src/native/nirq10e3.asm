; Native race raster handler $10E3; IRQ context, C64 blocks 2/3 mapped.
; @call targets are resolved against the translator segment placement.
	push af
	push de
	push bc
	ld hl,$0049
	ld e,(hl)
	ld a,($004A)
	ld hl,$14A6
	add hl,de
	cp (hl)
	jp z,T_10F7
T_10F4:
	jp NIRQ_return
T_10F7:
	ld a,$3B
	call iowf_D011
	ld a,$10
	call iowf_D016
	ld hl,$14B3
	add hl,de
	ld a,(hl)
	call iowf_D021
	inc e
	ld a,e
	cp $0D
	jp z,T_110F
	jp T_11B3
T_110F:
	ld a,$00
	call iowf_D012
	ld ($0049),a
	ld a,($CFEE)
	or a
	jp z,T_1121
	ld hl,$CFEE
	dec (hl)
	ld hl,$CFEC
	inc (hl)
T_1121:
	ld a,$11
	ld (vec_ffff),a
	ld a,$C5
	ld ($FFFE),a
	ld a,$01
	call iowf_D019
	ld a,($0354)
	or a
	jp z,T_1139
	cp $03
	jp c,T_10F4
T_1139:
	@call B4A2
	ld a,($14C2)
	ld hl,$004B
	sub (hl)
	ld ($14C2),a
	jp nc,T_10F4
	ld a,($14C2)
	add a,$20
	ld ($14C2),a
	ld hl,$006B
	inc (hl)
	jp nz,T_1156
	ld hl,$006A
	inc (hl)
T_1156:
	ld hl,$02E8
	inc (hl)
	ld hl,$14C3
	inc (hl)
	ld hl,$033A
	ld e,(hl)
	ld a,($14C3)
	ld hl,$1347
	add hl,de
	cp (hl)
	jp nz,T_116F
	ld a,$00
	ld ($14C3),a
	ld hl,$9D2F
	inc (hl)
T_116F:
	ld a,($0047)
	add a,$0D
	ld ($0047),a
	cp $41
	jp nz,T_11A1
	ld a,$00
	ld ($0047),a
	ld hl,($1094)
	ld a,l
	ld ($1095),a
	ld a,h
	ld ($1094),a
	ld c,l
	ld hl,$14B3
	ld b,7
NIRQ_bands:
	ld (hl),a
	inc l
	ld (hl),c
	inc l
	djnz NIRQ_bands
	ld hl,$9BF5
	inc (hl)
	ld a,($0047)
T_11A1:
	ld e,a
	ld hl,$ECC9
	add hl,de
	ld de,$14A6
	ld bc,13
	ldir
	jp T_11B0
T_11B0:
	jp NIRQ_return
T_11B3:
	ld hl,$0049
	ld (hl),e
	ld hl,$14A6
	add hl,de
	ld a,(hl)
	call iowf_D012
	ld ($004A),a
	ld a,$01
	call iowf_D019
	jp NIRQ_return
