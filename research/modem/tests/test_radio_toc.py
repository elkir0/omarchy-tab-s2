"""Tests for radio_toc.py.

Run from research/modem/:
    python3 -m unittest discover -s tests -v

Two suites:
  * RealImageTests — parses the repository's dumps/radio.img and checks the
    byte-verified TOC values from CBD_RE.md §3. Skipped when the image is not
    present.
  * SyntheticImageTests — builds a minimal image in-memory / in a tempdir so the
    parser is exercised without the dump.
"""

import os
import struct
import sys
import tempfile
import unittest
import zlib

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import radio_toc


def make_entry(name, offset, load_addr, size, crc, index):
    return radio_toc.ENTRY_STRUCT.pack(name.encode("ascii").ljust(12, b"\x00"),
                                       offset, load_addr, size, crc, index)


def build_image(entries_payloads, toc_extra=None):
    """Build an in-memory image. entries_payloads: list of
    (name, load_addr, index, payload_bytes). Payloads are placed right after the
    0x200-byte TOC; CRCs are computed. The self-record occupies slot 0
    (image byte 0x00). Returns (bytes, meta) where meta maps name ->
    (offset, size, crc)."""
    toc = bytearray(radio_toc.TOC_SIZE)
    toc[0:4] = b"TOC\x00"
    struct.pack_into("<IIIII", toc, 0x0C, 0, 0, radio_toc.TOC_SIZE, 0, 1)  # self-record
    body = bytearray()
    pos = radio_toc.TOC_SIZE
    meta = {}
    for i, (name, load_addr, index, payload) in enumerate(entries_payloads):
        crc = zlib.crc32(payload) & 0xFFFFFFFF
        slot = (i + 1) * radio_toc.ENTRY_SIZE  # slot 0 = self-record
        struct.pack_into("<12s", toc, slot, name.encode("ascii").ljust(12, b"\x00"))
        struct.pack_into("<IIIII", toc, slot + 0x0C,
                         pos, load_addr, len(payload), crc, index)
        meta[name] = (pos, len(payload), crc)
        body.extend(payload)
        pos += len(payload)
    if toc_extra:
        toc_extra(toc)
    return bytes(toc) + bytes(body), meta


class SyntheticImageTests(unittest.TestCase):
    def setUp(self):
        boot = bytes(range(256)) * 3            # 0x300 bytes
        main = bytes(range(255, -1, -1)) * 64   # 0x4000 bytes
        self.img, self.meta = build_image([
            ("BOOT", 0x0, 0, boot),
            ("MAIN", 0x40000000, 2, main),
        ])

    def test_parse_returns_self_record_first(self):
        entries = radio_toc.parse_toc(self.img)
        self.assertEqual(entries[0].name, "TOC")
        self.assertEqual(entries[0].size, radio_toc.TOC_SIZE)
        self.assertEqual(entries[0].index, 1)

    def test_parse_entry_fields(self):
        entries = radio_toc.parse_toc(self.img)
        by = {e.name: e for e in entries}
        off, size, crc = self.meta["BOOT"]
        self.assertEqual(by["BOOT"].offset, off)
        self.assertEqual(by["BOOT"].size, size)
        self.assertEqual(by["BOOT"].crc32, crc)
        self.assertEqual(by["BOOT"].index, 0)
        self.assertEqual(by["MAIN"].load_addr, 0x40000000)
        self.assertEqual(by["MAIN"].index, 2)

    def test_crc_verification(self):
        entries = radio_toc.parse_toc(self.img)
        for e in entries:
            if not e.has_data:
                continue
            computed, ok = radio_toc.verify_entry(self.img, e)
            self.assertTrue(ok)
            self.assertEqual(computed, e.crc32)

    def test_crc_detects_corruption(self):
        bad = bytearray(self.img)
        off, size, _ = self.meta["MAIN"]
        bad[off] ^= 0xFF
        entries = radio_toc.parse_toc(bytes(bad))
        by = {e.name: e for e in entries}
        computed, ok = radio_toc.verify_entry(bytes(bad), by["MAIN"])
        self.assertFalse(ok)
        self.assertNotEqual(computed, by["MAIN"].crc32)

    def test_bad_magic_rejected(self):
        bad = bytearray(self.img)
        bad[0:4] = b"XOC\x00"
        with self.assertRaises(radio_toc.TocError):
            radio_toc.parse_toc(bytes(bad))

    def test_truncated_image_rejected(self):
        with self.assertRaises(radio_toc.TocError):
            radio_toc.parse_toc(self.img[:100])

    def test_extract_writes_payloads(self):
        entries = radio_toc.parse_toc(self.img)
        with tempfile.TemporaryDirectory() as tmp:
            written = radio_toc.extract(self.img, entries, tmp)
            names = {os.path.basename(p) for p in written}
            self.assertEqual(names, {"BOOT", "MAIN"})
            off, size, _ = self.meta["BOOT"]
            with open(os.path.join(tmp, "BOOT"), "rb") as f:
                self.assertEqual(f.read(), self.img[off:off + size])

    def test_unused_zero_entries_skipped(self):
        # image with only the self-record: parse must succeed and return [TOC]
        img = build_image([])[0]
        entries = radio_toc.parse_toc(img)
        self.assertEqual([e.name for e in entries], ["TOC"])

    def test_cli_print_and_extract(self):
        with tempfile.TemporaryDirectory() as tmp:
            img_path = os.path.join(tmp, "radio.img")
            with open(img_path, "wb") as f:
                f.write(self.img)
            out = os.path.join(tmp, "out")
            rc = radio_toc.main([img_path, "--extract", out])
            self.assertEqual(rc, 0)
            self.assertTrue(os.path.exists(os.path.join(out, "MAIN")))


