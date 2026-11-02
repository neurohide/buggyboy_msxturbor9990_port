; VIC-II -> V9958 renderer.  Lives in its own mapper segment (SEG_RENDER),
; mapped into page 1 and called from the vblank interrupt with interrupts
; enabled, after the C64 IRQs of the frame it draws (vblanks that come while
; it runs only do sound, input and the palette).
;
; GRAPHIC 6 (SCREEN 7), 512x212, 4 bpp.  One C64 multicolour pixel becomes
; three V9958 pixels (one hires pixel 1.5), so the 320 pixel C64 screen is
; 480 pixels wide, which matches the C64's pixel aspect closely.
;
; The clean bitmap and cached sprites live in mapper RAM. Damaged scanlines
; are composed in RAM and uploaded once, avoiding pixel-wise VDP copies and
; the visible erase/redraw gap between overlapping sprites.
;
; Everything that writes the VDP's port $99 twice runs with interrupts off:
; the line interrupt (palette) and the vblank use the same port.
;
; While rendering, the VIC bank is mapped in page 2: C64 $4000 = Z80 $8000.

	org $4000
region_render_start:
	jp render

; ---------------------------------------------------------------- variables
NT:              equ $7000           ; nibble table: 16 x 3 bytes
BUF:             equ $7100           ; cell pixels, line-major, up to 40 cells
VDW:             equ $7900           ; work copy of VDIRTY
CHDIRTY:         equ $7A00           ; per character code
SCACHE:          equ $7B00           ; sprite cache: 16 slots x 16 bytes (see sp_cache)
SPR_MASK:        equ $7C00           ; transparent-nibble masks, 256 bytes
RV:              equ $7F00           ; misc variables (overlaps nothing below $7F00)
SC_SLOTS:        equ 16
DAMAGE:          equ $6500           ; 212 x 16 bits, one per 16-byte span
SP_SOURCE:       equ $6800           ; 16 x (source x, source y) for DRAWN
OLD_DRAWN:       equ $6900           ; last frame's sprite list
OLD_SOURCE:      equ $6980
OLD_KEY:         equ $6A00           ; cache key for each previous sprite
FG:              equ BUF+256        ; one cached sprite scanline

cdw:             equ RV+$00          ; 16
row_full:        equ RV+$10          ; 25
cur_row:         equ RV+$29
row_rec:         equ RV+$2A          ; 2
row_mode:        equ RV+$2C          ; bit0 mc, bit1 bitmap, bit2 blank
row_scr:         equ RV+$2D          ; 2: Z80 address of the row's screen bytes
row_data:        equ RV+$2F          ; 2: Z80 address of char base / bitmap row
row_xoff:        equ RV+$31          ; x shift in SCREEN 7 pixels
row_csel:        equ RV+$32
row_scroff:      equ RV+$33          ; 2: bank offset of screen row (for dirty lookup)
row_bmoff:       equ RV+$35          ; 2: bank offset of bitmap row
stride:          equ RV+$37          ; 2
run_start:       equ RV+$39
run_len:         equ RV+$3A
nt_key:          equ RV+$3B          ; 5: mode, c0, c1, c2, c3
cell_cols:       equ RV+$40          ; 5: mode, c0..c3 of the cell being drawn
chd_cb:          equ RV+$45          ; charset base (high byte) CHDIRTY belongs to, $FF none
any_chd:         equ RV+$46
first_done:      equ RV+$47
slot_of:         equ RV+$48          ; 16: C64 colour -> palette slot (0 = none)
next_slot:       equ RV+$58
celldirty:       equ RV+$59          ; 40
tl_ptr:          equ RV+$81          ; 2: next event record
tl_left:         equ RV+$83          ; events left
rec_cur:         equ RV+$84          ; 2
cmdblk:          equ RV+$86          ; rectangle: SX, SY, DX, DY, NX, NY
spr_n:           equ RV+$9B          ; sprites drawn this frame
spr_tmp:         equ RV+$D0          ; 32 scratch
rgn_rec:         equ RV+$A5          ; 2 record of the sprite region
rgn_lo:          equ RV+$A7          ; 2 first raster line of region
rgn_hi:          equ RV+$A9          ; 2 first raster line after region
coll_acc:        equ RV+$AB
rgn_idx:         equ RV+$AC
sc_frame:        equ RV+$AD          ; sprite cache clock (one tick per frame)
blit_sx:         equ RV+$AE
blit_dx:         equ RV+$AF
blit_srcbytes:   equ RV+$B0
blit_bytes:      equ RV+$B1
blit_rows:       equ RV+$B2
blit_phase:      equ RV+$B3          ; 0 aligned, 1 shift right, 2 shift left
blit_first:      equ RV+$B4          ; destination starts on a low nibble
blit_last:       equ RV+$B5          ; destination ends on a high nibble
flush_y:         equ RV+$B6
flush_x:         equ RV+$B7
flush_bytes:     equ RV+$B8
flush_sprite:    equ RV+$B9
blit_dst:        equ RV+$BA          ; 2: scanline composition pointer
old_spr_n:       equ RV+$BC
flush_mask:      equ RV+$BD          ; 2: remaining spans on this scanline
flush_chunk:     equ RV+$BF
fbw_all:         equ RV+$C0          ; framebuffer_write marks every byte (first frame)
fbw_last:        equ RV+$C1          ; last byte framebuffer_write changed
flush_ptr:       equ RV+$C2          ; 2: DAMAGE word after the line being flushed
dbg_cells:       equ RV+$F0          ; 2: cells drawn last frame
dbg_full:        equ RV+$F2          ; rows fully redrawn last frame
dbg_cnt:         equ RV+$F3          ; 2: running cell count
dbg_rows:        equ RV+$F5          ; 4: bitmask of rows with drawn cells
dbg_ev:          equ $7E00           ; count, base d011, then (line lo, d011) pairs
LTL:             equ $6000           ; local timeline: base + up to TL_MAX events
ltl_count:       equ RV+$F9
rd_any:          equ RV+$FA          ; row-wide (screen/colour) chunks dirty
rd_grp:          equ RV+$FB          ; 5: bitmap 8-cell group chunks dirty
rd_sgrp:         equ $7EF0           ; 5: screen|colour dirty per 8-cell group
rd_cgrp:         equ $7EF5           ; 5: colour dirty per group (scratch)
gb_mode:         equ $7EFA
mode_rows:       equ $7EFB           ; rows whose display mode changed this frame
settle:          equ $7EFC           ; calm renders since a screen change
settle_time:     equ $7EFD           ; renders since a screen change
; drawn sprite lists live in BUF's tail when not rendering cells
DRAWN:           equ $7880           ; 16 x 8: x lo, x hi, y, w lo, w hi, h, sprite #, -
MAX_SPR:         equ 16

