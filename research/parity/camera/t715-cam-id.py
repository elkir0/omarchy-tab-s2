#!/usr/bin/env python3
import fcntl, os, sys
I2C_SLAVE = 0x0703

def rd(bus, addr, reg, n):
    fd = os.open(f'/dev/i2c-{bus}', os.O_RDWR)
    try:
        fcntl.ioctl(fd, I2C_SLAVE, addr)
        os.write(fd, bytes([reg >> 8, reg & 0xff]))
        return os.read(fd, n)
    finally:
        os.close(fd)

def show(label, bus, addr, reg, n):
    try:
        d = rd(bus, addr, reg, n)
        print(f'{label} i2c-{bus} 0x{addr:02x} reg 0x{reg:04x}: {d.hex()} {d!r}')
    except OSError as e:
        print(f'{label} i2c-{bus} 0x{addr:02x} reg 0x{reg:04x}: {e}')

what = sys.argv[1]
if what == 'eeprom':
    show('header', 4, 0x58, 0x20, 11)
    show('calmap', 4, 0x58, 0x30, 4)
    show('control', 4, 0x59, 0x20, 1)
elif what == 'front':
    for i in range(2):
        show('front id', 22, 0x35, 0x0000, 6)
    show('control', 22, 0x34, 0x0000, 2)
elif what == 'rear':
    for i in range(2):
        show('rear id', 21, 0x37, 0x0000, 6)
    show('control', 21, 0x36, 0x0000, 2)
    show('af ack', 21, 0x0c, 0x0000, 1)
