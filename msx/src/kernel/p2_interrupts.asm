; V9990 interrupt dispatch, frame scheduling, and timeline snapshots.
; Routines: int_dispatch, int_hline, int_vblank, k_render_now, vbl_catchup, vbl_border, tl_*.

; interrupts
; ============================================================================
int_dispatch:
	in a,(V_INT)
	push af
	and 3
	cp 3
	if MSX2PLUS
	jr id_normal
	else
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
	endif
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
	if MSX2PLUS
	ld a,2
	out (V_INT),a
	ret                         ; only the kerb chain arms lines (k_int_kb)
	else
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
	if MSX2PLUS
	call arm_next               ; keep the raster clock running
	endif
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
	ld a,1
	ld (in_irq),a
	call irq_native
	jr z,ih_nat
	ld bc,0
	ld de,0
	ld a,($FFFE)
	ld l,a
	ld a,(vec_ffff)
	ld h,a
	call k_callc64
ih_nat:
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
	endif                       ; (MSX2+: int_hline only acknowledges)

if MSX2PLUS
;  Arm the V9990 line IRQ at the C64 compare line (soft_target).  The
; MSX2+ has no free-running timer and line IRQs taken late (the C64
; handlers run with interrupts off) would break a chain of clock ticks, so
; only the compare line is armed; raster reads step the clock (get_raster).
; V9990 line IRQs fire for C64 lines 45..RASTER_LAST (V9990 0..256): a
; compare line outside is served at RASTER_LAST.  Interrupts off.  Uses A, DE, HL.
arm_next:
	ret                         ; no line IRQs: vbl_catchup runs the chain
endif

int_vblank:
	ld a,1
	out (V_INT),a
	; a kerb band chain still running missed a line: drop it (vbl_catchup
	; runs the band-12 handler, its line is the armed C64 one)
	ld hl,kb_n
	ld a,(hl)
	or a
	jr z,ivb_nokb
	ld (hl),0
	call sli_zero
ivb_nokb:
	; show the page the renderer finished
	ld a,(flip_pending)
	or a
	jr z,ivb_noflip
	ld a,(calm_flips)
	inc a
	jr z,ivb_noflip          ; keep the visible page while a new screen is built
	xor a
	ld (flip_pending),a
	ld a,(busy_vbls)
	cp 150
	jr nc,ivb_busy_keep         ; preserve the timeout latch across page flips
	ld a,(calm_flips)
	inc a
	jr z,ivb_busy_keep          ; preserve blank-transition time across flips
	xor a
	ld (busy_vbls),a
ivb_busy_keep:
	ld a,8
	out (V_SEL),a
	ld hl,calm_flips
	ld a,(hl)
	or a
	jr z,ivb_disp
	inc a
	jr z,ivb_disp              ; $FF: hold front page; renderer builds the back page
	dec (hl)
ivb_disp:
	ld a,$C2                    ; keep the last complete page visible
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
	if MSX2PLUS
	ld a,(race_wait)
	or a
	jr z,ivb_notwait
	ld a,8
	out (V_SEL),a
	ld a,$C2                    ; show the last complete page during race setup
	out (V_REG),a
ivb_notwait:
	endif
	if MSX2PLUS=0
	xor a
	out (TIMER_LO),a            ; raster clock restarts at C64 line 257
	endif
	ld hl,257
	ld (raster_base),hl
	if MSX2PLUS
	call arm_next
	endif
	ld hl,frame_count
	inc (hl)
	if MSX2PLUS
	ld a,(race_wait)
	or a
	jr z,ivb_timeout_check
	ld hl,busy_vbls
	inc (hl)
	jr nz,ivb_timeout_done
	ld hl,race_wait
	inc (hl)                    ; release after about 15 seconds if no road draw returns
	ld a,(hl)
	cp 4
	jr c,ivb_timeout_done
	call race_ready
	jr ivb_timeout_done
