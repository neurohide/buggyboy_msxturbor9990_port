; Renderer memory map and per-frame state.
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
celldirty:       equ $7040           ; 40 + sentinel $80 (renderer_draw_dirty_cells scan)
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
row_cram:        equ RV+$A2          ; 2: COLOR_RAM + r*40 (renderer_setup_row)
row_shad:        equ RV+$AD          ; 2: SHADOW + r*400 (renderer_setup_row)
rgn_rec:         equ RV+$A5          ; 2 record of the sprite region
rgn_lo:          equ RV+$A7          ; 2 first raster line of region
rgn_hi:          equ RV+$A9          ; 2 first raster line after region
coll_acc:        equ RV+$AB
ntq:             equ RV+$B0          ; 8: nt_build, 4 x (colour, colour * $11)
fslot:           equ RV+$B8          ; 16: fix_slot cache, C64 colour -> slot (0 = not yet)
cc_key:          equ RV+$C8          ; 3: row_mode, colour nibble, screen byte cell_cols was made from
row_xchg:        equ RV+$CC          ; signed fine pixel delta, then combined shift
cm_fc:           equ RV+$CD          ; CMMC cell: foreground colour byte (colour * $11)
cm_bc:           equ RV+$CE          ; background colour byte
cm_x:            equ RV+$CF          ; fg value * $55: XOR makes fg pixels 00
cm_lv:           equ RV+$5A          ; cm_lfc/cm_lbc hold what R#48-51 contain
cm_lfc:          equ RV+$5B
cm_lbc:          equ RV+$5C
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

