#!/bin/sh
# usage: test/replay.sh [name] [outprefix] [screenshot secs...]
# Drives the current build with the inputs recorded by test/record.sh <name>
# (emulated time from boot, throttle off) until the recording ends.
# Writes <outprefix>_sec.txt ("sec flips mainloop" per emulated second),
# <outprefix>_s<T>.png screenshots, and prints the in-race average
# (seconds with main loop < 50/s, i.e. not menus/attract).
NAME=${1:-ref}
OUT=${2:-${TMPDIR:-/tmp}/bb_replay}
shift 2 2>/dev/null
SHOTS=${*:-}
HERE=$(cd "$(dirname "$0")/.." && pwd)
IN="$HERE/test/replays/$NAME.tcl"
[ -f "$IN" ] || python3 "$HERE/tools/omr2tcl.py" "$HERE/test/replays/$NAME.omr" > "$IN" || exit 1
cd "$HERE"
s=$(awk '/code segment/{s=$8} $1=="T_8003:"{print s; exit}' build/code.asm | tr -d ')')
z=$(grep "^T_8003:" build/main.lbl | sed 's/.*\$//')
f=$(grep -i "^ivb_flip:" build/main.lbl | sed 's/.*\$//')
cat > "$OUT.tcl" <<TCL
set throttle off
set renderer SDLGL-PP
after time 1 { catch { set videosource GFX9000 } }
source "$IN"
set ::nf 0; set ::ml 0
debug set_bp 0x$f {[debug read memory 0x2F61] == 6} { incr ::nf }
debug set_bp 0x$z {[debug read memory 0x2F60] == $s} { incr ::ml }
set ::lg [open "${OUT}_sec.txt" w]
proc tick {s} {
  puts \$::lg "\$s \$::nf \$::ml"; flush \$::lg; set ::nf 0; set ::ml 0
  if {\$s >= ceil(\$::bb_end)} { screenshot "${OUT}_end.png"; close \$::lg; exit }
  after time 1 [list tick [expr {\$s+1}]]
}
after time 1 { tick 1 }
foreach t {$SHOTS} { after time \$t [list screenshot "${OUT}_s\$t.png"] }
TCL
"${OPENMSX:-openmsx}" -machine Panasonic_FS-A1GT -ext gfx9000 \
  -cart "$HERE/build/buggyboy.rom" -romtype ASCII16 -script "$OUT.tcl" > "$OUT.log" 2>&1
awk '$3>0 && $3<50 {n++; a+=$2; m+=$3} END{if (n) printf "in-race %.2f fps, main loop %.2f/s over %d s\n", a/n, m/n, n; else print "no in-race seconds"}' "${OUT}_sec.txt"
