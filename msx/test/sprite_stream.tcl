# Compare every newly uploaded sprite with a software expansion of its
# source bytes and nibble tables. Check after v_wait, before the next command.
namespace eval stream_check {
 variable active 0
 variable count 0
 variable modes [dict create]
 variable source_address 0
 variable source_captures 0
}
proc stream_check::capture {} {
 variable source_address; variable source_captures
 if {[debug read_block memory $source_address 63] ne
     [debug read_block memory [expr {[reg hl]-63}] 63]} {
  puts stderr {Sprite source snapshot differs from live bitmap}
  exit 1
 }
 incr source_captures
}
proc stream_check::bytes {space address size} {
 binary scan [debug read_block $space $address $size] cu* result
 return $result
}
proc stream_check::enter {} {
 variable active; variable expected; variable x; variable y; variable height
 variable modes; variable source_address
 if {$active} {error {Sprite upload was not checked before the next upload}}
 set base 0x7FD0
 set flags [debug read memory [expr {$base+11}]]
 dict incr modes [expr {$flags & 6}]
 set pointer [debug read memory [expr {$base+10}]]
 set address [expr {$source_address ? $source_address : 0x8000+64*$pointer}]
 set source [bytes memory $address 63]
 set expanded [expr {($flags & 2) != 0}]
 set size [expr {$expanded ? 6 : 3}]
 set stride [expr {$expanded ? 8 : 4}]
 set table [bytes memory [expr {$expanded ? 0x6780 : 0x6700}] [expr {16*$stride}]]
 set expected {}
 for {set row 0} {$row < 21} {incr row} {
  set pixels {}
  foreach value [lrange $source [expr {3*$row}] [expr {3*$row+2}]] {
   foreach nibble [list [expr {$value >> 4}] [expr {$value & 15}]] {
    set first [expr {$nibble*$stride}]
    lappend pixels {*}[lrange $table $first [expr {$first+$size-1}]]
   }
  }
  lappend expected $pixels
  if {$flags & 4} {lappend expected $pixels}
 }
 lassign [bytes memory 0x7F8A 4] xl xh yl yh
 set x [expr {$xl+256*$xh}]
 set y [expr {$yl+256*$yh}]
 set height [llength $expected]
 set active 1
}
proc stream_check::leave {} {
 variable active; variable expected; variable x; variable y; variable height
 variable count; variable vram
 if {!$active} {return}
 for {set row 0} {$row < $height} {incr row} {
  set want [lindex $expected $row]
  # B3 interleaves consecutive bytes between the two 256 KB banks.
  # Match openMSX V9990VRAM::transformBx, rather than reading raw RAM linearly.
  set address [expr {(256*($y+$row)+$x/2) >> 1}]
  set size [expr {[llength $want]/2}]
  set even [bytes $vram $address $size]
  set odd [bytes $vram [expr {$address+0x40000}] $size]
  set got {}
  foreach a $even b $odd {lappend got $a $b}
  if {$got ne $want} {
   puts stderr "Sprite-stream validation failed: upload $count, row $row, ($x,$y)"
   exit 1
   return
  }
 }
 set active 0
 incr count
}
proc stream_check::summary {args} {
 variable active; variable count; variable modes; variable source_captures
 variable source_address
 puts stderr "Sprite uploads checked: $count; expansion flags: $modes; source snapshots: $source_captures"
 if {$active || !$count} {puts stderr {Sprite-stream validation incomplete}; exit 1}
 if {$source_address && $source_captures != $count} {puts stderr {Sprite source snapshot validation incomplete}; exit 1}
}
proc stream_check::install {entries wait_done {snapshot 0} {captured 0}} {
 variable vram
 variable source_address
 set source_address $snapshot
 if {$snapshot} {debug set_bp $captured {[debug read memory 0x2F60] == 12} stream_check::capture}
 foreach name [debug list] {
  if {[string match -nocase {*vram*} $name] &&
      [regexp -nocase {v9990|gfx9000} $name]} {set vram $name; break}
 }
 if {![info exists vram]} {error "V9990 VRAM debugger missing: [debug list]"}
 foreach entry $entries {
  debug set_bp $entry {[debug read memory 0x2F60] == 12} stream_check::enter
 }
 debug set_bp $wait_done {[debug read memory 0x2F60] == 12 && $stream_check::active} stream_check::leave
 trace add execution finish enter stream_check::summary
}