ivb_timeout_check:
	endif
	ld a,(calm_flips)
	inc a
	jr nz,ivb_timeout_done
	ld hl,busy_vbls
	inc (hl)
	ld a,(hl)
	cp 150
	jr c,ivb_timeout_done
	xor a
	ld (calm_flips),a           ; release blank after 150 vblanks
	ld a,150
	ld (busy_vbls),a            ; suppress repeat blanking until rows settle
ivb_timeout_done:
	if MSX2PLUS=0
	call vbl_catchup
	endif
	call read_input
	ld a,SEG_RENDER             ; sound code lives in the render segment
	out (PORT_P1),a
	call sound_frame
	ld a,(cur_p1)
	out (PORT_P1),a
	if MSX2PLUS
	ld a,$FF
	ld (VIC_REGS+$21),a        ; shadow differs: iowf_D021 must write the live palette
	ld a,(top_col)              ; the kerb bands and later handlers left their
	call iowf_D021              ; last colour in the live palette: the next frame
	; kerb bands: replay the last list every frame (on even frames
	; vbl_catchup's kb_start runs ~10-15 ms later, often past band 1), then
	; stage band 1's colour
	ld a,(kb_n0)
	or a
	jr z,ivb_kbs
	ld (kb_n),a
	ld hl,kb_list
	ld (kb_ptr),hl
	or 1
	call kb_due
ivb_kbs:
	ld a,(kb_n)
	or a
	jr z,ivb_kbx
	ld hl,(kb_ptr)
	inc hl
	ld a,(hl)
	call kb_prep
ivb_kbx:
	; the C64 handlers run after the frame's palette is set up: they take
	; ~10 ms, and their D021 writes only reach the timeline (iowr_bg)
	call vbl_catchup
	endif
	if MSX2PLUS
	; odd vblanks run no C64 IRQs: keep the last complete timeline for the
	; renderer (an empty one would draw every row in the top-of-frame mode)
	ld a,(frame_count)
	and CHAIN_MASK
	jr z,ivb_even
	ld a,(rendering)
	or a
	ret nz
	jp ivb_decide
ivb_even:
	endif
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
ivb_decide:
	if MSX2PLUS
	ld a,(race_wait)
	or a
	ret nz                      ; give setup all CPU until the first road draw
	endif
                       ; starts with the colour of the line-0 handler
	; The game's main loop only gets the CPU the renderer leaves free (it fell
	; to ~2 iterations/s while the renderer ran at every vblank).  Render only
	; once the main code has reached a frame sync (polled the raster) since the
	; last render, or after 4 vblanks without one, or while a new screen is
	; being built (calm_flips = $FF).
	ld a,(mt_sync)
	or a
	jr nz,ivb_go
	ld a,(calm_flips)
	inc a
	jr z,ivb_go
	ld b,1                      ; vblanks to skip without a sync
	ld hl,mt_head
	ld a,(hl)
	or a
	jr z,ivb_skip
	dec (hl)                    ; race loop: wait for its pass (fallback 12)
	ld b,12
ivb_skip:
	ld hl,skip_n
	ld a,(hl)
	cp b
	jr nc,ivb_go
	inc (hl)
	ret
ivb_go:
	xor a
	ld (skip_n),a
	ld (mt_sync),a
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

; main code, end of a race-loop pass: run the render it asked for now instead
; of at the next vblank (the wait for that vblank was idle time).  Keeps every
; register; the vblank ISR sees `rendering` set, as for its own renders.
sli_zero:
	if MSX2PLUS
	ret
	else
	ld hl,0
	ld (sli_last),hl
	ret
	endif

