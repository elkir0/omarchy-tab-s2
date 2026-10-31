#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Tests for zimage_extract.py.

Groups:
- pure LZO1X: hand-crafted minimal streams (literal run, match, EOF marker)
  against the port of lib/lzo/lzo1x_decompress_safe.c;
- synthetic containers: zImage-like files (header words at 0x24 + payload)
  for gzip, xz, lzma-alone (exercises the aligned brute-force fallback),
  lz4 (needs the lz4 CLI, skipped otherwise) and kernel-framed LZO built
  from stored blocks (dst_len == src_len, so no compressor is needed);
- IKCONFIG: round trip, absence, and the ST-without-ED error;
- decoys: an lzop magic at an aligned offset that fails trial decompression
  must not hide the real payload behind it;
- the real stock dump (skipped when dumps/stock/unpacked/kernel is
  absent): full pipeline + the exact offsets found on the SM-T715 kernel.
"""

import gzip
import lzma
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO_ROOT, "boot"))

import zimage_extract as ze  # noqa: E402

REAL_KERNEL = os.path.join(REPO_ROOT, "dumps", "stock", "unpacked",
                           "kernel")
SKIP_REAL = ("stock kernel dump not present (%s)" % REAL_KERNEL)


class TempDirTest(unittest.TestCase):
    """Base class giving each test a fresh scratch directory."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="zimage_test_")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def path(self, *names):
        return os.path.join(self.tmp, *names)


# ---------------------------------------------------------------------------
# container builders
# ---------------------------------------------------------------------------

def make_zimage(payload, payload_off=0x100, start=0x8000):
    """A minimal zImage: 0x30 bytes of head.S filler (header words at 0x24),
    padding up to the word-aligned payload, payload; _edata == file size."""
    img = bytearray(b"\xe1\xa0\x00\x00" * 9)          # 0x00..0x23 MOV r0,r0
    img += struct.pack("<III", ze.ZIMAGE_MAGIC, start,
                       payload_off + len(payload))    # magic, start, _edata
    img += bytes(payload_off - 0x30)                  # 'decompressor' filler
    img += payload
    return bytes(img)


def lzop_stored_stream(chunks):
    """An lzop file whose blocks are stored (dst_len == src_len), exactly as
    lib/decompress_unlzo.c consumes them; checksums are real adler32."""
    fields = struct.pack(">HHH", 0x0940, 0x2060, 0x0940)   # ver/lib/need
    fields += bytes([1, 5])                       # method LZO1X_1, level
    fields += struct.pack(">I", 0x00000001)       # flags: ADLER32_D
    fields += struct.pack(">II", 0o100644, 0)     # mode, mtime_lo
    fields += struct.pack(">I", 0)                # mtime_hi (ver >= 0x0940)
    fields += bytes([0])                          # empty name
    hdr = (ze.LZOP_MAGIC + fields +
           struct.pack(">I", zlib.adler32(fields)))
    parts = [hdr]
    for chunk in chunks:
        assert 0 < len(chunk) <= ze.LZO_BLOCK_SIZE
        parts.append(struct.pack(">III", len(chunk), len(chunk),
                                 zlib.adler32(chunk)))
        parts.append(chunk)
    parts.append(struct.pack(">I", 0))            # dst_len == 0: terminator
    return b"".join(parts)


def make_image_with_ikconfig(config_bytes, body=b"vmlinux body\n"):
    return body + b"IKCFG_ST" + gzip.compress(config_bytes) + b"IKCFG_ED"


def write(path, data):
    with open(path, "wb") as f:
        f.write(data)
    return path


# ---------------------------------------------------------------------------
# LZO1X decompressor (hand-crafted streams)
# ---------------------------------------------------------------------------

class TestLzo1x(TempDirTest):

    def decompress(self, stream, out_cap):
        out, produced, code = ze.lzo1x_decompress_safe(stream, len(stream),
                                                       out_cap)
        return out[:produced], code

    def test_literal_run_then_eof(self):
        # 0x15 = 17+4: literal run of 4; M4 token 0x11 + le16 0 = EOF marker
        out, code = self.decompress(b"\x15AAAA\x11\x00\x00", 64)
        self.assertEqual(code, ze.LZO_E_OK)
        self.assertEqual(out, b"AAAA")

    def test_short_literal_match_then_eof(self):
        # 'ABCD', then M2-style match t=0x6c: len 4, offset 4, next 0; EOF
        out, code = self.decompress(b"\x15ABCD\x6c\x00\x11\x00\x00", 64)
        self.assertEqual(code, ze.LZO_E_OK)
        self.assertEqual(out, b"ABCDABCD")

    def test_truncated_input(self):
        out, produced, code = ze.lzo1x_decompress_safe(b"\x15AA", 2, 64)
        self.assertEqual(code, ze.LZO_E_INPUT_OVERRUN)

    def test_input_not_consumed(self):
        # valid stream followed by extra bytes -> INPUT_NOT_CONSUMED (-8)
        out, produced, code = ze.lzo1x_decompress_safe(
            b"\x15AAAA\x11\x00\x00" + b"\x00", 10, 64)
        self.assertEqual(code, ze.LZO_E_INPUT_NOT_CONSUMED)


