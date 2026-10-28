#!/usr/bin/env python3
"""Recursive-descent code tracer -> da65 info file.
usage: trace.py mem.bin lo hi entry info_out"""
import sys

mem = open(sys.argv[1], 'rb').read()
LO, HI, ENTRY = (int(x, 16) for x in sys.argv[2:5])
info_out = sys.argv[5]

# opcode -> length for documented 6502 opcodes
L = {}
for c in [0x00,0x08,0x0A,0x18,0x28,0x2A,0x38,0x40,0x48,0x4A,0x58,0x60,0x68,0x6A,0x78,0x88,
          0x8A,0x98,0x9A,0xA8,0xAA,0xB8,0xBA,0xC8,0xCA,0xD8,0xE8,0xEA,0xF8]:
    L[c] = 1
for c in [0x01,0x05,0x06,0x09,0x10,0x11,0x15,0x16,0x21,0x24,0x25,0x26,0x29,0x30,0x31,0x35,
          0x36,0x41,0x45,0x46,0x49,0x50,0x51,0x55,0x56,0x61,0x65,0x66,0x69,0x70,0x71,0x75,
          0x76,0x81,0x84,0x85,0x86,0x90,0x91,0x94,0x95,0x96,0xA0,0xA1,0xA2,0xA4,0xA5,0xA6,
          0xA9,0xB0,0xB1,0xB4,0xB5,0xB6,0xC0,0xC1,0xC4,0xC5,0xC6,0xC9,0xD0,0xD1,0xD5,0xD6,
          0xE0,0xE1,0xE4,0xE5,0xE6,0xE9,0xF0,0xF1,0xF5,0xF6]:
    L[c] = 2
for c in [0x0D,0x0E,0x19,0x1D,0x1E,0x20,0x2C,0x2D,0x2E,0x39,0x3D,0x3E,0x4C,0x4D,0x4E,0x59,
          0x5D,0x5E,0x6C,0x6D,0x6E,0x79,0x7D,0x7E,0x8C,0x8D,0x8E,0x99,0x9D,0xAC,0xAD,0xAE,
          0xB9,0xBC,0xBD,0xBE,0xCC,0xCD,0xCE,0xD9,0xDD,0xDE,0xEC,0xED,0xEE,0xF9,0xFD,0xFE]:
    L[c] = 3
BRANCH = {0x10,0x30,0x50,0x70,0x90,0xB0,0xD0,0xF0}
STOP = {0x00,0x40,0x60,0x4C,0x6C}

def w(a): return mem[a] | mem[a + 1] << 8

code = set()      # bytes that are code
starts = set()    # instruction starts
labels = set()
todo = [ENTRY]
vec_targets = set()

VEC = (0x0314, 0x0316, 0x0318, 0xFFFA, 0xFFFC, 0xFFFE)
def follow(a):
    imm = {}; pend = {}
    while LO <= a <= HI and a not in starts:
        op = mem[a]
        if op not in L:
            return
        n = L[op]
        if any(b in code for b in range(a, a + n)):
            return  # overlaps existing code: likely data
        starts.add(a)
        code.update(range(a, a + n))
        if op in BRANCH:
            off = mem[a + 1]; off -= 256 if off & 0x80 else 0
            t = a + 2 + off; labels.add(t); todo.append(t)
        elif op in (0x20, 0x4C):
            t = w(a + 1); labels.add(t)
            if LO <= t <= HI and t < 0xFF81: todo.append(t)
        # pattern: LDA #lo / STA vec / LDA #hi / STA vec+1 (IRQ/NMI/BRK vectors)
        if op == 0xA9 and mem[a + 2] in (0x8D, 0x8E) and mem[a + 5] == 0xA9 and mem[a + 7] == 0x8D:
            v1, v2 = w(a + 3), w(a + 8)
            if v2 == v1 + 1 and v1 in (0x0314, 0x0316, 0x0318, 0xFFFA, 0xFFFC, 0xFFFE):
                t = mem[a + 1] | mem[a + 6] << 8
                vec_targets.add(t); labels.add(t); todo.append(t)
        if op in (0xA9, 0xA2, 0xA0): imm['AXY'[(0xA9,0xA2,0xA0).index(op)]] = mem[a + 1]
        if op in (0x8D, 0x8E, 0x8C):
            r = 'AXY'[(0x8D,0x8E,0x8C).index(op)]; t = w(a + 1)
            for v in VEC:
                if t in (v, v + 1) and r in imm:
                    pend.setdefault(v, {})[t - v] = imm[r]
                    if len(pend[v]) == 2:
                        tt = pend[v][0] | pend[v][1] << 8
                        vec_targets.add(tt); labels.add(tt); todo.append(tt); del pend[v]
        if op in STOP:
            return
        a += n

while todo:
    follow(todo.pop())

# build ranges
lines = []
lines.append(f'GLOBAL {{ STARTADDR ${LO:04X}; CPU "6502"; COMMENTS 3; }};')
cur = None; rs = LO
def emit(s, e, t):
    lines.append(f'RANGE {{ START ${s:04X}; END ${e:04X}; TYPE {t}; }};')
