#!/usr/bin/env python3
"""Generate live keyboard/course/audio checks for production or differential ROMs."""
import re
import sys
from pathlib import Path
root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root/'tools'))
from symmap import load
labels = {m[1]: int(m[2], 16) for line in (root/'build/main.lbl').read_text().splitlines()
          if (m := re.match(r'(\w+):\s+equ\s+\$([0-9a-fA-F]+)', line))}
segment, address = next((s, a) for s, values in load().items() if isinstance(s, int)
                        for a, name in values if name == 'T_11C5')
settings = dict(entry=address, segment=segment, sound=labels['sound_frame'],
                input=labels['read_input'], frame=labels['frame_count'], irq=labels['in_irq'])
source = 'set ::irq_live_labels {' + ' '.join(f'{k} {v}' for k, v in settings.items()) + '}\n'
source += (root/'test/irq_live.tcl').read_text()
Path(sys.argv[1]).write_text(source)
