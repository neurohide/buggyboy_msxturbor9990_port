# Exercise all 128 cache slots once, then restore the renderer's real state.
namespace eval cache_check {variable phase 0}
proc cache_check::enter {} {
 variable phase; variable saved; variable flags; variable count; variable bc
 if {$phase} {return}
 set phase 1
 set saved [debug read_block memory 0x6800 0x500]
 set flags [debug read_block memory 0x7900 256]
 set count [debug read memory 0x7FA4]
 set bc [reg bc]
 for {set slot 0} {$slot < 128} {incr slot} {
  debug write memory [expr {0x6800+8*$slot}] $slot
  debug write memory [expr {0x6805+8*$slot}] 1
  debug write memory [expr {0x6C80+$slot}] $slot
  debug write memory [expr {0x6C00+$slot}] 1
  debug write memory [expr {0x7900+$slot}] [expr {$slot >= 32}]
 }
 debug write memory 0x7FA4 128
}
proc cache_check::leave {} {
 variable phase; variable saved; variable flags; variable count; variable bc
 if {$phase != 1} {return}
 if {[debug read memory 0x7FA4] != 32} {
  puts stderr {Sprite-cache validation failed: live count}; exit 1
 }
 for {set slot 0} {$slot < 128} {incr slot} {
  set expected [expr {$slot < 32}]
  if {[debug read memory [expr {0x6805+8*$slot}]] != $expected ||
      [debug read memory [expr {0x6C00+$slot}]] != $expected} {
   puts stderr "Sprite-cache validation failed at slot $slot"; exit 1
  }
 }
 debug write_block memory 0x6800 $saved
 debug write_block memory 0x7900 $flags
 debug write memory 0x7FA4 $count
 reg bc [expr {($count << 8) | ($bc & 255)}]
 set phase 2
 puts stderr {Sprite-cache slots checked: 128}
}
proc cache_check::install {entry leave} {
 debug set_bp $entry {[debug read memory 0x2F60] == 12 && $cache_check::phase == 0} cache_check::enter
 debug set_bp $leave {[debug read memory 0x2F60] == 12 && $cache_check::phase == 1} cache_check::leave
}
