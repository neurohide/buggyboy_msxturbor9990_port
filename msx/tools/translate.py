"""Static 6502 -> Z80 (R800) translator for the C64 Buggy Boy game image.

Register mapping:   A -> A,   X -> E (D is always 0),   Y -> C (B is always 0)
Flags:              N -> S,   Z -> Z,   C -> C (polarity tracked, see below)
Scratch:            HL, IX, AF' (inside kernel helpers only)

6502 subroutines become Z80 CALL/RET on the Z80 stack, PHA/PLA become
PUSH AF / POP HL.  The overflow flag is never tested by the game and is not
emulated.  Decimal mode is never used.

Memory model (Z80 view while translated code runs):
  $0000-$3FFF  C64 $0000-$3FFF            (segment SEG_C0, identity)
  $4000-$7FFF  translated code window      (segments SEG_CODE+n)
  $8000-$BFFF  C64 $8000-$BFFF            (SEG_C2, identity)
  $C000-$FFFF  C64 $C000-$FFFF            (SEG_C3, identity)
The C64 VIC bank $4000-$7FFF lives in SEG_VIC and is reached through kernel
helpers (which also do dirty tracking for the renderer).  $D000-$DFFF is C64
RAM; I/O accesses are routed to kernel helpers at translation time.  Z80
$FFFF is the secondary slot register, so C64 $FFFF is kept in a kernel var.

Carry polarity: SUB/SBC/CP leave the Z80 carry as *borrow*, the inverse of
the 6502 carry.  Within a basic block the translator remembers the polarity
(or a known constant after SEC/CLC) and only materialises the 6502 polarity
where the carry is live across a block boundary or consumed.
"""
import json
import os
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(__file__))
from c64image import (load_image, trace, IRQ_HANDLERS, JUMP_TABLES,  # noqa: E402
                      table_targets, ram_mode, GAME_START)

N, Z, C = 1, 2, 4
ALL = N | Z | C

SEG_CAPACITY = 0x3C00         # bytes of translated code per 16K segment
SEG_CODE_FIRST = 8            # mapper segment number of the first code segment

# flags read (uses) / written (defs) per mnemonic
USES = defaultdict(int, {'adc': C, 'sbc': C, 'rol': C, 'ror': C,
                         'bcc': C, 'bcs': C, 'beq': Z, 'bne': Z, 'bmi': N, 'bpl': N})
DEFS = defaultdict(int)
for m in ('lda', 'ldx', 'ldy', 'tax', 'tay', 'txa', 'tya', 'inx', 'iny', 'dex', 'dey',
          'and', 'ora', 'eor', 'inc', 'dec', 'pla'):
    DEFS[m] = N | Z
for m in ('adc', 'sbc', 'cmp', 'cpx', 'cpy', 'asl', 'lsr', 'rol', 'ror'):
    DEFS[m] = N | Z | C
DEFS['clc'] = DEFS['sec'] = C

# JMPs by which an IRQ handler abandons the interrupt (game over at $1329)
ESCAPE_JUMPS = {0x1329}
# Top of a main loop that spins until the IRQ code sets flags (the race loop
# at $2861 never polls the raster); k_mainpass marks the main code idle there
MAIN_LOOP_TOPS = {0x2861}

BRANCH_COND = {'beq': 'z', 'bne': 'nz', 'bmi': 'm', 'bpl': 'p'}
SMC_OPERAND = set()           # instruction addresses whose operand is patched at runtime


def addr_class(a, ramio=False):
    """Classify a C64 address for direct (static) access."""
    if 0x4000 <= a <= 0x7FFF:
        return 'vic'
    if 0xD000 <= a <= 0xDFFF:
        return 'direct' if ramio else 'io'
    if a == 0xFFFF:
        return 'vec'
    return 'direct'


def range_class(lo, hi, ramio=False):
    classes = {addr_class(a, ramio) for a in (lo, hi)}
    # a range that spans a boundary must be resolved at run time
    for b in (0x4000, 0x8000, 0xD000, 0xE000, 0xFFFF):
        if lo < b <= hi:
            return 'gen'
    if len(classes) != 1:
        return 'gen'
    c = classes.pop()
    return 'gen' if c == 'vec' else c