# ---------------------------------------------------------------------------
# synthetic containers
# ---------------------------------------------------------------------------

class TestSyntheticContainers(TempDirTest):

    def check_roundtrip(self, payload, expected_fmt, expected_image):
        img = make_zimage(payload)
        hdr = ze.ZImageHeader(img)
        self.assertTrue(hdr.valid)
        self.assertEqual(hdr.end, len(img))
        self.assertEqual(hdr.trailing, 0)
        hit = ze.find_payload(img, hdr.end)
        self.assertIsNotNone(hit)
        off, fmt, image, _meta = hit
        self.assertEqual(fmt, expected_fmt)
        self.assertEqual(off % 4, 0)
        self.assertEqual(image, expected_image)
        return img, off

    def test_gzip_payload(self):
        blob = os.urandom(4096)
        self.check_roundtrip(b"\x00\x00\x00\x00" + gzip.compress(blob),
                             "gzip", blob)

    def test_xz_payload(self):
        blob = os.urandom(4096)
        self.check_roundtrip(lzma.compress(blob), "xz", blob)

    def test_lzma_alone_payload_needs_brute_force(self):
        # lzma-alone has no magic: pass 1 must fail, pass 2 (aligned trial
        # decompression bounded by _edata) must find it
        blob = os.urandom(2048)
        filt = [{"id": lzma.FILTER_LZMA1, "preset": 6}]
        comp = lzma.compress(blob, format=lzma.FORMAT_ALONE, filters=filt)
        img, off = self.check_roundtrip(comp, "lzma-alone", blob)
        self.assertEqual(off, 0x100)

    def test_lzo_stored_blocks(self):
        chunks = [b"hello " * 1000, b"world" * 700, os.urandom(333)]
        blob = b"".join(chunks)
        stream = lzop_stored_stream(chunks)
        img, off = self.check_roundtrip(stream, "lzo-kernel", blob)
        _off, fmt, image, meta = ze.find_payload(img, len(img))
        info = meta["info"]
        self.assertEqual(info["nblocks"], 3)
        self.assertTrue(info["hdr_cksum_ok"])
        self.assertEqual(meta["end"], off + len(stream))
        self.assertEqual(info["flags"], 0x1)
        self.assertEqual(info["name"], b"")

    def test_lzo_bad_header_checksum_is_flagged(self):
        stream = bytearray(lzop_stored_stream([b"abc"]))
        hlen = ze.parse_lzop_header(bytes(stream), 0)["blocks_off"]
        stream[hlen - 1] ^= 0xFF               # corrupt the header checksum
        h = ze.parse_lzop_header(bytes(stream), 0)
        self.assertIsNotNone(h)
        self.assertFalse(h["hdr_cksum_ok"])

    def test_lzo_truncated_block_raises(self):
        stream = lzop_stored_stream([b"abc" * 100])
        with self.assertRaises(ValueError):
            ze.decompress_lzo_stream(stream[:-10], 0)

    def test_decoy_magic_does_not_hide_real_payload(self):
        # a corrupted lzop stream at an aligned offset (what a magic inside
        # the decompressor's .rodata looks like) must not stop the scan
        blob = os.urandom(4096)
        decoy = ze.LZOP_MAGIC + b"garbage that is not an lzop header"
        pad = b"\x00" * (0x40 + (-len(decoy)) % 4)   # keep the payload aligned
        real = b"\x00\x00\x00\x00" + gzip.compress(blob)
        img = make_zimage(decoy + pad + real, payload_off=0x100)
        hit = ze.find_payload(img, len(img))
        self.assertIsNotNone(hit)
        off, fmt, image, _meta = hit
        self.assertEqual(fmt, "gzip")
        self.assertEqual(image, blob)

    def test_no_payload(self):
        img = make_zimage(os.urandom(256))
        self.assertIsNone(ze.find_payload(img, len(img)))

    def test_header_too_small(self):
        with self.assertRaises(ValueError):
            ze.ZImageHeader(b"\x00" * 16)

    def test_appended_data_reported(self):
        img = make_zimage(b"payload") + b"APPENDED DTB"
        hdr = ze.ZImageHeader(img)
        self.assertTrue(hdr.valid)
        self.assertEqual(hdr.trailing, len(b"APPENDED DTB"))


# ---------------------------------------------------------------------------
# IKCONFIG
# ---------------------------------------------------------------------------

