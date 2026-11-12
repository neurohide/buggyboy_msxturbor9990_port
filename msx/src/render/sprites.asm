; Sprite erase, page synchronization, collision, and shape cache.
; ============================================================================
; sprites
; ============================================================================
; B = sprites to restore, IX -> their DRAWN records: copy each rectangle
; from the clean buffer to the page being built
erase_hist:
	ld a,b
	or a
	ret z
	ld a,(SH_CUR_PG)
	ld (cmdblk+7),a
eh_loop:
	push bc
	push ix
	ld l,(ix+0)
	ld h,(ix+1)
	ld (cmdblk+0),hl
	ld (cmdblk+4),hl
	ld l,(ix+3)
	ld h,(ix+4)
	ld (cmdblk+8),hl
	ld a,(ix+5)
	ld l,a
	ld h,0
	ld (cmdblk+10),hl
	ld a,(ix+2)
	ld l,a
	ld h,0
	ld de,CLEAN_Y
	add hl,de
	ld (cmdblk+2),hl
	ld a,(ix+2)
	ld (cmdblk+6),a
	call lmmm
	pop ix
	ld de,8
	add ix,de
	pop bc
	djnz eh_loop
	ret

; C = 1: sync every row; otherwise rows changed this or last frame.
; E = row index on entry to sync_row
sync_rows:
	ld d,0
	ld e,0
sr_loop:
	ld a,c
	or a
	jr nz,sr_full
	ld hl,SH_ROWS
	add hl,de
	ld b,(hl)                   ; changed this frame
	ld a,(SH_EARLY)
	or a
	jr z,sr_old
	; changed this frame were already copied by render; only last frame's
	ld a,b
	or a
	jr nz,sr_next
	ld hl,SH_ROWP
	add hl,de
	ld a,(hl)
	or a
	jr z,sr_next
	jr sr_do
sr_old:
	ld a,b
	ld hl,SH_ROWP
	add hl,de
	or (hl)
	jr z,sr_next
sr_do:
	call sync_row
	jr sr_next
sr_full:
	call sync_row_full
sr_next:
	inc e
	ld a,e
	cp 25
	jr nz,sr_loop
	ret

; copy row E from clean to the page being built: the span changed this
; and last frame (the page is two frames old)
sync_row:
	push bc
	push de
	ld h,SH_ROWS/256
	ld l,e
	ld b,(hl)                   ; changed this frame
	set 5,l
	ld c,(hl)                   ; changed last frame (SH_ROWP)
	ld d,255
	ld e,0
	res 5,l
	set 7,l                     ; SPAN_LO
	ld a,b
	or a
	jr z,srs_p
	ld d,(hl)
	set 5,l
	ld e,(hl)
	res 5,l
srs_p:
	ld a,c
	or a
	jr z,srs_go
	set 6,l                     ; SPANP_LO
	ld a,(hl)
	cp d
	jr nc,srs_1
	ld d,a
srs_1:
	set 5,l                     ; SPANP_HI
	ld a,(hl)
	cp e
	jr c,srs_go
	ld e,a
srs_go:
	ld a,d
	cp e
	jr c,srs_have
sync_row_fullx:                 ; nothing flagged: whole row
	ld d,0
	ld e,SPAN_FULL
srs_have:
	ld a,e
	sub d
	ld l,a
	ld h,0
	add hl,hl
	add hl,hl
	ld (cmdblk+8),hl            ; NX
	ld l,d
	ld h,0
	add hl,hl
	add hl,hl
	ld bc,SCREEN_X
	add hl,bc
	ld (cmdblk+0),hl
	ld (cmdblk+4),hl
	pop de
	push de
	ld l,e
	ld h,0
	add hl,hl
	add hl,hl
	add hl,hl
	ld de,SCREEN_Y
	add hl,de
	ld a,l
	ld (cmdblk+6),a
	ld a,(SH_CUR_PG)
	ld (cmdblk+7),a
	push hl
	ld bc,CLEAN_Y
	add hl,bc
	ld (cmdblk+2),hl
	ld hl,8
	ld (cmdblk+10),hl
	pop hl
	call lmmm
	pop de
	pop bc
	ret
sync_row_full:
	push bc
	push de
	jr sync_row_fullx



