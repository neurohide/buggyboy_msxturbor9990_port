; Dirty group checks, scrolling detection, and cell comparisons.
; ============================================================================
; which cells of the current row must be redrawn -> celldirty[40]
; returns NZ if any
; ============================================================================
renderer_find_dirty_cells:
	ld a,(cur_row)
	ld hl,row_full
	add a,l
	ld l,a
	ld a,(hl)
	ld (hl),0
	or a
	jr z,rd_check
	ld hl,dbg_full
	inc (hl)
	ld hl,celldirty
	ld b,40
rd_all:
	ld (hl),1
	inc hl
	djnz rd_all
	or 1
	ret
rd_check:
	; A fine offset change may move the row even when no source bytes changed.
	ld a,(row_xchg)
	or a
	jp nz,rd_coarse
	ld a,(row_edge)
	or a
	jr z,rd_check2
	xor a
	ld (row_edge),a
	ld hl,celldirty
	ld b,40
rd_clr:
	ld (hl),a
	inc hl
	djnz rd_clr
	call rd_check2              ; rewrites celldirty only if it compares cells
	ld a,1
	ld (celldirty+0),a
	ld (celldirty+1),a
	ld (celldirty+38),a
	ld (celldirty+39),a
	or a                        ; NZ
	ret
rd_check2:
	; colour RAM chunk index = (r*40+c)>>6, screen chunk = (scroff+c)>>6
	ld a,(row_mode)
	bit 2,a
	jr z,rd_live
	xor a                       ; blank row, unchanged
	ret
rd_live:
	; quick reject: nothing changed in the row's screen, colour or data chunks
	ld hl,(row_scroff)
	ld de,39
	call chunks_any
	jr nz,rd_groups
	ld a,(cur_row)
	ld l,a
	ld h,0
	add hl,hl
	ld de,row40
	add hl,de
	ld a,(hl)
	inc hl
	ld h,(hl)
	ld l,a
	call chunk_of
	and 15
	ld e,a
	ld d,0
	ld hl,cdw
	add hl,de
	ld a,(hl)
	inc hl
	or (hl)
	jr nz,rd_groups
	ld a,(row_mode)
	bit 1,a
	jr nz,rd_qbm
	ld a,(any_chd)
	or a
	ret z
	jr rd_groups
rd_qbm:
	ld hl,(row_bmoff)
	ld de,319
	call chunks_any
	ret z
rd_groups:
	; per 8-cell group: screen or colour bytes changed (rows start 8-aligned)
	ld hl,(row_scroff)
	ld de,rd_sgrp
	xor a
	call grp_bits
	ld a,(cur_row)
	ld l,a
	ld h,0
	add hl,hl
	ld de,row40
	add hl,de
	ld a,(hl)
	inc hl
	ld h,(hl)
	ld l,a
	ld de,rd_cgrp
	ld a,1
	call grp_bits
	; merge colour into screen groups, note if anything is set
	ld hl,rd_sgrp
	ld b,5
	ld c,0
rdm_l:
	ld a,l
	add a,5                     ; rd_cgrp = rd_sgrp + 5, same page
	ld e,a
	ld d,h
	ld a,(de)
	or (hl)
	ld (hl),a
	or c
	ld c,a
	inc hl
	djnz rdm_l
	ld a,c
	ld (rd_any),a
	ld a,(row_mode)
	bit 1,a
	jr nz,rd_bmprep
	ld a,(any_chd)
	ld hl,rd_any
	or (hl)
	ret z                       ; text row: nothing changed
	jr rd_coarse
rd_bmprep:
	; a bitmap row is 320 bytes = 5 aligned chunks of 8 cells each
	ld hl,(row_bmoff)
	call chunk_of
	ld l,a
	ld h,VDW/256
	ld de,rd_grp
	ld bc,5*256
rdg_l:
	ld a,(hl)
	ld (de),a
	or c
	ld c,a
	inc l
	inc de
	djnz rdg_l
	ld a,(rd_any)
	or c
	ret z
rd_coarse:
	; the horizon scrolls by whole cells: when the row matches its shadow
	; moved by k columns, move the drawn row and the shadow instead, then
	; compare every cell (the dirty groups no longer describe what is drawn)
	call row_coarse
	jp z,rd_cells
	ld a,$FF
	ld hl,rd_sgrp
	ld b,5
