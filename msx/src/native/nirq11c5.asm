; Native race raster handler $11C5; IRQ context, C64 blocks 2/3 mapped.
; @call targets are resolved against the translator segment placement.
	push af
	push de
	push bc
	ld a,($02B8)
	call iowf_D021
	ld a,$00
	call iowf_D022
	ld a,$01
	call iowf_D023
	ld a,$1B
	call iowf_D011
	ld a,$1A
	ld hl,VIC_REGS+$18
	call NIRQ_set
	ld hl,$D01E
	call k_iord
	ld a,l
	ld ($14C1),a
	ld a,$00
	ld ($028D),a
	ld (cia1_pra),a
	ld a,($EFA6)
	or a
	jp nz,T_122E
	ld hl,$DC01
	call k_iord
	ld a,l
	ld ($1269),a
	ld a,($0354)
	or a
	jp z,T_1237
	cp $01
	jp nz,T_1216
	ld a,($1269)
	cp $FF
	jp nz,T_1261
	ld hl,$0354
	inc (hl)
	jp T_1261
T_1216:
	cp $02
	jp nz,T_1231
	ld a,($1269)
	cp $7F
	jp nz,T_1261
	ld a,($126A)
	ld ($004B),a
	ld a,$E0
	ld ($0354),a
	@call C80C
T_122E:
	jp T_126B
T_1231:
	ld hl,$0354
	inc (hl)
	jp T_126B
T_1237:
	ld a,($1269)
	cp $FD
	jp nz,T_124E
	ld a,$00
	ld ($9C4E),a
	ld ($0337),a
	ld a,$7F
	ld (cia1_pra),a
	jp T_12A2
T_124E:
	cp $7F
	jp nz,T_126B
	ld hl,$0354
	inc (hl)
	@call C800
	ld a,($004B)
	ld ($126A),a
	ld a,$00
	ld ($004B),a
T_1261:
	ld a,$7F
	ld (cia1_pra),a
	jp T_12A2
T_126B:
	ld a,$7F
	ld (cia1_pra),a
	@call 1577
	ld a,($02E8)
	or a
	jp z,T_127B
	ld hl,$02E8
	dec (hl)
T_127B:
	@call B62E
	@call 9BF7
	@call 9A2A
	@call 1BBF
	@call 9A95
	@call 9B60
	@call 251F
	@call B781
	@call C812
	@call C809
	@call C80F
	@call EF21
	@call 0720
T_12A2:
	ld a,($CFEC)
	or a
	jp nz,T_12AC
	ld a,($02E9)
	or a
	jp z,T_1300
T_12AC:
	call k_vic_on
	ld hl,$132F
	ld de,VIC_REGS
	ld c,0
	call NIRQ_xy6
	ld e,1
	call NIRQ_xy6
	push bc
	ld de,$C7F8
	ld b,6
	ld c,0
NIRQ_ptr6:
	ld a,(de)
	cp (hl)
	jr z,NIRQ_ptr_same
	ld a,(hl)
	ld (de),a
	ld c,$80
NIRQ_ptr_same:
	inc l
	inc e
	djnz NIRQ_ptr6
	ld a,(VDIRTY+$1F)
	or c
	ld (VDIRTY+$1F),a
	pop bc
	ld de,VIC_REGS+$27
	ld b,6
NIRQ_col6:
	ld a,(de)
	cp (hl)
	jr z,NIRQ_col_same
	ld a,(hl)
	ld (de),a
	ld c,1
NIRQ_col_same:
	inc l
	inc e
	djnz NIRQ_col6
	ld a,c
	or a
	jr z,NIRQ_upper_same
	ld a,1
	ld (vic_changed),a
NIRQ_upper_same:
	call k_c2
	ld a,($148C)
	ld hl,VIC_REGS+$0C
	call NIRQ_set
	ld a,($1494)
	ld hl,VIC_REGS+$0D
	call NIRQ_set
	ld a,($148D)
	ld hl,VIC_REGS+$0E
	call NIRQ_set
	ld a,($1495)
	ld hl,VIC_REGS+$0F
	call NIRQ_set
	ld a,($02E0)
	ld hl,VIC_REGS+$1D
	call NIRQ_set
	ld a,($02E1)
	ld hl,VIC_REGS+$17
	call NIRQ_set
	ld a,($02E2)
	ld hl,VIC_REGS+$10
	call NIRQ_set
	ld a,($02E6)
	ld hl,VIC_REGS+$15
	call NIRQ_set
	ld de,$00FF                 ; translated upper-zone loop exits X=$FF, Y=$FE
	ld bc,$00FE                 ; later game/audio calls require B=D=0
	jp T_1303
T_1300:
	@call 1452
T_1303:
	ld a,$13
	call k_c2
	ld (vec_ffff),a
	ld a,$4C
	ld ($FFFE),a
	ld a,$7B
	call iowf_D012
	ld a,$01
	call iowf_D019
	ld a,($9C4E)
	or a
	jp nz,T_132C
	ld a,$00
	ld ($9A93),a
	ld a,($0337)
	or a
	jp nz,T_132C
	@call C800
	@escape BF7E
T_132C:
	jp NIRQ_return

; Two linear source streams, six hardware sprite X/Y pairs. C collects changes.
NIRQ_xy6:
	ld b,6
NIRQ_xy_loop:
	ld a,(de)
	cp (hl)
	jr z,NIRQ_xy_same
	ld a,(hl)
	ld (de),a
	ld c,1
NIRQ_xy_same:
	inc l
	inc e
	inc e
	djnz NIRQ_xy_loop
	ret