; keep this frame's drawn sprites for the page, for the next erase
sp_save:
	ld a,(SH_CUR_PG)
	ld e,a
	ld d,0
	ld hl,SH_PG
	add hl,de
	ld a,(spr_n)
	ld (hl),a
	or a
	ret z
	add a,a
	add a,a
	add a,a
	ld c,a
	ld b,0
	ld hl,DRAWN
	ld de,SH_SPR
	ld a,(SH_CUR_PG)
	or a
	jr z,ss_cp
	ld de,SH_SPR+128
ss_cp:
	ldir
	ret

render_sprites:
	; the back page still holds its own last sprites: restore their
	; rectangles from the clean playfield, then the rows that changed
	; since this page was last built (a full copy if it was never built)
	ld a,(page_back)
	ld (SH_CUR_PG),a
	ld e,a
	ld d,0
	ld hl,SH_PG+2
	add hl,de
	ld a,(hl)
	ld (hl),1
	xor 1
	ld c,a                      ; C = 1: copy every row
	ld hl,SH_PG
	add hl,de
	ld b,(hl)                   ; B = sprites last drawn on this page
	push bc
	ld ix,SH_SPR
	ld a,e
	or a
	jr z,sp_h0
	ld de,128
	add ix,de
sp_h0:
	call erase_hist
	pop bc
	call sync_rows
sp_erased:
	call sp_live
	xor a
	ld (spr_n),a
	ld (coll_acc),a
	; walk the regions of the timeline again
	call tl_rewind
	ld hl,0
	ld (rgn_lo),hl
sp_region:
	; region record = record active at rgn_lo; region end = next event line
	ld hl,(rgn_lo)
	call tl_at
	ld (rgn_rec),hl
	ld hl,400
	ld a,(tl_left)
	or a
	jr z,sp_last
	ld hl,(tl_ptr)
	ld a,(hl)
	inc hl
	ld h,(hl)
	ld l,a
sp_last:
	ld (rgn_hi),hl
	call sp_draw_region
	ld hl,(rgn_hi)
	ld de,400
	or a
	sbc hl,de
	jr z,sp_done
	ld hl,(rgn_hi)
	ld (rgn_lo),hl
	jr sp_region
sp_done:
	ld a,(coll_acc)
	ld hl,coll_ss
	or (hl)
	ld (hl),a
	call sp_save
	; this frame's changed rows become "last frame" for the other page
	ld hl,SH_ROWS
	ld de,SH_ROWP
	ld bc,25
	ldir
	ld hl,SPAN_LO
	ld de,SPANP_LO
	ld bc,64
	ldir
	ld hl,SH_ROWS
	ld de,SH_ROWS+1
	ld bc,24
	ld (hl),0
	ldir
	; the back page is complete: shown from the next vblank
	ld a,1
	ld (flip_pending),a
	ret

; draw sprites 7..0 of record rgn_rec whose first line falls in [rgn_lo, rgn_hi)
sp_draw_region:
	ld a,7
spd_loop:
	ld (rgn_idx),a
	call sp_one
	ld a,(rgn_idx)
	dec a
	jp p,spd_loop
	ret

sp_one:
	ld hl,(rgn_rec)
	ld de,8
	add hl,de
	push hl
	pop iy                      ; IY -> VIC regs of the region
	ld a,(rgn_idx)
	ld b,a
	inc b
	ld a,(iy+$15)
spo_en:
	rrca
	djnz spo_en
	ret nc                      ; not enabled
	; first raster line = Y + 1
	ld a,(rgn_idx)
	add a,a
	ld e,a
	ld d,0
	push iy
	pop hl
	add hl,de
	ld a,(hl)                   ; X low
	inc hl
	ld c,(hl)                   ; Y
	ld (spr_tmp),a
	ld b,0
	ld h,b
	ld l,c
	inc hl
	ld de,(rgn_lo)
	or a
	sbc hl,de
	ret c
	ld h,b
	ld l,c
	inc hl
	ld de,(rgn_hi)
	or a
	sbc hl,de
	ret nc
	ld a,(spr_n)
	cp MAX_SPR
	ret nc
	; x = SCREEN_X + (X9 - 24) * 3 / 2 ; y = Y + 1 - 51 + SCREEN_Y
	ld a,(rgn_idx)
	ld b,a
	inc b
	ld a,(iy+$10)
spo_msb:
	rrca
	djnz spo_msb
	ld a,(spr_tmp)
	ld l,a
	ld h,0
	jr nc,spo_nomsb
	inc h
