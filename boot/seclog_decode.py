#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Decode a raw dump of Samsung's "sec_log" RAM area into text.

The stock kernel (drivers/staging/samsung/sec_log.c) keeps a persistent
kernel log handed over across reboots::

    base - 8   u32 magic  0x4d474f4c ("LOGM"); anything else means the
               buffer did not survive the previous boot
    base - 4   u32 ptr    monotonic count of bytes ever written (u32,
               wraps only after 4 GiB of log)
    base       ring buffer of `size` bytes, `size` a power of two

Every console message is copied at ``ptr & (size - 1)`` (wrapping in two
memcpys) and then ``ptr`` advances, so the ring always holds the *last*
``size`` bytes and the readable log is the last ``min(ptr, size)`` bytes
unwrapped oldest-first -- exactly what the stock ``sec_log_save_old()``
reconstructs into /proc/last_kmsg.

FILE is a raw physical dump of [base-8, base+size): 8 header bytes
followed by the ring (little endian).  Example for the SM-T715 ground
truth::

    seclog_decode.py dump.bin --base 0x26000000 --size 0x200000
"""

import argparse
import struct
import sys

SEC_LOG_MAGIC = 0x4D474F4C          # "LOGM"
HEADER_SIZE = 8


def decode_dump(data, size, cap=None):
    """Decode a raw [base-8, base+size) dump; return the log as bytes.

    `cap` limits the amount reconstructed, like the stock reader's
    ``min(1 << CONFIG_LOG_BUF_SHIFT, ptr)`` (default: no cap).
    Raises ValueError on a bad header or a size that is not a power of
    two.
    """
    if len(data) < HEADER_SIZE + size:
        raise ValueError(
            "dump too short: %d bytes, need %d (header + 0x%x ring)"
            % (len(data), HEADER_SIZE + size, size))
    if size == 0 or size & (size - 1):
        raise ValueError("ring size 0x%x is not a power of two" % size)

    magic, ptr = struct.unpack_from("<II", data, 0)
    if magic != SEC_LOG_MAGIC:
        raise ValueError("bad magic 0x%08x (expected 0x%08x): the buffer "
                         "did not survive the previous boot"
                         % (magic, SEC_LOG_MAGIC))

    ring = data[HEADER_SIZE:HEADER_SIZE + size]
    n = min(ptr, size) if cap is None else min(ptr, size, cap)
    return bytes(ring[(ptr - n + i) & (size - 1)] for i in range(n))


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Decode a raw Samsung sec_log dump into text.")
    parser.add_argument("file", help="raw dump of [base-8, base+size)")
    parser.add_argument("--base", default="0x26000000",
                        help="ring physical address (default 0x26000000; "
                             "informational, the dump layout is what is "
                             "parsed)")
    parser.add_argument("--size", default="0x200000",
                        help="ring size in bytes, power of two "
                             "(default 0x200000)")
    parser.add_argument("--cap", default=None, type=lambda s: int(s, 0),
                        help="reconstruct at most this many bytes, like "
                             "the stock reader's LOG_BUF_SHIFT cap")
    args = parser.parse_args(argv)

    base = int(args.base, 0)
    size = int(args.size, 0)
    try:
        with open(args.file, "rb") as f:
            data = f.read()
        out = decode_dump(data, size, args.cap)
    except (OSError, ValueError) as e:
        parser.exit(1, "error: %s\n" % e)
    sys.stdout.write(out.decode("utf-8", errors="replace"))
    if not out.endswith(b"\n"):
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
