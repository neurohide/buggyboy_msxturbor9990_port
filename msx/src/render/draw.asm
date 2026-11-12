; Dirty-cell drawing.
; ============================================================================
; draw the dirty runs of the current row
; ============================================================================
renderer_draw_dirty_cells:
	ld a,(row_mode)
	bit 2,a
	jp nz,row_blank
	ld hl,celldirty
rrn_scan:                       ; next dirty cell (sentinel $80 after cell 39)
	ld a,(hl)
	inc l
	or a
	jr z,rrn_scan
	dec l
	ld a,l
	sub celldirty & 255
	cp 40
	ret nc
	ld (run_start),a
	ld b,0
rrn_len:                        ; run of 1s (0 or the sentinel ends it)
	inc b
	inc l
	ld a,(hl)
	dec a
	jr z,rrn_len
	ld a,b
	ld (run_len),a
	push hl
	call draw_run
	pop hl
	jr rrn_scan

row_blank:
	; display disabled: border colour over the row
	ld a,(cur_row)
	call row_y_clean
	ld de,SCREEN_X
	ld bc,480
	ld a,8
	call fill_rect_hl
	ret

; A = row -> HL = y in the clean buffer; the row is marked changed
row_y_clean:
	ld e,a
	ld h,SH_ROWS/256
	ld l,a
	ld (hl),1
	set 7,l                     ; SPAN_LO
	ld (hl),0
	set 5,l                     ; SPAN_HI
	ld (hl),SPAN_FULL
row_y_of:                       ; E = row -> HL = y in the clean buffer, no mark
	ld l,e
	ld h,0
	add hl,hl
	add hl,hl
	add hl,hl
	ld de,CLEAN_Y+SCREEN_Y
	add hl,de
	ret

; mark clean row cur_row changed over [D, E) (4-pixel units)
span_mark:
	ld a,(cur_row)
	ld l,a
	ld h,SH_ROWS/256
	ld a,(hl)
	ld (hl),1
	set 7,l                     ; SPAN_LO
	or a
	jr z,sm_new
	ld a,(hl)
	cp d
	jr c,sm_lo
	ld (hl),d
sm_lo:
	set 5,l                     ; SPAN_HI
	ld a,(hl)
	cp e
	ret nc
	ld (hl),e
	ret
sm_new:
	ld (hl),d
	set 5,l
	ld (hl),e
	ret

; render run_len cells from run_start: one LMMC per cell (12x8 pixels), the
; pixels go straight to the command port (no buffer, no stride)
draw_run:
	; shadow records are 10 bytes each; keep a running pointer across this run
	; instead of multiplying the column by 10 again for every drawn cell.
	ld a,(run_start)
	ld l,a
	ld h,0
	add hl,hl
	ld d,h
	ld e,l
	add hl,hl
	add hl,hl
	add hl,de
	ld de,(row_shad)
	add hl,de
	ld (dr_shad),hl
	ld a,(cur_row)
	ld e,a
	call row_y_of
	ld (cmdblk+6),hl
	ld hl,12
	ld (cmdblk+8),hl
	ld hl,8
	ld (cmdblk+10),hl
	; x = SCREEN_X + 12*start + xoff
	ld a,(run_start)
	ld l,a
	ld h,0
	add hl,hl
	add hl,hl                   ; *4
	ld d,h
	ld e,l
	add hl,hl                   ; *8
	add hl,de                   ; *12
	ld de,SCREEN_X
	add hl,de
	ld a,(row_xoff)
	ld e,a
	ld d,0
	add hl,de
	ld (cmdblk+4),hl
	; changed span: [x/4, x/4 + 3*len + 1)
	ld de,-SCREEN_X
	add hl,de
	srl h
	rr l
	srl l
	ld d,l
	ld a,(run_len)
	ld e,a
	add a,a
	add a,e
	inc a
	add a,d
	ld e,a
	call span_mark
	ld a,1
	ld (dr_full),a
	xor a
	ld (pf_n),a
	ld a,(run_len)
	ld b,a
	ld a,(run_start)
	ld c,a
dr_cell:
	ld hl,(dbg_cnt)
	inc hl
	ld (dbg_cnt),hl
	push bc
	call cell_colours           ; fills cell_cols, returns HL = source bytes
	push hl
	call shadow_store
	pop hl
	push hl
	ld a,(cc_hit)
	or a
	call z,nt_build             ; rows phase: only dr_cell builds NT
	pop hl
	call cell_uniform
	jr nz,dr_pix
	; one colour: merge with the pending fill when it continues it
	ld b,a
	ld a,(pf_n)
	or a
	jr z,dr_pf_new
	ld a,(pf_col)
	cp b
	jr z,dr_pf_ext
	push bc
	call dr_flush
	pop bc
dr_pf_new:
	ld a,b
	ld (pf_col),a
	ld hl,(cmdblk+4)
	ld (pf_dx),hl
	ld a,1
	ld (pf_n),a
	jr dr_adv