; ============================================================================
SHADOW:          equ $C000           ; 1000 cells x 10 bytes in SEG_SHADOW

render:
	call k_map_vic
	ld a,SEG_SHADOW
	ld (cur_p3),a
	out (PORT_P3),a
	ld hl,DAMAGE
	ld de,DAMAGE+1
	ld bc,423
	ld (hl),0
	ldir
	xor a
	ld (fbw_all),a
	ld a,(first_done)
	or a
	call z,render_first
	; take the dirty flags
	di
	ld hl,VDIRTY
	ld de,VDW
	ld bc,256
	ldir
	ld hl,VDIRTY
	ld b,0
r_clr:
	ld (hl),0
	inc hl
	djnz r_clr
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
	ld a,$FF
	ld (chd_cb),a
	xor a
	ld (mode_rows),a
	ld hl,(dbg_cnt)
	ld (dbg_cells),hl
	ld hl,0
	ld (dbg_cnt),hl
	xor a
	ld (dbg_full),a
	call tl_begin
	xor a
rr_loop:
	ld (cur_row),a
	call row_setup
	call row_dirty
	call nz,row_render
	ld a,(cur_row)
	inc a
	cp 25
	jr nz,rr_loop
	call sprites
	call sprite_changes
	call screen_change
	call flush_damage

	ld a,SEG_C3
	ld (cur_p3),a
	out (PORT_P3),a
	jp k_map_c2

render_first:
	ld a,1
	ld (first_done),a
	ld (fbw_all),a
	ld hl,SPR_MASK
	ld b,0
rf_mask:
	ld a,l
	and $F0
	ld c,0
	jr nz,rf_mask_lo
	ld c,$F0
rf_mask_lo:
	ld a,l
	and $0F
	sub 1
	sbc a,a
	and $0F
	or c
	ld (hl),a
	inc l
	djnz rf_mask
	ld hl,row_full
	ld b,25
rf1:
	ld (hl),1
	inc hl
	djnz rf1
	ld a,SEG_FRAME
rf_clear:
	ld (cur_p2),a
	out (PORT_P2),a
	push af
	ld hl,$8000
	ld de,$8001
	ld bc,$3FFF
	ld (hl),0
	ldir
	pop af
	inc a
	cp SEG_FRAME+4
	jr nz,rf_clear
	call k_map_vic
	; border colour around the C64 screen in the clean bitmap
	ld hl,0
	jp border_fill

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
	; DE = x, HL = y, BC = width (even, 512 only from x 0), A = height;
	; colour PAL_BORDER
	ld (blit_rows),a
	srl b
	rr c                        ; byte count (0 means 256)
	ld a,c
	ld (blit_bytes),a
	srl d
	rr e
	ld a,e
	ld (blit_dx),a
	push hl
	ld hl,BUF
	ld b,0
frh_pixels:
	ld (hl),PAL_BORDER*$11
	inc hl
	djnz frh_pixels
	pop hl
frh_row:
	ld a,(blit_bytes)
	ld b,a
	ld a,(blit_dx)
	ld de,BUF
	call framebuffer_write
	inc hl
	ld a,(blit_rows)
	dec a
	ld (blit_rows),a
	jr nz,frh_row
	ret

; Fill the logical clean-buffer rectangle in RAM.
fill_both:
	dec h                       ; y - 256
	jp fill_rect_hl

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
row_setup:
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
	; signature check: D011&$70, D016&$1F, D018
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
	and $1F
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
	ld c,32
chp_l:
	ld a,(hl)
	inc l
	or a
	jr nz,chp_bits
	ld (de),a                   ; eight clean characters
	inc e
	ld (de),a
	inc e
	ld (de),a
	inc e
	ld (de),a
	inc e
	ld (de),a
	inc e
	ld (de),a
	inc e
	ld (de),a
	inc e
	ld (de),a
	inc e
	jr chp_n
chp_bits:
	ld (any_chd),a
	ld b,8
chp_8:
	push af
	and 1                       ; one dirty bit per character
	ld (de),a
	pop af
	rrca
	inc e
	djnz chp_8
chp_n:
	dec c
	jr nz,chp_l
	ret

; ============================================================================
; which cells of the current row must be redrawn -> celldirty[40]
; returns NZ if any
; ============================================================================
row_dirty:
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
	jr rd_cells
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
rdc_loop:
	; at a group start, skip all eight cells when nothing in the group changed
	ld a,c
	and 7
	jr nz,rdc_cell
	push hl
	ld a,c
	rrca
	rrca
	rrca                        ; group (C is a multiple of 8)
	add a,rd_sgrp & 255
	ld l,a
	ld h,rd_sgrp/256
	ld a,(hl)
	or a
	jr nz,rdc_grp_busy
	ld a,(row_mode)
	bit 1,a
	ld a,(any_chd)
	jr z,rdc_grp_test
	ld a,c
	rrca
	rrca
	rrca
	add a,rd_grp & 255
	ld l,a
	ld h,rd_grp/256
	ld a,(hl)
rdc_grp_test:
	or a
	jr nz,rdc_grp_busy
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
	pop hl
	push bc
	ld bc,8
	add hl,bc                   ; screen
	ex de,hl
	add hl,bc                   ; colour RAM
	ex de,hl
	ld bc,80
	add iy,bc                   ; shadow
	ld bc,64
	add ix,bc                   ; bitmap
	pop bc
	ld a,c
	add a,8
	ld c,a
	cp 40
	jp nz,rdc_loop
	ld a,b
	or a
	ret
rdc_grp_busy:
	pop hl
rdc_cell:
	push hl
	ld a,c
	rrca
	rrca
	rrca
	and $1F
	add a,rd_sgrp & 255
	ld l,a
	ld h,rd_sgrp/256
	ld a,(hl)                   ; screen/colour changed in this group
	pop hl
	or a
	jr nz,rdc_cand
	ld a,(row_mode)
	bit 1,a
	jr z,rdc_textc
	push hl
	ld a,c
	and 7
	add a,bittab & 255
	ld l,a
	ld h,bittab/256
	ld a,c
	rrca
	rrca
	rrca
	and $1F
	add a,rd_grp & 255
	push hl
	ld l,a
	ld h,rd_grp/256
	ld a,(hl)                   ; dirty bits of the cell's group
	pop hl
	and (hl)                    ; this cell's bit
	pop hl
	jr nz,rdc_cand
	jp rdc_clean
