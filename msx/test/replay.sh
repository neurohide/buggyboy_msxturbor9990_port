#!/bin/sh
# usage: test/replay.sh [name] [outprefix] [screenshot secs...]
# Drives the current build with the inputs recorded by test/record.sh <name>
# (emulated time from boot, throttle off) until the recording ends.
# Writes <outprefix>_sec.txt ("sec flips mainloop" per emulated second),
# <outprefix>_s<T>.png screenshots, and prints the in-race average
# (seconds with main loop < 50/s, i.e. not menus/attract).
# PROFILE=1 records per-frame work in <outprefix>_frames.csv, aggregate counts
# in <outprefix>_work.txt, and PC samples in <outprefix>_pc.samples.
# PROFILE_FROM/PROFILE_TO select the emulated-second window (default 60..100).
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
if [ "${PROFILE:-0}" = 1 ]; then
  # Sample the same recorded race without changing the ROM. Breakpoints count
  # work; PC samples show where the Z80 spends emulated time.
  label_addr() {
    awk -v name="$1:" '$1 == name {sub(/^\$/, "0x", $3); print $3; exit}' "$HERE/build/main.lbl"
  }
  for name in render_frame dbg_cells dbg_full v_send_cmd dr_next dt_op \
              sp_cache sp_render tl_fill k_lookup klu_scan cmdblk v_wait SEG_RENDER SEG_C2; do
    value=$(label_addr "$name")
    [ -n "$value" ] || { echo "missing label: $name" >&2; exit 1; }
    eval "prof_$name=\$value"
  done
  cat >> "$OUT.tcl" <<TCL
set ::prof_on 0
set ::prof_frames 0
set ::prof_cells 0
set ::prof_full 0
set ::prof_commands 0
set ::prof_lmmm 0
set ::prof_lmmv 0
set ::prof_lmmc 0
set ::prof_cmmc 0
set ::prof_copy_pixels 0
set ::prof_sprite_lookups 0
set ::prof_sprite_builds 0
set ::prof_snapshots 0
set ::prof_lookups 0
set ::prof_lookup_misses 0
set ::prof_samples 0
set ::prof_wait_samples 0
set ::prof_pc [open "${OUT}_pc.samples" w]
set ::prof_frame_log [open "${OUT}_frames.csv" w]
puts \$::prof_frame_log {time,frame_seconds,cells,full_rows,commands,lmmm,lmmv,lmmc,cmmc,copy_pixels,sprite_lookups,sprite_builds,snapshots,lookups,lookup_misses}
set ::prof_last_time {}
foreach name {commands lmmm lmmv lmmc cmmc copy_pixels sprite_lookups sprite_builds snapshots lookups lookup_misses} {
  set ::prof_prev_\$name 0
}
proc prof_frame {} {
  set now [machine_info time]
  set cells [expr {[debug read memory $prof_dbg_cells] + 256 * [debug read memory [expr {$prof_dbg_cells + 1}]]}]
  set full [debug read memory $prof_dbg_full]
  if {\$::prof_last_time ne {}} {
    set row [list \$now [expr {\$now - \$::prof_last_time}] \$cells \$full]
    foreach name {commands lmmm lmmv lmmc cmmc copy_pixels sprite_lookups sprite_builds snapshots lookups lookup_misses} {
      lappend row [expr {[set ::prof_\$name] - [set ::prof_prev_\$name]}]
    }
    puts \$::prof_frame_log [join \$row ,]
  }
  set ::prof_last_time \$now
  foreach name {commands lmmm lmmv lmmc cmmc copy_pixels sprite_lookups sprite_builds snapshots lookups lookup_misses} {
    set ::prof_prev_\$name [set ::prof_\$name]
  }
  incr ::prof_frames
  incr ::prof_cells \$cells
  incr ::prof_full \$full
}
proc prof_sample {} {
  if {!\$::prof_on} { return }
  set pc [reg pc]
  puts \$::prof_pc "[format %X [debug read memory 0x2F60]] [format %X \$pc]"
  incr ::prof_samples
  if {\$pc >= $prof_v_wait && \$pc < $prof_v_send_cmd && [debug read memory 0x2F60] == $prof_SEG_RENDER} {
    incr ::prof_wait_samples
  }
  after time 0.001 prof_sample
}
proc prof_start {} {
  set ::prof_on 1
  debug set_bp $prof_render_frame {[debug read memory 0x2F60] == $prof_SEG_RENDER} { prof_frame }
  debug set_bp $prof_v_send_cmd {[debug read memory 0x2F60] == $prof_SEG_RENDER} {
    incr ::prof_commands
    set op [debug read memory [expr {$prof_cmdblk + 20}]]
    switch \$op {
      64 {
        incr ::prof_lmmm
        set nx [expr {[debug read memory [expr {$prof_cmdblk + 8}]] + 256 * [debug read memory [expr {$prof_cmdblk + 9}]]}]
        set ny [expr {[debug read memory [expr {$prof_cmdblk + 10}]] + 256 * [debug read memory [expr {$prof_cmdblk + 11}]]}]
        incr ::prof_copy_pixels [expr {\$nx * \$ny}]
      }
      32 { incr ::prof_lmmv }
      16 { incr ::prof_lmmc }
    }
  }
  debug set_bp $prof_dr_next {[debug read memory 0x2F60] == $prof_SEG_RENDER} { incr ::prof_commands; incr ::prof_lmmc }
  debug set_bp $prof_dt_op {[debug read memory 0x2F60] == $prof_SEG_RENDER} { incr ::prof_commands; incr ::prof_cmmc }
  debug set_bp $prof_sp_cache {[debug read memory 0x2F60] == $prof_SEG_RENDER} { incr ::prof_sprite_lookups }
  debug set_bp $prof_sp_render {[debug read memory 0x2F60] == $prof_SEG_RENDER} {
    incr ::prof_sprite_builds
    if {[info exists ::prof_sprite_log]} { set ::prof_sprite_miss 1 }
  }
  debug set_bp $prof_tl_fill {[debug read memory 0x2F61] == $prof_SEG_C2} { incr ::prof_snapshots }
  debug set_bp $prof_k_lookup {[debug read memory 0x2F61] == $prof_SEG_C2} { incr ::prof_lookups }
  debug set_bp $prof_klu_scan {[debug read memory 0x2F61] == $prof_SEG_C2} { incr ::prof_lookup_misses }
  prof_sample
}
proc prof_stop {} {
  set ::prof_on 0
  close \$::prof_pc
  close \$::prof_frame_log
  set f [open "${OUT}_work.txt" w]
  foreach name {frames cells full commands lmmm lmmv lmmc cmmc copy_pixels sprite_lookups sprite_builds snapshots lookups lookup_misses samples wait_samples} {
    puts \$f "\$name [set ::prof_\$name]"
  }
  close \$f
}
after time ${PROFILE_FROM:-60} prof_start
after time ${PROFILE_TO:-100} prof_stop
TCL
  if [ "${PROFILE_CELLS:-0}" = 1 ]; then
    for name in cell_uniform cell_cols row_mode cur_row; do
      value=$(label_addr "$name")
      [ -n "$value" ] || { echo "missing label: $name" >&2; exit 1; }
      eval "prof_$name=\$value"
    done
    cat >> "$OUT.tcl" <<TCL
