; Native edges write a line-major byte plane instead of the canonical VIC
; bitmap. Encode each line once at publication, never once per changed byte.
; Public entries preserve AF/BC/DE/HL; rd_read returns its byte in L.
	org $4000
road_cpu_start:
rd_begin:
	push af
	push bc
	push de
	push hl
	ld a,1
	ld (road_busy),a
	call rd_checkpoint_body
	call k_vic_on
	ld hl,$F180
	ld de,rd_plane
	ld b,96
rd_seed:
	push bc
	push hl
	call rd_columns
rd_seed_read:
	ld a,h
	and l
	inc a
	jr nz,rd_seed_mapped
	call k_get_iff
	push af
	di
	ld a,SEG_VIC
	out (PORT_P2),a
	ld a,($BFFF)
	ld (rd_value),a
	ld a,SEG_C2
	out (PORT_P2),a
	pop af
	or a
	jr z,rd_seed_di
	ei
rd_seed_di:
	ld a,(rd_value)
	jr rd_seed_got
rd_seed_mapped:
	ld a,(hl)
rd_seed_got:
	ld (de),a
	inc de
	ld a,l
	add a,8
	ld l,a
	jr nc,rd_seed_next
	inc h
rd_seed_next:
	djnz rd_seed_read
	ld a,c
	or a
	jr z,rd_seed_end
	xor a
	ld b,c
rd_seed_pad:
	ld (de),a
	inc de
	djnz rd_seed_pad
rd_seed_end:
	pop hl
	inc hl
	ld a,l
	and 7
	jr nz,rd_seed_base
	ld bc,312
	add hl,bc
rd_seed_base:
	pop bc
	djnz rd_seed
	ld a,1
	ld (road_active),a
	jp rd_pop

; HL = canonical line base. B = columns, C = plane-only padding columns.
rd_columns:
	ld bc,40*256
	ld a,h
	cp $FF
	ret c
	ld a,l
	cp $40
	ret c
	ld bc,24*256+16
	ret

rd_encode_all:
	ld hl,rd_plane
	ld de,$6000
	ld b,96
rd_encode_line:
	push bc
	push de
	call rd_encode
	pop de
	push hl
	ld hl,80
	add hl,de
	ex de,hl
	pop hl
	pop bc
	djnz rd_encode_line
	ret

; Encode exactly 40 columns. Padding columns beyond the bitmap are never
; consumed or materialized; seed them deterministically on the short last row.
rd_encode:
	ld c,0
rd_enc_run:
	ld a,(hl)
	ld (rd_value),a
rd_enc_same:
	inc hl
	inc c
	ld a,c
	cp 40
	jr z,rd_enc_out
	ld a,(rd_value)
	cp (hl)
	jr z,rd_enc_same
rd_enc_out:
	ld a,c
	ld (de),a
	inc de
	ld a,(rd_value)
	ld (de),a
	inc de
	ld a,c
	cp 40
	jr nz,rd_enc_run
	ret

rd_put:                         ; IX = mapped VIC address, A = native edge byte
	push af
	push bc
	push de
	push hl
	ld (rd_store),a
	ld a,1
	ld (road_busy),a
	push ix
	pop hl
	ld a,h
	or $C0
	ld h,a
	call rd_locate
	ld a,(rd_store)
	ld (hl),a
	jp rd_pop

; The existing $35F9 edge cleanup reads and writes road bytes after the
; specialized drawer. Keep those accesses in the same logical span image.
; Outside that image (or with spans inactive), retain the ordinary helpers.
rd_read:
	push ix
	pop hl
	push af
	call rd_is_span
	jr nz,rd_read_span
	pop af
	jp k_grd
rd_read_span:
	pop af
	push af
	push bc
	push de
	ld a,1
	ld (road_busy),a
	ld a,h
	or $C0
	ld h,a
	call rd_locate
	ld l,(hl)
rd_read_done:
	pop de
	pop bc
	pop af
	ret
rd_write:
	push ix
	pop hl
	push af
	call rd_is_span
	jr nz,rd_write_span
	pop af
	jp k_gwrlf
rd_write_span:
	pop af
rd_write_put:
	jp rd_put
rd_is_span:
	ld a,(road_active)
	or a
	ret z
	ld a,h
	cp $80
	jr nc,rd_not_span
	cp $71
	jr c,rd_not_span
	jr nz,rd_in_span
	ld a,l
	cp $80
	jr c,rd_not_span
rd_in_span:
	ld a,1
	or a
	ret
rd_not_span:
	xor a
	ret

; offset=q*64+r -> (q/5)*320+(q%5)*8+(r&7)*40+(r>>3).
; Two small word tables replace division and repeated line decoding.
rd_locate:
	ld bc,$0E80
	add hl,bc
	ld a,l
	and 63
	add a,a
	ld e,a
	ld d,0
	push hl
	ld hl,rd_tails
	add hl,de
	ld e,(hl)
	inc hl
	ld d,(hl)
	pop hl
	push de
	ld a,l
	rlca
	rlca
	and 3
	ld e,a
	ld a,h
	add a,a
	add a,a
	or e
	add a,a
	ld e,a
	ld d,0
	ld hl,rd_chunks
	add hl,de
	ld e,(hl)
	inc hl
	ld d,(hl)
	pop hl
	add hl,de
	ld de,rd_plane
	add hl,de
	ret

