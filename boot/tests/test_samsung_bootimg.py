#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Golden tests: samsung_bootimg.py must be byte-identical to the LineageOS
C reference (src/hardware_samsung-18.1/dtbhtool), built with
boot/build-dtbhtool-ref.sh and run in the dtbhtool-ref container.

Golden tests are skipped (not failed) with a clear reason when Docker, the
reference image, or the prebuilt reference binaries are unavailable.
"""

import json
import os
import random
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO_ROOT, "boot"))

import samsung_bootimg as sbi  # noqa: E402

REF_IMAGE = "dtbhtool-ref"
TOOLS_DIR = os.path.join(REPO_ROOT, "out", "tools")
REF_TOOLS = ("mkbootimg", "unpackbootimg", "mkdtbimg", "unpackdtbhimg")

DTC_CANDIDATES = ("/opt/homebrew/bin/dtc", "/usr/local/bin/dtc", "/usr/bin/dtc")

# Tiny DTS in the shape of the real device ones
# (kernel_universal5433/arch/arm/boot/dts/exynos5433-gts28_eur_open_0N.dts:21-25).
DTS_TEMPLATE = """\
/dts-v1/;
/ {{
\tmodel = "Samsung SM-T715";
\tmodel_info-chip = <5433>;
\tmodel_info-platform = "gts28";
\tmodel_info-subtype = "gts28_eur_open";
\tmodel_info-hw_rev = <{rev}>;
\tmodel_info-hw_rev_end = <{rev_end}>;
\tfiller-@{tag} {{ prop = <0x{tag} 1 2 3>; }};
}};
"""


def which_dtc():
    for path in DTC_CANDIDATES:
        if os.path.exists(path):
            return path
    return shutil.which("dtc")


def docker_available():
    try:
        proc = subprocess.run(("docker", "info"), capture_output=True,
                              timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return proc.returncode == 0


def ref_tools_present():
    return all(os.access(os.path.join(TOOLS_DIR, name), os.X_OK)
               for name in REF_TOOLS)


def ref_image_works():
    """docker available AND the image can see the prebuilt tools via the /out
    mount (its CMD compiles them into a mounted /out; without the mount there
    is nothing to run)."""
    if not docker_available():
        return False
    probe = subprocess.run(
        ("docker", "run", "--rm", "--platform", "linux/arm64",
         "-v", TOOLS_DIR + ":/out:ro", REF_IMAGE,
         "test", "-x", "/out/mkbootimg"),
        capture_output=True, timeout=120)
    return probe.returncode == 0


DOCKER_OK = docker_available()
DTC_OK = which_dtc() is not None
REF_OK = DOCKER_OK and ref_tools_present() and ref_image_works()

SKIP_REF = ("Docker or the C reference tools unavailable (build them with: "
            "bash boot/build-dtbhtool-ref.sh)")
SKIP_DTC = "dtc not found (expected /opt/homebrew/bin/dtc)"


class TempDirTest(unittest.TestCase):
    """Base class giving each test a fresh scratch directory."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sbi_test_")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def path(self, *names):
        return os.path.join(self.tmp, *names)

    def run_py(self, *argv):
        tool = os.path.join(REPO_ROOT, "boot", "samsung_bootimg.py")
        cmd = [sys.executable, "-I", tool] + list(argv)
        proc = subprocess.run(cmd, capture_output=True)
        return proc.returncode, proc.stdout, proc.stderr

    def read(self, *names):
        with open(self.path(*names), "rb") as f:
            return f.read()


def write_random(path, size, seed):
    """Deterministic pseudo-random payload (stdlib only)."""
    rng = random.Random(seed)
    data = bytes(rng.getrandbits(8) for _ in range(size))
    with open(path, "wb") as f:
        f.write(data)
    return path


def write_dts(dtc, path_dts, path_dtb, rev, rev_end, tag=0):
    with open(path_dts, "w") as f:
        f.write(DTS_TEMPLATE.format(rev=rev, rev_end=rev_end, tag=tag))
    subprocess.run([dtc, "-q", "-I", "dts", "-O", "dtb",
                    "-o", path_dtb, path_dts], check=True)
    return path_dtb


