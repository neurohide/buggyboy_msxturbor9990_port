# Run span drawer and translated general drawer from identical state with
# interrupts masked during each pair. Compare logical bitmap and collision
# footprint inputs, then resume the span result. Differential time is not FPS.
namespace eval road_check {
 variable phase 0
 variable count 0
 variable returns {}
 variable ram {1MB External RAM}
 variable regions {{0x4e 3} {0x55 1} {0xfb 2} {0x4d8 576} {0x3002 1} {0x3503 1}}
}
proc road_check::fail {message} {puts stderr "Road spans FAILED: $message"; exit 1; error $message}
proc road_check::registers {} {
 set result {}
 foreach name {af bc de hl ix iy sp pc iff} {lappend result $name [reg $name]}
 return $result
}
proc road_check::restore {memory registers} {
 variable ram
 debug write_block $ram 0x10000 $memory
 foreach {name value} $registers {reg $name $value}
 foreach {port address} {253 0x2f60 254 0x2f61 255 0x2fb7} {
  debug write ioports $port [debug read $ram [expr {0x10000+$address}]]
 }
}
proc road_check::enter {} {
 variable phase; variable ram; variable pre; variable regs; variable sp; variable returns; variable iff
 if {$phase || !$::begun} return
 if {[debug read memory 0x2fe1]} {fail {previous span transaction was not checkpointed}}
 set iff [reg iff]
 reg iff 0
 set regs [registers]
 set pre [debug read_block $ram 0x10000 0x20000]
 set sp [reg sp]
 set ret [expr {[debug read memory $sp] | [debug read memory [expr {$sp+1}]]<<8}]
 if {$ret ni $returns} {
  lappend returns $ret
  debug set_bp $ret {$road_check::phase && [reg sp] == $road_check::sp+2} road_check::leave
 }
 set phase 1
}
proc road_check::logical {memory} {
 variable ram
 set bytes [string range $memory 0x4000 0x7fff]
 set raw [debug read_block $ram 0x3a000 7680]
 binary scan $raw cu* records
 for {set line 0} {$line < 96} {incr line} {
  set column 0
  set index [expr {$line*80}]
  while {$column < 40} {
   set end [lindex $records $index]; incr index
   set value [lindex $records $index]; incr index
   if {$end <= $column || $end > 40} {fail "invalid span line=$line column=$column end=$end"}
   for {} {$column < $end} {incr column} {
    set address [expr {0x3180+($line/8)*320+($line&7)+8*$column}]
    if {$address < 0x4000} {
     set bytes [string replace $bytes $address $address [binary format c $value]]
    }
   }
  }
 }
 return $bytes
}
proc road_check::leave {} {
 variable phase; variable ram; variable pre; variable regs; variable post; variable post_regs
 variable expected; variable count; variable regions; variable iff
 if {$phase == 1} {
  set post [debug read_block $ram 0x10000 0x20000]
  set post_regs [registers]
  if {[string range $pre 0x6000 0x7fff] ne [string range $post 0x6000 0x7fff]} {
   fail {specialized drawer wrote the VIC bitmap}
  }
  set expected [logical $post]
  restore $pre $regs
  set segment [dict get $::road_labels general_segment]
  debug write memory 0x2f60 $segment
  debug write ioports 253 $segment
  reg pc [dict get $::road_labels T_289C_g]
  set phase 2
  return
 }
 set reference [debug read_block $ram 0x10000 0x20000]
 set bitmap [string range $reference 0x4000 0x7fff]
 if {$bitmap ne $expected} {
  binary scan $bitmap cu* a; binary scan $expected cu* b
  for {set i 0} {$i < 16384} {incr i} {
   if {[lindex $a $i] != [lindex $b $i]} {fail [format {bitmap $%04X native %02X reference %02X pair %d} [expr {$i+0x4000}] [lindex $b $i] [lindex $a $i] $count]}
  }
 }
 foreach region $regions {
  lassign $region start length
  set end [expr {$start+$length-1}]
  if {[string range $post $start $end] ne [string range $reference $start $end]} {
   fail [format {collision/state region $%04X differs at pair %d} $start $count]
  }
 }
 restore $post $post_regs
 reg iff $iff
 set phase 0
 incr count
 if {$count % 20 == 0} {puts stderr "Road spans: $count matched transactions"}
}
proc road_check::summary {args} {
 variable count; variable phase
 if {!$count || $phase} {fail {no completed differential coverage}}
 puts stderr "Road spans verification passed: $count transactions, bitmap and collision inputs match"
}
debug set_bp [dict get $::road_labels road_entry] {[debug read memory 0x2f60] == [dict get $::road_labels road_segment]} road_check::enter
trace add execution finish enter road_check::summary