class Translator:
    def __init__(self):
        self.mem = load_image()
        self.ins = trace(self.mem)
        self.find_smc()
        self.find_blocks()
        self.liveness()
        # JSR targets that end in an indirect jump are always called through
        # k_farcall: k_jmpind then switches segment without a stack frame, so
        # handlers that pull bytes pushed before the jump still work.
        self.ind_callees = {t for t in self.jsr_targets if self.reaches_jmpind(t)}

    # ------------------------------------------------------------------ analysis
    def find_smc(self):
        """Instructions whose operand bytes are stored to by other code."""
        code_bytes = {}
        for a, (op, mn, mode, v, n) in self.ins.items():
            for b in range(a + 1, a + n):
                code_bytes[b] = a
        writers = ('sta', 'stx', 'sty', 'inc', 'dec', 'asl', 'lsr', 'rol', 'ror')
        for a, (op, mn, mode, v, n) in self.ins.items():
            if mn in writers and mode in ('abs', 'abx', 'aby'):
                if v in code_bytes:
                    SMC_OPERAND.add(code_bytes[v])
                if v in self.ins and v not in code_bytes:
                    raise ValueError('opcode modified at %04X by %04X' % (v, a))

    def succs(self, a):
        op, mn, mode, v, n = self.ins[a]
        s = []
        if mn not in ('jmp', 'rts', 'rti', 'brk'):
            s.append(a + n)
        if mode == 'rel' or (mn == 'jmp' and mode == 'abs'):
            s.append(v)
        return s

    def find_blocks(self):
        self.block_start = set(IRQ_HANDLERS) | set(table_targets(self.mem)) | {GAME_START}
        self.jsr_targets = defaultdict(list)     # target -> list of return addresses
        for a, (op, mn, mode, v, n) in self.ins.items():
            if mode == 'rel' or (mn in ('jmp', 'jsr') and mode == 'abs'):
                self.block_start.add(v)
            if mn == 'jsr':
                self.block_start.add(a + n)
                self.jsr_targets[v].append(a + n)
            if mode == 'rel':
                self.block_start.add(a + n)

    def reaches_jmpind(self, entry):
        """True if code reachable from entry (without following JSR) has a JMP (ind)."""
        seen, todo = set(), [entry]
        while todo:
            a = todo.pop()
            if a in seen or a not in self.ins:
                continue
            seen.add(a)
            if self.ins[a][1] == 'jmp' and self.ins[a][2] == 'ind':
                return True
            todo.extend(self.succs(a))
        return False

    def rts_reached(self, entry):
        """RTS instructions reachable from entry without following JSR."""
        seen, todo, out = set(), [entry], set()
        while todo:
            a = todo.pop()
            if a in seen or a not in self.ins:
                continue
            seen.add(a)
            mn, mode = self.ins[a][1], self.ins[a][2]
            if mn == 'rts':
                out.add(a)
            if mn == 'jmp' and mode == 'ind':
                out.add(None)          # unknown continuation
            todo.extend(self.succs(a))
        return out

    def liveness(self):
        ins = self.ins
        # which return sites can each RTS return to
        rts_ret = defaultdict(set)
        unknown_rts = set()
        for t, rets in self.jsr_targets.items():
            for r in self.rts_reached(t):
                if r is not None:
                    rts_ret[r].update(rets)
        for a, d in ins.items():
            if d[1] == 'rts' and a not in rts_ret:
                unknown_rts.add(a)
        live_in = {a: 0 for a in ins}
        live_out = {a: 0 for a in ins}
        order = sorted(ins, reverse=True)
        changed = True
        while changed:
            changed = False
            for a in order:
                op, mn, mode, v, n = ins[a]
                if mn == 'rts':
                    lo = ALL if a in unknown_rts else 0
                    for r in rts_ret.get(a, ()):
                        lo |= live_in.get(r, ALL)
                elif mn == 'rti' or mn == 'brk':
                    lo = 0
                elif mn == 'jmp' and mode == 'ind':
                    lo = ALL
                elif mn == 'jsr':
                    lo = live_in.get(v, ALL)
                else:
                    lo = 0
                    for s in self.succs(a):
                        lo |= live_in.get(s, ALL)
                li = USES[mn] | (lo & ~DEFS[mn])
                if mn == 'jsr':
                    li = lo
                if lo != live_out[a] or li != live_in[a]:
                    live_out[a], live_in[a] = lo, li
                    changed = True
        self.live_in, self.live_out = live_in, live_out

    # --------------------------------------------------------------- partition
    def components(self):
        par = {a: a for a in self.ins}

        def find(a):
            while par[a] != a:
                par[a] = par[par[a]]
                a = par[a]
            return a
        for a, (op, mn, mode, v, n) in self.ins.items():
            for s in self.succs(a):
                if s in par:
                    par[find(a)] = find(s)
        comps = defaultdict(list)
        for a in self.ins:
            comps[find(a)].append(a)
        return [sorted(c) for c in comps.values()]


# ---------------------------------------------------------------------- codegen
def L(a):
    return 'T_%04X' % a


class Gen:
    def __init__(self, tr, seg_of):
        self.tr = tr
        self.seg_of = seg_of
        self.out = []

    def emit(self, *lines):
        self.out.extend('\t' + l for l in lines)

    # carry state: 'P' 6502 polarity in Z80 C, 'Z' inverted (borrow), 0/1 known
    def need_p(self):
        cs = self.cs
        if cs == 'Z':
            self.emit('ccf')
        elif cs == 0:
            self.emit('scf', 'ccf')
        elif cs == 1:
            self.emit('scf')
        self.cs = 'P'

    def need_z(self):
        cs = self.cs
        if cs == 'P':
            self.emit('ccf')
        elif cs == 0:
            self.emit('scf')
        elif cs == 1:
            self.emit('scf', 'ccf')
        self.cs = 'Z'

    def fix_carry_for(self, target_live):
        if target_live & C:
            self.need_p()

    def setnz(self, reg):
        self.emit('inc ' + reg, 'dec ' + reg)

    # ---- operand access -----------------------------------------------------
    def operand(self, a, d, ramio):
        """Emit code to make the operand accessible; return Z80 operand text
        usable as the source of ld/ALU ops ('n', '(hl)' or 'l')."""
        op, mn, mode, v, n = d
        if mode == 'imm':
            if a in SMC_OPERAND:
                self.emit('ld hl,$%04X' % (a + 1))
                return '(hl)'
            return '$%02X' % v
        if mode == 'zp':
            self.emit('ld hl,$%04X' % v)
            return '(hl)'
        if mode in ('zpx', 'zpy'):
            self.emit('ld hl,$%04X' % v, 'add hl,%s' % ('de' if mode == 'zpx' else 'bc'), 'ld h,0')
            return '(hl)'
        if mode == 'izy':
            self.emit('ld hl,($%04X)' % v, 'add hl,bc',
                      'call %s' % ('k_grd_ram' if ramio else 'k_grd'))
            return 'l'
        if mode == 'abs':
            cls = addr_class(v, ramio)
            if a in SMC_OPERAND:
                raise ValueError('SMC abs operand at %04X' % a)
            self.emit('ld hl,$%04X' % v)
            return self.access_hl(cls)
        if mode in ('abx', 'aby'):
            idx = 'de' if mode == 'abx' else 'bc'
            if a in SMC_OPERAND:
                self.emit('ld hl,($%04X)' % (a + 1), 'add hl,' + idx, 'call k_grd')
                return 'l'
            self.emit('ld hl,$%04X' % v, 'add hl,' + idx)
            return self.access_hl(range_class(v, v + 255, ramio))
        raise ValueError('mode %s at %04X' % (mode, a))

    def access_hl(self, cls):
        if cls == 'direct':
            return '(hl)'
        self.emit('call ' + {'vic': 'k_vrd', 'io': 'k_iord', 'gen': 'k_grd',
                             'vec': 'k_vecrd'}[cls])
        return 'l'

    def store(self, a, d, reg, ramio):
        """Store Z80 register reg ('a', 'e' or 'c') to the operand."""
        op, mn, mode, v, n = d
        if mode in ('zp', 'abs') and addr_class(v, ramio) == 'direct' and a not in SMC_OPERAND:
            if reg == 'a':
                self.emit('ld ($%04X),a' % v)
            else:
                self.emit('ld hl,$%04X' % v, 'ld (hl),%s' % reg)
            return
        if mode in ('zpx', 'zpy'):
            self.emit('ld hl,$%04X' % v, 'add hl,%s' % ('de' if mode == 'zpx' else 'bc'),
                      'ld h,0', 'ld (hl),%s' % reg)
            return
        # helper path: address in HL, value in A
        if mode == 'izy':
            setup = ['ld hl,($%04X)' % v, 'add hl,bc']
            cls = 'genram' if ramio else 'gen'
        elif mode in ('abs', 'zp'):
            setup = ['ld hl,$%04X' % v]
            cls = addr_class(v, ramio)
        else:
            idx = 'de' if mode == 'abx' else 'bc'
            if a in SMC_OPERAND:
                setup = ['ld hl,($%04X)' % (a + 1), 'add hl,' + idx]
                cls = 'gen'
            else:
                setup = ['ld hl,$%04X' % v, 'add hl,' + idx]
                cls = range_class(v, v + 255, ramio)
        if cls == 'direct':
            self.emit(*setup)
            self.emit('ld (hl),%s' % reg)
            return
        helper = {'vic': 'k_vwr', 'io': 'k_iowr', 'gen': 'k_gwr', 'genram': 'k_gwr_ram',
                  'vec': 'k_vecwr'}[cls]
        if reg == 'a':
            self.emit(*setup)
            self.emit('call ' + helper)
        else:
            self.emit('push af', 'ld a,%s' % reg)
            self.emit(*setup)
            self.emit('call ' + helper, 'pop hl', 'ld a,h')

    def rmw(self, a, d, ramio, z80op):
        """inc/dec/asl/lsr/rol/ror on memory."""
        op, mn, mode, v, n = d
        if mode in ('zp', 'zpx', 'zpy'):
            cls = 'direct'
            self.operand(a, d, ramio)
        elif mode == 'abs':
            cls = addr_class(v, ramio)
            self.emit('ld hl,$%04X' % v)
        else:
            idx = 'de' if mode == 'abx' else 'bc'
            if a in SMC_OPERAND:
                raise ValueError('SMC rmw at %04X' % a)
            self.emit('ld hl,$%04X' % v, 'add hl,' + idx)
            cls = range_class(v, v + 255, ramio)
        if cls == 'direct':
            self.emit('%s (hl)' % z80op)
            return
        rd = {'vic': 'k_vrd', 'io': 'k_iord', 'gen': 'k_grd', 'vec': 'k_vecrd'}[cls]
        wr = {'vic': 'k_vwr', 'io': 'k_iowr', 'gen': 'k_gwr', 'vec': 'k_vecwr'}[cls]
        self.emit('push af', 'push hl', 'call ' + rd, '%s l' % z80op, 'ld a,l', 'pop hl',
                  'call ' + wr, 'pop hl', 'ld a,h')

    # ---- control transfer ---------------------------------------------------
    def jump_to(self, cond, target, cur_seg):
        if self.seg_of[target] != cur_seg:
            raise ValueError('cross-segment jump to %04X' % target)
        self.emit(('jp %s,%s' % (cond, L(target))) if cond else ('jp ' + L(target)))

    def call_to(self, target, cur_seg):
        tseg = self.seg_of[target]
        if tseg == cur_seg and target not in self.tr.ind_callees:
            self.emit('call ' + L(target))
        else:
            self.emit('call k_farcall', 'db %d' % (SEG_CODE_FIRST + tseg), 'dw ' + L(target))

    # ---- one instruction ----------------------------------------------------
    def instr(self, a, cur_seg):
        tr = self.tr
        d = tr.ins[a]
        op, mn, mode, v, n = d
        ramio = ram_mode(a)
        lo = tr.live_out[a]
        if a in tr.block_start:
            self.cs = 'P'
        text = mn + ('' if v is None else (' #$%02X' % v if mode == 'imm' else ' $%04X' % v))
        self.out.append('%s:\t\t\t; %04X %s %s' % (L(a), a, text, mode))
        if a in MAIN_LOOP_TOPS:
            self.emit('call k_mainpass')
        nz = lo & (N | Z)

        if mn == 'lda':
            if mode in ('zp', 'abs') and addr_class(v, ramio) == 'direct' and a not in SMC_OPERAND:
                self.emit('ld a,($%04X)' % v)
            else:
                src = self.operand(a, d, ramio)
                self.emit('ld a,' + src)
            if nz:
                self.setnz('a')
        elif mn in ('ldx', 'ldy'):
            r = 'e' if mn == 'ldx' else 'c'
            src = self.operand(a, d, ramio)
            self.emit('ld %s,%s' % (r, src))
            if nz:
                self.setnz(r)
        elif mn in ('sta', 'stx', 'sty'):
            self.store(a, d, {'sta': 'a', 'stx': 'e', 'sty': 'c'}[mn], ramio)
        elif mn in ('tax', 'tay', 'txa', 'tya'):
            dst, src = {'tax': ('e', 'a'), 'tay': ('c', 'a'), 'txa': ('a', 'e'),
                        'tya': ('a', 'c')}[mn]
            self.emit('ld %s,%s' % (dst, src))
            if nz:
                self.setnz(dst)
        elif mn in ('inx', 'iny', 'dex', 'dey'):
            self.emit('%s %s' % ('inc' if mn[0] == 'i' else 'dec', 'e' if mn[2] == 'x' else 'c'))
        elif mn in ('and', 'ora', 'eor'):
            zop = {'and': 'and', 'ora': 'or', 'eor': 'xor'}[mn]
            keep_c = (lo & C) and self.cs in ('P', 'Z')
            if keep_c:
                self.emit('push af')
            src = self.operand(a, d, ramio)
            self.emit('%s %s' % (zop, src))
            if keep_c:
                self.emit('ex (sp),hl', 'ld h,a', 'ld a,l', 'rra', 'ld a,h', 'inc a', 'dec a',
                          'pop hl')
                if self.cs == 'Z':
                    pass        # carry restored with the same (inverted) polarity
            # a known carry constant is untouched by the logic op
        elif mn == 'adc':
            if self.cs == 0:
                src = self.operand(a, d, ramio)
                self.emit('add a,' + src)
            else:
                self.need_p()
                src = self.operand(a, d, ramio)
                self.emit('adc a,' + src)
            self.cs = 'P'
        elif mn == 'sbc':
            if self.cs == 1:
                src = self.operand(a, d, ramio)
                self.emit('sub ' + src)
            else:
                self.need_z()
                src = self.operand(a, d, ramio)
                self.emit('sbc a,' + src)
            self.cs = 'Z'
        elif mn == 'cmp':
            src = self.operand(a, d, ramio)
            self.emit('cp ' + src)
            self.cs = 'Z'
        elif mn in ('cpx', 'cpy'):
            r = 'e' if mn == 'cpx' else 'c'
            src = self.operand(a, d, ramio)
            if src.startswith('$'):
                self.emit('ld h,a', 'ld a,%s' % r, 'cp ' + src, 'ld a,h')
            else:
                if src == '(hl)':
                    self.emit('ld l,(hl)')
                self.emit('ld h,a', 'ld a,%s' % r, 'cp l', 'ld a,h')
            self.cs = 'Z'
        elif mn in ('inc', 'dec'):
            self.rmw(a, d, ramio, mn)
        elif mn in ('asl', 'lsr', 'rol', 'ror'):
            zop = {'asl': 'sla', 'lsr': 'srl', 'rol': 'rl', 'ror': 'rr'}[mn]
            if mn in ('rol', 'ror'):
                self.need_p()
            if mode == 'acc':
                self.emit('%s a' % zop)
            else:
                self.rmw(a, d, ramio, zop)
            self.cs = 'P'
        elif mn == 'clc':
            self.cs = 0
        elif mn == 'sec':
            self.cs = 1
        elif mn == 'pha':
            self.emit('push af')
        elif mn == 'pla':
            self.emit('pop hl', 'ld a,h')
            if nz:
                self.setnz('a')
        elif mn == 'sei':
            self.emit('di')
        elif mn == 'cli':
            self.emit('ei')
        elif mn == 'nop':
            pass
        elif mn in BRANCH_COND:
            self.fix_carry_for(tr.live_in[v])
            self.jump_to(BRANCH_COND[mn], v, cur_seg)
        elif mn in ('bcc', 'bcs'):
            if tr.live_in[v] & C or (lo & C):
                self.need_p()
            taken_if_carry = (mn == 'bcs')
            if self.cs == 'Z':
                taken_if_carry = not taken_if_carry
            elif self.cs in (0, 1):
                # constant carry: unconditional or never
                if (self.cs == 1) == (mn == 'bcs'):
                    self.jump_to(None, v, cur_seg)
                return
            self.jump_to('c' if taken_if_carry else 'nc', v, cur_seg)
        elif mn == 'jmp':
            if mode == 'abs' and a in ESCAPE_JUMPS:
                # IRQ handler leaves for good (game over): drop the interrupt
                # context, which may be nested inside the renderer
                self.emit('call k_escape', 'db %d' % (SEG_CODE_FIRST + self.seg_of[v]),
                          'dw ' + L(v))
                return
            if mode == 'abs' and v == GAME_START:
                # game restart from inside an IRQ handler: drop the Z80 stack
                self.emit('jp k_restart')
                return
            if mode == 'abs':
                self.fix_carry_for(tr.live_in[v])
                self.jump_to(None, v, cur_seg)
            else:
                self.need_p()
                self.emit('ld hl,($%04X)' % v, 'jp k_jmpind')
            return
        elif mn == 'jsr':
            self.fix_carry_for(tr.live_in[v])
            self.call_to(v, cur_seg)
            self.cs = 'P'
            return
        elif mn == 'rts':
            if lo & C:
                self.need_p()
            self.emit('ret')
            return
        elif mn == 'rti':
            self.emit('ret')
            return
        else:
            raise ValueError('unhandled %s at %04X' % (mn, a))
        # fall through into a block start: normalise the carry if it is needed
        nxt = a + n
        if nxt in tr.block_start and nxt in tr.ins and mn not in ('jmp',):
            self.fix_carry_for(tr.live_in[nxt])


