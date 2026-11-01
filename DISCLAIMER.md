# Disclaimer

This is an **unofficial fan port** of the Commodore 64 version of
*Buggy Boy*, made to celebrate the original game and to study it
technically. All credit for the game goes to its original authors:

- **Dave Thomas**, programming (C64 version)
- **Bob Thomas**, graphics (C64 version)
- **Elite Systems Ltd**, publisher of the C64 version (1987)
- **Tatsumi**, developer of the original arcade game, and **Taito
  Corporation** (© 1987, as credited on the title screen)

This repository is a **non-commercial, educational project**. Its purpose
is to study and document the techniques involved in moving software
between 8-bit platforms:

- reverse engineering a packed Commodore 64 program,
- static binary translation from 6502 to Z80/R800 machine code,
- replacing C64 hardware (VIC-II, SID, CIA, raster interrupts) with
  MSX hardware (V9990, PSG, the turbo R system timer).

The game is only the test case for this work.

## Ownership

*Buggy Boy* is © 1987 Tatsumi Electronics and Taito Corporation. The
Commodore 64 version is © 1987 Elite Systems Ltd (programming by Dave
Thomas, graphics by Bob Thomas). All trademarks, names, graphics, sound
and game code belong to their respective owners, who keep all rights.

This project is not affiliated with, authorised, sponsored or endorsed by
Tatsumi, Taito, Elite Systems or any other rights holder.

## What the repository contains

- `disasm/` holds disassembly listings derived from the original C64
  program, and the built ROM (`msx/build/buggyboy.rom`) contains the
  original game code (translated) and data. **These remain the work of the
  original authors.** They are included only so that the translation
  process can be studied and reproduced.
- The translator, kernel, renderer, loader, tools and the MSX intro were
  written for this project by neurohide.

## Use

- Do not sell this software or use it for any commercial purpose.
- Do not use this project as a replacement for buying the original game.
  If you want to play *Buggy Boy*, support the rights holders and get it
  through legitimate channels. Use this port only for study, and only if
  you own an original copy of the C64 game.
- If you are a rights holder and want any material removed, open an issue
  on the repository and it will be taken down promptly.

## No warranty

This software is provided "as is", without warranty of any kind. Running
it on real hardware is at your own risk. The authors are not liable for
any damage or loss resulting from its use.
