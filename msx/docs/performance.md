# First-race performance

Run from `msx/` with `sh test/first_race.sh /tmp/bb_first 240`.
Use `PROFILE=1` to collect CPU samples, then
`python3 tools/profgroup.py /tmp/bb_first_pc.samples`.

The harness boots the current ROM on an MSX2+ FS-A1WSX with a 1 MB mapper
and GFX9000. It pulses fire until the race loop begins, accepting the default
OFFROAD course. It then holds acceleration for the requested game passes.
Use at least 240 passes: 120 covers the initial straight and misses large
later stalls. This is a course segment benchmark, not a completed leg.
Elapsed time starts at the first race-loop entry, excluding menus.
Outputs include elapsed time, displayed page flips, game-pass timestamps,
page-flip timestamps, median/p95/worst flip intervals, and start/end screenshots.
Timeout is a failure. No steering is applied. A JSON sidecar records the ROM
SHA-256, build configuration, input policy, pass count, and profiling/validation
settings. Results also report separate 120-pass windows.

`VALIDATE_SPRITES=1` additionally exercises every cache slot, restoring the
real cache afterward, and checks every native $1452 call against its input
tables, dirty flags, VIC state, and documented Z80 return registers. Validation
also checks actual sprite uploads in all four expansion modes, deterministic
cache replacement, dirty copy/clear snapshots, all 256 hires mask entries, and
actual CMMC cell pixels against an independent software expansion. Validation
changes boot timing; use runs without validation for performance comparisons.

## November 17, 2026

| Build | Elapsed seconds | Displayed FPS | Game passes/s |
| --- | ---: | ---: | ---: |
| Baseline, two identical runs | 40.9284 | 3.1763 | 2.9319 |
| Direct IFF2 check in V9990 command setup, two identical runs | 27.6152 | 4.4541 | 4.3454 |
| IFF2 check plus direct DE sprite-buffer writes | 27.2107 | 4.5203 | 4.4100 |
| Linear native sprite tables, palette optimization, corrected cache; two identical runs | 25.2258 | 4.7967 | 4.7570 |

That checkpoint improves displayed FPS by 51.0% against the recorded baseline,
and 6.1% against the previous 4.5203 FPS build. It is still below a playable
framerate. The first-race run has median/p95/worst page-flip intervals of
199.37 / 282.64 / 558.33 ms. Raster IRQ timing amplifies small CPU changes;
these gains are not equivalent reductions in instruction count.

## Retained changes

- Native $1452 now walks the X/Y/pointer/colour tables linearly, collects VIC
  changes, and marks the fixed eight-byte pointer group once. It preserves
  IX/IY and its documented translated-register ABI.
- V9990 live-palette updates keep IFF2 directly in P/V and calculate RGB lookup
  addresses without saving/clobbering DE. Both palette banks remain coherent.
- Sprite invalidation previously truncated `slot * 8` to eight bits. Slots
  32–127 consequently addressed records 0–31. Invalidation now uses the full
  address helper. Its $800-aligned base is folded into HL before multiplication,
  saving instructions in every cache lookup; the build enforces that alignment.
- Validation checked all 128 cache slots and 786 native sprite-update calls
  during a complete 120-pass run. That checkpoint screenshot reaches 165 KPH in leg 1.
  Scores and exact scenery positions can differ with IRQ timing; this benchmark
  does not establish frame-by-frame game-state equivalence or validate steering.

## Extended benchmark before native raster replacement

| 240-pass build | Seconds | Displayed FPS | Game passes/s |
| --- | ---: | ---: | ---: |
| Before scheduler correction | 94.1447 | 3.0485 | 2.5493 |
| Scheduler correction; two identical runs | 63.2581 | 3.8098 | 3.7940 |
| Scheduler plus hires CMMC, unrolled streamer; two identical runs | 63.5055 | 3.7949 | 3.7792 |

