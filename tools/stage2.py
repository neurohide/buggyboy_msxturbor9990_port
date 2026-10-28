#!/usr/bin/env python3
"""Minimal 6502 emulator: loads a .prg, runs from start until PC leaves the
depacker area (stack/zp/$0334-$03FF/$0810 stub), then dumps 64K RAM."""
import sys

prg = open(sys.argv[1], 'rb').read()
out = sys.argv[2]
start = int(sys.argv[3], 0)
mem = bytearray(open(sys.argv[1],'rb').read())
load=0;prg=b'\0\0'
STUB_LO, STUB_HI = int(sys.argv[4],0), int(sys.argv[5],0)

A = X = Y = 0
SP = 0xFF; mem[1] = 0x37
PC = start
C = Z = I = D = V = N = 0
lo_w, hi_w = 0xFFFF, 0  # range of written addresses

def rd(a): return mem[a & 0xFFFF]
def wr(a, v):
    global lo_w, hi_w
    a &= 0xFFFF
    mem[a] = v & 0xFF
    if True:
        lo_w = min(lo_w, a); hi_w = max(hi_w, a)
def rw(a): return rd(a) | rd(a + 1) << 8
def rwzp(a): return rd(a & 0xFF) | rd((a + 1) & 0xFF) << 8
def push(v):
    global SP
    mem[0x100 + SP] = v & 0xFF; SP = (SP - 1) & 0xFF
def pop():
    global SP
    SP = (SP + 1) & 0xFF; return mem[0x100 + SP]
def nz(v):
    global Z, N
    v &= 0xFF; Z = int(v == 0); N = v >> 7; return v
def getp(b=1): return C | Z << 1 | I << 2 | D << 3 | b << 4 | 0x20 | V << 6 | N << 7
def setp(p):
    global C, Z, I, D, V, N
    C, Z, I, D, V, N = p & 1, p >> 1 & 1, p >> 2 & 1, p >> 3 & 1, p >> 6 & 1, p >> 7

# addressing modes return address (None for imp/acc)
def am(mode):
    global PC
    if mode == 'imm': a = PC; PC += 1
    elif mode == 'zp': a = rd(PC); PC += 1
    elif mode == 'zpx': a = (rd(PC) + X) & 0xFF; PC += 1
    elif mode == 'zpy': a = (rd(PC) + Y) & 0xFF; PC += 1
    elif mode == 'abs': a = rw(PC); PC += 2
    elif mode == 'abx': a = (rw(PC) + X) & 0xFFFF; PC += 2
    elif mode == 'aby': a = (rw(PC) + Y) & 0xFFFF; PC += 2
    elif mode == 'izx': a = rwzp(rd(PC) + X); PC += 1
    elif mode == 'izy': a = (rwzp(rd(PC)) + Y) & 0xFFFF; PC += 1
    elif mode == 'ind':
        p = rw(PC); PC += 2
        a = rd(p) | rd((p & 0xFF00) | ((p + 1) & 0xFF)) << 8
    else: a = None
    return a

def adc(v):
    global A, C, V
    if D:
        raise RuntimeError('decimal mode not implemented')
    r = A + v + C
    V = int(((A ^ r) & (v ^ r) & 0x80) != 0)
    C = int(r > 0xFF); A = nz(r)
def cmp(r, v):
    global C
    C = int(r >= v); nz(r - v)