class RealImageTests(unittest.TestCase):
    IMAGE = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.dirname(os.path.abspath(__file__))))), "dumps", "radio.img")

    def setUp(self):
        if not os.path.exists(self.IMAGE):
            self.skipTest("real radio.img not present")
        with open(self.IMAGE, "rb") as f:
            self.data = f.read()

    def test_size(self):
        self.assertEqual(len(self.data), 92274688)  # 0x5800000

    def test_toc_values_match_cbd_re_md(self):
        entries = {e.name: e for e in radio_toc.parse_toc(self.data)}
        boot, main, nv, offs = entries["BOOT"], entries["MAIN"], entries["NV"], entries["OFFSET"]
        self.assertEqual((boot.offset, boot.load_addr, boot.size, boot.crc32, boot.index),
                         (0x200, 0x0, 0x29fc, 0x5db1f04c, 0))
        self.assertEqual((main.offset, main.load_addr, main.size, main.crc32, main.index),
                         (0x2C00, 0x40000000, 0x21271A0, 0x1E71169C, 2))
        self.assertEqual((nv.offset, nv.load_addr, nv.size, nv.crc32, nv.index),
                         (0x0, 0x47EE0000, 0x100000, 0x0, 3))
        self.assertEqual((offs.offset, offs.size, offs.crc32, offs.index),
                         (0x7AA00, 0x85600, 0x0, 4))
        self.assertEqual(entries["TOC"].size, 0x200)

    def test_boot_and_main_crc_ok(self):
        entries = radio_toc.parse_toc(self.data)
        for e in entries:
            if e.name in ("BOOT", "MAIN"):
                computed, ok = radio_toc.verify_entry(self.data, e, len(self.data))
                self.assertTrue(ok, "%s crc mismatch" % e.name)
                self.assertEqual(computed, e.crc32)

    def test_nv_has_no_data_in_image(self):
        nv = {e.name: e for e in radio_toc.parse_toc(self.data)}["NV"]
        computed, ok = radio_toc.verify_entry(self.data, nv)
        self.assertEqual(computed, 0)
        self.assertTrue(ok)  # stored crc is 0 too

    def test_offset_entry_crc_not_stored(self):
        offs = {e.name: e for e in radio_toc.parse_toc(self.data)}["OFFSET"]
        computed, ok = radio_toc.verify_entry(self.data, offs, len(self.data))
        self.assertEqual(computed, 0x8E1BFE80)
        self.assertFalse(ok)  # image does not store a crc for OFFSET


if __name__ == "__main__":
    unittest.main()