dr_pf_ext:
	ld hl,pf_n
	inc (hl)
	jr dr_adv
dr_pix:
	push hl
	call dr_flush
	pop hl
	ld a,(cell_cols)
	or a
	call nz,dr_two              ; multicolour with 2 pixel values: CMMC, CF
	jr c,dr_adv
	ld a,(dr_full)
	or a
	jr z,dr_next
	xor a
	ld (dr_full),a
	push hl
	call lmmc_start             ; full command
	pop hl
	jr dr_out
dr_next:                        ; later cells: resend DX/DY/NX/NY (R#36-R#43; the
	call v_wait                 ; command advances DY) and the opcode
	ld a,i                      ; P/V = IFF2 (read twice, as k_get_iff)
	jp pe,dn_on
	ld a,i
dn_on:
	push af
	di
	push hl
	ld a,36
	out (V_SEL),a
	ld hl,cmdblk+4
	ld bc,4*256+V_REG           ; DX, DY only: NX/NY survive a command
	otir
	pop hl
	ld a,52
	out (V_SEL),a
	ld a,$10                    ; LMMC
	out (V_REG),a
	pop af
	jp po,dr_out
	ei
dr_out:
	call cell_out
dr_adv:
	ld hl,(cmdblk+4)
	ld de,12
	add hl,de
	ld (cmdblk+4),hl
	pop bc
	inc c
	dec b
	jp nz,dr_cell
	call dr_flush
	jp csel_fix

