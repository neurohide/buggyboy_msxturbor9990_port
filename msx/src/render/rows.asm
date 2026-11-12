; Raster timeline, row setup, and character dirty preparation.
; ============================================================================
; timeline
; ============================================================================
; buffer just completed = tl_write ^ 1
tl_begin:
	ld a,(tl_write)
	xor 1
	ld hl,TL_BASE
	ld de,TIMELINE
	or a
	jr z,tlb_b0
	ld hl,TL_BASE+TL_REC
	ld de,TIMELINE1
tlb_b0:
	push hl
	ld hl,tl_count
	add a,l
	ld l,a
	ld a,(hl)
	pop hl
	or a
	jr nz,tlb_copy
	; no display change recorded: if no C64 IRQ ran at all (the chain slipped)
	; keep the last timeline, else the frame is just its base state
	push hl
	ld a,(tl_write)
	xor 1
	ld hl,tl_hadirq
	add a,l
	ld l,a
	ld a,(hl)
	pop hl
	or a
	jr z,tlb_reuse
	xor a
tlb_copy:
	; copy base + events to the local timeline
	ld (ltl_count),a
	push de
	ld de,LTL
	ld bc,TL_REC
	ldir
	pop hl
	ld a,(ltl_count)
	or a
	jr z,tlb_reuse
	ld b,a
tlb_cp:
	push bc
	ld bc,TL_REC
	ldir
	pop bc
	djnz tlb_cp
tlb_reuse:
tl_rewind:
	ld hl,LTL
	ld (rec_cur),hl
	ld hl,LTL+TL_REC
	ld (tl_ptr),hl
	ld a,(ltl_count)
	ld (tl_left),a
	; debug: remember this frame's events
	push af
	ld (dbg_ev),a
	ld a,(LTL+8+$11)
	ld (dbg_ev+1),a
	pop af
	or a
	ret z
	cp 14
	jr c,tlb_d1
	ld a,14
tlb_d1:
	ld b,a
	ld hl,(tl_ptr)
	ld de,dbg_ev+2
tlb_d2:
	ld a,(hl)
	ld (de),a
	inc de
	push hl
	push bc
	ld bc,8+$11
	add hl,bc
	ld a,(hl)
	ld (de),a
	inc de
	pop bc
	pop hl
	push de
	ld de,TL_REC
	add hl,de
	pop de
	djnz tlb_d2
	ret

; record for raster line HL: advance through events with line <= HL
; (lines must be requested in increasing order). Returns HL = record.
tl_at:
	ex de,hl
tla_loop:
	ld a,(tl_left)
	or a
	jr z,tla_done
	ld hl,(tl_ptr)
	ld a,(hl)
	inc hl
	ld h,(hl)
	ld l,a                      ; event line
	ex de,hl
	push hl
	or a
	sbc hl,de                   ; target - event
	pop hl
	ex de,hl
	jr c,tla_done               ; event after target
	ld hl,(tl_ptr)
	ld (rec_cur),hl
	ld bc,TL_REC
	add hl,bc
	ld (tl_ptr),hl
	ld hl,tl_left
	dec (hl)
	jr tla_loop
tla_done:
	ld hl,(rec_cur)
	ret

; ============================================================================
; per-row setup
; ============================================================================
renderer_setup_row:
	ld a,(cur_row)
	ld l,a
	ld h,0
	add hl,hl
	add hl,hl
	add hl,hl                   ; r*8
	ld de,51
	add hl,de
	call tl_at
	ld (row_rec),hl
	ld de,8
	add hl,de                   ; -> VIC regs
	push hl
	pop ix
	; signature check: D011&$70, D016&$18, D018 (xscroll is handled below)
	ld a,(cur_row)
	ld l,a
	ld h,0
	add hl,hl
	add hl,hl                   ; *4
	ld de,row_sigs
	add hl,de
	ld a,(ix+$11)
	and $70
	ld b,a
	ld a,(ix+$16)
	and $18
	ld c,a
	ld d,(ix+$18)
	ld a,(hl)
	cp b
	jr nz,rs_diff
	inc hl
	ld a,(hl)
	cp c
	jr nz,rs_diff1
	inc hl
	ld a,(hl)
	cp d
	jr z,rs_same
	jr rs_diff2
rs_diff:
	ld a,(mode_rows)
	inc a
	ld (mode_rows),a
	ld (hl),b
	inc hl
rs_diff1:
	ld (hl),c
	inc hl
rs_diff2:
	ld (hl),d
	ld a,(cur_row)
	ld hl,row_full
	add a,l
	ld l,a
	ld (hl),1
rs_same:
	; mode bits
	ld a,(ix+$16)
	rrca
	rrca
	rrca
	rrca
	and 1                       ; MCM
	ld b,a
	ld a,(ix+$11)
	and $20                     ; BMM
	jr z,rs_nbm
	set 1,b
rs_nbm:
	ld a,(ix+$11)
	and $10                     ; DEN
	jr nz,rs_den
	set 2,b
