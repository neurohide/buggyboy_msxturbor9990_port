; VIC-II -> V9958 renderer.  Lives in its own mapper segment (SEG_RENDER),
; mapped into page 1 and called from the vblank interrupt with interrupts
; enabled (the next vblanks may nest: they run the C64 IRQs of later frames).
;
; GRAPHIC 6 (SCREEN 7), 512x212, 4 bpp.  One C64 multicolour pixel becomes
; three V9958 pixels (one hires pixel 1.5), so the 320 pixel C64 screen is
; 480 pixels wide, which matches the C64's pixel aspect closely.
;
;   y 0..211     display (page 0, the only one shown: no double buffering)
;   y 212..253   sprite shape cache, 7 slots of 72x42
;   y 256..467   clean playfield (no sprites): dirty cells are written here by
;                the CPU and copied to the display by the VDP; sprites are
;                erased from here
;   y 468..509   sprite shape cache, 7 more slots
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
SCACHE:          equ $7B00           ; sprite cache: 14 slots x 16 bytes (see sp_cache)
RV:              equ $7F00           ; misc variables (overlaps nothing below $7F00)
SC_SLOTS:        equ 14              ; 2 rows of 7 in VRAM

cdw:             equ RV+$00          ; 16
row_full:        equ RV+$10          ; 25
cur_row:         equ RV+$29
row_rec:         equ RV+$2A          ; 2
row_mode:        equ RV+$2C          ; bit0 mc, bit1 bitmap, bit2 blank
row_scr:         equ RV+$2D          ; 2: Z80 address of the row's screen bytes
row_data:        equ RV+$2F          ; 2: Z80 address of char base / bitmap row
row_xoff:        equ RV+$31          ; x shift in V9990 pixels
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
cmdblk:          equ RV+$86          ; 15: R#32..R#46
spr_n:           equ RV+$9B          ; sprites drawn this frame
spr_tmp:         equ RV+$D0          ; 32 scratch
rgn_rec:         equ RV+$A5          ; 2 record of the sprite region
rgn_lo:          equ RV+$A7          ; 2 first raster line of region
rgn_hi:          equ RV+$A9          ; 2 first raster line after region
coll_acc:        equ RV+$AB
rgn_idx:         equ RV+$AC
sc_frame:        equ RV+$AD          ; sprite cache clock (one tick per frame)
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
	call screen_change

	ld a,SEG_C3
	ld (cur_p3),a
	out (PORT_P3),a
	jp k_map_c2

render_first:
	ld a,1
	ld (first_done),a
	ld hl,row_full
	ld b,25
rf1:
	ld (hl),1
	inc hl
	djnz rf1
	; border colour around the C64 screen on the display and the clean copy
	ld hl,0
	call border_fill
	ld hl,CLEAN_Y
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
	ld (cmdblk+4),de
	ld (cmdblk+6),hl
	ld (cmdblk+10),a
	xor a
	ld (cmdblk+11),a
	ld a,b
	cp 2
	jr c,frh_one
	ld hl,256                   ; NX has 9 bits: two halves
	ld (cmdblk+8),hl
	call frh_go
	ld a,1
	ld (cmdblk+5),a             ; x 256
	jr frh_go
frh_one:
	ld (cmdblk+8),bc
frh_go:
	ld a,PAL_BORDER*$11
	jp hmmv

; the same rectangle on the clean copy (HL = its y) and on the display
fill_both:
	push af
	push bc
	push de
	push hl
	call fill_rect_hl
	pop hl
	dec h                       ; y - 256
	pop de
	pop bc
	pop af
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
	ld b,8
chp_8:
	push af
	and 1                       ; one dirty bit per character
	ld (de),a
	pop af
	rrca
	inc de
	djnz chp_8
	or a
	or a
	jr z,chp_n
	ld (any_chd),a
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

; render run_len cells from run_start into BUF, send with LMMC, copy to display
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
	ld (cmdblk+0),hl            ; SX
	ld (cmdblk+4),hl            ; DX
	srl h
	rr l
	ld a,l
	ld (spr_tmp+20),a           ; x byte
	ld a,(cur_row)
	call row_y_clean
	ld (cmdblk+2),hl            ; SY
	dec h
	ld (cmdblk+6),hl            ; DY: display
	ld a,(run_len)
	ld l,a
	ld h,0
	add hl,hl
	add hl,hl
	ld d,h
	ld e,l
	add hl,hl
	add hl,de                   ; 12k
	ld (cmdblk+8),hl
	ld hl,8
	ld (cmdblk+10),hl
	; the pixels into the clean copy, line by line
	ld hl,(cmdblk+2)
	ld de,BUF
	ld c,8
