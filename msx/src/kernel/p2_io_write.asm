; C64 memory-mapped I/O writes and live palette updates.
; Routines: k_iowr, k_vrdl, k_setlive.

; I/O writes: HL = $D000-$DFFF, A = value.  Preserves A, F, BC, DE.
; ============================================================================
k_iowr:
	push af
	ld a,h
	cp $D4
	jr c,iowr_vic
	cp $D8
	jp c,iowr_sid
	cp $DC
	jr c,iowr_col
	jr z,iowr_cia1
	cp $DD
	jr z,iowr_cia2
	pop af
	ret
iowr_col:
	and 3
	add a,COLOR_RAM/256
	ld h,a
	pop af
	push af
	cp (hl)
	jr z,iowr_x                 ; unchanged (iowr_x restores the flags)
	pop af
	ld (hl),a
	push af
	; dirty: byte offset >> 6, bit (offset >> 3) & 7
	ld a,l
	rrca
	rrca
	rrca
	and 7
	add a,bittab & 255
	push hl
	ld l,a
	ld h,bittab/256
	ld a,(hl)
	pop hl
	push af
	ld a,l
	rlca
	rlca
	and 3
	ld l,a
	ld a,h
	sub COLOR_RAM/256           ; H is the Z80 page $2A-$2D here
	add a,a
	add a,a
	or l
	add a,cdirty & 255
	ld l,a
	ld h,cdirty/256
	pop af
	or (hl)
	ld (hl),a
	pop af
	ret
iowr_cia1:
	ld a,l
	and $0F
	jr nz,iowr_x
	pop af
	ld (cia1_pra),a
	ret
iowr_cia2:
	ld a,l
	and $0F
	jr nz,iowr_x
	pop af
	ld (cia2_pra),a
	ret
iowr_x:
	pop af
	ret
iowr_vic:
	ld a,l
	and $3F
	cp $2F
	jr nc,iowr_x
	ld l,a
	ld h,VIC_REGS/256
	pop af
	push af
	cp (hl)
	ld (hl),a
	ld a,l
	jr nz,iowr_vic_new
	cp $19                      ; IRQ acknowledge acts on every write
	jr z,iowr_d019
	jr iowr_x
iowr_vic_new:
	; $D020-$D023 (live palette slots: border/bg0/bg1/bg2) are written far
	; more often than the other special registers below (every raster-split
	; colour change), so they're checked first here instead of after 6
	; comparisons that almost always miss.
	cp $20
	jr c,ivn_rest
	cp $24
	jr nc,ivn_rest
	; $D020-$D023: live palette slots (border -> 3, bg0..bg2 -> 0..2)
	sub $20
	jr nz,iowr_bg
	ld a,PAL_BORDER+1
iowr_bg:
	dec a
	pop hl                      ; H = value written
	push hl
	call k_setlive              ; slot A, colour H
	pop af
	ret
ivn_rest:
	cp $11
	jr z,iowr_d011
	cp $12
	jr z,iowr_d012
	cp $19
	jr z,iowr_d019
	cp $1A
	jr z,iowr_d01a
	cp $1E
	jr z,iowr_x
	cp $1F
	jr z,iowr_x
	jr iowr_changed
iowr_d011:
	ld a,1
	ld (vic_changed),a
	ld a,(in_irq)
	or a
	jr nz,iowr_d012
	inc a
	ld (blank_req),a            ; mode change from main code: new screen
	dec a
	dec a
	ld (calm_flips),a           ; $FF: keep blank until the renderer settles
	call k_get_iff
	push af
	di
	ld a,8
	out (V_SEL),a
	ld a,$42                    ; blank right now, not at the next page flip
	out (V_REG),a
	pop af
	or a
	jr z,iowr_d012
	ei
iowr_d012:
	call set_line_irq
	pop af
	ret
iowr_d019:
	pop af
	push af
	cpl
	ld hl,vic_irr
	and (hl)
	ld (hl),a
	pop af
	ret
iowr_d01a:
	pop af
	push af
	and $0F
	ld (vic_imr),a
	pop af
	ret
iowr_changed:
	ld a,1
	ld (vic_changed),a
	pop af
	ret

