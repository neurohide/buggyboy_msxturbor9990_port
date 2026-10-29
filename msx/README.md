# Buggy Boy for MSX2+ (V9958)

A port of the Commodore 64 version of Buggy Boy (the depacked image in
`../disasm/game.s`) to a stock MSX2+: Z80 at 3.58 MHz, V9958, plus a memory
mapper of at least 256K. It also runs on a turbo R, which it switches to the R800.

The 6502 game code is not emulated: it is **statically translated** to Z80
code. A small kernel stands in for the C64 hardware: VIC-II, SID, CIA and the
raster interrupts.

**Speed:** a Z80 needs many frames for one C64 frame. The game runs in slow
motion: about 4 game frames per second in a race on a 3.58 MHz MSX2+ and
about 8 on a turbo R, where the C64 runs 50.

## Build

Requirements: Python 3 and `z80asm` (Bas Wijnen's, `brew install z80asm`).

    python3 tools/build.py        # -> build/buggyboy.rom (256K ASCII16 MegaROM)

## Run

openMSX, an MSX2+ with a RAM expansion (Japanese MSX2+ machines have 64K):

    openmsx -machine Sony_HB-F1XDJ -ext ram512k -cart build/buggyboy.rom -romtype ASCII16

On real hardware: any MSX2+ or turbo R with a memory mapper of 256K or more,
in any slot. The loader picks the biggest mapper it finds. Without one it
prints a message and stops. The ROM goes in an ASCII16 MegaROM cartridge.

Controls: joystick in port 1, or cursor keys + SPACE (fire).
STOP = pause (C64 RUN/STOP), ESC = C64 "←" key.

## How it works

| Piece | File | What it does |
|---|---|---|
| Image + tracer | `tools/c64image.py` | Rebuilds the C64 memory image from the listing, applies the crack's start-up patches, traces all code (including code only reachable through jump tables). |
| Translator | `tools/translate.py` | 6502 → Z80: A→A, X→E (D=0), Y→C (B=0), N/Z→S/Z, carry polarity tracked lazily, flag liveness analysis, self-modifying operands read at run time. JMP-connected code stays in one 16K segment; JSR across segments goes through `k_farcall`. |
| Kernel | `src/kernel_p0.asm`, `src/kernel_p2.asm` | Lives in C64 pages that only held 6502 code. IM2 interrupt entry, memory helpers, VIC/SID/CIA register emulation, the C64 raster IRQs (see below), far calls, indirect-jump dispatch (hash table), SID→PSG with software ADSR, joystick/keyboard. |
| Renderer | `src/render.asm` | Own mapper segment, runs after each C64 frame. Draws dirty C64 cells (text, multicolour, bitmap) into SCREEN 7 (GRAPHIC 6, 512×212, 16 colours) at 3 pixels per C64 multicolour pixel, so the full 40-column screen fits with the right aspect ratio. Cells are written by the CPU into a sprite-free copy in VRAM page 1 and copied to the display (page 0) by the VDP. Sprites are cached as shapes in the unseen lines of both pages and drawn with LMMM (colour 0 transparent). |
| Loader | `src/loader.asm` | ROM bank 0: finds the biggest memory mapper, copies the images into mapper segments, takes over all four pages. |

Memory while the game runs: page 0 = C64 $0000-$3FFF, page 1 = translated
code (banked), page 2 = C64 $8000-$BFFF, page 3 = C64 $C000-$FFFF. The VIC
bank ($4000-$7FFF) is a separate segment reached through `k_vrd`/`k_vwr`,
which also keep the renderer's dirty bitmap (1 bit per 8 bytes).

Raster interrupts: the V9958 has no readable raster counter and the MSX2+ has
no timer. So the C64 raster IRQs are not run at their lines. At each vblank
that starts a frame, the kernel runs the whole chain of handlers for the
coming frame at once, in line order. Each handler sees the line it was
raised for. Their VIC register changes go to a per-frame timeline, which the
renderer uses to pick the mode, colours and sprite set for each character
row. Their writes to `$D020-$D023` go to a palette schedule. A small V9958
line-interrupt handler plays that schedule back on the next frame, which
gives the road stripes.

Frames are run when the C64 main code has had its turn: when it polls the
raster (which it does to wait for the next frame), or at the latest after 2
vblanks. Raster reads from main code see a virtual beam that moves 8 lines
per read through every line the game waits for, then stays at the bottom
until a vblank has passed.

## Known limitations

- Slow motion (see above). The CPU time goes roughly to the renderer
  (60%: dirty-cell analysis, cell drawing, waiting for the VDP's sprite
  copies), the C64 main code (25%: mostly drawing the road into the VIC bank
  through `k_vwr`) and the C64 IRQs (15%).
- One display page: sprites are erased and redrawn while the frame is on
  screen, so they can flicker.
- Horizontal fine scroll is rounded to whole bytes (2 pixels, at most 1/3 of
  a C64 multicolour pixel off).
- The 4bpp palette has 12 free entries, so brown, light red, dark grey and
  light green are shown as orange, red, grey and green. Colours are 3 bits
  per component.
- Hires pixels are 1.5 V9958 pixels wide (two become `a, a|b, b`).
- Sprite-sprite collisions use the sprites' bounding boxes, not pixels.
  Sprite-background priority and collisions are not emulated.
- SID sound is approximated on the PSG (square/noise, software envelope, no
  filter).

## Tests

`test/run.sh <seconds> <out-prefix> [tcl]` boots the ROM headless in openMSX
(Sony HB-F1XDJ + 512K mapper). It optionally runs extra Tcl (key presses,
breakpoints), samples the PC every 0.5 ms (from `SAMPLE_FROM` seconds on) and
prints a profile (`tools/symmap.py`, `tools/profgroup.py`).
`test/mkdrive.sh <dir>` writes a Tcl script that taps fire through the menus,
drives the buggy and measures the game's frame rate. To use it:

    test/mkdrive.sh /tmp/d && SAMPLE_FROM=120 test/run.sh 136 /tmp/d/run "source /tmp/d/drive.tcl"
