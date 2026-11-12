; Startup and initial device state.
; Routines: k_init, k_all_dirty.

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
