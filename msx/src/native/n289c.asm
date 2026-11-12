; native $1289C-$13507: the road drawer's specialized copy (special overlays off,
; see SPEC_ASSUME in translate.py).  Same stores, tables and zero-page results as
; the 6502; within one edge the stores hit distinct bytes, so they are issued in
; ascending order along one pointer walk.  BC = 8 (one cell right), DE = line
; (D = 0) for the per-line tables.  L3002 stays 0 (never incremented here) and
; L3503 is only ever set to $AA.  Exit as the 6502: X = $48, block 3 mapped.
	call k_vic_on
	; globals the line conditions read: NR_gc counts calls they stayed equal (max 2)
	ld hl,NR_gv
	ld de,$3F75
	call NR_g
	ld de,$96E2
	call NR_g
	ld de,$96E6
	call NR_g
	ld de,$02D1
	call NR_g
	ld de,$02C9
	call NR_g
	ld de,$02D2
	call NR_g
	ld hl,NR_gc
	ld a,(NR_gd)
	or a
	jr z,NR_g1
	ld (hl),0
	jr NR_g2
NR_g1:
	ld a,(hl)
	cp 2
	jr nc,NR_g2
	inc (hl)
NR_g2:
	xor a
	ld (NR_gd),a
	ld ($0050),a
	ld ($3002),a
	; per line: NR_cc = calls its 4 edge inputs stayed equal (max 2).
	; Compare L3E00-L3F1F with the copy; a changed byte updates the copy
	; and flags its line in NR_df
	ld hl,$3E00
	ld de,NR_cv
	ld c,4
NR_p0:
	ld b,$48
NR_p1:
	ld a,(de)
	cp (hl)
	jr nz,NR_pd
NR_p2:
	inc hl
	inc de
	djnz NR_p1
	dec c
	jr nz,NR_p0
	ld hl,NR_cc
	ld de,NR_df
	ld b,$48
NR_p3:
	ld a,(de)
	or a
	jr nz,NR_p4
	ld a,(hl)
	cp 2
	jr nc,NR_p5
	inc (hl)
	jr NR_p5
NR_p4:
	xor a
	ld (de),a
	ld (hl),a
NR_p5:
	inc hl
	inc de
	djnz NR_p3
	ld bc,8
	jr NR_line
NR_pd:
	ld a,(hl)
	ld (de),a
	push hl
	ld a,$48
	sub b
	ld l,a
	ld h,NR_df/256
	ld a,l
	add a,NR_df&255
	ld l,a
	jr nc,NR_pd1
	inc h
NR_pd1:
	ld (hl),1
	pop hl
	jr NR_p2
NR_line:
	ld a,($0050)
	ld e,a
	ld d,0
	; skip a line whose inputs and globals equal those of the last 2 calls:
	; it would redo the last call's stores exactly.  Lines x-8 / x+8 can reach
	; its bytes (edges past the row end), so they and x must be stable and
	; "contained" (last stores inside their own row).  The last line always
	; runs: it leaves the zero-page results.
	ld a,(NR_gc)
	cp 2
	jr c,NR_full
	ld a,e
	cp $47
	jr z,NR_full
	ld hl,NR_cc
	add hl,de
	ld a,(hl)
	or a
	sbc hl,bc
	and (hl)
	add hl,bc
	add hl,bc
	and (hl)
	push de
	ld de,NR_ct-NR_cc-16
	add hl,de
	pop de
	and (hl)
	add hl,bc
	and (hl)
	add hl,bc
	and (hl)
	and 2
	jp nz,NR_nx
NR_full:
	xor a
	ld (NR_lnc),a
	; per line: row base, pattern base, default pointer
	ld hl,$95C0
	add hl,de
	ld a,(hl)
	ld hl,$9578
	add hl,de
	ld h,(hl)
	ld l,a
	ld (NR_rb1+1),hl
	ld (NR_rb2+1),hl
	ld hl,$9608
	add hl,de
	ld a,(hl)
	ld (NR_i1+1),a
	ld (NR_i2+1),a
	ld hl,$9698
	add hl,de
	ld a,(hl)
	ld hl,$9650
	add hl,de
	ld h,(hl)
	ld l,a
	ld (NR_dv),hl
	; range mode: line in [L02D1, L02D2): NR_ld = L02D2 != 0 (edges 3/4
	; parked), NR_lr = also L02C9 != 0 (edges 1/2 alternate patterns)
	xor a
	ld (NR_ld),a
	ld (NR_lr),a
	ld a,($02D2)
	or a
	jr z,NR_r0
	ld a,e
	ld hl,$02D1
	cp (hl)
	jr c,NR_r0
	inc hl
	cp (hl)
	jr nc,NR_r0
	ld a,1
	ld (NR_ld),a
	ld (NR_lnc),a               ; parked edges 3/4: next prologue stores at col 39-40
	ld a,($02C9)
	ld (NR_lr),a
