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

; line IRQ while the kerb band chain runs.  Fast path (MSX2+): the bands
; alternate two colours and band 1's ISR staged band 2's, so from band 2 on
; each band is a plain palette bank flip, done here with AF/HL/BC only.
; First band, a failed kb_chk or a vblank flag with the line flag: heavy path.
k_int_kb:
	if MSX2PLUS
	push hl
	ld a,(pal_bank)             ; fast only when the bank not on screen already
	rrca                        ; holds this band's colour (staged): else heavy
	ld hl,bank_live
	jr c,kik_ob
	ld hl,bank_live+4
kik_ob:
	ld a,(hl)
	ld hl,(kb_ptr)
	inc hl
	cp (hl)
	jr nz,kik_heavy             ; HL = kb_ptr+1 (colour) from here on
	in a,(V_INT)
	rrca
	jr c,kik_heavy              ; vblank pending too (command end is not ours: ignore)
	ld a,2
	out (V_INT),a
	inc hl
	ld (kb_ptr),hl              ; -> next entry (line)
	ld a,13
	out (V_SEL),a
	ld a,(pal_bank)
	xor 1
	ld (pal_bank),a
	add a,a
	add a,a
	out (V_REG),a               ; R#13 = bank * 4
	ld a,15                     ; R#15 too, as pal_show (openMSX shows R#13 at the next sync)
	out (V_SEL),a
	ld a,(pal_bank)
	rrca
	rrca
	rrca
	rrca
	or PAL_BORDER
	out (V_REG),a
	ld a,10
	out (V_SEL),a
	ld a,(hl)                   ; next band's line (or band 12's)
	sub RASTER_OFS
	out (V_REG),a
	xor a
	out (V_REG),a
	ld hl,kb_n
	dec (hl)
	pop hl
	pop af
	ei
	reti
kik_heavy:
	pop hl
	endif
k_int_kbh:
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
