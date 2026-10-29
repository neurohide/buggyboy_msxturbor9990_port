; Shared constants for the MSX2+ / V9958 port of C64 Buggy Boy.

; ---- memory mapper ----------------------------------------------------------
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

; ---- V9958 -------------------------------------------------------------------
VDP_DATA:        equ $98             ; VRAM data
VDP_CTRL:        equ $99             ; register writes, address set-up, status reads
VDP_PAL:         equ $9A             ; palette data
VDP_IND:         equ $9B             ; indirect register writes (R#17)
VR0_G6:          equ $0A             ; R#0: GRAPHIC 6 (SCREEN 7), line interrupt off
VR0_G6_IE1:      equ $1A             ; R#0: GRAPHIC 6, line interrupt on
VR1_ON:          equ $60             ; R#1: display on, vblank interrupt on
VR1_OFF:         equ $20             ; R#1: display blanked, vblank interrupt on

; ---- display geometry -------------------------------------------------------
; C64 raster line c is shown on V9958 display line c-RASTER_OFS.
RASTER_OFS:      equ 45
SCREEN_X:        equ 16              ; V9958 x of C64 pixel column 0
SCREEN_Y:        equ 6               ; V9958 y of C64 raster line 51
CLEAN_Y:         equ 256             ; y of the sprite-free playfield copy (page 1)
; display at y 0 (page 0); sprite shape cache in the unseen lines 212-253 of
; both pages (SC_Y0, SC_Y1)
SC_Y0:           equ 212
SC_Y1:           equ 256+212

; palette slots
PAL_BG0:         equ 0               ; $D021 (live)
PAL_BG1:         equ 1               ; $D022 (live)
PAL_BG2:         equ 2               ; $D023 (live)
PAL_BORDER:      equ 3               ; $D020 (live, backdrop)
PAL_FIXED:       equ 4               ; first slot for fixed C64 colours

; ---- resident kernel data in C64 code holes (page 0) -----------------------
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
irq_count:       equ KVARS+$B4       ; 2 bytes
vbl_pending:     equ KVARS+$B6
cur_p3:          equ KVARS+$B7       ; mapper segment in page 3
lu_cache:        equ KVARS+$B9       ; 5: last k_lookup (C64 addr, seg, Z80 addr)
flip_pending:    equ KVARS+$BF       ; the renderer finished a frame
tl_hadirq:       equ KVARS+$C0       ; 2: a C64 IRQ ran in timeline buffer 0/1
calm_flips:      equ KVARS+$C3       ; rendered frames to keep blank ($FF: until the renderer says so)
in_irq:          equ KVARS+$C4       ; a C64 IRQ handler is running
blank_req:       equ KVARS+$C5       ; main code changed the display mode: new screen coming
vr_line:         equ KVARS+$C6       ; 2: virtual raster line seen by main code
vr_sync:         equ KVARS+$C8       ; a vblank happened: virtual raster restarts
vdp_r15:         equ KVARS+$C9       ; R#15 (status register) the main code selected
in_vbl:          equ KVARS+$CA       ; the vblank handler is running the C64 IRQs
vbl_missed:      equ KVARS+$CB       ; vblanks that came while it was still busy
ps_active:       equ KVARS+$CC       ; 2: palette schedule on screen
ps_build:        equ KVARS+$CE       ; 2: palette schedule being built
ps_wr:           equ KVARS+$D0       ; 2: write pointer into ps_build
ps_ptr:          equ KVARS+$D2       ; 2: next entry for the line interrupt
ps_ready:        equ KVARS+$D4       ; ps_build is complete
chain_key:       equ KVARS+$D5       ; 2: line order key of the last IRQ run this frame
main_idle:       equ KVARS+$D7       ; main code polled the raster (it waits for a frame)
vbl_wait:        equ KVARS+$D8       ; vblanks since the last frame while it was busy
CHAIN_WAIT:      equ 2               ; ... after which the next frame runs anyway
sid_pcache:      equ KVARS+$D9       ; 12: per voice last SID frequency, its PSG period

; timeline: two buffers of TL_MAX records of 64 bytes (in two separate holes)
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

; palette schedules (two, see k_setlive): 8 bytes of V9958 colour data for the
; live slots 0-3 at the top of the frame, then entries (display line, slot,
; colour byte 1, colour byte 2) in line order, ended by line $FF
PSCHED0:         equ $1A00
PSCHED1:         equ $1B80
PS_MAX:          equ 90              ; entries per schedule