That checkpoint's 240-pass run improves game throughput by 48.2% and displayed FPS
by 24.5% against the extended run before the scheduler correction. Its first
120 passes take 23.7994 seconds at 5.0421 displayed FPS, compared with the
original short baseline's 3.1763 FPS (+58.7%). Passes 121–240 run at 3.0222
game passes/s. Report both windows; the initial straight overstates performance.

Median/p95/worst page-flip intervals over 240 passes are
159.60 / 956.96 / 1395.56 ms. Hires CMMC improves median flip time compared
with the scheduler-only build's 179.49 ms, but its whole-window throughput is
slightly lower and its worst stall is longer. Do not describe the mask transfer
reduction as an equivalent whole-game FPS gain. IRQ timing changes game state,
collisions, and scene timing; these runs are not identical scene workloads.

The final 240-pass validation checked all 128 sprite-cache slots, 2,313 CMMC
cells (1,171 hires and 1,142 multicolour), 184 sprite uploads across all four
expansion modes, 2,162 cache decisions, 432 dirty snapshots, and 1,740 native
sprite-register calls. It also checked all 256 hires mask entries. This proves
the checked pixel/state transformations, not full game or steering equivalence.
The build leaves 200 bytes before the renderer's first runtime table.

Additional retained changes:

- Race scheduling waits for the next completed game pass while the existing
  watchdog is active. It previously invoked extra rendering after 12 eligible
  vblanks, allowing a slow pass to trigger more rendering and further delay
  game progress. The watchdog still restores menu rendering if the loop stops.
- On MSX2+, ordinary C64 raster compares only update the software schedule;
  they no longer program redundant hardware line registers. The native kerb
  band chain still programs the V9990 line interrupt.
- The two-way sprite cache uses invalid entries first, then evicts the least
  recently used way. It no longer uses the Z80 refresh register as a victim
  selector. Existing five-byte keys and all 128 slots remain supported.
- Five dirty-chunk calculations are inlined after checking that each caller
  discards or restores HL. Dirty snapshots copy and clear each source byte
  together with page-contained increments and an eight-byte unrolled loop.
- Hires cells use the V9990 CMMC foreground/background engine. A 12×8 cell
  transfers 12 mask bytes instead of 48 expanded pixel bytes and skips the
  colour-specific nibble-table build. Four lookup pages in shadow RAM preserve
  the original OR interpolation exactly. Pair streaming is unrolled; the build
  checks table placement and the remaining renderer code space.

Rejected experiments: a content-addressed road-cell VRAM cache had only 31 hits
against 32 misses in the short run; its overhead reduced throughput. Alternative
sprite byte streamers improved average time in some runs but worsened p95 flip
latency. They are not included. The longer run also exposed an end-state timeout
at 311 passes; do not treat page flips after that state as useful racing FPS.

Artifacts for that checkpoint: `/tmp/bb_first_hires_unroll_*`, repeat
`/tmp/bb_first_final240_repeat_*`, and validation
`/tmp/bb_first_final240_validate_*`. Temporary artifacts are local to this machine.

## Native raster-handler replacement

`IRQ_NATIVE=1 IRQ_SNAPSHOT=1 python3 tools/build.py` selects native Z80 race
handlers at $10E3, $11C5, $134C and $141A and sparse timeline capture. Both
options now default to `1`. Build with `IRQ_NATIVE=0 IRQ_SNAPSHOT=0` to restore
the previous configuration.
`IRQ_NATIVE=ab` places the candidates beside the translated reference handlers.
These switches are independent, allowing sparse capture and handler changes to
be measured separately.

The handlers use direct counter/vector/CIA state updates, linear sprite-table
walks, and overlapping block copies for the three horizon rows. Dirty bits match
the translated writes exactly, including the original wrap-byte order. Groups
already marked dirty bypass character comparisons. The horizon scan uses AF'
for its wrap source; the outer ISR still saves and restores both register banks.
Game/audio callbacks and pause, input, race-exit and sprite-multiplexing branches
remain in their original order. Vblank input polling, audio dispatch, the game
IRQ divider and hardware kerb-band chain are unchanged.