NR_r0:
	; last frame's edge 3/4 pointers of this line: [00],[08] = $FF
	ld a,($02C9)
	or a
	jp nz,NR_e1
	ld a,e
	ld hl,$3F75
	cp (hl)
	jr c,NR_pa
	ld a,($96E2)
	or a
	jr nz,NR_pa
	ld a,($02D2)
	or a
	jr z,NR_e1
	ld a,e
	ld hl,$02D1
	cp (hl)
	jr c,NR_pa
	inc hl
	cp (hl)
	jr nc,NR_e1
NR_pa:
	ld hl,$0640
	call NR_old
	call NR_ff2
	ld a,e
	ld hl,$02D1
	cp (hl)
	jr c,NR_pb
	inc hl
	cp (hl)
	jr c,NR_pb
	ld hl,$96E2
	cp (hl)
	jr nc,NR_e1
NR_pb:
	ld hl,$06D0
	call NR_old
	call NR_ff2
	; ---- edge 1: L3E00, pointer L0520/L04D8
NR_e1:
	ld hl,$3E00
	add hl,de
	ld a,(hl)
	ld ($0055),a
	or a
	jp m,NR_e1n
	cp $40
	jr nc,NR_e1o
	call NR_pos
	jr NR_e1w
NR_e1n:
	cp $B0
	jp c,NR_e1d
	call NR_neg
NR_e1w:
	ld a,(NR_lr)
	or a
	jp nz,NR_e1r
	ld hl,$9420
	call NR_pat
	call NR_p
	ld a,$AA
	ld ($3503),a
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
	add hl,bc
	ld a,e
	cp (hl)
	call nz,NR_st
	add hl,bc
	ld a,d
	cp (hl)
	call nz,NR_st
	add hl,bc
	ld a,$FF
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
	jr NR_e1s
NR_e1o:
	call NR_def
	ld a,l
	sub $18
	ld l,a
	jr nc,NR_e1a
	dec h
NR_e1a:
	ld ($00FB),hl
	call NR_p
	ld a,($3503)
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
	add hl,bc
	add hl,bc
	add hl,bc
	ld a,$FF
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
NR_e1s:
	ld a,($0050)
	ld e,a
	ld d,0
	ld a,$A0
	ld (NR_svk),a
	ld hl,$0520
	call NR_sv
	jr NR_e2
NR_e1d:
	ld hl,$0520
	call NR_svd
	; ---- edge 2: L3E48, pointer L05B0/L0568
NR_e2:
	ld hl,$3E48
	add hl,de
	ld a,(hl)
	ld ($0055),a
	or a
	jp m,NR_e2n
	cp $4C
	jp nc,NR_e2d
	call NR_pos
	ld a,(NR_lr)
	or a
	jp nz,NR_e2r
	call NR_e2p
	add hl,bc
	ld a,($0050)
	cp $10
	jr c,NR_e2a
	ld a,$FF
	cp (hl)
	call nz,NR_st
NR_e2a:
	add hl,bc
	ld a,$FF
	cp (hl)
	call nz,NR_st
	jr NR_e2j
NR_e2n:
	cp $9C
	jr c,NR_e2o
	call NR_neg
	ld a,(NR_lr)
	or a
	jp nz,NR_e2r
	call NR_e2p
	add hl,bc
	ld a,($0055)
	cp $A8
	jr c,NR_e2b
	ld a,($0050)
	cp $10
	jr c,NR_e2b
	ld a,$FF
	cp (hl)
	call nz,NR_st
NR_e2b:
	add hl,bc
	ld a,($0055)
	cp $A4
	jr c,NR_e2j
	ld a,$FF
	cp (hl)
	call nz,NR_st
NR_e2j:
	add hl,bc
	ld a,$FF
	cp (hl)
	call nz,NR_st
	add hl,bc
	ld a,e
	cp (hl)
	call nz,NR_st
	add hl,bc
	ld a,d
	cp (hl)
	call nz,NR_st
	jr NR_e2t
NR_e2o:
	ld hl,$05B0
	call NR_old
	call NR_p
	add hl,bc
	add hl,bc
	add hl,bc
	add hl,bc
	ld a,$AA
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
	call NR_def
	ld a,l
	sub $20
	ld l,a
	jr nc,NR_e2c
	dec h
