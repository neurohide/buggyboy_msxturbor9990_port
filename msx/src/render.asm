; VIC-II -> V9990 renderer.  Lives in its own mapper segment (SEG_RENDER),
; mapped into page 1 and called once per frame from the V9990 vblank
; interrupt with interrupts enabled (C64 raster IRQs may nest).
;
; V9990 B3 mode, 512x212, 4 bpp.  One C64 multicolour pixel becomes three
; V9990 pixels (one hires pixel 1.5), so the 320 pixel C64 screen is 480
; pixels wide, which matches the C64's pixel aspect closely.
;
;   y 0..211     display
;   y 256..467   clean playfield (no sprites); dirty cells are drawn here
;                and copied to the display, sprites are erased from here
;   y 512..      sprite shape cache, 7 slots of 72x42 per row
;
; While rendering, the VIC bank is mapped in page 2: C64 $4000 = Z80 $8000.

	org $4000
region_render_start:
	jp render

; ---------------------------------------------------------------- variables
NT:              equ $7000           ; nibble table: 16 x 4 bytes (3 used)
BUF:             equ $7100           ; cell pixels, line-major, up to 40 cells
VDW:             equ $7900           ; work copy of VDIRTY
CHDIRTY:         equ $7A00           ; per character code
SCACHE:          equ $6800           ; sprite cache: 128 slots x 8 bytes ($6800-$6BFF, above LTL)
RV:              equ $7F00           ; misc variables (overlaps nothing below $7F00)
SC_SLOTS:        equ 128

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
celldirty:       equ $7040           ; 40 + sentinel $80 (row_render scan)
tl_ptr:          equ RV+$81          ; 2: next event record
tl_left:         equ RV+$83          ; events left
rec_cur:         equ RV+$84          ; 2
cmdblk:          equ RV+$86          ; 21: R#32..R#52
spr_n:           equ RV+$9B          ; sprites drawn this frame
row_edge:        equ RV+$9C          ; row was shifted in 38-col mode: redraw edge cells
dr_full:         equ RV+$9D          ; draw_run: next LMMC needs the full command
pf_n:            equ RV+$9E          ; draw_run: pending one-colour cells (merged LMMV)
pf_col:          equ RV+$9F          ;   their colour byte
pf_dx:           equ RV+$A0          ; 2 their first x
spr_tmp:         equ RV+$D0          ; 32 scratch
rdc_gf:          equ spr_tmp+20      ; rd_cells: group-changed flag (sprites are not drawn meanwhile)
rdc_bg:          equ spr_tmp+21      ; rd_cells: bitmap dirty bits of the group, shifted per cell
rdc_gs:          equ spr_tmp+22      ; rd_cells: first column of the group
dr_shad:         equ spr_tmp+23      ; draw_run: shadow entry for the current cell
row_cram:        equ RV+$A2          ; 2: COLOR_RAM + r*40 (row_setup)
row_shad:        equ RV+$AD          ; 2: SHADOW + r*400 (row_setup)
rgn_rec:         equ RV+$A5          ; 2 record of the sprite region
rgn_lo:          equ RV+$A7          ; 2 first raster line of region
rgn_hi:          equ RV+$A9          ; 2 first raster line after region
coll_acc:        equ RV+$AB
ntq:             equ RV+$B0          ; 8: nt_build, 4 x (colour, colour * $11)
fslot:           equ RV+$B8          ; 16: fix_slot cache, C64 colour -> slot (0 = not yet)
cc_key:          equ RV+$C8          ; 3: row_mode, colour nibble, screen byte cell_cols was made from
row_xchg:        equ RV+$CC          ; row_setup: the row's x offset changed this frame
cm_fc:           equ RV+$CD          ; CMMC cell: foreground colour byte (colour * $11)
cm_bc:           equ RV+$CE          ; background colour byte
cm_x:            equ RV+$CF          ; fg value * $55: XOR makes fg pixels 00
CM_TA:           equ $5C00           ; CMMC tables, index = source byte ^ cm_x, 12 bits
CM_TB:           equ $5D00           ; per byte (bit 11 = left pixel, fg pixel = 1):
CM_TC:           equ $5E00           ; TA = bits 11-4, TB = bits 3-0 << 4,
CM_TD:           equ $5F00           ; TC = bits 11-8, TD = bits 7-0
CM_PT:           equ $6600           ; byte -> mask of the 2-bit pixel values in it
cc_hit:          equ RV+$CB          ; cell_colours reused cell_cols (so NT is still built for it)
rgn_idx:         equ RV+$AC
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
; back-page sync state, also in SEG_SHADOW (above the cell shadow)
SH_SPR:          equ $F000           ; 2 pages x 16 x 8: sprites drawn last time on a page
SH_ROWS:         equ $F100           ; 25 flags: clean rows changed this frame
SH_ROWP:         equ SH_ROWS+32      ; 25 flags: clean rows changed last frame
SH_PG:           equ $F140           ; [0..1] sprites drawn per page, [2..3] page built
SH_CUR_PG:       equ SH_PG+4         ; page being synced
SH_EARLY:        equ SH_CUR_PG+1     ; 1: rows were synced to the back page during this render
SH_XOFF:         equ $F150           ; last rendered horizontal offset for each row
; changed x span of each clean row, 4-pixel units from SCREEN_X, [lo, hi)
SPAN_LO:         equ $F180           ; this frame (valid where SH_ROWS is set)
SPAN_HI:         equ $F1A0
SPANP_LO:        equ $F1C0           ; last frame (valid where SH_ROWP is set)
SPANP_HI:        equ $F1E0
SPAN_FULL:       equ 120             ; 480 / 4

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
	; sprite shapes the game rewrote (one 64-byte chunk per pointer): drop
	; their cached copies so they are rendered again
	ld hl,SCACHE
	ld b,SC_SLOTS
	ld d,VDW/256
