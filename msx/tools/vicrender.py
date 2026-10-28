#!/usr/bin/env python3
"""Reference VIC-II renderer for debugging: renders a 64K C64 memory image
(VIC bank 1) + colour RAM with per-row modes into a PPM."""
import sys

PAL = [0x000000,0xFFFFFF,0xAF3C58,0x7EF3D6,0xAA40F5,0x62D532,0x2C3DEC,0xFFFF46,
       0xC46C1C,0x7A5000,0xF08080,0x606060,0x949494,0xA6FF86,0x7385FF,0xCDCDCD]


def render(mem, colram, rowmode, d018=0x1A, bg=(0, 0, 0, 0), out='out.ppm'):
    W, H = 320, 200
    img = [[0] * W for _ in range(H)]
    scr = 0x4000 + (d018 >> 4) * 0x400
    chb = 0x4000 + ((d018 >> 1) & 7) * 0x800
    bmb = 0x4000 + (0x2000 if d018 & 8 else 0)
    for r in range(25):
        bitmap, mc = rowmode(r)
        for c in range(40):
            code = mem[scr + r * 40 + c]
            cr = colram[r * 40 + c] & 15
            for l in range(8):
                if bitmap:
                    b = mem[bmb + (r * 40 + c) * 8 + l]
                    cols = (bg[0], code >> 4, code & 15, cr)
                else:
                    b = mem[chb + code * 8 + l]
                    cols = (bg[0], bg[1], bg[2], cr & 7)
                y = r * 8 + l
                if mc and (bitmap or cr & 8):
                    for p in range(4):
                        v = cols[(b >> (6 - 2 * p)) & 3]
                        img[y][c * 8 + 2 * p] = img[y][c * 8 + 2 * p + 1] = v
                else:
                    for p in range(8):
                        on = (b >> (7 - p)) & 1
                        if bitmap:
                            v = (code >> 4) if on else (code & 15)
                        else:
                            v = cr if on else bg[0]
                        img[y][c * 8 + p] = v
    with open(out, 'wb') as f:
        f.write(b'P6 320 200 255\n')
        for row in img:
            for v in row:
                c = PAL[v & 15]
                f.write(bytes([c >> 16, (c >> 8) & 255, c & 255]))


if __name__ == '__main__':
    mem = open(sys.argv[1], 'rb').read()
    col = open(sys.argv[2], 'rb').read() if len(sys.argv) > 3 else bytes([1]) * 1024
    render(mem, col, lambda r: (r >= 16, True), out=sys.argv[-1])
