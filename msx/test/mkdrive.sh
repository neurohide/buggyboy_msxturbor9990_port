#!/bin/sh
# usage: test/mkdrive.sh <outdir>
# Leaves the intro, selects OFFROAD, accelerates and measures game frames at 70-80s.
set -eu
S=${1:?usage: test/mkdrive.sh outdir}
mkdir -p "$S"
S=$(cd "$S" && pwd)
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
cat > "$S/drive.tcl" <<TCL
proc shot {t name} { after time \$t [list screenshot \$name] }
after time 7 { keymatrixdown 8 0x01 }
after time 7.3 { keymatrixup 8 0x01 }
after time 23 { keymatrixdown 8 0x01 }
after time 24 { keymatrixup 8 0x01 }
after time 36 { keymatrixdown 8 0x01 }
after time 40 { keymatrixup 8 0x01 }
after time 48 { keymatrixdown 8 0x20 }
shot 26 {$S/title.png}
shot 35 {$S/select.png}
shot 81 {$S/race.png}
set ::n11 0
debug set_bp $ADDR {[debug read memory 0x2F60] == $SEG} { incr ::n11 }
after time 70 { set ::n11 0 }
after time 80 {
  set f [open {$S/rate.txt} w]
  puts \$f "cpu=[get_active_cpu]"
  puts \$f "game frames per second: [expr {\$::n11/10.0}]"
  close \$f
}
TCL