rdc_textc:
	push hl
	ld l,(hl)
	ld h,CHDIRTY/256
	ld a,(hl)
	pop hl
	or a
	jp z,rdc_clean
rdc_cand:
	ld a,(hl)
	cp (iy+0)
	jp nz,rdc_dirty
	ld a,(de)
	and $0F
	cp (iy+1)
	jp nz,rdc_dirty
	ld a,(row_mode)
	bit 1,a
	jr nz,rdc_bmcmp
	; text: compare the character's 8 bytes
	push hl
	push de
	push bc
	ld l,(hl)
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
rdc_tl:
	ld a,(de)
	cp (hl)
	jr nz,rdc_tdiff
	inc hl
	inc de
	djnz rdc_tl
	pop bc
	pop de
	pop hl
	jp rdc_clean
rdc_tdiff:
	pop bc
	pop de
	pop hl
	jp rdc_dirty
rdc_bmcmp:
	ld a,(ix+0)
	cp (iy+2)
	jp nz,rdc_dirty
	ld a,(ix+1)
	cp (iy+3)
	jp nz,rdc_dirty
	ld a,(ix+2)
	cp (iy+4)
	jp nz,rdc_dirty
	ld a,(ix+3)
	cp (iy+5)
	jp nz,rdc_dirty
	ld a,(ix+4)
	cp (iy+6)
	jp nz,rdc_dirty
	ld a,(ix+5)
	cp (iy+7)
	jp nz,rdc_dirty
	ld a,(ix+6)
	cp (iy+8)
	jp nz,rdc_dirty
	ld a,(ix+7)
	cp (iy+9)
	jp nz,rdc_dirty
rdc_clean:
	xor a
	jr rdc_store
rdc_dirty:
	ld b,1
	ld a,1
rdc_store:
	push hl
	push af
	ld a,c
	add a,celldirty & 255
	ld l,a
	ld h,celldirty/256
	pop af
	ld (hl),a
	pop hl
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
	cp 40
	jp nz,rdc_loop
	ld a,b
	or a
	ret

; 5 group flags (8 bytes each) for offsets HL..HL+39 -> (DE)..(DE+4)
; A = 0: HL is a VIC bank offset (VDW), A = 1: colour RAM offset (cdw)
grp_bits:
	ld (gb_mode),a
	ld b,5
gb_l:
	push bc
	push de
	push hl
	ld a,l
	rrca
	rrca
	rrca
	and 7
	add a,bittab & 255
	ld c,a
	ld b,bittab/256
	ld a,(bc)
	ld b,a                      ; mask
	call chunk_of
	ld l,a
	ld h,VDW/256
	ld a,(gb_mode)
	or a
	jr z,gb_v
	ld a,l
	and 15
	add a,cdw & 255
	ld l,a
	ld h,cdw/256
gb_v:
	ld a,(hl)
	and b
	pop hl
	pop de
	ld (de),a
	inc de
	ld bc,8
	add hl,bc
	pop bc
	djnz gb_l
	ret

; The game is building a new screen when many character rows change their
; display mode at once (text <-> bitmap, display off/on); that never happens
; while racing.  The display stays blank (calm_flips = $FF, the kernel blanks
; at vblank) until the redraws have been small for 10 frames, at most
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
shadow_ptr:
	push de
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
	ld e,c
	ld d,0
	add hl,de                   ; cell index
	add hl,hl
	ld d,h
	ld e,l
	add hl,hl
	add hl,hl
	add hl,de                   ; *10
	ld de,SHADOW
	add hl,de
	pop de
	ret

; record the inputs of the cell being drawn (C = column, HL = data,
; spr_tmp = colour nibble, spr_tmp+1 = screen byte).  Preserves BC.
shadow_store:
	push hl
	call shadow_ptr
	ex de,hl
	ld a,(spr_tmp+1)
	ld (de),a
	inc de
	ld a,(spr_tmp)
	ld (de),a
	inc de
	pop hl
	push bc
	ld bc,8
	ldir
	pop bc
	ret

; HL = bank offset -> A = 64-byte chunk index
chunk_of:
	ld a,l
	rlca
	rlca
	and 3
	push bc
	ld b,a
	ld a,h
	and $3F
	add a,a
	add a,a
	or b
	pop bc
	ret

; ============================================================================
; draw the dirty runs of the current row
; ============================================================================
row_render:
	ld a,(row_mode)
	bit 2,a
	jp nz,row_blank
	ld c,0
rrn_scan:
	ld a,c
	cp 40
	ret nc
	ld hl,celldirty
	add a,l
	ld l,a
	jr nc,rrn1
	inc h
rrn1:
	ld a,(hl)
	or a
	jr nz,rrn_start
	inc c
	jr rrn_scan
rrn_start:
	ld a,c
	ld (run_start),a
	ld b,0
rrn_len:
	inc b
	inc c
	inc hl
	ld a,c
	cp 40
	jr nc,rrn_have
	ld a,(hl)
	or a
	jr nz,rrn_len
rrn_have:
	ld a,b
	ld (run_len),a
	push bc
	call draw_run
	pop bc
	jr rrn_scan

row_blank:
	; display disabled: border colour over the row
	ld a,(cur_row)
	call row_y_clean
	ld de,SCREEN_X
	ld bc,480
	ld a,8
	jp fill_both

; A = row -> HL = y in the clean buffer
row_y_clean:
	ld l,a
	ld h,0
	add hl,hl
	add hl,hl
	add hl,hl
	ld de,CLEAN_Y+SCREEN_Y
	add hl,de
	ret

; Render run_len cells into BUF and update the clean RAM bitmap.
draw_run:
	ld a,(run_len)
	ld b,a
	add a,a
	add a,b
	add a,a                     ; 6k
	ld l,a
	ld h,0
	ld (stride),hl
	ld ix,BUF
	ld a,(run_start)
	ld c,a