Sparse capture writes 37 VIC bytes and eight sprite pointers instead of 48 VIC
bytes and eight pointers: 45 versus 56 payload bytes, a 19.6% reduction. It keeps
the 64-byte record layout and all offsets used by rows and sprites. It omits
raster/light-pen, IRQ, priority, collision, border and unused colour fields.
Unused fields retain their previous contents. This reduces captured payload;
it does not reduce the record stride or the renderer's subsequent record copy.
Build guards enforce the page alignment required by the short pointer increments.
The sparse build leaves 11 bytes in the fixed kernel region and 175 bytes
before the renderer's first runtime table.

Renderer validation also exposed a live-source race: the IRQ game callback can
rewrite sprite bitmap bytes halfway through an upload. The native configuration
now snapshots exactly 63 source bytes on each sprite cache miss into unused
sprite-workspace bytes. A short LDIR runs with interrupts disabled and restores
the previous interrupt state; row conversion and upload then use that stable
copy. It does not copy every sprite at every raster event. Validation compares
the captured bytes with live memory at the end of the atomic copy, then checks
every uploaded pixel against the captured source in all expansion modes.

Run `sh test/irq_ab.sh /tmp/bb_irq_check` from `msx/`. The script builds the
comparison ROM, generates breakpoints from its labels, and runs the default
first race. It restores the normal build defaults after success and selects
`IRQ_NATIVE=0 IRQ_SNAPSHOT=0` after failure. Each intercepted handler runs
native first, then translated from the same saved RAM and registers. Comparison
covers all 128 KiB containing game/VIC memory, kernel state and translated code,
including counters, input shadows, dirty maps, SID state and mapper state. Only
dead bytes in the reserved Z80 stack, eight helper scratch bytes, and address
lookup caches are excluded. A, BC, DE and SP, ordered game/audio callback traces,
and return versus race-exit transfers must match. Scratch registers and flags
restored by the outer ISR are not handler outputs.

The replay injects 155 cases covering pause/resume keys, counter overflow, stale
band state, sprite zones and pointers, signed horizon steps, phase/speed edges,
and uniform, grouped and alternating characters with clear, mixed and full dirty
maps.
Every sparse capture is checked against the renderer's required fields and
sprite pointers; every omitted byte must remain untouched. The replay ends
after comparing the first race-to-menu transfer. Its elapsed time includes both
implementations and fixtures and must not be reported as racing FPS. It proves
the checked state transformations and callback order on the FS-A1WSX setup;
it does not validate steering, audible output, all courses or every hardware
register side effect.

Without the atomic sprite-source capture, the focused candidate passed handler
state comparison but failed sprite upload validation and reached only 3.2779 FPS
over 240 passes. It was not enabled. The final source-snapshot configuration
passes sprite upload validation and is measured separately below.

| 240-pass configuration, validation hooks off | Seconds | Displayed FPS | Game passes/s |
| --- | ---: | ---: | ---: |
| Retained previous default, repeated baseline | 63.5055 | 3.7949 | 3.7792 |
| Native raster handlers, sparse capture, atomic sprite source; two identical runs | 59.6521 | 4.0401 | 4.0233 |

The final configuration improves displayed FPS and game throughput by
6.5%. Its first and second 120-pass windows take 22.842 and 36.810 seconds.
Median/p95/worst page-flip intervals are 159.50 / 956.96 / 1315.82 ms.
Default enablement followed the state comparison, renderer validation and
identical repeat benchmark.

The final differential replay checked 14,380 handler invocations, 155 injected
cases and 16,141 snapshots. Aggregate handler time was 41.3330 seconds native
versus 43.6764 seconds translated (5.4% lower). Separate 240-pass renderer
validation checked 128 cache slots, 178 atomic source snapshots and sprite
uploads across all four expansion modes, 2,134 cache decisions, 426 dirty
snapshots, 2,299 CMMC cells and 1,614 native sprite-register calls. Timing with
validation hooks is excluded from the performance comparison.

