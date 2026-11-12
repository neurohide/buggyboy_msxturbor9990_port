; Page-2 kernel, in the $8000-$8CFF code hole of C64 block 2.  Only runs
; while SEG_C2 is mapped in page 2 (always true for translated code).
;
; Keep these includes in address order: build.py slices this as one region.
	org $8000
region_k2_start:
	include "src/kernel/p2_startup.asm"
	include "src/kernel/p2_calls.asm"
	include "src/kernel/p2_interrupts.asm"
	include "src/kernel/p2_io_read.asm"
	include "src/kernel/p2_io_write.asm"
	include "src/kernel/p2_raster_irq.asm"
	include "src/kernel/p2_v9990.asm"
	include "src/kernel/p2_input.asm"
	include "src/kernel/p2_audio.asm"
	include "build/dispatch.asm"
region_k2_end:
