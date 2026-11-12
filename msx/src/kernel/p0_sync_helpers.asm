; Interrupt-state query, VIC-bank copying, raster waits and polling, and color RAM writes.
; Routines: k_get_iff, k_vcopy8, k_rwait, mt_poll, k_colwr.

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

; CMP $D012 / BNE self: wait until the raster low byte is A, or has passed A
; since the previous poll (the renderer can hold the CPU for tens of lines).
; Returns Z set, C clear (6502: equal, carry set) and A unchanged.
k_rwait:
	push hl
	push de
	ld e,a
	call mt_poll
	call get_raster
	ld d,l                      ; previous low byte
krw_l:
	call get_raster
	ld a,l
	cp e
	jr z,krw_hit
	sub d                       ; advance since the previous poll
	cp 128
	jr nc,krw_next              ; low byte wrapped back (line 311 -> 0)
	ld h,a
	ld a,e
	sub d                       ; distance from the previous poll to the target
	dec a
	cp h
	jr c,krw_hit                ; target in (previous, now]
krw_next:
	ld d,l
	jr krw_l
krw_hit:
	ld a,e
	pop de
	pop hl
	cp a
	ret

; the main code reads the raster (a frame sync point): its new state is
; worth rendering.  Called by iord_d011/iord_d012.  Not while the race loop
; runs (mt_head): it polls several times per pass, renders follow MAIN_LOOP.
mt_poll:
	ld a,(mt_head)
	or a
	ret nz
	ld a,(in_irq)
	or a
	ret nz
	ld a,(rendering)
	or a
	ret nz
	inc a
	ld (mt_sync),a
	ret

; colour RAM store (the translator knows HL is in $D800-$DBFF): k_iowr minus its decode
k_colwr:
	push af
	ld a,h
	jp iowr_col