; main code, end of a race-loop pass: run the render it asked for now instead
; of at the next vblank (the wait for that vblank was idle time).  Same
; environment as the vblank ISR gives it: C64 block 3 in page 3 (page 2 holds
; block 2 in main code already).  Keeps BC, DE, HL (A is the caller's scratch).
k_render_now:
	if MSX2PLUS
	ld a,(race_wait)
	or a
	ret nz
	endif
	push bc
	push de
	push hl
	ld a,(cur_p3)
	push af
	call k_c2
	di
	call ivb_go
	ei
	pop af
	ld (cur_p3),a
	out (PORT_P3),a
	pop hl
	pop de
	pop bc
	ret

if MSX2PLUS
; Called when either road drawer finishes. Preserve the translated 6502 state.
race_ready:
	push af
	ld a,(race_wait)
	or a
	jr z,rr_done
	xor a
	ld (race_wait),a
	ld (calm_flips),a
	ld (blank_req),a
	ld a,150
	ld (busy_vbls),a            ; first full redraw can show immediately
rr_done:
	pop af
	ret
endif

; A raster IRQ armed for a visible line that the beam has already passed was
; missed (the line was programmed a moment too late): run the C64 handlers
; now, at the bottom of the screen, so the chain keeps its 50 Hz rhythm.
vbl_catchup:
	if MSX2PLUS
	; the Z80 cannot run the C64 IRQ chain and render in one frame: game
	; IRQs at 25 Hz, the other vblank is the renderer's
	ld a,(frame_count)
	and CHAIN_MASK
	ret nz
	endif
	ld b,16                     ; at most this many handlers
	if MSX2PLUS
	; MSX2+: no line IRQs (taken late they broke the chain); the whole
	; frame's C64 IRQ chain runs here, in raster order from the vblank line.
	; The timeline keeps each handler's line for the renderer.
	ld b,32
	ld hl,$FFFF
	ld (vc_last),hl
	xor a
	ld (irq_late),a
	endif
vc_loop:
	ld a,(vic_imr)
	and 1
	ret z
	if MSX2PLUS
	ld a,(VIC_REGS+$11)
	rlca
	and 1
	ld h,a
	ld a,(VIC_REGS+$12)
	ld l,a
	ld de,-257
	add hl,de
	jr c,vck_k                  ; key = (line - 257) mod 312
	ld de,312
	add hl,de
vck_k:
	ld de,(vc_last)
	ld a,d
	and e
	inc a
	jr z,vck_run                ; first handler of the frame
	push hl
	or a
	sbc hl,de
	pop hl
	ret c                       ; compare line wrapped: next frame
	ret z
vck_run:
	ld (vc_last),hl
	jr vc_run
	endif
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
	if MSX2PLUS
	ld a,1
	ld (in_irq),a
	call irq_native             ; kerb bands natively (Z: done)
	jr z,vc_nat
	endif
	ld bc,0
	ld de,0
	ld a,($FFFE)
	ld l,a
	ld a,(vec_ffff)
	ld h,a
	ld a,1
	ld (in_irq),a
	call k_callc64
vc_nat:
	xor a
	ld (in_irq),a
	if MSX2PLUS
	ld hl,(irq_line)            ; a handler above the first visible line (51)
	ld a,h                      ; sets the colour of the top of the frame
	or a
	jr nz,vcn_nt
	ld a,l
	cp 52
	jr nc,vcn_nt
	ld a,(VIC_REGS+$21)
	ld (top_col),a
vcn_nt:
	endif
	call tl_snapshot
	pop bc
	dec b
	jp nz,vc_loop
	ret

; the border-slot IRQ (C64 raster 0, top of the frame) was armed too late:
; run it now that the new frame's timeline is open
vbl_border:
	if MSX2PLUS
	ld a,(frame_count)
	and CHAIN_MASK
	ret nz
	endif
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
	ld a,6                      ; 48 bytes: 8 x ldi per pass (ldir costs 21 T/byte, ldi 16)
tlf_l:
	ldi
	ldi
	ldi
	ldi
	ldi
	ldi
	ldi
	ldi
	dec a
	jr nz,tlf_l
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
