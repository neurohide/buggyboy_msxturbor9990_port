; Generic C64 memory and I/O reads and writes, including the C64 $FFFF vector.
; Routines: k_grd, k_grd_ram, k_gwr, k_gwr_ram, k_vecwr.

; generic read: HL = any C64 address -> L
k_grd:
	push af
	ld a,h
	cp $40
	jr c,grd_direct
	cp $80
	jr c,grd_vic
	cp $D0
	jr c,grd_direct
	cp $E0
	jr c,grd_io
	inc a
	jr nz,grd_direct
	ld a,l
	inc a
	jr nz,grd_direct            ; $FFxx except $FFFF
	ld a,(vec_ffff)
	ld l,a
	pop af
	ret
grd_direct:
	ld l,(hl)
	pop af
	ret
grd_vic:
	jp k_vrd1
grd_io:
	pop af
	jp k_iord

; generic read with all RAM visible ($D000-$DFFF is RAM)
k_grd_ram:
	push af
	ld a,h
	cp $40
	jr c,grd_direct
	cp $80
	jr c,grd_vic
	jr grd_direct

; generic write: HL = any C64 address, A = value
k_gwr:
	push af
	ld a,h
	cp $40
	jr c,gwr_direct
	cp $80
	jr c,gwr_vic
	cp $D0
	jr c,gwr_direct
	cp $E0
	jr c,gwr_io
	inc a
	jr nz,gwr_direct
	ld a,l
	inc a
	jr nz,gwr_direct
	pop af
	ld (vec_ffff),a
	ret
gwr_direct:
	pop af
	ld (hl),a
	ret
gwr_vic:
	jp k_vwr1
gwr_io:
	pop af
	jp k_iowr

k_gwr_ram:
	push af
	ld a,h
	cp $40
	jr c,gwr_direct
	cp $80
	jr c,gwr_vic
	jr gwr_direct

; C64 $FFFF (lives in a kernel variable; Z80 $FFFF is the sub-slot register)
k_vecwr:
	ld (vec_ffff),a
	ret

