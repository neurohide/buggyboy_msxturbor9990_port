; Native $9BE0-$9BF1: carry a HUD timer digit across $44DE-$44E1.
; E is the original X (2 or 3), C is the original Y.  The translated
; continuation at $9BF2 updates the other HUD fields.
	call k_vic_on
	ld a,(VDIRTY+$13)
	or $18                     ; $44D8-$44E7: both dirty groups of the digits
	ld (VDIRTY+$13),a
N9BE0_loop:
	ld d,0
	ld hl,$C4DE
	add hl,de
	inc (hl)
	ld a,(hl)
	cp $3A
	jr nz,N9BE0_done
	ld a,$30
	ld (hl),a
	dec e
	jp p,N9BE0_loop
N9BE0_done:
	call k_c2
	jp T_9BF2
