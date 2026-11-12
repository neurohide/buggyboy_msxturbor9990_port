#!/bin/sh
# usage: test/road_ab.sh [log]
# Builds with ROAD_NATIVE=ab (native road drawer at NR_ab next to the
# original translated drawer) and, at every drawer call during a scripted
# race where native's flag assumptions hold, runs native, restores memory
# and registers, runs the translated drawer,
# and compares the drawer's outputs (edge tables, its zero page, bitmap,
# bitmap dirty flags).  The dirty flags differ even translated vs translated
# (harness artifact); bitmap, tables and zero page must match exactly.
# AB_REPLAY=test/replays/ref.tcl: drive with a recorded play instead.
# Rebuild normally afterwards (python3 tools/build.py).
HERE=$(cd "$(dirname "$0")/.." && pwd)
LOG=${1:-${TMPDIR:-/tmp}/road_ab.log}
cd "$HERE" && ROAD_NATIVE=ab python3 tools/build.py | tail -1 || exit 1
a=$(grep -i "^NR_ab:" build/main.lbl | sed 's/.*\$//')
t=$(grep "^T_289C:" build/main.lbl | sed 's/.*\$//')
g=$(grep "^NR_gc:" build/main.lbl | sed 's/.*\$//')
s=$(awk '/code segment/{s=$8} $1=="T_289C:"{print s; exit}' build/code.asm | tr -d ')')
sed -e "s/NRAB/0x$a/; s/T1289C/0x$t/g; s/NRGC/0x$g/; s/== SEG}/== $s}/" test/road_ab.tcl > "$LOG.tcl"
AB_LOG=$LOG "${OPENMSX:-openmsx}" -machine Panasonic_FS-A1GT -ext gfx9000 \
  -cart build/buggyboy.rom -romtype ASCII16 -script "$LOG.tcl" > "$LOG.out" 2>&1
tail -1 "$LOG"
grep -v '^frames\|^done\|^timeout\| dirty ' "$LOG" | head -20
