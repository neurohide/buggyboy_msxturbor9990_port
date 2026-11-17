# Reference the two-way replacement decision before each cache access.
namespace eval replacement_check {
 variable active 0
 variable count 0
 variable cases [dict create]
}
proc replacement_check::enter {} {
 variable active; variable expected; variable key; variable cases
 if {$active} {error {Nested sprite-cache lookup}}
 set key [debug read_block memory 0x7FDA 5]
 set slot [debug read memory 0x7FDF]
 set base [expr {$slot & 126}]
 set expected -1
 foreach candidate [list $slot [expr {$slot ^ 1}]] {
  set address [expr {0x6800+8*$candidate}]
  if {[debug read memory [expr {$address+5}]] &&
      [debug read_block memory $address 5] eq $key} {
   set expected $candidate
   set reason hit
   break
  }
 }
 if {$expected < 0} {
  if {![debug read memory [expr {0x6805+8*$base}]]} {
   set expected $base
   set reason invalid
  } elseif {![debug read memory [expr {0x680D+8*$base}]]} {
   set expected [expr {$base+1}]
   set reason invalid
  } else {
   set expected [expr {$base | (1 ^ [debug read memory [expr {0x6806+8*$base}]])}]
   set reason lru
  }
 }
 dict incr cases $reason
 set active 1
}
proc replacement_check::leave {} {
 variable active; variable expected; variable key; variable count
 if {!$active} {return}
 set slot [debug read memory 0x7FDF]
 if {$slot != $expected ||
     [debug read_block memory [expr {0x6800+8*$slot}] 5] ne $key ||
     ![debug read memory [expr {0x6805+8*$slot}]] ||
     [debug read memory [expr {0x6806+8*($slot & 126)}]] != ($slot & 1)} {
  puts stderr "Sprite replacement failed: lookup $count, slot $slot, expected $expected"
  binary scan $key cu* want
  binary scan [debug read_block memory [expr {0x6800+8*$slot}] 8] cu* got
  puts stderr "Expected key: $want; entry: $got; MRU: [debug read memory [expr {0x6806+8*($slot & 126)}]]"
  exit 1
  return
 }
 set active 0
 incr count
}
proc replacement_check::summary {args} {
 variable active; variable count; variable cases
 puts stderr "Sprite-cache decisions checked: $count; $cases"
 if {$active || !$count} {puts stderr {Sprite replacement validation incomplete}; exit 1}
}
proc replacement_check::install {entry leave} {
 debug set_bp $entry {[debug read memory 0x2F60] == 12} replacement_check::enter
 debug set_bp $leave {[debug read memory 0x2F60] == 12 && $replacement_check::active} replacement_check::leave
 trace add execution finish enter replacement_check::summary
}
