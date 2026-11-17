; Optional native road store target. Records are (exclusive column end, byte)
; runs, one 80-byte record per scanline from y=112 through bitmap padding.
; Only a transient 40-byte line is expanded. The VIC bitmap is not written by
; the specialized drawer. Checkpoint restores it before another game pass or
; the general overlay drawer. Public entries preserve AF/BC/DE/HL.
	org $4000
road_cpu_start:
rd_begin:
	push af
	push bc
	push de
	push hl
	call rd_checkpoint_body
	call k_vic_on
	ld hl,$F180
	ld de,$6000
	ld b,96
rd_seed:
	push bc
	push hl
	push de
	ld de,rd_linebuf
	push hl
	ld hl,rd_linebuf
	ld (hl),0
	push de
	ld de,rd_linebuf+1
	ld bc,39
	ldir
	pop de
	pop hl
	ld b,40
	ld a,h
	cp $FF
	jr c,rd_seed_read
	ld a,l
	cp $40
	jr c,rd_seed_read
	ld b,24                    ; last bitmap cell row is only 24 columns
rd_seed_read:
	ld a,h
	and l
	inc a
	jr nz,rd_seed_mapped
	ld a,SEG_VIC
	out (PORT_P2),a
	ld a,($BFFF)
	push af
	ld a,SEG_C2
	out (PORT_P2),a
	pop af
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
	pop de
	push de
	call rd_encode
	pop de
	ex de,hl
	ld bc,80
	add hl,bc
	ex de,hl
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
	ld a,$FF
	ld (rd_cached),a
	xor a
	ld (rd_changed),a
	inc a
	ld (road_active),a
	jp rd_pop

; Encode exactly 40 columns. Padding columns beyond the bitmap are never
; consumed or materialized; seed them deterministically on the short last row.
rd_encode:
	ld hl,rd_linebuf
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

rd_record:                      ; A = line index -> DE = its RLE record
	ld l,a
	ld h,0
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl                   ; *16
	ld d,h
	ld e,l
	add hl,hl
	add hl,hl
	add hl,de                   ; *80
	ld de,$6000
	add hl,de
	ex de,hl
	ret

rd_flush:
	ld a,(rd_changed)
	or a
	ret z
	ld a,(rd_cached)
	call rd_record
	call rd_encode
	xor a
	ld (rd_changed),a
	ret

rd_put:                         ; IX = mapped VIC address, A = native edge byte
	push af
	push bc
	push de
	push hl
	push ix
	pop hl
	ld (rd_store),a
	ld bc,$0E80
	add hl,bc
	ld d,0
	ld bc,-320
rd_address:
	push hl
	add hl,bc
	jr nc,rd_address_done
	pop bc
	inc d
	ld bc,-320
	jr rd_address
rd_address_done:
	pop hl
	ld a,l
	and 7
	ld e,a
	ld a,d
	add a,a
	add a,a
	add a,a
	add a,e
	ld (rd_target),a
	srl h
	rr l
	srl h
	rr l
	srl h
	rr l
	ld a,l
	ld (rd_column),a
	ld a,(rd_target)
	ld hl,rd_cached
	cp (hl)
	jr z,rd_put_byte
	call rd_flush
	ld a,(rd_target)
	ld (rd_cached),a
	call rd_record
	ld hl,rd_linebuf
	ld c,0
rd_decode:
	ld a,(de)
	ld b,a
	inc de
	ld a,(de)
	ld (rd_value),a
	inc de
rd_decode_run:
	ld (hl),a
	inc hl
	inc c
	ld a,c
	cp b
	ld a,(rd_value)
	jr c,rd_decode_run
	ld a,c
	cp 40
	jr c,rd_decode
rd_put_byte:
	ld a,(rd_column)
	ld hl,rd_linebuf
	add a,l
	ld l,a
	jr nc,rd_put_ptr
	inc h
rd_put_ptr:
	ld a,(rd_store)
	ld (hl),a
	ld a,1
	ld (rd_changed),a
	jp rd_pop

rd_finish:                      ; publish the final scratch line before rendering
	push af
	push bc
	push de
	push hl
	call rd_flush
	jp rd_pop

rd_checkpoint:
	push af
	push bc
	push de
	push hl
	call rd_checkpoint_body
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
	call rd_flush
	ld a,(cur_p3)
	push af
	call k_vic_on
	ld hl,$6000
	ld de,$F180
	ld b,96
rd_materialize:
	push bc
	push de
	push hl
	ld c,0
rd_mat_run:
	ld b,(hl)
	inc hl
	ld a,(hl)
	ld (rd_value),a
	inc hl
rd_mat_byte:
	ld a,d
	cp $FF
	jr c,rd_mat_write
	ld a,e
	and $F8
	cp $F8
	jr nz,rd_mat_write
	ld a,e
	cp $FF
	jr nz,rd_mat_write
	ld a,SEG_VIC
	out (PORT_P2),a
	ld a,(rd_value)
	ld ($BFFF),a
	ld a,SEG_C2
	out (PORT_P2),a
	jr rd_mat_skip
rd_mat_write:
	ld a,(rd_value)
	ld (de),a
rd_mat_skip:
	push hl
	ld hl,8
	add hl,de
	ex de,hl
	pop hl
	inc c
	ld a,d
	or a
	jr z,rd_mat_line_done      ; byte after $FFFF wraps: end of bitmap
	ld a,c
	cp b
	jr c,rd_mat_byte
	ld a,c
	cp 40
	jr c,rd_mat_run
rd_mat_line_done:
	pop hl
	ld bc,80
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

rd_cached: db $FF
rd_changed: db 0
rd_target: db 0
rd_column: db 0
rd_store: db 0
rd_value: db 0
rd_linebuf: ds 40
	defs $5000-$,0
road_cpu_end:
