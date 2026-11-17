# Physical MSX verification gate

Status, 2026-11-17: **not measured on physical hardware**. No connected MSX,
GFX9000 capture interface or logic analyzer was available during this session.
An openMSX timestamp measures the emulator's model; it cannot establish real
V9990 command completion, cartridge wait states, interrupt latency or analog
sound quality. Native-handler differential replay also runs both implementations
and must never supply a hardware FPS result.

## Reproducible handoff

1. Record machine model, CPU mode/clock, PAL/NTSC setting, RAM mapper, cartridge
   interface, GFX9000/V9990 revision, video output and audio output connection.
   Use the MSX2+ build on an MSX2+; rebuild for the target before collecting data.
2. Record the ROM SHA-256, build/config.inc and build/main.lbl. The production
   build is `python3 tools/build.py` from msx/. Rollback is
   `IRQ_NATIVE=0 IRQ_SNAPSHOT=0 python3 tools/build.py`. Keep separate ROM/label
   copies for each build. Do not time the `IRQ_NATIVE=ab` comparison ROM.
3. Select OFFROAD, NORTH, EAST, WEST and SOUTH through the menu. Hold acceleration,
   steer left until car position changes, then right until car position changes.
   Press and release STOP; verify a stationary game. Wait at least two seconds,
   press and release STOP, then confirm acceleration and course progress resume.
   Include an obstacle impact and subsequent recovery. Record inputs and video
   continuously; menu/race state changes must remain visible.
4. Record line-level audio throughout. Listen for engine pitch changes, effects,
   pause and resume, missing channels, clicks, stuck tones and distortion. Compare
   the rollback and native builds at the same gameplay events. Do not infer
   subjective quality from PCM amplitude or SID/PSG register values.

## Timing capture without changing the production ROM

Use a logic analyzer connected through an appropriate MSX cartridge breakout.
Record the CPU clock, address/data bus, /M1, /IORQ, /RD, /WR and /INT, together with
video frame synchronization. Establish electrical compatibility and signal names
from the particular machine and cartridge documentation before connecting probes.
Capture enough consecutive execution to identify 240 race-loop intervals.

Decode bank writes as well as memory fetches. Resolve `T_8003`, `render_frame`,
`k_int`, `read_input`, `sound_frame`, command routines and their returns against
that build's labels. Page-one address matches alone are ambiguous. Track nested
interrupts and renderer calls so renderer CPU time and IRQ service time do not
include each other twice. Include a separate interrupt assertion-to-service
latency measurement. Retain the raw analyzer capture and decoder configuration.

The checked source defines command data at port $62, register data at $63 and
interrupt flags at $66 (`src/defs.inc`). Decode the complete register-select and
command transactions, including streamed paths. Count command types and capture
command-completion waits from actual bus activity. Do not count one arbitrary
port write as one command. Snapshot payload and local timeline copies are memory
transfers; decode their loop boundaries and transferred bytes separately.

Report passes 1–240, 121–160 and 121–240, with median/p95/worst game-pass, render
and page-flip latency; changed cells; command types/counts; timeline transfers;
IRQ service and context time; and speed-dependent world-step progress. Use the
same percentile convention as test/race_metrics.py. Preserve raw captures for
both builds. Require useful progress and successful controls/collision recovery
before interpreting a faster result as an improvement. Compare each course to
itself, with matching input and machine configuration. Repeat captures to expose
run-to-run variability; no hardware acceptance decision exists until these
measurements and listening results are attached.
