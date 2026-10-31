#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Canary in the no-map CP guard region (cp-guard@de920000, 384 KiB, above the
# 8 MiB shared region and below the end of DRAM): `canary.py set` fills it
# with a seeded pattern, `canary.py check` verifies it is unchanged, so a CP
# write beyond the shared region shows up (kernel_boot_review.md D3-c).
# The region is reserved no-map: nothing in Linux uses it.
import hashlib, mmap, os, sys

BASE, SIZE = 0xde920000, 0x60000

def pattern():
    out, block, i = bytearray(), b"", 0
    while len(out) < SIZE:
        block = hashlib.sha256(b"t715-cp-guard-canary" + i.to_bytes(4, "little")).digest()
        out += block
        i += 1
    return bytes(out[:SIZE])

def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "check"
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    m = mmap.mmap(fd, SIZE, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=BASE)
    p = pattern()
    if mode == "set":
        m[:] = p
        print("canary set:", hashlib.sha256(m[:]).hexdigest()[:16])
    else:
        cur = bytes(m[:])
        bad = sum(1 for a, b in zip(cur, p) if a != b)
        first = next((i for i, (a, b) in enumerate(zip(cur, p)) if a != b), None)
        print("canary %s: %d byte(s) differ%s" % ("OK" if bad == 0 else "CHANGED", bad,
              "" if first is None else ", first at 0x%x" % (BASE + first)))
        sys.exit(0 if bad == 0 else 3)

if __name__ == "__main__":
    main()
