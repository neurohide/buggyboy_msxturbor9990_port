; Per-frame MSX joystick and keyboard sampling into C64 input state.
; Routines: read_input.

; input (once per frame)
; ============================================================================
read_input:
	; joystick port 1 via PSG R14. R15 drives the connector lines: pin 6/7
	; high, pin 8 low, and bit 6 low selects port 1.
	ld a,15
	out ($A0),a
	in a,($A2)
	or $03                     ; port 1 pins 6 and 7 high
	and $EF                    ; port 1 pin 8 low
	and $BF
	out ($A1),a
	ld a,14
	out ($A0),a
	in a,($A2)
	or $E0
	ld b,a                      ; MSX: b0 up b1 down b2 left b3 right b4 trig A
	; keyboard row 8: b0 space, b4 left, b5 up, b6 down, b7 right
	in a,($AA)
	and $F0
	or 8
	out ($AA),a
	in a,($A9)
	ld c,a
	bit 5,c
	jr nz,ri1
	res 0,b
ri1:
	bit 6,c
	jr nz,ri2
	res 1,b
ri2:
	bit 4,c
	jr nz,ri3
	res 2,b
ri3:
	bit 7,c
	jr nz,ri4
	res 3,b
ri4:
	bit 0,c
	jr nz,ri5
	res 4,b
ri5:
	; steering direction changed: the game only steers on the frame where its
	; countdown LEED0 ($EED0) equals 1 (once per 8 frames).  Make that the next
	; frame so a key press is felt at once; the 8-frame rhythm then restarts.
	ld a,(joy_state)
	xor b
	and $0C
	jr z,ri5b
	ld a,($EED0)
	cp 2
	jr c,ri5b                   ; 0: not racing, 1: steering step is already next
	ld a,1
	ld ($EED0),a
ri5b:
	ld a,b
	ld (joy_state),a
	; C64 column 7: RUN/STOP (row 7) <- MSX STOP (row 7 bit 4);
	;               <- (row 1) <- MSX ESC (row 7 bit 2)
	in a,($AA)
	and $F0
	or 7
	out ($AA),a
	in a,($A9)
	ld c,a
	ld b,$FF
	bit 4,c
	jr nz,ri6
	res 7,b
ri6:
	bit 2,c
	jr nz,ri7
	res 1,b
ri7:
	ld a,b
	ld (key_rows+7),a
	ret

; ============================================================================
