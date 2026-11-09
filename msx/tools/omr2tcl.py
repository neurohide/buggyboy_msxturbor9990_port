#!/usr/bin/env python3
"""openMSX replay (.omr) -> Tcl script re-injecting the recorded inputs at the
same emulated time from boot, so any build can be driven by the same play.

Keyboard events become keymatrixdown/up. MSX joystick events become the
equivalent keyboard row 8 keys (the port ANDs joystick 1 with row 8):
up/down/left/right/A -> cursor keys/space. Last line: `set ::bb_end <secs>`."""
import gzip
import sys
import xml.etree.ElementTree as ET

TICKS = 3579545 * 960            # openMSX EmuTime units per second
# MSX joystick bit -> keyboard row 8 bit
JOY2ROW8 = {0x01: 0x20, 0x02: 0x40, 0x04: 0x10, 0x08: 0x80, 0x10: 0x01}


def events(path):
    root = ET.fromstring(gzip.open(path).read())
    for it in root.iter('item'):
        t = it.find('StateChange/time/time')
        if t is None:
            continue
        yield it.get('type'), int(t.text) / TICKS, it


def row8(bits):
    return sum(v for k, v in JOY2ROW8.items() if bits & k)


def main(path):
    out, end = [], 0.0
    for typ, t, it in events(path):
        end = max(end, t)
        f = {c.tag: c.text for c in it}
        cmds = []
        if typ == 'MSXCommandEvent':
            tok = [x.text for x in it.find('tokens')]
            if tok[0] not in ('plug', 'unplug'):
                cmds.append(' '.join(tok))
        elif 'press' in f and 'row' in f:
            row, p, r = int(f['row']), int(f['press']), int(f['release'])
            if p:
                cmds.append('keymatrixdown %d 0x%02X' % (row, p))
            if r:
                cmds.append('keymatrixup %d 0x%02X' % (row, r))
        elif 'press' in f:                      # MSX joystick
            p, r = row8(int(f['press'])), row8(int(f['release']))
            if p:
                cmds.append('keymatrixdown 8 0x%02X' % p)
            if r:
                cmds.append('keymatrixup 8 0x%02X' % r)
        elif typ not in ('EndLog',):
            sys.stderr.write('omr2tcl: skipped %s at %.3f\n' % (typ, t))
        for c in cmds:
            out.append('after time %.9f { %s }' % (t, c))
    print('\n'.join(out))
    print('set ::bb_end %.3f' % end)


if __name__ == '__main__':
    main(sys.argv[1])
