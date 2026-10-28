#!/usr/bin/env python3
"""Convert a V9990 B3/4bpp VRAM dump (512 px wide) to a PPM: vram2png.py vram pal y0 h out"""
import sys
raw = open(sys.argv[1], 'rb').read()
half = len(raw) // 2
# openMSX exposes VRAM0 (even bytes) then VRAM1 (odd bytes)
v = bytes(raw[(i >> 1) + (i & 1) * half] for i in range(len(raw)))
pal = open(sys.argv[2], 'rb').read()
y0, h = int(sys.argv[3]), int(sys.argv[4])
cols = []
for i in range(16):
    r, g, b = pal[i * 4] & 31, pal[i * 4 + 1] & 31, pal[i * 4 + 2] & 31
    cols.append(bytes([r * 255 // 31, g * 255 // 31, b * 255 // 31]))
with open(sys.argv[5], 'wb') as f:
    f.write(b'P6 512 %d 255\n' % h)
    for y in range(y0, y0 + h):
        for x in range(256):
            byte = v[y * 256 + x]
            f.write(cols[byte >> 4] + cols[byte & 15])
