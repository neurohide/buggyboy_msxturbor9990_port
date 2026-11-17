; Copy the 13-character IRQ table slice indexed by the current character.
; The IRQ epilogue at $144C restores the translated registers and flags.
	ld e,a
	ld hl,$ECC9
	add hl,de
	ld de,$14A6
	ld bc,13
	ldir
	jp T_11B0
