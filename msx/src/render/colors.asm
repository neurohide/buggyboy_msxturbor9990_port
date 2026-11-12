; Cell colour and palette selection.
; ============================================================================
; colours of cell C of the current row -> cell_cols; HL = pixel source
; ============================================================================
cell_colours:
	; colour RAM
	ld hl,(row_cram)
	ld b,0
	add hl,bc
	ld a,(hl)
	and $0F
	ld (spr_tmp),a              ; colour RAM nibble
	ld e,a
	; screen byte
	ld hl,(row_scr)
	add hl,bc
	ld a,(hl)
	ld (spr_tmp+1),a
	ld d,a
	; same inputs as the last cell: cell_cols is still right (palette
	; slots are never freed), only the source pointer is needed
	ld hl,cc_key
	ld a,(row_mode)
	cp (hl)
	jr nz,cc_new
	inc l
	ld a,e
	cp (hl)
	jr nz,cc_new
	inc l
	ld a,d
	cp (hl)
	jr nz,cc_new
	ld a,(row_mode)
	bit 1,a
	ld l,c                      ; bitmap: 8 bytes per column
	jr nz,cc_src
	ld l,d                      ; text: 8 bytes per character
cc_src:
	ld h,0
	add hl,hl
	add hl,hl
	add hl,hl
	ld de,(row_data)
	add hl,de
	ld a,1
	ld (cc_hit),a
	ret
cc_new:
	xor a
	ld (cc_hit),a
	ld hl,cc_key
	ld a,(row_mode)
	ld (hl),a
	inc l
	ld (hl),e
	inc l
	ld (hl),d
	bit 1,a
	jr nz,cc_bitmap
	; text mode: char data = charbase + code*8
	ld a,(spr_tmp+1)
	ld l,a
	ld h,0
	add hl,hl
	add hl,hl
	add hl,hl
	ld de,(row_data)
	add hl,de
	push hl
	ld a,(row_mode)
	and 1
	jr z,cc_hires_text
	ld a,(spr_tmp)
	bit 3,a
	jr z,cc_hires_text7
	and 7
	call fix_slot
	ld (cell_cols+4),a
	ld a,1
	ld (cell_cols),a
	xor a
	ld (cell_cols+1),a
	inc a
	ld (cell_cols+2),a
	inc a
	ld (cell_cols+3),a
	pop hl
	ret
cc_hires_text7:
	and 7
	jr cc_ht
cc_hires_text:
	ld a,(spr_tmp)
cc_ht:
	call fix_slot
	ld (cell_cols+2),a
	xor a
	ld (cell_cols),a
	ld (cell_cols+1),a
	pop hl
	ret
cc_bitmap:
	ld l,c
	ld h,0
	add hl,hl
	add hl,hl
	add hl,hl
	ld de,(row_data)
	add hl,de
	push hl
	ld a,(row_mode)
	and 1
	jr z,cc_hires_bm
	ld a,1
	ld (cell_cols),a
	xor a
	ld (cell_cols+1),a
	ld a,(spr_tmp+1)
	rrca
	rrca
	rrca
	rrca
	and 15
	call fix_slot
	ld (cell_cols+2),a
	ld a,(spr_tmp+1)
	and 15
	call fix_slot
	ld (cell_cols+3),a
	ld a,(spr_tmp)
	call fix_slot
	ld (cell_cols+4),a
	pop hl
	ret
cc_hires_bm:
	xor a
	ld (cell_cols),a
	ld a,(spr_tmp+1)
	and 15
	call fix_slot
	ld (cell_cols+1),a
	ld a,(spr_tmp+1)
	rrca
	rrca
	rrca
	rrca
	and 15
	call fix_slot
	ld (cell_cols+2),a
	pop hl
	ret

; C64 colour A -> palette slot A (allocated on first use)
fix_slot:
	and 15
	push hl
	ld hl,fslot
	add a,l
	ld l,a
	ld a,(hl)
	or a
	jr z,fs_slow
	pop hl
	ret
fs_slow:                        ; HL = fslot entry: allocate, then cache it
	ld a,l
	sub fslot & 255
	call fs_alloc
	cp PAL_FIXED
	jr z,fs_nocache             ; maybe the out-of-slots fallback: ask again next time
	ld (hl),a
fs_nocache:
	pop hl
	ret
fs_alloc:
	push hl
	push bc
	and 15
	; only 12 palette slots are free: fold 4 rare colours into neighbours
	ld c,a
	ld b,0
	ld hl,col_fold
	add hl,bc
	ld a,(hl)
	ld c,a
	ld hl,slot_of
	add a,l
	ld l,a
	ld a,(hl)
	or a
	jr nz,fs_done
	ld a,(next_slot)
	or a
	jr nz,fs_have
	ld a,PAL_FIXED
fs_have:
	cp 16
	jr nc,fs_full
	ld (hl),a
	inc a
	ld (next_slot),a
	dec a
	push af
	; program the palette entry
	ld b,a
	ld l,c
	ld a,l
	add a,a
	add a,l
	ld l,a
	ld h,0
	push de
	ld de,r_c64_rgb
	add hl,de
	pop de
	call k_get_iff
	push af
	di
	ld a,b
	add a,a
	add a,a
	ld b,a
	call fs_write               ; palette bank 0
	ld a,b
	add a,64
	ld b,a
	call fs_write               ; palette bank 1 (see k_setlive)
	pop af
	or a
	jp z,fs_di
	ei
fs_di:
	pop af
	jr fs_done
fs_full:
	ld a,PAL_FIXED              ; out of slots: reuse the first one
fs_done:
	pop bc
	pop hl
	ret

; palette pointer B, colour bytes at HL (HL preserved)
fs_write:
	ld a,14
	out (V_SEL),a
	ld a,b
	out (V_REG),a
	push hl
	ld a,(hl)
	out (V_PAL),a
	inc hl
	ld a,(hl)
	out (V_PAL),a
	inc hl
	ld a,(hl)
	out (V_PAL),a
	pop hl
	ret

