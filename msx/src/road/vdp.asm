; Second 4K of SEG_ROAD, executed in page 2 while the renderer stays in page 1.
; RLE records made by the native edges appear at $A000 here. Convert their
; two-bit values into horizontal LMMV spans, merging across cell boundaries.
; Uniform bytes contribute 12 pixels at once. No cell shadow or expanded
; 12x8 CPU pixel buffer is used. Caller maps SEG_VIC back into page 2.
	org $9000
road_vdp_start:
	; CPU $4800-$56FF is the producer's line-major byte plane. Its final
	; portion overlaps this image's initial padding in the same mapper bank.
	defs $9800-$,0
rdv_row:
	ld a,(row_mode)
	cp 3
	jp nz,rdv_reject
	ld a,(cur_row)
	ld e,a
	ld d,0
	ld hl,row320
	add hl,de
	add hl,de
	ld e,(hl)
	inc hl
	ld d,(hl)
	ld hl,$2000
	add hl,de
	ld de,(row_bmoff)
	or a
	sbc hl,de
	jr nz,rdv_reject
	ld a,(cur_row)
	call row_y_clean
	ld (rdv_y),hl
	ld hl,1
	ld (cmdblk+10),hl
	ld a,SEG_VIC
	ld (cur_p3),a
	out (PORT_P3),a
	ld hl,(row_scr)
	set 6,h                     ; page-2 VIC address -> page-3 VIC address
	ld de,(row_cram)
	ld iy,rdv_colors
	ld b,40
rdv_palette:
	ld a,(hl)
	ld (rdv_screen),a
	inc hl
	push hl
	ld (iy+0),0
	rrca
	rrca
	rrca
	rrca
	and 15
	call fix_slot
	ld (iy+1),a
	ld a,(rdv_screen)
	and 15
	call fix_slot
	ld (iy+2),a
	ld a,(de)
	and 15
	call fix_slot
	ld (iy+3),a
	inc de
	inc iy
	inc iy
	inc iy
	inc iy
	pop hl
	djnz rdv_palette
	ld a,(cur_row)
	sub 14
	add a,a
	add a,a
	add a,a
	ld l,a
	ld h,0
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl
	ld d,h
	ld e,l
	add hl,hl
	add hl,hl
	add hl,de
	ld de,$A000
	add hl,de
	ld (rdv_record),hl
	xor a
	ld (rdv_line),a
	jr rdv_scanline
rdv_reject:
	ld a,1
	or a
	ret
; Merge identical adjacent RLE scanlines into one taller V9990 fill.
; Palette and horizontal offset are constant throughout this character row.
rdv_scanline:
	call rdv_count_height
	ld hl,(rdv_y)
	ld (cmdblk+6),hl
	ld a,(row_xoff)
	ld l,a
	ld h,0
	ld de,SCREEN_X
	add hl,de
	ld (rdv_x),hl
	ld hl,0
	ld (rdv_width),hl
	ld hl,(rdv_record)
	ld ix,rdv_colors
	xor a
	ld (rdv_column),a
rdv_run:
	ld a,(hl)
	ld (rdv_end),a
	inc hl
	ld a,(hl)
	ld (rdv_pattern),a
	inc hl
	ld (rdv_ptr),hl
rdv_byte:
	ld a,(rdv_pattern)
	ld b,12
	or a
	jr z,rdv_uniform
	cp $55
	ld a,1
	jr z,rdv_uniform
	ld a,(rdv_pattern)
	cp $AA
	ld a,2
	jr z,rdv_uniform
	ld a,(rdv_pattern)
	cp $FF
	ld a,3
	jr z,rdv_uniform
	ld a,(rdv_pattern)
	ld (rdv_bits),a
	ld a,4
	ld (rdv_pixels),a
rdv_pixel:
	ld a,(rdv_bits)
	rlca
	rlca
	ld (rdv_bits),a
	and 3
	ld b,3
	call rdv_value
	ld hl,rdv_pixels
	dec (hl)
	jr nz,rdv_pixel
	jr rdv_next_byte
