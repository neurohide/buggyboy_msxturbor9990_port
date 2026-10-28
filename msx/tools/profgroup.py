#!/usr/bin/env python3
"""Group PC samples: game code / kernel helpers / renderer / interrupt / idle."""
import sys
from collections import Counter
from symmap import load, name
t = load()
g = Counter(); top = Counter()
for l in open(sys.argv[1]):
    p = l.split()
    if len(p) < 2:
        continue
    n = name(t, int(p[0], 16), int(p[1], 16))
    if n.startswith('r:'):
        k = 'renderer'
    elif n.startswith('T_'):
        k = 'game'
        top[n] += 1
    elif n in ('k_int', 'int_dispatch', 'int_hline', 'int_vblank', 'tl_snapshot', 'tl_fill',
               'tls_room', 'tls_b0', 'k_callc64', 'k_lookup', 'klu_loop', 'klu_next', 'klu_found',
               'read_input', 'k_vcopy8') or n.startswith(('ri', 'sf_', 'sdp_', 'se_', 'sid_', 'psg', 'm44', 'env_', 'div3', 'sfb')):
        k = 'irq/sound/input'
    else:
        k = 'kernel:' + n
    g[k] += 1
tot = sum(g.values())
kern = sum(v for k, v in g.items() if k.startswith('kernel:'))
print('total', tot)
for k in ('game', 'renderer', 'irq/sound/input'):
    print('%-16s %5.1f%%' % (k, 100.0 * g[k] / tot))
print('%-16s %5.1f%%' % ('kernel helpers', 100.0 * kern / tot))
for k, v in sorted(((k, v) for k, v in g.items() if k.startswith('kernel:')), key=lambda x: -x[1])[:12]:
    print('   %-24s %5.1f%%' % (k[7:], 100.0 * v / tot))
print('top game code:', ', '.join('%s:%d' % kv for kv in top.most_common(12)))
