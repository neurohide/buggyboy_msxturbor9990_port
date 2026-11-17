# Run span drawer and translated general drawer from identical state with
# interrupts masked during each pair. Compare logical bitmap and collision
# footprint inputs, then resume the span result. Differential time is not FPS.
namespace eval road_check {
 variable phase 0
 variable count 0
 variable returns {}
 variable pixel_rows 0
 variable pending {}
 variable general 0
 variable assumptions {}
 variable ram {1MB External RAM}
 variable regions {{0x4e 3} {0x55 1} {0xfb 2} {0x4d8 576} {0x3002 1} {0x3503 1}}
}
proc road_check::fail {message} {puts stderr "Road spans FAILED: $message"; exit 1; error $message}
proc road_check::entry_matches {name} {
 return [expr {[debug read_block memory [dict get $::road_labels ${name}_entry] 8] eq [binary format H* [dict get $::road_labels ${name}_signature]]}]
}
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
proc road_check::enter {{kind edge}} {
 variable phase; variable ram; variable pre; variable regs; variable sp; variable returns; variable iff
 variable operation; variable prelogical
 if {$phase || !$::course_ready} return
 # cur_p1 also remains stale during sound_frame calls outside the C64 IRQ
 # chain. Verify the mapped entry instruction, independent of mapper reads.
 if {$kind eq "cleanup"} {
  if {![entry_matches cleanup]} return
 } else {
  if {![entry_matches road]} return
 }
 set active [debug read memory 0x2fe1]
 if {$kind eq "cleanup" && !$active} return
 if {$kind eq "edge" && $active} {fail {previous span transaction was not checkpointed}}
 set operation $kind
 set iff [reg iff]
 reg iff 0
 set regs [registers]
 set pre [debug read_block $ram 0x10000 0x20000]
 if {$kind eq "cleanup"} {set prelogical [logical $pre]}
 set sp [reg sp]
 set ret [expr {[debug read memory $sp] | [debug read memory [expr {$sp+1}]]<<8}]
 if {$ret ni $returns} {
  lappend returns $ret
  debug set_bp $ret {$road_check::phase && [reg sp] == $road_check::sp+2} road_check::leave
 }
 set phase 1
 if {$kind eq "edge"} {arm_access_guard}
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
 variable operation; variable prelogical
 if {$phase == 1} {
  set post [debug read_block $ram 0x10000 0x20000]
  set post_regs [registers]
  if {[string range $pre 0x6000 0x7fff] ne [string range $post 0x6000 0x7fff]} {
   fail {specialized drawer wrote the VIC bitmap}
  }
  set result [logical $post]
  if {$operation eq "cleanup" && $expected ne $result} {
   fail {cleanup span publication differs from observed reads/writes}
  }
  set expected $result
  restore $pre $regs
  if {$operation eq "cleanup"} {
   debug write_block $ram 0x14000 $prelogical
   debug write memory 0x2fe1 0
  } else {
   set segment [dict get $::road_labels general_segment]
   debug write memory 0x2f60 $segment
   debug write ioports 253 $segment
   reg pc [dict get $::road_labels T_289C_g]
  }
  set phase 2
  return
 }
 set reference [debug read_block $ram 0x10000 0x20000]
 set bitmap [string range $reference 0x4000 0x7fff]
 if {$bitmap ne $expected} {
  binary scan $bitmap cu* a; binary scan $expected cu* b
  for {set i 0} {$i < 16384} {incr i} {
   if {[lindex $a $i] != [lindex $b $i]} {fail [format {bitmap $%04X native %02X reference %02X pair %d operation %s reads %s writes %s} [expr {$i+0x4000}] [lindex $b $i] [lindex $a $i] $count $operation $::road_check::reads $::road_check::writes]}
  }
 }
 foreach region $regions {
  lassign $region start length
  set end [expr {$start+$length-1}]
  if {[string range $post $start $end] ne [string range $reference $start $end]} {
   binary scan [string range $post $start $end] H* native
   binary scan [string range $reference $start $end] H* translated
   fail [format {collision/state region $%04X differs at pair %d operation %s native=%s reference=%s} $start $count $operation $native $translated]
  }
 }
 restore $post $post_regs
 reg iff $iff
 set phase 0
 incr count
 if {$count % 20 == 0} {puts stderr "Road spans: $count matched transactions"}
}
proc road_check::summary {args} {
 variable count; variable phase; variable pixel_rows; variable pending
 if {!$count || $phase || !$pixel_rows || [llength $pending]} {fail "incomplete coverage transactions=$count phase=$phase pixel_rows=$pixel_rows pending=[llength $pending] reads=$::road_check::reads writes=$::road_check::writes general=$::road_check::general flags=$::road_check::assumptions"}
 set status [lindex [lindex $args 0] 1]
 puts stderr "Road spans checks: status=$status, $count transactions, $pixel_rows V9990 rows, bitmap and collision inputs match"
}
proc road_check::general_enter {} {
 if {$::road_check::phase || !$::begun} return
 incr ::road_check::general
 set ::road_check::assumptions {}
 foreach a {0x0342 0x02bc 0x02b9 0x2fe0 0x0334 0x96e4 0x02ca} {
  lappend ::road_check::assumptions [debug read memory $a]
 }
}
proc road_check::word {label} {
 set a [dict get $::road_labels $label]
 return [expr {[debug read memory $a] | [debug read memory [expr {$a+1}]]<<8}]
}
proc road_check::palette_inputs {} {
 variable source_screen; variable source_cram
 if {([reg bc] >> 8) == 40} {set source_screen {}; set source_cram {}}
 lappend source_screen [debug read memory [reg hl]]
 lappend source_cram [debug read memory [reg de]]
}
proc road_check::pixels_begin {} {
 variable pending; variable ram; variable expected
 variable source_screen; variable source_cram
 if {![info exists expected]} return
 if {[debug read memory [dict get $::road_labels road_busy]]} {fail {renderer consumed unpublished road spans}}
 if {[llength $pending]} {fail {previous V9990 row was not checked}}
 set row [debug read memory [dict get $::road_labels cur_row]]
 set live [logical [debug read_block $ram 0x10000 0x20000]]
 for {set line 0} {$line < 8} {incr line} {
  for {set col 0} {$col < 40} {incr col} {
   set offset [expr {0x2000+$row*320+$col*8+$line}]
   if {[string index $live $offset] ne [string index $expected $offset]} {fail "unverified span update row=$row column=$col line=$line transactions=$::road_check::count"}
  }
 }
 set x [expr {[dict get $::road_labels SCREEN_X]+[debug read memory [dict get $::road_labels row_xoff]]}]
 set y [expr {[dict get $::road_labels CLEAN_Y]+[dict get $::road_labels SCREEN_Y]+8*$row}]
 binary scan $expected cu* bitmap
 set screen $source_screen
 set cram $source_cram
 if {[llength $screen] != 40 || [llength $cram] != 40} {fail {incomplete palette input capture}}
 set palettes {}
 for {set col 0} {$col < 40} {incr col} {
  set palette {0}
  foreach color [list [expr {[lindex $screen $col]>>4}] [expr {[lindex $screen $col]&15}] [expr {[lindex $cram $col]&15}]] {
   set folded [debug read memory [expr {[dict get $::road_labels col_fold]+$color}]]
   set slot [debug read memory [expr {[dict get $::road_labels slot_of]+$folded}]]
   if {!$slot} {set slot [dict get $::road_labels PAL_FIXED]}
   lappend palette $slot
  }
  lappend palettes $palette
 }
 binary scan [debug read_block memory [dict get $::road_labels rdv_colors] 160] cu* native_colors
 for {set col 0} {$col < 40} {incr col} {
  set actual [lrange $native_colors [expr {$col*4}] [expr {$col*4+3}]]
  if {$actual ne [lindex $palettes $col]} {fail "palette row=$row column=$col actual=$actual expected=[lindex $palettes $col] screen=[lindex $screen $col] cram=[lindex $cram $col] fslot=[binary encode hex [debug read_block memory [dict get $::road_labels fslot] 16]]"}
 }
 set rows {}
 for {set line 0} {$line < 8} {incr line} {
  set pixels {}
  for {set col 0} {$col < 40} {incr col} {
   set palette [lindex $palettes $col]
   set byte [lindex $bitmap [expr {0x2000+$row*320+$col*8+$line}]]
   foreach shift {6 4 2 0} {
    set color [lindex $palette [expr {($byte>>$shift)&3}]]
    lappend pixels $color $color $color
   }
  }
  lappend rows $pixels
 }
 set pending [list $x $y $rows]
}
proc road_check::pixels_finish {} {
 variable pending; variable pixel_rows
 if {![llength $pending]} return
 lassign $pending x y rows
 set line 0
 foreach pixels $rows {
  # B3 interleaves logical bytes across the two 256K VRAM banks.
  set base [expr {($y+$line)*128}]
  binary scan [debug read_block {Sunrise GFX9000 VRAM} $base 128] cu* even
  binary scan [debug read_block {Sunrise GFX9000 VRAM} [expr {$base+0x40000}] 128] cu* odd
  set raw {}
  foreach a $even b $odd {lappend raw $a $b}
  set p $x
  foreach want $pixels {
   set byte [lindex $raw [expr {$p/2}]]
   set got [expr {($byte >> (($p&1)?0:4))&15}]
   if {$got != $want} {fail "V9990 pixel x=$p y=[expr {$y+$line}] actual=$got expected=$want pass=$::n transactions=$::road_check::count verified_rows=$pixel_rows"}
   incr p
  }
  incr line
 }
 set pending {}
 incr pixel_rows
}
proc road_check::bitmap_access {} {
 set stack {}
 for {set a [reg sp]} {$a < [reg sp]+12} {incr a 2} {
  lappend stack [format %04X [expr {[debug read memory $a] | [debug read memory [expr {$a+1}]]<<8}]]
 }
 fail [format {bitmap access before checkpoint PC=$%04X HL=$%04X bank=%d pass=%d stack=%s} [reg pc] [reg hl] [debug read memory 0x2f60] $::n $stack]
}
proc road_check::arm_access_guard {} {
 if {[info exists ::road_check::guards]} return
 set ::road_check::guards {}
 foreach type {read_mem write_mem} {
  lappend ::road_check::guards [debug set_watchpoint $type {0xf180 0xffff} {[debug read memory 0x2fe1] && [debug read memory 0x2fb7] == 5 && [debug read memory 0x2f60] != 14} road_check::bitmap_access]
  lappend ::road_check::guards [debug set_watchpoint $type {0xb180 0xbfff} {[debug read memory 0x2fe1] && [debug read memory 0x2f61] == 5 && [debug read memory 0x2f60] != 14} road_check::bitmap_access]
 }
}
proc road_check::disarm_access_guard {} {
 if {![info exists ::road_check::guards]} return
 foreach guard $::road_check::guards {debug remove_watchpoint $guard}
 unset ::road_check::guards
}
proc road_check::cleanup_read {} {
 variable expected
 incr ::road_check::reads
 set address [expr {[reg ix]&0x3fff}]
 binary scan [string index $expected $address] cu want
 set got [expr {[reg hl]&255}]
 if {$got != $want} {fail [format {cleanup read $%04X actual %02X expected %02X} [reg ix] $got $want]}
}
proc road_check::cleanup_write {} {
 variable expected
 incr ::road_check::writes
 set address [expr {[reg ix]&0x3fff}]
 set expected [string replace $expected $address $address [binary format c [expr {[reg af]>>8}]]]
}
proc road_check::publication {} {
 variable expected; variable ram
 if {![info exists expected]} return
 if {[logical [debug read_block $ram 0x10000 0x20000]] ne $expected} {fail {published spans differ from verified drawer and cleanup accesses}}
}
set road_check::reads 0
set road_check::writes 0
# Audio temporarily maps the renderer without changing cur_p1. Main-game
# probes must check mapped instructions, where an audio PC can alias game code.
debug set_bp [dict get $::road_labels road_entry] {[road_check::entry_matches road]} road_check::enter
debug set_bp [dict get $::road_labels T_289C] {[debug read memory 0x2f60] == [dict get $::road_labels general_segment] && ![debug read memory 0x2fc4]} road_check::general_enter
debug set_bp [dict get $::road_labels cleanup_entry] {[road_check::entry_matches cleanup]} {road_check::enter cleanup}
debug set_bp [dict get $::road_labels rd_read_done] {$road_check::phase != 2 && [info exists ::road_check::expected] && [debug read memory 0x2f60] == 14} road_check::cleanup_read
debug set_bp [dict get $::road_labels rd_write_put] {$road_check::phase != 2 && [info exists ::road_check::expected] && [debug read memory 0x2f60] == 14} road_check::cleanup_write
debug set_bp [dict get $::road_labels rd_pop] {!$road_check::phase && [debug read memory 0x2f60] == 14 && [debug read memory 0x2fe1] && ![debug read memory 0x2fe3]} road_check::publication
debug set_bp [dict get $::road_labels rdv_palette] {[debug read memory 0x2f61] == 14 && [debug read memory [dict get $::road_labels rdv_palette]] == 0x7e} road_check::palette_inputs
debug set_bp [dict get $::road_labels rdv_border] {[debug read memory 0x2f61] == 14} road_check::pixels_begin
debug set_bp [dict get $::road_labels v_wait_done] {$road_check::pending ne {} && [debug read memory 0x2f60] == 12} road_check::pixels_finish
debug set_bp [dict get $::road_labels rd_checkpoint] {[debug read memory 0x2f60] == 14 && [debug read memory [dict get $::road_labels rd_checkpoint]] == 0xf5} road_check::disarm_access_guard
trace add execution finish enter road_check::summary
