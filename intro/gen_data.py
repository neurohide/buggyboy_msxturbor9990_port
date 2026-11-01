#!/usr/bin/env python3
"""Generate data.inc for intro.asm: palette, sky RLE, wave tiles, glyphs, tables."""
import math

MESSAGE = "MSX port by neurohide" + " " * 8

# Theme, looped. One bass pluck per group of four melody notes.
MELODY = ["F#5", "F#5", "D#5", "D#5", "C#5", "C#5", "A#4", "G#4", "A#4", "G#4", "F#4", "D#4"]
BASS = ["F#3", "C#3", "D#3"]
NOTE_LEN = 14      # frames per note (60 Hz)
ECHO_DELAY = 6     # frames before the softer resonance pluck
ENV_LEN = 64       # envelope table length; the last entry is silence

# Palette (R, G, B), 0..7 each
PALETTE = [
    (7, 7, 1),  # 0  sun glow, inner ring (cycled at runtime)
    (1, 1, 1),  # 1  near-black grey: Fuji shadow side, text shadow, border
    (1, 2, 5),  # 2  blue
    (2, 4, 6),  # 3  light blue
    (5, 6, 7),  # 4  pale blue
    (7, 7, 7),  # 5  foam white
    (7, 6, 4),  # 6  cream sky (text background)
    (4, 4, 5),  # 7  cloud grey
    (7, 1, 0),  # 8  sun red, text middle
    (7, 4, 0),  # 9  sun glow, middle ring (cycled at runtime)
    (7, 4, 0),  # 10 text top
    (5, 0, 1),  # 11 text bottom
    (4, 5, 7),  # 12 contour lines (pulsed at runtime)
    (1, 3, 5),  # 13 mid blue
    (3, 3, 3),  # 14 dark grey: Fuji sunlit side
    (7, 1, 0),  # 15 sun glow, outer ring (cycled at runtime)
]

SEA = 13         # sea colour: band seams, water behind the crests, VRAM fill
OVERLAP = 0.10   # each layer starts this fraction of its height over the one behind
# display Y, height, step in bytes (1 = 2px, 2 = 4px), crest amp, foam rows, phase seed, frame shift, mask
BANDS = [
    dict(h=12, sb=1, amp=6, foam=1, seed=0, shift=2, behind=SEA, period=16),
    dict(h=14, sb=1, amp=9, foam=1, seed=11, shift=1, behind=SEA),
    dict(h=24, sb=2, amp=17, foam=2, seed=5, shift=1, behind=SEA),
    dict(h=28, sb=2, amp=21, foam=2, seed=19, shift=0, behind=SEA),
]
# Stack the layers from the bottom of the screen up; vis = rows left visible.
_y = 212
for _i in range(len(BANDS) - 1, -1, -1):
    _b = BANDS[_i]
    _b["y"] = _y - _b["h"] + (round(_b["h"] * OVERLAP) if _i < len(BANDS) - 1 else 0)
    _b["vis"] = _y - _b["y"]
    _y = _b["y"]
HORIZON = BANDS[0]["y"]
LEAD = 3  # line interrupt fires this many lines before a band starts
NEUTRAL_ROW = 252  # rows 252..255 are solid sea colour in every page

# Moving clouds: width, screen row, speed (1/16 px per 15 Hz update), start x.
# Each is 4 rows tall. VRAM: sprites page 1 rows 176.., clean sky strips
# page 2 rows 224.., compose buffers page 2 rows 236..
CLOUDS = [
    dict(w=96, y=101, speed=12, x=150),
    dict(w=72, y=109, speed=8, x=10),
    dict(w=88, y=118, speed=6, x=120),
]
CLOUD_SPRITE_ROW, CLOUD_CLEAN_ROW, CLOUD_BUF_ROW = 176, 224, 236

