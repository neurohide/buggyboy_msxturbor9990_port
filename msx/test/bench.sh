#!/bin/sh
# usage: test/bench.sh <outprefix>
# Repeatable speed benchmark. Sets the kernel's bench_pace, so a frame only
# runs after a complete main loop pass (never on a timeout), and presses the
# keys at fixed frame numbers: every build then computes exactly the same
# frames. Prints the time per frame spent in each context over race frames
# 1450-1600 (driving), and writes <outprefix>.samples for tools/profgroup.py.
# openMSX is taken from PATH, or from $OPENMSX.
OUT=${1:-${TMPDIR:-/tmp}/bench}
HERE=$(cd "$(dirname "$0")/.." && pwd)
L() { grep "^$1:" "$HERE/build/main.lbl" | sed 's/.*\$//'; }
FC=$(L k_farcall); FE=$(L k_jmpind); IV=$(L in_vbl); RD=$(L rendering); RF=$(L run_frame)
BP=$(L bench_pace); SEG=$(L cur_p1)
cat > "$OUT.tcl" <<TCL
set throttle off
after time 10 { keymatrixdown 8 0x01 }
after time 10.3 { keymatrixup 8 0x01 }
after time 11 { debug write memory 0x$BP 1 }
set ::rf 0; set ::c [dict create]; set ::on 0; set ::samp [open $OUT.samples w]
proc frame {} {
  incr ::rf
  switch \$::rf {
    638 { keymatrixdown 8 0x01 } 645 { keymatrixup 8 0x01 }
    781 { keymatrixdown 8 0x01 } 788 { keymatrixup 8 0x01 }
    999 { keymatrixdown 8 0x21 }
    1450 { set ::on 1; set ::t0 [machine_info time]; smp }
    1600 { set ::on 0; report }
  }
}
debug set_bp 0x$RF {} { frame }
proc smp {} {
  if {!\$::on} return
  set pc [reg pc]
  if {[debug read memory 0x$RD]} { set k render } elseif {[debug read memory 0x$IV]} { set k run_frame } elseif {\$pc >= 0x$FC && \$pc < 0x$FE} { set k idle } else { set k main }
  dict incr ::c \$k
  puts \$::samp "[format %X [debug read memory 0x$SEG]] [format %X \$pc]"
  after time 0.0002 smp
}
proc report {} {
  set el [expr {[machine_info time] - \$::t0}]
  close \$::samp
  set f [open $OUT.txt w]
  foreach k {render main run_frame idle} { set v 0; catch { set v [dict get \$::c \$k] }; puts -nonewline \$f [format "%s=%.2fms " \$k [expr {\$v*0.2/150}]] }
  puts \$f [format "total=%.2fms" [expr {\$el*1000/150}]]
  close \$f; screenshot $OUT.png; exit
}
TCL
"${OPENMSX:-openmsx}" -machine Panasonic_FS-A1GT -ext gfx9000 \
  -cart "$HERE/build/buggyboy.rom" -romtype ASCII16 -script "$OUT.tcl" > "$OUT.log" 2>&1
cat "$OUT.txt"
