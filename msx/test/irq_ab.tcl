# Replay both handlers with interrupts already disabled by the IRQ dispatcher.
namespace eval irq_ab {
 variable phase 0
 variable counts [dict create 10E3 0 11C5 0 134C 0 141A 0]
 variable ram {1MB External RAM}
 variable returns {}
 variable snapshots 0
 variable native_time 0
 variable reference_time 0
 variable snapshot_active 0
 variable calls {}
 variable covered {}
 variable queue {}
 variable synthetic 0
 variable synthetic_count 0
}
proc irq_ab::regs {} {
 set result {}
 foreach r {af bc de hl ix iy sp pc} {lappend result $r [reg $r]}
 return $result
}
proc irq_ab::memory {} {
 variable ram
 return [debug read_block $ram 0x10000 0x20000]
}
proc irq_ab::enter {name segment reference native} {
 variable phase
 if {$phase || [debug read memory 0x2F60] != $segment || !$::begun} return
 variable saved_regs; variable pre; variable sp; variable entry; variable handler
 variable returns; variable start
 variable queue; variable covered; variable base_pre; variable base_regs; variable native_entry
 set handler $name
 set saved_regs [regs]
 set sp [reg sp]
 set entry $reference
 set native_entry $native
 set base_pre [memory]
 set base_regs $saved_regs
 if {![dict exists $covered $name] && (![info exists ::env(IRQ_AB_SYNTHETIC)] || $::env(IRQ_AB_SYNTHETIC) != 0)} {
  dict set covered $name 1
  set queue [cases $name]
 } else {set queue {}}
 lappend queue {}
 set ret [expr {[debug read memory $sp] | ([debug read memory [expr {$sp+1}]] << 8)}]
 if {$ret ni $returns} {
  lappend returns $ret
  debug set_bp $ret {$irq_ab::phase && [reg sp] == $irq_ab::sp+2} irq_ab::leave
 }
 next_case
}
proc irq_ab::cases {name} {
 set result {}
 switch $name {
  10E3 {
   foreach band {0 1 11 12} {
    set line [debug read memory [expr {0x14A6+$band}]]
    lappend result [list 0x49 $band 0x4A $line 0xCFEE 1]
   }
   lappend result [list 0x49 12 0x4A [expr {[debug read memory 0x14B2]^1}]]
   foreach status {1 2 3} {lappend result [list 0x0354 $status 0xCFEE 255]}
   foreach speed {0 1 31 32 255} {
    lappend result [list 0x0354 0 0x004B $speed 0x14C2 0 0x006B 255 0x006A 255 0x0047 52 0x14C3 255]
   }
  }
  11C5 {
   foreach status {0 1 2 3 255} {
    foreach key {255 127 253} {
     set test [list 0xEFA6 0 0x0354 $status 0xCFEC 0 0x02E9 0 0x02E8 1]
     for {set a 0x2F6A} {$a < 0x2F72} {incr a} {lappend test $a $key}
     lappend result $test
    }
   }
   foreach flags {{1 0} {0 1} {255 255}} {
    lassign $flags upper race
    set test [list 0xEFA6 1 0x0354 0 0xCFEC $upper 0x02E9 $race 0x02E8 255 0x2E1F 0]
    # Force different X/Y, pointer and colour bytes for all upper sprites.
    for {set i 0} {$i < 24} {incr i} {lappend test [expr {0x132F+$i}] [expr {($i*19+7)&255}]}
    lappend result $test
   }
   foreach curve {0 1 7 127 128 249 255} {
    foreach speed {0 3 31 255} {
     foreach phase {0 7 255} {
      lappend result [list 0xEFA6 1 0x02D6 $curve 0x004B $speed 0xB675 $phase]
     }
    }
   }
  }
  134C {
   foreach flag {0x004B 0x02BC 0x02B9 0x24FC} {
    set value [expr {$flag == 0x004B ? 0 : 1}]
    lappend result [list $flag $value]
   }
   foreach step {0 1 7 127 128 249 255} {
    foreach scroll {16 23} {
     set test [list 0x004B 1 0x02BC 0 0x02B9 0 0x24FC 0 0x0070 $step 0x006F $scroll 0x2E18 0 0x2E19 0]
     # Alternating / repeated groups expose over-marking hidden by a full dirty map.
     for {set i 0} {$i < 120} {incr i} {lappend test [expr {0x14608+$i}] [expr {($i/8)%3}]}
     lappend result $test
    }
   }
   foreach pattern {uniform rows alternating} {
    foreach dirty {0 85 255} {
     foreach direction {{1 23} {255 16}} {
      lassign $direction step scroll
      set test [list 0x004B 1 0x02BC 0 0x02B9 0 0x24FC 0 0x0070 $step 0x006F $scroll 0x2E18 $dirty 0x2E19 $dirty]
      for {set i 0} {$i < 120} {incr i} {
       switch $pattern {
        uniform {set value 7}
        rows {set value [expr {$i/40}]}
        alternating {set value [expr {$i&1}]}
       }
       lappend test [expr {0x14608+$i}] $value
      }
      lappend result $test
     }
    }
   }
  }
  141A {
   foreach flags {{0 0} {1 0} {0 1} {255 255}} {
    lassign $flags countdown race
    lappend result [list 0xCFEC $countdown 0x02E9 $race 0x02E7 255 0x2E1F 0]
   }
  }
 }
 return $result
}
proc irq_ab::next_case {} {
 variable queue; variable base_pre; variable base_regs; variable synthetic
 variable pre; variable saved_regs; variable ram; variable native_entry
 variable phase; variable start; variable calls
 debug write_block $ram 0x10000 $base_pre
 foreach {r v} $base_regs {reg $r $v}
 set test [lindex $queue 0]
 set queue [lrange $queue 1 end]
 set synthetic [expr {[llength $test] != 0}]
 foreach {address value} $test {
  if {$address >= 0x10000} {debug write $ram $address $value} else {debug write memory $address $value}
 }
 set saved_regs [regs]
 set pre [memory]
 set calls {}
 set phase 1
 set start [machine_info time]
 reg pc $native_entry
}
proc irq_ab::fail {message} {
 puts stderr "IRQ differential FAILED: $message"
 exit 1
}
proc irq_ab::leave {{endpoint return}} {
 variable phase; variable pre; variable ram; variable saved_regs
 variable native_post; variable native_regs; variable sp; variable entry; variable handler
 variable counts; variable start; variable native_time; variable reference_time
 variable calls; variable native_calls
 variable native_endpoint
 variable queue; variable synthetic; variable synthetic_count
 if {$phase == 1} {
  set native_time [expr {$native_time + [machine_info time]-$start}]
  set native_post [memory]
  set native_regs [regs]
  set native_calls $calls
  set native_endpoint $endpoint
  set calls {}
  debug write_block $ram 0x10000 $pre
  foreach {r v} $saved_regs {reg $r $v}
  reg pc $entry
  set phase 2
  set start [machine_info time]
  return
 }
 set reference_time [expr {$reference_time + [machine_info time]-$start}]
 if {$endpoint ne $native_endpoint} {fail "$handler control transfer: native=$native_endpoint translated=$endpoint"}
 if {$calls ne $native_calls} {fail "$handler game/audio call order: native=$native_calls translated=$calls"}
 set post [memory]
 # These bytes hold no persistent game state: stack below entry SP, kernel
 # scratch k_tmp, the last lookup result and the 32-entry lookup cache.
 foreach {lo hi} [list 0x3500 $sp 0x2F90 0x2F98 0x2FB9 0x2FBE 0x3060 0x3100] {
  set zero [string repeat \0 [expr {$hi-$lo}]]
  set native_post [string replace $native_post $lo [expr {$hi-1}] $zero]
  set post [string replace $post $lo [expr {$hi-1}] $zero]
 }
 if {$native_post ne $post} {
  binary scan $native_post cu* a
  binary scan $post cu* b
  set differences {}
  for {set i 0} {$i < [llength $a] && [llength $differences] < 12} {incr i} {
   if {[lindex $a $i] != [lindex $b $i]} {
    lappend differences [format {%05X native=%02X translated=%02X} [expr {$i+0x10000}] [lindex $a $i] [lindex $b $i]]
   }
  }
  fail "$handler call [dict get $counts $handler]: $differences"
 }
 # IRQ dispatcher consumes memory and scheduling state; both register banks
 # are restored by k_int. Still check the handler's accumulator/X/Y/stack ABI.
 foreach r {bc de sp} {
  if {[dict get $native_regs $r] != [reg $r]} {fail "$handler register $r"}
 }
 if {([dict get $native_regs af] >> 8) != ([reg af] >> 8)} {fail "$handler register A"}
 dict incr counts $handler
 if {$synthetic} {incr synthetic_count}
 if {[llength $queue]} {next_case; return}
 set phase 0
 if {[llength [info procs ::irq_live::handler]]} {irq_live::handler $handler}
 if {$endpoint eq "escape"} {finish complete}
}
proc irq_ab::call {name} {
 variable phase; variable calls
 if {$phase} {lappend calls $name}
}
proc irq_ab::snapshot_enter {} {
 variable snapshot_active; variable snapshot_pre; variable snapshot_de
 variable snapshot_expected; variable snapshot_ret; variable ram
 if {$snapshot_active} {fail {nested snapshot}}
 set snapshot_de [reg de]
 set snapshot_pre [debug read_block memory $snapshot_de 62]
 set snapshot_expected $snapshot_pre
 set fields {0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 21 22 23 24 28 29 33 34 35 37 38 39 40 41 42 43 44 45 46}
 foreach offset $fields {
  set byte [debug read_block memory [expr {0x2F00+$offset}] 1]
  set index [expr {$offset+6}]
  set snapshot_expected [string replace $snapshot_expected $index $index $byte]
 }
 set base [expr {0x14000 + (([debug read memory 0x2F18] & 0xF0) << 6) + 0x3F8}]
 set snapshot_expected [string replace $snapshot_expected 54 61 [debug read_block $ram $base 8]]
 set sp [reg sp]
 set snapshot_ret [expr {[debug read memory $sp] | ([debug read memory [expr {$sp+1}]] << 8)}]
 set snapshot_active 1
}
proc irq_ab::snapshot_leave {} {
 variable snapshot_active; variable snapshot_ret; variable snapshot_de
 variable snapshot_expected; variable snapshots
 if {!$snapshot_active || [reg pc] != $snapshot_ret} return
 if {[debug read_block memory $snapshot_de 62] ne $snapshot_expected} {fail {sparse snapshot contents or unused-field write}}
 set snapshot_active 0
 incr snapshots
}
proc irq_ab::summary {args} {
 variable counts; variable phase; variable snapshots; variable snapshot_active
 variable native_time; variable reference_time
 variable synthetic_count
 puts stderr "IRQ differential counts: $counts synthetic=$synthetic_count snapshots=$snapshots native_seconds=$native_time translated_seconds=$reference_time"
 if {$phase || $snapshot_active || !$snapshots} {fail {incomplete replay}}
 set expected 155
 if {[info exists ::env(IRQ_AB_SYNTHETIC)] && $::env(IRQ_AB_SYNTHETIC) == 0} {set expected 0}
 if {$synthetic_count != $expected} {fail "expected $expected synthetic cases, got $synthetic_count"}
 dict for {name count} $counts {if {!$count} {fail "handler $name not exercised"}}
}
proc irq_ab::install {entries snapshot} {
 foreach item $entries {
  lassign $item name segment reference native
  debug set_bp $reference {} [list irq_ab::enter $name $segment $reference $native]
 }
 debug set_bp $snapshot {} irq_ab::snapshot_enter
 # Return from k_vcopy8 lands at one of these two kernel snapshot callers.
 # Checking each instruction would be excessive: install caller return BPs
 # on the first snapshot, then reuse them.
 debug set_bp $snapshot {} {
  set sp [reg sp]
  set ret [expr {[debug read memory $sp] | ([debug read memory [expr {$sp+1}]] << 8)}]
  if {![info exists ::irq_ab::snapshot_returns($ret)]} {
   set ::irq_ab::snapshot_returns($ret) 1
   debug set_bp $ret {} irq_ab::snapshot_leave
  }
 }
 trace add execution finish enter irq_ab::summary
}
