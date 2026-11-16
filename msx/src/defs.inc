; Shared constants for the MSX / V9990 port of C64 Buggy Boy.
; `equ` assigns a name to a value and emits no bytes. Keep this file as the
; common vocabulary for the kernel, renderer, loader, and translated game.

; ---- memory mapper ----------------------------------------------------------
; Each port selects the 16K RAM segment visible in one Z80 address page.
PORT_P0:         equ $FC
PORT_P1:         equ $FD
PORT_P2:         equ $FE
PORT_P3:         equ $FF

SEG_C0:          equ 4               ; C64 $0000-$3FFF (+ resident kernel in code holes)
SEG_VIC:         equ 5               ; C64 $4000-$7FFF (VIC bank 1)
SEG_C2:          equ 6               ; C64 $8000-$BFFF (+ kernel in the $8000 hole)
SEG_C3:          equ 7               ; C64 $C000-$FFFF
SEG_CODE:        equ 8               ; first translated code segment
SEG_RENDER:      equ 12              ; renderer code + tables (mapped in page 1)
SEG_SHADOW:      equ 13              ; renderer: last drawn cell inputs (mapped in page 3)

; ---- V9990 (Gfx9000) --------------------------------------------------------
V_VRAM:          equ $60             ; P#0 VRAM data
V_PAL:           equ $61             ; P#1 palette data
V_CMD:           equ $62             ; P#2 command data
V_REG:           equ $63             ; P#3 register data
V_SEL:           equ $64             ; P#4 register select
V_STAT:          equ $65             ; P#5 status
V_INT:           equ $66             ; P#6 interrupt flags
V_SYS:           equ $67             ; P#7 system control

; ---- Turbo R timer (used by the legacy Turbo R build only) -----------------
TIMER_LO:        equ $E6
TIMER_HI:        equ $E7

; ---- display geometry -------------------------------------------------------
; C64 raster line c is shown on V9990 display line c-RASTER_OFS.
RASTER_OFS:      equ 45
SCREEN_X:        equ 16              ; V9990 x of C64 pixel column 0
SCREEN_Y:        equ 6               ; V9990 y of C64 raster line 51
CLEAN_Y:         equ 512             ; y of the sprite-free playfield copy
SPRITE_CACHE_Y:  equ 768             ; y of the sprite shape cache
; display pages at y 0 and 256 (double buffered)

; palette slots
PAL_BG0:         equ 0               ; $D021 (live)
PAL_BG1:         equ 1               ; $D022 (live)
PAL_BG2:         equ 2               ; $D023 (live)
PAL_BORDER:      equ 3               ; $D020 (live, backdrop)
PAL_FIXED:       equ 4               ; first slot for fixed C64 colours