rs_den:
	ld a,b
	ld (row_mode),a
	ld a,(ix+$16)
	and 8
	ld (row_csel),a
	; x offset = xscroll*3/2
	ld a,(ix+$16)
	and 7
	ld b,a
	add a,a
	add a,b
	srl a
	ld (row_xoff),a
	; Keep the fine pixel delta until renderer_find_dirty_cells, where it can be combined
	; with a whole-cell horizon move into one VRAM blit.
	ld a,(cur_row)
	ld e,a
	ld d,0
	ld hl,SH_XOFF
	add hl,de
	xor a
	ld (row_xchg),a
	ld a,(row_xoff)
	cp (hl)
	jr z,rs_xsame
	ld b,(hl)                   ; old offset
	ld c,a
	sub b
	ld (row_xchg),a             ; signed fine pixel delta
	ld a,c
	ld (hl),a
	ld hl,row_full
	add hl,de
	ld a,b
	inc a
	jr z,rs_xfull               ; never drawn
	ld a,(row_mode)
	bit 2,a
	jr nz,rs_xfull              ; blank row
	jr rs_xsame
rs_xfull:
	ld (hl),1
rs_xsame:
	; screen row: bank offset (D018>>4)*$400 + r*40
	ld a,(cur_row)
	ld l,a
	ld h,0
	add hl,hl
	ld de,row40
	add hl,de
	ld e,(hl)
	inc hl
	ld d,(hl)                   ; r*40
	; per-row bases for cell_colours / shadow_ptr
	ld hl,COLOR_RAM
	add hl,de
	ld (row_cram),hl
	ld h,d
	ld l,e
	add hl,hl
	add hl,hl
	add hl,de
	add hl,hl                   ; r*400
	push de
	ld de,SHADOW
	add hl,de
	pop de
	ld (row_shad),hl
	ld a,(ix+$18)
	and $F0
	rrca
	rrca
	ld h,a
	ld l,0
	add hl,de
	ld (row_scroff),hl
	ld a,h
	add a,$80
	ld h,a
	ld (row_scr),hl
	ld a,(row_mode)
	bit 1,a
	jr nz,rs_bitmap
	; text: char base ((D018>>1)&7)*$800
	ld a,(ix+$18)
	and $0E
	add a,a
	add a,a
	ld h,a                      ; bank offset high byte
	ld l,0
	ld (row_bmoff),hl
	add a,$80
	ld h,a
	ld (row_data),hl
	jp chd_prepare
rs_bitmap:
	ld a,(cur_row)
	ld l,a
	ld h,0
	add hl,hl
	ld de,row320
	add hl,de
	ld e,(hl)
	inc hl
	ld d,(hl)
	ld a,(ix+$18)
	and 8
	add a,a
	add a,a                     ; $00 or $20
	ld h,a
	ld l,0
	add hl,de
	ld (row_bmoff),hl
	ld a,h
	add a,$80
	ld h,a
	ld (row_data),hl
	ret

; move the current clean row from x offset B to row_xoff with one LMMM
; (right moves copy from the right edge, DIX=1, so the overlap is safe)
row_shift:
	push ix
	ld a,(cur_row)
	call row_y_clean            ; also marks the row for the page sync
	ld (cmdblk+2),hl
	ld (cmdblk+6),hl
	ld hl,480
	ld (cmdblk+8),hl
	ld hl,8
	ld (cmdblk+10),hl
	ld a,(row_xoff)
	ld c,a
	ld hl,SCREEN_X
	cp b
	ld a,0
	jr c,rsh_dir                ; moving left: copy forwards
	ld hl,SCREEN_X+479
	ld a,4
rsh_dir:
	ld (cmdblk+12),a            ; ARG
	push hl
	ld e,b
	ld d,0
	add hl,de
	ld (cmdblk+0),hl            ; SX
	pop hl
	ld e,c
	add hl,de
	ld (cmdblk+4),hl            ; DX
	ld a,$0C
	ld (cmdblk+13),a
	ld a,$FF
	ld (cmdblk+14),a
	ld (cmdblk+15),a
	ld a,$40                    ; LMMM
	ld (cmdblk+20),a
	call v_send_cmd
	; 38 columns: the edge border moved with the row and the cells it
	; covered were never drawn: redraw them (draw_run re-borders)
	ld a,(row_csel)
	or a
	jr nz,rsh_done
	inc a
	ld (row_edge),a
rsh_done:
	pop ix
	ret

; character dirty flags for the current charset (computed once per base)
chd_prepare:
	ld a,(row_bmoff+1)
	ld hl,chd_cb
	cp (hl)
	ret z
	ld (hl),a
	; 32 chunks of 64 bytes starting at chunk (base>>6)
	rlca
	rlca                        ; high byte * 4 = chunk index
	ld l,a
	ld h,VDW/256
	ld de,CHDIRTY
	xor a
	ld (any_chd),a
	ld a,32
	ld (rgn_idx),a
chp_l:
	ld a,(hl)
	inc l
	ld c,a
	or a
	jr nz,chp_bits
	ld b,8                      ; clean chunk (the common case): 8 zero flags
chp_z:
	ld (de),a
	inc e                       ; CHDIRTY is page aligned
	djnz chp_z
	jr chp_next
chp_bits:
	ld (any_chd),a
	ld b,8
chp_8:
	srl c
	ld a,0
	adc a,0
	ld (de),a
	inc de
	djnz chp_8
chp_next:
	ld a,(rgn_idx)
	dec a
	ld (rgn_idx),a
	jr nz,chp_l
	ret

