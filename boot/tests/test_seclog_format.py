#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Format tests for the Samsung "sec_log" RAM ring buffer.

Re-implements, in Python, (a) the stock writer emit_sec_log() and (b)
the stock reader sec_log_save_old(), from
src/kernel_universal5433/drivers/staging/samsung/sec_log.c, then
checks on random message streams (including wrap-around and the
exact-full case) that what the reader reconstructs equals the tail of
the written stream -- the same property the mainline driver
drivers/soc/samsung/sec-log-console.c relies on.

Stock ground truth (byte-exact):

* writer: copy at ``ptr & (size-1)``; if it does not fit, two memcpys
  (tail to the end of the ring, remainder to offset 0); then
  ``ptr += len``.  ``ptr`` is a monotonic u32 byte counter.
* reader: ``n = min(1 << LOG_BUF_SHIFT, ptr)``; the old log is
  ``ring[(ptr - n + i) & (size-1)]`` for i in 0..n-1 -- the last n bytes
  written, oldest first.
"""

import os
import random
import struct
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO_ROOT, "boot"))

import seclog_decode  # noqa: E402

SEC_LOG_MAGIC = 0x4D474F4C          # "LOGM"
STOCK_LOG_BUF_SHIFT = 19            # stock device defconfig


class SecLogRing:
    """In-memory sec_log area: header + ring, written like the stock kernel."""

    def __init__(self, size, init_ptr=0):
        if size & (size - 1) or size <= 0:
            raise ValueError("size must be a power of two")
        self.size = size
        self.ring = bytearray(size)
        self.ptr = init_ptr & 0xFFFFFFFF

    def emit(self, text):
        """Stock emit_sec_log(), byte for byte.

        A message longer than the ring would overflow the stock C
        buffer (its second memcpy writes past ring end); real printk
        lines are far below the ring size, so refuse the case instead
        of modeling the corruption.
        """
        size = len(text)
        if size > self.size:
            raise ValueError("message %d bytes exceeds ring 0x%x"
                             % (size, self.size))
        pos = self.ptr & (self.size - 1)
        if size + pos <= self.size:
            self.ring[pos:pos + size] = text
        else:
            first = self.size - pos
            second = size - first
            self.ring[pos:pos + first] = text[:first]
            self.ring[0:second] = text[first:first + second]
        self.ptr = (self.ptr + size) & 0xFFFFFFFF
        # the ring "wraps" only via ptr masking; full only matters to
        # the stock reader through min(ptr, size)

    def save_old(self, log_buf_shift=STOCK_LOG_BUF_SHIFT):
        """Stock sec_log_save_old(): the readable previous log."""
        n = min((1 << log_buf_shift) & 0xFFFFFFFF, self.ptr)
        return bytes(self.ring[(self.ptr - n + i) & (self.size - 1)]
                     for i in range(n))


class RandomStreams(unittest.TestCase):
    """Reader reconstruction == tail of the written stream, on randoms.

    The stock reader caps at ``min(1 << LOG_BUF_SHIFT, ptr)`` without
    clamping to the ring size, so the tail property only holds while
    the cap does not exceed the size -- the case on the real device
    (stock cap 512 KiB < ring 2 MiB).  All checks below keep
    ``1 << cap_shift <= size``; the cap-exceeds-size artifact is pinned
    separately in test_stock_reader_duplicating_cap.
    """

    def check(self, size, total_len, cap_shift, seed, exact_full=False):
        assert (1 << cap_shift) <= size, "cap must not exceed the ring size"
        rng = random.Random(seed)
        ring = SecLogRing(size)
        stream = bytearray()
        while len(stream) < total_len:
            # message lengths like real printk lines
            n = rng.randint(1, min(160, 2 * size))
            msg = bytes(rng.randrange(0x20, 0x7f) for _ in range(n))
            ring.emit(msg)
            stream += msg
        if exact_full:
            # pad so the stream ends exactly at a multiple of size
            pad = (size - (len(stream) % size)) % size
            msg = b"x" * pad
            ring.emit(msg)
            stream += msg
            self.assertEqual(ring.ptr % size, 0)

        expect = bytes(stream[-min(len(stream), 1 << cap_shift):])
        got = ring.save_old(cap_shift)
        self.assertEqual(got, expect)

    def test_no_wrap(self):
        """Total below the ring size: the whole stream is readable."""
        self.check(size=0x1000, total_len=0x800, cap_shift=12, seed=1)

    def test_wraparound(self):
        """Several wraps: only the last ring-full survives."""
        self.check(size=0x1000, total_len=0x5000, cap_shift=12, seed=2)

    def test_exact_full(self):
        """Stream length a multiple of size: boundary single-memcpy case."""
        for seed in (3, 4):
            self.check(size=0x1000, total_len=0x2300, cap_shift=12,
                       seed=seed, exact_full=True)

    def test_capped_by_log_buf(self):
        """Reader cap < ring: only the last cap bytes are reconstructed."""
        self.check(size=0x80000, total_len=0x100000, cap_shift=17, seed=5)

    def test_many_random_configurations(self):
        """Sweep sizes, caps and seeds, including device-like caps."""
        for i, (size, total, cap, seed) in enumerate([
                (0x1000, 0x1000, 12, 10),
                (0x2000, 0x9000, 13, 11),
                (0x40000, 0x150000, 18, 12),
                (0x80000, 0x200000, 19, 13),
        ]):
            with self.subTest(case=i, size=size, cap=cap, seed=seed):
                self.check(size, total, cap, seed)

    def test_stock_reader_cap_larger_than_ring(self):
        """A cap above the ring size is a stock quirk, not modeled here.

        The stock sec_log_save_old() reads ``min(1 << LOG_BUF_SHIFT,
        ptr)`` bytes through the ring mask without clamping to the ring
        size, so a cap above the ring size re-reads cells and the output
        is no longer the true tail of the stream.  On the real device
        the cap (512 KiB, LOG_BUF_SHIFT=19) stays below the ring
        (2 MiB), so the quirk cannot trigger; every other test asserts
        ``1 << cap_shift <= size`` like the device.  This one just pins
        the quirk's trigger condition.
        """
        size = 0x1000
        ring = SecLogRing(size)
        while ring.ptr < size + 100:
            ring.emit(b"x" * 64)
        n = min(1 << STOCK_LOG_BUF_SHIFT, ring.ptr)
        self.assertGreater(n, size)               # the quirk condition


class WriteModel(unittest.TestCase):
    """The Python writer model pins the stock emit algorithm exactly."""

    def test_emit_refuses_message_larger_than_ring(self):
        """A message longer than the ring would overflow the C buffer."""
        ring = SecLogRing(0x400)
        with self.assertRaises(ValueError):
            ring.emit(b"a" * 0x500)

    def test_emit_boundary_one_memcpy(self):
        """pos+len == size stays a single memcpy (stock uses <=)."""
        ring = SecLogRing(0x10)
        ring.emit(b"0123456789")                  # pos 0 -> 10
        ring.emit(b"abcdef")                      # 10+6 == 16: one copy
        self.assertEqual(ring.ptr, 16)
        self.assertEqual(bytes(ring.ring), b"0123456789abcdef")
        ring.emit(b"XY")                          # pos wraps to 0
        self.assertEqual(bytes(ring.ring), b"XY23456789abcdef")
        self.assertEqual(ring.ptr, 18)

    def test_emit_wrap_two_parts(self):
        """Pin a wrap split across the ring end."""
        ring = SecLogRing(0x10)
        ring.emit(b"A" * 14)                      # pos 0 -> 14
        ring.emit(b"BCDE")                        # 14+4 > 16: 2 + 2
        self.assertEqual(bytes(ring.ring), b"DE" + b"A" * 12 + b"BC")
        self.assertEqual(ring.ptr, 18)

    def test_emit_u32_ptr_wrap(self):
        """ptr wraps at 2**32 exactly like the stock u32 counter."""
        ring = SecLogRing(0x10, init_ptr=(1 << 32) - 3)
        ring.emit(b"wxyz")
        self.assertEqual(ring.ptr, 1)
        # the write happened at pos (2**32-3)&0xf = 13: 3 bytes at the
        # ring end, 1 at the start
        self.assertEqual(bytes(ring.ring[13:]), b"wxy")
        self.assertEqual(bytes(ring.ring[0:1]), b"z")

    def test_ptr_u32_wraparound(self):
        """ptr truncates at 2**32 like the stock u32 counter."""
        ring = SecLogRing(0x1000, init_ptr=(1 << 32) - 7)
        ring.emit(b"abcdefgh")
        self.assertEqual(ring.ptr, 1)             # wrapped mod 2**32
        # The stock reader sees n = min(cap, ptr) = 1 byte: everything
        # but the last written byte is unrecoverable after the wrap.
        self.assertEqual(ring.save_old(STOCK_LOG_BUF_SHIFT), b"h")

    def test_single_message_larger_than_half_ring(self):
        """A message longer than size/2 must still wrap correctly."""
        ring = SecLogRing(0x400)
        msg = bytes((i * 7 + 3) & 0xff for i in range(0x300))
        ring.emit(msg)
        self.assertEqual(ring.save_old(10), msg)


class DecodeScript(unittest.TestCase):
    """seclog_decode.py decodes a synthetic dump of [base-8, base+size)."""

    def build_dump(self, size, stream, cap_shift=STOCK_LOG_BUF_SHIFT):
        """Emit `stream` as message-sized writes (a real kernel log), then
        return (raw dump of [base-8, base+size), stock reader output)."""
        rng = random.Random(0xBEEF)
        ring = SecLogRing(size)
        off = 0
        while off < len(stream):
            n = rng.randint(1, 160)
            ring.emit(stream[off:off + n])
            off += n
        return (struct.pack("<II", SEC_LOG_MAGIC, ring.ptr) + bytes(ring.ring),
                ring.save_old(cap_shift))

    def test_decode_matches_stock_reader(self):
        for size, total, cap, seed in [(0x1000, 0x3500, 12, 20),
                                       (0x80000, 0x90000, 19, 21)]:
            with self.subTest(size=size, seed=seed):
                rng = random.Random(seed)
                stream = bytes(rng.randrange(0x20, 0x7f)
                               for _ in range(total))
                dump, expect = self.build_dump(size, stream, cap)
                got = seclog_decode.decode_dump(dump, size, cap=1 << cap)
                self.assertEqual(got, expect)
                # uncapped decoding reconstructs the full ring content
                self.assertEqual(got, stream[-min(len(stream), size):])

    def test_decode_no_wrap(self):
        stream = b"[    0.000000] Booting mainline on Exynos5433\n"
        dump, expect = self.build_dump(0x1000, stream)
        got = seclog_decode.decode_dump(dump, 0x1000)
        self.assertEqual(got, expect)
        self.assertEqual(got, stream)

    def test_decode_bad_magic(self):
        dump = struct.pack("<II", 0xDEADBEEF, 8) + b"\0" * 0x1000
        with self.assertRaises(ValueError):
            seclog_decode.decode_dump(dump, 0x1000)

    def test_decode_rejects_non_power_of_two(self):
        dump = struct.pack("<II", SEC_LOG_MAGIC, 8) + b"\0" * 0x1000
        with self.assertRaises(ValueError):
            seclog_decode.decode_dump(dump, 0x1800)

    def test_decode_short_dump(self):
        dump = struct.pack("<II", SEC_LOG_MAGIC, 8) + b"\0" * 0x100
        with self.assertRaises(ValueError):
            seclog_decode.decode_dump(dump, 0x1000)

    def test_decode_cap(self):
        stream = bytes(range(0x20, 0x60)) * 0x20          # 0x400 bytes
        dump, expect = self.build_dump(0x1000, stream, cap_shift=8)
        got = seclog_decode.decode_dump(dump, 0x1000, cap=1 << 8)
        self.assertEqual(got, expect)
        self.assertEqual(got, stream[-(1 << 8):])

    def test_decode_cli_smoke(self):
        """The CLI decodes a file end-to-end (capture to avoid noisy output)."""
        import io
        import contextlib

        stream = b"hello sec_log\n"
        dump, expect = self.build_dump(0x1000, stream)
        path = os.path.join(self.dirpath(), "seclog-dump-tmp.bin")
        with open(path, "wb") as f:
            f.write(dump)
        try:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc = seclog_decode.main(["--size", "0x1000", path])
            self.assertEqual(rc, 0)
            self.assertEqual(out.getvalue().encode(), expect)
        finally:
            os.unlink(path)

    @staticmethod
    def dirpath():
        return os.path.dirname(os.path.abspath(__file__))


if __name__ == "__main__":
    unittest.main()
