#!/usr/bin/env python3
# Play the vibration motor and look for it on the accelerometer. Test tool.
import fcntl, glob, os, statistics, struct, sys, time

def find_event(name):
    for p in sorted(glob.glob('/sys/class/input/event*/device/name')):
        if open(p).read().strip() == name:
            return '/dev/input/' + p.split('/')[4]
    return None

def accel():
    for p in glob.glob('/sys/bus/iio/devices/iio:device*'):
        if os.path.exists(p + '/in_accel_x_raw'):
            return p
    return None

def sample(dev, seconds):
    out = {'x': [], 'y': [], 'z': []}
    end = time.time() + seconds
    while time.time() < end:
        for a in 'xyz':
            out[a].append(int(open('%s/in_accel_%s_raw' % (dev, a)).read()))
    return {a: (len(v), round(statistics.pstdev(v), 2)) for a, v in out.items()}

ev = find_event('pwm-vibrator')
print('device', ev)
if not ev:
    sys.exit(1)
strong = int(sys.argv[1], 0) if len(sys.argv) > 1 else 0xffff
ms = int(sys.argv[2]) if len(sys.argv) > 2 else 1500
fd = os.open(ev, os.O_RDWR)
EVIOCSFF = 0x402c4580
FF_RUMBLE, EV_FF = 0x50, 0x15
eff = bytearray(struct.pack('<HhHHHHHxxHH', FF_RUMBLE, -1, 0, 0, 0, ms, 0, strong, 0).ljust(44, b'\0'))
fcntl.ioctl(fd, EVIOCSFF, eff, True)
eid = struct.unpack_from('<h', eff, 2)[0]
print('effect id', eid)
a = accel()
print('accel', a)
if a:
    print('quiet ', sample(a, 1.0))
os.write(fd, struct.pack('<llHHi', 0, 0, EV_FF, eid, 1))
if a:
    print('motor ', sample(a, ms / 1000 - 0.2))
else:
    time.sleep(ms / 1000)
time.sleep(0.5)
if a:
    print('after ', sample(a, 1.0))
os.close(fd)