; ---- resident kernel data in C64 code holes (page 0) -----------------------
; The translated game keeps the original C64 address layout. These symbols
; occupy unused code addresses in that layout, so their numeric addresses are
; part of the kernel's memory map.
COLOR_RAM:       equ $2A00           ; 1K, C64 $D800-$DBFF
VDIRTY:          equ $2E00           ; 256 flags, one per 64 bytes of VIC bank
KVARS:           equ $2F00
VIC_REGS:        equ KVARS+$00       ; shadow of $D000-$D03F
SID_REGS:        equ KVARS+$40       ; shadow of $D400-$D41F
cur_p1:          equ KVARS+$60       ; mapper segment in page 1
cur_p2:          equ KVARS+$61       ; mapper segment in page 2
vec_ffff:        equ KVARS+$62       ; C64 $FFFF (IRQ vector high)
vic_irr:         equ KVARS+$63
vic_imr:         equ KVARS+$64
irq_line:        equ KVARS+$65       ; 2 bytes: raster line of the IRQ being served
vic_changed:     equ KVARS+$67
cia1_pra:        equ KVARS+$68       ; keyboard column select written by game
joy_state:       equ KVARS+$69       ; C64 joystick port 2 bits, active low
key_rows:        equ KVARS+$6A       ; 8 bytes: C64 keyboard rows per column (active low)
frame_count:     equ KVARS+$72
rendering:       equ KVARS+$73
cia2_pra:        equ KVARS+$74
rnd_state:       equ KVARS+$75       ; 2 bytes
coll_ss:         equ KVARS+$77       ; sprite-sprite collision latch
coll_sb:         equ KVARS+$78       ; sprite-background collision latch
tl_write:        equ KVARS+$79       ; timeline buffer being written (0/1)
tl_count:        equ KVARS+$7A       ; 2 bytes: events in timeline buffers 0/1
cdirty:          equ KVARS+$7C       ; colour RAM dirty, 16 flags (64 bytes each)
palette_shadow:  equ KVARS+$8C       ; 4 bytes: live colours for BG0/BG1/BG2/BORDER
k_tmp:           equ KVARS+$90       ; scratch
sid_gate:        equ KVARS+$98       ; 3 bytes
sid_env:         equ KVARS+$9B       ; 3 bytes: software envelope level 0-15 (x16)
sid_phase:       equ KVARS+$9E       ; 3 bytes: 0 off, 1 attack, 2 decay/sustain, 3 release
sid_lvl:         equ KVARS+$A1       ; 6 bytes: 8.8 envelope level per voice
debug_last:      equ KVARS+$B0       ; 2 bytes: last unimplemented / error address
debug_code:      equ KVARS+$B2
race_wait:       equ KVARS+$B3       ; MSX2+: hold the previous page while race bitmap is built
irq_count:       equ KVARS+$B4       ; 2 bytes
vbl_pending:     equ KVARS+$B6
cur_p3:          equ KVARS+$B7       ; mapper segment in page 3
irq_late:        equ KVARS+$B8       ; raster line armed after it had passed
LU_CACHE:        equ $3060           ; 16 x 5: direct-mapped k_lookup cache (C64 lo, hi, seg, Z80 addr); 0 = empty
lu_cache:        equ KVARS+$B9       ; 5: last k_lookup (C64 addr, seg, Z80 addr)
page_back:       equ KVARS+$BE       ; display page being drawn (0/1)
flip_pending:    equ KVARS+$BF       ; back page complete: show it at vblank
tl_hadirq:       equ KVARS+$C0       ; 2: a C64 IRQ ran in timeline buffer 0/1
busy_vbls:       equ KVARS+$C2       ; blank timeout in vblanks; 150 latches until rows settle
calm_flips:      equ KVARS+$C3       ; page flips to keep blank ($FF: until the renderer says so)
in_irq:          equ KVARS+$C4       ; a C64 IRQ handler is running
blank_req:       equ KVARS+$C5       ; main code changed the display mode: new screen coming
sli_bord:        equ KVARS+$C6       ; the armed raster line is the border slot
pal_bank:        equ KVARS+$C7       ; palette bank on screen (0/1, R#13 offset)
raster_base:     equ KVARS+$C8       ; 2: C64 line at the last raster clock restart
bank_live:       equ KVARS+$CA       ; 8: live colours last written into V9990 palette bank 0/1 ($FF = unknown)
sli_last:        equ KVARS+$D2       ; 2: line+1 last written to V9990 R#10 (0 = unknown)
skip_n:          equ KVARS+$D4       ; vblanks in a row without a render (frame unchanged)
mt_sync:         equ KVARS+$D5       ; main code polled the raster since the last render
mt_head:         equ KVARS+$D6       ; vblanks left in game-loop mode (renders follow MAIN_LOOP)
kb_n:            equ KVARS+$D7       ; kerb bands left in the native line-IRQ chain (k_int fast path)
kb_ptr:          equ KVARS+$D8       ; 2: next kb_list entry (its C64 line)
pace_due:        equ KVARS+$DA       ; frame_count when the next race-loop pass is due
pace_np:         equ KVARS+$DB       ; race-loop passes skipped since the last render
soft_target:     equ KVARS+$DC       ; MSX2+ C64 raster line scheduled on the V9990
ras_sub:         equ sli_last        ; MSX2+: 2: lines added to raster_base by raster reads since the last IRQ (0..311)
vc_last:         equ KVARS+$DE       ; MSX2+: 2: frame-order key of the last handler run by vbl_catchup
kb_n0:           equ KVARS+$A7       ; MSX2+: bands in the last kb_start list (odd-frame replay)
kb_fok:          equ KVARS+$A9       ; MSX2+: 1 = kerb colours alternate: k_int_kb fast path
top_col:         equ KVARS+$A8       ; MSX2+: D021 at the top of the frame (re-applied on odd vblanks)
RASTER_LAST:     equ 301             ; MSX2+: last C64 line with a V9990 line IRQ (V9990 256)
CHAIN_MASK:      equ 1               ; MSX2+: the C64 IRQ chain runs when frame_count & CHAIN_MASK == 0 (1 = every 2nd vblank, 3 = every 4th)
PACE_VBLS:       equ 4               ; vblanks per race-loop pass (C64 original: ~6)
kb_list:         equ $3040           ; 27: (line, colour) per chained band, then band 12's line
; KVARS+$E0..: C64 page-3 variables relocated by translate.py RELOC ($FB2A)

; The interrupt code writes one event record per raster change. Two buffers
; let the game write the next frame while the renderer reads the last one.
TIMELINE:        equ $3100
TIMELINE1:       equ $3800
TL_MAX:          equ 16
TL_REC:          equ 64
; record layout: +0 line lo, +1 line hi, +8..+$37 VIC regs $00-$2F, +$38 sprite pointers

STACK_TOP:       equ $3800
IM2_PAGE:        equ $27             ; IM2 vector at $27FF/$2800
LOOKUP_HASH:     equ $F800           ; 128 x 6: C64 addr, seg, Z80 addr (build.py fills it)
LOOKUP_SLOTS:    equ 128
TL_BASE:         equ $1800           ; base record (frame start state) for each timeline buffer
SPC_KEY:         equ KVARS+$AA       ; 6: last SID freq per voice (sid_period_c)
SPC_VAL:         equ KVARS+$5A       ; 6: its PSG period (unused SID shadow bytes)
KB_SKIP:         equ 12              ; MSX2+: kerb lines a heavy band ISR skips (its run time in lines)