; HL = 8 source bytes of a multicolour cell.  Exactly 2 pixel values: draw it
; with CMMC (12 data bytes instead of LMMC's 48), CF.  Otherwise NC, HL kept.
dr_two:
	push hl
	ld d,CM_PT/256
	ld c,0
	ld e,(hl)
	inc hl
	ld a,(de)
	or c
	ld c,a
	ld e,(hl)
	inc hl
	ld a,(de)
	or c
	ld c,a
	ld e,(hl)
	inc hl
	ld a,(de)
	or c
	ld c,a
	ld e,(hl)
	inc hl
	ld a,(de)
	or c
	ld c,a
	ld e,(hl)
	inc hl
	ld a,(de)
	or c
	ld c,a
	ld e,(hl)
	inc hl
	ld a,(de)
	or c
	ld c,a
	ld e,(hl)
	inc hl
	ld a,(de)
	or c
	ld c,a
	ld e,(hl)
	inc hl
	ld a,(de)
	or c
	ld c,a
	ld hl,cm_pv
	ld e,c
	ld d,0
	add hl,de
	ld a,(hl)
	or a                        ; NC
	jr nz,dt_go
	pop hl
	ret
dt_go:                          ; A = $80 | fg << 2 | bg
	ld b,a
	and 3
	add a,a
	ld e,a
	ld hl,ntq+1
	add hl,de
	ld a,(hl)
	ld (cm_bc),a
	ld a,b
	rrca
	rrca
	and 3
	ld c,a
	add a,a
	ld e,a
	ld hl,ntq+1
	add hl,de
	ld a,(hl)
	ld (cm_fc),a
	ld e,c
	ld hl,cm_x55
	add hl,de
	ld a,(hl)
	ld (cm_x),a
	call v_wait
	ld a,i                      ; P/V = IFF2 (read twice, as k_get_iff)
	jp pe,dt_on
	ld a,i
dt_on:
	push af
	di
	ld a,36
	out (V_SEL),a
	ld hl,cmdblk+4
	ld a,(dr_full)
	or a
	jr z,dt_dxy
	xor a
	ld (dr_full),a
	ld bc,8*256+V_REG
	otir                        ; DX, DY, NX, NY
	xor a
	out (V_REG),a               ; R#44 ARG
	ld a,$0C
	out (V_REG),a               ; R#45 LOP: WC = SC (no transparency)
	jr dt_cols
dt_dxy:                         ; later cells of the run: NX/NY, ARG, LOP survive
	ld bc,4*256+V_REG
	otir                        ; DX, DY
dt_cols:
	ld a,(cm_lv)
	or a
	jr z,dt_send
	ld hl,cm_fc
	ld a,(cm_lfc)
	cp (hl)
	jr nz,dt_send
	inc hl                      ; cm_bc
	ld a,(cm_lbc)
	cp (hl)
	jr z,dt_op                  ; R#48-51 already hold these colours
dt_send:
	ld a,48
	out (V_SEL),a
	ld a,(cm_fc)
	ld (cm_lfc),a
	out (V_REG),a
	out (V_REG),a               ; R#48/49 foreground
	ld a,(cm_bc)
	ld (cm_lbc),a
	out (V_REG),a
	out (V_REG),a               ; R#50/51 background
	ld a,1
	ld (cm_lv),a
dt_op:
	ld a,52
	out (V_SEL),a
	ld a,$50                    ; CMMC
	out (V_REG),a
	pop af
	jp po,dt_di
	ei
dt_di:
	pop de                      ; source
	ld a,(cm_x)
	ld c,a
	ld a,(de)
	inc de
	xor c
	ld l,a
	ld h,CM_TA/256
	ld a,(hl)
	out (V_CMD),a
	inc h
	ld b,(hl)
	ld a,(de)
	inc de
	xor c
	ld l,a
	inc h
	ld a,(hl)
	or b
	out (V_CMD),a
	inc h
	ld a,(hl)
	out (V_CMD),a
	ld a,(de)
	inc de
	xor c
	ld l,a
	ld h,CM_TA/256
	ld a,(hl)
	out (V_CMD),a
	inc h
	ld b,(hl)
	ld a,(de)
	inc de
	xor c
	ld l,a
	inc h
	ld a,(hl)
	or b
	out (V_CMD),a
	inc h
	ld a,(hl)
	out (V_CMD),a
	ld a,(de)
	inc de
	xor c
	ld l,a
	ld h,CM_TA/256
	ld a,(hl)
	out (V_CMD),a
	inc h
	ld b,(hl)
	ld a,(de)
	inc de
	xor c
	ld l,a
	inc h
	ld a,(hl)
	or b
	out (V_CMD),a
	inc h
	ld a,(hl)
	out (V_CMD),a
	ld a,(de)
	inc de
	xor c
	ld l,a
	ld h,CM_TA/256
	ld a,(hl)
	out (V_CMD),a
	inc h
	ld b,(hl)
	ld a,(de)
	inc de
	xor c
	ld l,a
	inc h
	ld a,(hl)
	or b
	out (V_CMD),a
	inc h
	ld a,(hl)
	out (V_CMD),a
	scf
	ret

cm_x55:
	db $00,$55,$AA,$FF
cm_pv:                          ; value mask -> $80 | fg << 2 | bg, 0 unless 2 values
	db 0,0,0,$84,0,$88,$89,0
	db 0,$8C,$8D,0,$8E,0,0,0

; build the CMMC tables (once)
cm_init:
	ld bc,0                     ; C = byte
cmi_l:
	; presence mask
	ld a,c
	ld e,0
	ld b,4
cmi_p:
	push af
	and 3
	ld hl,cm_bit
	add a,l
	ld l,a
	jr nc,cmi_p1
	inc h
cmi_p1:
	ld a,(hl)
	or e
	ld e,a
	pop af
	rrca
	rrca
	djnz cmi_p
	ld h,CM_PT/256
	ld l,c
	ld (hl),e
	; 12-bit pattern in DE: pixel 00 -> 111
	ld de,0
	ld a,c
	ld b,4
cmi_b:
	ex de,hl
	add hl,hl
	add hl,hl
	add hl,hl
	ex de,hl
	rlca
	rlca
	push af
	and 3
	jr nz,cmi_b0
	ld a,e
	or 7
	ld e,a
cmi_b0:
	pop af
	djnz cmi_b
	; DE = bits 11-0
	ld l,c
	ld h,CM_TD/256
	ld (hl),e
	ld h,CM_TC/256
	ld (hl),d
	ld a,e
	and $0F
	rlca
	rlca
	rlca
	rlca
	ld h,CM_TB/256
	ld (hl),a
	ld a,e
	rrca
	rrca
	rrca
	rrca
	and $0F
	ld b,a
	ld a,d
	rlca
	rlca
	rlca
	rlca
	or b
	ld h,CM_TA/256
	ld (hl),a
	inc c
	jr nz,cmi_l
	ret
cm_bit:
	db 1,2,4,8

; send the pending merged one-colour fill (pf_n cells from pf_dx)
dr_flush:
	ld a,(pf_n)
	or a
	ret z
	ld hl,(cmdblk+4)
	push hl
	ld hl,(pf_dx)
	ld (cmdblk+4),hl
	ld b,a
	ld hl,0
	ld de,12
df_l:
	add hl,de
	djnz df_l
	ld (cmdblk+8),hl
	ld a,(pf_col)
	call lmmv
	pop hl
	ld (cmdblk+4),hl
	ld hl,12
	ld (cmdblk+8),hl
	xor a
	ld (pf_n),a
	inc a
	ld (dr_full),a
	ret

; 38-column mode: border over the outer columns of this row
csel_fix:
	ld a,(row_csel)
	or a
	ret nz
	ld a,(row_xoff)
	or a
	jr nz,csf_do
	ld a,(run_start)
	or a
	jr z,csf_do
	ld a,(run_start)
	ld b,a
	ld a,(run_len)
	add a,b
	cp 39
	ret c
csf_do:
	ld a,(cur_row)
	call row_y_clean
	push hl
	ld de,SCREEN_X
	ld bc,12                    ; 7 C64 pixels -> 10.5, round up
	ld a,8
	call fill_rect_hl
	pop hl
	ld de,SCREEN_X+480-14       ; 9 C64 pixels -> 13.5
	ld bc,512-(SCREEN_X+480-14)
	ld a,8
	jp fill_rect_hl

