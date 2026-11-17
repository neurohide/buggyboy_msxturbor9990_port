# Live IRQ verification, 2026-11-17

Run from `msx`: `sh test/irq_live.sh /tmp/bb_irq_verified`.

`verification.json` records five courses, 20,000 matched native/translated
handler invocations, 31,294 sparse snapshot checks, keyboard steering and STOP
pause/resume events, audio dispatch intervals and PCM measurements. Differential
timing includes both implementations and must not be used as FPS evidence.

Production ROM SHA-256:
`d901216ba89698e4186a4062916493c115c3c1e6a5b3d616fb0bbdf48f2ec318`.
Differential ROM SHA-256:
`874b4bf8b18da6dd83c6f2aa69579c906fc4ee84345946e4eda6f98501ad644b`.

Each course has live-state, cadence, frame/pass and flip traces, metadata,
completion status and emulator assertions. Production runs additionally include
start/end screenshots and short engine, pause and resume WAV clips for listening.
Course numbers: 0 OFFROAD, 1 NORTH, 2 EAST, 3 WEST, 4 SOUTH.

The original complete WAV recordings remain at the `/tmp` paths recorded in
the report and are temporary. Their hashes and PCM measurements are preserved;
only the short clips are retained here. Original output prefixes are preserved
in filenames and metadata. `sha256.json` covers the durable files beside it.

No subjective listening or physical hardware measurement has been performed.
Signal presence, duration, saturation and software dispatch cadence were checked
in openMSX. These checks cannot establish audible quality or hardware timing.
See [the hardware protocol](../../../hardware-verification.md).

The production runs complete 240 race passes on OFFROAD and 160 on each other
course. These are control verification runs with audio capture, not a paired
performance comparison or evidence of a completed race leg. They retain severe
renderer stalls; no playability or 3–4x speedup claim follows from this matrix.
