#!/usr/bin/env python3
"""Build the Buggy Boy MSX turbo R ROM: translate, assemble, slice, pack."""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BUILD = os.path.join(ROOT, 'build')
sys.path.insert(0, HERE)
from c64image import load_image  # noqa: E402

# region name -> (lowest allowed address, highest allowed end address)
KERNEL_REGIONS = {
    'im2': (0x27FF, 0x2900),
    'mem': (0x0E00, 0x1000),
    'k2': (0x8000, 0x8D00),
}
ROM_BANKS = 16      # 256K ASCII16


def labels(path):
    out = {}
    for line in open(path):
        m = re.match(r'(\w+):\s+equ\s+\$?([0-9A-Fa-f]+)h?', line)
        if m:
            out[m.group(1)] = int(m.group(2), 16)
    return out


LOOKUP_HASH = 0xF800
LOOKUP_SLOTS = 128


def build_lookup(mem, lab, nseg):
    """Hash table C64 address -> (segment, Z80 address) for indirect jumps and
    IRQ vectors: slot = (lo + 7*hi) & 127, linear probing, 6 bytes per slot."""
    segof = {}
    seg = None
    for l in open(os.path.join(BUILD, 'code.asm')):
        m = re.match(r'seg(\d+)_start:', l)
        if m:
            seg = int(m.group(1)) + 8
        m = re.match(r'T_([0-9A-F]{4}):', l)
        if m:
            segof[int(m.group(1), 16)] = seg
    targets = []
    for l in open(os.path.join(BUILD, 'dispatch.asm')):
        m = re.match(r'\tdw \$([0-9A-F]{4})$', l)
        if m and int(m.group(1), 16):
            targets.append(int(m.group(1), 16))
    table = [None] * LOOKUP_SLOTS
    for t in targets:
        h = ((t & 255) + 7 * (t >> 8)) & (LOOKUP_SLOTS - 1)
        while table[h] is not None and table[h] != t:
            h = (h + 1) & (LOOKUP_SLOTS - 1)
        table[h] = t
    if sum(1 for x in table if x is not None) > LOOKUP_SLOTS - 8:
        sys.exit('lookup hash table too full')
    for i, t in enumerate(table):
        a = LOOKUP_HASH + 6 * i
        if t is None:
            mem[a:a + 6] = bytes(6)
        else:
            z = lab['T_%04X' % t]
            mem[a:a + 6] = bytes([t & 255, t >> 8, segof[t], z & 255, z >> 8, 0])


def main():
    os.makedirs(BUILD, exist_ok=True)
    subprocess.check_call([sys.executable, os.path.join(HERE, 'translate.py'), BUILD])
    info = json.load(open(os.path.join(BUILD, 'translate.json')))
    nseg = len(info['segments'])
    if nseg > 4:
        sys.exit('too many code segments: %d' % nseg)
    binf = os.path.join(BUILD, 'main.bin')
    lblf = os.path.join(BUILD, 'main.lbl')
    r = subprocess.run(['z80asm', '-o', binf, '-L' + lblf, 'src/main.asm'], cwd=ROOT,
                       capture_output=True, text=True)
    if r.returncode or r.stderr.strip():
        sys.stderr.write(r.stderr)
        if r.returncode:
            sys.exit('assembly failed')
    lab = labels(lblf)
    data = open(binf, 'rb').read()
    # regions in source order with their lengths
    order = [('im2', 'region_im2_start', 'region_im2_end'),
             ('mem', 'region_mem_start', 'region_mem_end'),
             ('k2', 'region_k2_start', 'region_k2_end'),
             ('render', 'region_render_start', None)]
    for i in range(nseg):
        order.append(('seg%d' % i, 'seg%d_start' % i, None))
    order.append(('loader', 'loader_start', None))
    pos = 0
    chunks = {}
    for name, s, e in order:
        start = lab[s]
        end = lab[e] if e else (lab['NT'] if name == 'render' else 0x8000)
        n = end - start
        chunks[name] = (start, data[pos:pos + n])
        pos += n
        if name in KERNEL_REGIONS:
            lo, hi = KERNEL_REGIONS[name]
            print('%-6s %04X-%04X (%d bytes free)' % (name, start, end - 1, hi - end))
            if start < lo or end > hi:
                sys.exit('region %s out of bounds' % name)
        elif name.startswith('seg'):
            print('%-6s %d bytes' % (name, lab['%s_end' % name] - 0x4000))
    if pos != len(data):
        sys.exit('region size mismatch: %d vs %d' % (pos, len(data)))
    mem = bytearray(load_image())
    for name in ('im2', 'mem', 'k2'):
        start, b = chunks[name]
        mem[start:start + len(b)] = b
    build_lookup(mem, lab, nseg)
    # render segment: code + zeroed variable area
    rstart, rb = chunks['render']
    render = bytes(rb) + bytes(0x4000 - len(rb))
    banks = [chunks['loader'][1], bytes(mem[0x0000:0x4000]), bytes(mem[0x4000:0x8000]),
             bytes(mem[0x8000:0xC000]), bytes(mem[0xC000:0x10000]), render]
    for i in range(nseg):
        banks.append(chunks['seg%d' % i][1])
    for b in banks:
        assert len(b) == 0x4000, len(b)
    rom = b''.join(banks)
    rom += b'\xFF' * (ROM_BANKS * 0x4000 - len(rom))
    out = os.path.join(BUILD, 'buggyboy.rom')
    open(out, 'wb').write(rom)
    print('wrote', out, len(rom))


if __name__ == '__main__':
    main()
