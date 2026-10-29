#!/bin/sh
# usage: test/mkdrive.sh <outdir>  -> writes <outdir>/drive.tcl (fire tapped from 20s
# through the menus, up+fire held from 110s, screenshots, and the rate of the C64
# frame IRQ $11C5 between 120s and 135s; the MSX2+ runs the game in slow motion)
S=$1
HERE=$(cd "$(dirname "$0")/.." && pwd)
set -- $(python3 - <<PY
import sys; sys.path.insert(0,'$HERE/tools')
from symmap import load
t=load()
for seg,lst in t.items():
    if isinstance(seg,int):
        for a,n in lst:
            if n=='T_11C5': print(seg, hex(a))
PY
)
SEG=$1; ADDR=$2
cat > $S/drive.tcl <<TCL
proc shot {t name} { after time \$t "screenshot \$name" }
for {set t 20} {\$t < 106} {incr t 2} {
  after time \$t { keymatrixdown 8 0x01 }
  after time [expr {\$t + 1}] { keymatrixup 8 0x01 }
}
after time 110 { keymatrixdown 8 0x21 }
shot 115 $S/d1.png
shot 125 $S/d2.png
shot 135 $S/d3.png
set ::n11 0
debug set_bp $ADDR {[debug read memory 0x2F60] == $SEG} { incr ::n11 }
after time 120 { set ::n11 0 }
after time 135 { set f [open $S/rate.txt w]; puts \$f "11C5 per second: [expr {\$::n11/15.0}]"; close \$f }
TCL