rdk_l:
	ld (hl),a
	inc hl
	djnz rdk_l
	ld hl,rd_grp
	ld b,5
rdk_l2:
	ld (hl),a
	inc hl
	djnz rdk_l2
	call rd_cells
	; the 38-column border drawn over cells 0 and 39 moved inwards
	ld a,1
	ld hl,celldirty
	ld (hl),a
	inc hl
	ld (hl),a
	inc hl
	ld (hl),a
	ld hl,celldirty+37
	ld (hl),a
	inc hl
	ld (hl),a
	inc hl
	ld (hl),a
	or a                        ; NZ
	ret

; Z = no whole-cell move.  NZ: the row was moved by k (+-1, +-2) columns,
; in VRAM (one LMMM) and in SHADOW.  Probes columns 10, 20 and 30.
row_coarse:
	ld a,(row_xchg)
	or a
	jr z,rc_no                  ; a whole-cell scroll comes with an xscroll wrap
	ld a,(row_mode)
	bit 2,a
	jr nz,rc_no                 ; blank row
	ld d,0
	call rc_try
	jr z,rc_no                  ; unmoved
	ld d,1
	call rc_try
	jr z,rc_go
	ld d,-1
	call rc_try
	jr z,rc_go
	ld d,2
	call rc_try
	jr z,rc_go
	ld d,-2
	call rc_try
	jr z,rc_go
rc_no:
	; No whole-cell match: still apply the deferred fine pixel displacement.
	ld a,(row_xchg)
	or a
	ret z
	ld b,0                      ; fine-only move keeps the old 480-pixel width
	call rc_fine
	or 1
	ret
rc_go:
	push de
	; Combine the coarse cell shift with the deferred fine pixel delta.
	ld a,d
	add a,a
	add a,d
	add a,a
	add a,a                     ; 12*k
	ld b,a
	ld a,(row_xchg)
	add a,b
	ld (row_xchg),a             ; combined signed pixel displacement
	ld b,1                      ; coarse move clips the exposed edge
	call rc_fine
	; Shadow: retain the original whole-cell k for its memmove.
	jp rc_shadow

; Apply row_xchg pixels as one overlap-safe LMMM, using current cell origin.
rc_fine:
	ld a,(row_xchg)
	or a
	ret z
	push ix
	push bc                     ; B selects clipped (coarse) versus full width
	ld a,(cur_row)
	call row_y_clean            ; also marks the row for the page sync
	ld (cmdblk+2),hl
	ld (cmdblk+6),hl
	ld hl,8
	ld (cmdblk+10),hl
	ld a,(row_xchg)
	ld b,a
	ld a,b
	bit 7,a
	jr z,rcf_abs
	neg
rcf_abs:
	ld c,a
	ld e,c
	ld d,0
	pop bc
	ld hl,480
	ld a,b
	or a
	jr z,rcf_width
	xor a
	sbc hl,de
rcf_width:
	ld (cmdblk+8),hl            ; NX = 480 or 480 - |displacement|
	ld a,(row_xoff)
	ld c,a
	ld b,0
	ld hl,SCREEN_X
	add hl,bc                   ; current cell 0 origin
	ld a,(row_xchg)
	bit 7,a
	jr nz,rcf_left
	push hl
	ld de,479
	add hl,de
	ld (cmdblk+4),hl            ; DX = right edge
	ld a,(row_xchg)
	ld c,a
	ld b,0
	or a
	sbc hl,bc
	ld (cmdblk+0),hl            ; SX = DX - displacement
	pop hl
	ld a,4                      ; backwards overlap copy
	jr rcf_cmd
rcf_left:
	ld (cmdblk+4),hl            ; DX = left edge
	ld a,(row_xchg)
	neg
	ld e,a
	ld d,0
	add hl,de
	ld (cmdblk+0),hl            ; SX = DX + |displacement|
	xor a                       ; forwards overlap copy
rcf_cmd:
	ld (cmdblk+12),a            ; ARG
	ld a,$0C
	ld (cmdblk+13),a
	ld a,$FF
	ld (cmdblk+14),a
	ld (cmdblk+15),a
	ld a,$40                    ; LMMM
	ld (cmdblk+20),a
	call v_send_cmd
	ld a,(row_csel)
	or a
	jr nz,rcf_done
	inc a
	ld (row_edge),a
rcf_done:
	pop ix
	ret

