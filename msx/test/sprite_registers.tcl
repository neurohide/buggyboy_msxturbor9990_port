# Optional first-race assertions for the native $1452 register-table copy.
# The reference is the C64 table layout and the routine's documented exit ABI.
namespace eval sprite_check {variable active 0; variable count 0; variable ram {Main RAM}}
proc sprite_check::bytes {space address size} {
 binary scan [debug read_block $space $address $size] cu* result
 return $result
}
proc sprite_check::enter {} {
 variable active; variable source; variable expected; variable dirty; variable ram
 variable changed; variable indexes
 if {$active} {error {Nested native sprite-register call}}
 set source [bytes memory 0x1486 32]
 set old [bytes memory 0x2F00 47]
 set expected $old
 for {set i 0} {$i < 8} {incr i} {
  lset expected [expr {2*$i}] [lindex $source $i]
  lset expected [expr {2*$i+1}] [lindex $source [expr {$i+8}]]
  lset expected [expr {0x27+$i}] [lindex $source [expr {$i+24}]]
 }
 foreach offset {0x1D 0x17 0x10} value [bytes memory 0x02E3 3] {
  lset expected $offset $value
 }
 set changed [debug read memory 0x2F67]
 if {$expected ne $old} {set changed 1}
 set dirty [debug read memory 0x2E1F]
 if {[bytes $ram 0x147F8 8] ne [lrange $source 16 23]} {
  set dirty [expr {$dirty | 128}]
 }
 set indexes [list [reg ix] [reg iy]]
 set active 1
}
proc sprite_check::leave {} {
 variable active; variable count; variable source; variable expected
 variable dirty; variable changed; variable indexes; variable ram
 if {!$active} {return}
 set a [debug read memory 0x02E5]
 set f [expr {$a & 0xA8}]
 if {!$a} {set f [expr {$f | 0x40}]}
 set parity 0
 for {set bit 0} {$bit < 8} {incr bit} {set parity [expr {$parity ^ (($a >> $bit) & 1)}]}
 if {!$parity} {set f [expr {$f | 4}]}
 if {[bytes memory 0x2F00 47] ne $expected ||
     [bytes $ram 0x147F8 8] ne [lrange $source 16 23] ||
     [debug read memory 0x2E1F] != $dirty ||
     [debug read memory 0x2F67] != $changed ||
     [reg bc] != 0x00FE || [reg de] != 0x00FF ||
     [reg af] != (($a << 8) | $f) ||
     [list [reg ix] [reg iy]] ne $indexes ||
     [debug read memory 0x2FB7] != 7} {
  puts stderr "Native sprite-register assertion failed at call $count"
  exit 1
 }
 set active 0
 incr count
}
proc sprite_check::summary {args} {
 variable count
 puts stderr "Native sprite-register calls checked: $count"
 if {!$count} {puts stderr {Native sprite-register validation did not execute}; exit 1}
}
proc sprite_check::install {segment entry leave} {
 variable ram
 if {[debug size $ram] < 0x14800} {set ram {1MB External RAM}}
 debug set_bp $entry "\[debug read memory 0x2F60\] == $segment" sprite_check::enter
 debug set_bp $leave "\[debug read memory 0x2F60\] == $segment" sprite_check::leave
 trace add execution finish enter sprite_check::summary
}
