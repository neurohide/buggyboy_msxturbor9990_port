; Buggy Boy for MSX turbo R + V9990: top-level assembly file.
; Output is a sequence of regions; tools/build.py slices them into
; memory images using the region_* labels.
	include "src/defs.inc"
	include "src/kernel_p0.asm"
	include "src/kernel_p2.asm"
	include "src/render.asm"
	include "build/code.asm"
	include "src/loader.asm"
