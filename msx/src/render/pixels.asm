; Cell pixel expansion and V9990 pixel streaming.
; ============================================================================
; nibble table for cell_cols (mode 1 = multicolour c0..c3, 0 = hires c0/c1)
; NT[n] = 3 bytes = 6 pixels for the 4 source bits of nibble n
; ============================================================================
nt_build:
	ld hl,cell_cols
	ld de,nt_key
	ld b,5
ntb_cmp:
	ld a,(de)
	cp (hl)
	jr nz,ntb_new
	inc hl
	inc de
	djnz ntb_cmp
	ret
ntb_new:
	ld hl,cell_cols
	ld de,nt_key
	ld bc,5
	ldir
	ld a,(nt_key)
	or a
	jr z,ntb_hires
	; multicolour: nibble = fat pixels a (hi 2 bits), b (lo 2 bits)
	; bytes: aa, ab, bb.  ntq = 4 x (colour, colour * $11)
	ld hl,nt_key+1
	ld de,ntq
	ld b,4
ntb_q:
	ld a,(hl)
	inc hl
	ld (de),a
	inc de
	ld c,a
	add a,a
	add a,a
	add a,a
	add a,a
	or c
	ld (de),a
	inc de
	djnz ntb_q
	ld hl,NT
	ld a,(nt_key+1)
	call ntb_row
	ld a,(nt_key+2)
	call ntb_row
	ld a,(nt_key+3)
	call ntb_row
	ld a,(nt_key+4)
ntb_row:                        ; A = colour a -> the 4 entries a,0..a,3 at HL (NT page aligned)
	ld b,a
	add a,a
	add a,a
	add a,a
	add a,a
	ld c,a                      ; a << 4
	or b
	ld b,a                      ; a * $11
	ld de,ntq
	ld (hl),b
	inc l
	ld a,(de)
	inc de
	or c
	ld (hl),a
	inc l
	ld a,(de)
	inc de
	ld (hl),a
	inc l
	inc l
	ld (hl),b
	inc l
	ld a,(de)
	inc de
	or c
	ld (hl),a
	inc l
	ld a,(de)
	inc de
	ld (hl),a
	inc l
	inc l
	ld (hl),b
	inc l
	ld a,(de)
	inc de
	or c
	ld (hl),a
	inc l
	ld a,(de)
	inc de
	ld (hl),a
	inc l
	inc l
	ld (hl),b
	inc l
	ld a,(de)
	inc de
	or c
	ld (hl),a
	inc l
	ld a,(de)
	inc de
	ld (hl),a
	inc l
	inc l
	ret
ntb_hires:
	; bits h0..h3 (msb first) -> pixels h0, h0|h1, h1, h2, h2|h3, h3
	ld hl,NT
	ld c,0
ntb_h:
	bit 3,c
	ld a,(nt_key+1)
	jr z,ntb_h0
	ld a,(nt_key+2)
ntb_h0:
	ld d,a                      ; h0
	ld a,(nt_key+1)
	bit 3,c
	jr nz,ntb_h01_one
	bit 2,c
	jr z,ntb_h01
ntb_h01_one:
	ld a,(nt_key+2)
ntb_h01:
	ld e,a                      ; h0|h1
	ld a,d
	add a,a
	add a,a
	add a,a
	add a,a
	or e
	ld (hl),a
	inc l
	bit 2,c
	ld a,(nt_key+1)
	jr z,ntb_h1
	ld a,(nt_key+2)
ntb_h1:
	add a,a
	add a,a
	add a,a
	add a,a
	ld b,a                      ; h1 in high nibble
	bit 1,c
	ld a,(nt_key+1)
	jr z,ntb_h2
	ld a,(nt_key+2)
ntb_h2:
	or b
	ld (hl),a                   ; h1, h2
	inc l
	ld a,(nt_key+1)
	bit 1,c
	jr nz,ntb_h23_one
	bit 0,c
	jr z,ntb_h23
ntb_h23_one:
	ld a,(nt_key+2)
ntb_h23:
	add a,a
	add a,a
	add a,a
	add a,a
	ld b,a
	bit 0,c
	ld a,(nt_key+1)
	jr z,ntb_h3
	ld a,(nt_key+2)
ntb_h3:
	or b
	ld (hl),a                   ; h2|h3, h3
	inc l
	inc l
	inc c
	ld a,c
	cp 16
	jr nz,ntb_h
	ret

; Fast single-colour check for the common $00/$FF cells, without NT.
; HL = 8 source bytes: Z and A = repeated colour byte on a match; HL kept.
cell_plain_uniform:
	push hl
	ld a,(hl)
	or a
	jr z,cpu_zero
	cp $FF
	jr nz,cpu_miss
	ld a,(cell_cols)
	or a
	ld de,cell_cols+2          ; hires $FF = colour 1
	jr z,cpu_check
	ld de,cell_cols+4          ; multicolour $FF = colour 3
	jr cpu_check
cpu_zero:
	ld de,cell_cols+1          ; $00 = colour 0 in both modes
cpu_check:
	ld a,(hl)
	ld b,7
cpu_next:
	inc hl
	cp (hl)
	jr nz,cpu_miss
	djnz cpu_next
	pop hl
	ld a,(de)
	ld b,a
	add a,a
	add a,a
	add a,a
	add a,a
	or b
	cp a                        ; Z, with A = repeated colour byte
	ret
cpu_miss:
	pop hl
	or 1                        ; NZ
	ret

; HL = 8 source bytes: Z and A = colour byte if the whole cell is one colour
; (8 equal bytes whose two nibbles expand to 6 equal bytes).  Preserves HL.
cell_uniform:
	push hl
	ld a,(hl)
	ld b,7
cu_l:
	inc hl
	cp (hl)
	jr nz,cu_no
	djnz cu_l
	pop hl
	ld c,a
	rrca
	rrca
	rrca
	rrca
	and $0F
	call cu_ent
	ld a,(de)
	ld b,a                      ; B = first pixel byte
	call cu_chk3
	ret nz
	ld a,c
	and $0F
	call cu_ent
	call cu_chk3
	ld a,b
	ret
cu_no:
	pop hl
	ret
cu_ent:                         ; A = nibble -> DE = its NT entry
	add a,a
	add a,a
	ld e,a
	ld d,NT/256
	ret
cu_chk3:                        ; Z if the 3 bytes at DE all equal B
	ld a,(de)
	cp b
	ret nz
	inc e
	ld a,(de)
	cp b
	ret nz
	inc e
	ld a,(de)
	cp b
	ret

; HL = 8 source bytes -> 8 lines of 6 bytes to the LMMC data port (NT page aligned)
cell_out:
	ex de,hl                    ; DE = source
	ld h,NT/256
	ld bc,48*256+V_CMD          ; B counts the 48 bytes sent by OUTI
co_line:
	ld a,(de)
	and $F0
	rrca
	rrca
	ld l,a
	outi
	outi
	outi
	ld a,(de)
	inc de
	and $0F
	add a,a
	add a,a
	ld l,a
	outi
	outi
	outi
	jr nz,co_line
	ret