rc_shadow:
	; shadow: 10 bytes per cell
	pop de                      ; D = k
	ld a,d
	bit 7,a
	jr z,rc_sr
	neg
	ld d,a
	call rc_len                 ; BC = (40-|k|)*10, DE = |k|*10
	ld hl,(row_shad)
	push hl
	add hl,de
	pop de
	ldir                        ; left: entry c = entry c+|k|
	or 1
	ret
rc_sr:
	call rc_len
	ld hl,(row_shad)
	push hl
	push de
	ld de,399
	add hl,de
	pop de
	ex de,hl                    ; DE = last byte, HL = |k|*10
	pop hl
	push de
	add hl,bc
	dec hl                      ; HL = row_shad + (40-k)*10 - 1
	pop de
	lddr                        ; right: entry c = entry c-k
	or 1
	ret
rc_len:                         ; D = |k| -> DE = |k|*10, BC = 400 - DE
	ld a,d
	add a,a
	ld e,a
	add a,a
	add a,a
	add a,e
	ld e,a
	ld d,0
	ld hl,400
	or a
	sbc hl,de
	ld b,h
	ld c,l
	ret

; D = k: Z if probe columns 10, 20, 30 equal their shadow entries at c-k
rc_try:
	ld c,10
	call rc_t1
	ret nz
	ld c,20
	call rc_t1
	ret nz
	ld c,30
rc_t1:
	push de
	push bc
	ld a,c
	sub d
	ld c,a
	call shadow_ptr
	push hl
	pop iy
	pop bc
	push bc
	call rc_cmp
	pop bc
	pop de
	ret

; C = column, IY = shadow entry: Z if the cell's inputs equal it
rc_cmp:
	ld b,0
	ld hl,(row_scr)
	add hl,bc
	ld a,(hl)
	cp (iy+0)
	ret nz
	ld e,a
	ld hl,(row_cram)
	add hl,bc
	ld a,(hl)
	and $0F
	cp (iy+1)
	ret nz
	ld a,(row_mode)
	bit 1,a
	ld l,c                      ; bitmap: 8 bytes per column
	jr nz,rc_b
	ld l,e                      ; text: 8 bytes per character
rc_b:
	ld h,0
	add hl,hl
	add hl,hl
	add hl,hl
	ld de,(row_data)
	add hl,de
	push iy
	pop de
	inc de
	inc de
	ld b,8
rc_l:
	ld a,(de)
	cp (hl)
	ret nz
	inc hl
	inc de
	djnz rc_l
	ret

; candidate cells are compared with what was drawn last (SHADOW)
rd_cells:
	ld c,0
	call shadow_ptr
	push hl
	pop iy                      ; IY -> shadow of cell 0
	ld a,(cur_row)
	ld l,a
	ld h,0
	add hl,hl
	ld de,row40
	add hl,de
	ld e,(hl)
	inc hl
	ld d,(hl)
	ld hl,COLOR_RAM
	add hl,de
	ex de,hl                    ; DE -> colour RAM
	ld ix,(row_data)            ; bitmap data (bitmap rows)
	ld hl,(row_scr)             ; HL -> screen
	ld bc,0                     ; B = any dirty, C = column
	; row_mode bit 1 (text/bitmap) is constant for all 40 cells of this row:
	; test it once here instead of on every rdc_loop/rdc_cand iteration below.
	ld a,(row_mode)
	bit 1,a
	jp nz,rdc_loop_b
	ld ix,celldirty             ; text mode never uses IX for bitmap data
rdc_loop_t:                     ; group start (C = 0, 8 .. 32), B = any dirty
	ld a,c
	ld (rdc_gs),a
	rrca
	rrca
	rrca
	add a,rd_sgrp & 255
	ld l,a
	ld h,rd_sgrp/256
	ld a,(hl)
	ld (rdc_gf),a
	ld a,c
	add a,celldirty & 255
	ld l,a
	ld h,celldirty/256
	xor a
	ld (hl),a
	inc l
	ld (hl),a
	inc l
	ld (hl),a
	inc l
	ld (hl),a
	inc l
	ld (hl),a
	inc l
	ld (hl),a
	inc l
	ld (hl),a
	inc l
	ld (hl),a
	ld a,(rdc_gf)
	or a
	jr nz,rdt_all
	ld a,(any_chd)
	or a
	jr z,rdt_gend               ; no character changed: all 8 clean
	; screen and colour unchanged: only cells showing a changed character
	ld hl,(row_scr)
	ld e,c
	ld d,0
	add hl,de
