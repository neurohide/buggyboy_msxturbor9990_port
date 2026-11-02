# Buggy Boy: C64 to MSX turbo R + V9958

An educational study in porting a Commodore 64 game to the MSX. The 6502
code of the C64 version of *Buggy Boy* is not emulated: it is **statically
translated** to Z80/R800 code. A small kernel stands in for the C64
hardware (VIC-II, SID, CIA and raster interrupts).

This branch uses the turbo R's **built-in V9958 in SCREEN 7**
(512 x 212, 16 colors). No V9990 cartridge or video-output switching is
needed. The loader runs the intro on the Z80, then selects **R800 ROM
mode**, leaving all mapper RAM available to the game and renderer.

**Please read the [disclaimer](DISCLAIMER.md) first.** This is a
non-commercial project for learning, not affiliated with or endorsed by
the owners of *Buggy Boy*.

## Requirements and building

- An MSX turbo R with at least 256 KB mapper RAM and 128 KB VRAM.
- Python 3 (standard library only), `make`, and Bas Wijnen's `z80asm`.
- [openMSX](https://openmsx.org/) with Panasonic FS-A1GT system ROMs for tests.

Build the 256 KB ASCII16 MegaROM:

    cd msx
    python3 tools/build.py

The pipeline translates the C64 listing, assembles the kernel and renderer,
checks the kernel's memory boundaries, builds the MSX2 intro, then packs
the images into `build/buggyboy.rom`. The intro occupies ROM bank 15.
Prebuilt game and intro ROMs are included; other build products are
regenerated.

Run without a Gfx9000 extension:

    cd msx
    openmsx -machine Panasonic_FS-A1GT -cart build/buggyboy.rom -romtype ASCII16

Press and release a key or joystick button to leave the intro. The game
stays on the normal MSX video output. Controls: joystick port 1, or cursor
keys and SPACE (fire). STOP pauses; ESC maps to the C64 left-arrow key.

The intro can also be built separately with `make` in `intro/`.

## Repository layout

| Folder | Contents |
|---|---|
| `disasm/` | C64 game and loader disassemblies, plus da65 information files. |
| `tools/` | Reverse-engineering helpers used to produce the disassembly. |
| `msx/src/` | Mapper loader, C64 hardware kernel and SCREEN 7 renderer. |
| `msx/tools/` | Static translator, ROM builder and profiling helpers. |
| `msx/test/` | openMSX state/profiling, driving and renderer regression tests. |
| `intro/` | MSX2 SCREEN 5 intro with wave parallax, sine scroller and PSG music. |
| `docs/screenshots/` | Historical screenshots from the V9990 version, not this renderer. |

## Rendering

C64 pixels are scaled into a 480 x 200 window in SCREEN 7: one C64
multicolor pixel becomes three V9958 pixels. The dirty-cell decoder
supports text, multicolor and bitmap modes.

The sprite-free bitmap is stored in **64 KB of mapper RAM**, not a second
VRAM page. A further 32 KB holds 16 cached sprite shapes. Dirty cells update
that RAM bitmap; changes to sprite position, clipping, colors or shape
damage both the old and new rectangles. Unchanged sprites do not force
uploads.

Damage is tracked in 16-byte horizontal spans on each scanline. Each
damaged span is rebuilt from the clean bitmap and the intersecting sprites
in priority order, then uploaded once. Transparent sprite nibbles preserve
the background, including odd-pixel edges. This avoids slow V9958
pixel-wise transparent copies and the visible gap between erasing and
redrawing a multipart sprite. Uploads use groups of 16 `OUTI` instructions
instead of block-repeat I/O.

There is still one displayed page, not full-frame double buffering.
Scanlines can change while visible, but a sprite is no longer deliberately
erased before its replacement is ready.

### RAM layout

| Mapper segments | Use |
|---|---|
| 0-3 | Clean SCREEN 7 bitmap. Mapped through CPU page 2 to avoid writing the expanded-slot register at `$FFFF`. |
| 4-7 | C64 memory and resident kernel. Segment 5 is the separate VIC bank. |
| 8-11 | Translated code. |
| 12 | Renderer code, timeline, damage tracking and working buffers. |
| 13 | Last-drawn inputs for dirty-cell comparisons. |
| 14-15 | Sprite shape cache. |

The renderer's code is constrained below its local timeline at `$6000`.
Mapper changes update the kernel's mapping shadows so nested VDP interrupts
restore the correct pages.

### Raster effects and timing

The V9958 has no directly readable raster counter. The kernel runs a C64
frame's raster-handler chain in line order, recording VIC changes in a
timeline. The renderer uses that timeline to select the state for each
character row. Writes to `$D020-$D023` become a palette schedule, played
back by V9958 line interrupts for the road stripes.

Sound, input and palette playback run at 50 Hz. Game logic and rendering
run more slowly rather than dropping C64 frames. In the scripted OFFROAD
test, a pre-optimization R800 run measured **6.8 game frames/s**; the
RAM-composited renderer measured **10.6-10.7 game frames/s** over the same
70-80-second measurement window. These are emulator observations, not a
50 Hz or real-hardware performance guarantee; speed depends on the scene.

## Known limitations

- Rendering and game logic remain below the original's 50 Hz.
- Horizontal fine scroll is rounded to whole bytes (two V9958 pixels).
- Four palette slots are reserved for live background/border colors.
  Brown, light red, dark grey and light green are folded into other colors.
  V9958 colors have three bits per component.
- Hires pixels are 1.5 V9958 pixels wide.
- Sprite-sprite collisions use shrunken bounding boxes, not pixels.
  Sprite-background priority and collisions are not emulated.
- SID sound is approximated with PSG square/noise and software envelopes.
- This loader targets the turbo R; running on a stock Z80-only MSX2+ is
  not supported by this branch.

## Tests

From `msx/`, capture state, a screenshot and a PC-sampling profile:

    test/run.sh 16 /tmp/bb 'after time 7 { keymatrixdown 8 0x01 }; after time 7.3 { keymatrixup 8 0x01 }'

Run the scripted OFFROAD benchmark:

    test/mkdrive.sh /tmp/bb-drive
    SAMPLE_FROM=70 test/run.sh 82 /tmp/bb-drive/run 'source /tmp/bb-drive/drive.tcl'

The driving script leaves the intro, selects a course, accelerates, saves
screenshots and measures C64 frame IRQ `$11C5` between 70 and 80 seconds.
The output includes the active CPU and VDP registers. `OPENMSX` can
override the emulator executable.

Run isolated assembly regressions from the repository root:

    openmsx -machine Panasonic_FS-A1GT -cart msx/build/buggyboy.rom -romtype ASCII16 -script msx/test/render.tcl

This checks R800/SCREEN 7 selection, damage masks, clean-bitmap mapper
boundaries, sprite transparency/alignment/cache addressing and VRAM uploads.
It exits with a nonzero status on failure.

The translator's reference VIC renderer is `msx/tools/vicrender.py`.
`msx/tools/vram2png.py` is a historical V9990 dump utility and does not
decode this branch's SCREEN 7 VRAM.
