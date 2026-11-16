; PSG setup and per-frame SID-to-PSG audio synthesis.
; Routines: psg_init, psg_write, sound_frame, sid_period, sid_envelope, env_rate.

; SID -> PSG (once per frame)
; ============================================================================
psg_init:
	ld b,14
	ld c,0
pi_l:
	ld a,c
	out ($A0),a
	xor a
	out ($A1),a
	inc c
	djnz pi_l
	ld a,7
	out ($A0),a
	ld a,$BF                    ; all off, port A input / B output
	out ($A1),a
	ld hl,SPC_KEY               ; period cache: freq 0 -> clamp period $0FFF
	ld b,6
pi_k:
	ld (hl),0
	inc hl
	djnz pi_k
	ld hl,SPC_VAL
	ld b,3
pi_v:
	ld (hl),$FF
	inc hl
	ld (hl),$0F
	inc hl
	djnz pi_v
	ret

psg_write:                      ; register A, value L
	out ($A0),a
	ld a,l
	out ($A1),a
	ret

sound_frame:
	; odd vblanks: advance the envelopes only (same rate), skip the PSG synthesis
	ld a,(frame_count)
	rrca
	jr nc,sf_full
	ld c,0
	ld ix,SID_REGS
sf_eo:
	call sid_envelope
	ld de,7
	add ix,de
	inc c
	ld a,c
	cp 3
	jr nz,sf_eo
	ret
sf_full:
	ld a,$BF                    ; mixer: start with everything off
	ld (k_tmp),a
	ld c,0                      ; voice
	ld ix,SID_REGS
sf_voice:
	call sid_envelope           ; A = level 0..15
	ld b,a
	; waveform: control register
	ld a,(ix+4)
	and $F8
	jr z,sf_silent
	bit 3,(ix+4)                ; test bit
	jr nz,sf_silent
	; volume * master / 16
	ld a,(SID_REGS+$18)
	and $0F
	inc a
	ld h,a
	ld a,b
	call mul4x4                 ; A = b*h/16
	ld l,a
	ld a,c
	add a,8
	call psg_write
	; tone period = 1905600 / F
	ld l,(ix+0)
	ld h,(ix+1)
	call sid_period_c           ; HL = PSG period (12 bit)
	ld a,c
	add a,a
	push hl
	call psg_write
	pop hl
	ld l,h
	ld a,c
	add a,a
	inc a
	call psg_write
	; mixer bits: tone enable = bit c low, noise enable = bit c+3 low
	ld a,(ix+4)
	bit 7,a
	ld a,(k_tmp)
	jr nz,sf_noise
	call sf_bit
	cpl
	and (hl)
	ld (k_tmp),a
	jr sf_next
sf_noise:
	; noise period from the frequency high byte
	ld a,(ix+1)
	cpl
	rrca
	rrca
	rrca
	and $1F
	ld l,a
	ld a,6
	call psg_write
	call sf_bit
	rlca
	rlca
	rlca
	cpl
	ld hl,k_tmp
	and (hl)
	ld (hl),a
	jr sf_next
sf_silent:
	ld a,c
	add a,8
	ld l,0
	call psg_write
sf_next:
	ld de,7
	add ix,de
	ld de,0
	inc c
	ld a,c
	cp 3
	jp nz,sf_voice
	ld a,(k_tmp)
	ld l,a
	ld a,7
	jp psg_write
sf_bit:                         ; A = 1 << c, HL = k_tmp
	push bc
	ld b,c
	inc b
	ld a,1
sfb_l:
	djnz sfb_s
	pop bc
	ld hl,k_tmp
	ret
sfb_s:
	add a,a
	jr sfb_l

; A*H/16 with A,H in 0..16 -> A
mul4x4:
	push bc
	ld b,h
	ld c,a
	xor a
	inc b
m44_l:
	dec b
	jr z,m44_d
	add a,c
	jr m44_l
m44_d:
	rrca
	rrca
	rrca
	rrca
	and $0F
	pop bc
	ret

; sid_period with a per-voice (C) cache: the division reruns only when the
; voice frequency changed.  shortcut: SPC_VAL lives in unused SID shadow
; $5A-$5F, a game write there would corrupt the cache; none is expected.
sid_period_c:
	push bc
	ld a,c
	add a,a
	ld b,a                      ; B = 2*voice
	add a,SPC_KEY & 255
	ld e,a
	ld d,SPC_KEY/256
	ld a,(de)
	cp l
	jr nz,spc_miss
	inc de
	ld a,(de)
	cp h
	jr nz,spc_miss1
	ld a,SPC_VAL & 255
	add a,b
	ld l,a
	ld h,SPC_VAL/256
	ld a,(hl)
	inc hl
	ld h,(hl)
	ld l,a
	pop bc
	ret
