; Page-2 kernel, in the $8000-$8CFF code hole of C64 block 2.  Only runs
; while SEG_C2 is mapped in page 2 (always true for translated code).

	org $8000
region_k2_start:

; ============================================================================
; entry from the loader: all pages mapped (S0/x/S2/S3), interrupts off
; ============================================================================
k_init:
	di
	ld sp,STACK_TOP
	im 2
	ld a,IM2_PAGE
	ld i,a
	; V9958: interrupts off (R#1 = $80: 16K, display off, IE0 off)
	ld a,$80
	out ($99),a
	ld a,$81
	out ($99),a
	; clear kernel variables
	ld hl,KVARS
	ld b,0
ki_clr:
	ld (hl),0
	inc hl
	djnz ki_clr
	; 0 is a valid C64 colour (black): bank_live must start as "no colour
	; written yet", not "colour 0 already written", or k_setlive would skip
	; the V9990's genuinely-uninitialized palette entries for colour 0.
	ld hl,bank_live
	ld b,8
ki_bl:
	ld (hl),$FF
	inc hl
	djnz ki_bl
	ld a,SEG_C2
	ld (cur_p2),a
	ld a,SEG_C3
	ld (cur_p3),a
	ld a,SEG_GAME_START
	ld (cur_p1),a
	ld a,$FF
	ld (joy_state),a
	ld a,$7F                    ; as the C64 KERNAL's keyboard scan leaves it
	ld (cia1_pra),a
	ld hl,key_rows
	ld b,8
ki_keys:
	ld (hl),$FF
	inc hl
	djnz ki_keys
	ld a,$97
	ld (cia2_pra),a
	ld a,1
	ld (page_back),a            ; page 0 is shown first
	ld hl,$1234
	ld (rnd_state),hl
	; colour RAM starts as light blue like after a C64 reset
	ld hl,COLOR_RAM
	ld de,COLOR_RAM+1
	ld bc,1023
	ld (hl),14
	ldir
	; force a full first render
	call k_all_dirty
	call psg_init
	call v_init
	; both timeline buffers start from the current (reset) VIC state
	ld a,1
	ld (tl_write),a
	call tl_base_snapshot
	xor a
	ld (tl_write),a
	call tl_base_snapshot
	; enter the game (page 1 switch is safe: we execute in page 2)
	ld bc,0
	ld de,0
	xor a
	ld a,SEG_GAME_START
	ld (cur_p1),a
	out (PORT_P1),a
	xor a
	jp T_GAME_START

k_all_dirty:
	ld hl,VDIRTY
	ld b,0
kad1:
	ld (hl),$FF
	inc hl
	djnz kad1
	ld hl,cdirty
	ld b,16
kad2:
	ld (hl),$FF
	inc hl
	djnz kad2
	ret

; ============================================================================
; far calls between translated code segments
;   call k_farcall / db seg / dw target    (preserves A, F, BC, DE)
; ============================================================================
k_farcall:
	ex af,af'
	pop ix                      ; -> parameters
	ld l,(ix+1)
	ld h,(ix+2)
	inc ix
	inc ix
	inc ix
	push ix                     ; caller's return address
	ld a,(cur_p1)
	push af                     ; caller's segment
	ld a,(ix-3)
	ld ix,fc_epilogue
	push ix
	ld (cur_p1),a
	out (PORT_P1),a
	ex af,af'
	jp (hl)
fc_epilogue:
	ex af,af'
	pop af
	ld (cur_p1),a
	out (PORT_P1),a
	ex af,af'
	ret

; JMP (ind): HL = C64 target.  Switches segment and jumps, leaving the stack
; alone (handlers may pull bytes pushed before the jump).  The routine that
; contains the indirect jump is always entered through k_farcall, whose frame
; restores the caller's segment when the handler returns.
k_jmpind:
	ex af,af'
	call k_lookup               ; IX = Z80 address, A = segment
	ld (cur_p1),a
	out (PORT_P1),a
	ex af,af'
	jp (ix)

; call the translated code for C64 address HL (used for IRQ vectors)
k_callc64:
	call k_lookup
	ld l,a
	ld a,(cur_p1)
	push af
	ld a,l
	ld (cur_p1),a
	out (PORT_P1),a
	call k_jpix
	pop af
	ld (cur_p1),a
	out (PORT_P1),a
	ret
k_jpix:
	jp (ix)

; HL = C64 address -> IX = Z80 address, A = segment.  Clobbers HL.
; Hash table built by tools/build.py: slot = (lo + 7*hi) & 127, linear probing.
k_lookup:
	push de
	ld a,(lu_cache)
	cp l
	jr nz,klu_scan
	ld a,(lu_cache+1)
	cp h
	jr nz,klu_scan
	ld ix,(lu_cache+3)
	ld a,(lu_cache+2)
	pop de
	ret
klu_scan:
	ld a,h
	add a,a
	add a,a
	add a,a
	sub h
	add a,l
	and LOOKUP_SLOTS-1
	ld e,a
	ld d,0
	ld ix,LOOKUP_HASH
	add ix,de
	add ix,de
	add ix,de
	add ix,de
	add ix,de
	add ix,de                   ; slot * 6
klu_loop:
	ld a,(ix+1)
	or a
	jr z,klu_fail               ; empty slot
	cp h
	jr nz,klu_next
	ld a,(ix+0)
	cp l
	jr z,klu_found
klu_next:
	inc e
	ld a,e
	and LOOKUP_SLOTS-1
	ld e,a
	jr nz,klu_step
	ld ix,LOOKUP_HASH           ; wrapped around to slot 0
	jr klu_loop
klu_step:
	push de
	ld de,6
	add ix,de
	pop de
	jr klu_loop
klu_found:
	ld a,(ix+2)
	ld e,(ix+3)
	ld d,(ix+4)
	ld (lu_cache),hl
	ld (lu_cache+2),a
	ld (lu_cache+3),de
	push de
	pop ix
	pop de
	ret
klu_fail:
	ld (debug_last),hl
	ld a,1
	ld (debug_code),a
	jp k_fatal

; leave the interrupt context for good: call k_escape / db seg / dw target
; (the C64 game jumps out of its raster IRQ handler at game over)
k_escape:
	di
	pop ix
	ld sp,STACK_TOP
	call k_reset_ctx
	ld l,(ix+1)
	ld h,(ix+2)
	ld a,(ix+0)
	ld (cur_p1),a
	out (PORT_P1),a
	jp (hl)

; forget any interrupted renderer: mapping, busy flag, half-done V9990 command
k_reset_ctx:
	xor a
	ld (rendering),a
	ld (in_irq),a
	ld (irq_late),a
	ld a,52
	out (V_SEL),a
	xor a
	out (V_REG),a               ; STOP command
	ld a,SEG_C2
	ld (cur_p2),a
	out (PORT_P2),a
	ld a,SEG_C3
	ld (cur_p3),a
	out (PORT_P3),a
	jp k_all_dirty              ; cells of the abandoned frame get compared again

; restart the game from scratch (C64 code jumped to $0800 inside an IRQ)
k_restart:
	di
	ld sp,STACK_TOP
	call k_reset_ctx
	ld bc,0
	ld de,0
	ld a,SEG_GAME_START
	ld (cur_p1),a
	out (PORT_P1),a
	jp T_GAME_START

; fatal error: red backdrop forever (debug_last/debug_code tell why)
k_fatal:
	di
	ld a,PAL_BORDER*4
	call v_palptr
	ld a,31
	out (V_PAL),a
	xor a
	out (V_PAL),a
	out (V_PAL),a
kf_loop:
	jr kf_loop

; ============================================================================
; interrupts
; ============================================================================
int_dispatch:
	in a,(V_INT)
	push af
	and 3
	cp 3
	jr nz,id_normal
	ld a,(sli_bord)
	or a
	jr z,id_normal
	; vblank and the border-slot IRQ (top of the next frame) both pending:
	; the vblank comes first, the C64 handler belongs to the next frame
	pop af
	call int_vblank
	in a,(V_INT)
	bit 1,a
	ret z                       ; already served during the render
	jp int_hline
id_normal:
	pop af
	push af
	bit 1,a
	call nz,int_hline
	pop af
	bit 0,a
	ret z
	jp int_vblank

int_hline:
	ld a,2
	out (V_INT),a
	; the beam is at the armed line right now: restart the raster clock there
	; (anchoring only at vblank lags whenever the vblank was served late)
	xor a
	out (TIMER_LO),a
	ld hl,267                   ; border slot: V9990 line 222
	ld a,(sli_bord)
	or a
	jr nz,ih_anchor
	ld a,(VIC_REGS+$11)
	rlca
	and 1
	ld h,a
	ld a,(VIC_REGS+$12)
	ld l,a
ih_anchor:
	ld (raster_base),hl
	ld hl,(irq_count)
	inc hl
	ld (irq_count),hl
	ld a,(vic_irr)
	or 1
	ld (vic_irr),a
	ld a,(vic_imr)
	and 1
	ret z
	ld a,(VIC_REGS+$12)
	ld (irq_line),a
	ld a,(VIC_REGS+$11)
	rlca
	and 1
	ld (irq_line+1),a
ih_again:
	call tl_mark_irq
	ld bc,0
	ld de,0
	ld a,($FFFE)
	ld l,a
	ld a,(vec_ffff)
	ld h,a
	ld a,1
	ld (in_irq),a
	call k_callc64
	xor a
	ld (in_irq),a
	call tl_snapshot
	; the handler armed a line that had already passed: serve it right away
	; (the translated handler is slower than the C64 one; bands are 4 lines apart)
	ld hl,irq_late
	ld a,(hl)
	or a
	ret z
	ld a,(sli_bord)
	or a
	jr z,ih_late
	in a,(V_INT)
	rrca
	ret c                       ; vblank pending: it runs the border slot later
ih_late:
	ld (hl),0
	ld a,(vic_imr)
	and 1
	ret z
	ld a,(vic_irr)
	or 1
	ld (vic_irr),a
	ld a,(VIC_REGS+$12)
	ld (irq_line),a
	ld a,(VIC_REGS+$11)
	rlca
	and 1
	ld (irq_line+1),a
	jr ih_again

int_vblank:
	ld a,1
	out (V_INT),a
	; show the page the renderer finished
	ld a,(flip_pending)
	or a
	jr z,ivb_noflip
	xor a
	ld (flip_pending),a
	ld (busy_vbls),a
	; pages from a big redraw (screen change) stay hidden, see render.asm
	ld a,8
	out (V_SEL),a
	ld hl,calm_flips
	ld a,(hl)
	or a
	ld a,$C2                    ; display on
	jr z,ivb_disp
	ld a,(hl)
	inc a
	jr z,ivb_off                ; $FF: screen being built, stay blank
	dec (hl)
ivb_off:
	ld a,$42                    ; display off (backdrop)
ivb_disp:
	out (V_REG),a
ivb_flip:
	ld a,17
	out (V_SEL),a
	xor a
	out (V_REG),a               ; SCAY low
	ld a,(page_back)
	out (V_REG),a               ; SCAY bits 12-8: 0 or 1 (line 256)
	xor 1
	ld (page_back),a
ivb_noflip:
	xor a
	out (TIMER_LO),a            ; raster clock restarts at C64 line 257
	ld hl,257
	ld (raster_base),hl
	ld hl,frame_count
	inc (hl)
	call vbl_catchup
	call read_input
	call sound_frame
	ld a,(rendering)
	or a
	jr z,ivb_swap
	; renderer still busy: drop this frame's events and start over
	ld a,(tl_write)
	ld hl,tl_count
	add a,l
	ld l,a
	ld (hl),0
	call tl_clear_irq
	call tl_base_snapshot
	jp vbl_border
ivb_swap:
	; close this frame's timeline, open the next one
	ld a,(tl_write)
	xor 1
	ld (tl_write),a
	ld hl,tl_count
	add a,l
	ld l,a
	ld (hl),0
	call tl_clear_irq
	call tl_base_snapshot
	call vbl_border
	ld a,1
	ld (rendering),a
	ei
	ld a,(cur_p1)
	push af
	ld a,SEG_RENDER
	ld (cur_p1),a
	out (PORT_P1),a
	call $4000
	di
	pop af
	ld (cur_p1),a
	out (PORT_P1),a
	call k_map_c2
	xor a
	ld (rendering),a
	ret

; A raster IRQ armed for a visible line that the beam has already passed was
; missed (the line was programmed a moment too late): run the C64 handlers
; now, at the bottom of the screen, so the chain keeps its 50 Hz rhythm.
vbl_catchup:
	ld b,16                     ; at most this many handlers
vc_loop:
	ld a,(vic_imr)
	and 1
	ret z
	ld a,(irq_late)
	or a
	jr z,vc_vis
	ld a,(sli_bord)
	or a
	ret nz                      ; border slot: run after the timeline swap
	jr vc_run                   ; armed after its line had passed
vc_vis:
	ld a,(VIC_REGS+$11)
	rlca
	and 1
	ld h,a
	ld a,(VIC_REGS+$12)
	ld l,a
	ld de,RASTER_OFS
	or a
	sbc hl,de
	ret c                       ; above the visible area: not due yet
	ld de,257-RASTER_OFS
	or a
	sbc hl,de
	ret nc                      ; at or below the vblank line: not due yet
vc_run:
	push bc
	xor a
	ld (irq_late),a             ; the handler may set it again
	call tl_mark_irq
	ld a,(vic_irr)
	or 1
	ld (vic_irr),a
	ld a,(VIC_REGS+$12)
	ld (irq_line),a
	ld a,(VIC_REGS+$11)
	rlca
	and 1
	ld (irq_line+1),a
	ld bc,0
	ld de,0
	ld a,($FFFE)
	ld l,a
	ld a,(vec_ffff)
	ld h,a
	ld a,1
	ld (in_irq),a
	call k_callc64
	xor a
	ld (in_irq),a
	call tl_snapshot
	pop bc
	djnz vc_loop
	ret

; the border-slot IRQ (C64 raster 0, top of the frame) was armed too late:
; run it now that the new frame's timeline is open
vbl_border:
	ld a,(irq_late)
	or a
	ret z
	ld a,(sli_bord)
	or a
	ret z
	ld b,1
	jp vc_run

; ---- timeline --------------------------------------------------------------
tl_clear_irq:
	ld a,(tl_write)
	ld hl,tl_hadirq
	add a,l
	ld l,a
	ld (hl),0
	ret
tl_mark_irq:
	ld a,(tl_write)
	ld hl,tl_hadirq
	add a,l
	ld l,a
	ld (hl),1
	ret

; record the VIC state after an IRQ handler changed display registers
tl_snapshot:
	ld a,(vic_changed)
	or a
	ret z
	xor a
	ld (vic_changed),a
	ld a,(tl_write)
	ld hl,tl_count
	add a,l
	ld l,a
	ld a,(hl)
	cp TL_MAX
	jr c,tls_room
	ld a,TL_MAX-1               ; full: overwrite the last record
	dec (hl)
tls_room:
	inc (hl)
	; record address = TIMELINE + tl_write*TL_MAX*TL_REC + index*TL_REC
	ld l,a
	ld h,0
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl
	ld bc,TIMELINE
	ld a,(tl_write)
	or a
	jr z,tls_b0
	ld bc,TIMELINE1
tls_b0:
	add hl,bc
	ex de,hl
	ld hl,irq_line
	ldi
	ldi
	jr tl_fill

; base record of the frame that starts now (state at vblank)
tl_base_snapshot:
	ld a,(tl_write)
	ld de,TL_BASE
	or a
	jr z,tlb0
	ld de,TL_BASE+TL_REC
tlb0:
	ld hl,tlb_line
	ldi
	ldi
tl_fill:
	; DE -> record+2
	ld hl,6
	add hl,de
	ex de,hl                    ; DE -> record+8
	ld hl,VIC_REGS
	ld bc,$30
	ldir
	; sprite pointers: screen base + $3F8 inside the VIC bank
	ld a,(VIC_REGS+$18)
	and $F0
	rrca
	rrca
	add a,$43                   ; $4000 + (D018>>4)*$400 + $300
	ld h,a
	ld l,$F8
	jp k_vcopy8
tlb_line:
	dw 0

; ============================================================================
; I/O reads: HL = $D000-$DFFF -> L.  Preserves A, F, BC, DE.
; ============================================================================
k_iord:
	push af
	ld a,h
	cp $D4
	jr c,iord_vic
	cp $D8
	jr c,iord_sid
	cp $DC
	jr c,iord_col
	jr z,iord_cia1
	cp $DD
	jr z,iord_cia2
	ld l,$FF
	pop af
	ret
iord_col:
	and 3
	add a,COLOR_RAM/256
	ld h,a
	ld a,(hl)
	or $F0
	ld l,a
	pop af
	ret
iord_sid:
	ld a,l
	and $1F
	cp $1B
	jr c,iord_sid_0
	call k_random
	ld l,a
	pop af
	ret
iord_sid_0:
	ld l,0
	pop af
	ret
iord_cia2:
	ld a,l
	and $0F
	ld l,$FF
	jr nz,iord_cia2_x
	ld a,(cia2_pra)
	ld l,a
iord_cia2_x:
	pop af
	ret
iord_cia1:
	ld a,l
	and $0F
	jr z,iord_pra
	dec a
	jr z,iord_prb
	ld l,0
	pop af
	ret
iord_pra:
	; port A pins = joystick 2 AND the keyboard column bits the game drives
	ld a,(cia1_pra)
	ld l,a
	ld a,(joy_state)
	and l
	ld l,a
	pop af
	ret
iord_prb:
	; AND the rows of every selected (low) column
	push bc
	ld a,(cia1_pra)
	ld c,a
	ld hl,key_rows
	ld a,$FF
	ld b,8
iprb_l:
	rr c
	jr c,iprb_n
	and (hl)
iprb_n:
	inc hl
	djnz iprb_l
	ld l,a
	pop bc
	pop af
	ret
iord_vic:
	ld a,l
	and $3F
	cp $11
	jr z,iord_d011
	cp $12
	jr z,iord_d012
	cp $19
	jr z,iord_d019
	cp $1A
	jr z,iord_d01a
	cp $1E
	jr z,iord_d01e
	cp $1F
	jr z,iord_d01f
	cp $2F
	jr nc,iord_ff
	ld l,a
	ld h,VIC_REGS/256
	ld a,(hl)
	ld l,a
	pop af
	ret
iord_ff:
	ld l,$FF
	pop af
	ret
iord_d011:
	call get_raster
	ld a,h
	rrca
	and $80
	ld l,a
	ld a,(VIC_REGS+$11)
	and $7F
	or l
	ld l,a
	pop af
	ret
iord_d012:
	call get_raster
	pop af
	ret
iord_d019:
	ld a,(vic_irr)
	ld l,a
	ld a,(vic_imr)
	and l
	jr z,i19
	ld a,$80
i19:
	or l
	or $70
	ld l,a
	pop af
	ret
iord_d01a:
	ld a,(vic_imr)
	or $F0
	ld l,a
	pop af
	ret
iord_d01e:
	ld hl,coll_ss
	ld a,(hl)
	ld (hl),0
	ld l,a
	pop af
	ret
iord_d01f:
	ld hl,coll_sb
	ld a,(hl)
	ld (hl),0
	ld l,a
	pop af
	ret

; current C64 raster line -> HL (0..311).  Clobbers A.
get_raster:
	push de
	in a,(TIMER_HI)
	ld h,a
	in a,(TIMER_LO)
	ld l,a
	in a,(TIMER_HI)
	cp h
	jr z,gr_ok
	ld h,a
	in a,(TIMER_LO)
	ld l,a
gr_ok:
	; lines = t/16 - t/1024 (3.911us ticks, 63.7us lines)
	ld a,h
	rrca
	rrca
	and $3F
	ld e,a
	ld d,0
	srl h
	rr l
	srl h
	rr l
	srl h
	rr l
	srl h
	rr l
	or a
	sbc hl,de
	ld de,(raster_base)
	add hl,de
	ld de,312
gr_wrap:
	or a
	sbc hl,de
	jr nc,gr_wrap
	add hl,de
	pop de
	ret

; 16-bit Galois LFSR -> A
k_random:
	push hl
	ld hl,(rnd_state)
	srl h
	rr l
	jr nc,kr_n
	ld a,h
	xor $B4
	ld h,a
kr_n:
	ld (rnd_state),hl
	ld a,l
	pop hl
	ret

; ============================================================================
; I/O writes: HL = $D000-$DFFF, A = value.  Preserves A, F, BC, DE.
; ============================================================================
k_iowr:
	push af
	ld a,h
	cp $D4
	jr c,iowr_vic
	cp $D8
	jp c,iowr_sid
	cp $DC
	jr c,iowr_col
	jr z,iowr_cia1
	cp $DD
	jr z,iowr_cia2
	pop af
	ret
iowr_col:
	and 3
	add a,COLOR_RAM/256
	ld h,a
	pop af
	push af
	cp (hl)
	jr z,iowr_x                 ; unchanged (iowr_x restores the flags)
	pop af
	ld (hl),a
	push af
	; dirty: byte offset >> 6, bit (offset >> 3) & 7
	ld a,l
	rrca
	rrca
	rrca
	and 7
	add a,bittab & 255
	push hl
	ld l,a
	ld h,bittab/256
	ld a,(hl)
	pop hl
	push af
	ld a,l
	rlca
	rlca
	and 3
	ld l,a
	ld a,h
	sub COLOR_RAM/256           ; H is the Z80 page $2A-$2D here
	add a,a
	add a,a
	or l
	add a,cdirty & 255
	ld l,a
	ld h,cdirty/256
	pop af
	or (hl)
	ld (hl),a
	pop af
	ret
iowr_cia1:
	ld a,l
	and $0F
	jr nz,iowr_x
	pop af
	ld (cia1_pra),a
	ret
iowr_cia2:
	ld a,l
	and $0F
	jr nz,iowr_x
	pop af
	ld (cia2_pra),a
	ret
iowr_x:
	pop af
	ret
iowr_vic:
	ld a,l
	and $3F
	cp $2F
	jr nc,iowr_x
	ld l,a
	ld h,VIC_REGS/256
	pop af
	push af
	cp (hl)
	ld (hl),a
	ld a,l
	jr nz,iowr_vic_new
	cp $19                      ; IRQ acknowledge acts on every write
	jr z,iowr_d019
	jr iowr_x
iowr_vic_new:
	; $D020-$D023 (live palette slots: border/bg0/bg1/bg2) are written far
	; more often than the other special registers below (every raster-split
	; colour change), so they're checked first here instead of after 6
	; comparisons that almost always miss.
	cp $20
	jr c,ivn_rest
	cp $24
	jr nc,ivn_rest
	; $D020-$D023: live palette slots (border -> 3, bg0..bg2 -> 0..2)
	sub $20
	jr nz,iowr_bg
	ld a,PAL_BORDER+1
iowr_bg:
	dec a
	pop hl                      ; H = value written
	push hl
	call k_setlive              ; slot A, colour H
	pop af
	ret
ivn_rest:
	cp $11
	jr z,iowr_d011
	cp $12
	jr z,iowr_d012
	cp $19
	jr z,iowr_d019
	cp $1A
	jr z,iowr_d01a
	cp $1E
	jr z,iowr_x
	cp $1F
	jr z,iowr_x
	jr iowr_changed
iowr_d011:
	ld a,1
	ld (vic_changed),a
	ld a,(in_irq)
	or a
	jr nz,iowr_d012
	inc a
	ld (blank_req),a            ; mode change from main code: new screen
	dec a
	dec a
	ld (calm_flips),a           ; $FF: keep blank until the renderer settles
	call k_get_iff
	push af
	di
	ld a,8
	out (V_SEL),a
	ld a,$42                    ; blank right now, not at the next page flip
	out (V_REG),a
	pop af
	or a
	jr z,iowr_d012
	ei
iowr_d012:
	call set_line_irq
	pop af
	ret
iowr_d019:
	pop af
	push af
	cpl
	ld hl,vic_irr
	and (hl)
	ld (hl),a
	pop af
	ret
iowr_d01a:
	pop af
	push af
	and $0F
	ld (vic_imr),a
	pop af
	ret
iowr_changed:
	ld a,1
	ld (vic_changed),a
	pop af
	ret

; set live palette slot A (0..3) to C64 colour H.  Preserves BC, DE.
; The live slots are written into the palette bank that is not on screen,
; then R#13/R#15 switch to it: the beam never sees a half-written colour
; (R, G and B arrive one by one, so red->white would flash yellow).
k_setlive:
	push bc
	push de
	ld c,a
	ld a,h
	and $0F
	ld b,a
	ld hl,palette_shadow
	ld a,l
	add a,c
	ld l,a
	ld (hl),b
	call k_get_iff
	push af
	di
	ld a,(pal_bank)
	xor 1
	ld (pal_bank),a
	ld e,a                      ; e = new bank index (0/1)
	rrca
	rrca
	ld c,a                      ; bank * 64: palette pointer of its slot 0
	; IX -> bank_live[bank*4]: colours this bank's VRAM palette already holds
	ld a,e
	add a,a
	add a,a
	ld d,0
	ld e,a
	ld ix,bank_live
	add ix,de
	ld d,c                      ; d = this slot's R#14 value, starts at bank*64
	ld hl,palette_shadow
	ld b,4
ksl_slot:
	ld a,(hl)
	inc hl
	push hl
	cp (ix+0)
	jr z,ksl_skip                ; this bank's VRAM already has this colour here
	ld (ix+0),a
	ld l,a
	add a,a
	add a,l
	ld l,a
	ld h,0
	push de
	ld de,c64_rgb
	add hl,de
	pop de
	push hl
	ld a,14
	out (V_SEL),a
	ld a,d
	out (V_REG),a
	pop hl
	ld a,(hl)
	out (V_PAL),a
	inc hl
	ld a,(hl)
	out (V_PAL),a
	inc hl
	ld a,(hl)
	out (V_PAL),a
ksl_skip:
	ld a,d
	add a,4                      ; R#14 is in units of entry*4
	ld d,a
	inc ix
	pop hl
	djnz ksl_slot
	ld a,c
	rrca
	rrca
	ld c,a                      ; bank * 16
	ld a,13
	out (V_SEL),a
	ld a,c
	rrca
	rrca
	out (V_REG),a               ; PLTO5-4: bank
	ld a,15
	out (V_SEL),a
	ld a,c
	or PAL_BORDER
	out (V_REG),a               ; backdrop follows the bank
	pop af
	or a
	jp z,ksl_di
	ei
ksl_di:
	pop de
	pop bc
	ret

; program the V9990 line interrupt from the C64 raster compare value
set_line_irq:
	push de
	ld a,(VIC_REGS+$11)
	rlca
	and 1
	ld h,a
	ld a,(VIC_REGS+$12)
	ld l,a
	; v = c - RASTER_OFS for RASTER_OFS <= c <= 301, else 256
	ld de,RASTER_OFS
	or a
	sbc hl,de
	jr c,sli_border
	ld de,257
	or a
	sbc hl,de
	jr nc,sli_border
	add hl,de
	jr sli_set
sli_border:
	ld hl,222                   ; bottom border, well before the next frame
	ld a,1
	jr sli_set2
sli_set:
	xor a
sli_set2:
	ld (sli_bord),a
	; the V9990 line register only changes when the armed line does
	inc hl
	push hl
	ld de,(sli_last)
	or a
	sbc hl,de
	pop hl
	jr z,sli_di
	ld (sli_last),hl
	dec hl
	call k_get_iff
	push af
	di
	ld a,10
	out (V_SEL),a
	ld a,l
	out (V_REG),a
	ld a,h
	out (V_REG),a
	pop af
	or a
	jp z,sli_di
	ei
sli_di:
	; has the beam already passed the compare line (by less than 24 lines)?
	call get_raster              ; HL = current line
	ld a,(sli_bord)
	or a
	jr z,sli_vis
	; border slot (V9990 line 222 = C64 267): late if the beam is past it
	ld de,267
	or a
	sbc hl,de
	jr c,sli_ok
	jr sli_late
sli_vis:
	ld a,(VIC_REGS+$11)
	rlca
	and 1
	ld d,a
	ld a,(VIC_REGS+$12)
	ld e,a
	dec de                      ; a line counts as passed while the beam is on it
	or a
	sbc hl,de                   ; current - (compare - 1)
	jr c,sli_ok
	ld a,h
	or a
	jr nz,sli_ok
	ld a,l
	cp 24
	jr nc,sli_ok
sli_late:
	ld a,1
	jr sli_x
sli_ok:
	xor a                       ; the last arming decides: an earlier D011/D012
sli_x:                          ; write of the same handler may have looked late
	ld (irq_late),a
	pop de
	ret

; ---- SID ----------------------------------------------------------------
iowr_sid:
	ld a,l
	and $1F
	ld l,a
	ld h,SID_REGS/256
	ld a,l
	add a,SID_REGS & 255
	ld l,a
	pop af
	push af
	push bc
	ld b,(hl)                   ; previous value
	ld (hl),a
	ld c,a
	ld a,l
	sub SID_REGS & 255
	; control registers 4, 11, 18: gate transitions
	ld l,0
	cp 4
	jr z,isid_ctl
	inc l
	cp 11
	jr z,isid_ctl
	inc l
	cp 18
	jr nz,isid_x
isid_ctl:
	ld a,b
	xor c
	and 1
	jr z,isid_x                 ; gate unchanged
	ld h,sid_phase/256
	ld a,l
	add a,sid_phase & 255
	ld l,a
	ld a,c
	and 1
	jr z,isid_rel
	ld (hl),1                   ; attack
	jr isid_x
isid_rel:
	ld (hl),3                   ; release
isid_x:
	pop bc
	pop af
	ret

; ============================================================================
; V9990
; ============================================================================
; set V9990 palette pointer to A (palette*4)
v_palptr:
	push af
	ld a,14
	out (V_SEL),a
	pop af
	out (V_REG),a
	ret

; write register A with value L
v_wreg:
	out (V_SEL),a
	ld a,l
	out (V_REG),a
	ret

v_init:
	ld a,2                      ; reset
	out (V_SYS),a
	xor a
	out (V_SYS),a               ; MCS=0: XTAL1 21.5 MHz
	ld hl,v_init_regs
vi_loop:
	ld a,(hl)
	cp $FF
	jr z,vi_regs_done
	inc hl
	out (V_SEL),a
	ld a,(hl)
	inc hl
	out (V_REG),a
	jr vi_loop
vi_regs_done:
	; palette: live slots + fixed slots start black
	xor a
	call v_palptr
	ld b,64*3
vi_pal:
	xor a
	out (V_PAL),a
	djnz vi_pal
	; clear all 512K of VRAM with linear writes
	xor a
	out (V_SEL),a
	out (V_REG),a
	out (V_REG),a
	out (V_REG),a
	ld de,2048
vi_clr:
	ld b,0
	xor a
vi_clr2:
	out (V_VRAM),a
	djnz vi_clr2
	dec de
	ld a,d
	or e
	jr nz,vi_clr
	; interrupt line 256 until the game sets one
	ld hl,256
	ld a,10
	out (V_SEL),a
	ld a,l
	out (V_REG),a
	ld a,h
	out (V_REG),a
	ld hl,0
	ld (sli_last),hl
	ld a,7
	out (V_INT),a
	ret
v_init_regs:
	db 6, $95                   ; B3: bitmap, XTAL1, 512 px, 4 bpp
	db 7, $08                   ; PAL, non interlaced
	db 8, $C2                   ; display on, cursor off
	db 9, $03                   ; line + vblank interrupts
	db 13, $00                  ; palette mode, offset 0
	db 15, PAL_BORDER           ; backdrop
	db 16, $00
	db 17, 0, 18, 0, 19, 0, 20, 0
	db 25, 0, 26, 0, 27, 0, 28, 0
	db $FF

; C64 colours (Pepto) as V9990 5-bit R,G,B
c64_rgb:
	db  0, 0, 0,  31,31,31,  21, 7,11,  15,30,26
	db 21, 8,30,  12,26, 6,   5, 7,29,  31,31, 8
	db 24,13, 3,  15,10, 0,  30,16,16,  12,12,12
	db 18,18,18,  20,31,16,  14,16,31,  25,25,25

; ============================================================================
; input (once per frame)
; ============================================================================
read_input:
	; joystick port 1 via PSG R14 (port A selected in R15 bit 6 = 0)
	ld a,15
	out ($A0),a
	in a,($A2)
	and $BF
	out ($A1),a
	ld a,14
	out ($A0),a
	in a,($A2)
	or $E0
	ld b,a                      ; MSX: b0 up b1 down b2 left b3 right b4 trig A
	; keyboard row 8: b0 space, b4 left, b5 up, b6 down, b7 right
	in a,($AA)
	and $F0
	or 8
	out ($AA),a
	in a,($A9)
	ld c,a
	bit 5,c
	jr nz,ri1
	res 0,b
ri1:
	bit 6,c
	jr nz,ri2
	res 1,b
ri2:
	bit 4,c
	jr nz,ri3
	res 2,b
ri3:
	bit 7,c
	jr nz,ri4
	res 3,b
ri4:
	bit 0,c
	jr nz,ri5
	res 4,b
ri5:
	ld a,b
	ld (joy_state),a
	; C64 column 7: RUN/STOP (row 7) <- MSX STOP (row 7 bit 4);
	;               <- (row 1) <- MSX ESC (row 7 bit 2)
	in a,($AA)
	and $F0
	or 7
	out ($AA),a
	in a,($A9)
	ld c,a
	ld b,$FF
	bit 4,c
	jr nz,ri6
	res 7,b
ri6:
	bit 2,c
	jr nz,ri7
	res 1,b
ri7:
	ld a,b
	ld (key_rows+7),a
	ret

; ============================================================================
; SID -> PSG (once per frame)
; ============================================================================
psg_init:
	ld b,14
	ld c,0
pi_l:
	ld a,c
	out ($A0),a
	xor a
	out ($A1),a
	inc c
	djnz pi_l
	ld a,7
	out ($A0),a
	ld a,$BF                    ; all off, port A input / B output
	out ($A1),a
	ret

psg_write:                      ; register A, value L
	out ($A0),a
	ld a,l
	out ($A1),a
	ret

sound_frame:
	ld a,$BF                    ; mixer: start with everything off
	ld (k_tmp),a
	ld c,0                      ; voice
	ld ix,SID_REGS
sf_voice:
	call sid_envelope           ; A = level 0..15
	ld b,a
	; waveform: control register
	ld a,(ix+4)
	and $F8
	jr z,sf_silent
	bit 3,(ix+4)                ; test bit
	jr nz,sf_silent
	; volume * master / 16
	ld a,(SID_REGS+$18)
	and $0F
	inc a
	ld h,a
	ld a,b
	call mul4x4                 ; A = b*h/16
	ld l,a
	ld a,c
	add a,8
	call psg_write
	; tone period = 1905600 / F
	ld l,(ix+0)
	ld h,(ix+1)
	call sid_period             ; HL = PSG period (12 bit)
	ld a,c
	add a,a
	push hl
	call psg_write
	pop hl
	ld l,h
	ld a,c
	add a,a
	inc a
	call psg_write
	; mixer bits: tone enable = bit c low, noise enable = bit c+3 low
	ld a,(ix+4)
	bit 7,a
	ld a,(k_tmp)
	jr nz,sf_noise
	call sf_bit
	cpl
	and (hl)
	ld (k_tmp),a
	jr sf_next
sf_noise:
	; noise period from the frequency high byte
	ld a,(ix+1)
	cpl
	rrca
	rrca
	rrca
	and $1F
	ld l,a
	ld a,6
	call psg_write
	call sf_bit
	rlca
	rlca
	rlca
	cpl
	ld hl,k_tmp
	and (hl)
	ld (hl),a
	jr sf_next
sf_silent:
	ld a,c
	add a,8
	ld l,0
	call psg_write
sf_next:
	ld de,7
	add ix,de
	ld de,0
	inc c
	ld a,c
	cp 3
	jp nz,sf_voice
	ld a,(k_tmp)
	ld l,a
	ld a,7
	jp psg_write
sf_bit:                         ; A = 1 << c, HL = k_tmp
	push bc
	ld b,c
	inc b
	ld a,1
sfb_l:
	djnz sfb_s
	pop bc
	ld hl,k_tmp
	ret
sfb_s:
	add a,a
	jr sfb_l

; A*H/16 with A,H in 0..16 -> A
mul4x4:
	push bc
	ld b,h
	ld c,a
	xor a
	inc b
m44_l:
	dec b
	jr z,m44_d
	add a,c
	jr m44_l
m44_d:
	rrca
	rrca
	rrca
	rrca
	and $0F
	pop bc
	ret

; HL = SID frequency -> HL = PSG tone period (1905600 / F, clamped to 12 bit)
sid_period:
	ld a,h
	cp 2
	jr nc,sdp_ok_range           ; F < 512 -> period >= 3722: clamp
	ld hl,$0FFF
	ret
sdp_ok_range:
	push bc
	push de
	ex de,hl                    ; DE = F
	ld a,$1D                    ; A:HL = 1905600 = $1D13C0
	ld hl,$13C0
	bit 7,d
	jr z,sdp_div
	srl d                       ; keep the remainder within 16 bits
	rr e
	srl a                       ; dividend / 2
	rr h
	rr l
sdp_div:
	ld bc,0                     ; remainder
	push af
	ld a,24
	ld (k_tmp+4),a
	pop af
sdp_l:
	add hl,hl
	rla
	rl c
	rl b
	push hl
	ld h,b
	ld l,c
	or a
	sbc hl,de
	jr c,sdp_no
	ld b,h
	ld c,l
	pop hl
	inc l                       ; quotient bit
	jr sdp_nx
sdp_no:
	pop hl
sdp_nx:
	push hl
	ld hl,k_tmp+4
	dec (hl)
	pop hl
	jr nz,sdp_l
	or a                        ; quotient in A:HL
	jr nz,sdp_clamp
	ld a,h
	cp $10
	jr c,sdp_done
sdp_clamp:
	ld hl,$0FFF
sdp_done:
	pop de
	pop bc
	ret

; ADSR emulation for voice C (IX -> its SID registers) -> A = level 0..15.
; Levels are 8.8 fixed point; clobbers B, DE, HL.
sid_envelope:
	ld a,c
	add a,a
	add a,sid_lvl & 255
	ld l,a
	ld h,sid_lvl/256
	ld e,(hl)
	inc hl
	ld d,(hl)                   ; DE = level
	ld a,c
	add a,sid_phase & 255
	ld l,a
	ld h,sid_phase/256
	push hl                     ; phase pointer
	ld a,(hl)
	cp 1
	jr z,se_attack
	cp 2
	jr z,se_decay
	cp 3
	jr z,se_release
	ld de,0
	jr se_store
se_attack:
	ld a,(ix+5)
	rrca
	rrca
	rrca
	rrca
	call env_rate
	add hl,de
	ex de,hl
	ld a,d
	cp $0F
	jr c,se_store
	ld de,$0F00
	pop hl
	ld (hl),2
	push hl
	jr se_store
se_decay:
	ld a,(ix+6)
	rrca
	rrca
	rrca
	rrca
	and $0F
	ld b,a                      ; sustain level
	cp d
	jr nc,se_hold
	ld a,(ix+5)
	call env_rate
	call div3_hl
	ex de,hl
	or a
	sbc hl,de
	ex de,hl
	jr c,se_hold
	ld a,d
	cp b
	jr nc,se_store
se_hold:
	ld d,b
	ld e,0
	jr se_store
se_release:
	ld a,(ix+6)
	call env_rate
	call div3_hl
	ex de,hl
	or a
	sbc hl,de
	ex de,hl
	jr nc,se_store
	ld de,0
	pop hl
	ld (hl),0
	push hl
se_store:
	pop hl
	ld a,c
	add a,a
	add a,sid_lvl & 255
	ld l,a
	ld h,sid_lvl/256
	ld (hl),e
	inc hl
	ld (hl),d
	ld a,d
	ret

; A low nibble = SID rate index -> HL = level increment per frame (8.8)
env_rate:
	and $0F
	add a,a
	ld l,a
	ld h,0
	push de
	ld de,env_rates
	add hl,de
	pop de
	ld a,(hl)
	inc hl
	ld h,(hl)
	ld l,a
	ret
div3_hl:                        ; HL = HL/3 (approx: *85/256)
	push de
	ld d,h
	ld e,l
	srl h
	rr l
	srl h
	rr l                        ; /4
	push hl
	srl h
	rr l
	srl h
	rr l                        ; /16
	pop de
	add hl,de                   ; /4 + /16
	ld d,h
	ld e,l
	srl h
	rr l
	srl h
	rr l
	srl h
	rr l
	srl h
	rr l
	add hl,de                   ; *(1+1/16)
	pop de
	ret
; 15*256*20ms / attack time (2,8,16,24,38,56,68,80,100,250,500,800,1000,3000,5000,8000 ms)
env_rates:
	dw 38400, 9600, 4800, 3200, 2021, 1371, 1129, 960
	dw 768, 307, 154, 96, 77, 26, 15, 10

	include "build/dispatch.asm"
region_k2_end:
