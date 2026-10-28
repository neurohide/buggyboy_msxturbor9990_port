#!/usr/bin/env python3
"""Print PC samples in time order with symbol names, collapsing repeats."""
import sys
from symmap import load, name
tables = load()
prev = None; n = 0; t = 0
for l in open(sys.argv[1]):
    p = l.split()
    if len(p) < 2:
        continue
    s = name(tables, int(p[0], 16), int(p[1], 16))
    if s != prev:
        if prev is not None:
            print('%5d %-20s x%d' % (t - n, prev, n))
        prev, n = s, 0
    n += 1; t += 1
print('%5d %-20s x%d' % (t - n, prev, n))