rdt_cl:
	ld a,(hl)
	push hl
	ld l,a
	ld h,CHDIRTY/256
	ld a,(hl)
	or a
	call nz,rdt_one
	pop hl
	inc hl
	inc c
	ld a,c
	and 7
	jr nz,rdt_cl
	jr rdt_next
rdt_all:                        ; screen or colour changed: all 8 are candidates
	push bc
	ld b,0
	ld l,c
	ld h,b
	add hl,hl
	push hl
	add hl,hl
	add hl,hl
	pop de
	add hl,de                   ; 10c
	ld de,(row_shad)
	add hl,de
	push hl
	pop iy
	ld hl,(row_cram)
	add hl,bc
	ex de,hl                    ; DE = colour RAM
	ld hl,(row_scr)
	add hl,bc                   ; HL = screen
	pop bc
rdt_al:
	ld a,(hl)
	cp (iy+0)
	jr nz,rdt_ad
	ld a,(de)
	and $0F
	cp (iy+1)
	jr nz,rdt_ad
	push hl
	ld l,(hl)
	ld h,CHDIRTY/256
	ld a,(hl)
	pop hl
	or a
	jr z,rdt_an                 ; same character, unchanged bytes
	push hl
	push de
	call rdt_one                ; changed character: compare its bytes
	pop de
	pop hl
	jr rdt_an
rdt_ad:
	ld b,1
	push hl
	ld a,c
	add a,celldirty & 255
	ld l,a
	ld h,celldirty/256
	ld (hl),1
	pop hl
rdt_an:
	inc hl
	inc de
	push de
	ld de,10
	add iy,de
	pop de
	inc c
	ld a,c
	and 7
	jr nz,rdt_al
	jr rdt_next
rdt_gend:
	ld a,c
	add a,8
	ld c,a
rdt_next:
	ld a,c
	cp 40
	jp nz,rdc_loop_t
	ld a,b
	or a
	ret

; text cell C vs its shadow: mark it in celldirty and B when it differs (C kept)
rdt_one:
	push bc
	ld b,0
	ld hl,(row_scr)
	add hl,bc
	ld e,(hl)                   ; character
	ld hl,(row_cram)
	add hl,bc
	ld a,(hl)
	and $0F
	ld d,a                      ; colour
	ld l,c
	ld h,b
	add hl,hl
	push hl
	add hl,hl
	add hl,hl
	pop bc
	add hl,bc                   ; 10c
	ld bc,(row_shad)
	add hl,bc
	ld a,e
	cp (hl)
	jr nz,rdt_d
	inc hl
	ld a,d
	cp (hl)
	jr nz,rdt_d
	inc hl
	; same character and colour: its 8 bytes only matter if they changed
	ld c,e
	ld b,CHDIRTY/256
	ld a,(bc)
	or a
	jr z,rdt_s
	ex de,hl                    ; DE = shadow bytes
	ld l,c
	ld h,0
	add hl,hl
	add hl,hl
	add hl,hl
	ld bc,(row_data)
	add hl,bc
	ld b,8
rdt_l:
	ld a,(de)
	cp (hl)
	jr nz,rdt_d
	inc hl
	inc de
	djnz rdt_l
rdt_s:
	pop bc
	ret
rdt_d:
	pop bc
	ld b,1
	ld a,c
	add a,celldirty & 255
	ld l,a
	ld h,celldirty/256
	ld (hl),1
	ret
rdc_loop_b:                     ; group start (C = 0, 8 .. 32), B = any dirty
	ld a,c
	ld (rdc_gs),a
	rrca
	rrca
	rrca
	ld e,a
	ld d,0
	ld hl,rd_sgrp
	add hl,de
	ld a,(hl)
	ld (rdc_gf),a
	ld hl,rd_grp
	add hl,de
	ld a,(hl)
	ld (rdc_bg),a
	ld a,c
	add a,celldirty & 255
	ld l,a
	ld h,celldirty/256
	xor a
	ld (hl),a
	inc l
	ld (hl),a
	inc l
	ld (hl),a
	inc l
	ld (hl),a
	inc l
	ld (hl),a
	inc l
	ld (hl),a
	inc l
	ld (hl),a
	inc l
	ld (hl),a
	ld a,(rdc_gf)
	or a
	jr nz,rdb_all
	; screen and colour unchanged: only cells whose bitmap bytes were
	; written can differ, visit just those
