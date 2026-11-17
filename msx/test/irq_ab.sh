#!/bin/sh
# Compare native race handlers with translated handlers from identical RAM.
# The replay stops at the first race-to-menu transfer; its timings include
# both implementations and injected fixtures and are not an FPS benchmark.
set -eu
cd "$(dirname "$0")/.."
OUT=${1:-/tmp/bb_irq_ab}
# Restore normal defaults only after success; failures select the old path.
restore_reference() {
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
trap restore_reference 0
IRQ_NATIVE=ab IRQ_SNAPSHOT=1 python3 tools/build.py
python3 test/irq_ab.py "${OUT}_checks.tcl"
IRQ_AB_SCRIPT="${OUT}_checks.tcl" sh test/first_race.sh "$OUT" 240