r_sci:
	ld e,(hl)                   ; key byte 0 = pointer
	ld a,(de)
	or a
	jr z,r_sci_n
	push hl
	ld de,5
	add hl,de
	ld (hl),0                   ; valid flag
	pop hl
	ld d,VDW/256
r_sci_n:
	ld de,8
	add hl,de
	ld d,VDW/256
	djnz r_sci
	ld a,$FF
	ld (chd_cb),a
	ld (cc_key),a               ; no row_mode is $FF: cell_cols is rebuilt
	xor a
	ld (mode_rows),a
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
	ld a,(page_back)
	ld (SH_CUR_PG),a
	xor a
rr_loop:
	ld (cur_row),a
	call row_setup
	call row_dirty
	call nz,row_render
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
	call sprites
	call screen_change

	ld a,SEG_C3
	ld (cur_p3),a
	out (PORT_P3),a
	jp k_map_c2

render_first:
	ld a,1
	ld (first_done),a
	call cm_init
	ld a,$80
	ld (celldirty+40),a         ; row_render scan sentinel
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
	; A changed horizontal offset moves every pixel in the row (the road
	; curves this way): shift the drawn row in VRAM instead of redrawing it.
	; Cells whose bytes changed are still found by row_dirty.
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
	ld a,1
	ld (row_xchg),a
	ld a,(row_xoff)
	ld b,(hl)                   ; old offset
	ld (hl),a
	ld hl,row_full
	add hl,de
	ld a,b
	inc a
	jr z,rs_xfull               ; never drawn
	ld a,(row_mode)
	bit 2,a
	jr nz,rs_xfull              ; blank row
	ld a,(hl)
	or a
	call z,row_shift            ; not redrawn anyway: move it
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
	xor a
	ret
rc_go:
	push de
	ld a,(cur_row)
	call row_y_clean            ; also marks the row for the page sync
	ld (cmdblk+2),hl
	ld (cmdblk+6),hl
	ld hl,8
	ld (cmdblk+10),hl
	pop de
	push de
	ld a,d
	bit 7,a
	jr z,rc_pos
	neg