def c_blob_order(c_image, dtb_paths):
    """The C tool lays blobs out in readdir order; entries are sorted by
    (chip, hw_rev) but point at their blob via offset.  Recover the layout
    order actually used by matching each entry's payload against the input
    DTBs (by exact content), then returning the DTB indices in blob file
    order."""
    _version, entries, _blobs = sbi.dtbh_parse(c_image)
    raws = []
    for p in dtb_paths:
        with open(p, "rb") as f:
            raws.append(f.read())
    pairs = []                             # (blob offset, dtb index)
    for ent in entries:
        start = ent["offset"]
        for b_i, raw in enumerate(raws):
            if c_image[start:start + len(raw)] == raw:
                pairs.append((start, b_i))
                break
        else:
            raise AssertionError("could not recover C blob order")
    pairs.sort()
    return [b_i for _off, b_i in pairs]


class GoldenTests(TempDirTest):
    """Byte-identity against the C reference (needs Docker + reference
    binaries; skipped otherwise)."""

    def setUp(self):
        super().setUp()
        if not REF_OK:
            self.skipTest(SKIP_REF)
        if which_dtc() is None:
            self.skipTest(SKIP_DTC)
        self.dtc = which_dtc()

    # -- helpers ----------------------------------------------------------

    def run_ref(self, *shell_argv):
        cmd = ["docker", "run", "--rm", "--platform", "linux/arm64",
               "-v", self.tmp + ":/w",
               "-v", TOOLS_DIR + ":/out:ro",
               REF_IMAGE, "bash", "-c", " ".join(shell_argv)]
        proc = subprocess.run(cmd, capture_output=True)
        if proc.returncode != 0:
            raise AssertionError(
                "reference tool failed: %s\nstderr: %s"
                % (" ".join(shell_argv),
                   proc.stderr.decode("utf-8", "replace")))
        return proc

    def run_ref_rc(self, *shell_argv):
        """Same but returns (rc, stderr) without raising."""
        cmd = ["docker", "run", "--rm", "--platform", "linux/arm64",
               "-v", self.tmp + ":/w",
               "-v", TOOLS_DIR + ":/out:ro",
               REF_IMAGE, "bash", "-c", " ".join(shell_argv)]
        proc = subprocess.run(cmd, capture_output=True)
        return proc.returncode, proc.stderr

    def make_dtb(self, name, rev, rev_end, tag):
        return write_dts(self.dtc, self.path(name + ".dts"),
                         self.path(name + ".dtb"), rev, rev_end, tag=tag)

    def c_dtbh(self, dtbs):
        """DTBH built by the C tool from a directory containing exactly
        *dtbs*.  Returns (image, layout_order)."""
        dtbdir = self.path("dtbdir")
        os.mkdir(dtbdir)
        for i, src in enumerate(dtbs):
            shutil.copy(src, os.path.join(dtbdir, "dtb%02d.dtb" % i))
        self.run_ref("/out/mkdtbimg -s 2048 --dt_dir /w/dtbdir -o /w/c_dtb.img")
        image = self.read("c_dtb.img")
        return image, c_blob_order(image, dtbs)

    def py_dtbh(self, dtbs, revs=None):
        argv = ["dtbh-pack", "-o", self.path("py_dtb.img")]
        for dtb in dtbs:
            with open(dtb, "rb") as f:
                props = sbi.fdt_root_properties(f.read())
            rev = struct.unpack(">I", props["model_info-hw_rev"][:4])[0]
            argv.append("--dtb=%d=%s" % (rev, dtb))
        code, _out, err = self.run_py(*argv)
        self.assertEqual(code, 0, "python dtbh-pack failed: %s" % err)
        return self.read("py_dtb.img")

    # -- golden tests -----------------------------------------------------

    def test_dtbh_pack_two_entries_golden(self):
        """dtbh-pack == C mkdtbimg -s 2048, two entries, different hw_rev."""
        rev3 = self.make_dtb("rev3", 3, 3, tag=3)
        rev9 = self.make_dtb("rev9", 9, 255, tag=9)
        dtbs = [rev3, rev9]
        c_image, layout = self.c_dtbh(dtbs)
        py_image = self.py_dtbh([dtbs[i] for i in layout], [3, 9])
        self.assertEqual(c_image, py_image,
                         "dtbh-pack output differs from the C reference")

    def test_dtbh_pack_four_entries_golden(self):
        """Revisions 03/04/06/09, the set the downstream kernel ships."""
        revs = (3, 4, 6, 9)
        dtbs = [self.make_dtb("rev%d" % r, r, e, tag=r)
                for r, e in zip(revs, (3, 4, 8, 255))]
        c_image, layout = self.c_dtbh(dtbs)
        py_image = self.py_dtbh([dtbs[i] for i in layout], list(revs))
        self.assertEqual(c_image, py_image,
                         "dtbh-pack output differs from the C reference")

    def test_pack_with_dt_golden(self):
        """pack with a dt section == C mkbootimg."""
        rev3 = self.make_dtb("rev3", 3, 3, tag=3)
        rev9 = self.make_dtb("rev9", 9, 255, tag=9)
        c_dtbh_image, layout = self.c_dtbh([rev3, rev9])
        dtbs = [rev3, rev9]
        dtbh = self.py_dtbh([dtbs[i] for i in layout], [3, 9])
        with open(self.path("dt.img"), "wb") as f:
            f.write(dtbh)
        self.assertEqual(c_dtbh_image, dtbh)   # sanity: same dt content

        write_random(self.path("zImage"), 100 * 1024, seed=1)
        write_random(self.path("ramdisk.gz"), 300 * 1024, seed=2)
        cmdline = "console=ttySAC0,115200 androidboot.hw_rev=9"

        self.run_ref("/out/mkbootimg --kernel /w/zImage"
                     " --ramdisk /w/ramdisk.gz --dt /w/dt.img"
                     " --cmdline '" + cmdline + "'"
                     " --base 0x10000000"
                     " --ramdisk_offset 0x01000000"
                     " --tags_offset 0x00000100"
                     " -o /w/c_boot.img")
        code, _out, err = self.run_py(
            "pack", "--kernel", self.path("zImage"),
            "--ramdisk", self.path("ramdisk.gz"),
            "--dt", self.path("dt.img"), "--cmdline", cmdline,
            "--base", "0x10000000",
            "--ramdisk-offset", "0x01000000",
            "--tags-offset", "0x00000100",
            "-o", self.path("py_boot.img"))
        self.assertEqual(code, 0, err)
        self.assertEqual(self.read("c_boot.img"), self.read("py_boot.img"),
                         "pack (with dt) differs from the C reference")

    def test_pack_no_dt_golden(self):
        """pack without a dt section == C mkbootimg."""
        write_random(self.path("zImage"), 50 * 1024, seed=3)
        write_random(self.path("ramdisk.gz"), 17 * 1024, seed=4)
        self.run_ref("/out/mkbootimg --kernel /w/zImage"
                     " --ramdisk /w/ramdisk.gz"
                     " --cmdline 'console=ttySAC0'"
                     " -o /w/c_boot.img")
        code, _out, err = self.run_py(
            "pack", "--kernel", self.path("zImage"),
            "--ramdisk", self.path("ramdisk.gz"),
            "--cmdline", "console=ttySAC0",
            "-o", self.path("py_boot.img"))
        self.assertEqual(code, 0, err)
        self.assertEqual(self.read("c_boot.img"), self.read("py_boot.img"),
                         "pack (no dt) differs from the C reference")

    def test_pack_second_stage_golden(self):
        """pack with a second stage exercises the C padding quirk
        (mkbootimg.c:318 pads second by ramdisk_size)."""
        write_random(self.path("zImage"), 48 * 1024, seed=11)
        write_random(self.path("ramdisk.gz"), 20 * 1024, seed=12)
        write_random(self.path("second"), 5 * 1024, seed=13)
        self.run_ref("/out/mkbootimg --kernel /w/zImage"
                     " --ramdisk /w/ramdisk.gz --second /w/second"
                     " --cmdline 'second test' -o /w/c_boot.img")
        code, _out, err = self.run_py(
            "pack", "--kernel", self.path("zImage"),
            "--ramdisk", self.path("ramdisk.gz"),
            "--second", self.path("second"),
            "--cmdline", "second test",
            "-o", self.path("py_boot.img"))
        self.assertEqual(code, 0, err)
        self.assertEqual(self.read("c_boot.img"), self.read("py_boot.img"),
                         "pack (second stage) differs from the C reference")

    def test_seandroid_golden(self):
        """--seandroid output == C reference output + the footer (the C tool
        never writes the footer; it is observed on real device images)."""
        write_random(self.path("zImage"), 33 * 1024, seed=14)
        write_random(self.path("ramdisk.gz"), 9 * 1024, seed=15)
        self.run_ref("/out/mkbootimg --kernel /w/zImage"
                     " --ramdisk /w/ramdisk.gz"
                     " --cmdline 'seandroid test' -o /w/c_boot.img")
        code, _out, err = self.run_py(
            "pack", "--kernel", self.path("zImage"),
            "--ramdisk", self.path("ramdisk.gz"),
            "--cmdline", "seandroid test",
            "--seandroid",
            "-o", self.path("py_sea.img"))
        self.assertEqual(code, 0, err)
        expected = self.read("c_boot.img") + b"SEANDROIDENFORCE"
        self.assertEqual(self.read("py_sea.img"), expected,
                         "--seandroid output != C output + footer")

    def test_pack_long_cmdline_golden(self):
        """>511-char commandline: the C tool rejects it (no extra-cmdline
        field in this header v0 variant), so must we, with the same error."""
        write_random(self.path("zImage"), 32 * 1024, seed=5)
        write_random(self.path("ramdisk.gz"), 8 * 1024, seed=6)
        with open(self.path("cmdline.txt"), "w") as f:
            f.write("x" * 600)

        rc, err = self.run_ref_rc(
            "/out/mkbootimg --kernel /w/zImage --ramdisk /w/ramdisk.gz"
            " --cmdline \"$(cat /w/cmdline.txt)\" -o /w/c_long.img")
        self.assertNotEqual(rc, 0, "C accepted a >511-char cmdline")
        self.assertIn(b"commandline too large", err)

        code, _out, err = self.run_py(
            "pack", "--kernel", self.path("zImage"),
            "--ramdisk", self.path("ramdisk.gz"),
            "--cmdline", "x" * 600,
            "-o", self.path("py_long.img"))
        self.assertEqual(code, 1)
        self.assertIn(b"commandline too large", err)
        self.assertFalse(os.path.exists(self.path("py_long.img")))

    def test_max_size_guard(self):
        """pack refuses (exit 2) when the image would exceed --max-size."""
        kernel = write_random(self.path("zImage"), 64 * 1024, seed=21)
        code, _out, err = self.run_py(
            "pack", "--kernel", kernel, "--ramdisk", "NONE",
            "--max-size", "0x10000", "-o", self.path("too_big.img"))
        self.assertEqual(code, 2)
        self.assertIn(b"max-size", err)
        self.assertFalse(os.path.exists(self.path("too_big.img")))


