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
# far calls per 20 s of racing by JSR site (openMSX breakpoint on k_farcall,
# merged over two placements so sites that were near calls are counted too):
# weights for placing caller and callee in one segment
HOT_JSR = {0x1139: 1003, 0x1270: 1003, 0x127B: 1003, 0x127E: 1003, 0x1281: 1003, 0x1284: 1003, 0x1287: 1003, 0x128A: 1003, 0x128D: 1003, 0x1290: 1003, 0x1293: 1003, 0x1296: 1003, 0x1299: 1003, 0x129C: 1003, 0x129F: 1003, 0x1620: 36, 0x1645: 989, 0x1659: 989, 0x166D: 989, 0x1681: 989, 0x1695: 989, 0x16A9: 989, 0x16BD: 989, 0x1920: 1010, 0x1928: 1010, 0x19CB: 252, 0x19D3: 252, 0x1AFC: 902, 0x1C24: 339, 0x1C3B: 300, 0x1E4A: 381, 0x2870: 753, 0x2873: 753, 0x2876: 1453, 0x2879: 1453, 0x287C: 753, 0x287F: 753, 0x2882: 753, 0x2885: 753, 0x2888: 753, 0x288B: 753, 0x288E: 753, 0xB784: 1003, 0xB78A: 1003, 0xB952: 902, 0xCA51: 4}
# hand-written Z80 replacing C64 code: start -> (end, file under src/native)
NATIVE = {0x1452: (0x1486, 'n1452.asm')}
NATIVE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'src', 'native')
# code whose (zp),y stores always hit the VIC bank (road drawer: bitmap
# pointers from tables; checked over a full race: no store left the bank)
VIC_PTR_CODE = ((0x289C, 0x3508),)
# map the VIC bank once on entry: every first store in the routine's blocks inlines
VIC_MAP_ENTRY = {0x289C}
# Specialized copy of the road drawer: translated again at addresses + SPEC_OFS
# under per-frame flag assumptions (the special road overlays are off), with the
# flag-dependent branches folded and their dead loads removed.  The original
# entry checks the flags and jumps to the copy.  None of the flags is written
# inside the routine while they hold (L96E4 only when L02CA > 0).
SPEC_RANGE = (0x289C, 0x3508)
SPEC_OFS = 0x10000
# address -> set of values it may hold (as seen by the copy)
_NEG = frozenset(range(0x80, 0x100))
SPEC_ASSUME = {0x0342: {0}, 0x02BC: {0}, 0x02B9: {0},
               0x2FE0: _NEG,                    # LFB2A (relocated, RELOC)
               0x0334: _NEG, 0x96E4: _NEG, 0x02CA: _NEG | {0}}
VIC_PTR_CODE = VIC_PTR_CODE + ((SPEC_RANGE[0] + SPEC_OFS, SPEC_RANGE[1] + SPEC_OFS),)
VIC_MAP_ENTRY = VIC_MAP_ENTRY | {SPEC_RANGE[0] + SPEC_OFS}
# the specialized copy as hand-written Z80 (ROAD_NATIVE=0: translated copy;
# =ab: no copy, native at NR_ab next to the original drawer, for test/road_ab.sh)
ROAD_NATIVE = os.environ.get('ROAD_NATIVE', '1')
SPEC_ON = ROAD_NATIVE != 'ab'
if ROAD_NATIVE == '1':
    NATIVE[SPEC_RANGE[0] + SPEC_OFS] = (SPEC_RANGE[1] + SPEC_OFS, 'n289c.asm')