spo_nomsb:
	ld de,-24
	add hl,de
	ld d,h
	ld e,l
	add hl,hl
	add hl,de                   ; *3
	sra h
	rr l                        ; /2
	ld de,SCREEN_X
	add hl,de
	ld (spr_tmp+2),hl           ; x (signed)
	ld a,c
	sub 51-1-SCREEN_Y
	ld l,a
	ld h,0
	jr nc,spo_y
	ld h,$FF
spo_y:
	ld (spr_tmp+4),hl           ; y (signed)
	; shape in the cache
	call sp_cache               ; -> HL = cache x, A = slot, sets spr w/h in spr_tmp+6/7
	ret c
	; DRAWN entry
	push hl
	ld a,(spr_n)
	ld l,a
	ld h,0
	add hl,hl
	add hl,hl
	add hl,hl
	ld de,DRAWN
	add hl,de
	push hl
	pop ix
	pop hl                      ; cache x
	; clip against x 0..511, y 0..211
	ld (cmdblk+0),hl
	ld de,(spr_tmp+2)
	ld a,(spr_tmp+6)
	ld c,a
	ld b,0                      ; width
	bit 7,d
	jr z,spo_xpos
	; x < 0: skip -x columns
	ld hl,0
	or a
	sbc hl,de                   ; -x
	ld a,h
	or a
	ret nz
	ld a,l
	cp c
	ret nc
	ld a,c
	sub l
	ld c,a
	ld de,(cmdblk+0)
	add hl,de
	ld (cmdblk+0),hl
	ld de,0
spo_xpos:
	; x + w <= 512
	ld hl,512
	or a
	sbc hl,de
	ret c
	ret z
	ld a,h
	or a
	jr nz,spo_wok
	ld a,l
	cp c
	jr nc,spo_wok
	ld c,l
spo_wok:
	ld (cmdblk+4),de
	ld (ix+0),e
	ld (ix+1),d
	ld (ix+3),c
	ld (ix+4),0
	ld l,c
	ld h,0
	ld (cmdblk+8),hl
	; y
	ld hl,(spr_tmp+4)
	ld a,(spr_tmp+7)
	ld c,a                      ; height
	bit 7,h
	jr z,spo_ypos
	ld a,l
	neg
	cp c
	ret nc
	ld b,a
	ld a,c
	sub b
	ld c,a
	ld a,(spr_tmp+8)            ; cache y low
	add a,b
	ld (spr_tmp+8),a
	jr nc,spo_y2
	ld a,(spr_tmp+9)
	inc a
	ld (spr_tmp+9),a
spo_y2:
	ld hl,0
spo_ypos:
	ld a,h
	or a
	ret nz
	ld a,l
	cp 212
	ret nc
	ld (ix+2),a
	ld b,a
	ld a,212
	sub b
	cp c
	jr nc,spo_hok
	ld c,a
spo_hok:
	ld (ix+5),c
	ld a,(page_back)
	add a,h
	ld h,a                      ; y in the back page
	ld (cmdblk+6),hl
	ld l,c
	ld h,0
	ld (cmdblk+10),hl
	ld hl,(spr_tmp+8)
	ld (cmdblk+2),hl
	; collision bounding box in screen coordinates
	call sp_coll
	ld hl,spr_n
	inc (hl)
	jp lmmm_tp

; --- sprite-sprite collision on tight bounding boxes --------------------------
; this sprite: IX entry (x,y,w,h) + bbox from the cache slot in spr_tmp+10..13
; Race display (all 8 sprites from the L1486 tables, L1452): the player's car
; is sprites 0/1, which the 50 Hz raster IRQ moves (LB781) even while we
; render.  Draw them at their current shadow position instead of the frame's:
; the car (position and frame) then shows ~3 fields fresher.
sp_live:
	ld a,($02E9)
	or a
	ret nz
	ld a,i                      ; P/V = IFF2 (read twice, as k_get_iff)
	jp pe,spl_on
	ld a,i
spl_on:
	push af
	di
	ld a,SEG_C3
	out (PORT_P3),a
	ld a,($CFEC)
	ld c,a
	ld a,SEG_SHADOW
	out (PORT_P3),a
	pop af
	jp po,spl_di
	ei
spl_di:
	ld a,c
	or a
	ret nz                      ; upper zone from L132F: not the race layout
	ld a,(ltl_count)
	inc a
	ld b,a                      ; base record + events
	ld hl,LTL+8                 ; VIC registers of the record
	ld de,TL_REC-$10
