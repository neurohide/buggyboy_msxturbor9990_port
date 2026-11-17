# Check actual CMMC pixels against the source bytes and palette slots.
# The hires reference preserves the original OR interpolation between pairs.
namespace eval cmmc_check {
 variable active 0
 variable count 0
 variable modes [dict create]
}
proc cmmc_check::expand {value mode colours} {
 set pixels {}
 if {$mode} {
  foreach shift {6 4 2 0} {
   set colour [lindex $colours [expr {($value >> $shift) & 3}]]
   lappend pixels $colour $colour $colour
  }
 } else {
  foreach shift {6 4 2 0} {
   set pair [expr {($value >> $shift) & 3}]
   lappend pixels [lindex $colours [expr {$pair >> 1}]] \
                  [lindex $colours [expr {$pair != 0}]] \
                  [lindex $colours [expr {$pair & 1}]]
  }
 }
 return $pixels
}
proc cmmc_check::tables {} {
 for {set value 0} {$value < 256} {incr value} {
  set mask 0
  foreach bit [expand $value 0 {0 1}] {set mask [expr {2*$mask+$bit}]}
  set want [list [expr {$mask >> 4}] [expr {($mask & 15) << 4}] \
                 [expr {$mask >> 8}] [expr {$mask & 255}]]
  set got {}
  foreach base {0xF400 0xF500 0xF600 0xF700} {
   lappend got [debug read memory [expr {$base+$value}]]
  }
  if {$got ne $want} {error "Hires CMMC table mismatch at source byte $value"}
 }
}
proc cmmc_check::enter {} {
 variable active; variable expected; variable x; variable y; variable count; variable modes
 if {$active} {error {CMMC stream was not checked before the next cell}}
 if {!$count} {tables}
 set mode [debug read memory 0x7F40]
 dict incr modes $mode
 set colours {}
 for {set i 1} {$i <= 4} {incr i} {
  lappend colours [debug read memory [expr {0x7F40+$i}]]
 }
 set expected {}
 for {set i 0} {$i < 8} {incr i} {
  lappend expected [expand [debug read memory [expr {[reg de]+$i}]] $mode $colours]
 }
 set x [expr {[debug read memory 0x7F8A]+256*[debug read memory 0x7F8B]}]
 set y [expr {[debug read memory 0x7F8C]+256*[debug read memory 0x7F8D]}]
 set active 1
}
proc cmmc_check::leave {} {
 variable active; variable expected; variable x; variable y; variable count; variable vram
 if {!$active} {return}
 for {set row 0} {$row < 8} {incr row} {
  set got {}
  for {set column 0} {$column < 12} {incr column} {
   set pixel [expr {$x+$column}]
   set logical [expr {256*($y+$row)+$pixel/2}]
   set physical [expr {(($logical & 1) << 18) | ($logical >> 1)}]
   set value [debug read $vram $physical]
   lappend got [expr {($value >> (($pixel & 1) ? 0 : 4)) & 15}]
  }
  if {$got ne [lindex $expected $row]} {
   puts stderr "CMMC pixel mismatch: cell $count, row $row at ($x,$y): $got expected [lindex $expected $row]"
   exit 1
   return
  }
 }
 set active 0
 incr count
}
proc cmmc_check::summary {args} {
 variable active; variable count; variable modes
 puts stderr "CMMC cells checked: $count; modes: $modes"
 if {$active || ![dict exists $modes 0] || ![dict exists $modes 1]} {
  puts stderr {CMMC validation incomplete}; exit 1
 }
}
proc cmmc_check::install {entry done} {
 variable vram
 foreach name [debug list] {
  if {[string match -nocase {*vram*} $name] && [regexp -nocase {v9990|gfx9000} $name]} {
   set vram $name; break
  }
 }
 if {![info exists vram]} {error {V9990 VRAM debugger missing}}
 debug set_bp $entry {[debug read memory 0x2F60] == 12} cmmc_check::enter
 debug set_bp $done {[debug read memory 0x2F60] == 12 && $cmmc_check::active} cmmc_check::leave
 trace add execution finish enter cmmc_check::summary
}
