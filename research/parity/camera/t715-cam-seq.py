#!/usr/bin/env python3
"""Make the sensor tables t715-camera.ko asks for, from the owner's copy of the ISP firmware.

    t715-cam-seq.py FW SEQ6B2 OUTDIR [REAR_MODE]

FW is fimc_is_fw2_4h5.bin, SEQ6B2 the sequence ex6b2b.py decoded from it. The records are
{ le16 reg; le16 width; le32 value }. Their content is Samsung's: the output stays out of
the repository, and goes to /usr/lib/firmware/t715/ on the tablet.
"""
import os
import re
import struct
import sys

fw, seq6b2, out = sys.argv[1:4]
rear_mode = int(sys.argv[4]) if len(sys.argv) > 4 else 0


def records(items):
    return b''.join(struct.pack('<HHI', reg, width, val) for reg, width, val in items)


def front():
    items, on = [], False
    for line in open(seq6b2):
        m = re.match(r'FUNC (0x[0-9a-f]+)', line)
        if m:
            on = int(m.group(1), 16) in (0x77498, 0x78548)
            continue
        m = re.match(r'\s+0x[0-9a-f]+ (W8|W16) (0x[0-9a-f]+) (0x[0-9a-f]+)', line)
        if on and m:
            items.append((int(m.group(2), 16), 2 if m.group(1) == 'W16' else 1, int(m.group(3), 16)))
    return items


def rear():
    d = open(fw, 'rb').read()
    o = 0x188490 + rear_mode * 0x4f8
    items = [(0x0104, 1, 1)]
    for i in range(106):
        width, reg, val = struct.unpack_from('<III', d, o + i * 12)
        if width not in (1, 2):
            sys.exit('entry %d of mode %d is not a register write' % (i, rear_mode))
        items.append((reg, width, val))
    return items + [(0x0104, 1, 0)]


os.makedirs(out, exist_ok=True)
for name, items in (('s5k6b2.seq', front()), ('s5k4h5.seq', rear())):
    with open(os.path.join(out, name), 'wb') as f:
        f.write(records(items))
    print(name, len(items), 'writes')
