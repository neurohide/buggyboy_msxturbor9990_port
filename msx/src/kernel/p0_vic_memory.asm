; VIC-bank reads and writes, dirty tracking, and translated fast-store helpers.
; Routines: bittab, k_vrd, k_vwr, k_vic_on, k_vwrm, k_vwrl, k_gwrl, k_gwrm, k_vwrmf, k_vicw, k_c2.

; bit masks 1 << n (kept at the start of the region: no page crossing)
bittab:
	db $01, $02, $04, $08, $10, $20, $40, $80

; read VIC bank: HL = $4000-$7FFF -> L
k_vrd:
	push af
k_vrd1:                         ; entry with AF already pushed
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

; write VIC bank: HL = $4000-$7FFF, A = value.  Preserves AF, BC, DE.
k_vwr:
	push af
k_vwr1:                         ; entry with AF already pushed
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
vwr_mark:
	; mark dirty: byte (addr & $3FFF) >> 6, bit (addr >> 3) & 7.
	; HL << 2: H = dirty byte (bits 7-6 of h fall out), L bits 7-5 = bit index
	push bc
	add hl,hl
	add hl,hl
	ld a,l
	rlca
	rlca
	rlca
	and 7
	ld c,a
	ld b,bittab/256             ; bittab is page aligned
	ld a,(bc)
	ld l,h
	ld h,VDIRTY/256
	or (hl)
	ld (hl),a
	pop bc
	pop af
	ret
vwr_same:
	ld a,SEG_C2
	ld (cur_p2),a
	out (PORT_P2),a
	pop af
	ret

; map the VIC bank into page 3 for the VIC-bank store helpers below
k_vic_on:
	push af
	ld a,SEG_VIC
	ld (cur_p3),a
	out (PORT_P3),a
	pop af
	ret

; VIC-bank stores from translated code (translate.py plan_vic_lazy):
;   k_vwrm/k_gwrm  the VIC bank is in page 3 already
;   k_vwrl/k_gwrl  map the VIC bank into page 3 when it is not; it stays mapped
; (page 3, not 2: the page-2 tables the game reads between its stores stay
; visible; translated code touching C64 $C000-$FFFF calls k_c2 first)
;   *f variants    6502 flags dead after the store: F is clobbered
; HL = C64 address ($4000-$7FFF for k_vwr*), A = value.  Preserve A, BC, DE
; (the non-f ones also F).  Translated code keeps B = 0: used as scratch.
; Interrupts restore page 3 from cur_p3; k_c2 maps C64 block 3 back.
k_vwrm:
	push af
	call k_vwrmf
	pop af
	ret
k_gwrm:
	push af
	call k_gwrmf
	pop af
	ret
k_vwrl:
	push af
	call k_vwrlf
	pop af
	ret
k_gwrl:
	push af
	call k_gwrlf
	pop af
	ret
k_gwrlf:
	bit 6,h
	jr z,gwrlf_o
	bit 7,h
	jr nz,gwrlf_o
k_vwrlf:
	ld b,a
	ld a,(cur_p3)
	cp SEG_VIC
	jr z,vwrlf_m
	ld a,SEG_VIC
	ld (cur_p3),a
	out (PORT_P3),a
vwrlf_m:
	ld a,b
	ld b,0
	jr k_vwrmf
gwrlf_o:                        ; not the VIC bank: generic write with block 2
	call k_c2
	jp k_gwr
gwrmf_o:                        ; not the VIC bank: generic write, VIC bank back after
	call k_c2
	call k_gwr
	jp k_vic_on
k_gwrmf:
	bit 6,h
	jr z,gwrmf_o
	bit 7,h
	jr nz,gwrmf_o
k_vwrmf:
	set 7,h
	set 6,h
	cp (hl)                     ; (reading $FFFF is harmless)
	ret z                       ; unchanged: no redraw needed
vwr_st:                         ; HL = page-3 address, A = new value: store, mark dirty
	ld b,a                      ; (translate.py inlines the part above)
	ld a,h
	and l
	inc a
	jr z,vwrmf_ff               ; Z80 $FFFF is the sub-slot register
	ld a,b
	ld (hl),a
	; mark dirty: byte (addr & $3FFF) >> 6, bit (addr >> 3) & 7
	add hl,hl
	add hl,hl                   ; H = dirty byte, L bits 7-5 = bit index
	ld a,l
	rlca
	rlca
	rlca
	and 7
	ld l,a
	ld a,h
	ld h,bittab/256             ; bittab is page aligned
	ld h,(hl)                   ; mask
	ld l,a
	ld a,h
	ld h,VDIRTY/256
	or (hl)
	ld (hl),a
	ld a,b
	ld b,0
	ret
vwrmf_ff:                       ; C64 $7FFF: through page 2
	ld a,b
	ld b,0
	ld hl,$7FFF
	jp k_vwr

; VIC register store from translated code (HL = $D000-$D03F, A = value):
; plain registers inline, the special ones through k_iowr with block 2.
; Preserves AF, BC, DE; leaves the page-2 mapping as it found it.
k_vicw:
	push af
	ld a,l
	and $3F
	cp $11
	jr c,vicw_p
	cp $13
	jr c,vicw_s                 ; $11/$12: mode, raster line
	cp $19
	jr c,vicw_p
	cp $1B
	jr c,vicw_s                 ; $19/$1A: IRQ
	cp $1E
	jr c,vicw_p
	cp $24
	jr c,vicw_s                 ; $1E/$1F collisions, $20-$23 live colours
	cp $2F
	jr nc,vicw_x
vicw_p:
	ld l,a
	ld h,VIC_REGS/256           ; VIC_REGS is page aligned
	pop af
	push af
	cp (hl)
	jr z,vicw_x
	ld (hl),a
	ld a,1
	ld (vic_changed),a
vicw_x:
	pop af
	ret
vicw_s:
	ld a,(cur_p3)
	cp SEG_VIC
	jr z,vicw_v
	pop af
	jp k_iowr
vicw_v:
	pop af
	call k_c2
	call k_iowr
	jp k_vic_on

k_c2:                           ; C64 block 3 back in page 3
	push af
	ld a,(cur_p3)
	cp SEG_C3
	jr z,kc2_ok
	ld a,SEG_C3
	ld (cur_p3),a
	out (PORT_P3),a
kc2_ok:
	pop af
	ret