NR_e2c:
	ld ($00FB),hl
	call NR_p
	add hl,bc
	add hl,bc
	add hl,bc
	add hl,bc
	add hl,bc
NR_e2t:
	ld a,($0050)
	ld e,a
	add hl,bc
	cp 4
	jr c,NR_e2s
	ld a,($3503)
	cp (hl)
	call nz,NR_st
	add hl,bc
	ld a,e
	cp $10
	jr c,NR_e2s
	ld a,($3503)
	cp (hl)
	call nz,NR_st
	add hl,bc
	ld a,e
	cp $20
	jr c,NR_e2s
	ld a,($3503)
	cp (hl)
	call nz,NR_st
NR_e2s0:
	ld a,($0050)
	ld e,a
NR_e2s:
	ld d,0
	ld a,$A8
	ld (NR_svk),a
	ld hl,$05B0
	call NR_sv
	jr NR_e3
NR_e2d:
	ld hl,$05B0
	call NR_svd
	; ---- edge 3: L3E90, pointer L0640/L05F8
NR_e3:
	ld a,(NR_ld)
	or a
	jp nz,NR_e34p
	ld hl,$3E90
	add hl,de
	ld a,(hl)
	ld ($0055),a
	ld a,e
	ld hl,$3F75
	cp (hl)
	jp c,NR_e3o
	ld a,($0055)
	or a
	jp m,NR_e3n
	cp $4C
	jp nc,NR_e3o
	call NR_pos
	jr NR_e3w
NR_e3n:
	cp $B0
	jp c,NR_e3d
	call NR_neg
NR_e3w:
	ld hl,$93D0
	call NR_pat
	call NR_q
	ld a,($0050)
	cp $12
	jr c,NR_e3b
	ld a,$FF
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
	add hl,bc
	jr NR_e3c
NR_e3b:
	add hl,bc
	add hl,bc
	add hl,bc
NR_e3c:
	ld a,e
	cp (hl)
	call nz,NR_st
	add hl,bc
	ld a,d
	cp (hl)
	call nz,NR_st
	ld a,($0055)
	or a
	jp m,NR_e3f
	cp $44
	jr nc,NR_e3s
NR_e3f:
	add hl,bc
	ld a,$FF
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
NR_e3s:
	ld a,($0050)
	ld e,a
	ld d,0
	ld a,$88
	ld (NR_svk),a
	ld hl,$0640
	call NR_sv
	jr NR_e4
NR_e3o:
	ld hl,$0640
	call NR_svdm
	call NR_def
	ld a,l
	sub $18                     ; no borrow into the high byte (as the 6502)
	ld l,a
	ld ($00FB),hl
	ld a,($0055)
	cp $60
	jr nc,NR_e4
	ld a,h
	or $C0
	ld h,a
	ld a,$FF
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
	jr NR_e4
NR_e3d:
	ld hl,$0640
	call NR_svdm
	; ---- edge 4: L3ED8, pointer L06D0/L0688
NR_e4:
	ld a,e
	ld hl,$96E6
	cp (hl)
	jr c,NR_e4l
	ld hl,$96E2
	cp (hl)
	jp c,NR_e4d
NR_e4l:
	ld hl,$3ED8
	add hl,de
	ld a,(hl)
	ld ($0055),a
	or a
	jp m,NR_e4n
	cp $4C
	jp nc,NR_e4d
	call NR_pos
	jr NR_e4w
NR_e4n:
	cp $B0
	jr nc,NR_e4m
	ld a,e
	add a,a
	ld l,a
	ld h,0
	push de
	ld de,$94E8
	add hl,de
	pop de
	ld a,(hl)
	inc hl
	ld h,(hl)
	ld l,a
	ld ($004E),hl
	push hl
	ld hl,$06D0
	call NR_sv4
	pop hl
	ld a,($0055)
	cp $A0
	jp c,NR_next
	ld a,h
	or $C0
	ld h,a
	ld a,$FF
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
	jr NR_next
NR_e4m:
	call NR_neg
NR_e4w:
	ld hl,$93D0
	call NR_pat
	call NR_q
	ld a,($0055)
	or a
	jp p,NR_e4f
	cp $B8
	jr c,NR_e4b
NR_e4f:
	ld a,$FF
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
	add hl,bc
	jr NR_e4c
NR_e4b:
	add hl,bc
	add hl,bc
	add hl,bc