set ::prof_cell_log [open "${OUT}_cells.txt" w]
proc prof_cell {} {
  set key {}
  set source [reg hl]
  for {set i 0} {\$i < 8} {incr i} {
    append key [format %02X [debug read memory [expr {\$source + \$i}]]]
  }
  for {set i 0} {\$i < 5} {incr i} {
    append key [format %02X [debug read memory [expr {$prof_cell_cols + \$i}]]]
  }
  puts \$::prof_cell_log "[debug read memory $prof_cur_row] [debug read memory $prof_row_mode] \$key"
}
after time ${PROFILE_FROM:-60} {
  debug set_bp $prof_cell_uniform {[debug read memory 0x2F60] == $prof_SEG_RENDER} { prof_cell }
}
after time ${PROFILE_TO:-100} { close \$::prof_cell_log }
TCL
  fi
  if [ "${PROFILE_SPRITES:-0}" = 1 ]; then
    for name in spc_pos spr_tmp; do
      value=$(label_addr "$name")
      [ -n "$value" ] || { echo "missing label: $name" >&2; exit 1; }
      eval "prof_$name=\$value"
    done
    cat >> "$OUT.tcl" <<TCL
set ::prof_sprite_miss 0
set ::prof_sprite_log [open "${OUT}_sprites.txt" w]
proc prof_sprite {} {
  set key {}
  for {set i 10} {\$i < 15} {incr i} {
    append key [format %02X [debug read memory [expr {$prof_spr_tmp + \$i}]]]
  }
  puts \$::prof_sprite_log "\$::prof_sprite_miss [debug read memory [expr {$prof_spr_tmp + 15}]] \$key"
  set ::prof_sprite_miss 0
}
after time ${PROFILE_FROM:-60} {
  debug set_bp $prof_spc_pos {[debug read memory 0x2F60] == $prof_SEG_RENDER} { prof_sprite }
}
after time ${PROFILE_TO:-100} { close \$::prof_sprite_log; unset ::prof_sprite_log }
TCL
  fi
fi
# machine follows the build: MSX2+ (FS-A1WSX + 1 MB mapper) or turbo R
if grep -q 'MSX2PLUS: equ 1' "$HERE/build/config.inc"; then
  MACH=${MACHINE:--machine Panasonic_FS-A1WSX -ext ram1mb}
else
  MACH=${MACHINE:--machine Panasonic_FS-A1GT}
fi
"${OPENMSX:-openmsx}" $MACH -ext gfx9000 \
  -cart "$HERE/build/buggyboy.rom" -romtype ASCII16 -script "$OUT.tcl" > "$OUT.log" 2>&1
awk '$3>0 && $3<50 {n++; a+=$2; m+=$3} END{if (n) printf "in-race %.2f fps, main loop %.2f/s over %d s\n", a/n, m/n, n; else print "no in-race seconds"}' "${OUT}_sec.txt"
if [ "${PROFILE:-0}" = 1 ] && [ -f "${OUT}_work.txt" ]; then
  cat "${OUT}_work.txt"
  python3 "$HERE/tools/profgroup.py" "${OUT}_pc.samples"
fi