rdv_uniform:
	call rdv_value
rdv_next_byte:
	inc ix
	inc ix
	inc ix
	inc ix
	ld hl,rdv_column
	inc (hl)
	ld a,(rdv_end)
	cp (hl)
	jr nz,rdv_byte
	ld a,(hl)
	cp 40
	ld hl,(rdv_ptr)
	jr c,rdv_run
	call rdv_flush
	ld a,(rdv_height)
	ld e,a
	ld d,0
	ld hl,(rdv_y)
	add hl,de
	ld (rdv_y),hl
	ld hl,(rdv_record)
	ld bc,80
rdv_advance:
	add hl,bc
	dec e
	jr nz,rdv_advance
	ld (rdv_record),hl
	ld a,(rdv_height)
	ld hl,rdv_line
	add a,(hl)
	ld (hl),a
	cp 8
	jp c,rdv_scanline
	ld a,SEG_SHADOW
	ld (cur_p3),a
	out (PORT_P3),a
	ld a,(row_csel)
	or a
	ld a,0
	jr nz,rdv_border
	inc a
rdv_border:
	ld (csf_need),a
	call csel_fix
	xor a
	ret

rdv_count_height:
	ld a,8
	ld hl,rdv_line
	sub (hl)
	ld b,a
	ld c,1
	ld hl,(rdv_record)
	ld de,80
	add hl,de
	ex de,hl
	ld hl,(rdv_record)
rdv_height_next:
	ld a,c
	cp b
	jr z,rdv_height_done
	push bc
	push hl
	push de
rdv_height_pair:
	ld a,(de)
	cp (hl)
	jr nz,rdv_height_diff
	ld b,a
	inc hl
	inc de
	ld a,(de)
	cp (hl)
	jr nz,rdv_height_diff
	inc hl
	inc de
	ld a,b
	cp 40
	jr c,rdv_height_pair
	pop hl
	ld de,80
	add hl,de
	ex de,hl
	pop hl
	pop bc
	inc c
	jr rdv_height_next
rdv_height_diff:
	pop de
	pop hl
	pop bc
rdv_height_done:
	ld a,c
	ld (rdv_height),a
	ld l,c
	ld h,0
	ld (cmdblk+10),hl
	ret

rdv_value:                      ; A = 2-bit value, B = pixel width
	push ix
	pop hl
	ld e,a
	ld d,0
	add hl,de
	ld a,(hl)
	ld (rdv_addcol),a
	ld a,b
	ld (rdv_addwidth),a
	ld hl,(rdv_width)
	ld a,h
	or l
	jr z,rdv_new
	ld a,(rdv_addcol)
	ld hl,rdv_color
	cp (hl)
	jr z,rdv_extend
	call rdv_flush
rdv_new:
	ld a,(rdv_addcol)
	ld (rdv_color),a
rdv_extend:
	ld a,(rdv_addwidth)
	ld e,a
	ld d,0
	ld hl,(rdv_width)
	add hl,de
	ld (rdv_width),hl
	ret
rdv_flush:
	ld hl,(rdv_x)
	ld (cmdblk+4),hl
	ld de,(rdv_width)
	add hl,de
	ld (rdv_x),hl
	ld (cmdblk+8),de
	ld a,(rdv_color)
	ld b,a
	add a,a
	add a,a
	add a,a
	add a,a
	or b
	call lmmv
	ld hl,0
	ld (rdv_width),hl
	ret

rdv_y: dw 0
rdv_x: dw 0
rdv_width: dw 0
rdv_record: dw 0
rdv_ptr: dw 0
rdv_screen: db 0
rdv_line: db 0
rdv_height: db 0
rdv_column: db 0
rdv_end: db 0
rdv_pattern: db 0
rdv_bits: db 0
rdv_pixels: db 0
rdv_color: db 0
rdv_addcol: db 0
rdv_addwidth: db 0
rdv_colors: ds 160
	defs $A000-$,0
road_vdp_end:
