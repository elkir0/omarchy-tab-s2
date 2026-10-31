#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Tests for cpio_newc.py and boot/patch-stock-boot.sh.

Three groups:
- stock ramdisk: byte-identical round trip and surgical replace of the real
  dumps/stock/unpacked/ramdisk (skipped when the dump is absent);
- synthetic archives: hard links, device nodes, symlinks, zero-size files,
  name/data padding corner cases, trailing bytes, 070702 crc magic;
- the patch script end-to-end: the produced boot.img must differ from the
  stock image in exactly ramdisk_size/id and in exactly the init.rc ramdisk
  entry.

The patched-image tests run boot/patch-stock-boot.sh once (setUpClass),
which writes out/stock-patched/ in the repo -- the same artifacts
the reviewer flashes.
"""

import gzip
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO_ROOT, "boot"))

import cpio_newc as cn  # noqa: E402

STOCK_BOOT = os.path.join(REPO_ROOT, "dumps", "stock", "boot.img")
STOCK_RAMDISK_GZ = os.path.join(REPO_ROOT, "dumps", "stock", "unpacked",
                                "ramdisk")
STOCK_RAMDISK_DIR = os.path.join(REPO_ROOT, "dumps", "stock", "ramdisk")
PATCH_SCRIPT = os.path.join(REPO_ROOT, "boot", "patch-stock-boot.sh")
OUT_DIR = os.path.join(REPO_ROOT, "out", "stock-patched")
PATCHED_BOOT = os.path.join(OUT_DIR, "boot.img")
PATCHED_DIFF = os.path.join(OUT_DIR, "init.rc.diff")
BOOT_PARTITION_SIZE = 0x00E00000      # 14 MiB

SKIP_STOCK = ("stock dump not present (%s); run the phase-1 dump first"
              % STOCK_RAMDISK_GZ)


class TempDirTest(unittest.TestCase):
    """Base class giving each test a fresh scratch directory."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="cpio_test_")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def path(self, *names):
        return os.path.join(self.tmp, *names)

    def run_py(self, *argv):
        tool = os.path.join(REPO_ROOT, "boot", "cpio_newc.py")
        proc = subprocess.run([sys.executable, "-I", tool] + list(argv),
                              capture_output=True)
        return proc.returncode, proc.stdout, proc.stderr

    def write(self, *names, data=b""):
        """Write *data* to path(*names) and return the path as str."""
        if names and isinstance(names[0], bytes):
            raise TypeError("write() takes str name components")
        path = self.path(*names)
        with open(path, "wb") as f:
            f.write(data)
        return path


def stock_cpio():
    """(entries, trailing) of the real stock ramdisk, decompressed."""
    with open(STOCK_RAMDISK_GZ, "rb") as f:
        return cn.read_archive_with_trailing(gzip.decompress(f.read()))


class StockRamdiskTests(unittest.TestCase):
    """Byte-faithfulness on the real 62-entry stock ramdisk."""

    def setUp(self):
        if not os.path.exists(STOCK_RAMDISK_GZ):
            self.skipTest(SKIP_STOCK)
        with open(STOCK_RAMDISK_GZ, "rb") as f:
            self.raw = gzip.decompress(f.read())

    def test_round_trip_byte_identical(self):
        entries, trailing = cn.read_archive_with_trailing(self.raw)
        self.assertEqual(cn.write_archive(entries, trailing), self.raw,
                         "write_archive(read_archive(x)) != x")

    def test_trailer_is_last_entry_with_trailing_bytes(self):
        entries, trailing = cn.read_archive_with_trailing(self.raw)
        self.assertEqual(entries[-1].name, cn.TRAILER_NAME)
        self.assertGreater(len(trailing), 0)
        self.assertEqual(set(trailing), {0},
                         "expected the stock archive's zero block padding")

    def test_extracted_init_rc_matches_reference(self):
        """The entry data equals the (non-root) reference extraction."""
        entries, _ = cn.read_archive_with_trailing(self.raw)
        hit = [e for e in entries if e.name == "init.rc"]
        self.assertEqual(len(hit), 1)
        with open(os.path.join(STOCK_RAMDISK_DIR, "init.rc"), "rb") as f:
            self.assertEqual(hit[0].data, f.read())
        # And the service block we patch is present exactly once.
        block = (b"service flash_recovery /system/bin/install-recovery.sh\n"
                 b"    class main\n")
        self.assertEqual(hit[0].data.count(block), 1)

    def test_replace_changes_only_target_entry(self):
        entries, trailing = cn.read_archive_with_trailing(self.raw)
        old_init = [e for e in entries if e.name == "init.rc"][0]
        new_data = old_init.data + b"# appended comment\n"
        new_entries = cn.replace_file(entries, "init.rc", new_data)
        rebuilt = cn.write_archive(new_entries, trailing)
        self.assertNotEqual(rebuilt, self.raw)

        # Entry-by-entry: everything but init.rc is bit-identical.
        self.assertEqual(len(new_entries), len(entries))
        for old, new in zip(entries, new_entries):
            if old.name == "init.rc":
                self.assertEqual(new.data, new_data)
                self.assertEqual(new.filesize, len(new_data))
                for field in ("ino", "mode", "uid", "gid", "nlink", "mtime",
                              "devmajor", "devminor", "rdevmajor",
                              "rdevminor", "check", "magic", "name_pad"):
                    self.assertEqual(getattr(new, field),
                                     getattr(old, field),
                                     "init.rc: field %s changed" % field)
            else:
                self.assertIs(new, old,
                              "%s must be the identical object" % old.name)
                self.assertEqual(cn.serialize_entry(new),
                                 cn.serialize_entry(old))

        # Re-parsing the rebuilt archive gives the same one-entry delta.
        r_entries, r_trailing = cn.read_archive_with_trailing(rebuilt)
        self.assertEqual(r_trailing, trailing)
        for old, new in zip(entries, r_entries):
            if old.name == "init.rc":
                self.assertEqual(new.data, new_data)
            else:
                self.assertEqual(cn.serialize_entry(new),
                                 cn.serialize_entry(old))

    def test_replace_preserves_prefix_and_suffix_bytes(self):
        """Only the init.rc data region (and its padding) may move."""
        entries, trailing = cn.read_archive_with_trailing(self.raw)
        old_init = [e for e in entries if e.name == "init.rc"][0]
        new_data = old_init.data + b"# tail\n"
        new_entries = cn.replace_file(entries, "init.rc", new_data)
        rebuilt = cn.write_archive(new_entries, trailing)
        # Everything before the entry and after its (re-padded) data is
        # byte-identical.
        offset = sum(len(cn.serialize_entry(e))
                     for e in entries[:entries.index(old_init)])
        self.assertEqual(rebuilt[:offset], self.raw[:offset])
        self.assertEqual(rebuilt[-len(trailing):], trailing)
        self.assertEqual(self.raw[-len(trailing):], trailing)
        # The entry grew by exactly the data delta plus the padding change.
        old_len = len(cn.serialize_entry(old_init))
        new_len = len(cn.serialize_entry(new_entries[
            [e.name for e in new_entries].index("init.rc")]))
        self.assertEqual(len(rebuilt) - len(self.raw), new_len - old_len)
        self.assertEqual(new_len - old_len,
                         len(new_data) - old_init.filesize
                         + cn.data_pad_len(len(new_data))
                         - cn.data_pad_len(old_init.filesize))


class SyntheticArchiveTests(unittest.TestCase):
    """Hand-built archives covering the corner cases of the newc format."""

    def build(self, entries, trailing=b"", append_trailer=True):
        if append_trailer:
            entries = list(entries) + [cn.Entry(name=cn.TRAILER_NAME)]
        return cn.write_archive(entries, trailing)

    def test_hard_links_device_nodes_symlinks_zerosize_padding(self):
        entries = [
            # directory with two links
            cn.Entry("dev", b"", mode=0o040755, nlink=2, ino=0x11),
            # zero-size regular file, name length 3 (mod 4 == 3 -> no pad)
            cn.Entry("dev/.", b"", mode=0o100644, ino=0x12),
            # symlink to /system/bin/sh (data = target, mode l/777)
            cn.Entry("sbin/sh", b"/system/bin/sh", mode=0o120777, ino=0x13),
            # character device 1:3 (null)
            cn.Entry("dev/null", b"", mode=0o020666, ino=0x14,
                     rdevmajor=1, rdevminor=3, nlink=1),
            # block device 179:0 (mmcblk0)
            cn.Entry("dev/mmcblk0", b"", mode=0o060600, ino=0x15,
                     rdevmajor=179, rdevminor=0, nlink=1),
            # hard link pair: same ino, data carried once (bsdcpio style)
            cn.Entry("a", b"", mode=0o100644, ino=0x16, nlink=2),
            cn.Entry("b", b"payload", mode=0o100644, ino=0x16, nlink=2),
            # name lengths around the 4-byte padding boundaries
            cn.Entry("x" * 1, b"1", mode=0o100644),
            cn.Entry("x" * 2, b"22", mode=0o100644),
            cn.Entry("x" * 3, b"333", mode=0o100644),
            cn.Entry("x" * 4, b"4444", mode=0o100644),
            # uid/gid/mtime larger than 0xffff (exercises 8-hex fields)
            cn.Entry("big", b"\x00\x01\x02", mode=0o100750, uid=0x123456,
                     gid=0x789abc, mtime=0x5f5e100, ino=0xdeadbeef,
                     check=0x12345678),
        ]
        trailing = b"\x00JUNK" + b"\x00" * 507   # non-uniform trailing bytes
        blob = self.build(entries, trailing)
        r_entries, r_trailing = cn.read_archive_with_trailing(blob)
        self.assertEqual(r_trailing, trailing)
        self.assertEqual([e.name for e in r_entries],
                         [e.name for e in entries] + [cn.TRAILER_NAME])
        for old, new in zip(entries, r_entries):
            self.assertEqual(cn.serialize_entry(old),
                             cn.serialize_entry(new), "entry %s" % old.name)
        self.assertEqual(cn.write_archive(r_entries, r_trailing), blob)

        # Replace a file and re-verify the byte-identity of everything else.
        target = r_entries[[e.name for e in r_entries].index("x" * 2)]
        new_entries = cn.replace_file(r_entries, "x" * 2, b"NEW")
        rebuilt = cn.write_archive(new_entries, r_trailing)
        self.assertEqual(cn.write_archive(cn.replace_file(
            r_entries, "x" * 2, b"NEW"), r_trailing), rebuilt)
        rr_entries, rr_trailing = cn.read_archive_with_trailing(rebuilt)
        self.assertEqual(rr_trailing, trailing)
        for old, new in zip(r_entries, rr_entries):
            if old.name == "x" * 2:
                self.assertEqual(new.data, b"NEW")
                self.assertEqual(new.filesize, 3)
            else:
                self.assertEqual(cn.serialize_entry(new),
                                 cn.serialize_entry(old))
        # zero-size entries keep zero padding after their (absent) data
        null_entry = rr_entries[[e.name for e in rr_entries]
                                .index("dev/null")]
        self.assertEqual(null_entry.data, b"")
        self.assertEqual(null_entry.rdevmajor, 1)
        self.assertEqual(null_entry.rdevminor, 3)

    def test_hard_link_entry_keeps_zero_filesize_on_replace_of_other(self):
        entries = [cn.Entry("a", b"", mode=0o100644, ino=7, nlink=2),
                   cn.Entry("b", b"shared-data", mode=0o100644, ino=7,
                            nlink=2)]
        blob = self.build(entries)
        r_entries, _ = cn.read_archive_with_trailing(blob)
        new_entries = cn.replace_file(r_entries, "a", b"xx")
        by_name = {e.name: e for e in new_entries}
        self.assertEqual(by_name["a"].data, b"xx")
        self.assertEqual(by_name["a"].ino, 7)
        self.assertEqual(by_name["a"].nlink, 2)
        self.assertEqual(by_name["b"].data, b"shared-data")

    def test_odd_padding_bytes_are_preserved(self):
        """The exact padding bytes from the source are reused verbatim,
        not regenerated."""
        # name "odd" (namesize 4 -> 2 pad bytes: 110+4 = 114) and 3 data
        # bytes (1 pad byte) -- the supplied pads must round-trip untouched.
        entry = cn.Entry("odd", b"abc", mode=0o100644,
                         name_pad=b"\x00\x00", data_pad=b"\x01")
        blob = cn.write_archive([entry, cn.Entry(name=cn.TRAILER_NAME)])
        self.assertIn(b"abc\x01", blob)
        r_entries, _ = cn.read_archive_with_trailing(blob)
        self.assertEqual(r_entries[0].name_pad, b"\x00\x00")
        self.assertEqual(r_entries[0].data_pad, b"\x01")
        self.assertEqual(cn.write_archive(r_entries), blob)

        # A pad length inconsistent with the name/filesize is refused.
        with self.assertRaises(cn.CpioFormatError):
            cn.serialize_entry(cn.Entry("odd", b"abc",
                                        name_pad=b"\x00\x00\x00"))
        with self.assertRaises(cn.CpioFormatError):
            cn.serialize_entry(cn.Entry("odd", b"abc", data_pad=b"\x01\x02"))

    def test_trailing_bytes_after_trailer_preserved(self):
        entry = cn.Entry("f", b"data", mode=0o100644)
        trailing = b"\x00" * 512 + b"garbage"
        blob = self.build([entry], trailing)
        r_entries, r_trailing = cn.read_archive_with_trailing(blob)
        self.assertEqual(r_trailing, trailing)
        self.assertEqual(cn.write_archive(r_entries, r_trailing), blob)

    def test_crc_magic_preserved_and_check_updated(self):
        entries = [cn.Entry("f", b"payload", mode=0o100644,
                            magic=cn.MAGIC_CRC, check=0)]
        blob = self.build(entries, append_trailer=False)
        # write_archive appends a trailer matching the last entry's magic
        self.assertIn(cn.MAGIC_CRC, blob)
        r_entries, _ = cn.read_archive_with_trailing(blob)
        self.assertEqual(r_entries[0].magic, cn.MAGIC_CRC)
        new_entries = cn.replace_file(r_entries, "f", b"other")
        import binascii
        self.assertEqual(new_entries[0].check,
                         binascii.crc32(b"other") & 0xFFFFFFFF)
        # ... but a newc archive's check field is left untouched
        newc = [cn.Entry("f", b"payload", mode=0o100644, check=0x5a5a5a5a)]
        blob2 = self.build(newc)
        r2, _ = cn.read_archive_with_trailing(blob2)
        self.assertEqual(cn.replace_file(r2, "f", b"other")[0].check,
                         0x5a5a5a5a)

    def test_header_layout_matches_format(self):
        """110-byte header, hex fields in the documented order."""
        entry = cn.Entry("name", b"ab", mode=0o100644, uid=1, gid=2,
                         mtime=3, ino=4, nlink=1, devmajor=8, devminor=9,
                         rdevmajor=10, rdevminor=11, check=12)
        blob = cn.serialize_entry(entry)
        self.assertEqual(blob[:6], b"070701")
        self.assertEqual(blob[6:14], b"00000004")     # ino
        self.assertEqual(blob[14:22], b"%08x" % 0o100644)   # mode
        self.assertEqual(blob[22:30], b"00000001")    # uid
        self.assertEqual(blob[30:38], b"00000002")    # gid
        self.assertEqual(blob[38:46], b"00000001")    # nlink
        self.assertEqual(blob[46:54], b"00000003")    # mtime
        self.assertEqual(blob[54:62], b"00000002")    # filesize
        self.assertEqual(blob[62:70], b"00000008")    # devmajor
        self.assertEqual(blob[70:78], b"00000009")    # devminor
        self.assertEqual(blob[78:86], b"0000000a")    # rdevmajor
        self.assertEqual(blob[86:94], b"0000000b")    # rdevminor
        self.assertEqual(blob[94:102], b"00000005")   # namesize ("name"+NUL)
        self.assertEqual(blob[102:110], b"0000000c")  # check
        self.assertEqual(blob[110:115], b"name\x00")
        self.assertEqual(blob[115:116], b"\x00")           # name pad (1)
        self.assertEqual(blob[116:118], b"ab")
        self.assertEqual(blob[118:120], b"\x00\x00")  # data pad
        self.assertEqual(len(blob), 120)

    def test_parse_errors(self):
        with self.assertRaises(cn.CpioFormatError):
            cn.read_archive(b"")                       # truncated
        with self.assertRaises(cn.CpioFormatError):
            cn.read_archive(b"070707" + b"0" * 104)    # bad magic
        with self.assertRaises(cn.CpioFormatError):
            cn.read_archive(b"070701" + b"zzzzzzzz" + b"0" * 96)
        # archive that just stops without a TRAILER entry
        truncated = cn.serialize_entry(cn.Entry("f", b"data"))[:60]
        with self.assertRaises(cn.CpioFormatError):
            cn.read_archive(truncated)

    def test_replace_file_refuses_missing_and_duplicate(self):
        entries = [cn.Entry("a", b"1"), cn.Entry("b", b"2"),
                   cn.Entry("b", b"3"), cn.Entry(name=cn.TRAILER_NAME)]
        with self.assertRaises(KeyError):
            cn.replace_file(entries, "nope", b"x")
        with self.assertRaises(cn.CpioFormatError):
            cn.replace_file(entries, "b", b"x")
        with self.assertRaises(cn.CpioFormatError):
            cn.replace_file(entries, cn.TRAILER_NAME, b"x")

    def test_write_archive_appends_trailer_when_missing(self):
        blob = cn.write_archive([cn.Entry("f", b"data")])
        entries, trailing = cn.read_archive_with_trailing(blob)
        self.assertEqual([e.name for e in entries], ["f", cn.TRAILER_NAME])
        self.assertEqual(trailing, b"")


class CliTests(TempDirTest):
    """The list / extract-file / replace subcommands."""

    def setUp(self):
        super().setUp()
        if not os.path.exists(STOCK_RAMDISK_GZ):
            self.skipTest(SKIP_STOCK)
        with open(STOCK_RAMDISK_GZ, "rb") as f:
            self.cpio = gzip.decompress(f.read())
        self.arch = self.write("ramdisk.cpio", data=self.cpio)

    def test_list(self):
        code, out, err = self.run_py("list", self.arch)
        self.assertEqual(code, 0, err)
        lines = out.decode().splitlines()
        self.assertEqual(len(lines), 62)      # 62 real entries, no TRAILER
        self.assertEqual(lines[0].split(), ["040755", "0:0", "0", "acct"])
        init_line = [l for l in lines if l.endswith(" init.rc")]
        self.assertEqual(init_line, ["100750 0:0    58919 init.rc"])

    def test_extract_file(self):
        code, out, err = self.run_py("extract-file", self.arch, "init.rc")
        self.assertEqual(code, 0, err)
        with open(os.path.join(STOCK_RAMDISK_DIR, "init.rc"), "rb") as f:
            self.assertEqual(out, f.read())

    def test_extract_file_missing(self):
        code, out, err = self.run_py("extract-file", self.arch, "nope")
        self.assertEqual(code, 1)
        self.assertIn(b"no entry named", err)
        self.assertEqual(out, b"")

    def test_replace(self):
        entries, trailing = cn.read_archive_with_trailing(self.cpio)
        old = [e for e in entries if e.name == "init.rc"][0]
        new_data = old.data.replace(b"class main", b"class hal")
        newfile = self.write("init.new", data=new_data)
        out_arch = self.path("out.cpio")
        code, _out, err = self.run_py("replace", self.arch, "init.rc",
                                      newfile, "-o", out_arch)
        self.assertEqual(code, 0, err)
        with open(out_arch, "rb") as f:
            got = f.read()
        self.assertEqual(got, cn.write_archive(
            cn.replace_file(entries, "init.rc", new_data), trailing))
        r_entries, r_trailing = cn.read_archive_with_trailing(got)
        self.assertEqual(r_trailing, trailing)
        self.assertEqual([e for e in r_entries if e.name == "init.rc"][0]
                         .data, new_data)

    def test_replace_trailing_bytes_kept(self):
        code, _out, err = self.run_py(
            "replace", self.arch, "init.rc",
            self.write("same",
                       data=[e for e in cn.read_archive(self.cpio)
                             if e.name == "init.rc"][0].data),
            "-o", self.path("out.cpio"))
        self.assertEqual(code, 0, err)
        with open(self.path("out.cpio"), "rb") as f:
            self.assertEqual(f.read(), self.cpio)   # no-op replace is identity


