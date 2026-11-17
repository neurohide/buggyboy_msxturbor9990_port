#!/bin/sh
# Full course matrix. Differential timings include both handlers and are not FPS.
# IRQ_LIVE_COURSES='0 2 4' restricts coverage explicitly; default checks all five.
set -eu
cd "$(dirname "$0")/.."
OUT=${1:-/tmp/bb_irq_live}
restore() {
 result=$?
 trap - 0
 if [ "$result" -eq 0 ]; then
  unset IRQ_NATIVE IRQ_SNAPSHOT
  python3 tools/build.py || exit 1
 else
  IRQ_NATIVE=0 IRQ_SNAPSHOT=0 python3 tools/build.py || exit 1
 fi
 exit "$result"
}
trap restore 0
IRQ_NATIVE=ab IRQ_SNAPSHOT=1 python3 tools/build.py
python3 test/irq_ab.py "${OUT}_ab.tcl"
python3 test/irq_live.py "${OUT}_live.tcl"
printf '\nsource {%s}\n' "${OUT}_live.tcl" >> "${OUT}_ab.tcl"
for course in ${IRQ_LIVE_COURSES:-0 1 2 3 4}; do
 prefix="${OUT}_ab_c${course}"
 RACE_COURSE=$course IRQ_AB_SYNTHETIC=0 IRQ_DIFFERENTIAL=1 IRQ_LIVE_HANDLER_LIMIT=1000 IRQ_LIVE_OUT=$prefix \
  IRQ_AB_SCRIPT="${OUT}_ab.tcl" sh test/first_race.sh "$prefix" 240
 done
unset IRQ_NATIVE IRQ_SNAPSHOT
python3 tools/build.py
python3 test/irq_live.py "${OUT}_live.tcl"
for course in ${IRQ_LIVE_COURSES:-0 1 2 3 4}; do
 prefix="${OUT}_native_c${course}"
 passes=160
 if [ "$course" = 0 ]; then passes=240; fi
 RACE_COURSE=$course IRQ_LIVE_OUT=$prefix IRQ_LIVE_AUDIO=1 \
  IRQ_AB_SCRIPT="${OUT}_live.tcl" sh test/first_race.sh "$prefix" "$passes"
 done
python3 test/irq_live_report.py "$OUT" ${IRQ_LIVE_COURSES:-0 1 2 3 4}
