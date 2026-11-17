#!/usr/bin/env python3
"""Generate differential race IRQ / sparse snapshot checks for an IRQ_NATIVE=ab ROM.

Run: IRQ_NATIVE=ab IRQ_SNAPSHOT=1 python3 msx/tools/build.py
     python3 msx/test/irq_ab.py /tmp/bb_irq_checks.tcl
     IRQ_AB_SCRIPT=/tmp/bb_irq_checks.tcl sh msx/test/first_race.sh /tmp/bb_irq_ab 240
Comparison replays native then translated from identical physical RAM/registers.
Only dead Z80 stack bytes, helper scratch, and address-lookup caches are excluded;
game memory, dirty flags, VIC/SID state, input, counters and mapper state are exact.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
labels = {m[1]: int(m[2], 16) for line in (root/'build/main.lbl').read_text().splitlines()
          if (m := re.match(r'(\w+):\s+equ\s+\$([0-9A-Fa-f]+)', line))}
segments = {}
for line in (root/'build/code.asm').read_text().splitlines():
    if m := re.match(r'seg(\d+)_start:', line):
        segment = int(m[1]) + 8
    if m := re.match(r'T_([0-9A-F]+):', line):
        segments[m[1]] = segment
source = (root/'test/irq_ab.tcl').read_text()
entries = ' '.join(f'{{{a} {segments[a]} {labels["T_"+a]} {labels["NIRQ_AB_"+a]}}}'
                   for a in ('10E3', '11C5', '134C', '141A'))
source += f'\nirq_ab::install {{{entries}}} {labels["tl_fill"]}\n'
source += f'debug set_bp {labels["k_escape"]} {{$irq_ab::phase}} {{irq_ab::leave escape}}\n'
for address in ('1577', 'B4A2', 'B62E', '9BF7', '9A2A', '1BBF', '9A95',
                '9B60', '251F', 'B781', 'C800', 'C80C', 'C812', 'C809',
                'C80F', 'EF21', '0720', '1452'):
    source += (f'debug set_bp {labels["T_"+address]} '
               f'{{[debug read memory 0x2F60] == {segments[address]}}} '
               f'{{irq_ab::call {address}}}\n')
Path(sys.argv[1]).write_text(source)