NR_e4c:
	ld a,e
	cp (hl)
	call nz,NR_st
	add hl,bc
	ld a,d
	cp (hl)
	call nz,NR_st
	ld a,($0050)
	cp $12
	jr c,NR_e4s
	add hl,bc
	ld a,$FF
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
NR_e4s:
	ld a,($0050)
	ld e,a
	ld d,0
	ld a,$88
	ld (NR_svk),a
	ld hl,$06D0
	call NR_sv
	jr NR_next
NR_e4d:
	ld hl,$06D0
	call NR_svdm
NR_next:                        ; line ran: remember whether its stores stayed in its row
	ld a,(NR_lnc)
	or a
	ld a,2
	jr z,NR_nx1
	xor a
NR_nx1:
	ld hl,NR_ct
	add hl,de
	ld (hl),a
NR_nx:
	ld hl,$0050
	inc (hl)
	ld a,(hl)
	cp $48
	jp nz,NR_line
NR_exit:
	call k_c2
	ld e,$48
	ret
NR_e1r:                         ; edge 1, range line (E = index)
	ld a,1
	ld (NR_lnc),a               ; stores reach +$40
	ld a,($004E)
	cp $20
	push af
	ld hl,$9498
	call NR_pat
	call NR_p
	pop af
	ld a,$AA
	jr c,NR_e1r1
	cp (hl)
	call nz,NR_st
NR_e1r1:
	add hl,bc
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
	add hl,bc
	ld a,e
	cp (hl)
	call nz,NR_st
	add hl,bc
	ld a,d
	cp (hl)
	call nz,NR_st
	add hl,bc
	ld a,$55
	cp (hl)
	call nz,NR_st
	ld a,($0055)
	cp $34
	jr c,NR_e1r2                ; v < $34: [30]-[40]
	cp $80
	jp c,NR_e1s                 ; $34 <= v < $80: none
	add hl,bc                   ; v >= $80: [30], [38]
	ld a,$55
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
	jp NR_e1s
NR_e1r2:
	ld a,$55
	add hl,bc
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
	jp NR_e1s
NR_e2r:                         ; edge 2, range line (E = index)
	ld a,1
	ld (NR_lnc),a
	ld hl,$94C0
	call NR_pat
	call NR_p
	ld a,($0055)
	or a
	jp p,NR_e2r1
	cp $AC
	jr nc,NR_e2r1
	add hl,bc                   ; v in $9C..$AB: only [20], [28]
	add hl,bc
	add hl,bc
	add hl,bc
	ld a,e
	cp (hl)
	call nz,NR_st
	add hl,bc
	ld a,d
	cp (hl)
	call nz,NR_st
	jp NR_e2s0
NR_e2r1:
	ld a,$55
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
	add hl,bc
	ld a,e
	cp (hl)
	call nz,NR_st
	add hl,bc
	ld a,d
	cp (hl)
	call nz,NR_st
	ld a,($0050)
	cp 4
	jp c,NR_e2s0
	add hl,bc
	ld a,$AA
	cp (hl)
	call nz,NR_st
	ld a,($0050)
	cp $20
	jp c,NR_e2s0
	add hl,bc
	ld a,$AA
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	call nz,NR_st
	jp NR_e2s0
NR_e34p:                        ; range line, L02D2 set: edges 3/4 parked
	ld hl,$0640
	call NR_svd
	ld hl,$06D0
	call NR_svd
	jp NR_next
NR_st:                          ; changed byte: store, mark dirty (A BC DE HL kept)
	ld (hl),a                   ; road stores never reach $FFFF (bitmap rows)
	push af
	push hl
	; vwr_st's mark: byte (addr & $3FFF) >> 6, bit (addr >> 3) & 7
	add hl,hl
	add hl,hl
	ld a,l
	rlca
	rlca
	rlca
	and 7
	ld l,a
	ld a,h
	ld h,bittab/256
	ld h,(hl)
	ld l,a
	ld a,h
	ld h,VDIRTY/256
	or (hl)
	ld (hl),a
	pop hl
	pop af
	ret
NR_ff2:                         ; HL = pointer: [00], [08] = $FF
	ld a,h
	or $C0
	ld h,a
	ld a,$FF
	cp (hl)
	call nz,NR_st
	add hl,bc
	cp (hl)
	ret z
	jp NR_st
NR_old:                         ; HL = low table, DE = line: HL = $FB = (low-$48)[x] : low[x]
	add hl,de
	ld a,(hl)
	push de
	ld de,-$48
	add hl,de
	pop de
	ld h,(hl)
	ld l,a
	ld ($00FB),hl
	ret
NR_def:                         ; HL = L9650[x] : L9698[x]
	ld hl,(NR_dv)
	ret
