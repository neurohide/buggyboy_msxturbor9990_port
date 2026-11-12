; V9990 command register setup and drawing primitives.
; ============================================================================
; V9990 commands (cmdblk = R#32..R#52)
; ============================================================================
v_wait:
	in a,(V_STAT)
	rrca
	jr c,v_wait
	ret

v_send_cmd:                     ; write R#32..R#52 atomically
	call v_wait
	call k_get_iff
	push af
	di
	ld a,(cmdblk+20)
	cp $40
	ld a,32
	ld hl,cmdblk
	ld bc,14*256+V_REG          ; R#32..R#45; WM (R#46/47) stays $FFFF from v_init
	jr nc,vsc_sx                ; LMMM and up read SX/SY
	ld a,36                     ; LMMC/LMMV: from DX
	ld l,cmdblk+4 & 255
	ld b,10
vsc_sx:
	out (V_SEL),a
	otir
	ld a,(cmdblk+20)
	cp $20
	jr nz,vsc_op
	ld a,48                     ; FC: only LMMV uses it
	out (V_SEL),a
	ld hl,cmdblk+16
	ld b,2
	otir
vsc_op:
	ld a,52
	out (V_SEL),a
	ld a,(cmdblk+20)
	out (V_REG),a
	pop af
	or a
	ret z
	ei
	ret

; LMMV fill: cmdblk+4 DX, +6 DY, +8 NX, +10 NY set; A = colour byte
lmmv:
	ld (cmdblk+16),a            ; FC
	ld (cmdblk+17),a
	xor a
	ld (cm_lv),a                ; FC changes
	ld (cmdblk+12),a            ; ARG
	ld a,$0C
	ld (cmdblk+13),a            ; LOP: WC = SC
	ld a,$FF
	ld (cmdblk+14),a
	ld (cmdblk+15),a
	ld a,$20                    ; LMMV
	ld (cmdblk+20),a
	jp v_send_cmd

; LMMC: DX, DY, NX, NY set
lmmc_start:
	xor a
	ld (cmdblk+12),a
	ld a,$0C
	ld (cmdblk+13),a
	ld a,$FF
	ld (cmdblk+14),a
	ld (cmdblk+15),a
	ld a,$10                    ; LMMC
	ld (cmdblk+20),a
	jp v_send_cmd

; LMMM copy: SX, SY, DX, DY, NX, NY set
lmmm:
	ld a,$0C
lmmm_lop:
	ld (cmdblk+13),a
	xor a
	ld (cmdblk+12),a
	ld a,$FF
	ld (cmdblk+14),a
	ld (cmdblk+15),a
	ld a,$40                    ; LMMM
	ld (cmdblk+20),a
	jp v_send_cmd
lmmm_tp:
	ld a,$1C                    ; transparent: skip colour 0
	jr lmmm_lop