OPS = {}
def op(code, name, mode): OPS[code] = (name, mode)
groups = {
 'ORA': {0x09:'imm',0x05:'zp',0x15:'zpx',0x0D:'abs',0x1D:'abx',0x19:'aby',0x01:'izx',0x11:'izy'},
 'AND': {0x29:'imm',0x25:'zp',0x35:'zpx',0x2D:'abs',0x3D:'abx',0x39:'aby',0x21:'izx',0x31:'izy'},
 'EOR': {0x49:'imm',0x45:'zp',0x55:'zpx',0x4D:'abs',0x5D:'abx',0x59:'aby',0x41:'izx',0x51:'izy'},
 'ADC': {0x69:'imm',0x65:'zp',0x75:'zpx',0x6D:'abs',0x7D:'abx',0x79:'aby',0x61:'izx',0x71:'izy'},
 'STA': {0x85:'zp',0x95:'zpx',0x8D:'abs',0x9D:'abx',0x99:'aby',0x81:'izx',0x91:'izy'},
 'LDA': {0xA9:'imm',0xA5:'zp',0xB5:'zpx',0xAD:'abs',0xBD:'abx',0xB9:'aby',0xA1:'izx',0xB1:'izy'},
 'CMP': {0xC9:'imm',0xC5:'zp',0xD5:'zpx',0xCD:'abs',0xDD:'abx',0xD9:'aby',0xC1:'izx',0xD1:'izy'},
 'SBC': {0xE9:'imm',0xE5:'zp',0xF5:'zpx',0xED:'abs',0xFD:'abx',0xF9:'aby',0xE1:'izx',0xF1:'izy'},
 'ASL': {0x0A:'acc',0x06:'zp',0x16:'zpx',0x0E:'abs',0x1E:'abx'},
 'ROL': {0x2A:'acc',0x26:'zp',0x36:'zpx',0x2E:'abs',0x3E:'abx'},
 'LSR': {0x4A:'acc',0x46:'zp',0x56:'zpx',0x4E:'abs',0x5E:'abx'},
 'ROR': {0x6A:'acc',0x66:'zp',0x76:'zpx',0x6E:'abs',0x7E:'abx'},
 'STX': {0x86:'zp',0x96:'zpy',0x8E:'abs'},
 'LDX': {0xA2:'imm',0xA6:'zp',0xB6:'zpy',0xAE:'abs',0xBE:'aby'},
 'STY': {0x84:'zp',0x94:'zpx',0x8C:'abs'},
 'LDY': {0xA0:'imm',0xA4:'zp',0xB4:'zpx',0xAC:'abs',0xBC:'abx'},
 'DEC': {0xC6:'zp',0xD6:'zpx',0xCE:'abs',0xDE:'abx'},
 'INC': {0xE6:'zp',0xF6:'zpx',0xEE:'abs',0xFE:'abx'},
 'CPX': {0xE0:'imm',0xE4:'zp',0xEC:'abs'},
 'CPY': {0xC0:'imm',0xC4:'zp',0xCC:'abs'},
 'BIT': {0x24:'zp',0x2C:'abs'},
 'JMP': {0x4C:'abs',0x6C:'ind'},
 'JSR': {0x20:'abs'},
}
for n, d in groups.items():
    for c, m in d.items(): op(c, n, m)
for c, n in {0x10:'BPL',0x30:'BMI',0x50:'BVC',0x70:'BVS',0x90:'BCC',0xB0:'BCS',0xD0:'BNE',0xF0:'BEQ'}.items():
    op(c, n, 'rel')
for c, n in {0x00:'BRK',0x40:'RTI',0x60:'RTS',0x08:'PHP',0x28:'PLP',0x48:'PHA',0x68:'PLA',
             0x88:'DEY',0xC8:'INY',0xCA:'DEX',0xE8:'INX',0xAA:'TAX',0x8A:'TXA',0xA8:'TAY',
             0x98:'TYA',0xBA:'TSX',0x9A:'TXS',0x18:'CLC',0x38:'SEC',0x58:'CLI',0x78:'SEI',
             0xB8:'CLV',0xD8:'CLD',0xF8:'SED',0xEA:'NOP'}.items():
    op(c, n, 'imp')

