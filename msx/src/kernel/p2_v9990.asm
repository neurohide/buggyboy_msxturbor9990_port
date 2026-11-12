; V9990 palette pointer, display initialization, palette data, and register setup.
; Routines: v_palptr, v_init.

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
	call sli_zero
	ld a,7
	out (V_INT),a
	ret
v_init_regs:
	db 6, $95                   ; B3: bitmap, XTAL1, 512 px, 4 bpp
	db 7, $08                   ; PAL, non interlaced
	db 8, $C2                   ; display on, cursor off
	db 9, $03                   ; line + vblank interrupts
	db 46, $FF, 47, $FF          ; command write mask: all bits (render never changes it)
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