class TestIkconfig(TempDirTest):

    def test_roundtrip(self):
        cfg = b"CONFIG_A=y\n# CONFIG_B is not set\n"
        image = make_image_with_ikconfig(cfg)
        self.assertEqual(ze.extract_ikconfig(image), cfg)

    def test_absent(self):
        self.assertIsNone(ze.extract_ikconfig(b"no config in here"))

    def test_st_without_ed(self):
        with self.assertRaises(ValueError):
            ze.extract_ikconfig(b"IKCFG_ST" + gzip.compress(b"x=y\n"))

    def test_non_gzip_blob(self):
        with self.assertRaises(ValueError):
            ze.extract_ikconfig(b"IKCFG_STnot gzip at allIKCFG_ED")


# ---------------------------------------------------------------------------
# main() end to end
# ---------------------------------------------------------------------------

class TestMain(TempDirTest):

    def run_main(self, kernel, outdir, *extra):
        argv = [kernel, "-o", outdir] + list(extra)
        return ze.main(argv)

    def test_gzip_with_ikconfig(self):
        cfg = b"CONFIG_FOO=y\nCONFIG_BAR=1\n"
        payload = gzip.compress(make_image_with_ikconfig(cfg))
        kernel = write(self.path("zImage"), make_zimage(payload))
        outdir = self.path("out")
        rc = self.run_main(kernel, outdir)
        self.assertEqual(rc, 0)
        with open(os.path.join(outdir, "Image.stock"), "rb") as f:
            self.assertEqual(f.read(), make_image_with_ikconfig(cfg))
        with open(os.path.join(outdir, "running_kernel.config"), "rb") as f:
            self.assertEqual(f.read(), cfg)

    def test_lzo_no_ikconfig(self):
        chunks = [b"the kernel image " * 100]
        kernel = write(self.path("zImage"),
                       make_zimage(lzop_stored_stream(chunks)))
        outdir = self.path("out")
        rc = self.run_main(kernel, outdir)
        self.assertEqual(rc, 0)
        self.assertTrue(os.path.exists(os.path.join(outdir, "Image.stock")))
        self.assertFalse(
            os.path.exists(os.path.join(outdir, "running_kernel.config")))

    def test_no_write(self):
        payload = gzip.compress(b"image")
        kernel = write(self.path("zImage"), make_zimage(payload))
        outdir = self.path("out")
        rc = self.run_main(kernel, outdir, "--no-write")
        self.assertEqual(rc, 0)
        self.assertEqual(os.listdir(outdir) if os.path.isdir(outdir) else [],
                         [])

    def test_unfindable_payload(self):
        kernel = write(self.path("zImage"), make_zimage(os.urandom(256)))
        rc = self.run_main(kernel, self.path("out"))
        self.assertEqual(rc, 1)


# ---------------------------------------------------------------------------
# lz4 (external CLI)
# ---------------------------------------------------------------------------

@unittest.skipUnless(shutil.which("lz4"), "lz4 CLI not installed")
class TestLz4(TempDirTest):

    def test_frame_payload(self):
        blob = os.urandom(8192)
        proc = subprocess.run(["lz4", "-z", "-c", "-q"], input=blob,
                              capture_output=True)
        self.assertEqual(proc.returncode, 0)
        img = make_zimage(b"\x00\x00\x00\x00" + proc.stdout)
        hit = ze.find_payload(img, len(img))
        self.assertIsNotNone(hit)
        _off, fmt, image, _meta = hit
        self.assertEqual(fmt, "lz4-frame")
        self.assertEqual(image, blob)


# ---------------------------------------------------------------------------
# the real SM-T715 stock kernel
# ---------------------------------------------------------------------------

@unittest.skipUnless(os.path.exists(REAL_KERNEL), SKIP_REAL)
class TestRealStockKernel(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        with open(REAL_KERNEL, "rb") as f:
            cls.data = f.read()
        cls.hdr = ze.ZImageHeader(cls.data)
        cls.hit = ze.find_payload(cls.data,
                                  cls.hdr.end if cls.hdr.valid else None)

    def test_header(self):
        self.assertTrue(self.hdr.valid)
        self.assertEqual(self.hdr.magic, 0x016F2818)
        self.assertEqual(self.hdr.end, len(self.data))
        self.assertEqual(self.hdr.trailing, 0)

    def test_payload_found(self):
        self.assertIsNotNone(self.hit)
        off, fmt, image, meta = self.hit
        self.assertEqual(fmt, "lzo-kernel")
        self.assertEqual(off, 0x18F0)
        self.assertEqual(len(image), 0xE83658)
        info = meta["info"]
        self.assertTrue(info["hdr_cksum_ok"])
        self.assertEqual(info["nblocks"], 59)
        self.assertEqual(meta["end"], 0x6E5A70)

    def test_banner(self):
        self.assertIn(b"Linux version 3.10.9", self.hit[2])

    def test_no_ikconfig(self):
        self.assertIsNone(ze.extract_ikconfig(self.hit[2]))


if __name__ == "__main__":
    unittest.main()
