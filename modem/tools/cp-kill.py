#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Emergency CP power-off through the GPIO registers (/dev/mem), for when the
# modem driver is not loaded or is wedged and the CP may still be powered
# (kernel_boot_review.md rule 22). Order: CP_RESET (gpc0-5) low, then CP_ON
# (gpr3-1) low; each line gets DAT=0 before CON=output, so it never glitches
# high. --check only prints the two lines. Bypasses gpiolib: emergency only.
import mmap, os, struct, sys

LINES = (  # name, CON register, pin
    ("CP_RESET gpc0-5", 0x14cc0040, 5),   # SYNTHESIS.md 2.2; pinctrl-exynos-arm64.c gpc0 @0x040 of 0x14cc0000
    ("CP_ON gpr3-1", 0x156900a0, 1),      # gpr3 @0x0a0 of 0x15690000
)

def rw(fd, addr, val=None):
    base = addr & ~0xfff
    prot = mmap.PROT_READ | (mmap.PROT_WRITE if val is not None else 0)
    m = mmap.mmap(fd, 4096, mmap.MAP_SHARED, prot, offset=base)
    old = struct.unpack_from("<I", m, addr - base)[0]
    if val is not None:
        struct.pack_into("<I", m, addr - base, val)
    m.close()
    return old

def main():
    check = "--check" in sys.argv
    fd = os.open("/dev/mem", (os.O_RDONLY if check else os.O_RDWR) | os.O_SYNC)
    for name, con, pin in LINES:
        dat = con + 4
        c, d = rw(fd, con), rw(fd, dat)
        print("%s: func %x level %d" % (name, (c >> (4 * pin)) & 0xf, (d >> pin) & 1))
        if check:
            continue
        rw(fd, dat, d & ~(1 << pin))
        rw(fd, con, (c & ~(0xf << (4 * pin))) | (0x1 << (4 * pin)))
        c, d = rw(fd, con), rw(fd, dat)
        print("  -> func %x level %d" % ((c >> (4 * pin)) & 0xf, (d >> pin) & 1))

if __name__ == "__main__":
    main()
