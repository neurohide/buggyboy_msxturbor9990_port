; native $1452-$1485: copy the 8 sprites' X, Y, pointer and colour from the
; game's tables to the VIC, then $D01D/$D017/$D010.  6502 exit state as the
; original: X = $FF, Y = $FE, A = ($02E5) with N/Z from it.
	ld c,7                      ; C = sprite (6502 X)
N1452_l:
	ld e,c
	sla e                       ; E = 2 * sprite (D = 0)
	ld hl,$1486
	add hl,bc
	ld a,(hl)
	ld hl,VIC_REGS+$00
	add hl,de
	call N1452_set              ; $D000+2x: X
	ld hl,$148E
	add hl,bc
	ld a,(hl)
	ld hl,VIC_REGS+$01
	add hl,de
	call N1452_set              ; $D001+2x: Y
	ld hl,$1496
	add hl,bc
	ld a,(hl)
	ld hl,$47F8
	add hl,bc
	call k_vwrl                 ; sprite pointer in the VIC bank
	ld hl,$149E
	add hl,bc
	ld a,(hl)
	ld hl,VIC_REGS+$27
	add hl,bc
	call N1452_set              ; $D027+x: colour
	dec c
	jp p,N1452_l
	ld a,($02E3)
	ld hl,VIC_REGS+$1D
	call N1452_set
	ld a,($02E4)
	ld hl,VIC_REGS+$17
	call N1452_set
	ld a,($02E5)
	ld hl,VIC_REGS+$10
	call N1452_set
	call k_c2                   ; leave with C64 block 3 mapped (caller's state)
	ld e,$FF
	ld c,$FE
	ld a,($02E5)
	or a
	ret
N1452_set:                      ; plain VIC register: store, flag a change (A clobbered)
	cp (hl)
	ret z
	ld (hl),a
	ld a,1
	ld (vic_changed),a
	ret
