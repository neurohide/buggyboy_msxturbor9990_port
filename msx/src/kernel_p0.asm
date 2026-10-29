; Page-0 resident kernel.  Lives in pages of the C64 image that contain only
; 6502 code (which is never read as data once translated).  Everything that
; remaps page 2 or that must be reachable from the IM2 vector is here.
;
; Conventions for helpers called from translated code:
;   in:  HL = C64 address, A = value (writes)
;   out: L  = value (reads)
;   preserve A, F, BC, DE; clobber HL (and IX where noted)

; ============================================================================
; region $27FF-$28FF: IM2 vector and interrupt entry
; ============================================================================
	org $27FF
region_im2_start:
	dw k_int

; Line interrupts only apply the palette schedule (road stripes) and must be
; quick: they use page 0 alone, whatever the other pages hold.
k_int:
	push af
	ld a,1
	out (VDP_CTRL),a
	ld a,$8F
	out (VDP_CTRL),a
	in a,(VDP_CTRL)             ; S#1: bit 0 = line interrupt (cleared by the read)
	rrca
	jr nc,ki_frame
	push hl
	push bc
	ld hl,(ps_ptr)
	ld a,(hl)
	inc a
	jr z,kil_done               ; schedule already finished
kil_grp:
	ld b,(hl)                   ; line of this group of entries
kil_ent:
	inc hl
	ld a,(hl)                   ; slot
	inc hl
	out (VDP_CTRL),a
	ld a,$90                    ; R#16: palette pointer
	out (VDP_CTRL),a
	ld a,(hl)
	inc hl
	out (VDP_PAL),a
	ld a,(hl)
	inc hl
	out (VDP_PAL),a
	ld a,(hl)                   ; next entry's line
	cp b
	jr z,kil_ent
	ld (ps_ptr),hl
	cp $FF
	jr z,kil_off
	sub b
	cp 3
	jr c,kil_grp                ; at most 2 lines on: the interrupt would be late
	ld a,(hl)
	out (VDP_CTRL),a
	ld a,$93                    ; R#19: next interrupt line
	out (VDP_CTRL),a
	jr kil_done
kil_off:
	ld a,VR0_G6
	out (VDP_CTRL),a
	ld a,$80
	out (VDP_CTRL),a
kil_done:
	ld a,(vdp_r15)
	out (VDP_CTRL),a
	ld a,$8F
	out (VDP_CTRL),a
	pop bc
	pop hl
	pop af
	ei
	reti

ki_frame:
	xor a
	out (VDP_CTRL),a
	ld a,$8F
	out (VDP_CTRL),a
	in a,(VDP_CTRL)             ; S#0: bit 7 = vblank (cleared by the read)
	rlca
	jr c,ki_vbl
	ld a,(vdp_r15)
	out (VDP_CTRL),a
	ld a,$8F
	out (VDP_CTRL),a
	pop af
	ei
	reti

ki_vbl:
	push bc
	push de
	push hl
	push ix
	push iy
	ex af,af'
	push af
	ex af,af'
	exx
	push bc
	push de
	push hl
	exx
	ld a,(cur_p1)
	push af
	ld a,(cur_p2)
	push af
	ld a,(cur_p3)
	push af
	ld a,SEG_C2
	ld (cur_p2),a
	out (PORT_P2),a
	ld a,SEG_C3
	ld (cur_p3),a
	out (PORT_P3),a
	call int_vblank             ; page-2 kernel
	pop af
	ld (cur_p3),a
	out (PORT_P3),a
	pop af
	ld (cur_p2),a
	out (PORT_P2),a
	pop af
	ld (cur_p1),a
	out (PORT_P1),a
	exx
	pop hl
	pop de
	pop bc
	exx
	ex af,af'
	pop af
	ex af,af'
	pop iy
	pop ix
	pop hl
	pop de
	pop bc
	pop af
	ei
	reti

; map the VIC bank into page 2 / restore C64 block 2 (A clobbered)
k_map_vic:
	ld a,SEG_VIC
	ld (cur_p2),a
	out (PORT_P2),a
	ret
k_map_c2:
	ld a,SEG_C2
	ld (cur_p2),a
	out (PORT_P2),a
	ret
region_im2_end:

; ============================================================================
; region $0E00-$0FFF: memory access helpers
; ============================================================================
	org $0E00
region_mem_start:

; bit masks 1 << n (kept at the start of the region: no page crossing)
bittab:
	db $01, $02, $04, $08, $10, $20, $40, $80

; read VIC bank: HL = $4000-$7FFF -> L
k_vrd:
	push af
	ld a,SEG_VIC
	ld (cur_p2),a
	out (PORT_P2),a
	set 7,h
	res 6,h
	ld l,(hl)
	ld a,SEG_C2
	ld (cur_p2),a
	out (PORT_P2),a
	pop af
	ret

; write VIC bank: HL = $4000-$7FFF, A = value
k_vwr:
	push af
	ld a,SEG_VIC
	ld (cur_p2),a
	out (PORT_P2),a
	pop af
	push af
	set 7,h
	res 6,h
	cp (hl)
	jr z,vwr_same               ; unchanged: no redraw needed
	ld (hl),a
	ld a,SEG_C2
	ld (cur_p2),a
	out (PORT_P2),a
	; mark dirty: byte (addr & $3FFF) >> 6, bit (addr >> 3) & 7
	ld a,l
	rrca
	rrca
	rrca
	and 7
	add a,bittab & 255
	push hl
	ld l,a
	ld h,bittab/256
	ld a,(hl)
	pop hl
	push af
	ld a,l
	rlca
	rlca
	and 3
	ld l,a
	ld a,h
	and $3F
	add a,a
	add a,a
	or l
	ld l,a
	ld h,VDIRTY/256
	pop af
	or (hl)
	ld (hl),a
	pop af
	ret
vwr_same:
	ld a,SEG_C2
	ld (cur_p2),a
	out (PORT_P2),a
	pop af
	ret

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
	pop af
	jp k_vrd
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
	pop af
	jp k_vwr
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
k_vecrd:
	push af
	ld a,(vec_ffff)
	ld l,a
	pop af
	ret
k_vecwr:
	ld (vec_ffff),a
	ret

; A = 1 if interrupts are enabled, else 0.  LD A,I reports "disabled" when an
; interrupt is accepted during it, so read twice: either read seeing IFF2 set
; means interrupts were on.
k_get_iff:
	ld a,i
	jp pe,kgi_on
	ld a,i
	jp pe,kgi_on
	xor a
	ret
kgi_on:
	ld a,1
	ret

; copy 8 bytes from the VIC bank (HL = C64 address) to DE (page 0/3)
k_vcopy8:
	call k_map_vic
	set 7,h
	res 6,h
	ld bc,8
	ldir
	jp k_map_c2

; read a byte from the VIC bank into A (HL = C64 address); used by the kernel
k_vpeek:
	call k_vrd
	ld a,l
	ret
region_mem_end:
