#!/bin/sh
# usage: sh test/first_race.sh [output prefix] [race passes, default 240]
# Enter the default first course; measure passes after the race loop starts.
set -eu
cd "$(dirname "$0")/.."
OUT=${1:-/tmp/bb_first_race}
python3 - "$OUT" "${2:-240}" <<'PY'
import sys,re,json,hashlib,os
from pathlib import Path
sys.path.insert(0,'tools')
from symmap import load
tables=load()
sprite_seg,sprite_addr=next((s,a) for s,v in tables.items() if isinstance(s,int) for a,n in v if n=='T_1452')
seg,addr=next((s,a) for s,v in load().items() if isinstance(s,int) for a,n in v if n=='T_8003')
labels=dict((m[1],int(m[2],16)) for l in Path('build/main.lbl').read_text().splitlines() if (m:=re.match(r'(\w+):\s+equ\s+\$([\da-fA-F]+)',l)))
out,passes=sys.argv[1],int(sys.argv[2])
scenario=os.environ.get('RACE_SCENARIO', 'straight')
course=int(os.environ.get('RACE_COURSE', '0'))
if course not in range(5):
    sys.exit('RACE_COURSE must be 0..4')
if scenario not in ('straight', 'steering', 'collision'):
    sys.exit('RACE_SCENARIO must be straight, steering, or collision')
if scenario != 'straight' and os.environ.get('RACE_METRICS') != '1':
    sys.exit('Steering/collision scenarios require RACE_METRICS=1')
if passes < 1:
    sys.exit('Race passes must be positive')
