#!/usr/bin/env python3
"""Generate an emulator differential probe for native road span transactions."""
from pathlib import Path
import sys

sys.path.insert(0, 'tools')
from build import labels
from symmap import load

lab = labels('build/main.lbl')
if not lab.get('ROAD_DIRECT'):
    raise SystemExit('Build with ROAD_DIRECT=1 first')
tables = load()
segment, entry = next((s, a) for s, rows in tables.items() if isinstance(s, int)
                      for a, name in rows if name == 'T_1289C')
general = next(s for s, rows in tables.items() if isinstance(s, int)
               for _, name in rows if name == 'T_289C')
cleanup = next((s, a) for s, rows in tables.items() if isinstance(s, int)
               for a, name in rows if name == 'T_35F9')
values = dict(lab, road_segment=segment, road_entry=entry, general_segment=general,
              cleanup_segment=cleanup[0], cleanup_entry=cleanup[1])
Path(sys.argv[1]).write_text('set ::road_labels {'+' '.join(f'{k} {v}' for k, v in values.items())+
                           '}\nsource test/road_direct.tcl\n')
