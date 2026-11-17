#!/bin/sh
# Bitmap, edge-cleanup, collision-input and completed-V9990-pixel differential.
# Timing includes both drawers and the oracle; use first_race.sh separately
# for performance measurements. Always restore the default road backend.
set -eu
cd "$(dirname "$0")/.."
OUT=${1:-/tmp/bb_road_direct}
PASSES=${2:-240}
restore() {
 result=$?
 trap - 0
 ROAD_DIRECT=0 python3 tools/build.py || exit 1
 exit "$result"
}
trap restore 0
ROAD_DIRECT=1 ROAD_NATIVE=1 python3 tools/build.py
python3 test/road_direct.py "${OUT}_checks.tcl"
IRQ_DIFFERENTIAL=1 IRQ_AB_SCRIPT="${OUT}_checks.tcl" \
 sh test/first_race.sh "$OUT" "$PASSES"