# Storage of each phase block: (page, first row)
STORAGE = [
    [(1, 12 * k) for k in range(8)],
    [(2, 14 * k) for k in range(16)],
    [(3, 24 * k) for k in range(8)],
    [(0, HORIZON + 28 * k) for k in range(4)]
    + [(1, 192 + 28 * k) for k in range(2)]
    + [(3, 192 + 28 * k) for k in range(2)],
]
GLYPH_PAGE, GLYPH_ROW = 1, 96
SCALE = 4
CELL = 8 * SCALE
TEXT_TOP = 2
BLOCK_H = TEXT_TOP + CELL + 2 + 2  # margin, glyph, shadow, margin

FONT = {
    "M": ["X.....X", "XX...XX", "X.X.X.X", "X..X..X", "X.....X", "X.....X", "X.....X", "......."],
    "S": [".XXXXX.", "X.....X", "X......", ".XXXXX.", "......X", "X.....X", ".XXXXX.", "......."],
    "X": ["X.....X", ".X...X.", "..X.X..", "...X...", "..X.X..", ".X...X.", "X.....X", "......."],
    "p": [".......", ".......", "XXXXXX.", "X.....X", "X.....X", "XXXXXX.", "X......", "X......"],
    "o": [".......", ".......", ".XXXXX.", "X.....X", "X.....X", "X.....X", ".XXXXX.", "......."],
    "r": [".......", ".......", "X.XXXX.", "XX....X", "X......", "X......", "X......", "......."],
    "t": ["..X....", "..X....", "XXXXX..", "..X....", "..X....", "..X..X.", "...XX..", "......."],
    "b": ["X......", "X......", "XXXXXX.", "X.....X", "X.....X", "X.....X", "XXXXXX.", "......."],
    "y": [".......", ".......", "X.....X", "X.....X", "X....XX", ".XXXX.X", "......X", ".XXXXX."],
    "n": [".......", ".......", "XXXXXX.", "X.....X", "X.....X", "X.....X", "X.....X", "......."],
    "e": [".......", ".......", ".XXXXX.", "X.....X", "XXXXXXX", "X......", ".XXXXX.", "......."],
    "u": [".......", ".......", "X.....X", "X.....X", "X.....X", "X....XX", ".XXXX.X", "......."],
    "h": ["X......", "X......", "XXXXXX.", "X.....X", "X.....X", "X.....X", "X.....X", "......."],
    "i": ["...X...", ".......", "..XX...", "...X...", "...X...", "...X...", "..XXX..", "......."],
    "d": ["......X", "......X", ".XXXXXX", "X.....X", "X.....X", "X.....X", ".XXXXXX", "......."],
    " ": ["......."] * 8,
}


def pack(row):
    return [(row[i] << 4) | row[i + 1] for i in range(0, len(row), 2)]


def db_lines(data, per=16):
    out = []
    for i in range(0, len(data), per):
        out.append("        db      " + ",".join("0x%02X" % b for b in data[i:i + per]))
    return out


