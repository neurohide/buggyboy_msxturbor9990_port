# Check the complete dirty snapshot, including flags that happen to be zero.
namespace eval dirty_check {variable active 0; variable count 0}
proc dirty_check::enter {} {
 variable active; variable vic; variable colour
 if {$active} {error {Nested dirty snapshot}}
 set vic [debug read_block memory 0x2E00 256]
 set colour [debug read_block memory 0x2F7C 16]
 set active 1
}
proc dirty_check::leave {} {
 variable active; variable vic; variable colour; variable count
 if {!$active} {error {Dirty snapshot exit without entry}}
 if {[debug read_block memory 0x7900 256] ne $vic ||
     [debug read_block memory 0x7F00 16] ne $colour ||
     [debug read_block memory 0x2E00 256] ne [string repeat \0 256] ||
     [debug read_block memory 0x2F7C 16] ne [string repeat \0 16]} {
  puts stderr "Dirty snapshot failed at frame $count"
  exit 1
  return
 }
 set active 0
 incr count
}
proc dirty_check::summary {args} {
 variable active; variable count
 puts stderr "Dirty snapshots checked: $count"
 if {$active || !$count} {puts stderr {Dirty snapshot validation incomplete}; exit 1}
}
proc dirty_check::install {entry leave} {
 debug set_bp $entry {[debug read memory 0x2F60] == 12} dirty_check::enter
 debug set_bp $leave {[debug read memory 0x2F60] == 12} dirty_check::leave
 trace add execution finish enter dirty_check::summary
}