dr_cell:
	ld hl,(dbg_cnt)
	inc hl
	ld (dbg_cnt),hl
	push bc
	push ix
	call cell_colours           ; fills cell_cols, returns HL = source bytes
	push hl
	call shadow_store
	pop hl
	push hl
	call nt_build
	pop hl
	pop ix
	push ix
	call cell_pixels
	pop ix
	ld de,6
	add ix,de
	pop bc
	inc c
	djnz dr_cell
	; x = SCREEN_X + 12*start + xoff (even: byte writes; at worst 1/3 of a
	; C64 multicolour pixel off), y = clean row
	ld a,(run_start)
	ld l,a
	ld h,0
	add hl,hl
	add hl,hl                   ; *4
	ld d,h
	ld e,l
	add hl,hl                   ; *8
	add hl,de                   ; *12
	ld de,SCREEN_X
	add hl,de
	ld a,(row_xoff)
	and $FE
	ld e,a
	ld d,0
	add hl,de
	srl h
	rr l
	ld a,l
	ld (spr_tmp+20),a           ; x byte
	ld a,(cur_row)
	call row_y_clean
	dec h                       ; display y
	ld de,BUF
	ld c,8
dr_send:
	push bc
	ld a,(stride)
	ld b,a
	ld a,(spr_tmp+20)
	call framebuffer_write
	inc hl
	pop bc
	dec c
	jr nz,dr_send
	jp csel_fix

; 38-column mode: border over the outer columns of this row
csel_fix:
	ld a,(row_csel)
	or a
	ret nz
	ld a,(row_xoff)
	or a
	jr nz,csf_do
	ld a,(run_start)
	or a
	jr z,csf_do
	ld a,(run_start)
	ld b,a
	ld a,(run_len)
	add a,b
	cp 39
	ret c
csf_do:
	ld a,(cur_row)
	call row_y_clean
	push hl
	ld de,SCREEN_X
	ld bc,12                    ; 7 C64 pixels -> 10.5, round up
	ld a,8
	call fill_both
	pop hl
	ld de,SCREEN_X+480-14       ; 9 C64 pixels -> 13.5
	ld bc,512-(SCREEN_X+480-14)
	ld a,8
	jp fill_both

; ============================================================================
; colours of cell C of the current row -> cell_cols; HL = pixel source
; ============================================================================
cell_colours:
	; colour RAM
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
	ld b,0
	add hl,bc
	ld de,COLOR_RAM
	add hl,de
	ld a,(hl)
	and $0F
	ld (spr_tmp),a              ; colour RAM nibble
	; screen byte
	ld hl,(row_scr)
	add hl,bc
	ld a,(hl)
	ld (spr_tmp+1),a
	ld a,(row_mode)
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
	ld l,c
	ld h,0
	add hl,hl
	push de
	ld de,r_c64_pal
	add hl,de
	pop de
	di
	out (VDP_CTRL),a
	ld a,$90                    ; R#16: palette pointer
	out (VDP_CTRL),a
	ld a,(hl)
	out (VDP_PAL),a
	inc hl
	ld a,(hl)
	out (VDP_PAL),a
	ei
	pop af
	jr fs_done
fs_full:
	ld a,PAL_FIXED              ; out of slots: reuse the first one
fs_done:
	pop bc
	pop hl
	ret

; ============================================================================
; nibble table for cell_cols (mode 1 = multicolour c0..c3, 0 = hires c0/c1)
; NT[n] = 3 bytes = 6 pixels for the 4 source bits of nibble n
; ============================================================================
nt_build:
	ld hl,cell_cols
	ld de,nt_key
	ld b,5
ntb_cmp:
	ld a,(de)
	cp (hl)
	jr nz,ntb_new
	inc hl
	inc de
	djnz ntb_cmp
	ret
ntb_new:
	ld hl,cell_cols
	ld de,nt_key
	ld bc,5
	ldir
	ld a,(nt_key)
	or a
	jr z,ntb_hires
	; multicolour: nibble = fat pixels a (hi 2 bits), b (lo 2 bits)
	; bytes: aa, ab, bb
	ld hl,NT
	ld c,0
ntb_mc:
	ld a,c
	rrca
	rrca
	and 3
	call ntb_col
	ld d,a                      ; a
	ld a,c
	and 3
	call ntb_col
	ld e,a                      ; b
	ld a,d
	add a,a
	add a,a
	add a,a
	add a,a
	ld b,a
	or d
	ld (hl),a
	inc l
	ld a,b
	or e
	ld (hl),a
	inc l
	ld a,e
	add a,a
	add a,a
	add a,a
	add a,a
	or e
	ld (hl),a
	inc l
	inc c
	ld a,c
	cp 16
	jr nz,ntb_mc
	ret
ntb_col:                        ; A = 0..3 -> nt_key[1+A]
	push hl
	ld hl,nt_key+1
	add a,l
	ld l,a
	ld a,(hl)
	pop hl
	ret
ntb_hires:
	; bits h0..h3 (msb first) -> pixels h0, h0|h1, h1, h2, h2|h3, h3
	ld hl,NT
	ld c,0
ntb_h:
	ld a,c
	and 8
	call ntb_bit
	ld d,a                      ; h0
	ld a,c
	and $0C
	call ntb_bit
	ld e,a                      ; h0|h1
	ld a,d
	add a,a
	add a,a
	add a,a
	add a,a
	or e
	ld (hl),a
	inc l
	ld a,c
	and 4
	call ntb_bit
	add a,a
	add a,a
	add a,a
	add a,a
	ld b,a                      ; h1 in high nibble
	ld a,c
	and 2
	call ntb_bit
	or b
	ld (hl),a                   ; h1, h2
	inc l
	ld a,c
	and 3
	call ntb_bit
	add a,a
	add a,a
	add a,a
	add a,a
	ld b,a
	ld a,c
	and 1
	call ntb_bit
	or b
	ld (hl),a                   ; h2|h3, h3
	inc l
	inc c
	ld a,c
	cp 16
	jr nz,ntb_h
	ret
ntb_bit:                        ; Z -> colour 0 (nt_key+1), NZ -> colour 1 (nt_key+2)
	ld a,(nt_key+1)
	ret z
	ld a,(nt_key+2)
	ret

; HL = 8 source bytes, IX = destination in BUF, stride in (stride)
cell_pixels:
	ld b,8