rd_finish:                      ; publish complete span records before rendering
	push af
	push bc
	push de
	push hl
	call rd_encode_all
	xor a
	ld (road_busy),a
	jp rd_pop

rd_checkpoint:
	push af
	push bc
	push de
	push hl
	ld a,(road_busy)
	push af
	ld a,1
	ld (road_busy),a
	call rd_checkpoint_body
	pop af
	ld (road_busy),a
rd_pop:
	pop hl
	pop de
	pop bc
	pop af
	ret

rd_checkpoint_body:
	ld a,(road_active)
	or a
	ret z
	ld a,(cur_p3)
	push af
	call k_vic_on
	ld hl,rd_plane
	ld de,$F180
	ld b,96
rd_materialize:
	push bc
	push de
	push hl
	ex de,hl
	call rd_columns
	ex de,hl
	pop hl
rd_mat_byte:
	ld a,d
	and e
	inc a
	jr nz,rd_mat_write
	call k_get_iff
	push af
	di
	ld a,SEG_VIC
	out (PORT_P2),a
	ld a,(hl)
	ld ($BFFF),a
	ld a,SEG_C2
	out (PORT_P2),a
	pop af
	or a
	jr z,rd_mat_skip
	ei
	jr rd_mat_skip
rd_mat_write:
	ld a,(hl)
	ld (de),a
rd_mat_skip:
	inc hl
	ld a,e
	add a,8
	ld e,a
	jr nc,rd_mat_next
	inc d
rd_mat_next:
	djnz rd_mat_byte
	ld b,0
	add hl,bc
	pop de
	inc de
	ld a,e
	and 7
	jr nz,rd_mat_base
	push hl
	ld hl,312
	add hl,de
	ex de,hl
	pop hl
rd_mat_base:
	pop bc
	djnz rd_materialize
	pop af
	ld (cur_p3),a
	out (PORT_P3),a
	xor a
	ld (road_active),a
	inc a
	ld (road_repair),a
	ld hl,VDIRTY+$C6
	ld b,58
rd_mat_dirty:
	ld (hl),$FF
	inc l
	djnz rd_mat_dirty
	ret

rd_store: db 0
rd_value: db 0
rd_chunks:
	dw $0000,$0008,$0010,$0018,$0020,$0140,$0148,$0150
	dw $0158,$0160,$0280,$0288,$0290,$0298,$02A0,$03C0
	dw $03C8,$03D0,$03D8,$03E0,$0500,$0508,$0510,$0518
	dw $0520,$0640,$0648,$0650,$0658,$0660,$0780,$0788
	dw $0790,$0798,$07A0,$08C0,$08C8,$08D0,$08D8,$08E0
	dw $0A00,$0A08,$0A10,$0A18,$0A20,$0B40,$0B48,$0B50
	dw $0B58,$0B60,$0C80,$0C88,$0C90,$0C98,$0CA0,$0DC0
	dw $0DC8,$0DD0
rd_tails:
	dw $0000,$0028,$0050,$0078,$00A0,$00C8,$00F0,$0118
	dw $0001,$0029,$0051,$0079,$00A1,$00C9,$00F1,$0119
	dw $0002,$002A,$0052,$007A,$00A2,$00CA,$00F2,$011A
	dw $0003,$002B,$0053,$007B,$00A3,$00CB,$00F3,$011B
	dw $0004,$002C,$0054,$007C,$00A4,$00CC,$00F4,$011C
	dw $0005,$002D,$0055,$007D,$00A5,$00CD,$00F5,$011D
	dw $0006,$002E,$0056,$007E,$00A6,$00CE,$00F6,$011E
	dw $0007,$002F,$0057,$007F,$00A7,$00CF,$00F7,$011F
; 3840 bytes across CPU padding and the consumer's initial padding.
rd_plane: equ $4800
	defs $4700-$,0
	org $C700
; P3 alias of the producer bank: called with the native address in HL.
; Only shadow BC/DE/HL and AF are scratch; no per-store farcall needed.
rd_hot_put:
	ld (rd_hot_value),a
	ld a,h
	or $C0
	ld h,a
	call rd_hot_locate
	ld a,(rd_hot_value)
	ld (hl),a
	ret
rd_hot_locate:
	ld bc,$0E80
	add hl,bc
	ld a,l
	and 63
	add a,a
	ld e,a
	ld d,0
	push hl
	ld hl,rd_tails+$8000
	add hl,de
	ld e,(hl)
	inc hl
	ld d,(hl)
	pop hl
	push de
	ld a,l
	rlca
	rlca
	and 3
	ld e,a
	ld a,h
	add a,a
	add a,a
	or e
	add a,a
	ld e,a
	ld d,0
	ld hl,rd_chunks+$8000
	add hl,de
	ld e,(hl)
	inc hl
	ld d,(hl)
	pop hl
	add hl,de
	ld de,rd_plane+$8000
	add hl,de
	ret

rd_hot_value: db 0
	defs $C800-$,0
	org $4800
	defs $5000-$,0
road_cpu_end:
