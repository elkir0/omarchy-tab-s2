#!/usr/bin/env python3
# Drive the front sensor over /dev/i2c-22 from a private sequence file. Test tool.
#   t715-cam-init.py SEQFILE init|on|off|exp COARSE GAIN
import fcntl, os, re, sys, time
I2C_SLAVE, ADDR, BUS = 0x0703, 0x35, 22

def w(fd, reg, val, n):
    os.write(fd, bytes([reg >> 8, reg & 0xff]) + val.to_bytes(n, 'big'))

def rd(fd, reg, n):
    os.write(fd, bytes([reg >> 8, reg & 0xff]))
    return os.read(fd, n)

def func(path, addr):
    out, on = [], False
    for line in open(path):
        m = re.match(r'FUNC (0x[0-9a-f]+)', line)
        if m:
            on = int(m.group(1), 16) == addr
            continue
        m = re.match(r'\s+0x[0-9a-f]+ (W8|W16|W8hold) (0x[0-9a-f]+) (0x[0-9a-f]+)', line)
        if on and m:
            out.append((m.group(1), int(m.group(2), 16), int(m.group(3), 16)))
    return out

fd = os.open('/dev/i2c-%d' % BUS, os.O_RDWR)
fcntl.ioctl(fd, I2C_SLAVE, ADDR)
cmd = sys.argv[2]
if cmd == 'init':
    print('id', rd(fd, 0, 6).hex())
    n = 0
    for kind, reg, val in func(sys.argv[1], 0x77498) + func(sys.argv[1], 0x78548):
        if kind == 'W8hold':
            continue    # the stock sequence reads the revision here, a read
        w(fd, reg, val, 2 if kind == 'W16' else 1)
        n += 1
    print('wrote', n)
    print('fll', rd(fd, 0x0340, 2).hex(), 'llp', rd(fd, 0x0342, 2).hex())
elif cmd == 'exp':
    w(fd, 0x0202, int(sys.argv[3], 0), 2)
    w(fd, 0x0204, int(sys.argv[4], 0), 2)
    if len(sys.argv) > 5:
        w(fd, 0x0340, int(sys.argv[5], 0), 2)
elif cmd == 'on':
    w(fd, 0x0100, 1, 1)
elif cmd == 'off':
    w(fd, 0x0100, 0, 1)
print('0x0100', rd(fd, 0x0100, 1).hex(), 'frame count 0x0005', rd(fd, 0x0005, 1).hex())