cp_line:
	ld a,(hl)
	inc hl
	exx
	ld c,a
	rrca
	rrca
	rrca
	rrca
	and $0F
	ld l,a
	add a,a
	add a,l
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
	ld a,c
	and $0F
	ld l,a
	add a,a
	add a,l
	ld l,a
	ld a,(hl)
	ld (ix+3),a
	inc l
	ld a,(hl)
	ld (ix+4),a
	inc l
	ld a,(hl)
	ld (ix+5),a
	exx
	ld de,(stride)
	add ix,de
	djnz cp_line
	ret

; ============================================================================
; RAM bitmap and scanline composition
; ============================================================================
; HL = display y, A = x byte -> HL = mapped clean-bitmap address.
; Keeps BC, DE. Mapper changes must also be visible to nested vblanks.
framebuffer_addr:
	push af
	ld a,l
	rlca
	rlca
	and 3
	add a,SEG_FRAME
	ld (cur_p2),a
	out (PORT_P2),a
	pop af
	ld h,l
	ld l,a
	ld a,h
	and $3F
	or $80
	ld h,a
	ret

; HL = display y, A = first byte, B = byte count (0 = 256). Keeps BC, DE, HL.
damage_mark:
	push bc
	push de
	push hl
	ld c,a
	add a,b
	dec a
	rrca
	rrca
	rrca
	rrca
	and 15
	ld e,a
	ld a,c
	rrca
	rrca
	rrca
	rrca
	and 15
	ld c,a
	ld a,e
	sub c
	inc a
	ld b,a
	ld h,0
	add hl,hl
	ld de,DAMAGE
	add hl,de
	ld a,c
	cp 8
	jr c,dm_low
	inc hl
	sub 8
dm_low:
	ld c,a
	push bc
	ld b,a
	inc b
	ld a,$80
dm_bit:
	rlca
	djnz dm_bit
	pop bc
	ld c,a
dm_span:
	or (hl)
	ld (hl),a
	rlc c
	jr nc,dm_same_byte
	inc hl
dm_same_byte:
	ld a,c
	djnz dm_span
dm_done:
	pop hl
	pop de
	pop bc
	ret

; Write B bytes (0 = 256) from DE into the clean bitmap at (A, HL).
; Keeps BC and HL; advances DE and restores the VIC-bank mapping.
; Bytes that are already in the bitmap are not marked as damaged: a VDP
; write costs about 60 R800 cycles on the turbo R, a compare almost nothing.
framebuffer_write:
	push hl
	push bc
	push hl                     ; display y
	ld c,a
	call framebuffer_addr
	ld a,(fbw_all)
	or a
	jr nz,fbw_force
fbw_find:                       ; skip the unchanged head
	ld a,(de)
	cp (hl)
	jr nz,fbw_diff
	inc de
	inc hl
	inc c
	djnz fbw_find
	pop hl                      ; nothing changed
	jr fbw_done
fbw_diff:
	push bc                     ; C = first changed byte
	ld a,c
	ld (fbw_last),a
fbw_copy:
	ld a,(de)
	cp (hl)
	jr z,fbw_same
	ld (hl),a
	ld a,c
	ld (fbw_last),a
fbw_same:
	inc de
	inc hl
	inc c
	djnz fbw_copy
	pop bc
	pop hl                      ; display y
	ld a,(fbw_last)
	sub c
	inc a
	ld b,a                      ; first..last changed byte (0 = 256)
	ld a,c
	call damage_mark
fbw_done:
	call k_map_vic
	pop bc
	pop hl
	ret
fbw_force:                      ; first frame: the bitmap and VRAM may differ
	ex (sp),hl
	ld a,c
	call damage_mark
	pop hl
	ex de,hl
	ld c,b
	ld b,0
	ld a,c
	or a
	jr nz,fbw_ldir
	inc b
fbw_ldir:
	ldir
	ex de,hl
	jr fbw_done

; A = cache slot, L = source y, E = source x byte -> HL = mapped address.
sprite_addr:
	ld b,a
	and 7
	add a,a
	add a,a
	add a,a
	or $C0
	ld d,a
	ld a,b
	rrca
	rrca
	rrca
	and 1
	add a,SEG_SPRITES
	ld (cur_p3),a
	out (PORT_P3),a
	ld h,0
	add hl,hl
	add hl,hl
	add hl,hl                    ; y * 8
	ld b,h
	ld c,l
	add hl,hl
	add hl,hl
	add hl,bc                    ; y * 40
	ld c,e
	ld b,d
	add hl,bc
	ret

; Set the VRAM write address: HL = y, A = x byte. Keeps BC, DE, HL.
vram_wr:
	push af
	ld a,l
	rlca
	rlca
	and 3
	bit 0,h
	jr z,vw_lo
	or 4
vw_lo:
	di
	out (VDP_CTRL),a            ; A16-A14 = y bits 8-6
	ld a,$8E
	out (VDP_CTRL),a
	pop af
	out (VDP_CTRL),a            ; A7-A0
	ld a,l
	and $3F
	or $40
	out (VDP_CTRL),a
	ei
	ret

flush_damage:
	xor a
	ld (flush_y),a
	ld hl,DAMAGE
flush_scan:                     ; HL -> DAMAGE word of flush_y
	ld a,(hl)
	inc hl
	or (hl)
	inc hl
	jr nz,flush_row
	ld a,(flush_y)
	inc a
	ld (flush_y),a
	cp 212
	jr c,flush_scan
	ret
flush_row:
	ld (flush_ptr),hl
	dec hl
	ld d,(hl)
	dec hl
	ld e,(hl)
	ld (flush_mask),de
	xor a
	ld (flush_chunk),a
flush_spans:
	ld hl,(flush_mask)
	ld a,l
	or a
	jr nz,flush_bits
	or h
	jp z,flush_next
	ld l,h                      ; eight clean chunks at once
	ld h,0
	ld a,(flush_chunk)
	add a,8
	ld (flush_chunk),a
flush_bits:
	srl h
	rr l
	ld (flush_mask),hl
	ld a,(flush_chunk)
	ld e,a
	inc a
	ld (flush_chunk),a
	jr nc,flush_spans
	ld a,e
	add a,a
	add a,a
	add a,a
	add a,a
	ld (flush_x),a
	ld b,1
flush_run:
	bit 0,l
	jr z,flush_have
	srl h
	rr l
	inc b
	ld a,(flush_chunk)
	inc a
	ld (flush_chunk),a
	jr flush_run