rc_pos:
	ld b,a                      ; |k|
	add a,a
	add a,b
	add a,a
	add a,a                     ; 12|k|
	ld e,a
	ld d,0
	ld hl,480
	or a
	sbc hl,de
	ld (cmdblk+8),hl            ; NX = 480 - 12|k|
	ld a,(row_xoff)
	ld c,a
	ld b,0
	ld hl,SCREEN_X
	add hl,bc                   ; HL = x of cell 0
	pop bc                      ; B = k
	push bc
	bit 7,b
	jr nz,rc_left
	; right: copy backwards from the last pixel, DIX=1
	push de
	ld de,479
	add hl,de
	pop de
	ld (cmdblk+4),hl            ; DX = cell 0 + 479
	or a
	sbc hl,de
	ld (cmdblk+0),hl            ; SX = DX - 12k
	ld a,4
	jr rc_cmd
rc_left:
	ld (cmdblk+4),hl            ; DX = cell 0
	add hl,de
	ld (cmdblk+0),hl            ; SX = cell 0 + 12|k|
	xor a
rc_cmd:
	ld (cmdblk+12),a            ; ARG
	ld a,$0C
	ld (cmdblk+13),a
	ld a,$FF
	ld (cmdblk+14),a
	ld (cmdblk+15),a
	ld a,$40                    ; LMMM
	ld (cmdblk+20),a
	call v_send_cmd
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

; ============================================================================
; draw the dirty runs of the current row
; ============================================================================
row_render:
	ld a,(row_mode)
	bit 2,a
	jp nz,row_blank
	ld hl,celldirty
rrn_scan:                       ; next dirty cell (sentinel $80 after cell 39)
	ld a,(hl)
	inc l
	or a
	jr z,rrn_scan
	dec l
	ld a,l
	sub celldirty & 255
	cp 40
	ret nc
	ld (run_start),a
	ld b,0
rrn_len:                        ; run of 1s (0 or the sentinel ends it)
	inc b
	inc l
	ld a,(hl)
	dec a
	jr z,rrn_len
	ld a,b
	ld (run_len),a
	push hl
	call draw_run
	pop hl
	jr rrn_scan

row_blank:
	; display disabled: border colour over the row
	ld a,(cur_row)
	call row_y_clean
	ld de,SCREEN_X
	ld bc,480
	ld a,8
	call fill_rect_hl
	ret

; A = row -> HL = y in the clean buffer; the row is marked changed
row_y_clean:
	ld e,a
	ld h,SH_ROWS/256
	ld l,a
	ld (hl),1
	set 7,l                     ; SPAN_LO
	ld (hl),0
	set 5,l                     ; SPAN_HI
	ld (hl),SPAN_FULL
row_y_of:                       ; E = row -> HL = y in the clean buffer, no mark
	ld l,e
	ld h,0
	add hl,hl
	add hl,hl
	add hl,hl
	ld de,CLEAN_Y+SCREEN_Y
	add hl,de
	ret

; mark clean row cur_row changed over [D, E) (4-pixel units)
span_mark:
	ld a,(cur_row)
	ld l,a
	ld h,SH_ROWS/256
	ld a,(hl)
	ld (hl),1
	set 7,l                     ; SPAN_LO
	or a
	jr z,sm_new
	ld a,(hl)
	cp d
	jr c,sm_lo
	ld (hl),d
sm_lo:
	set 5,l                     ; SPAN_HI
	ld a,(hl)
	cp e
	ret nc
	ld (hl),e
	ret
sm_new:
	ld (hl),d
	set 5,l
	ld (hl),e
	ret

; render run_len cells from run_start: one LMMC per cell (12x8 pixels), the
; pixels go straight to the command port (no buffer, no stride)
draw_run:
	; shadow records are 10 bytes each; keep a running pointer across this run
	; instead of multiplying the column by 10 again for every drawn cell.
	ld a,(run_start)
	ld l,a
	ld h,0
	add hl,hl
	ld d,h
	ld e,l
	add hl,hl
	add hl,hl
	add hl,de
	ld de,(row_shad)
	add hl,de
	ld (dr_shad),hl
	ld a,(cur_row)
	ld e,a
	call row_y_of
	ld (cmdblk+6),hl
	ld hl,12
	ld (cmdblk+8),hl
	ld hl,8
	ld (cmdblk+10),hl
	; x = SCREEN_X + 12*start + xoff
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
	ld e,a
	ld d,0
	add hl,de
	ld (cmdblk+4),hl
	; changed span: [x/4, x/4 + 3*len + 1)
	ld de,-SCREEN_X
	add hl,de
	srl h
	rr l
	srl l
	ld d,l
	ld a,(run_len)
	ld e,a
	add a,a
	add a,e
	inc a
	add a,d
	ld e,a
	call span_mark
	ld a,1
	ld (dr_full),a
	xor a
	ld (pf_n),a
	ld a,(run_len)
	ld b,a
	ld a,(run_start)
	ld c,a
