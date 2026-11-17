#!/usr/bin/env python3
"""Build the Buggy Boy MSX2+ / V9990 ROM: translate, assemble, slice, pack."""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BUILD = os.path.join(ROOT, 'build')
INTRO = os.path.join(os.path.dirname(ROOT), 'intro')
sys.path.insert(0, HERE)
from c64image import load_image  # noqa: E402

# region name -> (lowest allowed address, highest allowed end address)
KERNEL_REGIONS = {
    'im2': (0x27FF, 0x2900),
    'mem': (0x0E00, 0x1000),
    'k2': (0x8000, 0x8DDF),     # $8CF2-$8DDE: 6502 code only
}
ROM_BANKS = 16      # 256K ASCII16
INTRO_BANK = 15     # must match src/loader.asm


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
    msx2plus = os.environ.get('MSX2PLUS', '1').lower() in ('1', 'true', 'yes', 'on')
    with open(os.path.join(BUILD, 'config.inc'), 'w') as f:
        f.write('MSX2PLUS: equ %d\n' % (1 if msx2plus else 0))
        f.write('ROAD_DIRECT: equ %d\n' % (os.environ.get('ROAD_DIRECT', '0') == '1'))
        f.write('IRQ_SNAPSHOT: equ %d\n' % (os.environ.get('IRQ_SNAPSHOT', '1') == '1'))
        f.write('IRQ_NATIVE_MODE: equ %d\n' % ({'0': 0, '1': 1, 'ab': 2}[
            os.environ.get('IRQ_NATIVE', '1')]))
    print('MSX2+ with V9990 raster clock: %s' % ('on' if msx2plus else 'off'))
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
    if lab['ROAD_DIRECT'] and os.environ.get('ROAD_NATIVE', '1') != '1':
        sys.exit('ROAD_DIRECT requires ROAD_NATIVE=1')
    if lab['IRQ_SNAPSHOT'] and (lab['TL_REC'] != 64 or lab['VIC_REGS'] & 255 or
                               any(lab[k] & 255 for k in ('TL_BASE', 'TIMELINE', 'TIMELINE1'))):
        sys.exit('Sparse IRQ snapshots require page-aligned tables and 64-byte records')
    if lab['SCACHE'] & 0x7FF:
        sys.exit('SCACHE must be $800 aligned for the native sprite-cache address calculation')
    if any(lab[k] & 255 for k in ('VDIRTY', 'VDW')) or any(
            (lab[k] & 255) > 240 for k in ('cdirty', 'cdw')):
        sys.exit('Dirty snapshot tables must stay within their source/destination pages')
    hires = [lab[k] for k in ('CM_HA', 'CM_HB', 'CM_HC', 'CM_HD')]
    if hires[0] & 255 or hires != list(range(hires[0], hires[0] + 1024, 256)) or not (
            lab['SPANP_HI'] + 25 <= hires[0] and hires[-1] + 256 <= 0x10000):
        sys.exit('Hires CMMC tables need four consecutive free pages in SEG_SHADOW')
    data = open(binf, 'rb').read()
    # regions in source order with their lengths
    order = [('im2', 'region_im2_start', 'region_im2_end'),
             ('mem', 'region_mem_start', 'region_mem_end'),
             ('k2', 'region_k2_start', 'region_k2_end'),
             ('render', 'region_render_start', None)]
    for i in range(nseg):
        order.append(('seg%d' % i, 'seg%d_start' % i, None))
    if lab['ROAD_DIRECT']:
        order.extend([('road_cpu', 'road_cpu_start', 'road_cpu_end'),
                      ('road_vdp', 'road_vdp_start', 'road_vdp_end')])
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
        elif name == 'render':
            # Include the dirty-cell buffer and timeline, before the lookup tables.
            low = min(lab[k] for k in ('celldirty', 'LTL', 'SCACHE', 'CM_TA', 'CM_PT'))
            print('render %04X-%04X (%d bytes before runtime tables)' % (start, lab['region_render_end'] - 1, low - lab['region_render_end']))
            if lab['region_render_end'] > low:
                sys.exit('render code overlaps its runtime tables')
        elif name.startswith('seg'):
            print('%-6s %d bytes' % (name, lab['%s_end' % name] - 0x4000))
    if pos != len(data):
        sys.exit('region size mismatch: %d vs %d' % (pos, len(data)))
    mem = bytearray(load_image())
    for name in ('im2', 'mem', 'k2'):
        start, b = chunks[name]
        mem[start:start + len(b)] = b
    build_lookup(mem, lab, nseg)
    from translate import RELOC_TAB
    for lo, hi, d in RELOC_TAB:
        mem[d:d + hi - lo] = mem[lo:hi]
    # render segment: code + zeroed variable area
    rstart, rb = chunks['render']
    render = bytes(rb) + bytes(0x4000 - len(rb))
    banks = [chunks['loader'][1], bytes(mem[0x0000:0x4000]), bytes(mem[0x4000:0x8000]),
             bytes(mem[0x8000:0xC000]), bytes(mem[0xC000:0x10000]), render]
    for i in range(nseg):
        banks.append(chunks['seg%d' % i][1])
    if lab['ROAD_DIRECT']:
        banks += [bytes(0x4000), chunks['road_cpu'][1] + chunks['road_vdp'][1] + bytes(0x2000)]
    for b in banks:
        assert len(b) == 0x4000, len(b)
    if len(banks) > INTRO_BANK:
        sys.exit('ROM banks run into the intro bank')
    subprocess.check_call(['make', '-s', 'intro.rom'], cwd=INTRO)
    intro = open(os.path.join(INTRO, 'intro.rom'), 'rb').read()
    assert len(intro) == 0x4000 and intro[0x10] == 0xC3, 'intro.rom has no timed entry'
    banks += [b'\xFF' * 0x4000] * (INTRO_BANK - len(banks)) + [intro]
    rom = b''.join(banks)
    rom += b'\xFF' * (ROM_BANKS * 0x4000 - len(rom))
    out = os.path.join(BUILD, 'buggyboy.rom')
    open(out, 'wb').write(rom)
    print('wrote', out, len(rom))


if __name__ == '__main__':
    main()