flush_have:
	ld (flush_mask),hl
	ld a,b
	add a,a
	add a,a
	add a,a
	add a,a
	ld (flush_bytes),a
	ld c,a
	ld b,0
	jr nz,flush_read
	inc b
flush_read:
	ld a,(flush_y)
	ld l,a
	ld h,0
	ld a,(flush_x)
	call framebuffer_addr
	ld a,(flush_x)
	ld e,a
	ld d,BUF/256
	ldir
	xor a
	ld (flush_sprite),a
flush_sprites:
	ld a,(spr_n)
	ld hl,flush_sprite
	cp (hl)
	jr z,flush_send
	ld a,(hl)
	ld l,a
	ld h,0
	add hl,hl
	add hl,hl
	add hl,hl
	ld de,DRAWN
	add hl,de
	push hl
	pop iy
	ld a,(flush_y)
	sub (iy+2)
	jr c,flush_sprite_next
	cp (iy+5)
	call c,compose_if_visible
flush_sprite_next:
	ld hl,flush_sprite
	inc (hl)
	jr flush_sprites
flush_send:
	ld a,(flush_y)
	ld l,a
	ld h,0
	ld a,(flush_x)
	call vram_wr
	ld a,(flush_x)
	ld l,a
	ld h,BUF/256
	ld a,(flush_bytes)
	ld b,a
	ld c,VDP_DATA
	call vram_upload
	jp flush_spans
flush_next:
	ld hl,flush_y
	inc (hl)
	ld a,(hl)
	ld hl,(flush_ptr)
	cp 212
	jp c,flush_scan
	ret

compose_if_visible:
	push af
	ld l,(iy+0)
	ld h,(iy+1)
	ld e,(iy+3)
	ld d,0
	add hl,de
	inc hl
	srl h
	rr l
	ld a,(flush_x)
	ld e,a
	or a
	sbc hl,de
	jr c,civ_skip
	jr z,civ_skip
	ld a,(flush_x)
	ld e,a
	ld a,(flush_bytes)
	ld l,a
	ld h,0
	or a
	jr nz,civ_width
	inc h
civ_width:
	add hl,de
	ld e,(iy+0)
	ld d,(iy+1)
	srl d
	rr e
	or a
	sbc hl,de
	jr c,civ_skip
	jr z,civ_skip
	pop af
	jp compose_sprite
civ_skip:
	pop af
	ret

; Dirty spans are multiples of 16 bytes. Avoid block-repeat I/O on the R800.
vram_upload:
	outi
	outi
	outi
	outi
	outi
	outi
	outi
	outi
	outi
	outi
	outi
	outi
	outi
	outi
	outi
	outi
	jp nz,vram_upload
	ret

; A = row within IY's sprite. Merge its cached pixels into BUF in priority
; order, preserving transparent nibbles and odd left/right edges.
compose_sprite:
	ld b,a
	ld a,(flush_sprite)
	add a,a
	ld l,a
	ld h,SP_SOURCE/256
	ld a,(hl)
	ld (blit_sx),a
	inc hl
	ld a,(hl)
	add a,b
	ld (blit_rows),a
	ld a,(blit_sx)
	and 1
	ld c,a
	ld a,(iy+3)
	add a,c
	inc a
	srl a
	ld (blit_srcbytes),a
	ld a,(iy+0)
	and 1
	ld (blit_first),a
	ld b,a
	ld a,(iy+3)
	add a,b
	ld e,a
	and 1
	ld (blit_last),a
	ld a,e
	inc a
	srl a
	ld (blit_bytes),a
	ld a,b
	xor c
	jr z,blit_aligned
	ld a,1
	bit 0,c
	jr z,blit_aligned
	inc a
blit_aligned:
	ld (blit_phase),a
	ld l,(iy+0)
	ld h,(iy+1)
	srl h
	rr l
	ld h,BUF/256
	ld (blit_dst),hl
	ld a,(blit_sx)
	srl a
	ld e,a
	ld a,(blit_rows)
	ld l,a
	ld a,(iy+7)
	call sprite_addr
	ld de,FG
	ld a,(blit_srcbytes)
	ld c,a
	ld b,0
	ldir
	ex de,hl
	ld (hl),0
	ld a,(blit_phase)
	or a
	jr z,blit_edges
	dec a
	jr nz,blit_left
	ld hl,FG
	ld a,(blit_bytes)
	ld b,a
	xor a
blit_right_loop:
	rrd
	inc hl
	djnz blit_right_loop
	jr blit_edges
blit_left:
	dec hl
	ld a,(blit_srcbytes)
	ld b,a
	xor a
blit_left_loop:
	rld
	dec hl
	djnz blit_left_loop
blit_edges:
	ld a,(blit_first)
	or a
	jr z,blit_tail
	ld a,(FG)
	and $0F
	ld (FG),a
blit_tail:
	ld a,(blit_last)
	or a
	jr z,blit_pixels
	ld a,(blit_bytes)
	dec a
	ld l,a
	ld h,FG/256
	ld a,(hl)
	and $F0
	ld (hl),a
blit_pixels:
	ld hl,FG
	ld ix,(blit_dst)
	ld d,SPR_MASK/256
	ld a,(blit_bytes)
	ld b,a
blit_merge:
	ld e,(hl)
	ld a,(de)
	and (ix+0)
	or (hl)
	ld (ix+0),a
	inc hl
	inc ix
	djnz blit_merge
	ret

; ============================================================================
; sprites
; ============================================================================
; sprites
; ============================================================================
sprites:
	ld hl,sc_frame
	inc (hl)
	ld a,(spr_n)
	ld (old_spr_n),a
	ld hl,DRAWN
	ld de,OLD_DRAWN
	ld bc,128
	ldir
	ld hl,SP_SOURCE
	ld de,OLD_SOURCE
	ld bc,32
	ldir
	ld a,(spr_n)
	or a
	jr z,sprites_start
	ld b,a
	ld ix,DRAWN
	ld de,OLD_KEY
sprites_save_key:
	push bc
	push de
	ld l,(ix+7)
	ld h,0
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl
	ld bc,SCACHE
	add hl,bc
	ld bc,5
	ldir
	pop de
	ld hl,5
	add hl,de
	ex de,hl
	ld bc,8
	add ix,bc
	pop bc
	djnz sprites_save_key
sprites_start:
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
	ret

; Static sprites need no upload unless their background, pixels or position
; changed. A changed sprite damages both its old and new rectangle.
sprite_changes:
	ld a,(old_spr_n)
	ld b,a
	ld a,(spr_n)
	cp b
	jr nc,sch_count
	ld a,b