rdb_bit:
	ld a,(rdc_bg)
	or a
	jr z,rdb_gend
	srl a
	ld (rdc_bg),a
	call c,rdb_one
	inc c
	jr rdb_bit
rdb_gend:
	ld a,(rdc_gs)
	add a,8
	ld c,a
	cp 40
	jp nz,rdc_loop_b
	ld a,b
	or a
	ret
rdb_all:                        ; screen or colour changed: all 8 are candidates
	call rdb_ptrs
rdb_al:
	call rdb_cmp
	or a
	jr z,rdb_ac
	ld b,1
	push hl
	ld a,c
	add a,celldirty & 255
	ld l,a
	ld h,celldirty/256
	ld (hl),1
	pop hl
rdb_ac:
	inc hl
	inc de
	push de
	ld de,10
	add iy,de
	ld de,8
	add ix,de
	pop de
	inc c
	ld a,c
	and 7
	jr nz,rdb_al
	ld a,c
	cp 40
	jp nz,rdc_loop_b
	ld a,b
	or a
	ret

; cell C: compare, mark it in celldirty and B when it differs (C kept).
; Bitmap bytes first: if they differ the cell is dirty whatever the colours.
rdb_one:
	push bc
	ld b,0
	ld l,c
	ld h,b
	add hl,hl
	ld d,h
	ld e,l                      ; 2c
	add hl,hl
	add hl,hl                   ; 8c
	push hl
	add hl,de
	ld de,(row_shad)
	add hl,de
	ex de,hl                    ; DE = shadow entry
	pop hl
	ld bc,(row_data)
	add hl,bc                   ; HL = bitmap bytes
	inc de
	inc de
	ld b,8
rbo_l:
	ld a,(de)
	cp (hl)
	jr nz,rbo_dirty
	inc hl
	inc de
	djnz rbo_l
	pop bc
	push bc
	call rdb_ptrs               ; same bytes: the colours decide
	call rdb_cmp
	pop bc
	or a
	ret z
	jr rbo_mark
rbo_dirty:
	pop bc
rbo_mark:
	ld b,1
	ld a,c
	add a,celldirty & 255
	ld l,a
	ld h,celldirty/256
	ld (hl),1
	ret

; C = column -> HL screen, DE colour RAM, IX bitmap bytes, IY shadow (BC kept)
rdb_ptrs:
	push bc
	ld b,0
	ld l,c
	ld h,b
	add hl,hl
	ld d,h
	ld e,l                      ; 2c
	add hl,hl
	add hl,hl                   ; 8c
	push hl
	add hl,de                   ; 10c
	ld de,(row_shad)
	add hl,de
	push hl
	pop iy
	pop hl
	ld de,(row_data)
	add hl,de
	push hl
	pop ix
	ld hl,(row_cram)
	add hl,bc
	ex de,hl
	ld hl,(row_scr)
	add hl,bc
	pop bc
	ret

; cell at HL/DE/IX vs its shadow IY: A = 1 differs, 0 same (pointers kept)
rdb_cmp:
	ld a,(hl)
	cp (iy+0)
	jr nz,rdb_cdiff
	ld a,(de)
	and $0F
	cp (iy+1)
	jr nz,rdb_cdiff
	ld a,(ix+0)
	cp (iy+2)
	jr nz,rdb_d
	ld a,(ix+1)
	cp (iy+3)
	jr nz,rdb_d
	ld a,(ix+2)
	cp (iy+4)
	jr nz,rdb_d
	ld a,(ix+3)
	cp (iy+5)
	jr nz,rdb_d
	ld a,(ix+4)
	cp (iy+6)
	jr nz,rdb_d
	ld a,(ix+5)
	cp (iy+7)
	jr nz,rdb_d
	ld a,(ix+6)
	cp (iy+8)
	jr nz,rdb_d
	ld a,(ix+7)
	cp (iy+9)
	jr nz,rdb_d
	xor a
	ret
