# Live input only: no injected game state. Can follow irq_ab.tcl or run alone.
namespace eval irq_live {
 variable state idle
 variable ticks 0
 variable state_tick 0
 variable started 0
 variable audio 0
 variable inputs 0
 variable awaiting_sound 0
 variable last_audio {}
 variable active_return 0
 variable returns {}
 variable complete 0
 variable left 0
 variable right 0
 variable pause_progress 0
 variable pause_audio 0
 variable pause_inputs 0
 variable events [open "$::env(IRQ_LIVE_OUT)_live.csv" w]
 puts $events {time,pass,tick,event,phase,velocity,steer,x,progress,joy,key,audio,inputs}
 variable cadence [open "$::env(IRQ_LIVE_OUT)_cadence.csv" w]
 puts $cadence {time,interval,frame,psg,sid}
}
proc irq_live::read {address} {
 return [debug read {1MB External RAM} [expr {0x10000+$address}]]
}
proc irq_live::progress {} {return [expr {256*[read 0x6a]+[read 0x6b]}]}
proc irq_live::fail {message} {puts stderr "Live IRQ verification FAILED: $message"; exit 1; error $message}
proc irq_live::event {name} {
 variable events; variable ticks; variable audio; variable inputs
 puts $events [join [list [machine_info time] $::n $ticks $name [read 0x354] [read 0x4b] [read 0x2d4] [read 0x1486] [progress] [read 0x2f69] [read 0x2f71] $audio $inputs] ,]
 flush $events
}
proc irq_live::transition {next} {
 variable state; variable ticks; variable state_tick
 set state $next; set state_tick $ticks
 event $next
}
proc irq_live::start {args} {
 variable started
 if {$started || !$::begun} return
 set started 1
 puts stderr "Audio settings: mute=$::mute master_volume=$::master_volume PSG_volume=$::PSG_volume devices=[machine_info sounddevice]"
 if {[info exists ::env(IRQ_LIVE_AUDIO)] && $::env(IRQ_LIVE_AUDIO) == 1} {
  set ::irq_live::old_volume $::master_volume
  set ::irq_live::old_mute $::mute
  set ::master_volume 100
  set ::mute false
  record start -audioonly "$::env(IRQ_LIVE_OUT)_audio.wav"
 }
 keymatrixdown 8 0x10
 transition left
}
proc irq_live::handler {name} {
 variable state; variable ticks; variable state_tick; variable started; variable complete
 variable left; variable right; variable left_x; variable right_x
 variable pause_progress; variable pause_audio; variable pause_inputs; variable audio; variable inputs
 if {$name ne "11C5" || !$started || $complete} return
 incr ticks
 if {$ticks-$state_tick > 1400} {fail "input scenario stalled in $state"}
 set phase [read 0x354]
 switch $state {
  left {
   if {![info exists left_x]} {set left_x [read 0x1486]}
   if {([read 0x2f69]&4)==0 && [read 0x2d4]<6 && [read 0x1486]<$left_x} {
    set left 1; keymatrixup 8 0x10; keymatrixdown 8 0x80
    set right_x [read 0x1486]; transition right
   }
  }
  right {
   if {([read 0x2f69]&8)==0 && [read 0x2d4]>6 && [read 0x1486]>$right_x} {
    set right 1; keymatrixup 8 0x80; keymatrixdown 7 0x10
    transition pause_down
   }
  }
  pause_down {
   if {$phase == 1} {keymatrixup 7 0x10; transition pause_release}
  }
  pause_release {
   if {$phase == 2} {
    set pause_progress [progress]; set pause_audio $audio; set pause_inputs $inputs
    transition paused
   }
  }
  paused {
   if {$phase != 2 || [read 0x4b] != 0 || [progress] != $pause_progress} {fail {game advanced while paused}}
   if {$ticks-$state_tick >= 30} {
    if {$audio <= $pause_audio || $inputs <= $pause_inputs} {fail {audio/input stopped during pause}}
    keymatrixdown 7 0x10; transition resume_down
   }
  }
  resume_down {
   if {$phase == 224} {keymatrixup 7 0x10; transition resume_release}
  }
  resume_release {
   if {$phase == 0 && [read 0x4b]>0 && [progress]!=$pause_progress} {
    set complete 1; transition resumed
   }
  }
 }
}
proc irq_live::enter {} {
 variable active_return; variable returns
 if {!$::begun || $active_return} return
 set sp [reg sp]
 set ret [expr {[debug read memory $sp]+256*[debug read memory [expr {$sp+1}]]}]
 set active_return [expr {$sp+2}]
 if {$ret ni $returns} {
  lappend returns $ret
  debug set_bp $ret {$irq_live::active_return && [reg sp] == $irq_live::active_return} {
   set ::irq_live::active_return 0
   irq_live::handler 11C5
  }
 }
}
proc irq_live::sound {} {
 variable audio; variable last_audio; variable cadence
 set ::irq_live::awaiting_sound 0
 if {!$::begun} return
 set now [machine_info time]
 set dt {}
 if {$last_audio ne {}} {set dt [expr {$now-$last_audio}]}
 binary scan [debug read_block {PSG regs} 0 14] H* psg
 binary scan [debug read_block {1MB External RAM} 0x12f40 25] H* sid
 puts $cadence "$now,$dt,[read 0x2f72],$psg,$sid"
 set last_audio $now
 incr audio
}
proc irq_live::summary {args} {
 variable complete; variable left; variable right; variable events; variable cadence; variable audio; variable inputs
 event finished
 if {[info exists ::env(IRQ_LIVE_AUDIO)] && $::env(IRQ_LIVE_AUDIO) == 1} {
  record stop
  set ::master_volume $::irq_live::old_volume
  set ::mute $::irq_live::old_mute
 }
 close $events; close $cadence
 if {!$complete || !$left || !$right} {fail {missing live steering or pause/resume coverage}}
 puts stderr "Live IRQ verification passed: steering left/right, paused 30 handlers, resumed progress; audio=$audio input=$inputs"
}
trace add execution race_pass leave irq_live::start
trace add execution finish enter irq_live::summary
if {![llength [info procs ::irq_ab::enter]]} {
 debug set_bp [dict get $::irq_live_labels entry] "\[debug read memory 0x2f60\] == [dict get $::irq_live_labels segment]" irq_live::enter
}
set sound [dict get $::irq_live_labels sound]
# sound_frame is mapped directly by k_int without changing cur_p1.
# Check its entry opcode/operand and preceding input poll to reject bank aliases.
debug set_bp $sound "\$::irq_live::awaiting_sound && \[debug read memory $sound\] == 0x3a && \[debug read memory [expr {$sound+1}]\] == ([dict get $::irq_live_labels frame]&255)" irq_live::sound
debug set_bp [dict get $::irq_live_labels input] "\$::begun && \[debug read memory 0x2f61\] == 6 && \[debug read memory [dict get $::irq_live_labels input]\] == 0x3e && \[debug read memory [expr {[dict get $::irq_live_labels input]+1}]\] == 15" {incr ::irq_live::inputs; set ::irq_live::awaiting_sound 1}