steps = 0
hist = []
limit = 200_000_000
while steps < limit:
    steps += 1
    opc = rd(PC)
    hist.append(PC); del hist[:-12]
    # Stop when control leaves the stub/depacker and lands in unpacked code
    if PC == 0x0500 or not (STUB_LO <= PC < STUB_HI):
        break
    if opc not in OPS:
        open(out, "wb").write(mem); print(f"lo={lo_w:04X} hi={hi_w:04X} steps={steps}")
        raise RuntimeError(f'illegal opcode {opc:02X} at {PC:04X}')
    name, mode = OPS[opc]
    PC += 1
    if mode == 'rel':
        off = rd(PC); PC += 1
        if off & 0x80: off -= 256
        cond = {'BPL': not N, 'BMI': N, 'BVC': not V, 'BVS': V,
                'BCC': not C, 'BCS': C, 'BNE': not Z, 'BEQ': Z}[name]
        if cond: PC = (PC + off) & 0xFFFF
        continue
    a = am(mode)
    if name == 'LDA': A = nz(rd(a))
    elif name == 'LDX': X = nz(rd(a))
    elif name == 'LDY': Y = nz(rd(a))
    elif name == 'STA': wr(a, A)
    elif name == 'STX': wr(a, X)
    elif name == 'STY': wr(a, Y)
    elif name == 'ORA': A = nz(A | rd(a))
    elif name == 'AND': A = nz(A & rd(a))
    elif name == 'EOR': A = nz(A ^ rd(a))
    elif name == 'ADC': adc(rd(a))
    elif name == 'SBC': adc(rd(a) ^ 0xFF)
    elif name == 'CMP': cmp(A, rd(a))
    elif name == 'CPX': cmp(X, rd(a))
    elif name == 'CPY': cmp(Y, rd(a))
    elif name == 'BIT':
        v = rd(a); Z = int((A & v) == 0); N = v >> 7; V = v >> 6 & 1
    elif name in ('ASL', 'ROL', 'LSR', 'ROR'):
        v = A if a is None else rd(a)
        if name == 'ASL': C = v >> 7; v = v << 1
        elif name == 'ROL': c0 = C; C = v >> 7; v = v << 1 | c0
        elif name == 'LSR': C = v & 1; v = v >> 1
        else: c0 = C; C = v & 1; v = v >> 1 | c0 << 7
        v = nz(v)
        if a is None: A = v
        else: wr(a, v)
    elif name == 'INC': wr(a, nz(rd(a) + 1))
    elif name == 'DEC': wr(a, nz(rd(a) - 1))
    elif name == 'JMP': PC = a
    elif name == 'JSR':
        r = PC - 1; push(r >> 8); push(r); PC = a
    elif name == 'RTS': PC = (pop() | pop() << 8) + 1
    elif name == 'RTI': setp(pop()); PC = pop() | pop() << 8
    elif name == 'BRK': raise RuntimeError(f'BRK at {PC-1:04X}')
    elif name == 'PHA': push(A)
    elif name == 'PLA': A = nz(pop())
    elif name == 'PHP': push(getp())
    elif name == 'PLP': setp(pop())
    elif name == 'INX': X = nz(X + 1)
    elif name == 'DEX': X = nz(X - 1)
    elif name == 'INY': Y = nz(Y + 1)
    elif name == 'DEY': Y = nz(Y - 1)
    elif name == 'TAX': X = nz(A)
    elif name == 'TXA': A = nz(X)
    elif name == 'TAY': Y = nz(A)
    elif name == 'TYA': A = nz(Y)
    elif name == 'TSX': X = nz(SP)
    elif name == 'TXS': SP = X
    elif name == 'CLC': C = 0
    elif name == 'SEC': C = 1
    elif name == 'CLI': I = 0
    elif name == 'SEI': I = 1
    elif name == 'CLV': V = 0
    elif name == 'CLD': D = 0
    elif name == 'SED': D = 1

print('last PCs:', ' '.join(f'{p:04X}' for p in hist))
print(f'stopped after {steps} steps at PC=${PC:04X}  $01=${mem[1]:02X}')
print(f'written range ${lo_w:04X}-${hi_w:04X}')
open(out, 'wb').write(mem)
open(out + '.entry', 'w').write(f'{PC:04X} {lo_w:04X} {hi_w:04X}\n')