dr_send:
	push bc
	ld a,(spr_tmp+20)
	call vram_wr
	ld a,(stride)
	ld b,a
	ld c,VDP_DATA
	ex de,hl
	otir
	ex de,hl
	inc hl
	pop bc
	dec c
	jr nz,dr_send
	; and on to the display
	call hmmm
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
; V9958 (cmdblk = R#32..R#46: +0 SX, +2 SY, +4 DX, +6 DY, +8 NX, +10 NY,
; +12 CLR, +13 ARG, +14 CMD)
; ============================================================================
; wait for the command engine (status register 2, CE)
v_wait:
	di
	ld a,2
	ld (vdp_r15),a              ; the interrupts put it back after their reads
	out (VDP_CTRL),a
	ld a,$8F
	out (VDP_CTRL),a
	ei
vwt_l:
	in a,(VDP_CTRL)
	rrca
	jr c,vwt_l
	di
	xor a
	ld (vdp_r15),a
	out (VDP_CTRL),a
	ld a,$8F
	out (VDP_CTRL),a
	ei
	ret

v_send_cmd:                     ; R#32..R#46 through the indirect port
	call v_wait
	di
	ld a,32
	out (VDP_CTRL),a
	ld a,$91                    ; R#17 = 32, auto increment
	out (VDP_CTRL),a
	ei
	ld hl,cmdblk
	ld bc,15*256+VDP_IND
	otir
	ret

; HMMV fill: DX, DY, NX, NY set; A = colour byte
hmmv:
	ld (cmdblk+12),a
	ld a,$C0
	jr cmd_arg0

; HMMM copy: SX, SY, DX, DY, NX, NY set (x even)
hmmm:
	ld a,$D0
	jr cmd_arg0

; LMMM copy skipping colour 0 (TIMP): SX, SY, DX, DY, NX, NY set
lmmm_tp:
	ld a,$98
cmd_arg0:
	ld (cmdblk+14),a
	xor a
	ld (cmdblk+13),a            ; ARG: left to right, top to bottom
	jp v_send_cmd

; set the VRAM write address: HL = y (0..511), A = x / 2.  Keeps BC, DE, HL.
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
	or $40                      ; A13-A8, write
	out (VDP_CTRL),a
	ei
	ret

; ============================================================================
; sprites
; ============================================================================
; sprites
; ============================================================================
sprites:
	ld hl,sc_frame
	inc (hl)
	call sp_erase
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

; last frame's sprites: their rectangles back from the clean copy
sp_erase:
	ld a,(spr_n)
	or a
	ret z
	ld b,a
	ld ix,DRAWN
spe_l:
	push bc
	ld l,(ix+0)
	ld h,(ix+1)
	ld a,l
	and $FE
	ld l,a                      ; x even
	ld (cmdblk+0),hl
	ld (cmdblk+4),hl
	ld a,(ix+0)
	and 1
	add a,(ix+3)
	inc a
	and $FE                     ; even width that covers the sprite
	ld l,a
	ld h,0
	ld (cmdblk+8),hl
	ld l,(ix+2)
	ld (cmdblk+6),hl
	inc h
	ld (cmdblk+2),hl            ; y + CLEAN_Y
	ld l,(ix+5)
	ld h,0
	ld (cmdblk+10),hl
	push ix
	call hmmm
	pop ix
	ld de,8
	add ix,de
	pop bc
	djnz spe_l
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
	; collision bounding box in screen coordinates
	call sp_coll
	ld hl,spr_n
	inc (hl)
	jp lmmm_tp

; --- sprite-sprite collision on tight bounding boxes --------------------------
; this sprite: IX entry (x,y,w,h) + bbox from the cache slot in spr_tmp+10..13
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
	ld de,SC_Y0
	ld a,c
	or a
	jr z,spc_y
	ld de,SC_Y1
spc_y:
	ld (spr_tmp+8),de
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
	; into the slot, line by line (a copy from it may still be running)
	call v_wait
	call spc_pos
	srl h
	rr l
	ld a,l
	ld (spr_tmp+18),a           ; x byte
	ld hl,(spr_tmp+8)
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
	ld a,(spr_tmp+18)
	call vram_wr
	inc hl
	ld (spr_tmp+16),hl
	ld hl,BUF
	ld a,(spr_tmp+6)
	srl a
	ld b,a
	ld c,VDP_DATA
	otir
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
	defs NT-region_render_end,0