; ---- fixed-address VIC register writes (translate.py IO_FAST) ----------------
; A = value; preserves A, F, BC, DE.  Enter the general path with AF on the stack.
iowf_D011:
	push af
	ld hl,VIC_REGS+$11
	cp (hl)
	jp z,iowr_x
	ld (hl),a
	ld a,$11
	jp iowr_vic_new
iowf_D012:
	push af
	ld hl,VIC_REGS+$12
	cp (hl)
	jp z,iowr_x
	ld (hl),a
	ld a,$12
	jp iowr_vic_new
iowf_D016:
	push af
	ld hl,VIC_REGS+$16
	cp (hl)
	jp z,iowr_x
	ld (hl),a
	ld a,$16
	jp iowr_vic_new
iowf_D019:
	push af
	ld hl,VIC_REGS+$19
	cp (hl)
	ld (hl),a
	jp iowr_d019
iowf_D021:
	push af
	ld hl,VIC_REGS+$21
	cp (hl)
	jp z,iowr_x
	ld (hl),a
	ld a,$21
	jp iowr_vic_new
iowf_D022:
	push af
	ld hl,VIC_REGS+$22
	cp (hl)
	jp z,iowr_x
	ld (hl),a
	ld a,$22
	jp iowr_vic_new
iowf_D023:
	push af
	ld hl,VIC_REGS+$23
	cp (hl)
	jp z,iowr_x
	ld (hl),a
	ld a,$23
	jp iowr_vic_new

; VIC-bank load from translated code (HL = $4000-$7FFF -> L, AF, BC, DE kept):
; maps the VIC bank into page 3 like the lazy stores (translate.py plan_vic_lazy)
k_vrdl:
	push af
	ld a,(cur_p3)
	cp SEG_VIC
	jr z,vrdl_m
	call k_vic_on
vrdl_m:
	set 7,h
	set 6,h
	ld a,h
	and l
	inc a
	jr z,vrdl_ff                ; Z80 $FFFF is the sub-slot register
	ld l,(hl)
	pop af
	ret
vrdl_ff:
	ld hl,$7FFF
	jp k_vrd1                   ; (AF still pushed)

; set live palette slot A (0..3) to C64 colour H.  Preserves BC, DE.
; The live slots are written into the palette bank that is not on screen,
; then R#13/R#15 switch to it: the beam never sees a half-written colour
; (R, G and B arrive one by one, so red->white would flash yellow).
k_setlive:
	push bc
	push de
	ld c,a
	ld a,h
	and $0F
	ld b,a
	ld a,palette_shadow & 255
	add a,c
	ld l,a
	ld h,palette_shadow/256
	ld (hl),b
	call k_get_iff
	push af
	di
	ld a,(pal_bank)
	xor 1
	ld (pal_bank),a
	ld b,a                      ; b = new bank index (0/1)
	rrca
	rrca
	ld c,a                      ; bank * 64: palette pointer of its slot 0
	; DE -> bank_live[bank*4]: colours this bank's VRAM palette already holds
	; (bank_live and palette_shadow share the KVARS page)
	ld a,b
	add a,a
	add a,a
	add a,bank_live & 255
	ld e,a
	ld d,bank_live/256
	ld hl,palette_shadow
	ld b,4
	call ksl_slot
	jr ksl_done

; HL = palette_shadow, DE -> bank_live of bank C/64, B = 4: write the slots
; that bank lacks
ksl_slot:
	ld a,(de)
	cp (hl)
	jr nz,ksl_diff              ; (out of line: unchanged slots are the common case)
ksl_skip:
	inc hl
	inc de
	djnz ksl_slot
	ret
ksl_diff:
	ld a,(hl)
	ld (de),a
	ld a,14
	out (V_SEL),a
	ld a,l
	sub palette_shadow & 255
	add a,a
	add a,a                     ; R#14 is in units of entry*4
	add a,c
	out (V_REG),a
	push hl
	push de
	ld a,(hl)
	ld l,a
	add a,a
	add a,l
	ld l,a
	ld h,0
	ld de,c64_rgb
	add hl,de
	ld a,(hl)
	out (V_PAL),a
	inc hl
	ld a,(hl)
	out (V_PAL),a
	inc hl
	ld a,(hl)
	out (V_PAL),a
	pop de
	pop hl
	jr ksl_skip
ksl_done:
	ld a,(pal_bank)
	call pal_show
	pop af
	or a
	jr z,ksl_di
	ei
ksl_di:
	pop de
	pop bc
	ret

