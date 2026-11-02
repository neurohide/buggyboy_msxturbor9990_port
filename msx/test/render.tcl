# Run with: openmsx -machine Panasonic_FS-A1GT -cart msx/build/buggyboy.rom \
#   -romtype ASCII16 -script msx/test/render.tcl
set throttle off
set ::root [file normalize [file join [file dirname [info script]] ..]]
set f [open [file join $::root build main.lbl]]
while {[gets $f line] >= 0} {
    if {[regexp {^(\w+):\s+equ \$([0-9a-fA-F]+)} $line -> name value]} {
        set ::label($name) [scan $value %x]
    }
}
close $f

proc check {condition message} {
    if {![uplevel 1 [list expr $condition]]} { error $message }
}
proc byte {address value} { debug write memory $address [expr {$value & 255}] }
proc word {address value} {
    byte $address $value
    byte [expr {$address + 1}] [expr {$value >> 8}]
}
proc mem {address} { debug read memory $address }
proc page {number segment} {
    debug write ioports [expr {0xFC + $number}] $segment
    switch $number {
        1 { byte 0x2F60 $segment }
        2 { byte 0x2F61 $segment }
        3 { byte 0x2FB7 $segment }
    }
}
proc invoke {name callback} {
    set ::callback $callback
    reg sp 0x3600
    word 0x3600 0x3006
    byte 0x3001 0xF3
    byte 0x3002 0xC3
    word 0x3003 $::label($name)
    # Let the VDP finish its queued final VRAM write before checking memory.
    for {set a 0x3006} {$a < 0x3016} {incr a} { byte $a 0 }
    byte 0x3016 0xC3
    word 0x3017 0x3000
    reg pc 0x3001
    debug cont
}
proc guard {script} {
    if {[catch {uplevel #0 $script} message options]} {
        puts stderr "FAIL: $message"
        puts stderr [dict get $options -errorinfo]
        exit 1
    }
}

debug set_bp 0x3000 {$::testing} {
    debug break
    guard $::callback
}
set ::testing false
after time 7 { keymatrixdown 8 0x01 }
after time 7.3 { keymatrixup 8 0x01 }
after time 10 {
    guard {
        debug break
        check {[get_active_cpu] eq "r800"} "R800 is not active"
        check {([debug read {VDP regs} 0] & 0x0E) == 0x0A} "Not SCREEN 7"
        page 1 12
        byte 0x2F60 12
        set ::testing true
        set ::damage_case 0
        damage_next
    }
}

proc damage_next {} {
    if {$::damage_case == 4} { framebuffer_start; return }
    foreach {y x count} [lindex {{0 0 256} {63 127 2} {64 240 16} {211 17 1}} $::damage_case] {}
    set ::damage_y $y
    set ::damage_x $x
    set ::damage_count $count
    for {set i 0} {$i < 424} {incr i} { byte [expr {$::label(DAMAGE) + $i}] 0 }
    reg hl $y
    reg a $x
    reg b [expr {$count & 255}]
    invoke damage_mark damage_check
}
proc damage_check {} {
    set expected 0
    for {set i [expr {$::damage_x / 16}]} {$i <= ($::damage_x + $::damage_count - 1) / 16} {incr i} {
        set expected [expr {$expected | (1 << $i)}]
    }
    for {set y 0} {$y < 212} {incr y} {
        set a [expr {$::label(DAMAGE) + 2 * $y}]
        set actual [expr {[mem $a] | ([mem [expr {$a + 1}]] << 8)}]
        check {$actual == ($y == $::damage_y ? $expected : 0)} "Wrong damage mask on line $y"
    }
    incr ::damage_case
    damage_next
}
proc framebuffer_start {} {
    set ::fb_case 0
    framebuffer_next
}
proc framebuffer_next {} {
    if {$::fb_case == 4} { sprite_changes_start; return }
    set y [lindex {0 63 64 211} $::fb_case]
    set ::fb_y $y
    page 3 13
    for {set i 0} {$i < 16} {incr i} { byte [expr {$::label(BUF) + $i}] [expr {$i + 32}] }
    reg hl $y
    reg de $::label(BUF)
    reg a 240
    reg b 16
    invoke framebuffer_write framebuffer_check
}
proc framebuffer_check {} {
    check {[mem 0x2F61] == 5} "VIC mapping not restored"
    page 2 [expr {$::fb_y / 64}]
    set a [expr {0x8000 + ($::fb_y % 64) * 256 + 240}]
    for {set i 0} {$i < 16} {incr i} {
        check {[mem [expr {$a + $i}]] == $i + 32} "Clean bitmap write mismatch"
    }
    incr ::fb_case
    framebuffer_next
}
proc sprite_changes_start {} {
    page 3 13
    for {set i 0} {$i < 424} {incr i} { byte [expr {$::label(DAMAGE) + $i}] 0 }
    foreach name {DRAWN OLD_DRAWN} {
        set a $::label($name)
        foreach value {40 0 100 24 0 2 0 0} {
            byte $a $value
            incr a
        }
    }
    foreach name {SP_SOURCE OLD_SOURCE} {
        byte $::label($name) 0
        byte [expr {$::label($name) + 1}] 0
    }
    foreach name {SCACHE OLD_KEY} {
        for {set i 0} {$i < 5} {incr i} { byte [expr {$::label($name) + $i}] 0 }
    }
    byte $::label(VDW) 0
    byte $::label(old_spr_n) 1
    byte $::label(spr_n) 1
    invoke sprite_changes sprite_unchanged_check
}
proc sprite_unchanged_check {} {
    for {set i 0} {$i < 424} {incr i} {
        check {[mem [expr {$::label(DAMAGE) + $i}]] == 0} "Unchanged sprite damaged the display"
    }
    word $::label(DRAWN) 80
    invoke sprite_changes sprite_moved_check
}
proc sprite_moved_check {} {
    for {set y 0} {$y < 212} {incr y} {
        set a [expr {$::label(DAMAGE) + 2 * $y}]
        set value [expr {[mem $a] | ([mem [expr {$a + 1}]] << 8)}]
        check {$value == (($y == 100 || $y == 101) ? 14 : 0)} "Wrong old/new sprite damage at line $y"
    }
    compose_start
}
proc compose_start {} {
    set ::compose_case 0
    compose_next
}
proc compose_next {} {
    if {$::compose_case == 288} { upload_start; return }
    set ::sx [expr {$::compose_case & 1}]
    set ::dx [expr {40 + (($::compose_case >> 1) & 1)}]
    set ::width [expr {1 + ($::compose_case >> 2)}]
    set slot [lindex {0 7 8 15} [expr {($::compose_case / 4) % 4}]]
    set row [expr {($::compose_case & 4) ? 41 : 0}]
    set ::pixels {}
    for {set i 0} {$i < 80} {incr i} { lappend ::pixels [expr {($i % 3) == 0 ? 0 : ($i % 15) + 1}] }
    page 3 [expr {14 + $slot / 8}]
    for {set i 0} {$i < 40} {incr i} {
        byte [expr {0xC000 + ($slot % 8) * 2048 + $row * 40 + $i}] [expr {([lindex $::pixels [expr {2 * $i}]] << 4) | [lindex $::pixels [expr {2 * $i + 1}]]}]
    }
    for {set i 0} {$i < 256} {incr i} { byte [expr {$::label(BUF) + $i}] 0xAB }
    word $::label(blit_dst) 0
    byte $::label(flush_sprite) 0
    byte $::label(SP_SOURCE) $::sx
    byte [expr {$::label(SP_SOURCE) + 1}] $row
    set a $::label(DRAWN)
    word $a $::dx
    byte [expr {$a + 2}] 0
    byte [expr {$a + 3}] $::width
    byte [expr {$a + 7}] $slot
    reg iy $a
    reg a 0
    invoke compose_sprite compose_check
}
proc compose_check {} {
    for {set x 0} {$x < 512} {incr x} {
        set expected [expr {($x & 1) ? 11 : 10}]
        if {$x >= $::dx && $x < $::dx + $::width} {
            set p [lindex $::pixels [expr {$::sx + $x - $::dx}]]
            if {$p != 0} { set expected $p }
        }
        set b [mem [expr {$::label(BUF) + $x / 2}]]
        set actual [expr {($x & 1) ? ($b & 15) : ($b >> 4)}]
        check {$actual == $expected} "Composition case $::compose_case pixel $x: $actual != $expected"
    }
    incr ::compose_case
    compose_next
}
proc upload_start {} {
    set ::upload_case 0
    upload_next
}
proc upload_next {} {
    if {$::upload_case == 2} {
        flush_start
        return
    }
    set ::upload_size [lindex {16 256} $::upload_case]
    reg hl 210
    reg a 0
    invoke vram_wr upload_send
}
proc upload_send {} {
    for {set i 0} {$i < 256} {incr i} { byte [expr {$::label(BUF) + $i}] $i }
    reg hl $::label(BUF)
    reg b [expr {$::upload_size & 255}]
    reg c 0x98
    invoke vram_upload upload_check
}
proc upload_check {} {
    for {set i 0} {$i < $::upload_size} {incr i} {
        set address [expr {210 * 256 + $i}]
        check {[debug read VRAM $address] == $i} "VRAM upload mismatch at byte $i"
    }
    incr ::upload_case
    upload_next
}
proc flush_start {} {
    byte $::label(spr_n) 0
    for {set i 0} {$i < 424} {incr i} { byte [expr {$::label(DAMAGE) + $i}] 0 }
    word [expr {$::label(DAMAGE) + 128}] 5
    page 2 1
    for {set i 0} {$i < 256} {incr i} {
        byte [expr {0x8000 + $i}] $i
        debug write VRAM [expr {64 * 256 + $i}] 0xEE
    }
    invoke flush_damage flush_check
}
proc flush_check {} {
    for {set i 0} {$i < 256} {incr i} {
        set expected [expr {($i < 16 || ($i >= 32 && $i < 48)) ? $i : 0xEE}]
        check {[debug read VRAM [expr {64 * 256 + $i}]] == $expected} "Sparse upload touched the wrong span at byte $i"
    }
    puts stderr "PASS: R800, SCREEN 7, damage/static-sprite tracking, mapper boundaries, 288 transparency/alignment/cache cases, VRAM/sparse uploads"
    exit
}
after time 30 { puts stderr "FAIL: renderer regression timed out"; exit 1 }
