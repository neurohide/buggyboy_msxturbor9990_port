; Raster-band chaining, line IRQ scheduling, and SID register writes.
; Routines: kb_start, kb_fast, kb_slow, set_line_irq, iowr_sid.

; ---- kerb bands ($10E3 chain, see irq_native) ------------------------------
; The C64 handler changes D021 at 13 raster lines per frame.  From the first
; band on, the rest is done here: one list per frame, and each line IRQ only
; sets the colour and arms the next line (k_int_kb, no C64 context).  The C64
; state is left as after band 11 ($49 = 12, D012 = band 12's line), so the
; band-12 handler runs as before.
; E = first band to chain (1..11), D = 0; IRQ context.  Returns Z.
kb_start:
	if MSX2PLUS
	ld a,13                     ; band 12 too: the C64 handler runs at vblank
	sub e
	ld (kb_n0),a                ; int_vblank replays the list on odd frames
	else
	ld a,12
	sub e
	endif
	ld (kb_n),a
	ld b,a
	ld hl,kb_list
	ld (kb_ptr),hl
kbs_l:
	push hl
	ld hl,$14A6
	add hl,de
	ld a,(hl)
	ld hl,$14B3
	add hl,de
	ld c,(hl)
	pop hl
	ld (hl),a
	inc hl
	ld (hl),c
	inc hl
	inc e
	djnz kbs_l
	if MSX2PLUS
	endif
	ld a,($14A6+12)
	ld (hl),a
	ld a,12
	ld ($0049),a
	ld a,($14A6+12)
	call iowf_D012
	ld ($004A),a
	ld a,1
	call iowf_D019
	call sli_zero
	xor a
	ld (irq_late),a
	ld (sli_bord),a
	; the bank not on screen: live palette with the first chained colour
	ld a,(kb_list+1)
	call kb_prep
	or 1
	call kb_due
	xor a
	ret


; stage C64 colour A in slot 0 of the palette bank not on screen (R#13 untouched)
kb_prep:
	push bc
	push de
	push hl
	and $0F
	ld b,a
	ld a,(palette_shadow)
	push af
	ld a,b
	ld (palette_shadow),a
	ld a,(pal_bank)
	xor 1
	ld b,a
	rrca
	rrca
	ld c,a                      ; bank * 64
	ld a,b
	add a,a
	add a,a
	add a,bank_live & 255
	ld e,a
	ld d,bank_live/256
	ld hl,palette_shadow
	ld b,4
	call ksl_slot
	pop af
	ld (palette_shadow),a
	pop hl
	pop de
	pop bc
	ret

; B = 0 served; B = 1 not a lone line IRQ (normal path)
kb_fast:
	ld b,1
	in a,(V_INT)
	and 3
	cp 2
	ret nz
	ld b,0
	ld a,2
	out (V_INT),a
kb_apply:                       ; the entry at kb_ptr is due: its colour now
	ld hl,(kb_ptr)
	ld d,(hl)                   ; its line
	inc hl
	ld c,(hl)                   ; colour
	inc hl
	if MSX2PLUS
	; this (heavy) path takes ~12 lines and bands are 3-5 lines apart near the
	; horizon: lines the beam passes before the next one is armed end the chain,
	; so skip them (the last skipped colour is applied) and arm the first later one
	ld a,d
	add a,KB_SKIP
	ld d,a
	jr c,kba_arm                ; near the bottom: nothing to skip
kba_skip:
	ld a,(kb_n)
	cp 2
	jr c,kba_arm                ; the next entry is band 12's line (C64 handler)
	ld a,(hl)
	cp d
	jr nc,kba_arm
	inc hl
	ld c,(hl)
	inc hl
	ld a,(kb_n)
	dec a
	ld (kb_n),a
	jr kba_skip
kba_arm:
	ld (kb_ptr),hl
	; arm the next line before the (slow) colour change
	ld hl,kb_n
	dec (hl)
	push af                     ; Z: next line is band 12's
	call kb_due
	else
	ld (kb_ptr),hl
	endif
	ld a,c                      ; VIC_REGS+$21 untouched (as the fast path): vbl_catchup's top_col
	and $0F                     ; must not pick up a kerb colour
	ld c,a
	ld a,(pal_bank)
	xor 1
	ld e,a
	add a,a
	add a,a
	add a,bank_live & 255
	ld l,a
	ld h,bank_live/256
	ld a,(hl)
	cp c
	jr nz,kb_slow
	ld a,c                      ; the other bank holds it (kb_start): flip
	ld (palette_shadow),a
	ld a,e
	ld (pal_bank),a
	call pal_show
	jr kb_dec
kb_slow:
	ld h,c
	xor a
	call k_setlive
kb_dec:
	if MSX2PLUS
	pop af                      ; B is still 0 from kb_fast (kb_due, pal_show, k_setlive keep it)
	ret z
	ld hl,(kb_ptr)              ; stage the next colour in the bank not on screen
	inc hl
	ld a,(hl)
	and $0F
	ld c,a
	ld a,(pal_bank)
	xor 1
	add a,a
	add a,a
	add a,bank_live & 255
	ld l,a
	ld h,bank_live/256
	ld a,(hl)
	cp c
	ret z                       ; the bands alternate two colours: usually staged
	ld a,c
	jp kb_prep
	else
	ld hl,kb_n
	dec (hl)
	endif
kb_due:                         ; Z: the next line is band 12's (C64 handler)
	ld hl,(kb_ptr)
	ld e,(hl)
	ld d,0
	if MSX2PLUS=0               ; MSX2+: no beam position, always arm
	jr z,kb_arm
	call get_raster
	inc hl
	or a
	sbc hl,de
	jp nc,kb_apply              ; the beam is there already
	endif
kb_arm:
	ld a,10
	out (V_SEL),a
	ld a,e
	sub RASTER_OFS
	ld l,a
	out (V_REG),a
	xor a
	out (V_REG),a
	ld h,a
	ld a,(kb_n)
	or a
	ret nz
	if MSX2PLUS
	ret
	else
	inc hl
	ld (sli_last),hl            ; as set_line_irq leaves it
	ret
	endif

; Native C64 IRQ handlers, called by int_hline in place of the translated
; ones (C64 page 3 mapped, in_irq set).  Z: handled; NZ: run the C64 handler.
irq_native:
	if 1
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
	endif

; program the V9990 line interrupt from the C64 raster compare value
set_line_irq:
	push de
	ld a,(VIC_REGS+$11)
	rlca
	and 1
	ld h,a
	ld a,(VIC_REGS+$12)
	ld l,a
	if MSX2PLUS
	; raster_base and the software clock use C64 scanlines; preserve the
	; original compare before converting HL to a V9990 display line below.
	ld (soft_target),hl
	endif
	; v = c - RASTER_OFS for RASTER_OFS <= c <= 301, else 256
	ld de,RASTER_OFS
	or a
	sbc hl,de
	jr c,sli_border
	ld de,257
	or a
	sbc hl,de
	jr nc,sli_border
	add hl,de
	jr sli_set
sli_border:
	ld hl,222                   ; bottom border, well before the next frame
	ld a,1
	jr sli_set2
sli_set:
	xor a
sli_set2:
	ld (sli_bord),a
	if MSX2PLUS
	ld a,(sli_bord)
	or a
	jr z,sli_soft_done
	push hl
	ld hl,267
	ld (soft_target),hl
	pop hl
sli_soft_done:
	jr sli_di
	else
	; the V9990 line register only changes when the armed line does
	inc hl
	push hl
	ld de,(sli_last)
	or a
	sbc hl,de
	pop hl
	jr z,sli_di
	ld (sli_last),hl
	dec hl
	call k_get_iff
	push af
	di
	ld a,10
	out (V_SEL),a
	ld a,l
	out (V_REG),a
	ld a,h
	out (V_REG),a
	pop af
	or a
	jr z,sli_di
	ei
	endif
sli_di:
	; has the beam already passed the compare line (by less than 24 lines)?
	call get_raster              ; HL = current line
	ld a,(sli_bord)
	or a
	jr z,sli_vis
	; border slot (V9990 line 222 = C64 267): late if the beam is past it
	ld de,267
	or a
	sbc hl,de
	jr c,sli_ok
	jr sli_late
sli_vis:
	ld a,(VIC_REGS+$11)
	rlca
	and 1
	ld d,a
	ld a,(VIC_REGS+$12)
	ld e,a
	if MSX2PLUS
	; no beam position here: HL is the line of the IRQ being served, and the
	; translated handler plus the re-arm take ~10 lines on the Z80
	push hl
	ld hl,-10
	add hl,de
	ex de,hl
	pop hl
	endif
	dec de                      ; a line counts as passed while the beam is on it,
	dec de                      ; and the next one too: the timer estimate of the
	or a                        ; beam can lag the V9990 line counter (arming one
	sbc hl,de                   ; line ahead missed the IRQ): current - (compare - 2)
	jr c,sli_ok
	ld a,h
	or a
	jr nz,sli_ok
	ld a,l
	cp 24
	jr nc,sli_ok
sli_late:
	ld a,1
	jr sli_x
sli_ok:
	xor a                       ; the last arming decides: an earlier D011/D012
sli_x:                          ; write of the same handler may have looked late
	ld (irq_late),a
	pop de
	ret

; ---- SID ----------------------------------------------------------------
iowr_sid:
	ld a,l
	and $1F
	ld l,a
	ld h,SID_REGS/256
	ld a,l
	add a,SID_REGS & 255
	ld l,a
	pop af
	push af
	push bc
	ld b,(hl)                   ; previous value
	ld (hl),a
	ld c,a
	ld a,l
	sub SID_REGS & 255
	; control registers 4, 11, 18: gate transitions
	ld l,0
	cp 4
	jr z,isid_ctl
	inc l
	cp 11
	jr z,isid_ctl
	inc l
	cp 18
	jr nz,isid_x
isid_ctl:
	ld a,b
	xor c
	and 1
	jr z,isid_x                 ; gate unchanged
	ld h,sid_phase/256
	ld a,l
	add a,sid_phase & 255
	ld l,a
	ld a,c
	and 1
	jr z,isid_rel
	ld (hl),1                   ; attack
	jr isid_x
isid_rel:
	ld (hl),3                   ; release
isid_x:
	pop bc
	pop af
	ret

; ============================================================================

; translated "lda $D011 / and #$80 / beq self": wait until the raster is at
; line 256 or later, or a vblank went by (the renderer runs in the vblank
; ISR and can hold the CPU across the whole bottom border).  A = $80, NZ.
k_vwait:
	push hl
	push de
	call mt_poll
	ld a,(frame_count)
	ld e,a
kvw_l:
	ld a,(frame_count)
	cp e
	jr nz,kvw_hit
	call get_raster_step
	ld a,h
	or a
	jr z,kvw_l
kvw_hit:
	pop de
	pop hl
	ld a,$80
	or a
	ret
