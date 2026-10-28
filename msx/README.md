# Buggy Boy for MSX turbo R + V9990

A port of the Commodore 64 version of Buggy Boy (the depacked image in
`../disasm/game.s`) to the MSX turbo R (R800, memory mapper) with a V9990
(Gfx9000 / compatible) as the display.

The 6502 game code is not emulated: it is **statically translated** to Z80/R800
code. A small kernel stands in for the C64 hardware: VIC-II, SID, CIA and the
raster interrupts.

## Build

Requirements: Python 3 and `z80asm` (Bas Wijnen's, `brew install z80asm`).

    python3 tools/build.py        # -> build/buggyboy.rom (256K ASCII16 MegaROM)

## Run

openMSX with a turbo R and the Gfx9000 extension:

    openmsx -machine Panasonic_FS-A1GT -ext gfx9000 -cart build/buggyboy.rom -romtype ASCII16

Select the Gfx9000 video output (`set videosource GFX9000`, or the
openMSX menu). On real hardware: a turbo R (256K+ mapper RAM) plus a V9990
cartridge, ROM in an ASCII16 MegaROM cartridge.

Controls: joystick in port 1, or cursor keys + SPACE (fire).
STOP = pause (C64 RUN/STOP), ESC = C64 "←" key.

## How it works

| Piece | File | What it does |
|---|---|---|
| Image + tracer | `tools/c64image.py` | Rebuilds the C64 memory image from the listing, applies the crack's start-up patches, traces all code (including code only reachable through jump tables). |
| Translator | `tools/translate.py` | 6502 → Z80: A→A, X→E (D=0), Y→C (B=0), N/Z→S/Z, carry polarity tracked lazily, flag liveness analysis, self-modifying operands read at run time. JMP-connected code stays in one 16K segment; JSR across segments goes through `k_farcall`. |
| Kernel | `src/kernel_p0.asm`, `src/kernel_p2.asm` | Lives in C64 pages that only held 6502 code. IM2 interrupt entry, memory helpers, VIC/SID/CIA register emulation, raster timing from the turbo R system timer, far calls, indirect-jump dispatch (hash table), SID→PSG with software ADSR, joystick/keyboard. |
| Renderer | `src/render.asm` | Own mapper segment, runs at V9990 vblank. Draws dirty C64 cells (text, multicolour, bitmap) into V9990 B3 (512×212, 4bpp) at 3 pixels per C64 multicolour pixel, so the full 40-column screen fits with the right aspect ratio. Sprites are cached as shapes in VRAM and blitted, and the display is double buffered. |
| Loader | `src/loader.asm` | ROM bank 0: switches to R800, copies the images into mapper segments, takes over all four pages. |

Memory while the game runs: page 0 = C64 $0000-$3FFF, page 1 = translated
code (banked), page 2 = C64 $8000-$BFFF, page 3 = C64 $C000-$FFFF. The VIC
bank ($4000-$7FFF) is a separate segment reached through `k_vrd`/`k_vwr`,
which also keep the renderer's dirty bitmap (1 bit per 8 bytes).

Raster interrupts: a C64 raster line *c* becomes V9990 line interrupt *c−45*.
The translated handler runs from that interrupt, so writes to `$D020-$D023`
change V9990 palette entries at the right line (the road stripes). Any other
VIC register change is recorded in a per-frame timeline, and the renderer
uses it to pick the mode, colours and sprite set for each character row.
Handlers whose line was armed too late are run right away, or at the latest
at vblank, so the game keeps its 50 Hz rhythm.

## Known limitations

- The 4bpp palette has 12 free entries, so brown, light red, dark grey and
  light green are shown as orange, red, grey and green.
- Hires pixels are 1.5 V9990 pixels wide (two become `a, a|b, b`).
- Sprite-sprite collisions use shrunken bounding boxes, not pixels.
  Sprite-background priority and collisions are not emulated.
- SID sound is approximated on the PSG (square/noise, software envelope, no
  filter).

## Tests

`test/run.sh <seconds> <out-prefix> [tcl]` boots the ROM headless in openMSX,
optionally runs extra Tcl (key presses, breakpoints), samples the PC every
0.5 ms and prints a profile (`tools/symmap.py`, `tools/profgroup.py`).
`test/mkdrive.sh <dir>` writes a Tcl script that drives the buggy and
measures the game's frame rate.
