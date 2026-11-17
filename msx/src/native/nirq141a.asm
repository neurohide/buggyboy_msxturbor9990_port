; Native race raster handler $141A; IRQ context, C64 blocks 2/3 mapped.
; @call targets are resolved against the translator segment placement.
	push af
	push de
	push bc
	ld a,($CFEC)
	or a
	jp nz,T_142C
	ld a,($02E9)
	or a
	jp z,T_142F
T_142C:
	@call 1452
T_142F:
	ld a,$10
	ld (vec_ffff),a
	ld a,$E3
	ld ($FFFE),a
	ld a,($14A6)
	call iowf_D012
	ld ($004A),a
	ld a,$01
	call iowf_D019
	ld a,($02E7)
	ld hl,VIC_REGS+$15
	call NIRQ_set
	jp NIRQ_return

; Only display state consumed by snapshots; preserve translated call registers.
NIRQ_set:
	push af
	cp (hl)
	jr z,NIRQ_same
	ld (hl),a
	ld a,1
	ld (vic_changed),a
NIRQ_same:
	pop af
	ret

NIRQ_return:
	pop bc
	pop de
	pop af
	ret