spc_miss:
	inc de
spc_miss1:
	ld a,h
	ld (de),a
	dec de
	ld a,l
	ld (de),a
	call sid_period
	push hl
	ld a,SPC_VAL & 255
	add a,b
	ld e,a
	ld d,SPC_VAL/256
	ld a,l
	ld (de),a
	inc de
	ld a,h
	ld (de),a
	pop hl
	pop bc
	ret

; HL = SID frequency -> HL = PSG tone period = 1905600 / F.  F >= 512 gives a
; quotient < 4096, so 12 restoring-division steps suffice: remainder starts as
; 1905600 >> 12 ($1D1 < F), dividend bits are the low 12 bits ($3C0) in DE.
sid_period:
	ld a,h
	cp 2
	jr nc,sdp_ok_range           ; F < 512 -> period >= 3722: clamp
	ld hl,$0FFF
	ret
sdp_ok_range:
	push bc
	push de
	ld b,h
	ld c,l                      ; BC = F
	ld hl,$01D1
	ld de,$3C00
	ld a,12
sdp_l:
	sla e
	rl d
	adc hl,hl
	jr c,sdp_f
	sbc hl,bc
	jr nc,sdp_q
	add hl,bc
	jr sdp_d
sdp_f:
	or a
	sbc hl,bc
sdp_q:
	inc e
sdp_d:
	dec a
	jr nz,sdp_l
	ex de,hl                    ; quotient
	pop de
	pop bc
	ret

; ADSR emulation for voice C (IX -> its SID registers) -> A = level 0..15.
; Levels are 8.8 fixed point; clobbers B, DE, HL.
sid_envelope:
	ld a,c
	add a,a
	add a,sid_lvl & 255
	ld l,a
	ld h,sid_lvl/256
	ld e,(hl)
	inc hl
	ld d,(hl)                   ; DE = level
	ld a,c
	add a,sid_phase & 255
	ld l,a
	ld h,sid_phase/256
	push hl                     ; phase pointer
	ld a,(hl)
	cp 1
	jr z,se_attack
	cp 2
	jr z,se_decay
	cp 3
	jr z,se_release
	ld de,0
	jr se_store
se_attack:
	ld a,(ix+5)
	rrca
	rrca
	rrca
	rrca
	call env_rate
	add hl,de
	ex de,hl
	ld a,d
	cp $0F
	jr c,se_store
	ld de,$0F00
	pop hl
	ld (hl),2
	push hl
	jr se_store
se_decay:
	ld a,(ix+6)
	rrca
	rrca
	rrca
	rrca
	and $0F
	ld b,a                      ; sustain level
	cp d
	jr nc,se_hold
	ld a,(ix+5)
	call env_rate
	call div3_hl
	ex de,hl
	or a
	sbc hl,de
	ex de,hl
	jr c,se_hold
	ld a,d
	cp b
	jr nc,se_store
se_hold:
	ld d,b
	ld e,0
	jr se_store
se_release:
	ld a,(ix+6)
	call env_rate
	call div3_hl
	ex de,hl
	or a
	sbc hl,de
	ex de,hl
	jr nc,se_store
	ld de,0
	pop hl
	ld (hl),0
	push hl
se_store:
	pop hl
	ld a,c
	add a,a
	add a,sid_lvl & 255
	ld l,a
	ld h,sid_lvl/256
	ld (hl),e
	inc hl
	ld (hl),d
	ld a,d
	ret

; A low nibble = SID rate index -> HL = level increment per frame (8.8)
env_rate:
	and $0F
	add a,a
	ld l,a
	ld h,0
	push de
	ld de,env_rates
	add hl,de
	pop de
	ld a,(hl)
	inc hl
	ld h,(hl)
	ld l,a
	ret
div3_hl:                        ; HL = HL/3 (approx: *85/256)
	push de
	ld d,h
	ld e,l
	srl h
	rr l
	srl h
	rr l                        ; /4
	push hl
	srl h
	rr l
	srl h
	rr l                        ; /16
	pop de
	add hl,de                   ; /4 + /16
	ld d,h
	ld e,l
	srl h
	rr l
	srl h
	rr l
	srl h
	rr l
	srl h
	rr l
	add hl,de                   ; *(1+1/16)
	pop de
	ret
; 15*256*20ms / attack time (2,8,16,24,38,56,68,80,100,250,500,800,1000,3000,5000,8000 ms)
env_rates:
	dw 38400, 9600, 4800, 3200, 2021, 1371, 1129, 960
	dw 768, 307, 154, 96, 77, 26, 15, 10

