; VIC-II -> V9990 renderer.  Lives in its own mapper segment (SEG_RENDER),
; mapped into page 1 and called once per frame from the V9990 vblank
; interrupt with interrupts enabled (C64 raster IRQs may nest).
;
; V9990 B3 mode, 512x212, 4 bpp.  One C64 multicolour pixel becomes three
; V9990 pixels (one hires pixel 1.5), so the 320 pixel C64 screen is 480
; pixels wide, which matches the C64's pixel aspect closely.
;
;   y 0..211     display
;   y 256..467   clean playfield (no sprites); dirty cells are drawn here
;                and copied to the display, sprites are erased from here
;   y 512..      sprite shape cache, 7 slots of 72x42 per row
;
; While rendering, the VIC bank is mapped in page 2: C64 $4000 = Z80 $8000.

	org $4000
region_render_start:
	jp render_frame

; ---------------------------------------------------------------- variables
; Keep these includes in address order: build.py slices this as one region.
	include "src/render/state.inc"
	include "src/render/frame.asm"
	include "src/render/rows.asm"
	include "src/render/dirty.asm"
	include "src/render/draw.asm"
	include "src/render/colors.asm"
	include "src/render/pixels.asm"
	include "src/render/commands.asm"
	include "src/render/sprites.asm"
	include "src/render/tables.asm"

region_render_end:
	defs NT-region_render_end,0
