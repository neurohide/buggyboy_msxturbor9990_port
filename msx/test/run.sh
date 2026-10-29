#!/bin/sh
# usage: test/run.sh <seconds> <outprefix> [extra tcl]
# Boots the ROM on a Sony HB-F1XDJ (MSX2+, Z80 3.58 MHz) with a 512K mapper
# and dumps state.
SECS=${1:-10}
OUT=${2:-/tmp/bb}
EXTRA=${3:-}
HERE=$(cd "$(dirname "$0")/.." && pwd)
cat > "$OUT.tcl" <<TCL
set throttle off
set renderer SDLGL-PP
$EXTRA
proc dumpstate {} {
  set f [open "$OUT.txt" w]
  puts \$f "pc=[format %04X [reg pc]] sp=[format %04X [reg sp]]"
  foreach {name addr n} {kvars 0x2F60 0x60 vicregs 0x2F00 0x30} {
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
/Applications/openMSX.app/Contents/MacOS/openmsx -machine Sony_HB-F1XDJ -ext ram512k \
  -cart "$HERE/build/buggyboy.rom" -romtype ASCII16 -script "$OUT.tcl" > "$OUT.log" 2>&1
cat "$OUT.txt"
python3 "$HERE/tools/symmap.py" "$OUT.samples" | head -${TOP:-25}