Artifacts: `/tmp/bb_irq_default_acceptance_*`, `/tmp/bb_irq_snapshot240_*`,
`/tmp/bb_irq_snapshot_repeat240_*` and `/tmp/bb_irq_snapshot_validate240_*`.
The benchmark ROM SHA-256 is
`d901216ba89698e4186a4062916493c115c3c1e6a5b3d616fb0bbdf48f2ec318`.
An injected emulator-launch failure also checked the script's failure path:
it returned failure and rebuilt the byte-identical previous baseline ROM.

Native constant-time horizon phase arithmetic was also checked, then discarded:
its 240-pass run reached 3.5970 FPS versus the retained build's 3.7949 FPS.
Faster individual handlers do not establish a whole-game speedup: changed IRQ
timing changes collisions and scene workloads. Compare the full long window.

## Pass instrumentation and scenario captures (November 17, 2026)

`test/race_metrics.tcl` adds host-side breakpoints to the existing first-race
harness. The ROM is unchanged. Enable it with `RACE_METRICS=1`; use
`RACE_SCENARIO=straight`, `steering`, or `collision` (default: straight).

```sh
RACE_METRICS=1 sh msx/test/first_race.sh /tmp/baseline_straight 240
RACE_METRICS=1 RACE_SCENARIO=steering sh msx/test/first_race.sh /tmp/baseline_steering 240
RACE_METRICS=1 RACE_SCENARIO=collision sh msx/test/first_race.sh /tmp/baseline_collision 240
```

Each `_passes.csv` row covers one complete `T_8003` entry-to-entry interval,
numbered identically to `_frames.csv`. It records renderer duration, renderer
time excluding interrupt preemption, complete MSX IRQ entry-to-resumption time,
redrawn cells, command types, copy area, timeline payload/record copies, and game
state. `_renders.csv` records individual render calls; `_events.csv` records
inputs, verified object contacts, impact animation and recovery.

Timing accounts for nested interrupts. `irq_s` excludes rendering performed
inside a vblank ISR; `render_cpu_s` excludes interrupt preemption. These two
columns do not overlap. `render_s` includes preemption and must **not** be added
to `irq_s`. `irq_context_s` also includes rendering inside an ISR. IRQ timing
starts at `k_int`, includes the fast kerb path and RETI, and excludes hardware
interrupt acknowledgement before the entry instruction. Renderer time includes
VDP waits. This measures emulated time, not host breakpoint overhead.

`cells` counts actual visits to `dr_cell`: dirty cells selected for conversion,
including forced redraws, rather than a count of distinct changed source bytes.
Blank-row fills are commands, not converted cells. Commands are counted once
at `v_send_cmd`, `dr_next`, or `dt_op`, including abbreviated LMMC/CMMC paths;
the type columns cover LMMC ($10), LMMV ($20), LMMM ($40), and CMMC ($50).
Counts describe issued drawing work; they do not establish pixel equivalence.
Timeline captures count 45 payload bytes per sparse snapshot (56 in fallback);
renderer timeline copies count 64 bytes per base/event record. Header writes
are excluded from capture payload bytes.

Durable results: `docs/benchmarks/2026-11-17/summary.json`, all 240 pass rows,
render/flip logs, event traces, and steering/impact/recovery screenshots.
The ROM hash remains `d901216ba89698e4186a4062916493c115c3c1e6a5b3d616fb0bbdf48f2ec318`.
The instrumented straight run reproduces every pass timestamp and flip count
from the earlier uninstrumented run. All three scenarios also reproduce their
earlier measurement runs exactly. A further straight repeat passed the gate.

### Long-window results

Latencies below use nearest-rank p95 throughout the new reporter. Earlier
reports used a floor-index percentile; steering flip p95 therefore differs
slightly despite identical timings.

| 240-pass scenario | Seconds | Passes/s | Pass median/p95/worst (ms) | Flip median/p95/worst (ms) | World steps |
| --- | ---: | ---: | --- | --- | ---: |
| Straight | 59.652 | 4.023 | 166.66 / 915.08 / 1348.39 | 159.50 / 956.96 / 1315.82 | 725 |
| Steering | 70.977 | 3.381 | 185.89 / 1000.68 / 1320.24 | 161.70 / 1076.57 / 1355.69 | 734 |
| Collision | 75.312 | 3.187 | 183.64 / 1004.84 / 1315.42 | 160.99 / 996.83 / 1315.82 | 700 |