spl_l:
	ld a,($1486)
	ld (hl),a                   ; sprite 0 X
	inc l
	ld a,($148E)
	ld (hl),a                   ; sprite 0 Y
	inc l
	ld a,($1487)
	ld (hl),a                   ; sprite 1 X
	inc l
	ld a,($148F)
	ld (hl),a                   ; sprite 1 Y
	ld a,l
	add a,$10-3
	ld l,a
	ld a,($02E5)
	xor (hl)
	and 3
	xor (hl)
	ld (hl),a                   ; X bit 8 of sprites 0/1
	push hl
	ld a,l
	add a,$20
	ld l,a                      ; record + $38: sprite pointers
	ld a,($1496)
	ld (hl),a
	inc l
	ld a,($1497)
	ld (hl),a
	pop hl
	add hl,de
	djnz spl_l
	ret

sp_coll:
	ld a,(rgn_idx)
	ld (ix+6),a
	ld a,(spr_tmp+10)
	ld (ix+7),a                 ; bbox packed: store x0..x1/y0..y1 offsets
	ld a,(spr_n)
	or a
	ret z
	ld b,a
	ld iy,DRAWN
spc_l:
	push bc
	call spc_test
	pop bc
	ld de,8
	add iy,de
	djnz spc_l
	ret
spc_test:
	; overlap of [x, x+w) x [y, y+h) shrunk by 1/4 on each side
	ld a,(iy+6)
	cp (ix+6)
	ret z                       ; same sprite number (multiplexed)
	ld l,(ix+0)
	ld h,(ix+1)
	ld e,(iy+0)
	ld d,(iy+1)
	; |dx| < (w1+w2)/2 * 3/4 ... approximated with half widths
	or a
	sbc hl,de
	jr nc,spt_px
	ex de,hl
	ld hl,0
	or a
	sbc hl,de
spt_px:
	ld a,h
	or a
	ret nz
	ld a,(ix+3)
	add a,(iy+3)
	srl a
	srl a
	ld c,a
	ld a,(ix+3)
	add a,(iy+3)
	srl a
	sub c
	srl c
	add a,c                     ; 3/8 of the summed widths
	cp l
	ret c
	ret z
	ld a,(ix+2)
	sub (iy+2)
	jr nc,spt_py
	neg
spt_py:
	ld l,a
	ld a,(ix+5)
	add a,(iy+5)
	srl a
	srl a
	ld c,a
	ld a,(ix+5)
	add a,(iy+5)
	srl a
	sub c
	srl c
	add a,c
	cp l
	ret c
	ret z
	; collide: set both sprite bits
	ld a,(ix+6)
	call bitmask
	ld c,a
	ld a,(iy+6)
	call bitmask
	or c
	ld hl,coll_acc
	or (hl)
	ld (hl),a
	ret
bitmask:
	ld b,a
	inc b
	ld a,$80
bm_l:
	rlca
	djnz bm_l
	ret

; --- sprite shape cache --------------------------------------------------------
; key: pointer, flags (mc | expx<<1 | expy<<2), colour, mc0, mc1
; -> HL = cache x, spr_tmp+8 = cache y, spr_tmp+6/7 = w/h; carry on failure
sp_cache:
	; build the key in spr_tmp+10..14
	ld hl,(rgn_rec)
	ld de,$38
	add hl,de
	ld a,(rgn_idx)
	add a,l
	ld l,a
	ld a,(hl)
	ld (spr_tmp+10),a           ; pointer
	ld a,(rgn_idx)
	ld b,a
	inc b
	ld c,0
	ld a,(iy+$1C)
spc_b1:
	rrca
	djnz spc_b1
	jr nc,spc_nmc
	set 0,c
spc_nmc:
	ld a,(rgn_idx)
	ld b,a
	inc b
	ld a,(iy+$1D)
spc_b2:
	rrca
	djnz spc_b2
	jr nc,spc_nex
	set 1,c
spc_nex:
	ld a,(rgn_idx)
	ld b,a
	inc b
	ld a,(iy+$17)
spc_b3:
	rrca
	djnz spc_b3
	jr nc,spc_ney
	set 2,c