class RoundTripTests(TempDirTest):
    """unpack -> pack --from-json byte-identity (no Docker needed for the
    pure-python images; the C-produced image case lives in GoldenTests)."""

    def test_roundtrip_with_dt(self):
        dtc = which_dtc()
        if dtc is None:
            self.skipTest(SKIP_DTC)
        rev3 = write_dts(dtc, self.path("rev3.dts"), self.path("rev3.dtb"),
                         3, 3, tag=3)
        rev9 = write_dts(dtc, self.path("rev9.dts"), self.path("rev9.dtb"),
                         9, 255, tag=9)
        code, _out, err = self.run_py(
            "dtbh-pack", "-o", self.path("dt.img"),
            "--dtb=3=" + rev3, "--dtb=9=" + rev9)
        self.assertEqual(code, 0, err)

        write_random(self.path("zImage"), 64 * 1024, seed=7)
        write_random(self.path("ramdisk.gz"), 40 * 1024, seed=8)
        code, _out, err = self.run_py(
            "pack", "--kernel", self.path("zImage"),
            "--ramdisk", self.path("ramdisk.gz"),
            "--dt", self.path("dt.img"),
            "--cmdline", "round=trip test image",
            "--board", "SM-T715",
            "-o", self.path("orig.img"))
        self.assertEqual(code, 0, err)
        original = self.read("orig.img")

        code, _out, err = self.run_py(
            "unpack", self.path("orig.img"), "-o", self.path("unpacked"))
        self.assertEqual(code, 0, err)
        code, _out, err = self.run_py(
            "pack", "--from-json", self.path("unpacked", "bootimg.json"),
            "-o", self.path("rt.img"))
        self.assertEqual(code, 0, err)
        self.assertEqual(original, self.read("rt.img"),
                         "round-trip not byte-identical")

    def test_roundtrip_minimal_and_json_fields(self):
        write_random(self.path("zImage"), 10 * 1024, seed=31)
        code, _out, err = self.run_py(
            "pack", "--kernel", self.path("zImage"),
            "--cmdline", "minimal", "-o", self.path("orig.img"))
        self.assertEqual(code, 0, err)
        code, _out, err = self.run_py(
            "unpack", self.path("orig.img"), "-o", self.path("unpacked"))
        self.assertEqual(code, 0, err)
        with open(self.path("unpacked", "bootimg.json")) as f:
            manifest = json.load(f)
        # Every header field must be present in the manifest.
        for field in ("kernel_size", "kernel_addr", "ramdisk_size",
                      "ramdisk_addr", "second_size", "second_addr",
                      "tags_addr", "page_size", "dt_size", "unused",
                      "name", "cmdline", "id"):
            self.assertIn(field, manifest["header"])
        code, _out, err = self.run_py(
            "pack", "--from-json", self.path("unpacked", "bootimg.json"),
            "-o", self.path("rt.img"))
        self.assertEqual(code, 0, err)
        self.assertEqual(self.read("orig.img"), self.read("rt.img"))

    def test_roundtrip_seandroid_footer(self):
        """A synthetic image with the SEANDROIDENFORCE footer round-trips
        byte-identically; --seandroid output == plain output + footer; the
        trailer lands in trailer.bin and trailer_hex."""
        write_random(self.path("zImage"), 30 * 1024, seed=51)
        write_random(self.path("ramdisk.gz"), 13 * 1024, seed=52)
        common = ("pack", "--kernel", self.path("zImage"),
                  "--ramdisk", self.path("ramdisk.gz"),
                  "--cmdline", "footer test")

        code, _out, err = self.run_py(*common, "-o", self.path("plain.img"))
        self.assertEqual(code, 0, err)
        code, _out, err = self.run_py(*common, "--seandroid",
                                      "-o", self.path("sea.img"))
        self.assertEqual(code, 0, err)
        self.assertEqual(self.read("sea.img"),
                         self.read("plain.img") + b"SEANDROIDENFORCE",
                         "--seandroid output != plain output + footer")

        code, _out, err = self.run_py(
            "unpack", self.path("sea.img"), "-o", self.path("unpacked"))
        self.assertEqual(code, 0, err)
        self.assertEqual(self.read("unpacked", "trailer.bin"),
                         b"SEANDROIDENFORCE")
        with open(self.path("unpacked", "bootimg.json")) as f:
            manifest = json.load(f)
        self.assertEqual(manifest["trailer_hex"],
                         b"SEANDROIDENFORCE".hex())

        code, _out, err = self.run_py(
            "pack", "--from-json", self.path("unpacked", "bootimg.json"),
            "-o", self.path("rt.img"))
        self.assertEqual(code, 0, err)
        self.assertEqual(self.read("sea.img"), self.read("rt.img"),
                         "footer round-trip not byte-identical")

    def test_roundtrip_no_ramdisk(self):
        write_random(self.path("zImage"), 24 * 1024, seed=41)
        code, _out, err = self.run_py(
            "pack", "--kernel", self.path("zImage"), "--ramdisk", "NONE",
            "-o", self.path("orig.img"))
        self.assertEqual(code, 0, err)
        original = self.read("orig.img")
        self.run_py("unpack", self.path("orig.img"),
                    "-o", self.path("unpacked"))
        code, _out, err = self.run_py(
            "pack", "--from-json", self.path("unpacked", "bootimg.json"),
            "-o", self.path("rt.img"))
        self.assertEqual(code, 0, err)
        self.assertEqual(original, self.read("rt.img"))


