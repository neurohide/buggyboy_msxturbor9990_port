; IM2 vector entry, interrupt context save/restore, native IRQ handling, and palette-bank display.
; Routines: k_int, k_map_vic, k_map_c2, irq_native, pal_show, k_int_kb.

; region $27FF-$28FF: IM2 vector and interrupt entry
; ============================================================================
	org $27FF
region_im2_start:
	dw k_int

k_int:
	push af
	ld a,(kb_n)
	or a
	jp nz,k_int_kb
k_int_n:
	push bc
	push de
	push hl
	push ix
	push iy
	ex af,af'
	push af
	ex af,af'
	exx
	push bc
	push de
	push hl
	exx
	ld a,(cur_p1)
	push af
	ld a,(cur_p2)
	push af
	ld a,(cur_p3)
	push af
	ld a,SEG_C2
	ld (cur_p2),a
	out (PORT_P2),a
	ld a,SEG_C3
	ld (cur_p3),a
	out (PORT_P3),a
	call int_dispatch           ; page-2 kernel
	pop af
	ld (cur_p3),a
	out (PORT_P3),a
	pop af
	ld (cur_p2),a
	out (PORT_P2),a
	pop af
	ld (cur_p1),a
	out (PORT_P1),a
	exx
	pop hl
	pop de
	pop bc
	exx
	ex af,af'
	pop af
	ex af,af'
	pop iy
	pop ix
	pop hl
	pop de
	pop bc
	pop af
	ei
	reti

; map the VIC bank into page 2 / restore C64 block 2 (A clobbered)
k_map_vic:
	ld a,SEG_VIC
	ld (cur_p2),a
	out (PORT_P2),a
	ret
k_map_c2:
	ld a,SEG_C2
	ld (cur_p2),a
	out (PORT_P2),a
	ret

; Native C64 IRQ handlers, called by int_hline in place of the translated
; ones (C64 page 3 mapped, in_irq set).  Z: handled; NZ: run the C64 handler.
irq_native:
	ld a,($FFFE)
	cp $E3
	ret nz
	ld a,(vec_ffff)
	cp $10
	ret nz
	; $10E3: kerb colour band.  X = $49 indexes the band line table L14A6
	; and the colour table L14B3; the last band (X = 12) does the frame
	; work: left to the translated handler.
	ld a,($0049)
	ld e,a
	ld d,0
	ld hl,$14A6
	add hl,de
	ld a,($004A)
	cp (hl)
	jr nz,irn_done              ; stale IRQ: the C64 handler just returns
	ld a,e
	cp 12
	jr z,irn_c64
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
	cp 12
	jp c,kb_start               ; bands e..11 by the native chain (returns Z)
	ld ($0049),a
	ld hl,$14A6
	add hl,de
	ld a,(hl)
	call iowf_D012
	ld ($004A),a
	ld a,1
	call iowf_D019
irn_done:
	xor a
	ret
irn_c64:
	or 1
	ret

; show palette bank A (0/1): R#13 PLTO5-4, R#15 backdrop follows (C clobbered)
pal_show:
	add a,a
	add a,a
	ld c,a
	ld a,13
	out (V_SEL),a
	ld a,c
	out (V_REG),a
	ld a,15
	out (V_SEL),a
	ld a,c
	add a,a
	add a,a
	or PAL_BORDER
	out (V_REG),a
	ret

; line IRQ while the kerb band chain runs (kernel_p2 kb_fast)
k_int_kb:
	push bc
	push de
	push hl
	ld a,(cur_p2)
	push af
	ld a,SEG_C2
	out (PORT_P2),a
	call kb_fast                ; B = 0: served
	pop af
	out (PORT_P2),a
	ld a,b
	pop hl
	pop de
	pop bc
	or a
	jp nz,k_int_n
	pop af
	ei
	reti
region_im2_end:

; ============================================================================
; region $0E00-$0FFF: memory access helpers
; ============================================================================