spc_ney:
	ld a,c
	ld (spr_tmp+11),a
	ld a,(rgn_idx)
	ld e,a
	ld d,0
	push iy
	pop hl
	add hl,de
	ld de,$27
	add hl,de
	ld a,(hl)
	and 15
	ld (spr_tmp+12),a
	ld a,(iy+$25)
	and 15
	ld (spr_tmp+13),a
	ld a,(iy+$26)
	and 15
	ld (spr_tmp+14),a
	; size
	ld a,36
	bit 1,c
	jr z,spc_w
	ld a,72
spc_w:
	ld (spr_tmp+6),a
	ld a,21
	bit 2,c
	jr z,spc_h
	ld a,42
spc_h:
	ld (spr_tmp+7),a
	; slot = (pointer + 7*colour + 31*flags) & 63
	ld a,(spr_tmp+12)
	ld b,a
	add a,a
	add a,a
	add a,a
	sub b
	ld b,a
	ld a,(spr_tmp+11)
	ld c,a
	add a,a
	add a,a
	add a,a
	add a,a
	add a,a
	sub c
	add a,b
	ld b,a
	ld a,(spr_tmp+10)
	add a,b
	and SC_SLOTS-1
	ld (spr_tmp+15),a
	; 2-way: try slot, then slot^1; on miss evict a random one of the pair
	call spc_chk
	jr c,spc_pos
	ld a,(spr_tmp+15)
	xor 1
	ld (spr_tmp+15),a
	call spc_chk
	jr c,spc_pos
	ld a,r
	and 1
	ld b,a
	ld a,(spr_tmp+15)
	and $FE
	or b
	ld (spr_tmp+15),a
	call spc_ent
	ex de,hl
	ld hl,spr_tmp+10
	ld bc,5
	ldir
	ld a,1
	ld (de),a
	call sp_render
spc_pos:
	; slot position: column = slot % 7, row = slot / 7
	ld a,(spr_tmp+15)
	ld c,0
spc_div:
	cp 7
	jr c,spc_dd
	sub 7
	inc c
	jr spc_div
spc_dd:
	; x = col*72
	ld l,a
	ld h,0
	add hl,hl
	add hl,hl
	add hl,hl
	ld d,h
	ld e,l
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,de                   ; *72
	push hl
	; y = SPRITE_CACHE_Y + row*42
	ld l,c
	ld h,0
	ld d,h
	ld e,l
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl                   ; *32
	add hl,de
	add hl,de
	add hl,de
	add hl,de
	add hl,de
	add hl,de
	add hl,de
	add hl,de
	add hl,de
	add hl,de                   ; *42
	ld de,SPRITE_CACHE_Y
	add hl,de
	ld (spr_tmp+8),hl
	pop hl
	or a
	ret

; A = slot -> HL = SCACHE entry
spc_ent:
	ld l,a
	ld h,0
	add hl,hl
	add hl,hl
	add hl,hl
	ld de,SCACHE
	add hl,de
	ret
; CF=1 if slot (spr_tmp+15) holds key spr_tmp+10..14
spc_chk:
	ld a,(spr_tmp+15)
	call spc_ent
	ld de,spr_tmp+10
	ld b,5
spc_cmp:
	ld a,(de)
	cp (hl)
	jr nz,spc_no
	inc hl
	inc de
	djnz spc_cmp
	ld a,(hl)
	or a
	ret z
	scf
	ret
spc_no:
	or a
	ret

; render the sprite shape for key spr_tmp+10.. into its cache slot
sp_render:
	push iy
	; colours: MC: 01 mc0, 10 colour, 11 mc1 ; hires: 1 colour
	ld a,(spr_tmp+11)
	and 1
	ld (cell_cols),a
	xor a
	ld (cell_cols+1),a
	ld a,(spr_tmp+11)
	and 1
	jr z,spr_hi
	ld a,(spr_tmp+13)
	call fix_slot
	ld (cell_cols+2),a
	ld a,(spr_tmp+12)
	call fix_slot
	ld (cell_cols+3),a
	ld a,(spr_tmp+14)
	call fix_slot
	ld (cell_cols+4),a
	jr spr_cols
spr_hi:
	ld a,(spr_tmp+12)
	call fix_slot
	ld (cell_cols+2),a