Path(out+'_result.txt').unlink(missing_ok=True)
Path(out+'_metadata.json').write_text(json.dumps({
    'rom_sha256': hashlib.sha256(Path('build/buggyboy.rom').read_bytes()).hexdigest(),
    'config': Path('build/config.inc').read_text().strip(),
    'passes': passes, 'course': course, 'acceleration': True,
    'steering': scenario != 'straight' or 'IRQ_LIVE_OUT' in os.environ,
    'live_controls': 'IRQ_LIVE_OUT' in os.environ,
    'differential': os.environ.get('IRQ_DIFFERENTIAL') == '1',
    'scenario': scenario, 'metrics': os.environ.get('RACE_METRICS') == '1',
    'profile': os.environ.get('PROFILE') == '1',
    'validation': os.environ.get('VALIDATE_SPRITES') == '1',
}, indent=2)+'\n')
s=r'''
set throttle off
set renderer SDLGL-PP
after time 1 {catch {set videosource GFX9000}}
set ::n 0
set ::flips 0
set ::begun 0
set ::course_selecting 0
set ::course_ready 0
set ::bb_samples [open "OUT_pc.samples" w]
set ::roadlog [open "OUT_road.csv" w]
puts $::roadlog {pass,time,0342,02bc,02b9,fb2a,0334,96e4,02ca}
set ::fliplog [open "OUT_flips.csv" w]
puts $::fliplog {flip,time,seconds}
set ::log [open "OUT_frames.csv" w]
puts $::log {pass,time,seconds,flips}
proc release_fire {} {keymatrixup 8 0x01}
proc menu_input {} {
 if {$::begun} {return}
 if {$::course_selecting && !$::course_ready} {after time 1 menu_input; return}
 keymatrixdown 8 0x01
 after time 0.5 release_fire
 after time 1 menu_input
}
after time 7 menu_input
debug set_bp COURSEENTRY {[debug read memory 0x2F60] == COURSESEG && !$::begun} {
 set ::course_selecting 1
 set ::course_ready [expr {[debug read memory 0x033A] == COURSE}]
 if {$::course_ready} {keymatrixup 8 0x40} else {
  keymatrixup 8 0x01
  keymatrixdown 8 0x40
 }
}
proc finish {status} {
 if {$status eq "complete" && [info exists ::env(VALIDATE_SPRITES)] && $::env(VALIDATE_SPRITES)==1} {
  if {![info exists ::cache_check::phase] || $::cache_check::phase != 2 ||
      ![info exists ::sprite_check::count] || $::sprite_check::count == 0 ||
      ![info exists ::stream_check::count] || $::stream_check::count == 0 || $::stream_check::active ||
      ![info exists ::replacement_check::count] || $::replacement_check::count == 0 || $::replacement_check::active ||
      ![info exists ::cmmc_check::count] || $::cmmc_check::count == 0 || $::cmmc_check::active ||
      ![info exists ::dirty_check::count] || $::dirty_check::count == 0 || $::dirty_check::active} {
   set status validation_failed
  }
 }
 set f [open "OUT_result.txt" w]
 puts $f "status=$status passes=$::n"
 if {$::begun && $::n>0 && !DIFFERENTIAL} {
  set dt [expr {[machine_info time]-$::start}]
  puts $f "seconds=$dt loops_per_second=[expr {$::n/$dt}] flips=$::flips fps=[expr {$::flips/$dt}]"
 }
 close $f
 close $::log
 close $::fliplog
 close $::bb_samples
 close $::roadlog
 screenshot "OUT_end.png"
 exit
}
proc sample_race {} {
 if {$::begun} {
  puts $::bb_samples "[format %X [debug read memory 0x2F60]] [format %X [reg pc]] [debug read memory IRQSTATE] [debug read memory RENDERSTATE]"
 }
 after time 0.001 sample_race
}
if {[info exists ::env(PROFILE)] && $::env(PROFILE)==1} {
 sample_race
 debug set_bp ROADENTRY {[debug read memory 0x2F60] == ROADSEG && $::begun} {
  set row [list $::n [machine_info time]]
  foreach a {0x0342 0x02bc 0x02b9 0x2fe0 0x0334 0x96e4 0x02ca} {
   lappend row [debug read memory $a]
  }
  puts $::roadlog [join $row ,]
 }
}
proc race_pass {} {
 set now [machine_info time]
 if {!$::begun} {
  if {!$::course_ready || [debug read memory 0x033A] != COURSE} {
   puts stderr {Requested course was not selected through the menu}
   exit 1
  }
  set ::begun 1
  set ::start $now
  set ::last $now
  keymatrixup 8 0x01
  keymatrixdown 8 0x20
  return
 }
 incr ::n
 puts $::log "$::n,$now,[expr {$now-$::last}],$::flips"
 set ::last $now
 if {$::n==1} {screenshot "OUT_start.png"}
 if {$::n>=PASSES} {finish complete}
}
debug set_bp ADDR {[debug read memory 0x2F60] == SEG} race_pass
debug set_bp FLIP {[debug read memory 0x2F61] == 6 && $::begun} {
 incr ::flips
 set now [machine_info time]
 puts $::fliplog "$::flips,$now,[expr {$now-$::start}]"
}
if {[info exists ::env(VALIDATE_SPRITES)] && $::env(VALIDATE_SPRITES)==1} {
 source test/sprite_registers.tcl
 sprite_check::install SPRBANK SPRENTRY SPRRET
 source test/sprite_cache.tcl
 cache_check::install CACHEIN CACHEOUT
 source test/sprite_stream.tcl
 stream_check::install {STREAMNORMAL STREAMY STREAMX} STREAMWAIT STREAMSOURCE STREAMCAPTURE
 source test/sprite_replacement.tcl
 replacement_check::install REPLACEIN REPLACEOUT
 source test/cmmc_stream.tcl
 cmmc_check::install CMMCIN CMMCDONE
 source test/dirty_snapshot.tcl
 dirty_check::install DIRTYIN DIRTYOUT
}
if {[info exists ::env(IRQ_AB_SCRIPT)]} {
 if {[catch {source $::env(IRQ_AB_SCRIPT)} problem]} {puts stderr $::errorInfo; exit 1}
}
if {[info exists ::env(RACE_METRICS)] && $::env(RACE_METRICS)==1} {
 set ::race_metrics_labels {METRICLABELS}
 set ::race_metrics_recovery {RECOVERY}
 set ::race_metrics_contacts {METRICCONTACTS}
 set ::race_metrics_out "OUT"
 set ::race_metrics_scenario SCENARIO
 if {[catch {source test/race_metrics.tcl} problem]} {puts stderr $::errorInfo; exit 1}
}
after time 240 {finish timeout}
'''
replacements=dict([('OUT',out),('PASSES',str(passes)),('ADDR',hex(addr)),('SEG',str(seg)),('FLIP',hex(labels['ivb_flip'])),('SPRBANK',str(sprite_seg)),('SPRENTRY',hex(sprite_addr)),('SPRRET',hex(labels['N1452_set']-1)),('CACHEIN',hex(labels['r_sci'])),('CACHEOUT',hex(labels['r_sci_done'])),('STREAMNORMAL',hex(labels['spr_stream_begin'])),('STREAMY',hex(labels['spr_rows_n'])),('STREAMX',hex(labels['spr_rows_x'])),('STREAMWAIT',hex(labels['vsc_iff'])),('REPLACEIN',hex(labels['spc_select'])),('REPLACEOUT',hex(labels['spc_pos']))])
road_seg,road_addr=next((s,a) for s,v in tables.items() if isinstance(s,int) for a,n in v if n=='T_289C')
replacements.update(IRQSTATE=hex(labels['in_irq']),RENDERSTATE=hex(labels['rendering']),ROADENTRY=hex(road_addr),ROADSEG=str(road_seg))
replacements.update(CMMCIN=hex(labels['dt_stream_begin']),CMMCDONE=hex(labels['v_wait_done']))
replacements.update(DIRTYIN=hex(labels['r_dirty_begin']),DIRTYOUT=hex(labels['r_dirty_done']))
replacements.update(STREAMSOURCE=hex(labels['SPR_SRC']) if labels['IRQ_NATIVE_MODE'] else '0',
                    STREAMCAPTURE=hex(labels.get('spr_source_captured', 0)))
