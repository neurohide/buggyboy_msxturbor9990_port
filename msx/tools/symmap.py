#!/usr/bin/env python3
"""Map Z80 (page-1 segment, PC) samples back to C64 addresses / kernel labels.
usage: symmap.py samples.txt   (lines: "<seg> <pc>" in hex)"""
import bisect
import glob
import os
import re
import sys
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEG_CODE = 8
SEG_RENDER = 12


def code_labels(path):
    out = set()
    for l in open(path):
        m = re.match(r'([A-Za-z_]\w*):(\s|$)', l)
        if m and ' equ' not in l:
            out.add(m.group(1))
    return out


def load():
    lab = {}
    for l in open(os.path.join(ROOT, 'build', 'main.lbl')):
        m = re.match(r'(\w+):\s+equ\s+\$?([0-9A-Fa-f]+)', l)
        if m:
            lab[m.group(1)] = int(m.group(2), 16)
    tables = {}
    sources = (
        [('k', os.path.join(ROOT, 'src', 'kernel_p0.asm'))]
        + [('k', f) for f in sorted(glob.glob(os.path.join(ROOT, 'src', 'kernel', 'p[02]_*.asm')))]
        + [('r', os.path.join(ROOT, 'src', 'render.asm'))]
        + [('l', os.path.join(ROOT, 'src', 'loader.asm'))]
    )
    for key, path in sources:
        names = code_labels(path)
        tables.setdefault(key, []).extend((lab[n], n) for n in names if n in lab)
    seg = None
    for l in open(os.path.join(ROOT, 'build', 'code.asm')):
        m = re.match(r'seg(\d+)_start:', l)
        if m:
            seg = int(m.group(1)) + SEG_CODE
        m = re.match(r'(T_[0-9A-F]{4}):', l)
        if m:
            tables.setdefault(seg, []).append((lab[m.group(1)], m.group(1)))
    for t in tables.values():
        t.sort()
    return tables


def lookup(t, pc):
    i = bisect.bisect_right(t, (pc, '~')) - 1
    return t[i][1] if i >= 0 else '?'


def name(tables, seg, pc):
    if 0x4000 <= pc < 0x8000:
        if seg == SEG_RENDER:
            return 'r:' + lookup(tables['r'], pc)
        if seg in tables:
            return lookup(tables[seg], pc)
        return 'p1?%02X:%04X' % (seg, pc)
    if 0x0E00 <= pc < 0x1000 or 0x27FF <= pc < 0x2900 or 0x8000 <= pc < 0x8D00:
        return lookup(tables['k'], pc)
    if 0x2700 <= pc < 0x27FF:
        return 'trampoline'
    return 'pc=%04X' % (pc & 0xFF00)


if __name__ == '__main__':
    tables = load()
    c = Counter()
    for l in open(sys.argv[1]):
        p = l.split()
        if len(p) >= 2:
            c[name(tables, int(p[0], 16), int(p[1], 16))] += 1
    for n, k in c.most_common(int(os.environ.get('TOP', 30))):
        print('%6d %s' % (k, n))
