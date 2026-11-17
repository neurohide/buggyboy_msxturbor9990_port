; Buggy Boy for MSX2+ + V9990: top-level assembly file.
; Output is a sequence of regions; tools/build.py slices them into
; memory images using the region_* labels.
	include "build/config.inc"
	include "src/defs.inc"
	include "src/kernel_p0.asm"
	include "src/kernel_p2.asm"
	include "src/render.asm"
	include "build/code.asm"
	if ROAD_DIRECT
	include "src/road/cpu.asm"
	include "src/road/vdp.asm"
	endif
	include "src/loader.asm"