Useful progress is the speed-dependent counter at `$006A:$006B`, updated by
`$1139..$1156`, not metres or completed legs. Whole-window progress rates are
12.154, 10.341 and 9.295 world steps/s respectively. These remain partial first
course runs; different inputs produce different scene and collision workloads.

### Straight passes 121–160

This 40-pass window takes **15.236 s** (2.625 passes/s), with pass latency
**190.47 / 1040.43 / 1348.39 ms** median/p95/worst.

| Measurement | Window total |
| --- | ---: |
| Render calls | 41 |
| Renderer elapsed time, including IRQs | 11.255 s |
| Renderer time excluding IRQ preemption | 4.697 s |
| IRQ service time excluding rendering inside the ISR | 8.878 s |
| Hardware IRQ entries | 4,644 |
| Converted dirty cells | 1,504 |
| Commands | 1,982 |
| LMMC / LMMV / LMMM / CMMC | 343 / 395 / 753 / 491 |
| LMMM copy area | 1,085,716 pixels |
| Timeline captures / payload bytes | 1,528 / 68,760 |
| Local timeline records / bytes | 164 / 10,496 |

Pass 160 alone takes 1.348 s: 183 converted cells, 188 commands, 136 captures,
0.347 s renderer time excluding IRQs, and 0.841 s IRQ service time. Across this
window, IRQ service occupies 58.3% and renderer time excluding IRQs 30.8%.
The next optimization needs to address both costs. More captures during a slow
pass are also a consequence of the fixed interrupt cadence; counts alone do
not establish the cause of a stall.

### Input and contact evidence

Steering replay holds left on passes 20–29 and 70–79, right on 30–49 and
80–99, with acceleration throughout. Left changes the steering state and car
position by pass 21. Right produces both changes by pass 94. The first contact
is at pass 29; impact handling prevents a prompt response during the first
right interval. This is a responsiveness limitation, not evidence of smooth
interactive control. Screenshots capture left and right positions.

Collision replay holds right on passes 20–99. The translated collision branch
`T_1925` confirms contact at pass 40 (object slot 6, velocity 24), followed by
`T_980C` impact handling. Speed falls from 165 to 49, then reaches zero at pass
51; impact state clears and acceleration resumes at pass 68. Later rows
confirm renewed world progress. Further contacts occur at passes 146, 180,
and 205. The initial probe watched only the separate `$02C8` crash state and
missed these object impacts; that probe was rejected as collision evidence.

Screenshots reflect the displayed page and can lag the state trace, including
HUD speed. Acceptance uses verified contact branches, impact state, resumed
velocity and renewed progress together. Audio quality, full-course control,
real hardware timing and playability remain unverified.

### Gate for subsequent changes

Run all three 240-pass scenarios for both baseline and candidate. For each pair:

```sh
python3 msx/test/race_metrics.py /tmp/candidate_straight /tmp/baseline_straight
python3 msx/test/race_metrics.py /tmp/candidate_steering /tmp/baseline_steering
python3 msx/test/race_metrics.py /tmp/candidate_collision /tmp/baseline_collision
```

The command exits nonzero on rejection. It requires complete long windows,
matching configuration/input policy, useful progress, both steering responses
for the steering replay, and observed impact followed by recovery for the
collision replay. It rejects regression in whole/late-window throughput,
median/p95/worst pass, render or flip latency, or useful world steps/s.
No tolerance is applied to these deterministic emulator runs. Pixel/state
equivalence checks remain separately required before enabling renderer changes.
The unchanged straight repeat was accepted; seven injected regressions
(incomplete evidence, scenario mismatch, pass worst, flip p95, render median,
late throughput and progress rate) were rejected.

## Remaining work, in order