dr_cell:
	ld hl,(dbg_cnt)
	inc hl
	ld (dbg_cnt),hl
	push bc
	call cell_colours           ; fills cell_cols, returns HL = source bytes
	push hl
	call shadow_store
	pop hl
	push hl
	ld a,(cc_hit)
	or a
	call z,nt_build             ; rows phase: only dr_cell builds NT
	pop hl
	call cell_uniform
	jr nz,dr_pix
	; one colour: merge with the pending fill when it continues it
	ld b,a
	ld a,(pf_n)
	or a
	jr z,dr_pf_new
	ld a,(pf_col)
	cp b
	jr z,dr_pf_ext
	push bc
	call dr_flush
	pop bc
dr_pf_new:
	ld a,b
	ld (pf_col),a
	ld hl,(cmdblk+4)
	ld (pf_dx),hl
	ld a,1
	ld (pf_n),a
	jr dr_adv
dr_pf_ext:
	ld hl,pf_n
	inc (hl)
	jr dr_adv
dr_pix:
	push hl
	call dr_flush
	pop hl
	ld a,(cell_cols)
	or a
	call nz,dr_two              ; multicolour with 2 pixel values: CMMC, CF
	jr c,dr_adv
	ld a,(dr_full)
	or a
	jr z,dr_next
	xor a
	ld (dr_full),a
	push hl
	call lmmc_start             ; full command
	pop hl
	jr dr_out
dr_next:                        ; later cells: resend DX/DY/NX/NY (R#36-R#43; the
	call v_wait                 ; command advances DY) and the opcode
	ld a,i                      ; P/V = IFF2 (read twice, as k_get_iff)
	jp pe,dn_on
	ld a,i
dn_on:
	push af
	di
	push hl
	ld a,36
	out (V_SEL),a
	ld hl,cmdblk+4
	ld bc,4*256+V_REG           ; DX, DY only: NX/NY survive a command
	otir
	pop hl
	ld a,52
	out (V_SEL),a
	ld a,$10                    ; LMMC
	out (V_REG),a
	pop af
	jp po,dr_out
	ei
dr_out:
	call cell_out
dr_adv:
	ld hl,(cmdblk+4)
	ld de,12
	add hl,de
	ld (cmdblk+4),hl
	pop bc
	inc c
	dec b
	jp nz,dr_cell
	call dr_flush
	jp csel_fix

