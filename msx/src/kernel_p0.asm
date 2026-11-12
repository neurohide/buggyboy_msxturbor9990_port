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

k_int:
	push af
	ld a,(kb_n)
	or a
	jp nz,k_int_kb
k_int_n:
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
	call int_dispatch           ; page-2 kernel
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

; Native C64 IRQ handlers, called by int_hline in place of the translated
; ones (C64 page 3 mapped, in_irq set).  Z: handled; NZ: run the C64 handler.
irq_native:
	ld a,($FFFE)
	cp $E3
	ret nz
	ld a,(vec_ffff)
	cp $10
	ret nz
	; $10E3: kerb colour band.  X = $49 indexes the band line table L14A6
	; and the colour table L14B3; the last band (X = 12) does the frame
	; work: left to the translated handler.
	ld a,($0049)
	ld e,a
	ld d,0
	ld hl,$14A6
	add hl,de
	ld a,($004A)
	cp (hl)
	jr nz,irn_done              ; stale IRQ: the C64 handler just returns
	ld a,e
	cp 12
	jr z,irn_c64
	ld a,$3B
	call iowf_D011
	ld a,$10
	call iowf_D016
	ld hl,$14B3
	add hl,de
	ld a,(hl)
	call iowf_D021
	inc e
	ld a,e
	cp 12
	jp c,kb_start               ; bands e..11 by the native chain (returns Z)
	ld ($0049),a
	ld hl,$14A6
	add hl,de
	ld a,(hl)
	call iowf_D012
	ld ($004A),a
	ld a,1
	call iowf_D019
irn_done:
	xor a
	ret
irn_c64:
	or 1
	ret

; show palette bank A (0/1): R#13 PLTO5-4, R#15 backdrop follows (C clobbered)
pal_show:
	add a,a
	add a,a
	ld c,a
	ld a,13
	out (V_SEL),a
	ld a,c
	out (V_REG),a
	ld a,15
	out (V_SEL),a
	ld a,c
	add a,a
	add a,a
	or PAL_BORDER
	out (V_REG),a
	ret

; line IRQ while the kerb band chain runs (kernel_p2 kb_fast)
k_int_kb:
	push bc
	push de
	push hl
	ld a,(cur_p2)
	push af
	ld a,SEG_C2
	out (PORT_P2),a
	call kb_fast                ; B = 0: served
	pop af
	out (PORT_P2),a
	ld a,b
	pop hl
	pop de
	pop bc
	or a
	jp nz,k_int_n
	pop af
	ei
	reti
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
region_mem_end:
