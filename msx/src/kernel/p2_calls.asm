; Translated-code calls, address lookup, escape, restart, and fatal handling.
; Routines: k_farcall, k_jmpind, k_callc64, k_lookup, k_escape, k_reset_ctx, k_restart, k_fatal.

; far calls between translated code segments
;   call k_farcall / db seg / dw target    (preserves A, F, BC, DE)
; ============================================================================
k_farcall:
	ex af,af'
	pop hl                      ; -> parameters
	inc hl
	inc hl
	inc hl
	push hl                     ; caller's return address
	ld a,(cur_p1)
	push af                     ; caller's segment
	push de
	dec hl
	ld d,(hl)
	dec hl
	ld e,(hl)                   ; DE = target
	dec hl
	ld a,(hl)                   ; A = segment
	ld hl,fc_epilogue
	ex (sp),hl                  ; epilogue on the stack, HL = caller's DE
	ex de,hl
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
	call k_map_c2
	call k_c2
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
