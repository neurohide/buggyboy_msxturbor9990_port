; Native $9A2A-$9A92: advance the HUD's three two-character counters.
; Screen pairs live at $44BE/$44C0/$44C2 in the VIC bank.  Preserve the
; original X exit value; the caller's Y is untouched.
	ld a,($9A93)
	ld hl,$0337
	cp (hl)
	ret z
	jp nc,N9A2A_up
	ld a,(hl)
	or a
	ret z
	dec (hl)
	ld e,4
	call k_vic_on
	call N9A2A_dirty
N9A2A_down_loop:
	ld d,0
	ld hl,$C4BE
	add hl,de
	dec (hl)
	dec (hl)
	ld a,(hl)
	inc hl
	dec (hl)
	dec (hl)
	dec hl
	cp $45
	jr nz,N9A2A_done
	ld a,$59
	ld (hl),a
	inc hl
	ld a,$5A
	ld (hl),a
	dec e
	dec e
	jp p,N9A2A_down_loop
	jr N9A2A_done
N9A2A_up:
	ld a,(hl)
	cp $E2
	ret z
	inc (hl)
	ld e,4
	call k_vic_on
	call N9A2A_dirty
N9A2A_up_loop:
	ld d,0
	ld hl,$C4BE
	add hl,de
	inc (hl)
	inc (hl)
	ld a,(hl)
	inc hl
	inc (hl)
	inc (hl)
	dec hl
	cp $5B
	jr nz,N9A2A_done
	ld a,$47
	ld (hl),a
	inc hl
	ld a,$48
	ld (hl),a
	dec e
	dec e
	jp p,N9A2A_up_loop
N9A2A_done:
	call k_c2
	ret
N9A2A_dirty:
	; $44BE-$44C3 spans two dirty groups.
	ld a,(VDIRTY+$12)
	or $80
	ld (VDIRTY+$12),a
	ld a,(VDIRTY+$13)
	or 1
	ld (VDIRTY+$13),a
	ret