class PatchedBootImageTests(TempDirTest):
    """End-to-end: boot/patch-stock-boot.sh output vs the stock image."""

    @classmethod
    def setUpClass(cls):
        if not os.path.exists(STOCK_BOOT):
            raise unittest.SkipTest("stock dump not present (%s)" % STOCK_BOOT)
        cls.script_out = subprocess.run(
            ["bash", PATCH_SCRIPT], capture_output=True, timeout=600)
        if cls.script_out.returncode != 0:
            raise AssertionError(
                "patch-stock-boot.sh failed (%d):\n%s\n%s"
                % (cls.script_out.returncode,
                   cls.script_out.stdout.decode("utf-8", "replace"),
                   cls.script_out.stderr.decode("utf-8", "replace")))

    def setUp(self):
        super().setUp()
        for path in (STOCK_BOOT, PATCHED_BOOT, PATCHED_DIFF):
            if not os.path.exists(path):
                self.failTest("missing %s (script output)" % path)

    def info(self, path):
        tool = os.path.join(REPO_ROOT, "boot", "samsung_bootimg.py")
        proc = subprocess.run([sys.executable, "-I", tool, "info", path],
                              capture_output=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout.decode()

    def unpack(self, path, dirname):
        tool = os.path.join(REPO_ROOT, "boot", "samsung_bootimg.py")
        out = self.path(dirname)
        proc = subprocess.run(
            [sys.executable, "-I", tool, "unpack", path, "-o", out],
            capture_output=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return out

    @staticmethod
    def read(path):
        with open(path, "rb") as f:
            return f.read()

    def test_info_same_except_ramdisk_size_and_id(self):
        stock = self.info(STOCK_BOOT).splitlines()
        patched = self.info(PATCHED_BOOT).splitlines()
        self.assertEqual(len(stock), len(patched))
        changed = []
        for a, b in zip(stock, patched):
            if a != b:
                changed.append((a, b))
        # Line 1 carries the path; then exactly ramdisk_size and the id.
        self.assertEqual(len(changed), 4, "unexpected info differences: %r"
                         % (changed,))
        self.assertTrue(changed[0][0].startswith("boot_img_hdr v0 ("))
        self.assertTrue(changed[0][1].startswith("boot_img_hdr v0 ("))
        for a, b in changed[1:]:
            field = a.strip().split()[0]
            self.assertIn(field, ("ramdisk_size", "id"),
                          "field %s changed: %r -> %r" % (field, a, b))
        # Every other header field byte-identical.
        for line in stock:
            field = line.strip().split()[0] if line.strip() else ""
            if field and field not in ("ramdisk_size", "id", "boot_img_hdr"):
                self.assertIn(line, patched, "field drift: %s" % line)

    def test_kernel_dt_signature_trailer_identical(self):
        stock = self.unpack(STOCK_BOOT, "stock")
        patched = self.unpack(PATCHED_BOOT, "patched")
        for part in ("kernel", "dt.img", "signature", "trailer.bin"):
            self.assertEqual(self.read(os.path.join(stock, part)),
                             self.read(os.path.join(patched, part)),
                             "%s differs" % part)
        # The raw header: everything but ramdisk_size and id is identical.
        h_stock = self.read(STOCK_BOOT)[:608]
        h_patched = self.read(PATCHED_BOOT)[:608]
        self.assertEqual(h_stock[0:0x10], h_patched[0:0x10])
        self.assertEqual(h_stock[0x14:0x240], h_patched[0x14:0x240],
                         "header bytes 0x14..0x240 changed")
        self.assertEqual(h_stock[0x260:], h_patched[0x260:],
                         "id[5..7] changed")
        self.assertNotEqual(h_stock[0x10:0x14], h_patched[0x10:0x14])
        self.assertNotEqual(h_stock[0x240:0x260], h_patched[0x240:0x260])

    def test_ramdisks_differ_only_in_init_rc(self):
        stock = self.unpack(STOCK_BOOT, "stock")
        patched = self.unpack(PATCHED_BOOT, "patched")
        gz_stock = self.read(os.path.join(stock, "ramdisk"))
        gz_patched = self.read(os.path.join(patched, "ramdisk"))
        self.assertNotEqual(gz_stock, gz_patched)
        e_stock, t_stock = cn.read_archive_with_trailing(
            gzip.decompress(gz_stock))
        e_patched, t_patched = cn.read_archive_with_trailing(
            gzip.decompress(gz_patched))
        self.assertEqual(t_stock, t_patched)
        self.assertEqual([e.name for e in e_stock],
                         [e.name for e in e_patched])
        diffs = []
        for a, b in zip(e_stock, e_patched):
            if cn.serialize_entry(a) != cn.serialize_entry(b):
                diffs.append(a.name)
        self.assertEqual(sorted(diffs), ["default.prop", "init.rc"],
                         "unexpected changed entries: %r" % diffs)

    def test_default_prop_patch_is_one_appended_line(self):
        stock = self.unpack(STOCK_BOOT, "stock")
        patched = self.unpack(PATCHED_BOOT, "patched")
        old = gzip.decompress(self.read(os.path.join(stock, "ramdisk")))
        new = gzip.decompress(self.read(os.path.join(patched, "ramdisk")))
        old_e = [e for e in cn.read_archive(old) if e.name == "default.prop"][0]
        new_e = [e for e in cn.read_archive(new) if e.name == "default.prop"][0]
        suffix = b"service.adb.tcp.port=5555\n"
        self.assertTrue(old_e.data.endswith(b"\n"))
        self.assertEqual(new_e.data, old_e.data + suffix)

    def test_init_rc_patch_is_exactly_the_intended_change(self):
        stock = self.unpack(STOCK_BOOT, "stock")
        patched = self.unpack(PATCHED_BOOT, "patched")
        old = gzip.decompress(self.read(os.path.join(stock, "ramdisk")))
        new = gzip.decompress(self.read(os.path.join(patched, "ramdisk")))
        old_rc = [e for e in cn.read_archive(old) if e.name == "init.rc"][0]
        new_rc = [e for e in cn.read_archive(new) if e.name == "init.rc"][0]

        old_block = (b"service flash_recovery /system/bin/install-recovery.sh"
                     b"\n    class main\n")
        new_block = (b"service flash_recovery /system/bin/install-recovery.sh"
                     b"\n    disabled\n"
                     b"    # t715: disabled so RECOVERY keeps the test kernel"
                     b"\n")
        self.assertEqual(old_rc.data.count(old_block), 1)
        self.assertEqual(new_rc.data.count(new_block), 1)
        self.assertEqual(new_rc.data,
                         old_rc.data.replace(old_block, new_block))
        # Nothing else moved and the file stays a sane size.
        self.assertLess(new_rc.filesize, old_rc.filesize + 200)
        self.assertGreater(new_rc.filesize, old_rc.filesize)
        # The oneshot line must survive (service shape intact).
        self.assertIn(b"\n    oneshot\n", new_rc.data)

    def test_init_rc_diff_file_contents(self):
        with open(PATCHED_DIFF, "r") as f:
            diff = f.read()
        self.assertIn("service flash_recovery", diff)
        minus = [l for l in diff.splitlines() if l.startswith("-")
                 and not l.startswith("---")]
        plus = [l for l in diff.splitlines() if l.startswith("+")
                and not l.startswith("+++")]
        self.assertEqual(minus, ["-    class main"])
        self.assertEqual(plus, ["+    disabled",
                                "+    # t715: disabled so RECOVERY keeps the "
                                "test kernel"])

    def test_image_size_and_sha256sums(self):
        blob = self.read(PATCHED_BOOT)
        self.assertLessEqual(len(blob), BOOT_PARTITION_SIZE)
        self.assertEqual(len(blob), BOOT_PARTITION_SIZE,
                         "image should stay exactly 14 MiB (trailer padding)")

        import hashlib
        with open(os.path.join(OUT_DIR, "SHA256SUMS")) as f:
            sums = f.read()
        for line in sums.splitlines():
            digest, path = line.split(None, 1)
            path = path.strip()
            self.assertEqual(
                hashlib.sha256(self.read(os.path.join(REPO_ROOT, path)))
                .hexdigest(), digest, "bad SHA256SUMS entry for %s" % path)
        self.assertIn("out/stock-patched/boot.img", sums)
        self.assertIn("dumps/stock/boot.img", sums)

    def test_script_reports_gzip_settings(self):
        out = self.__class__.script_out.stdout.decode("utf-8", "replace")
        self.assertIn("gzip settings:", out)


if __name__ == "__main__":
    unittest.main()
