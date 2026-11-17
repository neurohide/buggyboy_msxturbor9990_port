# Host-side counters: no ROM patches or emulated instructions added.
namespace eval race_metrics {
 variable labels $::race_metrics_labels
 variable out $::race_metrics_out
 variable scenario $::race_metrics_scenario
 variable active 0
 variable rendering 0
 variable render_depth 0
 variable irq_depth 0
 variable last [machine_info time]
 variable pending 0
 variable counters {}
 variable fields {renders render_s render_cpu_s irq_s irq_context_s irqs cells commands lmmc lmmv lmmm cmmc other copy_pixels captures capture_bytes local_records local_bytes recovery_calls collision_contacts}
 variable steering 0
 variable collision_seen 0
 variable impact_shot 0
 variable recovery_shot 0
 variable log [open "${out}_passes.csv" w]
 variable renderlog [open "${out}_renders.csv" w]
 variable events [open "${out}_events.csv" w]
 puts $log "pass,time,seconds,flips,[join $fields ,],progress,speed,velocity,steer,car_x,recovery,impact,jump,game_pending,joy"
 puts $renderlog {pass,start,seconds,cells,commands}
 puts $events {pass,time,event,value}
}
proc race_metrics::add {name {amount 1}} {
 variable counters
 if {![dict exists $counters $name]} {dict set counters $name 0}
 dict set counters $name [expr {[dict get $counters $name]+$amount}]
}
proc race_metrics::account {} {
 variable last; variable active; variable rendering; variable render_depth; variable irq_depth
 set now [machine_info time]
 set dt [expr {$now-$last}]
 if {$active} {
  if {$rendering} {
   add render_s $dt
   if {$irq_depth <= $render_depth} {add render_cpu_s $dt}
  }
  if {$irq_depth} {
   add irq_context_s $dt
   if {!$rendering || $irq_depth > $render_depth} {add irq_s $dt}
  }
 }
 set last $now
}
proc race_metrics::label {name} {variable labels; dict get $labels $name}
proc race_metrics::bp {name page segment action} {
 mapped_bp [label $name] $page $segment $action
}
proc race_metrics::mapped_bp {address page segment action} {
 set signature [dict get $::race_metrics_signatures ${segment}_$address]
 debug set_bp $address "\[debug read memory $page\] == $segment && \[debug read_block memory $address 8\] eq \[binary format H* $signature\]" $action
}
# Return breakpoints include RET/RETI execution. SP distinguishes recursive IRQs.
proc race_metrics::on_return {action} {
 variable pending
 incr pending
 set sp [reg sp]
 set pc [expr {[debug read memory $sp] | ([debug read memory [expr {$sp+1}]] << 8)}]
 set id [debug set_bp $pc "\[reg sp\] == [expr {($sp+2)&65535}]" [list race_metrics::returned $pending $action]]
 set ::race_metrics::return_$pending $id
}
proc race_metrics::returned {token action} {
 debug remove_bp [set ::race_metrics::return_$token]
 unset ::race_metrics::return_$token
 {*}$action
}
proc race_metrics::irq_enter {} {
 variable irq_depth; variable active
 account
 incr irq_depth
 if {$active} {add irqs}
 on_return race_metrics::irq_leave
}
proc race_metrics::irq_leave {} {variable irq_depth; account; incr irq_depth -1}
proc race_metrics::render_enter {} {
 variable rendering; variable render_depth; variable irq_depth; variable active
 variable render_start; variable render_cells; variable render_commands
 account
 if {$rendering} {error {Nested renderer}}
 set rendering 1
 set render_depth $irq_depth
 set render_start [machine_info time]
 set render_cells 0
 set render_commands 0
 if {$active} {add renders}
 on_return race_metrics::render_leave
}
proc race_metrics::render_leave {} {
 variable rendering; variable active; variable renderlog
 variable render_start; variable render_cells; variable render_commands
 account
 if {$active} {puts $renderlog "[expr {$::n+1}],$render_start,[expr {[machine_info time]-$render_start}],$render_cells,$render_commands"}
 set rendering 0
}
proc race_metrics::cell {} {
 variable active; variable render_cells
 if {$active} {add cells; incr render_cells}
}
proc race_metrics::command {op} {
 variable active; variable render_commands
 if {!$active} return
 add commands
 incr render_commands
 if {$op < 0} {set op [debug read memory [expr {[label cmdblk]+20}]]}
 switch $op {
  16 {add lmmc}
  32 {add lmmv}
  64 {
   add lmmm
   set a [expr {[label cmdblk]+8}]
   set nx [expr {[debug read memory $a]+256*[debug read memory [expr {$a+1}]]}]
   set ny [expr {[debug read memory [expr {$a+2}]]+256*[debug read memory [expr {$a+3}]]}]
   add copy_pixels [expr {$nx*$ny}]
  }
  80 {add cmmc}
  default {add other}
 }
}
proc race_metrics::capture {} {
 variable active
 if {$active} {add captures; add capture_bytes [expr {[label IRQ_SNAPSHOT] ? 45 : 56}]}
}
proc race_metrics::local_copy {} {
 variable active
 if {$active} {add local_records; add local_bytes 64}
}
# Read original C64 state independently of whichever mapper bank is visible.
proc race_metrics::c64 {address} {
 set segment [expr {4+($address>>14)}]
 set ram {1MB External RAM}
 if {![label MSX2PLUS]} {set ram {Main RAM}}
 debug read $ram [expr {$segment*16384+($address&16383)}]
}
proc race_metrics::event {name value} {
 variable events
 puts $events "[expr {$::n+1}],[machine_info time],$name,$value"
 flush $events
}
proc race_metrics::recovery {} {
 variable active; variable collision_seen; variable out
 if {!$active || ![c64 0x02c8]} return
 add recovery_calls
 if {!$collision_seen} {
  set collision_seen 1
  event collision_recovery [c64 0x02c8]
  screenshot "${out}_collision.png"
 }
}
proc race_metrics::contact {site} {
 variable active; variable collision_seen; variable out
 if {!$active} return
 if {$site eq "T_980C"} {
  if {[c64 0x0352] == 1} {event impact_animation [c64 0x004b]}
  return
 }
 add collision_contacts
 event collision_contact "$site:[reg c]:[c64 0x004b]"
 if {!$collision_seen} {
  set collision_seen 1
  screenshot "${out}_collision.png"
 }
}
proc race_metrics::boundary {args} {
 variable active; variable counters; variable fields; variable log; variable pass_start; variable last_flips
 variable collision_seen; variable impact_shot; variable recovery_shot; variable out
 account
 if {!$active} return
 set now [machine_info time]
 set row [list [expr {$::n+1}] $now [expr {$now-$pass_start}] [expr {$::flips-$last_flips}]]
 foreach name $fields {lappend row [expr {[dict exists $counters $name] ? [dict get $counters $name] : 0}]}
 lappend row [expr {256*[c64 0x6a]+[c64 0x6b]}]
 foreach address {0x0337 0x004b 0x02d4 0x1486 0x02c8 0x0352 0x02cd 0x02e8} {lappend row [c64 $address]}
 lappend row [debug read memory 0x2f69]
 puts $log [join $row ,]
 flush $log
 if {$collision_seen && !$impact_shot && ([c64 0x0352] || [c64 0x02c8])} {
  set impact_shot 1
  screenshot "${out}_impact.png"
 }
 if {$impact_shot && !$recovery_shot && ![c64 0x0352] && ![c64 0x02c8] && [c64 0x004b]} {
  set recovery_shot 1
  event recovered [c64 0x004b]
  screenshot "${out}_recovered.png"
 }
 set counters {}
 set pass_start $now
 set last_flips $::flips
}
proc race_metrics::inputs {args} {
 variable active; variable pass_start; variable last_flips; variable scenario; variable steering; variable out
 if {!$active} {
  account
  set active 1
  set pass_start [machine_info time]
  set last_flips $::flips
  event scenario $scenario
 }
 # Pass-indexed replay: input changes at the beginning of the named pass.
 set pass [expr {$::n+1}]
 set next 0
 if {$scenario eq "steering"} {
  if {($pass>=20 && $pass<30) || ($pass>=70 && $pass<80)} {set next 0x10}
  if {($pass>=30 && $pass<50) || ($pass>=80 && $pass<100)} {set next 0x80}
 } elseif {$scenario eq "collision" && $pass>=20 && $pass<100} {set next 0x80}
 if {$next != $steering} {
  keymatrixup 8 0x90
  if {$next} {keymatrixdown 8 $next}
  set steering $next
  event steering $next
 }
 if {$scenario ne "straight" && $pass in {30 50 80 100 160}} {screenshot "${out}_pass${pass}.png"}
}
proc race_metrics::finish {args} {
 variable log; variable renderlog; variable events; variable irq_depth; variable rendering
 close $log; close $renderlog; close $events
 puts stderr "Race metrics: IRQ depth $irq_depth, renderer active $rendering"
}
# Page 0 is fixed; all bank configurations share its IRQ entry.
debug set_bp [race_metrics::label k_int] {} race_metrics::irq_enter
race_metrics::bp render_frame 0x2f60 12 race_metrics::render_enter
race_metrics::bp dr_cell 0x2f60 12 race_metrics::cell
race_metrics::bp v_send_cmd 0x2f60 12 {race_metrics::command -1}
race_metrics::bp dr_next 0x2f60 12 {race_metrics::command 16}
race_metrics::bp dt_op 0x2f60 12 {race_metrics::command 80}
race_metrics::bp tl_fill 0x2f61 6 race_metrics::capture
race_metrics::bp tlb_copy 0x2f60 12 race_metrics::local_copy
race_metrics::bp tlb_cp 0x2f60 12 race_metrics::local_copy
lassign $::race_metrics_recovery recovery_segment recovery_address
race_metrics::mapped_bp $recovery_address 0x2f60 $recovery_segment race_metrics::recovery
foreach contact $::race_metrics_contacts {
 lassign $contact segment address site
 race_metrics::mapped_bp $address 0x2f60 $segment [list race_metrics::contact $site]
}
trace add execution race_pass enter race_metrics::boundary
trace add execution race_pass leave race_metrics::inputs
trace add execution finish enter race_metrics::finish