# ---------------------------------------------------------------- sky
def make_sky():
    sky = [[6] * 256 for _ in range(HORIZON)]
    for y in range(12):
        for x in range(256):
            if y < 4 or (y < 8 and (x + y) % 2 == 0) or (y < 12 and (x + 2 * y) % 4 == 0):
                sky[y][x] = 5

    # Sun with three glow rings (colours 0, 9, 15); the outer one is dithered.
    # Kept below row 94 so the scroller's erase margins never touch it.
    cx, cy, r = 200, 118, 15
    for y in range(cy - 23, HORIZON):
        for x in range(cx - 23, cx + 24):
            d = math.hypot(x - cx, y - cy)
            if r < d <= 18.5:
                sky[y][x] = 0
            elif 18.5 < d <= 21.5:
                sky[y][x] = 9
            elif 21.5 < d <= 23.5 and (x + y) % 2 == 0:
                sky[y][x] = 15
    for y in range(cy - r, cy + r + 1):
        for x in range(cx - r, cx + r + 1):
            if (x - cx) ** 2 + (y - cy) ** 2 <= r * r + r:
                sky[y][x] = 8

    # Mount Fuji: flat crater summit, concave slopes flaring into a wide base,
    # a snow cap whose streaks follow the ridges, shadowed on the side away
    # from the sun. The summit stays below row 94, clear of the scroller.
    fx, ftop, half_top, half_base = 72, 96, 7, 108
    height = HORIZON - ftop
    for x in range(256):
        dx = x - fx
        a = abs(dx)
        if a <= half_top:
            top = ftop + (1 if a in (2, 5) else 0)          # crater notches
        else:
            t = min(1.0, (a - half_top) / float(half_base - half_top))
            top = ftop + int(round(height * (1 - (1 - t) ** 2.8)))
        for y in range(top, HORIZON):
            depth = y - ftop
            # Position across the slope, constant along lines from the summit,
            # so the snow fingers run down the ridges.
            ridge = dx / (depth + 4.0)
            tri = abs((ridge * 3.2) % 2 - 1)
            snow_line = 9 + 9 * tri ** 2
            shadow = dx < -1 - (depth // 3) % 2
            if depth < snow_line:
                c = 7 if shadow else 5
            else:
                c = 1 if shadow else 14
                if depth < snow_line + 2 and (x + y) % 2 == 0:
                    c = 7                                   # soft snow edge
            sky[y][x] = c

    # The last two rows are sea: the raster switch to the waves happens there.
    sky[HORIZON - 2] = [SEA] * 256
    sky[HORIZON - 1] = [SEA] * 256
    return sky


def rle(data):
    out, i = [], 0
    while i < len(data):
        j = i
        while j < len(data) and j - i < 255 and data[j] == data[i]:
            j += 1
        out += [j - i, data[i]]
        i = j
    return out + [0]


# ---------------------------------------------------------------- waves
def make_band(b):
    h, amp, foam, seed = b["h"], b["amp"], b["foam"], b["seed"]
    vis = b["vis"]
    base = vis - 3
    tile = [[SEA] * 32 for _ in range(h)]

    period = b.get("period", 32)

    def crest(x):
        u = ((x + seed) % period) / float(period)
        c = (u / 0.68) ** 1.7 if u < 0.68 else (1 - (u - 0.68) / 0.32) ** 0.55
        c += 0.12 * math.sin(u * 4 * math.pi) * (1 - c)
        return max(1, base - int(round(amp * c)))

    # Body shades by depth below the crest, woodblock style contour lines.
    shades = [12, 4, 3, 12, 3, 13, 13, 12, 13, 2, 2, 2, 12, 2, 2, 2]
    top = min(crest(x) for x in range(32))
    for x in range(32):
        yc = crest(x)
        u = ((x + seed) % period) / float(period)
        for y in range(h):
            if y < yc:
                c = b["behind"]
            else:
                d = y - yc
                if d < foam:
                    c = 5
                else:
                    c = shades[min(d - foam, len(shades) - 1)]
                # foam claws on the falling face
                if 0.70 < u < 0.98 and foam <= d <= foam + 3 and (x + d) % 2 == 0:
                    c = 5
            # Rows where layers meet are solid sea, so raster switches hide.
            if y == 0 or y >= vis - 2:
                c = SEA
            tile[y][x] = c
        # overhanging lip of the curl
        if 0.66 <= u < 0.80 and top > 0:
            tile[top][x] = 5
            if foam > 1 and top + 1 < yc:
                tile[top + 1][x] = 5
    return tile


# ---------------------------------------------------------------- glyphs
def make_glyphs(chars):
    per_row = 256 // CELL
    nrows = (len(chars) + per_row - 1) // per_row
    rows = [[6] * 256 for _ in range(BLOCK_H * nrows)]
    n = CELL // 3
    shade = [10] * n + [8] * n + [11] * (CELL - 2 * n)
    for gi, ch in enumerate(chars):
        bits = FONT[ch]
        ox = (gi % per_row) * CELL
        oy = (gi // per_row) * BLOCK_H + TEXT_TOP
        for gy in range(CELL):
            for gx in range(CELL):
                fx, fy = gx // SCALE, gy // SCALE
                if fx < 7 and bits[fy][fx] == "X":
                    rows[oy + gy][ox + gx] = shade[gy]
        for gy in range(CELL + 1, -1, -1):
            for gx in range(CELL):
                y = oy + gy
                if rows[y][ox + gx] == 6 and any(
                        gy - k >= 0 and rows[y - k][ox + gx] not in (6, 1) for k in (1, 2)):
                    rows[y][ox + gx] = 1
    return rows


def main():
    out = ["; Generated by gen_data.py - do not edit.", ""]

    out.append("palette:")
    pal = []
    for r, g, b in PALETTE:
        pal += [(r << 4) | b, g]
    out += db_lines(pal)

    # Glow rings: at step s, ring i shows SUN_CYCLE[(s - i) % 3], so the colours
    # travel outward from the sun.
    sun_cycle = [(7, 7, 1), (7, 4, 0), (7, 1, 0)]  # yellow, orange, red
    out.append("sun_cycle:")
    steps = []
    for st in range(3):
        for ring in range(3):
            r, g, b = sun_cycle[(st - ring) % 3]
            steps += [(r << 4) | b, g]
    out += db_lines(steps, 6)
    out.append("contour_tab:")
    contour = []
    for i in range(16):
        t = (1 - math.cos(2 * math.pi * i / 16)) / 2
        contour.append((round(2 + 3 * t), round(4 + 2 * t), round(6 + 1 * t)))
    out += db_lines(sum([[(r << 4) | b, g] for r, g, b in contour], []))

    sky = make_sky()
    sky_bytes = sum((pack(row) for row in sky), [])
    out.append("sky_rle:")
    out += db_lines(rle(sky_bytes))

    for i, b in enumerate(BANDS):
        tile = make_band(b)
        n = len(STORAGE[i])
        out.append("band%d_desc:" % i)
        out.append("        db      %d, %d, %d" % (b["h"], b["sb"], n))
        out.append("        dw      band%d_tile" % i)
        for page, row in STORAGE[i]:
            out.append("        db      %d, %d" % (page, row))
        out.append("band%d_tile:" % i)
        for row in tile:
            p = pack(row)
            out += db_lines(p + p, 32)

    # Runtime band descriptors: shift, mask, next R19 base, last flag, neutral R23, phase table
    out.append("band_rt:")
    for i, b in enumerate(BANDS):
        n = len(STORAGE[i])
        last = i == len(BANDS) - 1
        nxt = 0 if last else (BANDS[i + 1]["y"] - LEAD) & 255
        neutral = (NEUTRAL_ROW - (b["y"] - LEAD + 1)) & 255
        out.append("        db      %d, %d, %d, %d, %d" % (b["shift"], n - 1, nxt, 1 if last else 0, neutral))
        out.append("        dw      band%d_regs" % i)
    for i, b in enumerate(BANDS):
        out.append("band%d_regs:" % i)
        for page, row in STORAGE[i]:
            out.append("        db      0x%02X, %d" % ((page << 5) | 0x1F, (row - b["y"]) & 255))

    chars = []
    for ch in MESSAGE:
        if ch not in chars and ch != " ":
            chars.append(ch)
    chars.append(" ")
    assert len(chars) <= 16
    glyph_rows = make_glyphs(chars)
    # Cloud sprites: white top, grey underside, rounded ends, puffy top edge.
    # Colour 0 is transparent for the LMMM/TIMP copy.
    spr = [[0] * 256 for _ in range(4 * len(CLOUDS))]
    for i, c in enumerate(CLOUDS):
        w = c["w"]
        for y in range(4):
            inset = [3, 1, 0, 2][y]
            for x in range(inset, w - inset):
                if y == 0 and (x // 7) % 3 == 2:
                    continue                        # gaps between puffs
                col = 5 if y < 2 else 7
                if y == 2 and (x + y) % 2 == 0:
                    col = 7
                spr[4 * i + y][x] = col
    out.append("clouds_rle:")
    out += db_lines(rle(sum((pack(r) for r in spr), [])))
    out.append("cloud_tab:")
    for i, c in enumerate(CLOUDS):
        out.append("        db      %d, %d, %d, %d, %d, %d" % (
            c["w"], c["y"], CLOUD_SPRITE_ROW + 4 * i, CLOUD_CLEAN_ROW + 4 * i,
            CLOUD_BUF_ROW + 4 * i, c["speed"]))
        out.append("        dw      %d" % ((256 + c["w"]) * 16))
    out.append("cloud_init:")
    for c in CLOUDS:
        out.append("        dw      %d" % ((c["x"] + c["w"]) * 16))

    out.append("glyphs_rle:")
    out += db_lines(rle(sum((pack(r) for r in glyph_rows), [])))
    # Per glyph: source X, source Y (low byte; all glyphs sit in one page)
    per_row = 256 // CELL
    out.append("glyph_src:")
    for gi in range(len(chars)):
        sy = GLYPH_PAGE * 256 + GLYPH_ROW + (gi // per_row) * BLOCK_H
        out.append("        db      %d, %d" % ((gi % per_row) * CELL, sy & 255))
    out.append("message:")
    out += db_lines([chars.index(c) for c in MESSAGE])

    # Sine path: top row of each 24-row text block
    out.append("sine_tab:")
    top_min, top_max = 12, 94 - BLOCK_H
    mid, amp = (top_min + top_max) / 2, (top_max - top_min) / 2
    out += db_lines([round(mid + amp * math.sin(2 * math.pi * i / 128)) for i in range(128)])

    # Music: koto-style plucks on the PSG (tone period = 111861 / Hz)
    def period(name):
        semis = {"C": 0, "C#": 1, "D": 2, "D#": 3, "E": 4, "F": 5, "F#": 6,
                 "G": 7, "G#": 8, "A": 9, "A#": 10, "B": 11}
        n, octave = name[:-1], int(name[-1])
        hz = 440.0 * 2 ** ((semis[n] + 12 * (octave - 4) - 9) / 12.0)
        return round(111861 / hz)

    out.append("melody:")
    for n in MELODY:
        out.append("        dw      %d          ; %s" % (period(n), n))
    out.append("bass_tab:")
    for n in BASS:
        out.append("        dw      %d          ; %s" % (period(n), n))

    def env(peak, tau, length):
        return [max(0, min(15, round(peak * math.exp(-t / tau)))) for t in range(length)] + [0]

    out.append("env_melody:")
    out += db_lines(env(15, 10, ENV_LEN - 1))
    out.append("env_echo:")
    out += db_lines(env(9, 12, ENV_LEN - 1))
    out.append("env_bass:")
    out += db_lines(env(12, 18, ENV_LEN - 1))

    eq = [
        ("MSG_LEN", len(MESSAGE)),
        ("CLOUD_COUNT", len(CLOUDS)),
        ("CLOUD_SPRITE_ROW", CLOUD_SPRITE_ROW),
        ("MEL_LEN", len(MELODY)),
        ("NOTE_LEN", NOTE_LEN),
        ("ECHO_DELAY", ECHO_DELAY),
        ("ENV_LEN", ENV_LEN),
        ("MSG_PIX", len(MESSAGE) * CELL),
        ("CELL", CELL),
        ("BLOCK_H", BLOCK_H),
        ("FIRST_IRQ", (BANDS[0]["y"] - LEAD) & 255),
        ("GLYPH_PAGE", GLYPH_PAGE),
        ("GLYPH_ROW", GLYPH_ROW),
    ]
    eq.append(("SEA_FILL", SEA * 17))
    out = [f"{k}: equ {v}" for k, v in eq] + out
    with open("data.inc", "w") as f:
        f.write("\n".join(out) + "\n")
    print("sky rle bytes:", len(rle(sky_bytes)))


if __name__ == "__main__":
    main()