class UnitTests(TempDirTest):
    """Small in-process checks of the parsing/format helpers."""

    def test_pad_len_matches_write_padding(self):
        # write_padding() (mkbootimg.c:95-111): 0 when already page aligned.
        self.assertEqual(sbi.pad_len(0, 2048), 0)
        self.assertEqual(sbi.pad_len(2048, 2048), 0)
        self.assertEqual(sbi.pad_len(1, 2048), 2047)
        self.assertEqual(sbi.pad_len(608, 2048), 2048 - 608)

    def test_boot_header_layout_offsets(self):
        # Field offsets derived from struct boot_img_hdr (bootimg.h:28-50).
        hdr = sbi.BootHeader()
        hdr.name = b"SM-T715"
        hdr.cmdline = b"console=ttySAC0"
        hdr.id[0] = 0xDEADBEEF
        raw = hdr.pack()
        self.assertEqual(len(raw), 608)
        self.assertEqual(raw[0:8], b"ANDROID!")
        self.assertEqual(struct.unpack_from("<I", raw, 0x28)[0], 0)  # dt_size
        self.assertEqual(raw[0x30:0x37], b"SM-T715")
        self.assertEqual(raw[0x40:0x4F], b"console=ttySAC0")
        self.assertEqual(struct.unpack_from("<I", raw, 0x240)[0], 0xDEADBEEF)

    def test_info_rejects_bad_magic(self):
        with open(self.path("garbage.img"), "wb") as f:
            f.write(b"\x00" * 4096)
        code, _out, _err = self.run_py("info", self.path("garbage.img"))
        self.assertNotEqual(code, 0)
        self.assertEqual(code, 1)

    def test_info_prints_trailer(self):
        write_random(self.path("zImage"), 12 * 1024, seed=61)
        code, _out, err = self.run_py(
            "pack", "--kernel", self.path("zImage"), "--seandroid",
            "-o", self.path("sea.img"))
        self.assertEqual(code, 0, err)
        code, out, err = self.run_py("info", self.path("sea.img"))
        self.assertEqual(code, 0, err)
        self.assertIn(b"SEANDROIDENFORCE", out)
        self.assertIn(b"16 bytes", out)

    def test_dtbh_parse_rejects_bad_magic(self):
        with self.assertRaises(sbi.ToolError):
            sbi.dtbh_parse(b"NOPE" + b"\x00" * 64)

    def test_dtbh_unpack_names_and_extracts(self):
        dtc = which_dtc()
        if dtc is None:
            self.skipTest(SKIP_DTC)
        rev3 = write_dts(dtc, self.path("rev3.dts"), self.path("rev3.dtb"),
                         3, 3, tag=3)
        rev9 = write_dts(dtc, self.path("rev9.dts"), self.path("rev9.dtb"),
                         9, 255, tag=9)
        code, _out, err = self.run_py(
            "dtbh-pack", "-o", self.path("dt.img"),
            "--dtb=3=" + rev3, "--dtb=9=" + rev9)
        self.assertEqual(code, 0, err)
        code, out, err = self.run_py(
            "dtbh-unpack", self.path("dt.img"), "-o", self.path("out"))
        self.assertEqual(code, 0, err)
        # unpackdtbhimg.c:165 naming scheme.
        self.assertTrue(os.path.exists(
            self.path("out", "chip5433-0x3138-0x36480ee3_rev3-3.dtb")))
        self.assertTrue(os.path.exists(
            self.path("out", "chip5433-0x3138-0x36480ee3_rev9-255.dtb")))
        # Extracted blobs must be valid DTBs again (padding included, the
        # trailing zeros are outside the FDT totalsize).
        for name in os.listdir(self.path("out")):
            if name.endswith(".dtb"):
                with open(os.path.join(self.path("out"), name), "rb") as f:
                    err = sbi.fdt_check_header(f.read())
                self.assertIsNone(err)


if __name__ == "__main__":
    unittest.main()