replacements['METRICLABELS']=' '.join('%s %d' % pair for pair in labels.items())
replacements['SCENARIO']=scenario
replacements['DIFFERENTIAL']='1' if os.environ.get('IRQ_DIFFERENTIAL') == '1' else '0'
recovery=next((s,a) for s,v in tables.items() if isinstance(s,int) for a,n in v if n=='T_B7C9')
course_seg,course_addr=next((s,a) for s,v in tables.items() if isinstance(s,int) for a,n in v if n=='T_0B5E')
replacements.update(COURSE=str(course), COURSEENTRY=hex(course_addr), COURSESEG=str(course_seg))
replacements['RECOVERY']='%d %d' % recovery
contacts={'T_1D64','T_BD2A','T_1925','T_19D0','T_1C54','T_980C'}
replacements['METRICCONTACTS']=' '.join('{%d %d %s}' % (s,a,n)
    for s,v in tables.items() if isinstance(s,int) for a,n in v if n in contacts)
s=re.sub(r"(?<![A-Z])(?:"+"|".join(map(re.escape,replacements))+r")(?![A-Z])",
         lambda m: replacements[m[0]],s)
Path(out+'.tcl').write_text(s)
PY
if grep -q 'MSX2PLUS: equ 1' build/config.inc; then
 "${OPENMSX:-openmsx}" -machine Panasonic_FS-A1WSX -ext ram1mb -ext gfx9000 -cart build/buggyboy.rom -romtype ASCII16 -script "$OUT.tcl" > "$OUT.log" 2>&1
else
 "${OPENMSX:-openmsx}" -machine Panasonic_FS-A1GT -ext gfx9000 -cart build/buggyboy.rom -romtype ASCII16 -script "$OUT.tcl" > "$OUT.log" 2>&1
fi
cat "${OUT}_result.txt"
if [ "${IRQ_DIFFERENTIAL:-0}" = 1 ]; then
 grep -q 'status=complete' "${OUT}_result.txt" || exit 1
 exit 0
fi
python3 - "$OUT" <<'PY'
import csv, math, statistics, sys
from pathlib import Path
out = sys.argv[1]
if 'status=complete' not in Path(out + '_result.txt').read_text():
    sys.exit('First-race benchmark did not complete')
rows = list(csv.DictReader(open(out + '_frames.csv')))
for start in range(0, len(rows), 120):
    window = rows[start:start+120]
    dt = sum(float(row['seconds']) for row in window)
    print('Passes %d–%d: %.3f seconds, %.3f game passes/s' %
          (start+1, start+len(window), dt, len(window)/dt))
times = sorted(float(row['seconds']) for row in rows)
print('Game-pass latency: median %.2f ms, p95 %.2f ms, worst %.2f ms' %
      (statistics.median(times) * 1000, times[math.ceil(.95 * len(times))-1] * 1000, times[-1]*1000))
flips = [float(row['seconds']) for row in csv.DictReader(open(out + '_flips.csv'))]
intervals = sorted(b-a for a,b in zip(flips,flips[1:]))
if intervals:
    print('Page-flip latency: median %.2f ms, p95 %.2f ms, worst %.2f ms' %
          (statistics.median(intervals)*1000,
           intervals[math.ceil(.95*len(intervals))-1]*1000, intervals[-1]*1000))
PY
if [ "${RACE_METRICS:-0}" = 1 ]; then
 python3 test/race_metrics.py "$OUT"
fi
