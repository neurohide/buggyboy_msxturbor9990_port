#!/bin/sh
# usage: test/record.sh [name]
# Play the current build at normal speed; your inputs are saved to
# test/replays/<name>.omr (openMSX replay, rewritten every 5 s and on F12).
# Close the window when done. Replay with test/replay.sh <name>.
NAME=${1:-ref}
HERE=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$HERE/test/replays"
OMR="$HERE/test/replays/$NAME.omr"
TCL="${TMPDIR:-/tmp}/bb_record.tcl"
cat > "$TCL" <<TCL
set renderer SDLGL-PP
after time 1 { catch { set videosource GFX9000 } }
reverse start
proc bb_save {} { catch { reverse savereplay "$OMR" } }
proc bb_tick {} { bb_save; after realtime 5 bb_tick }
after realtime 5 bb_tick
bind F12 bb_save
TCL
"${OPENMSX:-openmsx}" -machine Panasonic_FS-A1GT -ext gfx9000 \
  -cart "$HERE/build/buggyboy.rom" -romtype ASCII16 -script "$TCL"
cp "$HERE/build/buggyboy.rom" "$HERE/test/replays/$NAME.rom"
python3 "$HERE/tools/omr2tcl.py" "$OMR" > "$HERE/test/replays/$NAME.tcl" && \
  echo "saved $OMR ($(grep -c '^after' "$HERE/test/replays/$NAME.tcl") input events)"
