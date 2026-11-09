#!/usr/bin/env python3
"""Attribute samples inside kernel helpers to their translated-code caller.
usage: profcaller.py samples [helper-prefix ...]   (samples: "<seg> <pc> <w0> <w1> <w2>")
The first stack word that lands on translated code ($4000-$7FFF, T_ label) is the caller."""
import sys
from collections import Counter, defaultdict
from symmap import load, name
t = load()
want = tuple(sys.argv[2:]) or ('k_',)
by = defaultdict(Counter)
tot = 0
for l in open(sys.argv[1]):
    p = l.split()
    if len(p) < 3:
        continue
    tot += 1
    seg, pc = int(p[0], 16), int(p[1], 16)
    n = name(t, seg, pc)
    if not n.startswith(want) and not any(n.startswith(w) for w in ('vwr_', 'gwr_', 'grd_')):
        continue
    for w in p[2:]:
        a = int(w, 16)
        if 0x4000 <= a < 0x8000:
            c = name(t, seg, a)
            if c.startswith('T_'):
                by[n][c] += 1
                break
    else:
        by[n]['?'] += 1
for n, c in sorted(by.items(), key=lambda x: -sum(x[1].values())):
    s = sum(c.values())
    print('%-12s %5.1f%%  ' % (n, 100.0 * s / tot) + ' '.join('%s:%d' % kv for kv in c.most_common(8)))