def est_size(lines):
    """Rough byte size estimate of emitted Z80 lines."""
    s = 0
    for l in lines:
        t = l.strip()
        if not t or t.endswith(':') or ':\t' in l and not l.startswith('\t'):
            continue
        if t.startswith(('db', 'dw')):
            s += 1 if t.startswith('db') else 2
        elif t.startswith(('call', 'jp')) or ',$' in t and ('ld hl' in t or 'ld (' in t or 'ld a,(' in t):
            s += 3
        elif t.startswith(('sla', 'srl', 'rl ', 'rr ')):
            s += 2
        elif ',$' in t or ' $' in t:
            s += 2
        else:
            s += 1
    return s


def main():
    out_dir = sys.argv[1]
    tr = Translator()
    comps = tr.components()
    # size every component with a provisional same-segment placement
    seg_of = {a: 0 for a in tr.ins}
    sizes = []
    for c in comps:
        g = Gen(tr, seg_of)
        for a in c:
            g.instr(a, 0)
        sizes.append((est_size(g.out), c))
    # far calls add a few bytes; keep a margin
    bins = []
    for size, c in sorted(sizes, key=lambda x: -x[0]):
        size = int(size * 1.25) + 16
        for b in bins:
            if b[0] + size <= SEG_CAPACITY:
                b[0] += size
                b[1].append(c)
                break
        else:
            bins.append([size, [c]])
    for i, b in enumerate(bins):
        for c in b[1]:
            for a in c:
                seg_of[a] = i
    # emit
    lines = ['; generated by translate.py -- do not edit', '']
    for i, b in enumerate(bins):
        g = Gen(tr, seg_of)
        lines.append('; ---- code segment %d (mapper segment %d) ----' % (i, SEG_CODE_FIRST + i))
        lines.append('\torg $4000')
        lines.append('seg%d_start:' % i)
        for c in sorted(b[1], key=lambda c: c[0]):
            for a in c:
                g.instr(a, i)
        lines.extend(g.out)
        lines.append('seg%d_end:' % i)
        lines.append('\tdefs $8000-seg%d_end,$FF' % i)
        lines.append('')
    open(os.path.join(out_dir, 'code.asm'), 'w').write('\n'.join(lines) + '\n')
    # dispatch table: IRQ handlers first, then jump-table targets
    entries = list(IRQ_HANDLERS)
    for t in table_targets(tr.mem):
        if t not in entries:
            entries.append(t)
    dl = ['; generated by translate.py -- C64 address -> code segment / Z80 address',
          'dispatch_table:']
    for t in entries:
        dl.append('\tdw $%04X\n\tdb %d\n\tdw %s' % (t, SEG_CODE_FIRST + seg_of[t], L(t)))
    dl.append('\tdw $0000\t; end marker')
    dl.append('T_GAME_START:\n\tjp %s' % L(GAME_START))
    dl.append('SEG_GAME_START: equ %d' % (SEG_CODE_FIRST + seg_of[GAME_START]))
    dl.append('NUM_CODE_SEGS: equ %d' % len(bins))
    open(os.path.join(out_dir, 'dispatch.asm'), 'w').write('\n'.join(dl) + '\n')
    info = {'segments': [b[0] for b in bins], 'smc': ['%04X' % a for a in sorted(SMC_OPERAND)]}
    json.dump(info, open(os.path.join(out_dir, 'translate.json'), 'w'), indent=1)
    print('code segments:', [b[0] for b in bins], 'SMC:', len(SMC_OPERAND))


if __name__ == '__main__':
    main()