for a in range(LO, HI + 1):
    t = 'CODE' if a in code else 'BYTETABLE'
    if t != cur:
        if cur: emit(rs, a - 1, cur)
        cur, rs = t, a
emit(rs, HI, cur)

HW = {
 # VIC-II
 0xD000:'VIC_SPR0_X',0xD001:'VIC_SPR0_Y',0xD010:'VIC_SPR_HI_X',0xD011:'VIC_CTRL1',0xD012:'VIC_RASTER',
 0xD015:'VIC_SPR_ENA',0xD016:'VIC_CTRL2',0xD017:'VIC_SPR_EXP_Y',0xD018:'VIC_VIDEO_ADR',
 0xD019:'VIC_IRR',0xD01A:'VIC_IMR',0xD01B:'VIC_SPR_BG_PRIO',0xD01C:'VIC_SPR_MCOLOR',
 0xD01D:'VIC_SPR_EXP_X',0xD01E:'VIC_SPR_COLL',0xD01F:'VIC_SPR_BG_COLL',0xD020:'VIC_BORDERCOLOR',
 0xD021:'VIC_BG_COLOR0',0xD022:'VIC_BG_COLOR1',0xD023:'VIC_BG_COLOR2',0xD024:'VIC_BG_COLOR3',
 0xD025:'VIC_SPR_MCOLOR0',0xD026:'VIC_SPR_MCOLOR1',
 # SID
 0xD400:'SID_S1Lo',0xD401:'SID_S1Hi',0xD404:'SID_Ctl1',0xD405:'SID_AD1',0xD406:'SID_SUR1',
 0xD407:'SID_S2Lo',0xD408:'SID_S2Hi',0xD40B:'SID_Ctl2',0xD40C:'SID_AD2',0xD40D:'SID_SUR2',
 0xD40E:'SID_S3Lo',0xD40F:'SID_S3Hi',0xD412:'SID_Ctl3',0xD413:'SID_AD3',0xD414:'SID_SUR3',
 0xD415:'SID_FltLo',0xD416:'SID_FltHi',0xD417:'SID_FltCtl',0xD418:'SID_Amp',0xD41B:'SID_Noise',
 # CIA
 0xDC00:'CIA1_PRA',0xDC01:'CIA1_PRB',0xDC02:'CIA1_DDRA',0xDC03:'CIA1_DDRB',0xDC04:'CIA1_TA',
 0xDC05:'CIA1_TA_HI',0xDC0D:'CIA1_ICR',0xDC0E:'CIA1_CRA',0xDC0F:'CIA1_CRB',
 0xDD00:'CIA2_PRA',0xDD02:'CIA2_DDRA',0xDD0D:'CIA2_ICR',0xDD0E:'CIA2_CRA',
 # vectors / zp
 0x0001:'CPU_PORT',0x0314:'IRQ_VEC',0x0315:'IRQ_VEC_HI',0x0318:'NMI_VEC',0x0319:'NMI_VEC_HI',
 0xFFFA:'HW_NMI',0xFFFB:'HW_NMI_HI',0xFFFE:'HW_IRQ',0xFFFF:'HW_IRQ_HI',
 # KERNAL
 0xFF81:'CINT',0xFF84:'IOINIT',0xFF8A:'RESTOR',0xFF90:'SETMSG',0xFFBA:'SETLFS',0xFFBD:'SETNAM',
 0xFFC0:'OPEN',0xFFC3:'CLOSE',0xFFC6:'CHKIN',0xFFC9:'CHKOUT',0xFFCC:'CLRCHN',0xFFCF:'CHRIN',
 0xFFD2:'CHROUT',0xFFD5:'LOAD',0xFFD8:'SAVE',0xFFE1:'STOP',0xFFE4:'GETIN',0xFFE7:'CLALL',
 0xEA31:'KERNAL_IRQ',0xEA81:'KERNAL_IRQ_EXIT',0xFEBC:'KERNAL_NMI_EXIT',0xE544:'CLEAR_SCREEN',
 0xA400:'BASIC_A400',
}
for a, n in sorted(HW.items()):
    lines.append(f'LABEL {{ NAME "{n}"; ADDR ${a:04X}; }};')
for i in range(1, 8):
    lines.append(f'LABEL {{ NAME "VIC_SPR{i}_X"; ADDR ${0xD000+2*i:04X}; }};')
    lines.append(f'LABEL {{ NAME "VIC_SPR{i}_Y"; ADDR ${0xD001+2*i:04X}; }};')
lines.append(f'LABEL {{ NAME "entry"; ADDR ${ENTRY:04X}; COMMENT "Program entry (after depacking)"; }};')
for i, t in enumerate(sorted(vec_targets)):
    lines.append(f'LABEL {{ NAME "irq_handler_{t:04X}"; ADDR ${t:04X}; COMMENT "Interrupt handler"; }};')
open(info_out, 'w').write('\n'.join(lines) + '\n')
print(f'code bytes: {len(code)} / {HI-LO+1}, instructions: {len(starts)}, '
      f'interrupt handlers: {[hex(t) for t in sorted(vec_targets)]}')
