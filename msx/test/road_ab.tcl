# A/B: at each road-drawer entry run native (NR_ab), save result, restore
# memory + registers, run the translated copy (T_1289C), compare.
set throttle off
if {[info exists ::env(AB_REPLAY)]} { source $::env(AB_REPLAY) } else {
after time 7 { keymatrixdown 8 0x01 }
after time 7.3 { keymatrixup 8 0x01 }
foreach t {9 11 13 15} { after time $t { keymatrixdown 8 0x01 }; after time [expr {$t+0.2}] { keymatrixup 8 0x01 } }
after time 20 { keymatrixdown 8 0x21 }
}
set ::ph 0; set ::gen 0; set ::rng 0; set ::n 0; set ::bad 0; set ::rets {}
set ::lg [open $::env(AB_LOG) w]
# regions: name base len (Main RAM offsets)
set ::reg {{zp4E 0x1004E 2} {zp50 0x10050 1} {zp55 0x10055 1} {zpFB 0x100FB 2} {tab 0x104D8 0x240} {dirty 0x12E80 0x80} {v3002 0x13002 1} {v3503 0x13503 1} {bmp 0x16000 0x2000}}
proc snap {} { set r {}; foreach g $::reg { lappend r [debug read_block "Main RAM" [lindex $g 1] [lindex $g 2]] }; return $r }
proc put {s} { foreach g $::reg b $s { debug write_block "Main RAM" [lindex $g 1] $b } }
proc enter {} {
  if {$::ph != 0 || [machine_info time] < 22} return
  # native's assumptions (translate.py SPEC_ASSUME minus what it handles)
  foreach {a k} {0x0342 z 0x02BC z 0x02B9 z 0x2FE0 n 0x0334 n 0x96E4 n 0x02CA nz} {
    set v [debug read memory $a]
    if {($k eq "z" && $v) || ($k eq "n" && $v < 128) || ($k eq "nz" && $v && $v < 128)} { debug write memory NRGC 0; incr ::gen; return }
  }
  set ::regs {}; foreach r {af bc de hl ix iy sp} { lappend ::regs $r [reg $r] }
  set ::sp0 [reg sp]
  set ret [expr {[debug read memory $::sp0] | ([debug read memory [expr {$::sp0+1}]] << 8)}]
  if {[lsearch $::rets $ret] < 0} { lappend ::rets $ret; debug set_bp $ret {$::ph != 0 && [reg sp] == $::sp0 + 2} { back } }
  if {[debug read memory 0x02D2]} { incr ::rng }
  set ::pre [snap]; set ::ph 1; reg pc NRAB
}
proc back {} {
  if {$::ph == 1} {
    set ::pa [snap]; set ::pa2 $::pa; put $::pre
    foreach {r v} $::regs { reg $r $v }
    set ::ph 2; reg pc T1289C; return
  }
  set pb [snap]; set ::ph 0; incr ::n
  foreach g $::reg a $::pa b $pb {
    if {$a ne $b} {
      incr ::bad
      binary scan $a cu* la; binary scan $b cu* lb; set k 0
      for {set i 0} {$i < [llength $la] && $k < 6} {incr i} {
        if {[lindex $la $i] != [lindex $lb $i]} { incr k; puts $::lg [format "%d %s +%04X native %02X transl %02X" $::n [lindex $g 0] $i [lindex $la $i] [lindex $lb $i]] }
      }
    }
  }
  if {$::n % 100 == 0} { puts $::lg "frames $::n bad $::bad"; flush $::lg }
  if {$::n >= 2000 || [machine_info time] > $::ab_end} { puts $::lg "done frames $::n bad $::bad general $::gen range $::rng"; close $::lg; exit }
}
debug set_bp T1289C {[debug read memory 0x2F60] == SEG} { enter }
set ::ab_end [expr {[info exists ::env(AB_REPLAY)] ? 140 : 95}]
after time [expr {$::ab_end + 25}] { puts $::lg "timeout frames $::n bad $::bad general $::gen range $::rng"; close $::lg; exit }