sch_count:
	or a
	ret z
	ld b,a
	ld c,0
sch_loop:
	push bc
	ld a,(old_spr_n)
	cp c
	jr z,sch_new
	jr c,sch_new
	ld a,(spr_n)
	cp c
	jr z,sch_old
	jr c,sch_old
	call sch_ptrs
	push hl
	push de
	ld b,8
sch_cmp:
	ld a,(de)
	cp (hl)
	jr nz,sch_diff
	inc hl
	inc de
	djnz sch_cmp
	pop de
	pop hl
	ld a,c
	add a,a
	ld l,a
	ld h,SP_SOURCE/256
	add a,OLD_SOURCE & 255
	ld e,a
	ld d,OLD_SOURCE/256
	ld a,(de)
	cp (hl)
	jr nz,sch_both
	inc hl
	inc de
	ld a,(de)
	cp (hl)
	jr nz,sch_both
	call sch_ptrs
	ld de,7
	add hl,de
	ld l,(hl)
	ld h,0
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl
	ld de,SCACHE
	add hl,de
	push hl
	ld a,c
	add a,a
	add a,a
	add a,c
	ld e,a
	ld d,OLD_KEY/256
	ld b,5
sch_key:
	ld a,(de)
	cp (hl)
	jr nz,sch_key_diff
	inc de
	inc hl
	djnz sch_key
	pop hl
	ld l,(hl)                  ; sprite pointer indexes its dirty 64-byte chunk
	ld h,VDW/256
	ld a,(hl)
	or a
	jr z,sch_next
	jr sch_both
sch_key_diff:
	pop hl
	jr sch_both
sch_diff:
	pop de
	pop hl
sch_both:
	call sch_ptrs
	push bc
	push hl
	ex de,hl
	push hl
	pop ix
	call sprite_damage
	pop ix
	call sprite_damage
	pop bc
	jr sch_next
sch_old:
	call sch_ptrs
	ex de,hl
	jr sch_mark
sch_new:
	call sch_ptrs
sch_mark:
	push hl
	pop ix
	call sprite_damage
sch_next:
	pop bc
	inc c
	dec b
	jp nz,sch_loop
	ret
sch_ptrs:
	ld l,c
	ld h,0
	add hl,hl
	add hl,hl
	add hl,hl
	ld de,DRAWN
	add hl,de
	push hl
	ld de,OLD_DRAWN-DRAWN
	add hl,de
	ex de,hl
	pop hl
	ret

sprite_damage:
	ld l,(ix+0)
	ld h,(ix+1)
	srl h
	rr l
	ld c,l
	ld a,(ix+0)
	and 1
	add a,(ix+3)
	inc a
	srl a
	ld b,a
	ld l,(ix+2)
	ld h,0
	ld e,(ix+5)
sd_row:
	ld a,c
	call damage_mark
	inc l
	dec e
	jr nz,sd_row
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
	; only the bounding box of the set pixels is copied
	push hl
	ld a,(spr_tmp+15)
	ld l,a
	ld h,0
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl
	ld de,SCACHE+7
	add hl,de
	ld a,(hl)                   ; x0
	inc hl
	ld b,(hl)                   ; x1
	inc hl
	ld c,a
	sub b
	jr z,spo_none               ; nothing set
	neg
	ld (spr_tmp+6),a            ; width
	ld a,(hl)                   ; y0
	inc hl
	ld b,(hl)                   ; y1
	ld e,a
	neg
	add a,b
	ld (spr_tmp+7),a            ; height
	ld d,0
	ld hl,(spr_tmp+8)
	add hl,de
	ld (spr_tmp+8),hl           ; cache y
	ld hl,(spr_tmp+4)
	add hl,de
	ld (spr_tmp+4),hl           ; screen y
	ld e,c
	ld hl,(spr_tmp+2)
	add hl,de
	ld (spr_tmp+2),hl           ; screen x
	pop hl
	add hl,de                   ; cache x
	jr spo_trim
spo_none:
	pop hl
	ret
spo_trim:
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
	ld (cmdblk+6),hl
	ld l,c
	ld h,0
	ld (cmdblk+10),hl
	ld hl,(spr_tmp+8)
	ld (cmdblk+2),hl
	ld a,(spr_n)
	add a,a
	ld l,a
	ld h,SP_SOURCE/256
	ld a,(cmdblk)
	ld (hl),a
	inc hl
	ld a,(cmdblk+2)
	ld (hl),a
	; collision bounding box in screen coordinates
	call sp_coll
	ld a,(spr_tmp+15)
	ld (ix+7),a                 ; cache slot for scanline composition
	ld hl,spr_n
	inc (hl)
	ret

; --- sprite-sprite collision on tight bounding boxes --------------------------
; This sprite: IX entry (x,y,w,h).
sp_coll:
	ld a,(rgn_idx)
	ld (ix+6),a
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
	; the key in any slot?
	ld hl,SCACHE
	ld c,0
spc_find:
	push hl
	ld de,spr_tmp+10
	ld b,5
spc_cmp:
	ld a,(de)
	cp (hl)
	jr nz,spc_next
	inc hl
	inc de
	djnz spc_cmp
	ld a,(hl)                   ; valid flag
	or a
	jr nz,spc_hit
spc_next:
	pop hl
	ld de,16
	add hl,de
	inc c
	ld a,c
	cp SC_SLOTS
	jr nz,spc_find
	; no: the slot unused for longest gets it
	call spc_victim
	ld a,c
	ld (spr_tmp+15),a
	push hl
	ex de,hl
	ld hl,spr_tmp+10
	ld bc,5
	ldir
	ld a,1
	ld (de),a
	pop hl
	push hl
	call sp_bbox
	call sp_render
	pop hl
	jr spc_stamp
spc_hit:
	pop hl
	ld a,c
	ld (spr_tmp+15),a
	; the game rewrites sprite shapes in place: redraw the slot when the
	; shape's 64 bytes changed (once per frame)
	push hl
	ld a,(spr_tmp+10)
	ld e,a
	ld d,VDW/256
	ld a,(de)
	or a
	jr z,spc_fresh
	ld de,6
	add hl,de
	ld a,(sc_frame)
	cp (hl)
	jr z,spc_fresh
	pop hl
	push hl
	call sp_bbox
	call sp_render
