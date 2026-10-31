#!/usr/bin/env python3
# Drive the rear sensor over /dev/i2c-21 from the mode tables of the ISP firmware,
# an owner's copy on the tablet. Test tool.
#   t715-cam-rear.py FW init MODE | on | off | exp COARSE GAIN [FLL]
import fcntl, os, struct, sys
I2C_SLAVE, ADDR, BUS = 0x0703, 0x37, 21
TABLES, STEP, ENTRIES = 0x188490, 0x4f8, 106

def w(fd, reg, val, n):
    os.write(fd, bytes([reg >> 8, reg & 0xff]) + val.to_bytes(n, 'big'))

def rd(fd, reg, n):
    os.write(fd, bytes([reg >> 8, reg & 0xff]))
    return os.read(fd, n)

fd = os.open('/dev/i2c-%d' % BUS, os.O_RDWR)
fcntl.ioctl(fd, I2C_SLAVE, ADDR)
cmd = sys.argv[2]
if cmd == 'init':
    d = open(sys.argv[1], 'rb').read()
    o = TABLES + int(sys.argv[3]) * STEP
    print('id', rd(fd, 0, 6).hex())
    w(fd, 0x0104, 1, 1)
    for i in range(ENTRIES):
        width, reg, val = struct.unpack_from('<III', d, o + i * 12)
        if width not in (1, 2):
            sys.exit('bad entry %d' % i)
        w(fd, reg, val, width)
    w(fd, 0x0104, 0, 1)
    print('size', rd(fd, 0x034c, 4).hex(), 'fll', rd(fd, 0x0340, 2).hex(), 'llp', rd(fd, 0x0342, 2).hex())
elif cmd == 'exp':
    w(fd, 0x0202, int(sys.argv[3], 0), 2)
    w(fd, 0x0204, int(sys.argv[4], 0), 2)
    if len(sys.argv) > 5:
        w(fd, 0x0340, int(sys.argv[5], 0), 2)
elif cmd == 'on':
    w(fd, 0x0100, 1, 1)
elif cmd == 'off':
    w(fd, 0x0100, 0, 1)
print('0x0100', rd(fd, 0x0100, 1).hex(), 'frame count', rd(fd, 0x0005, 1).hex())
