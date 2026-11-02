#!/bin/sh
# usage: test/run.sh <seconds> <outprefix> [extra tcl]
# Boots the SCREEN 7 ROM on a Panasonic FS-A1GT and dumps state.
# openMSX is taken from PATH, or from $OPENMSX.
set -eu
SECS=${1:-10}
OUT=${2:-${TMPDIR:-/tmp}/bb}
EXTRA=${3:-}
HERE=$(cd "$(dirname "$0")/.." && pwd)
cat > "$OUT.tcl" <<TCL
set throttle off
set renderer SDLGL-PP
$EXTRA
proc dumpstate {} {
  set f [open "$OUT.txt" w]
  puts \$f "pc=[format %04X [reg pc]] sp=[format %04X [reg sp]]"
  puts \$f "cpu=[get_active_cpu]"
  set s ""
  for {set i 0} {\$i < 32} {incr i} { append s [format "%02X " [debug read {VDP regs} \$i]] }
  puts \$f "vdp: \$s"
  foreach {name addr n} {kvars 0x2F60 0x90 vicregs 0x2F00 0x30} {
    set s ""
    for {set i 0} {\$i < \$n} {incr i} { append s [format "%02X " [debug read memory [expr {\$addr + \$i}]]] }
    puts \$f "\$name: \$s"
  }
  set sp [reg sp]
  set s ""
  for {set i 0} {\$i < 48} {incr i 2} { append s [format "%04X " [expr {[debug read memory [expr {(\$sp+\$i)&0xFFFF}]] + 256*[debug read memory [expr {(\$sp+\$i+1)&0xFFFF}]]}]] }
  puts \$f "stack: \$s"
  puts \$f "zp60: [format %02X%02X [debug read memory 0x61] [debug read memory 0x60]] fffe: [format %02X [debug read memory 0xFFFE]]"
  close \$f
}
set ::samp [open "$OUT.samples" w]
proc sample {} {
  puts \$::samp "[format %X [debug read memory 0x2F60]] [format %X [reg pc]]"
  after time 0.0005 sample
}
after time ${SAMPLE_FROM:-0} sample
after time $SECS { dumpstate; screenshot $OUT.png; close \$::samp; exit }
TCL
if ! "${OPENMSX:-openmsx}" -machine Panasonic_FS-A1GT \
  -cart "$HERE/build/buggyboy.rom" -romtype ASCII16 -script "$OUT.tcl" > "$OUT.log" 2>&1; then
  cat "$OUT.log" >&2
  exit 1
fi
if [ ! -f "$OUT.txt" ]; then
  cat "$OUT.log" >&2
  exit 1
fi
cat "$OUT.txt"
python3 "$HERE/tools/symmap.py" "$OUT.samples" | head -${TOP:-25}
