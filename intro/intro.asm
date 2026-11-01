; MSX2 cartridge intro, assembled with z80asm.
; SCREEN 5 (256x212, 16 colours). Four layers of Japanese waves scroll at
; different speeds with no pixel copying: every phase of every layer is
; pre-rendered in VRAM, and line interrupts switch the display page (R#2)
; and vertical scroll (R#23) at the top of each layer. A pixel-font scroller
; rides a sine path in the sky, drawn with VDP HMMM block copies, while the
; PSG plays a looping pentatonic theme with koto-like plucks.
; Build: make (python3 gen_data.py && z80asm intro.asm -o intro.rom)

VDP_DATA:       equ     0x98
VDP_CTRL:       equ     0x99
VDP_PAL:        equ     0x9A
VDP_IND:        equ     0x9B
PSG_ADDR:       equ     0xA0
PSG_DATA:       equ     0xA1

; RAM
frame:          equ     0xC001
scroll:         equ     0xC002
tphase:         equ     0xC004
band_ptr:       equ     0xC006
text_x:         equ     0xC008
text_j:         equ     0xC00A
text_idx:       equ     0xC00B
tmp_k:          equ     0xC00C
tmp_n:          equ     0xC00D
tmp_r:          equ     0xC00E
tmp_ph:         equ     0xC010
last_frame:     equ     0xC012
mus_tick:       equ     0xC013
mus_note:       equ     0xC014
env_a:          equ     0xC015
env_b:          equ     0xC016
env_c:          equ     0xC017
mus_period:     equ     0xC018
sun_step:       equ     0xC01A
cmdbuf:         equ     0xC020          ; R#32..R#46
band_list:      equ     0xC040          ; 4 x 8 bytes of (value, register) pairs
cbuf:           equ     0xC060          ; cloud VDP command, R#32..R#46
cloud_pos:      equ     0xC070          ; 3 words, x + width in 1/16 px
cl_ptr:         equ     0xC076
cl_x:           equ     0xC078
last_cloud:     equ     0xC07A
cl_lo:          equ     0xC07B          ; strip span start (even)
cl_nx:          equ     0xC07C          ; strip span width (word)
im2_table:      equ     0xE000          ; 257 x 0xE1 -> vector 0xE1E1
im2_vector:     equ     0xE1E1

        org     0x4000
        db      "AB"
        dw      start
        dw      0, 0, 0, 0, 0, 0

start:
        di
        ld      sp, 0xDFF0

        ; IM2 with a full vector table, so any bus value lands on our handler.
        ld      hl, im2_table
        ld      de, im2_table + 1
        ld      bc, 256
        ld      (hl), 0xE1
        ldir
        ld      a, 0xC3
        ld      (im2_vector), a
        ld      hl, isr
        ld      (im2_vector + 1), hl
        ld      a, im2_table >> 8
        ld      i, a
        im      2

        ld      hl, vdp_init
        ld      bc, VDP_CTRL + 256 * (vdp_init_end - vdp_init)
        otir

        xor     a
        out     (VDP_CTRL), a
        ld      a, 0x90
        out     (VDP_CTRL), a
        ld      hl, palette
        ld      bc, 0x2000 + VDP_PAL
        otir

        call    clear_vram
        call    load_sky
        ld      ix, band0_desc
        call    init_band
        ld      ix, band1_desc
        call    init_band
        ld      ix, band2_desc
        call    init_band
        ld      ix, band3_desc
        call    init_band

        ld      a, GLYPH_PAGE
        ld      d, GLYPH_ROW
        call    vram_wr
        ld      hl, glyphs_rle
        call    out_rle
        call    init_clouds

        ; Constant part of the glyph HMMM command.
        ld      hl, text_cmd
        ld      de, cmdbuf
        ld      bc, 15
        ldir

        xor     a
        ld      (frame), a
        ld      (last_frame), a
        ld      (tphase), a
        ld      (sun_step), a
        ld      (last_cloud), a
        ld      hl, 0
        ld      (scroll), hl
        ld      hl, band_list
        ld      (band_ptr), hl
        call    build_bands
        call    init_music

        ld      a, 0x60                 ; display on, vblank interrupt on
        out     (VDP_CTRL), a
        ld      a, 0x81
        out     (VDP_CTRL), a
        ei

; The big scroller has priority and is redrawn every second frame (30 fps);
; the clouds are rebuilt every fourth frame with the time that is left.
main_loop:
        ld      a, (frame)
        ld      b, a
        ld      a, (last_frame)
        ld      c, a
        ld      a, b
        sub     c
        cp      2
        jr      c, ml_clouds
        ld      a, b
        ld      (last_frame), a
        call    draw_text
        jr      main_loop
ml_clouds:
        ld      a, (last_cloud)
        ld      c, a
        ld      a, b
        sub     c
        cp      4
        jr      c, main_loop
        ld      a, b
        ld      (last_cloud), a
        call    draw_clouds
        jr      main_loop

; ------------------------------------------------------------------ interrupts
; The main program keeps S#2 selected so it can poll CE without DI.
isr:
        push    af
        xor     a
        out     (VDP_CTRL), a
        ld      a, 0x8F
        out     (VDP_CTRL), a
        in      a, (VDP_CTRL)           ; S#0, clears the vblank flag
        rlca
        jr      c, isr_vblank
        push    hl
        push    bc
        ; Neutral scroll (solid rows in every page), page, real scroll, then
        ; the next line interrupt. Each write is atomic, so no torn lines.
        ld      hl, (band_ptr)
        ld      bc, 0x0800 + VDP_CTRL
        otir
        ld      (band_ptr), hl
        call    clear_fh
        pop     bc
        pop     hl
        pop     af
        ei
        reti

isr_vblank:
        push    hl
        push    bc
        ld      hl, top_regs
        ld      bc, 0x0800 + VDP_CTRL
        otir
        call    clear_fh
        ld      hl, band_list
        ld      (band_ptr), hl
        ; Waves advance here, so they stay smooth even if the text overruns.
        push    de
        push    ix
        ld      hl, frame
        inc     (hl)
        call    build_bands
        call    animate_palette
        call    music
        pop     ix
        pop     de
        pop     bc
        pop     hl
        pop     af
        ei
        reti

; Read S#1 to acknowledge a line interrupt, then select S#2 again.
clear_fh:
        ld      a, 1
        out     (VDP_CTRL), a
        ld      a, 0x8F
        out     (VDP_CTRL), a
        in      a, (VDP_CTRL)
        ld      a, 2
        out     (VDP_CTRL), a
        ld      a, 0x8F
        out     (VDP_CTRL), a
        ret

top_regs:
        db      0x1F, 0x82              ; page 0
        db      0x00, 0x97              ; no vertical scroll
        db      FIRST_IRQ, 0x93
        db      0x16, 0x80              ; line interrupts on

; ------------------------------------------------------------------ per frame
; Fill band_list with the register writes for each layer's current phase.
build_bands:
        ld      ix, band_rt
        ld      de, band_list
        ld      b, 4
bb_loop:
        push    bc
        ld      a, (frame)
        ld      b, (ix+0)
        inc     b
        dec     b
        jr      z, bb_noshift
bb_shift:
        srl     a
        djnz    bb_shift
bb_noshift:
        and     (ix+1)
        ld      c, a
        ld      a, (ix+4)               ; neutral scroll
        ld      (de), a
        inc     de
        ld      a, 0x97
        ld      (de), a
        inc     de
        ld      a, c
        add     a, a
        ld      l, (ix+5)
        ld      h, (ix+6)
        ld      c, a
        ld      b, 0
        add     hl, bc
        ld      a, (hl)
        ld      (de), a
        inc     de
        ld      a, 0x82
        ld      (de), a
        inc     de
        inc     hl
        ld      a, (hl)
        ld      (de), a
        inc     de
        ld      c, a
        ld      a, 0x97
        ld      (de), a
        inc     de
        ld      a, (ix+3)
        or      a
        jr      nz, bb_last
        ; Line interrupts count VRAM lines, so add this layer's scroll.
        ld      a, (ix+2)
        add     a, c
        ld      (de), a
        inc     de
        ld      a, 0x93
        jr      bb_store
bb_last:
        ld      a, 0x06                 ; last layer: line interrupts off
        ld      (de), a
        inc     de
        ld      a, 0x80
bb_store:
        ld      (de), a
        inc     de
        ld      bc, 7
        add     ix, bc
        pop     bc
        djnz    bb_loop
        ret

; Sun glow rings (colours 0, 9, 15) and pulsing contour lines (colour 12).
animate_palette:
        ld      a, (frame)
        and     7
        jr      nz, ap_sun_done
        ld      a, (sun_step)
        inc     a
        cp      3
        jr      c, ap_sun_step
        xor     a
ap_sun_step:
        ld      (sun_step), a
        ld      e, a                    ; step * 6
        add     a, a
        add     a, e
        add     a, a
        ld      e, a
        ld      d, 0
        ld      hl, sun_cycle
        add     hl, de
        xor     a
        call    set_colour
        inc     hl
        ld      a, 9
        call    set_colour
        inc     hl
        ld      a, 15
        call    set_colour
ap_sun_done:
        ld      a, (frame)
        rrca
        rrca
        rrca
        and     15
        add     a, a
        ld      e, a
        ld      d, 0
        ld      hl, contour_tab
        add     hl, de
        ld      a, 12
; A = colour index, HL -> two palette bytes. Called from the ISR only.
set_colour:
        out     (VDP_CTRL), a
        ld      a, 0x90
        out     (VDP_CTRL), a
        ld      a, (hl)
        out     (VDP_PAL), a
        inc     hl
        ld      a, (hl)
        out     (VDP_PAL), a
        ret

; Each glyph block is 32x38 with sky-coloured margins, so redrawing it at the
; new position also erases where it was last frame.
draw_text:
        ld      hl, (scroll)
        ld      de, 4
        add     hl, de
        ld      de, MSG_PIX
        or      a
        sbc     hl, de
        jr      nc, dt_wrapped
        add     hl, de
dt_wrapped:
        ld      (scroll), hl
        ld      a, (tphase)
        add     a, 2
        ld      (tphase), a

        ld      a, l
        and     CELL - 1
        neg
        ld      e, a
        ld      d, 0xFF
        jr      nz, dt_neg
        ld      d, 0
dt_neg:
        ld      (text_x), de
        ; first character = scroll / 32
        srl     h
        rr      l
        srl     h
        rr      l
        srl     l
        srl     l
        srl     l
        ld      a, l
        ld      (text_idx), a
        ld      a, 256 / CELL + 1
        ld      (text_j), a

dt_char:
        ld      hl, (text_x)
        ld      a, h
        cp      1
        jr      z, dt_next              ; x >= 256: off screen

        ; y from the sine path at the glyph centre
        ld      de, CELL / 2
        add     hl, de
        ld      a, (tphase)
        ld      e, a
        add     hl, de
        srl     h
        rr      l
        ld      a, l
        and     127
        ld      e, a
        ld      hl, sine_tab
        add     hl, de
        ld      a, (hl)
        ld      (cmdbuf + 6), a         ; DY

        ld      a, (text_idx)
        ld      e, a
        ld      hl, message
        add     hl, de
        ld      a, (hl)
        add     a, a
        ld      e, a
        ld      hl, glyph_src
        add     hl, de
        ld      b, (hl)                 ; SX
        inc     hl
        ld      a, (hl)
        ld      (cmdbuf + 2), a         ; SY low
        ld      c, CELL                 ; NX
        ld      hl, (text_x)
        ld      a, h
        or      a
        jr      z, dt_right
        ; partly off the left edge
        ld      a, l
        neg
        add     a, b
        ld      b, a
        ld      a, c
        add     a, l
        ld      c, a
        xor     a
        jr      dt_set
dt_right:
        ld      a, l
        cp      256 - CELL + 1
        jr      c, dt_set
        neg                             ; 256 - x
        ld      c, a
        ld      a, l
dt_set:
        ld      (cmdbuf + 4), a         ; DX
        ld      a, b
        ld      (cmdbuf + 0), a         ; SX
        ld      a, c
        ld      (cmdbuf + 8), a         ; NX
        ld      hl, cmdbuf
        call    vdp_cmd

dt_next:
        ld      hl, (text_x)
        ld      de, CELL
        add     hl, de
        ld      (text_x), hl
        ld      a, (text_idx)
        inc     a
        cp      MSG_LEN
        jr      c, dt_idx
        xor     a
dt_idx:
        ld      (text_idx), a
        ld      hl, text_j
        dec     (hl)
        jr      nz, dt_char
        ret

text_cmd:
        db      0, 0, 0, GLYPH_PAGE
        db      0, 0, 0, 0
        db      CELL, 0, BLOCK_H, 0
        db      0, 0, 0xD0              ; HMMM

; ------------------------------------------------------------------ clouds
; Each cloud is rebuilt off screen: copy its clean sky strip into a buffer,
; paste the cloud with a transparent LMMM, then copy the strip to the screen
; in one pass, so it never flickers over Fuji or the sun.
init_clouds:
        ld      a, 1
        ld      d, CLOUD_SPRITE_ROW
        call    vram_wr
        ld      hl, clouds_rle
        call    out_rle
        ld      hl, cloud_init
        ld      de, cloud_pos
        ld      bc, CLOUD_COUNT * 2
        ldir
        ld      ix, cloud_tab
        ld      b, CLOUD_COUNT
ic_loop:
        push    bc
        ld      hl, tmpl_grab
        call    cloud_cmd
        ld      a, (ix+1)
        ld      (cbuf + 2), a           ; SY = screen row, page 0
        ld      a, (ix+3)
        ld      (cbuf + 6), a           ; DY = clean strip, page 2
        call    cloud_go
        ld      bc, 8
        add     ix, bc
        pop     bc
        djnz    ic_loop
        ret

draw_clouds:
        ld      ix, cloud_tab
        ld      hl, cloud_pos
        ld      (cl_ptr), hl
        ld      b, CLOUD_COUNT
dc_loop:
        push    bc
        ; pos += speed, wrapping at (256 + width) * 16
        ld      hl, (cl_ptr)
        ld      e, (hl)
        inc     hl
        ld      d, (hl)
        ld      l, (ix+5)
        ld      h, 0
        add     hl, de
        ld      e, (ix+6)
        ld      d, (ix+7)
        or      a
        sbc     hl, de
        jr      nc, dc_wrapped
        add     hl, de
dc_wrapped:
        ex      de, hl
        ld      hl, (cl_ptr)
        ld      (hl), e
        inc     hl
        ld      (hl), d
        inc     hl
        ld      (cl_ptr), hl
        ; x = pos / 16 - width
        ex      de, hl
        srl     h
        rr      l
        srl     h
        rr      l
        srl     h
        rr      l
        srl     h
        rr      l
        ld      e, (ix+0)
        ld      d, 0
        or      a
        sbc     hl, de
        ld      (cl_x), hl

        ; Only rebuild the columns from x - 2 to x + width + 2.
        ld      de, -2
        add     hl, de
        bit     7, h
        jr      z, dc_lo
        ld      hl, 0
dc_lo:
        ld      a, l
        and     0xFE
        ld      (cl_lo), a
        ld      hl, (cl_x)
        ld      e, (ix+0)
        ld      d, 0
        add     hl, de
        inc     hl
        inc     hl
        inc     hl
        ld      a, l
        and     0xFE
        ld      l, a
        ld      de, 256
        or      a
        sbc     hl, de
        jr      c, dc_hi
        ld      hl, 0
dc_hi:
        add     hl, de
        ld      a, (cl_lo)
        ld      e, a
        ld      d, 0
        or      a
        sbc     hl, de
        ld      (cl_nx), hl

        ld      hl, tmpl_restore
        call    cloud_cmd
        ld      a, (ix+3)
        ld      (cbuf + 2), a
        ld      a, (ix+4)
        ld      (cbuf + 6), a
        call    set_span
        call    cloud_go

        ld      hl, tmpl_paste
        call    cloud_cmd
        ld      a, (ix+2)
        ld      (cbuf + 2), a
        ld      a, (ix+4)
        ld      (cbuf + 6), a
        ld      hl, (cl_x)
        ld      c, (ix+0)               ; NX
        ld      b, 0                    ; SX
        ld      a, h
        or      a
        jr      z, dc_right
        ; partly off the left edge
        ld      a, l
        neg
        ld      b, a
        ld      a, c
        add     a, l
        ld      c, a
        xor     a
        jr      dc_set
dc_right:
        ld      a, l
        add     a, c
        ld      a, l
        jr      nc, dc_set
        neg                             ; 256 - x
        ld      c, a
        ld      a, l
dc_set:
        ld      (cbuf + 4), a           ; DX
        ld      a, b
        ld      (cbuf + 0), a           ; SX
        ld      a, c
        ld      (cbuf + 8), a           ; NX
        or      a
        call    nz, cloud_go            ; NX = 0 would mean 512

        ld      hl, tmpl_show
        call    cloud_cmd
        ld      a, (ix+4)
        ld      (cbuf + 2), a
        ld      a, (ix+1)
        ld      (cbuf + 6), a
        call    set_span
        call    cloud_go

        ld      bc, 8
        add     ix, bc
        pop     bc
        dec     b
        jp      nz, dc_loop
        ret

; Copy a 15-byte command template from HL into cbuf.
cloud_cmd:
        ld      de, cbuf
        ld      bc, 15
        ldir
        ret

cloud_go:
        ld      hl, cbuf
        jp      vdp_cmd

; SX = DX = span start, NX = span width.
set_span:
        ld      a, (cl_lo)
        ld      (cbuf + 0), a
        ld      (cbuf + 4), a
        ld      hl, (cl_nx)
        ld      (cbuf + 8), hl
        ret

tmpl_grab:                              ; page 0 strip -> clean copy
        db      0, 0, 0, 0, 0, 0, 0, 2, 0, 1, 4, 0, 0, 0, 0xD0
tmpl_restore:                           ; clean copy -> buffer
        db      0, 0, 0, 2, 0, 0, 0, 2, 0, 1, 4, 0, 0, 0, 0xD0
tmpl_paste:                             ; cloud sprite -> buffer, LMMM TIMP
        db      0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 4, 0, 0, 0, 0x98
tmpl_show:                              ; buffer -> screen
        db      0, 0, 0, 2, 0, 0, 0, 0, 0, 1, 4, 0, 0, 0, 0xD0

; ------------------------------------------------------------------ music
; Koto imitation on the PSG: A plays the theme as a sharp pluck that starts
; slightly sharp and settles, B repeats each note softly as resonance, and
; C plucks a low root every four notes. Runs once per vblank.
init_music:
        xor     a
        ld      (mus_tick), a
        ld      (mus_note), a
        ld      a, ENV_LEN - 1
        ld      (env_a), a
        ld      (env_b), a
        ld      (env_c), a
        ld      a, 7
        ld      e, 0xB8                 ; tones on, noise off, MSX port bits
        jp      psg_write

music:
        ld      a, (mus_tick)
        or      a
        jr      nz, mu_echo
        ld      a, (mus_note)
        add     a, a
        ld      e, a
        ld      d, 0
        ld      hl, melody
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)
        ld      (mus_period), de
        xor     a
        ld      (env_a), a
        ld      a, (mus_note)
        ld      c, a
        and     3
        jr      nz, mu_echo
        ld      a, c                    ; note / 4 * 2
        rrca
        and     0x06
        ld      e, a
        ld      d, 0
        ld      hl, bass_tab
        add     hl, de
        ld      e, (hl)
        inc     hl
        ld      d, (hl)
        ld      a, 4
        call    psg_period
        xor     a
        ld      (env_c), a
mu_echo:
        ld      a, (mus_tick)
        cp      ECHO_DELAY
        jr      nz, mu_bend
        ld      de, (mus_period)
        ld      a, 2
        call    psg_period
        xor     a
        ld      (env_b), a
mu_bend:
        ; Pitch settles over the first frames of the pluck.
        ld      hl, (mus_period)
        ld      a, (env_a)
        cp      3
        jr      nc, mu_pitch
        ld      d, h
        ld      e, l
        ld      b, 5
mu_div:
        srl     d
        rr      e
        djnz    mu_div                  ; period / 32
        ld      b, a
        ld      a, 3
        sub     b
        ld      b, a
mu_sharp:
        or      a
        sbc     hl, de
        djnz    mu_sharp
mu_pitch:
        ex      de, hl
        xor     a
        call    psg_period

        ld      hl, env_a
        ld      de, env_melody
        ld      a, 8
        call    mu_volume
        ld      hl, env_b
        ld      de, env_echo
        ld      a, 9
        call    mu_volume
        ld      hl, env_c
        ld      de, env_bass
        ld      a, 10
        call    mu_volume

        ld      a, (mus_tick)
        inc     a
        cp      NOTE_LEN
        jr      c, mu_tick
        ld      a, (mus_note)
        inc     a
        cp      MEL_LEN
        jr      c, mu_note
        xor     a
mu_note:
        ld      (mus_note), a
        xor     a
mu_tick:
        ld      (mus_tick), a
        ret

; HL -> envelope position, DE -> envelope table, A = volume register.
mu_volume:
        ld      c, a
        ld      a, (hl)
        cp      ENV_LEN - 1
        jr      nc, mv_hold
        inc     (hl)
mv_hold:
        add     a, e
        ld      e, a
        jr      nc, mv_nc
        inc     d
mv_nc:
        ld      a, (de)
        ld      e, a
        ld      a, c
; A = PSG register, E = value.
psg_write:
        out     (PSG_ADDR), a
        ld      a, e
        out     (PSG_DATA), a
        ret

; A = first tone register of a channel, DE = period.
psg_period:
        out     (PSG_ADDR), a
        ld      c, a
        ld      a, e
        out     (PSG_DATA), a
        ld      a, c
        inc     a
        out     (PSG_ADDR), a
        ld      a, d
        out     (PSG_DATA), a
        ret

; ------------------------------------------------------------------ VDP helpers
wait_ce:
        in      a, (VDP_CTRL)           ; S#2
        rra
        jr      c, wait_ce
        ret

; HL -> 15 bytes for R#32..R#46.
vdp_cmd:
        call    wait_ce
        di
        ld      a, 32
        out     (VDP_CTRL), a
        ld      a, 0x91
        out     (VDP_CTRL), a
        ei                              ; the ISR never touches R#17
        ld      bc, 0x0F00 + VDP_IND
        otir
        ret

; Set the VRAM write address to A = page, D = row.
vram_wr:
        ld      e, a
        ld      a, d
        rrca
        and     0x80
        ld      l, a
        ld      a, d
        srl     a
        bit     0, e
        jr      z, vw_even
        or      0x80
vw_even:
        ld      h, a
        rlca
        rlca
        and     3
        ld      b, a
        ld      a, e
        and     2
        add     a, a
        or      b
        di
        out     (VDP_CTRL), a
        ld      a, 0x8E
        out     (VDP_CTRL), a
        ld      a, l
        out     (VDP_CTRL), a
        ld      a, h
        and     0x3F
        or      0x40
        out     (VDP_CTRL), a
        ei
        ret

; ------------------------------------------------------------------ setup
clear_vram:
        ld      hl, clear_cmd
        ld      de, cmdbuf
        ld      bc, 15
        ldir
        xor     a
cv_page:
        ld      (cmdbuf + 7), a         ; DY high = page
        push    af
        ld      hl, cmdbuf
        call    vdp_cmd
        pop     af
        inc     a
        cp      4
        jr      nz, cv_page
        jp      wait_ce

clear_cmd:
        db      0, 0, 0, 0
        db      0, 0, 0, 0
        db      0, 1, 0, 1              ; 256 x 256
        db      SEA_FILL, 0, 0xC0       ; HMMV with the sea colour

load_sky:
        xor     a
        ld      d, a
        call    vram_wr
        ld      hl, sky_rle
; Copy (count, byte) runs from HL to VRAM until a zero count.
out_rle:
ls_run:
        ld      a, (hl)
        or      a
        ret     z
        ld      b, a
        inc     hl
        ld      a, (hl)
        inc     hl
ls_byte:
        out     (VDP_DATA), a
        djnz    ls_byte
        jr      ls_run

; IX -> band descriptor: height, step bytes, phase count, tile, (page,row)*n.
; Tile rows are stored twice (32 bytes) so a phase is a plain offset into them.
init_band:
        ld      a, (ix+2)
        ld      (tmp_n), a
        xor     a
        ld      (tmp_k), a
        push    ix
        pop     hl
        ld      de, 5
        add     hl, de
        ld      (tmp_ph), hl
ib_phase:
        ld      hl, (tmp_ph)
        ld      a, (hl)
        inc     hl
        ld      d, (hl)
        call    vram_wr
        ld      a, (ix+1)
        ld      c, a
        ld      a, (tmp_k)
        dec     c
        jr      z, ib_step1
        add     a, a
ib_step1:
        ld      c, a
        ld      b, 0
        ld      l, (ix+3)
        ld      h, (ix+4)
        add     hl, bc
        ld      a, (ix+0)
        ld      (tmp_r), a
ib_row:
        ld      e, 8
ib_rep:
        push    hl
        ld      bc, 0x1000 + VDP_DATA
        otir
        pop     hl
        dec     e
        jr      nz, ib_rep
        ld      bc, 32
        add     hl, bc
        ld      a, (tmp_r)
        dec     a
        ld      (tmp_r), a
        jr      nz, ib_row
        ld      hl, (tmp_ph)
        inc     hl
        inc     hl
        ld      (tmp_ph), hl
        ld      a, (tmp_k)
        inc     a
        ld      (tmp_k), a
        ld      hl, tmp_n
        cp      (hl)
        jr      nz, ib_phase
        ret

vdp_init:
        db      0x06, 0x80              ; SCREEN 5, line interrupts off
        db      0x00, 0x81              ; display off during setup
        db      0x1F, 0x82              ; page 0
        db      0xEF, 0x85
        db      0x0F, 0x86
        db      0x01, 0x87              ; border colour
        db      0x2A, 0x88              ; colour 0 opaque, 64K VRAM, sprites off
        db      0x80, 0x89              ; 212 lines, 60 Hz
        db      0x00, 0x8B
        db      0x00, 0x8E
        db      0x02, 0x8F              ; status register 2 (CE polling)
        db      0x00, 0x92
        db      0x00, 0x93
        db      0x00, 0x97
vdp_init_end:

        include "data.inc"

rom_end:
        ds      0x8000 - rom_end, 0xFF
