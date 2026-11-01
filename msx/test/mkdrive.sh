#!/bin/sh
# usage: test/mkdrive.sh <outdir>  -> writes <outdir>/drive.tcl (SPACE at 7s to leave the intro,
# hold up+fire from 23s, screenshots, and the rate of the C64 frame IRQ $11C5
# between 27s and 31s)
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
after time 7 { keymatrixdown 8 0x01 }
after time 7.3 { keymatrixup 8 0x01 }
after time 23 { keymatrixdown 8 0x21 }
shot 26 $S/d1.png
shot 29 $S/d2.png
shot 32 $S/d3.png
set ::n11 0
debug set_bp $ADDR {[debug read memory 0x2F60] == $SEG} { incr ::n11 }
after time 27 { set ::n11 0 }
after time 31 { set f [open $S/rate.txt w]; puts \$f "11C5 per second: [expr {\$::n11/4.0}]"; close \$f }
TCL