; HL = 8 source bytes of a multicolour cell.  Exactly 2 pixel values: draw it
; with CMMC (12 data bytes instead of LMMC's 48), CF.  Otherwise NC, HL kept.
dr_two:
	push hl
	ld d,CM_PT/256
	ld c,0
	ld e,(hl)
	inc hl
	ld a,(de)
	or c
	ld c,a
	ld e,(hl)
	inc hl
	ld a,(de)
	or c
	ld c,a
	ld e,(hl)
	inc hl
	ld a,(de)
	or c
	ld c,a
	ld e,(hl)
	inc hl
	ld a,(de)
	or c
	ld c,a
	ld e,(hl)
	inc hl
	ld a,(de)
	or c
	ld c,a
	ld e,(hl)
	inc hl
	ld a,(de)
	or c
	ld c,a
	ld e,(hl)
	inc hl
	ld a,(de)
	or c
	ld c,a
	ld e,(hl)
	inc hl
	ld a,(de)
	or c
	ld c,a
	ld hl,cm_pv
	ld e,c
	ld d,0
	add hl,de
	ld a,(hl)
	or a                        ; NC
	jr nz,dt_go
	pop hl
	ret
dt_go:                          ; A = $80 | fg << 2 | bg
	ld b,a
	and 3
	add a,a
	ld e,a
	ld hl,ntq+1
	add hl,de
	ld a,(hl)
	ld (cm_bc),a
	ld a,b
	rrca
	rrca
	and 3
	ld c,a
	add a,a
	ld e,a
	ld hl,ntq+1
	add hl,de
	ld a,(hl)
	ld (cm_fc),a
	ld e,c
	ld hl,cm_x55
	add hl,de
	ld a,(hl)
	ld (cm_x),a
	call v_wait
	ld a,i                      ; P/V = IFF2 (read twice, as k_get_iff)
	jp pe,dt_on
	ld a,i
dt_on:
	push af
	di
	ld a,36
	out (V_SEL),a
	ld hl,cmdblk+4
	ld bc,8*256+V_REG
	otir                        ; DX, DY, NX, NY
	xor a
	out (V_REG),a               ; R#44 ARG
	ld a,$0C
	out (V_REG),a               ; R#45 LOP: WC = SC (no transparency)
	ld a,48
	out (V_SEL),a
	ld a,(cm_fc)
	out (V_REG),a
	out (V_REG),a               ; R#48/49 foreground
	ld a,(cm_bc)
	out (V_REG),a
	out (V_REG),a               ; R#50/51 background
	ld a,52
	out (V_SEL),a
	ld a,$50                    ; CMMC
	out (V_REG),a
	pop af
	jp po,dt_di
	ei
dt_di:
	pop de                      ; source
	ld a,(cm_x)
	ld c,a
	ld a,(de)
	inc de
	xor c
	ld l,a
	ld h,CM_TA/256
	ld a,(hl)
	out (V_CMD),a
	inc h
	ld b,(hl)
	ld a,(de)
	inc de
	xor c
	ld l,a
	inc h
	ld a,(hl)
	or b
	out (V_CMD),a
	inc h
	ld a,(hl)
	out (V_CMD),a
	ld a,(de)
	inc de
	xor c
	ld l,a
	ld h,CM_TA/256
	ld a,(hl)
	out (V_CMD),a
	inc h
	ld b,(hl)
	ld a,(de)
	inc de
	xor c
	ld l,a
	inc h
	ld a,(hl)
	or b
	out (V_CMD),a
	inc h
	ld a,(hl)
	out (V_CMD),a
	ld a,(de)
	inc de
	xor c
	ld l,a
	ld h,CM_TA/256
	ld a,(hl)
	out (V_CMD),a
	inc h
	ld b,(hl)
	ld a,(de)
	inc de
	xor c
	ld l,a
	inc h
	ld a,(hl)
	or b
	out (V_CMD),a
	inc h
	ld a,(hl)
	out (V_CMD),a
	ld a,(de)
	inc de
	xor c
	ld l,a
	ld h,CM_TA/256
	ld a,(hl)
	out (V_CMD),a
	inc h
	ld b,(hl)
	ld a,(de)
	inc de
	xor c
	ld l,a
	inc h
	ld a,(hl)
	or b
	out (V_CMD),a
	inc h
	ld a,(hl)
	out (V_CMD),a
	scf
	ret

cm_x55:
	db $00,$55,$AA,$FF
cm_pv:                          ; value mask -> $80 | fg << 2 | bg, 0 unless 2 values
	db 0,0,0,$84,0,$88,$89,0
	db 0,$8C,$8D,0,$8E,0,0,0

; build the CMMC tables (once)
cm_init:
	ld bc,0                     ; C = byte
cmi_l:
	; presence mask
	ld a,c
	ld e,0
	ld b,4
cmi_p:
	push af
	and 3
	ld hl,cm_bit
	add a,l
	ld l,a
	jr nc,cmi_p1
	inc h
cmi_p1:
	ld a,(hl)
	or e
	ld e,a
	pop af
	rrca
	rrca
	djnz cmi_p
	ld h,CM_PT/256
	ld l,c
	ld (hl),e
	; 12-bit pattern in DE: pixel 00 -> 111
	ld de,0
	ld a,c
	ld b,4
cmi_b:
	ex de,hl
	add hl,hl
	add hl,hl
	add hl,hl
	ex de,hl
	rlca
	rlca
	push af
	and 3
	jr nz,cmi_b0
	ld a,e
	or 7
	ld e,a
cmi_b0:
	pop af
	djnz cmi_b
	; DE = bits 11-0
	ld l,c
	ld h,CM_TD/256
	ld (hl),e
	ld h,CM_TC/256
	ld (hl),d
	ld a,e
	and $0F
	rlca
	rlca
	rlca
	rlca
	ld h,CM_TB/256
	ld (hl),a
	ld a,e
	rrca
	rrca
	rrca
	rrca
	and $0F
	ld b,a
	ld a,d
	rlca
	rlca
	rlca
	rlca
	or b
	ld h,CM_TA/256
	ld (hl),a
	inc c
	jr nz,cmi_l
	ret
cm_bit:
	db 1,2,4,8

; send the pending merged one-colour fill (pf_n cells from pf_dx)
dr_flush:
	ld a,(pf_n)
	or a
	ret z
	ld hl,(cmdblk+4)
	push hl
	ld hl,(pf_dx)
	ld (cmdblk+4),hl
	ld b,a
	ld hl,0
	ld de,12
df_l:
	add hl,de
	djnz df_l
	ld (cmdblk+8),hl
	ld a,(pf_col)
	call lmmv
	pop hl
	ld (cmdblk+4),hl
	ld hl,12
	ld (cmdblk+8),hl
	xor a
	ld (pf_n),a
	inc a
	ld (dr_full),a
	ret

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
	call fill_rect_hl
	pop hl
	ld de,SCREEN_X+480-14       ; 9 C64 pixels -> 13.5
	ld bc,512-(SCREEN_X+480-14)
	ld a,8
	jp fill_rect_hl

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
	; bytes: aa, ab, bb.  ntq = 4 x (colour, colour * $11)
	ld hl,nt_key+1
	ld de,ntq
	ld b,4
ntb_q:
	ld a,(hl)
	inc hl
	ld (de),a
	inc de
	ld c,a
	add a,a
	add a,a
	add a,a
	add a,a
	or c
	ld (de),a
	inc de
	djnz ntb_q
	ld hl,NT
	ld a,(nt_key+1)
	call ntb_row
	ld a,(nt_key+2)
	call ntb_row
	ld a,(nt_key+3)
	call ntb_row
	ld a,(nt_key+4)
ntb_row:                        ; A = colour a -> the 4 entries a,0..a,3 at HL (NT page aligned)
	ld b,a
	add a,a
	add a,a
	add a,a
	add a,a
	ld c,a                      ; a << 4
	or b
	ld b,a                      ; a * $11
	ld de,ntq
	ld (hl),b
	inc l
	ld a,(de)
	inc de
	or c
	ld (hl),a
	inc l
	ld a,(de)
	inc de
	ld (hl),a
	inc l
	inc l
	ld (hl),b
	inc l
	ld a,(de)
	inc de
	or c
	ld (hl),a
	inc l
	ld a,(de)
	inc de
	ld (hl),a
	inc l
	inc l
	ld (hl),b
	inc l
	ld a,(de)
	inc de
	or c
	ld (hl),a
	inc l
	ld a,(de)
	inc de
	ld (hl),a
	inc l
	inc l
	ld (hl),b
	inc l
	ld a,(de)
	inc de
	or c
	ld (hl),a
	inc l
	ld a,(de)
	inc de
	ld (hl),a
	inc l
	inc l
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

; HL = 8 source bytes: Z and A = colour byte if the whole cell is one colour
; (8 equal bytes whose two nibbles expand to 6 equal bytes).  Preserves HL.
cell_uniform:
	push hl
	ld a,(hl)
	ld b,7
cu_l:
	inc hl
	cp (hl)
	jr nz,cu_no
	djnz cu_l
	pop hl
	ld c,a
	rrca
	rrca
	rrca
	rrca
	and $0F
	call cu_ent
	ld a,(de)
	ld b,a                      ; B = first pixel byte
	call cu_chk3
	ret nz
	ld a,c
	and $0F
	call cu_ent
	call cu_chk3
	ld a,b
	ret
cu_no:
	pop hl
	ret
cu_ent:                         ; A = nibble -> DE = its NT entry
	add a,a
	add a,a
	ld e,a
	ld d,NT/256
	ret
cu_chk3:                        ; Z if the 3 bytes at DE all equal B
	ld a,(de)
	cp b
	ret nz
	inc e
	ld a,(de)
	cp b
	ret nz
	inc e
	ld a,(de)
	cp b
	ret

; HL = 8 source bytes -> 8 lines of 6 bytes to the LMMC data port (NT page aligned)
cell_out:
	ex de,hl                    ; DE = source
	ld h,NT/256
	ld bc,48*256+V_CMD          ; B counts the 48 bytes sent by OUTI
co_line:
	ld a,(de)
	and $F0
	rrca
	rrca
	ld l,a
	outi
	outi
	outi
	ld a,(de)
	inc de
	and $0F
	add a,a
	add a,a
	ld l,a
	outi
	outi
	outi
	jr nz,co_line
	ret

; ============================================================================
; V9990 commands (cmdblk = R#32..R#52)
; ============================================================================
v_wait:
	in a,(V_STAT)
	rrca
	jr c,v_wait
	ret

v_send_cmd:                     ; write R#32..R#52 atomically
	call v_wait
	call k_get_iff
	push af
	di
	ld a,(cmdblk+20)
	cp $40
	ld a,32
	ld hl,cmdblk
	ld bc,14*256+V_REG          ; R#32..R#45; WM (R#46/47) stays $FFFF from v_init
	jr nc,vsc_sx                ; LMMM and up read SX/SY
	ld a,36                     ; LMMC/LMMV: from DX
	ld l,cmdblk+4 & 255
	ld b,10
vsc_sx:
	out (V_SEL),a
	otir
	ld a,(cmdblk+20)
	cp $20
	jr nz,vsc_op
	ld a,48                     ; FC: only LMMV uses it
	out (V_SEL),a
	ld hl,cmdblk+16
	ld b,2
	otir
vsc_op:
	ld a,52
	out (V_SEL),a
	ld a,(cmdblk+20)
	out (V_REG),a
	pop af
	or a
	ret z
	ei
	ret

; LMMV fill: cmdblk+4 DX, +6 DY, +8 NX, +10 NY set; A = colour byte
lmmv:
	ld (cmdblk+16),a            ; FC
	ld (cmdblk+17),a
	xor a
	ld (cmdblk+12),a            ; ARG
	ld a,$0C
	ld (cmdblk+13),a            ; LOP: WC = SC
	ld a,$FF
	ld (cmdblk+14),a
	ld (cmdblk+15),a
	ld a,$20                    ; LMMV
	ld (cmdblk+20),a
	jp v_send_cmd

; LMMC: DX, DY, NX, NY set
lmmc_start:
	xor a
	ld (cmdblk+12),a
	ld a,$0C
	ld (cmdblk+13),a
	ld a,$FF
	ld (cmdblk+14),a
	ld (cmdblk+15),a
	ld a,$10                    ; LMMC
	ld (cmdblk+20),a
	jp v_send_cmd

; LMMM copy: SX, SY, DX, DY, NX, NY set
lmmm:
	ld a,$0C
lmmm_lop:
	ld (cmdblk+13),a
	xor a
	ld (cmdblk+12),a
	ld a,$FF
	ld (cmdblk+14),a
	ld (cmdblk+15),a
	ld a,$40                    ; LMMM
	ld (cmdblk+20),a
	jp v_send_cmd
lmmm_tp:
	ld a,$1C                    ; transparent: skip colour 0
	jr lmmm_lop

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

sprites:
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
; C64 colours (Pepto) as V9990 5-bit R,G,B (copy: page 2 holds the VIC bank here)
r_c64_rgb:
	db  0, 0, 0,  31,31,31,  21, 7,11,  15,30,26
	db 21, 8,30,  12,26, 6,   5, 7,29,  31,31, 8
	db 24,13, 3,  15,10, 0,  30,16,16,  12,12,12
	db 18,18,18,  20,31,16,  14,16,31,  25,25,25

region_render_end:
	defs NT-region_render_end,0