The earlier CPU samples attribute 38.4% to rendering, 14.3% to game code, 4.8%
to audio, 6.3% to grouped IRQ/input work, and 36.2% to other kernel helpers.
Timeline copying alone consumes 3.0%, palette differences 2.4%, and the fast
kerb ISR 2.6%. The native road drawer is the largest individual game routine.
The extended trace shows that most tunnel-section road calls still satisfy the
native fast-path assumptions; porting only the general fallback will not remove
that stall. Profile fields after segment/PC record `in_irq` and `rendering`.

1. Use the pass measurements above to split IRQ service into audio/input,
   translated callbacks and renderer preemption costs before the next rewrite.
2. Extend native-handler verification to live steering, pause/resume scenarios
   and additional courses. Check audible output and real hardware timing.
3. Add a direct V9990 road path for the existing specialized case. Build spans
   from native edge tables, avoiding bitmap writes followed by a second
   cell/shadow comparison and pixel expansion. Keep the general road path for
   overlays and require matching road pixels and collision inputs.
4. Batch adjacent renderer transfers where conversion and command setup
   dominate. Keep LMMV for uniform spans, CMMC for two-colour cells, and cached
   LMMM copies for sprites. Benchmark a full leg and additional courses.

A 3–4x result and playability have not been achieved. The remaining stalls need
whole rendering/raster stages removed, beyond further leaf instruction tuning.

## Live native-handler verification, 2026-11-17

`sh test/irq_live.sh /tmp/bb_irq_live` builds the differential ROM once, selects
all five courses through keyboard input, and checks native versus translated
handlers during live left/right steering and STOP pause/resume. Set
`IRQ_LIVE_COURSES='0 2 4'` to run an explicit subset (0 OFFROAD, 1 NORTH, 2 EAST,
3 WEST, 4 SOUTH). Synthetic fixtures remain in `irq_ab.sh`; the live matrix sets
`IRQ_AB_SYNTHETIC=0` so fixtures cannot satisfy live coverage. Differential replay
ends after at least 1,000 comparisons per handler and completed live controls,
or the first race exit or requested pass count. Its timing includes both
implementations and is not a performance benchmark.

Each course must show both an input shadow and steering/car-position response,
then actual pause states 1 and 2, thirty paused handler calls with zero velocity
and unchanged world progress, resume state $E0, and renewed velocity/progress.
Input polling and audio synthesis must continue during the paused interval.
Every differential invocation still compares persistent state, ABI outputs,
control transfers and ordered game/audio callbacks. Every sparse capture still
checks required bytes and omitted-field preservation.

The script then rebuilds production defaults and records audio over 240 OFFROAD
passes and 160 passes on each additional course, including the 121–160 window.
A preliminary SOUTH replay reached race exit after pass 225 and failed the
240-pass deadline; it is not a successful 240-pass measurement. Fixed 160-pass
additional-course coverage avoids mixing menu time into race latency. This is
verification coverage, not a claim of a completed leg or better performance.
`irq_live_report.py` gates scenario coverage, sequential
vblank audio counters, dispatch gaps, active PSG voices, nonzero PCM, saturation
and recording duration. Cadence is measured at synthesis entry and can include
IRQ scheduling jitter. It does not measure sound-device latency. Input polling
counts are retained as coverage, not interpreted as a precise sampling rate.
Recording temporarily enables master volume and unmutes audio, restoring both
settings before exit; this avoids silent WAV files caused by a saved zero master
volume. It retains PSG device volume and logs its value.

Full WAV recordings and engine/pause/resume listening clips use the output
prefix. Numerical audio gates establish signal presence and capture integrity;
they do not establish sound quality. Physical timing and listening results must
be reported separately. See [hardware-verification.md](hardware-verification.md)
for the physical capture protocol and outstanding hardware gate.

### Completed matrix

The saved [verification report](benchmarks/2026-11-17/live-irq/verification.json)
contains 20,000 matched handler invocations (1,000 per handler per course) and
31,294 checked sparse snapshots. All five courses passed actual left/right car
movement and STOP pause/resume transitions. Paused world progress stayed fixed
for thirty handler calls, about 1.196 seconds, while input and audio continued.