spc_fresh:
	pop hl
spc_stamp:
	ld de,6
	add hl,de
	ld a,(sc_frame)
	ld (hl),a                   ; last use
spc_pos:
	ld hl,0
	ld (spr_tmp+8),hl
	or a
	ret

; least recently used slot (an empty one first) -> C = slot, HL = entry
spc_victim:
	ld hl,SCACHE
	ld bc,SC_SLOTS*256          ; B = count, C = slot
	ld de,0                     ; D = best age, E = best slot
spv_l:
	push hl
	ld a,l
	add a,5
	ld l,a
	ld a,(hl)                   ; valid
	or a
	jr z,spv_free
	inc hl
	ld a,(sc_frame)
	sub (hl)                    ; age
	cp d
	jr c,spv_n
	ld d,a
	ld e,c
spv_n:
	pop hl
	ld a,l
	add a,16
	ld l,a
	jr nc,spv_c
	inc h
spv_c:
	inc c
	djnz spv_l
	ld c,e
	jr spv_ptr
spv_free:
	pop hl
spv_ptr:
	ld l,c
	ld h,0
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl
	ld de,SCACHE
	add hl,de
	ret

; bounding box of the sprite's set pixels, in 3-byte columns and rows (slot
; entry HL +7 x0, +8 x1, +9 y0, +10 y1, in pixels of the cached shape)
sp_bbox:
	push bc
	push hl
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
	add hl,de                   ; sprite data (VIC bank in page 2)
	ld bc,21*256+0              ; B rows, C column bits
	ld de,$FF00                 ; D first row, E last row + 1
spb_row:
	ld a,(hl)
	or a
	jr z,spb_1
	set 0,c
spb_1:
	inc hl
	ld a,(hl)
	or a
	jr z,spb_2
	set 1,c
spb_2:
	inc hl
	ld a,(hl)
	or a
	jr z,spb_3
	set 2,c
spb_3:
	dec hl
	or (hl)
	dec hl
	or (hl)                     ; the row's three bytes
	inc hl
	inc hl
	inc hl
	jr z,spb_next
	ld a,21
	sub b                       ; row index
	inc d
	jr nz,spb_hd
	ld d,a                      ; first set row
	jr spb_e
spb_hd:
	dec d
spb_e:
	inc a
	ld e,a                      ; last set row + 1
spb_next:
	djnz spb_row
	pop hl
	push hl
	ld a,l
	add a,7
	ld l,a
	; columns: lowest and highest set bit of C, 12 pixels each (24 x-expanded)
	ld b,12
	ld a,(spr_tmp+11)
	bit 1,a
	jr z,spb_w
	ld b,24
spb_w:
	xor a
	ld (hl),a                   ; x0
	inc hl
	ld (hl),a                   ; x1 (empty)
	ld a,c
	or a
	jr z,spb_y
	dec hl
	xor a
	bit 0,c
	jr nz,spb_x0
	add a,b
	bit 1,c
	jr nz,spb_x0
	add a,b
spb_x0:
	ld (hl),a
	inc hl
	ld a,b
	add a,a
	add a,b                     ; 3 columns
	bit 2,c
	jr nz,spb_x1
	sub b
	bit 1,c
	jr nz,spb_x1
	sub b
spb_x1:
	ld (hl),a
spb_y:
	inc hl
	ld a,(spr_tmp+11)
	bit 2,a                     ; y-expanded: rows count twice
	ld a,d
	jr z,spb_y0
	add a,a
spb_y0:
	ld (hl),a                   ; y0
	inc hl
	ld a,(spr_tmp+11)
	bit 2,a
	ld a,e
	jr z,spb_y1
	add a,a
spb_y1:
	ld (hl),a                   ; y1
	pop hl
	pop bc
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
	; Into the RAM slot, line by line.
	ld hl,0
	ld (spr_tmp+16),hl          ; line
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
	ld b,21
spr_row:
	push bc
	push hl
	; 3 bytes -> 18 output bytes in BUF (36 px), x-expanded: 36 bytes
	ld ix,BUF
	ld b,3
spr_byte:
	ld a,(hl)
	inc hl
	push hl
	ld c,a
	rrca
	rrca
	rrca
	rrca
	call spr_nib
	ld a,c
	call spr_nib
	pop hl
	djnz spr_byte
	; send once (twice for y-expansion)
	ld a,(spr_tmp+11)
	bit 2,a
	call nz,spr_send
	call spr_send
	pop hl
	ld de,3
	add hl,de
	pop bc
	djnz spr_row
	pop iy
	ret
spr_send:
	ld hl,(spr_tmp+16)
	inc hl
	ld (spr_tmp+16),hl
	dec hl
	ld e,0
	ld a,(spr_tmp+15)
	call sprite_addr
	ex de,hl
	ld hl,BUF
	ld a,(spr_tmp+6)
	srl a
	ld c,a
	ld b,0
	ldir
	ret
; nibble A (low 4 bits) -> 3 bytes at IX (6 bytes if x-expanded)
spr_nib:
	and $0F
	ld l,a
	add a,a
	add a,l
	ld l,a
	ld h,NT/256
	ld a,(spr_tmp+11)
	bit 1,a
	jr nz,spr_nib_x
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
spr_nib_x:
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

; ------------------------------------------------------------------ tables
row40:
	dw 0,40,80,120,160,200,240,280,320,360,400,440,480,520,560,600
	dw 640,680,720,760,800,840,880,920,960
row320:
	dw 0,320,640,960,1280,1600,1920,2240,2560,2880,3200,3520,3840,4160
	dw 4480,4800,5120,5440,5760,6080,6400,6720,7040,7360,7680
row_sigs:
	defs 25*4,$FF
; colour folding: brown -> orange, light red -> red, dark grey -> grey,
; light green -> green
col_fold:
	db 0, 1, 2, 3, 4, 5, 6, 7, 8, 8, 2, 12, 12, 5, 14, 15
; C64 colours as V9958 palette bytes (copy of c64_pal: page 2 holds the VIC
; bank here)
r_c64_pal:
	db $00,$00, $77,$07, $52,$02, $36,$07
	db $57,$02, $31,$06, $17,$02, $72,$07
	db $51,$03, $30,$02, $74,$04, $33,$03
	db $44,$04, $54,$07, $37,$04, $66,$06

region_render_end:
	defs LTL-region_render_end,0
	defs NT-LTL,0
