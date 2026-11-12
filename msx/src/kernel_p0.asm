; Page-0 resident kernel. Lives in C64 pages that contain only translated
; 6502 code. Fixed region origins and include order keep entry points at the
; addresses expected by the game.
;
; Helpers called from translated code take HL = C64 address, A = value for
; writes, and return reads in L. They preserve A, F, BC and DE; HL (and IX
; where noted) may be clobbered.
	include "src/kernel/p0_interrupts.asm"

	org $0E00
region_mem_start:
	include "src/kernel/p0_vic_memory.asm"
	include "src/kernel/p0_c64_memory.asm"
	include "src/kernel/p0_sync_helpers.asm"
region_mem_end:
