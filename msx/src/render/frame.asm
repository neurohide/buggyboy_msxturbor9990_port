; Frame entry, first-frame setup, border fill, and timeline setup.
render_frame:
	call k_map_vic
	ld a,SEG_SHADOW
	ld (cur_p3),a
	out (PORT_P3),a
	ld a,(first_done)
	or a
	call z,render_first
	; take the dirty flags
	di
	ld hl,VDIRTY
	ld de,VDW
	ld bc,256
	ldir
	; clear VDIRTY: write one zero and replicate it with LDIR (a byte
	; loop costs ~29 cycles per byte on the Z80, LDIR is 16)
	ld hl,VDIRTY
	ld (hl),0
	ld d,h
	ld e,l
	inc de
	push bc
	ld bc,255
	ldir
	pop bc
	ld hl,cdirty
	ld de,cdw
	ld bc,16
	ldir
	ld hl,cdirty
	ld b,16
r_clr2:
	ld (hl),0
	inc hl
	djnz r_clr2
	ei
	; sprite shapes the game rewrote (one 64-byte chunk per pointer): drop
	; their cached copies so they are rendered again.  Only the live slots
	; hold a cached shape (sc_live); stale entries are pruned here as well.
	ld b,0                      ; list index
r_sci:
	ld a,(sc_n)
	cp b
	jr z,r_sci_done
	ld a,b
	ld hl,sc_live
	ld e,a
	ld d,0
	add hl,de
	ld a,(hl)                   ; slot number
	push af
	add a,a
	add a,a
	add a,a
	ld e,a
	ld d,0
	ld hl,SCACHE
	add hl,de                   ; slot entry
	ld e,(hl)                   ; key byte 0 = pointer chunk
	ld d,VDW/256
	ld a,(de)
	or a
	jr z,r_sci_keep
	; source chunk changed: invalidate the shape and prune the slot
	push hl
	ld de,5
	add hl,de
	ld (hl),0                   ; valid flag
	pop hl
	pop af                      ; A = slot
	ld hl,sc_in
	ld e,a
	ld d,0
	add hl,de
	ld (hl),0                   ; sc_in[slot] = 0
	ld a,(sc_n)
	dec a                       ; last entry index
	ld e,a
	ld d,0
	ld hl,sc_live
	add hl,de
	ld a,(hl)                   ; sc_live[sc_n-1]
	ld e,b
	ld d,0
	ld hl,sc_live
	add hl,de
	ld (hl),a                   ; sc_live[b] = sc_live[sc_n-1]
	ld hl,sc_n
	dec (hl)                    ; position b is examined again next pass
	jr r_sci
r_sci_keep:
	pop af
	inc b
	jr r_sci
r_sci_done:
	ld a,$FF
	ld (chd_cb),a
	ld (cc_key),a               ; no row_mode is $FF: cell_cols is rebuilt
	xor a
	ld (mode_rows),a
	ld (cm_lv),a
	ld hl,(dbg_cnt)
	ld (dbg_cells),hl
	ld hl,0
	ld (dbg_cnt),hl
	xor a
	ld (dbg_full),a
	call tl_begin
	; back page only changes in vblank when flip_pending is set, so
	; with it clear the page is stable for the whole rows phase
	ld a,(flip_pending)
	xor 1
	ld (SH_EARLY),a
	ld a,(calm_flips)
	inc a
	jr nz,rf_page_ready
	xor a
	ld (SH_EARLY),a             ; keep redraws off the visible page during a mode change
rf_page_ready:
	ld a,(page_back)
	ld (SH_CUR_PG),a
	xor a
rr_loop:
	ld (cur_row),a
	call renderer_setup_row
	call renderer_find_dirty_cells
	call nz,renderer_draw_dirty_cells
	ld a,(SH_EARLY)
	or a
	jr z,rr_next
	; a row is final once its render is done: copy it now
	ld a,(cur_row)
	ld e,a
	ld d,0
	ld hl,SH_ROWS
	add hl,de
	ld a,(hl)
	or a
	call nz,sync_row
rr_next:
	ld a,(cur_row)
	inc a
	cp 25
	jr nz,rr_loop
	call render_sprites
	call screen_change

	ld a,SEG_C3
	ld (cur_p3),a
	out (PORT_P3),a
	jp k_map_c2

render_first:
	ld a,1
	ld (first_done),a
	call cm_init
	; no cached row setups, no live sprite cache slots yet
	xor a
	ld (sc_n),a
	ld hl,sc_in
	ld (hl),a
	ld d,h
	ld e,l
	inc de
	ld bc,127
	ldir
	ld a,$80
	ld (celldirty+40),a         ; renderer_draw_dirty_cells scan sentinel
	ld hl,SH_XOFF
	ld (hl),$FF
	ld de,SH_XOFF+1
	ld bc,24
	ldir
	ld hl,row_full
	ld b,25
rf1:
	ld (hl),1
	inc hl
	djnz rf1
	ld hl,SH_ROWS
	ld de,SH_ROWS+1
	ld bc,SH_CUR_PG-SH_ROWS
	ld (hl),0
	ldir
	; border colour around the C64 screen in all three buffers
	ld hl,0
	call border_fill
	ld hl,256
	call border_fill
	ld hl,CLEAN_Y
	call border_fill
	ret

; HL = y origin of a buffer: fill everything outside the 480x200 window
border_fill:
	push hl
	ld de,0
	ld bc,512
	ld a,SCREEN_Y
	call fill_rect_y            ; top strip
	pop hl
	push hl
	ld de,SCREEN_Y+200
	add hl,de
	ld de,0
	ld bc,512
	ld a,212-SCREEN_Y-200
	call fill_rect_hl
	pop hl
	push hl
	ld de,SCREEN_Y
	add hl,de
	ld de,0
	ld bc,SCREEN_X
	ld a,200
	call fill_rect_hl
	pop hl
	ld de,SCREEN_Y
	add hl,de
	ld de,SCREEN_X+480
	ld bc,512-SCREEN_X-480
	ld a,200
	jp fill_rect_hl
fill_rect_y:                    ; same as fill_rect_hl, y in HL
fill_rect_hl:
	; DE = x, HL = y, BC = width, A = height; colour PAL_BORDER
	ld (cmdblk+4),de
	ld (cmdblk+6),hl
	ld (cmdblk+8),bc
	ld (cmdblk+10),a
	xor a
	ld (cmdblk+11),a
	ld a,PAL_BORDER*$11
	jp lmmv

