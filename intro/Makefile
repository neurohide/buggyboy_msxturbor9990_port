OPENMSX ?= openmsx
MACHINE ?= Panasonic_FS-A1F

intro.rom: intro.asm data.inc
	z80asm intro.asm -o $@

data.inc: gen_data.py
	python3 gen_data.py

run: intro.rom
	$(OPENMSX) -machine $(MACHINE) -cart intro.rom

clean:
	rm -f intro.rom data.inc

.PHONY: run clean