Production synthesis-entry intervals, in milliseconds:

| Course | Race passes | Snapshot checks in differential run | Median | p95 | Worst |
| --- | ---: | ---: | ---: | ---: | ---: |
| OFFROAD | 240 | 5,948 | 19.937 | 21.193 | 38.169 |
| NORTH | 160 | 6,080 | 19.937 | 21.792 | 38.186 |
| EAST | 160 | 6,293 | 19.937 | 22.829 | 38.179 |
| WEST | 160 | 6,362 | 19.937 | 21.628 | 38.169 |
| SOUTH | 160 | 6,611 | 19.938 | 21.646 | 38.405 |

All production recordings contain nonzero PCM, active PSG voices and zero
saturated samples; duration matches the replay within 50 ms. No sampled audio
frame-counter steps were missing. Engine, pause and resume clips, state traces,
cadence/register traces, screenshots and hashes are retained beside the report.
Listening and physical hardware timing remain pending.

The reporter also rejected ten injected failures: missing pause, reversed right
movement, progress while paused, stopped paused audio, missing audio dispatch,
excessive dispatch gap, silent PCM, saturated PCM, shortened PCM and timeout.

These control replays do not establish a performance improvement. The OFFROAD
run reached 2.981 page flips/s, with game-pass median/p95/worst latency of
187/1,116/2,220 ms; its late 121–240 window reached only 2.168 game passes/s.
Other courses also retain multi-second worst game-pass latency. The audio and
control checks pass while renderer stalls remain. Use the separate paired
performance gate before accepting further optimization.

### Direct road experiment with Up held (2026-11-17)

Evidence: `benchmarks/2026-11-17/direct-road-up/`, including original metadata,
CSV records, emulator logs, screenshots and a SHA-256 manifest. All runs select
course 0 through the menu, hold Up at course confirmation and release steering.
The harness sends one launch fire pulse; it no longer keeps sending jump inputs
until the first measured pass. These runs must not be paired with older input
protocols.

The experimental producer now writes a line-major byte plane from native edge
stores and encodes RLE once per publication. Its mapped store helper uses shadow
BC/DE/HL, saved and restored around the whole native drawer. The consumer merges
identical adjacent scanlines into taller V9990 LMMV rectangles. The general
renderer still handles incompatible bitmap modes and overlapping character
overlays after a canonical checkpoint. `road_busy` prevents IRQ rendering from
consuming partially published spans without stopping the IRQ/audio chain.

The batched differential replay completed 20 measured passes: 20 whole native
drawer transactions and 198 rendered character rows matched the translated
bitmap, collision/state regions and finished V9990 pixels. Cleanup reads and
writes are also checked against the expected logical bitmap. This replay masks
IRQs during paired drawer execution and is not timing evidence or complete
long-window coverage.

| Run | Result | Timing conclusion |
| --- | --- | --- |
| Default | 240 passes in 60.028 s; 4.015 flips/s | Valid paired baseline |
| Unbatched direct | Timeout after 46 passes | Rejected |
| Vertically batched direct | Timeout after 56 passes | Rejected; nested-renderer warnings invalidate FPS/latency instrumentation |

The default baseline's 121–240 throughput is 3.267 passes/s. Its full-window
game-pass median/p95/worst latency is 169/919/1,316 ms. Neither direct run reaches
passes 121–160, so no late-window improvement is established. Timeout tail flips
and useful world-counter increments cannot substitute for completed game passes.
The paired gate rejects the batched candidate; it also reports the intentional
`ROAD_DIRECT` configuration mismatch. The gate now checks input protocol and
control metadata and rejects nested-renderer warnings.

`ROAD_DIRECT=0` remains the default. The restored default ROM SHA-256 is
`d901216ba89698e4186a4062916493c115c3c1e6a5b3d616fb0bbdf48f2ec318`.
Next work must resolve the renderer/return-probe warnings and avoid unconditional
full-road command submission, then repeat the complete paired gate. No speedup,
playability, audible-output or real-hardware timing claim follows from this
experiment.