rdb_cdiff:                      ; colours differ: same only for an all-$00 multicolour cell
	ld a,(row_mode)
	rrca
	jr nc,rdb_d
	ld a,(ix+0)
	or (ix+1)
	or (ix+2)
	or (ix+3)
	or (ix+4)
	or (ix+5)
	or (ix+6)
	or (ix+7)
	or (iy+2)
	or (iy+3)
	or (iy+4)
	or (iy+5)
	or (iy+6)
	or (iy+7)
	or (iy+8)
	or (iy+9)
	jr nz,rdb_d
	ld a,(hl)
	ld (iy+0),a
	ld a,(de)
	and $0F
	ld (iy+1),a
	xor a
	ret
rdb_d:
	ld a,1
	ret

; 5 group flags (8 bytes each) for offsets HL..HL+39 -> (DE)..(DE+4)
; A = 0: HL is a VIC bank offset (VDW), A = 1: colour RAM offset (cdw)
grp_bits:
	push af
	ld a,l
	rrca
	rrca
	rrca
	and 7
	add a,bittab & 255
	ld c,a
	ld b,bittab/256
	ld a,(bc)
	ld c,a                      ; C = mask of the first group's 8-byte block
	call chunk_of
	ld l,a
	ld h,VDW/256
	pop af
	or a
	jr z,gb_go
	ld a,l
	and 15
	add a,cdw & 255
	ld l,a
	ld h,cdw/256
gb_go:
	ld b,5
gb_l:                           ; next group = next bit (next byte after bit 7)
	ld a,(hl)
	and c
	ld (de),a
	inc de
	rlc c
	jr nc,gb_n
	inc l                       ; VDW / cdw are page aligned
gb_n:
	djnz gb_l
	ret

; The game is building a new screen when many character rows change their
; display mode at once (text <-> bitmap, display off/on); that never happens
; while racing.  The display stays blank (calm_flips = $FF, the kernel blanks
; at the page flip) until the redraws have been small for 10 frames, at most
; ~3 seconds, so the half-built screen is not shown.
screen_change:
	ld hl,blank_req
	ld a,(hl)
	ld (hl),0
	or a
	jr nz,sc_new
	ld a,(mode_rows)
	cp 5
	jr c,sc_nochange
sc_new:
	ld a,$FF
	ld (calm_flips),a
	xor a
	ld (settle),a
	ld (settle_time),a
	ret
sc_nochange:
	ld a,(calm_flips)
	cp $FF
	ret nz
	ld hl,settle_time
	inc (hl)
	ld a,(hl)
	cp 150
	jr nc,sc_done
	ld hl,(dbg_cnt)
	ld de,60
	or a
	sbc hl,de
	ld hl,settle
	jr c,sc_calm
	ld (hl),0
	ret
sc_calm:
	inc (hl)
	ld a,(hl)
	cp 10
	ret c
sc_done:
	ld a,1                      ; show the next page after this one
	ld (calm_flips),a
	ret

; NZ if any VDW chunk covering bank offsets HL..HL+DE is dirty
chunks_any:
	push hl
	add hl,de
	call chunk_of
	ld e,a                      ; last chunk
	pop hl
	call chunk_of               ; first chunk
	ld l,a
	ld h,VDW/256
	ld a,e
	sub l
	inc a
	ld b,a
	xor a
cha_l:
	or (hl)
	inc l
	djnz cha_l
	or a
	ret

; HL -> shadow record of cell C of the current row (preserves BC)
shadow_ptr:                     ; C = column -> HL = its SHADOW entry
	push de
	ld l,c
	ld h,0
	add hl,hl
	ld d,h
	ld e,l
	add hl,hl
	add hl,hl
	add hl,de                   ; c*10
	ld de,(row_shad)
	add hl,de
	pop de
	ret

; record the inputs of the cell being drawn (C = column, HL = data,
; spr_tmp = colour nibble, spr_tmp+1 = screen byte).  Preserves BC.
shadow_store:
	push hl
	ld hl,(dr_shad)
	ex de,hl
	ld a,(spr_tmp+1)
	ld (de),a
	inc de
	ld a,(spr_tmp)
	ld (de),a
	inc de
	pop hl
	push bc
	ldi
	ldi
	ldi
	ldi
	ldi
	ldi
	ldi
	ldi
	pop bc
	ld (dr_shad),de             ; LDI advanced source and shadow by 8 bytes
	ret

; HL = bank offset -> A = 64-byte chunk index
chunk_of:
	push hl
	add hl,hl
	add hl,hl                   ; H = (offset & $3FC0) >> 6
	ld a,h
	pop hl
	ret