NR_sv4:                         ; off4b: HL = low table, [x] = $4E / $4F (col 0-3: contained)
	add hl,de
	ld a,($004E)
	ld (hl),a
	ld a,l
	sub $48
	ld l,a
	ld a,($004F)
	jr nc,NR_sv2
	dec h
	ld (hl),a
	ret
NR_g:                           ; (DE) vs (HL): store, flag a difference in NR_gd
	ld a,(de)
	cp (hl)
	ld (hl),a
	inc hl
	ret z
	ld a,1
	ld (NR_gd),a
	ret
NR_sv:                          ; HL = low table (high = low - $48): [x] = $FB / $FC
	add hl,de
	ld a,($00FB)
	ld (hl),a
	ld a,l
	sub $48
	ld l,a
	ld a,($00FC)
	jr nc,NR_sv1
	dec h
NR_sv1:
	ld (hl),a
	; contained: stores at pointer + lo..lo+$38 stay in the row (columns at
	; row base - $A0 + 8c, c = 0..39): pointer - row base + $A0 + lo in 0..$100
	ld hl,(NR_rb1+1)
	ld a,($00FB)
	sub l
	ld l,a
	ld a,($00FC)
	sbc a,h
	ld h,a                      ; HL = pointer - row base
	ld a,(NR_svk)
	add a,l
	ld l,a
	ld a,h
	adc a,0
	ret z
	dec a
	jr nz,NR_nc
	or l
	ret z
NR_nc:
	ld a,1
	ld (NR_lnc),a
	ret
NR_svdm:                        ; edges 3/4: the next prologue stores at the default (col 39-40)
	ld a,1
	ld (NR_lnc),a
NR_svd:                         ; HL = low table: [x] = L9698[x] / L9650[x]
	add hl,de
	ld a,(NR_dv)
	ld (hl),a
	ld a,l
	sub $48
	ld l,a
	ld a,(NR_dv+1)
	jr nc,NR_sv2
	dec h
NR_sv2:
	ld (hl),a
	ret
NR_pos:                         ; A = v < $80: pointer = row base + L9350[v]; E = index
	ld e,a
	and 3
	add a,a
NR_i1:
	add a,0                     ; + L9608[x]
	ld ($004E),a
	ld hl,$9350
	add hl,de
	ld e,(hl)
NR_rb1:
	ld hl,0                     ; row base of the line
	add hl,de
	jr NR_pe
NR_neg:                         ; A = v >= $80: pointer = row base - L9350[3 - v]
	ld e,a
	and 3
	add a,a
NR_i2:
	add a,0
	ld ($004E),a
	ld a,e
	cpl
	add a,4
	ld e,a
	ld hl,$9350
	add hl,de
	ld e,(hl)
NR_rb2:
	ld hl,0
	or a
	sbc hl,de
NR_pe:
	ld ($00FB),hl
	ld a,($004E)
	ld e,a
	ret
NR_pat:                         ; HL = pattern table, DE = index: E = [i], D = [i+1]
	add hl,de
	ld e,(hl)
	inc hl
	ld d,(hl)
	ret
NR_p:                           ; HL = pointer in the mapped VIC bank
	ld hl,($00FB)
	ld a,h
	or $C0
	ld h,a
	ret
NR_q:                           ; $4E = pointer - $18; HL = that in the VIC bank
	ld hl,($00FB)
	ld a,l
	sub $18
	ld l,a
	jr nc,NR_q1
	dec h
NR_q1:
	ld ($004E),hl
	ld a,h
	or $C0
	ld h,a
	ret
NR_e2p:                         ; edge 2 pattern (L93F8), L3503 = $AA, HL = pointer
	ld hl,$93F8
	call NR_pat
	ld a,$AA
	ld ($3503),a
	jr NR_p
NR_dv:
	dw 0
NR_gv:
	ds 6
NR_gd:
	db 0
NR_gc:                          ; reset by the translated general path (translate.py)
	db 0
NR_lnc:
	db 0
NR_lr:
	db 0
NR_ld:
	db 0
NR_svk:                         ; $A0 + lowest store offset of the edge being saved
	db 0
	db 2,2,2,2,2,2,2,2              ; neighbours past the ends: stable, contained
NR_cc:
	ds 72
	db 2,2,2,2,2,2,2,2
NR_ct:                          ; 2 = line's last stores stayed in its row
	ds 72
	db 2,2,2,2,2,2,2,2
NR_cv:                          ; last edge inputs, laid out as L3E00-L3F1F
	ds 288
NR_df:                          ; line changed this call (pre-pass)
	ds 72
