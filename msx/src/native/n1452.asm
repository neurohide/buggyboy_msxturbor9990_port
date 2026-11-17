; Native $1452-$1485. Source tables are consecutive: X, Y, pointers, colours.
; Compare linear streams and collect changes instead of marking every register.
; Exit: X=$FF, Y=$FE, A=($02E5), N/Z from A; B=D=0. IX/IY kept.
	call k_vic_on
	ld hl,$1486
	ld de,VIC_REGS
	ld c,0                      ; any X/Y/colour register changed
	call N1452_xy
	ld e,1
	call N1452_xy
	; All eight sprite pointers occupy the same 8-byte dirty group.
	; No $FFFF subslot special case is possible for this fixed destination.
	ld de,$C7F8
	ld b,8
	push bc
	ld c,0
N1452_ptr:
	ld a,(de)
	cp (hl)
	jr z,N1452_psame
	ld a,(hl)
	ld (de),a
	ld c,$80
N1452_psame:
	inc l
	inc e
	djnz N1452_ptr
	ld a,(VDIRTY+$1F)
	or c
	ld (VDIRTY+$1F),a
	pop bc
	ld de,VIC_REGS+$27
	ld b,8
N1452_col:
	ld a,(de)
	cp (hl)
	jr z,N1452_csame
	ld a,(hl)
	ld (de),a
	ld c,1
N1452_csame:
	inc l
	inc e
	djnz N1452_col
	ld a,c
	or a
	jr z,N1452_regs_done
	ld a,1
	ld (vic_changed),a
N1452_regs_done:
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

; Eight linear source bytes to even/odd VIC sprite registers. C accumulates
; changes across both streams; all addresses remain within their initial page.
N1452_xy:
	ld b,8
N1452_xy_loop:
	ld a,(de)
	cp (hl)
	jr z,N1452_xysame
	ld a,(hl)
	ld (de),a
	ld c,1
N1452_xysame:
	inc l
	inc e
	inc e
	djnz N1452_xy_loop
	ret
