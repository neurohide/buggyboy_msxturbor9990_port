; native $1452-$1485: copy the 8 sprites' X, Y, pointer and colour from the
; game's tables to the VIC, then $D01D/$D017/$D010.  6502 exit state as the
; original: X = $FE, Y = $FF, A = ($02E5) with N/Z from it; B = D = 0.
	push ix
	ld ix,$148D                 ; game X table, sprite 7
	ld hl,VIC_REGS+$0E         ; sprite 7 X register
	ld de,VIC_REGS+$2E         ; sprite 7 colour register
	ld bc,7                    ; B = 0, C = sprite (6502 X)
	call k_vic_on              ; all pointer writes target the VIC bank
N1452_l:
	ld a,(ix+0)
	cp (hl)                     ; $D000+2x: X
	jr z,N1452_xsame
	ld (hl),a
	ld a,1
	ld (vic_changed),a
N1452_xsame:
	inc hl
	ld a,(ix+8)
	cp (hl)                     ; $D001+2x: Y
	jr z,N1452_ysame
	ld (hl),a
	ld a,1
	ld (vic_changed),a
N1452_ysame:
	dec hl
	push hl
	ld a,(ix+16)
	ld hl,$47F8
	add hl,bc
	call k_vwrmf                ; sprite pointer; VIC bank already mapped
	pop hl
	ex de,hl                    ; colour register in HL, X register in DE
	ld a,(ix+24)
	cp (hl)                     ; $D027+x: colour
	jr z,N1452_csame
	ld (hl),a
	ld a,1
	ld (vic_changed),a
N1452_csame:
	ex de,hl
	dec ix
	dec hl
	dec hl
	dec de
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
	pop ix
	ld d,0
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