# C64 page-3 variables moved to page 0 (KVARS+$E0.., see defs.inc): only ever
# accessed at their fixed address (no indexed or indirect access can reach
# them), read between VIC-bank stores (no k_c2 needed for them)
RELOC = {0xFB2A: 0x2FE0}
# constant page-3 tables copied low by build.py (reads stop forcing k_c2): (start, end, dest)
RELOC_TAB = ((0xFEBB, 0xFEF0, 0x3008),)
VIC_REGS_ADDR = 0x2F00         # defs.inc VIC_REGS
MAIN_LOOP = 0x8003     # called once per race-loop pass: render once per pass
MT_HEAD_VBLS = 50      # vblanks without a pass before raster polls drive renders again
NO_RASTER_WAIT = {0x8014}  # 'cmp $D012 / bcs self' waits translated as already passed
IO_FAST = (0xD011, 0xD012, 0xD016, 0xD019, 0xD021, 0xD022, 0xD023)   # handlers: iowf_XXXX in kernel_p2.asm
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
        for a, (op, mn, mode, v, n) in self.ins.items():
            if mode == 'abs' and v in RELOC:            # (after find_smc: kernel hole)
                self.ins[a] = (op, mn, mode, RELOC[v], n)
            for lo, hi, d in RELOC_TAB:
                if mode in ('abs', 'abx', 'aby') and lo <= v < hi:
                    assert mn in ('lda', 'ldx', 'ldy', 'cmp', 'adc', 'sbc', 'and', 'ora', 'eor'), '%04X writes table' % a
                    self.ins[a] = (op, mn, mode, v - lo + d, n)
        if SPEC_ON:
            self.specialize()
        self.find_blocks()
        self.liveness()
        # JSR targets that end in an indirect jump are always called through
        # k_farcall: k_jmpind then switches segment without a stack frame, so
        # handlers that pull bytes pushed before the jump still work.
        self.ind_callees = {t for t in self.jsr_targets if self.reaches_jmpind(t)}

    # ------------------------------------------------------------ specialization
    def specialize(self):
        lo, hi = SPEC_RANGE
        ins = self.ins
        inr = lambda t: lo <= t < hi
        copy = {}
        for a in [a for a in ins if inr(a)]:
            op, mn, mode, v, n = ins[a]
            if (mode == 'rel' or (mn == 'jmp' and mode == 'abs')) and inr(v):
                v += SPEC_OFS
            assert mn not in ('jsr', 'rti', 'brk') and not (mn == 'jmp' and mode == 'ind'), '%04X' % a
            copy[a + SPEC_OFS] = (op, mn, mode, v, n)
        ins.update(copy)
        # fold branches that follow a load/compare of an assumed flag
        cond = {'beq': lambda x: x == 0, 'bne': lambda x: x != 0,
                'bmi': lambda x: x >= 0x80, 'bpl': lambda x: x < 0x80}
        flag_loads = []
        for a in sorted(copy):
            op, mn, mode, v, n = ins[a]
            if mode != 'abs' or v not in SPEC_ASSUME:
                continue
            if mn in ('lda', 'ldx', 'ldy'):
                vals = set(SPEC_ASSUME[v])
                flag_loads.append(a)
                b = a + n
                while b in copy and ins[b][1] in cond:
                    t = ins[b][3]
                    taken = {x for x in vals if cond[ins[b][1]](x)}
                    if taken == vals:
                        ins[b] = (0x4C, 'jmp', 'abs', t, ins[b][4])
                        break
                    if not taken:
                        ins[b] = (0xEA, 'nop', 'imp', None, ins[b][4])
                    vals -= taken
                    b += ins[b][4]
            elif mn in ('cmp', 'cpx', 'cpy') and SPEC_ASSUME[v] == {0}:
                b = a + n                       # reg - 0: carry always set
                while b in copy and ins[b][1] in ('bcs', 'bcc', 'beq', 'bne', 'bmi', 'bpl'):
                    if ins[b][1] == 'bcs':
                        ins[b] = (0x4C, 'jmp', 'abs', ins[b][3], ins[b][4])
                        break
                    if ins[b][1] == 'bcc':
                        ins[b] = (0xEA, 'nop', 'imp', None, ins[b][4])
                    b += ins[b][4]
        # the copy must never write a flag it assumes
        seen, todo = set(), [lo + SPEC_OFS]
        while todo:
            a = todo.pop()
            if a in seen or a not in copy:
                continue
            seen.add(a)
            op, mn, mode, v, n = ins[a]
            assert not (mn[:2] in ('st', 'in', 'de', 'as', 'ls', 'ro') and v in SPEC_ASSUME), '%04X writes a flag' % a
            todo.extend(self.succs(a))
        for a in set(copy) - seen:              # unreachable under the assumptions
            del ins[a]
        copy = {a: ins[a] for a in seen}
        flag_loads = [a for a in flag_loads if a in seen]
        # drop the flag loads whose value and flags nobody reads any more
        self.find_blocks()
        self.liveness()
        alive = self.a_live(copy)
        for a in flag_loads:
            if not (self.live_out[a] & ALL) and not alive[a] and ins[a][1] == 'lda':
                ins[a] = (0xEA, 'nop', 'imp', None, ins[a][4])

    def a_live(self, region):
        """A register live after each instruction of region (conservative at exits)."""
        reads = {'sta', 'cmp', 'adc', 'sbc', 'and', 'ora', 'eor', 'tax', 'tay', 'pha', 'bit'}
        kills = {'lda', 'txa', 'tya', 'pla'}
        out = {a: True for a in region}
        inn = {a: True for a in region}
        changed = True
        while changed:
            changed = False
            for a in sorted(region, reverse=True):
                op, mn, mode, v, n = self.ins[a]
                if mn == 'rts' or (mn == 'jmp' and mode != 'abs'):
                    o = True
                else:
                    o = any(inn.get(s, True) for s in self.succs(a))
                r = mn in reads or (mn in ('asl', 'lsr', 'rol', 'ror') and mode == 'acc')
                i = r or (o and mn not in kills)
                if o != out[a] or i != inn[a]:
                    out[a], inn[a], changed = o, i, True
        return out

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
        if a == SPEC_RANGE[0] and SPEC_ON:
            s.append(a + SPEC_OFS)
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
        self.keepc = False
        self.c2_before = set()    # may run with the VIC bank mapped: 'call k_c2' first
        self.c2_after = set()     # leaves the component with the VIC bank maybe mapped
        self.vic_sure = set()     # runs with the VIC bank mapped for certain
        self.entries = (set(tr.jsr_targets) | set(IRQ_HANDLERS) | {GAME_START}
                        | set(table_targets(tr.mem)))

    # ---- VIC runs: consecutive stores to the VIC bank share one mapper switch
    def vic_store(self, a):
        op, mn, mode, v, n = self.tr.ins[a]
        if mn not in ('sta', 'stx', 'sty') or a in SMC_OPERAND or ram_mode(a):
            return False
        if mode == 'izy':
            return True
        if mode == 'abs':
            return addr_class(v) == 'vic'
        if mode in ('abx', 'aby'):
            return range_class(v, v + 255) == 'vic'
        return False

    def vic_load(self, a):
        """Non-store instruction reading the VIC bank through an abs/abx/aby operand."""
        op, mn, mode, v, n = self.tr.ins[a]
        if mn in ('sta', 'stx', 'sty') or a in SMC_OPERAND or ram_mode(a):
            return False
        if mn in ('inc', 'dec', 'asl', 'lsr', 'rol', 'ror'):
            return False                # read-modify-write: k_vrd/k_vwr
        if mode == 'abs':
            return addr_class(v) == 'vic'
        if mode in ('abx', 'aby'):
            return range_class(v, v + 255) == 'vic'
        return False

    def vicreg_store(self, a):
        """Store to a VIC register handled by k_vicw (page 0)."""
        op, mn, mode, v, n = self.tr.ins[a]
        return (mn in ('sta', 'stx', 'sty') and a not in SMC_OPERAND and not ram_mode(a)
                and mode in ('abs', 'abx', 'aby') and 0xD000 <= v < 0xD040
                and not (mode == 'abs' and v in IO_FAST))

    def vicreg_read(self, a):
        """Fixed-address read of a plain VIC register: its shadow in VIC_REGS."""
        op, mn, mode, v, n = self.tr.ins[a]
        return (mode == 'abs' and 0xD000 <= v < 0xD400 and mn not in ('sta', 'stx', 'sty')
                and mn not in ('inc', 'dec', 'asl', 'lsr', 'rol', 'ror')
                and (v & 0x3F) < 0x2F and (v & 0x3F) not in (0x11, 0x12, 0x19, 0x1A, 0x1E, 0x1F)
                and a not in SMC_OPERAND and not ram_mode(a))

    def vic_safe(self, a):
        """Instruction that runs correctly while page 3 holds the VIC bank."""
        op, mn, mode, v, n = self.tr.ins[a]
        if a in SMC_OPERAND:
            return False
        if mn in ('tax', 'tay', 'txa', 'tya', 'inx', 'iny', 'dex', 'dey', 'clc', 'sec',
                  'nop', 'bcc', 'bcs', 'beq', 'bne', 'bmi', 'bpl', 'bvc', 'bvs'):
            return True
        if mn == 'jmp':
            return mode == 'abs'
        if mn in ('pha', 'pla', 'clv', 'sei', 'cli', 'cld', 'sed'):
            return True                 # stack page / flags only
        if mn in ('asl', 'lsr', 'rol', 'ror') and mode in ('acc', 'imp'):
            return True
        if mn not in ('lda', 'ldx', 'ldy', 'sta', 'stx', 'sty', 'bit',
                      'cmp', 'cpx', 'cpy', 'and', 'ora', 'eor', 'adc', 'sbc',
                      'inc', 'dec', 'asl', 'lsr', 'rol', 'ror'):
            return False
        if mn[:2] == 'st' and (self.vic_store(a) or self.vicreg_store(a)):
            return True
        if self.vic_load(a) or self.vicreg_read(a):
            return True
        if mode in ('imm', 'zp', 'zpx', 'zpy'):
            return True
        if mode == 'abs':
            return addr_class(v, ram_mode(a)) == 'direct' and v < 0xC000   # VIC bank in page 3
        if mode in ('abx', 'aby'):
            return (range_class(v, v + 255, ram_mode(a)) == 'direct'
                    and v + 255 < 0xC000)
        return False

    def plan_vic_lazy(self, comp):
        """VIC-bank stores leave the VIC bank mapped in page 3 (k_vwrl/k_gwrl map
        it only when needed); 'call k_c2' maps C64 block 3 back before an
        instruction that needs it, or on leaving the component, wherever the
        VIC bank may be mapped.  Entries from outside always arrive with block 3."""
        tr = self.tr
        cs = set(comp)
        preds = defaultdict(list)
        for a in comp:
            for t in tr.succs(a):
                if t in cs:
                    preds[t].append(a)
        ext = self.entries
        vin, vout = {}, {a: False for a in comp}     # VIC bank may be mapped
        min_, mout = {}, {a: True for a in comp}     # VIC bank surely mapped
        changed = True
        while changed:
            changed = False
            for a in comp:
                m = any(vout[p] for p in preds[a])
                s = bool(preds[a]) and a not in ext and all(mout[p] for p in preds[a])
                if a in VIC_MAP_ENTRY:
                    m, s = True, True
                vin[a], min_[a] = m, s
                if self.vic_store(a) or self.vic_load(a):
                    o, so = True, True
                elif m and not self.vic_safe(a):
                    o, so = False, False
                else:
                    o, so = m, s
                if o != vout[a] or so != mout[a]:
                    vout[a], mout[a], changed = o, so, True
        self.vic_sure.update(a for a in comp if min_[a])
        for a in comp:
            mn = tr.ins[a][1]
            if vin[a] and not self.vic_safe(a):
                self.c2_before.add(a)
                continue
            if vout[a] and any(t not in cs for t in tr.succs(a)):
                if mn == 'jmp' or tr.ins[a][2] == 'rel':
                    self.c2_before.add(a)
                else:
                    self.c2_after.add(a)

    def emit(self, *lines):
        for l in lines:
            if l.endswith(':'):
                self.out.append(l)          # local label
            elif self.keepc and l.startswith('add hl,'):
                # indexed address calc clobbers C; 6502 LDA/STA/INC.. keep it
                self.out.extend(("\tex af,af'", '\t' + l, "\tex af,af'"))
            else:
                self.out.append('\t' + l)

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
            if self.vicreg_read(a):
                self.emit('ld hl,$%04X' % (VIC_REGS_ADDR + (v & 0x3F)))
                return '(hl)'
            self.emit('ld hl,$%04X' % v)
            if self.vic_load(a):
                return self.vic_read(a, v != 0x7FFF)
            return self.access_hl(cls)
        if mode in ('abx', 'aby'):
            idx = 'de' if mode == 'abx' else 'bc'
            if a in SMC_OPERAND:
                self.emit('ld hl,($%04X)' % (a + 1), 'add hl,' + idx, 'call k_grd')
                return 'l'
            self.emit('ld hl,$%04X' % v, 'add hl,' + idx)
            if self.vic_load(a):
                return self.vic_read(a, v + 255 < 0x7FFF)
            return self.access_hl(range_class(v, v + 255, ramio))
        raise ValueError('mode %s at %04X' % (mode, a))

    def vic_read(self, a, no_ffff):
        """VIC-bank operand at HL: read it through page 3 (VIC bank left mapped)."""
        if a in self.vic_sure and no_ffff:
            self.emit('set 7,h', 'set 6,h')
            return '(hl)'
        self.emit('call k_vrdl')
        return 'l'

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
            if not ramio and any(lo_ <= a < hi_ for lo_, hi_ in VIC_PTR_CODE):
                cls = 'vic'
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
        if self.vic_store(a):
            if a in self.vic_sure:
                helper = {'k_vwr': 'k_vwrm', 'k_gwr': 'k_gwrm'}[helper]
            else:
                helper = {'k_vwr': 'k_vwrl', 'k_gwr': 'k_gwrl'}[helper]
            if not self.tr.live_out[a] & ALL:
                helper += 'f'           # flags dead after the store: F may be clobbered
        elif self.vicreg_store(a):
            helper = 'k_vicw'
        if cls == 'io' and mode == 'abs' and v in IO_FAST:
            helper, setup = 'iowf_%04X' % v, []   # fixed hot VIC register: no address decode
        elif cls == 'io' and 0xD800 <= v and (v if mode == 'abs' else v + 255) < 0xDC00:
            helper = 'k_colwr'          # colour RAM for sure: skip k_iowr's decode
        # VIC bank surely mapped, flags dead: compare inline, call only to store
        if helper == 'k_vwrmf':
            body = ['set 7,h', 'set 6,h', 'cp (hl)', 'call nz,vwr_st']
        elif helper == 'k_gwrmf':
            s, e = 'G%04X_o' % a, 'G%04X_e' % a
            body = ['bit 6,h', 'jr z,' + s, 'bit 7,h', 'jr nz,' + s, 'set 7,h', 'set 6,h',
                    'cp (hl)', 'call nz,vwr_st', 'jr ' + e, s + ':', 'call gwrmf_o', e + ':']
        else:
            body = ['call ' + helper]
        if reg == 'a':
            self.emit(*setup)
            self.emit(*body)
        else:
            self.emit('push af', 'ld a,%s' % reg)
            self.emit(*setup)
            self.emit(*body)
            self.emit('pop hl', 'ld a,h')

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
        nat = next((k for k, (e, f) in NATIVE.items() if k <= a < e), None)
        if nat is not None:
            if a == nat:
                self.out.append('%s:\t\t\t; %04X-%04X native' % (L(a), a, NATIVE[a][0] - 1))
                for l in open(os.path.join(NATIVE_DIR, NATIVE[a][1])):
                    l = l.rstrip()
                    if l and not l.lstrip().startswith(';'):
                        self.out.append(l)
            return
        if ROAD_NATIVE == 'ab' and a == SPEC_RANGE[0]:
            self.out.append('NR_ab:')
            self.out.extend(l.rstrip() for l in open(os.path.join(NATIVE_DIR, 'n289c.asm'))
                            if l.strip() and not l.lstrip().startswith(';'))
        self.out.append('%s:\t\t\t; %04X %s %s' % (L(a), a, text, mode))
        if a == MAIN_LOOP:
            # game-loop pass: its new state is worth one render (flags preserved)
            # game-loop pass: hold passes to one per PACE_VBLS vblanks (steady game
            # speed); its new state is worth one render (mt_sync), except a pass
            # that started late after a rendered one: skip that render so the
            # game catches up.  A far-behind schedule (menus, pauses) restarts.
            # Registers and flags preserved.
            # An early pass asks for its render before waiting for its slot: the
            # render (vblank ISR) then overlaps the wait instead of following it.
            p = L(a)
            self.emit('push af', 'push hl', 'ld hl,pace_due',
                      'ld a,(frame_count)', 'sub (hl)', 'jp p,%s_pl' % p,
                      'ld a,%d' % MT_HEAD_VBLS, 'ld (mt_head),a',
                      'xor a', 'ld (pace_np),a', 'inc a', 'ld (mt_sync),a', 'call k_render_now',
                      '%s_pw:' % p, 'ld a,(frame_count)', 'sub (hl)', 'jp m,%s_pw' % p,
                      'ld a,(hl)', 'add a,PACE_VBLS', 'ld (hl),a', 'jr %s_pk' % p,
                      '%s_pl:' % p, 'cp 13', 'jr c,%s_pd' % p, 'ld a,(frame_count)', 'ld (hl),a', 'xor a',
                      '%s_pd:' % p, 'push af', 'ld a,(hl)', 'add a,PACE_VBLS', 'ld (hl),a',
                      'ld hl,pace_np', 'pop af', 'jr %s_pr' % p,   # always render (no catch-up skip)
                      'ld a,(hl)', 'or a', 'jr nz,%s_pr' % p, 'inc (hl)', 'jr %s_pk' % p,
                      '%s_pr:' % p, 'ld (hl),0', 'ld hl,mt_sync', 'ld (hl),1', 'call k_render_now',
                      '%s_pk:' % p, 'ld hl,mt_head', 'ld (hl),%d' % MT_HEAD_VBLS,
                      # Refresh controls after any vblank render wait, directly
                      # before the game loop consumes them.  Preserve BC here;
                      # AF/HL are already saved by the hook above.
                      'push bc', 'call read_input', 'pop bc',
                      'pop hl', 'pop af')
        if a in self.c2_before:
            self.emit('call k_c2')
        if a == SPEC_RANGE[0] and SPEC_ON:
            # every assumption holds: run the specialized copy
            for v, vals in sorted(SPEC_ASSUME.items()):
                self.emit('ld a,($%04X)' % v, 'or a')
                if vals == {0}:
                    self.emit('jr nz,%s_g' % L(a))
                elif vals == _NEG:
                    self.emit('jp p,%s_g' % L(a))
                else:
                    self.emit('jr z,%s_%04X' % (L(a), v), 'jp p,%s_g' % L(a), '%s_%04X:' % (L(a), v))
            self.emit('jp %s' % L(a + SPEC_OFS), '%s_g:' % L(a))
            if ROAD_NATIVE != '0':
                self.emit('xor a', 'ld (NR_gc),a')   # native line cache invalid
        if a in VIC_MAP_ENTRY:
            self.emit('call k_vic_on')
        nz = lo & (N | Z)
        # carry held in the Z80 flag and needed after (or by) this instruction
        self.keepc = self.cs in ('P', 'Z') and bool((lo & C) or mn in ('adc', 'sbc', 'rol', 'ror'))

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
        elif mn == 'cmp' and a in NO_RASTER_WAIT:
            # raster busy-wait before bitmap drawing (C64 anti-flicker): the
            # renderer only reads the bitmap while the game is stopped, so the
            # wait is pure delay here.  6502 C = 0: the loop's bcs falls through.
            self.emit('scf')
            self.cs = 'Z'
        elif mn == 'cmp' and mode == 'abs' and v == 0xD012 and not ramio and \
                tr.ins.get(a + n, (0, ''))[1] == 'bne' and tr.ins[a + n][3] == a:
            # "wait for raster line A": also return when the line went by while
            # the renderer held the CPU (the C64 would have seen it)
            self.emit('call k_rwait')
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
        elif t.startswith(('sla', 'srl', 'rl ', 'rr ', 'bit ', 'set ', 'res ')):
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
        g.plan_vic_lazy(c)
        for a in c:
            g.instr(a, 0)
            if a in g.c2_after:
                g.emit('call k_c2')
        sizes.append((est_size(g.out), c))
    # far calls add a few bytes; keep a margin
    # call affinity: components that call each other should share a segment
    # (a cross-segment call goes through k_farcall)
    comp_of = {a: i for i, c in enumerate(comps) for a in c}
    aff = {}
    for a, d in tr.ins.items():
        if d[1] == 'jsr' and d[3] in comp_of and a in comp_of:
            x, y = comp_of[a], comp_of[d[3]]
            if x != y:
                w = 1 + HOT_JSR.get(a, 0)
                aff[(x, y)] = aff.get((x, y), 0) + w
                aff[(y, x)] = aff.get((y, x), 0) + w
    csize = {i: int(sizes[i][0] * 1.25) + 16 for i in range(len(comps))}
    # hot pairs first: merge components joined by heavy calls into groups that
    # fit a segment, best weight per byte first (a group = one bin seed)
    grp = {i: {i} for i in range(len(comps))}
    gsize = dict(csize)
    edges = sorted(((w, x, y) for (x, y), w in aff.items() if x < y and w > 1),
                   key=lambda e: -e[0] / min(csize[e[1]], csize[e[2]]))
    for w, x, y in edges:
        gx, gy = grp[x], grp[y]
        if gx is gy or gsize[min(gx)] + gsize[min(gy)] > SEG_CAPACITY:
            continue
        tot = gsize[min(gx)] + gsize[min(gy)]
        gx |= gy
        for k in gy:
            grp[k] = gx
        gsize[min(gx)] = tot
    groups = sorted({id(g): g for g in grp.values()}.values(), key=lambda g: -gsize[min(g)])
    bins = []   # [size, [comps], {comp index}]
    for g in groups:
        size = gsize[min(g)]
        best = None
        for b in bins:
            if b[0] + size <= SEG_CAPACITY:
                w = sum(aff.get((i, j), 0) for i in g for j in b[2])
                if best is None or w > best[0]:
                    best = (w, b)
        if best is None:
            bins.append([size, [comps[i] for i in g], set(g)])
        else:
            b = best[1]
            b[0] += size
            b[1].extend(comps[i] for i in g)
            b[2] |= g
    def gain(i, b):
        return sum(aff.get((i, j), 0) for j in b[2] if j != i)
    for _ in range(20):
        moved = False
        for i in range(len(comps)):
            src = next(b for b in bins if i in b[2])
            for b in bins:
                if b is src or b[0] + csize[i] > SEG_CAPACITY:
                    continue
                if gain(i, b) > gain(i, src):
                    src[0] -= csize[i]; src[2].discard(i); src[1].remove(comps[i])
                    b[0] += csize[i]; b[2].add(i); b[1].append(comps[i])
                    moved = True
                    break
        if not moved:
            break
    cross = sum(w for (x, y), w in aff.items() if x < y and not any(x in b[2] and y in b[2] for b in bins))
    sys.stderr.write('cross-segment call weight: %d (%d segments)\n' % (cross, len(bins)))
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
            g.plan_vic_lazy(c)
            for a in c:
                g.instr(a, i)
                if a in g.c2_after:
                    g.emit('call k_c2')
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