spr_cols:
	call nt_build
	; LMMC into the slot
	call spc_pos
	ld (cmdblk+4),hl
	ld hl,(spr_tmp+8)
	ld (cmdblk+6),hl
	ld a,(spr_tmp+6)
	ld l,a
	ld h,0
	ld (cmdblk+8),hl
	ld a,(spr_tmp+7)
	ld l,a
	ld (cmdblk+10),hl
	call lmmc_start
	; source: VIC bank + pointer*64 (Z80 $8000 based)
	ld a,(spr_tmp+10)
	ld l,a
	ld h,0
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl
	ld de,$8000
	add hl,de
	; spr_tmp+11 bit 1 (x-expand) is constant for the whole sprite: test it
	; once here instead of on every one of the 126 spr_nib calls below.
	ld a,(spr_tmp+11)
	bit 1,a
	jp nz,spr_rows_x
	; no y-expansion: stream straight from the nibble table to the VDP
	; (the common case); y-expanded shapes need the row twice -> BUF path
	ld a,(spr_tmp+11)
	bit 2,a
	jp nz,spr_rows_n
	push hl
	pop ix
	ld a,21
	ld (spr_tmp+16),a
	ld c,V_CMD
	ld h,NT/256
spr_dr:
	ld a,(ix+0)
	inc ix
	ld d,a
	and $F0
	rrca
	rrca
	ld l,a
	outi
	outi
	outi
	ld a,d
	and $0F
	add a,a
	add a,a
	ld l,a
	outi
	outi
	outi
	ld a,(ix+0)
	inc ix
	ld d,a
	and $F0
	rrca
	rrca
	ld l,a
	outi
	outi
	outi
	ld a,d
	and $0F
	add a,a
	add a,a
	ld l,a
	outi
	outi
	outi
	ld a,(ix+0)
	inc ix
	ld d,a
	and $F0
	rrca
	rrca
	ld l,a
	outi
	outi
	outi
	ld a,d
	and $0F
	add a,a
	add a,a
	ld l,a
	outi
	outi
	outi
	ld a,(spr_tmp+16)
	dec a
	ld (spr_tmp+16),a
	jp nz,spr_dr
	pop iy
	ret
spr_rows_n:
	ld b,21
spr_row_n:
	push bc
	push hl
	; 3 bytes -> 18 output bytes in BUF (36 px)
	ld ix,BUF
	ld b,3
spr_byte_n:
	ld a,(hl)
	inc hl
	push hl
	ld c,a
	rrca
	rrca
	rrca
	rrca
	call spr_nib_n
	ld a,c
	call spr_nib_n
	pop hl
	djnz spr_byte_n
	; send once (twice for y-expansion)
	ld a,(spr_tmp+11)
	bit 2,a
	call nz,spr_send
	call spr_send
	pop hl
	ld de,3
	add hl,de
	pop bc
	djnz spr_row_n
	pop iy
	ret
spr_rows_x:
	ld b,21
spr_row_x:
	push bc
	push hl
	; 3 bytes -> 36 output bytes in BUF (x-expanded)
	ld ix,BUF
	ld b,3
spr_byte_x:
	ld a,(hl)
	inc hl
	push hl
	ld c,a
	rrca
	rrca
	rrca
	rrca
	call spr_nib_x
	ld a,c
	call spr_nib_x
	pop hl
	djnz spr_byte_x
	; send once (twice for y-expansion)
	ld a,(spr_tmp+11)
	bit 2,a
	call nz,spr_send
	call spr_send
	pop hl
	ld de,3
	add hl,de
	pop bc
	djnz spr_row_x
	pop iy
	ret
spr_send:
	ld hl,BUF
	ld a,(spr_tmp+6)
	srl a
	ld b,a
	ld c,V_CMD
	otir
	ret
; nibble A (low 4 bits) -> 3 bytes at IX
spr_nib_n:
	and $0F
	add a,a
	add a,a
	ld l,a
	ld h,NT/256
	ld a,(hl)
	ld (ix+0),a
	inc l
	ld a,(hl)
	ld (ix+1),a
	inc l
	ld a,(hl)
	ld (ix+2),a
	inc ix
	inc ix
	inc ix
	ret
; nibble A (low 4 bits) -> 6 bytes at IX (x-expanded)
spr_nib_x:
	and $0F
	add a,a
	add a,a
	ld l,a
	ld h,NT/256
	ld e,3
snx_l:
	ld a,(hl)
	and $F0
	ld d,a
	rrca
	rrca
	rrca
	rrca
	or d
	ld (ix+0),a
	ld a,(hl)
	and $0F
	ld d,a
	add a,a
	add a,a
	add a,a
	add a,a
	or d
	ld (ix+1),a
	inc ix
	inc ix
	inc l
	dec e
	jr nz,snx_l
	ret

