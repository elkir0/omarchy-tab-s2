# SPDX-License-Identifier: GPL-2.0-or-later
"""RFS server tests (offline, synthetic frames; not the real CP)."""

import errno
import hashlib
import os
import random
import struct
import tempfile
import unittest

import testutil  # noqa: F401  (sys.path)
from shannond import rfs
from shannond.rfs import HDR, RfsFramer, RfsServer

ARM_O_WRONLY = 0o1
ARM_O_RDWR = 0o2
ARM_O_CREAT = 0o100
ARM_O_TRUNC = 0o1000
ARM_O_EXCL = 0o200


def frame(cmd, rid, body=b""):
    return HDR.pack(6 + len(body), cmd, rid) + body


def path_body(path, len_first=True):
    p = path.encode() if isinstance(path, str) else path
    return struct.pack("<I", len(p)) + p


def fixed_path(path):
    p = path.encode() if isinstance(path, str) else path
    return struct.pack("<I", len(p)) + p.ljust(0x400, b"\0")


def parse(reply):
    length, cmd, rid = HDR.unpack_from(reply)
    assert length == len(reply), (length, len(reply))
    return cmd, rid, reply[6:]


def tree_digest(top):
    h = hashlib.sha256()
    for root, dirs, files in sorted(os.walk(top, followlinks=False)):
        dirs.sort()
        for name in sorted(files) + sorted(d for d in dirs if os.path.islink(os.path.join(root, d))):
            p = os.path.join(root, name)
            h.update(os.path.relpath(p, top).encode())
            if os.path.islink(p):
                h.update(b"L" + os.readlink(p).encode())
            else:
                with open(p, "rb") as f:
                    h.update(f.read())
    return h.hexdigest()


class FramerTest(unittest.TestCase):
    def test_single_frame(self):
        f = frame(1, 7, struct.pack("<II", 0, 16))
        self.assertEqual(RfsFramer().feed(f), [f])

    def test_byte_by_byte_reassembly(self):
        f = frame(2, 9, struct.pack("<II", 4, 300) + bytes(300))
        fr = RfsFramer()
        out = []
        for i in range(len(f)):
            out += fr.feed(f[i:i + 1])
        self.assertEqual(out, [f])

    def test_two_frames_one_chunk_and_split_tail(self):
        a = frame(1, 1, struct.pack("<II", 0, 4))
        b = frame(6, 2, struct.pack("<i", 1))
        fr = RfsFramer()
        self.assertEqual(fr.feed(a + b[:3]), [a])
        self.assertEqual(fr.feed(b[3:]), [b])

    def test_large_frame_in_chunks(self):
        data = os.urandom(0x7F000)
        f = frame(2, 3, struct.pack("<II", 0, len(data)) + data)
        fr = RfsFramer()
        out = []
        for i in range(0, len(f), 4096):
            out += fr.feed(f[i:i + 4096])
        self.assertEqual(out, [f])

    def test_oversize_frame_dropped(self):
        fr = RfsFramer()
        bad = struct.pack("<IBB", 0x80001, 2, 1) + bytes(100)
        self.assertEqual(fr.feed(bad), [])
        self.assertEqual(fr.dropped, len(bad))
        good = frame(6, 4, struct.pack("<i", 1))
        self.assertEqual(fr.feed(good), [good])

    def test_invalid_cmd_and_short_length_dropped(self):
        fr = RfsFramer()
        self.assertEqual(fr.feed(struct.pack("<IBB", 10, 0x30, 1) + bytes(4)), [])
        self.assertEqual(fr.feed(struct.pack("<IBB", 3, 1, 1)), [])
        self.assertEqual(fr.dropped, 16)


class RfsBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="shannond-rfs-")
        self.top = self.tmp.name
        self.nv_path = os.path.join(self.top, "nv", "nv_data.bin")
        os.makedirs(os.path.dirname(self.nv_path))
        self.nv_bytes = random.Random(5).randbytes(0x100000)
        with open(self.nv_path, "wb") as f:
            f.write(self.nv_bytes)
        os.chmod(self.nv_path, 0o444)
        self.lower = os.path.join(self.top, "efs-root")
        os.makedirs(os.path.join(self.lower, "sub"))
        with open(os.path.join(self.lower, "ProtectedNVInitCause.txt"), "wb") as f:
            f.write(b"lower-content")
        with open(os.path.join(self.lower, "sub", "inner.bin"), "wb") as f:
            f.write(b"inner")
        self.outside = os.path.join(self.top, "outside")
        os.makedirs(self.outside)
        with open(os.path.join(self.outside, "secret"), "wb") as f:
            f.write(b"do-not-touch")
        os.symlink(self.outside, os.path.join(self.lower, "escape"))
        os.symlink(os.path.join(self.outside, "secret"), os.path.join(self.lower, "secret-link"))
        self.upper = os.path.join(self.top, "upper")
        self.server = RfsServer(self.nv_path, self.upper, self.lower, max_file_size=64 * 1024,
                                max_total=256 * 1024)
        self.server.open()
        self.lower_digest = tree_digest(self.lower)
        self.outside_digest = tree_digest(self.outside)

    def tearDown(self):
        self.server.close()
        os.chmod(self.nv_path, 0o644)
        self.tmp.cleanup()

    def req(self, cmd, body=b"", rid=0x42):
        reply = self.server.handle(frame(cmd, rid, body))
        if reply is None:
            return None
        rcmd, rrid, payload = parse(reply)
        self.assertEqual((rcmd, rrid), (cmd, rid), "cmd/id must be echoed")
        return payload

    def open_file(self, path, flags):
        p = self.req(rfs.OPEN_FILE, struct.pack("<I", flags) + path_body(path))
        return struct.unpack("<iI", p)

    def assert_untouched(self):
        self.assertEqual(tree_digest(self.lower), self.lower_digest, "lower layer modified")
        self.assertEqual(tree_digest(self.outside), self.outside_digest, "outside of the sandbox modified")
        with open(self.nv_path, "rb") as f:
            self.assertEqual(f.read(), self.nv_bytes, "NV snapshot modified")


class NvTest(RfsBase):
    def test_nv_read(self):
        p = self.req(rfs.NV_READ_ITEM, struct.pack("<II", 0x1000, 64))
        confirm, off, n = struct.unpack_from("<BII", p)
        self.assertEqual((confirm, off, n), (1, 0x1000, 64))
        self.assertEqual(p[9:], self.nv_bytes[0x1000:0x1040])
        self.assertEqual(len(p) + 6, 15 + 64)

    def test_nv_read_clamped_and_past_end(self):
        p = self.req(rfs.NV_READ_ITEM, struct.pack("<II", 0, 0x200000))
        self.assertEqual(struct.unpack_from("<BII", p)[2], 0x80000)
        p = self.req(rfs.NV_READ_ITEM, struct.pack("<II", 0x200000, 16))
        self.assertEqual(struct.unpack_from("<BII", p), (0, 0x200000, 0))

    def test_nv_write_is_acknowledged_kept_in_memory_and_discarded(self):
        p = self.req(rfs.NV_WRITE_ITEM, struct.pack("<II", 0x20, 4) + b"ABCD")
        self.assertEqual(len(p) + 6, 15)
        self.assertEqual(struct.unpack_from("<BII", p), (1, 0x20, 4))
        p = self.req(rfs.NV_READ_ITEM, struct.pack("<II", 0x20, 4))
        self.assertEqual(p[9:], b"ABCD")
        self.assert_untouched()
        self.server.reseed()
        p = self.req(rfs.NV_READ_ITEM, struct.pack("<II", 0x20, 4))
        self.assertEqual(p[9:], self.nv_bytes[0x20:0x24])

    def test_nv_restore_reseeds(self):
        self.req(rfs.NV_WRITE_ALL_ITEM, struct.pack("<II", 0, 3) + b"xyz")
        p = self.req(rfs.NV_RESTORE)
        self.assertEqual(struct.unpack("<iI", p), (0, 0))
        p = self.req(rfs.NV_READ_ITEM, struct.pack("<II", 0, 3))
        self.assertEqual(p[9:], self.nv_bytes[:3])
        self.assert_untouched()

    def test_write_all_and_buffer_replies_are_13_bytes(self):
        p = self.req(rfs.NV_WRITE_ALL_ITEM, struct.pack("<II", 8, 2) + b"zz")
        self.assertEqual(len(p) + 6, 13)
        self.assertEqual(struct.unpack("<BIH", p), (1, 8, 2))
        p = self.req(rfs.NV_BUFFER_MESSAGE, struct.pack("<BII", 1, 0x100, 0x200))
        self.assertEqual(len(p) + 6, 13)
        self.assertEqual(struct.unpack("<BIH", p), (1, 0x100, 0x200))

    def test_nv_windows_limited_to_snapshot(self):
        p = self.req(rfs.NV_WRITE_ITEM, struct.pack("<II", 0x100000 - 2, 4) + b"ABCD")
        self.assertEqual(p[0], 0, "no growth beyond the snapshot size")
        self.assertEqual(len(self.server.nv.data), 0x100000)
        p = self.req(rfs.NV_WRITE_ITEM, struct.pack("<II", 0x100000 - 4, 4) + b"ABCD")
        self.assertEqual(p[0], 1)

    def test_largest_sizes_recorded(self):
        self.req(rfs.NV_READ_ITEM, struct.pack("<II", 0, 0x1234))
        self.req(rfs.NV_READ_ITEM, struct.pack("<II", 0, 0x10))
        fd, _ = self.open_file("r", ARM_O_RDWR | ARM_O_CREAT)
        self.req(rfs.READ_FILE, struct.pack("<iI", fd, 0x777))
        self.assertEqual(self.server.stats["max_nv_read"], 0x1234)
        self.assertEqual(self.server.stats["max_read_file"], 0x777)

    def test_write_beyond_nv_cap_refused(self):
        p = self.req(rfs.NV_WRITE_ITEM, struct.pack("<II", 0x1FFFFF, 4) + b"ABCD")
        self.assertEqual(p[0], 0)
        self.assert_untouched()

    def test_no_snapshot(self):
        server = RfsServer(None, os.path.join(self.top, "u2"))
        server.open()
        try:
            reply = server.handle(frame(rfs.NV_READ_ITEM, 1, struct.pack("<II", 0, 4)))
            self.assertEqual(struct.unpack_from("<BII", reply, 6), (0, 0, 0))
        finally:
            server.close()

    def test_no_reply_commands(self):
        for cmd in (0x0D, 0x0E, 0x0F, 0x10, 0x12):
            self.assertIsNone(self.server.handle(frame(cmd, 3, b"\0" * 8)), hex(cmd))

    def test_id_echo_for_every_replying_command(self):
        for cmd in range(1, 0x18):
            if cmd in rfs.NO_REPLY:
                continue
            for rid in (0, 1, 0x7F, 0xFF):
                reply = self.server.handle(frame(cmd, rid, bytes(0x420)))
                self.assertIsNotNone(reply, hex(cmd))
                rcmd, rrid, _ = parse(reply)
                self.assertEqual((rcmd, rrid), (cmd, rid))

    def test_truncated_requests_do_not_crash(self):
        for cmd in range(1, 0x18):
            for n in range(0, 20):
                reply = self.server.handle(frame(cmd, 5, bytes(n)))
                if reply is not None:
                    parse(reply)
        self.assert_untouched()


class FileVerbTest(RfsBase):
    def test_create_write_seek_read_close_info(self):
        h, err = self.open_file("dir/a.txt", ARM_O_RDWR | ARM_O_CREAT)
        self.assertEqual((h, err), (3, 0), "handles are small integers numbered from 3")
        p = self.req(rfs.WRITE_FILE, struct.pack("<iI", h, 5) + b"hello")
        self.assertEqual(struct.unpack("<iI", p), (5, 0))
        p = self.req(rfs.LSEEK_FILE, struct.pack("<iiI", h, 0, 0))
        self.assertEqual(len(p) + 6, 18)
        self.assertEqual(struct.unpack("<IiI", p), (0, 0, 0))
        p = self.req(rfs.READ_FILE, struct.pack("<iI", h, 100))
        n, e = struct.unpack_from("<II", p)
        self.assertEqual((n, e, p[8:]), (5, 0, b"hello"))
        p = self.req(rfs.GET_HANDLE_INFO, struct.pack("<i", h))
        self.assertEqual(len(p) + 6, 32)
        self.assertEqual(struct.unpack_from("<iHI", p), (0, 2, 5))
        self.assertEqual(struct.unpack("<iI", self.req(rfs.CLOSE_FILE, struct.pack("<i", h))), (0, 0))
        p = self.req(rfs.GET_FILE_INFO, path_body("dir/a.txt"))
        self.assertEqual(struct.unpack_from("<iHI", p), (0, 2, 5))
        self.assertTrue(os.path.isfile(os.path.join(self.upper, "efs", "dir", "a.txt")))
        self.assert_untouched()

    def test_put_get_rename_unlink_mkdir_create(self):
        body = struct.pack("<I", ARM_O_WRONLY | ARM_O_CREAT | ARM_O_TRUNC) + fixed_path("p.bin") \
            + struct.pack("<I", 3) + b"abc"
        p = self.req(rfs.PUT_FILE, body)
        self.assertEqual(struct.unpack("<IiI", p), (0, 3, 0))
        p = self.req(rfs.GET_FILE, fixed_path("p.bin") + struct.pack("<I", 10))
        self.assertEqual(p[8:], b"abc")
        p = self.req(rfs.RENAME_FILE, fixed_path("p.bin") + path_body("q.bin"))
        self.assertEqual(struct.unpack("<iI", p), (0, 0))
        self.assertEqual(struct.unpack_from("<iHI", self.req(rfs.GET_FILE_INFO, path_body("q.bin"))), (0, 2, 3))
        self.assertEqual(struct.unpack("<iI", self.req(rfs.UNLINK_FILE, path_body("q.bin"))), (0, 0))
        p = self.req(rfs.GET_FILE_INFO, path_body("q.bin"))
        self.assertEqual(struct.unpack_from("<i", p)[0], -1)
        self.assertEqual(struct.unpack_from("<I", p, 22)[0], 2, "ENOENT as the Linux number")
        self.assertEqual(struct.unpack("<iI", self.req(rfs.MAKE_DIR, path_body("newdir"))), (0, 0))
        self.assertEqual(struct.unpack_from("<iH", self.req(rfs.GET_FILE_INFO, path_body("newdir")))[1], 1)
        fd, err = struct.unpack("<iI", self.req(rfs.CREATE_FILE, path_body("newdir/c")))
        self.assertGreater(fd, 0)
        self.assert_untouched()

    def test_lower_read_copy_up_and_whiteout(self):
        h, err = self.open_file("ProtectedNVInitCause.txt", 0)
        self.assertEqual(err, 0)
        p = self.req(rfs.READ_FILE, struct.pack("<iI", h, 100))
        self.assertEqual(p[8:], b"lower-content")
        self.req(rfs.CLOSE_FILE, struct.pack("<i", h))
        h, err = self.open_file("ProtectedNVInitCause.txt", ARM_O_RDWR)
        self.assertEqual(err, 0)
        self.req(rfs.WRITE_FILE, struct.pack("<iI", h, 3) + b"NEW")
        self.req(rfs.CLOSE_FILE, struct.pack("<i", h))
        with open(os.path.join(self.upper, "efs", "ProtectedNVInitCause.txt"), "rb") as f:
            self.assertEqual(f.read(), b"NEWer-content")
        self.assertEqual(struct.unpack("<iI", self.req(rfs.UNLINK_FILE, path_body("sub/inner.bin"))), (0, 0))
        _, err = self.open_file("sub/inner.bin", 0)
        self.assertEqual(err, errno.ENOENT)
        self.assert_untouched()

    def test_reset_upper_wipes_efs_keeps_log(self):
        self.open_file("x/y", ARM_O_RDWR | ARM_O_CREAT)
        self.open_file("err_crash.log", ARM_O_RDWR | ARM_O_CREAT)
        self.open_file("/data/log/cp.log", ARM_O_RDWR | ARM_O_CREAT)
        self.server.reseed()
        self.assertEqual(os.listdir(os.path.join(self.upper, "efs")), [])
        self.assertEqual(sorted(os.listdir(os.path.join(self.upper, "log"))), ["cp.log", "err_crash.log"])
        self.assertEqual(self.server.sandbox.handles, {})

    def test_system_etc_names_enoent(self):
        for name in ("Audio_OEM_x", "RF_NVM_y", "CP_AUDIO_SLSI.bin", "Audio_IFX"):
            fd, err = self.open_file(name, ARM_O_RDWR | ARM_O_CREAT)
            self.assertEqual((fd, err), (-1, errno.ENOENT))

    def test_handle_limit(self):
        self.assertEqual(rfs.Sandbox.MAX_HANDLES, 64)
        for i in range(rfs.Sandbox.MAX_HANDLES):
            fd, err = self.open_file("f%d" % i, ARM_O_RDWR | ARM_O_CREAT)
            self.assertEqual(fd, i + 3)
        fd, err = self.open_file("one-more", ARM_O_RDWR | ARM_O_CREAT)
        self.assertEqual((fd, err), (-1, 24))
        self.req(rfs.CLOSE_FILE, struct.pack("<i", 10))
        fd, err = self.open_file("reuse", ARM_O_RDWR | ARM_O_CREAT)
        self.assertEqual(fd, 10, "lowest free handle is reused")

    def test_bad_handles(self):
        for cmd, body in ((rfs.READ_FILE, struct.pack("<iI", 99, 4)), (rfs.CLOSE_FILE, struct.pack("<i", -1)),
                          (rfs.WRITE_FILE, struct.pack("<iI", 3, 1) + b"x"),
                          (rfs.GET_HANDLE_INFO, struct.pack("<i", 0))):
            self.assertIsNotNone(self.req(cmd, body))

    def test_size_caps(self):
        fd, _ = self.open_file("big", ARM_O_RDWR | ARM_O_CREAT)
        p = self.req(rfs.WRITE_FILE, struct.pack("<iI", fd, 70000) + bytes(70000))
        self.assertEqual(struct.unpack("<iI", p), (-1, 27))  # EFBIG
        for i in range(5):
            fd, _ = self.open_file("q%d" % i, ARM_O_RDWR | ARM_O_CREAT)
            self.req(rfs.WRITE_FILE, struct.pack("<iI", fd, 60000) + bytes(60000))
        self.assertLessEqual(self.server.sandbox.usage(), 256 * 1024)

    def test_symlinks_in_lower_are_never_followed(self):
        for path in ("escape/secret", "secret-link", "escape"):
            for flags in (0, ARM_O_RDWR):
                fd, err = self.open_file(path, flags)
                self.assertEqual(fd, -1, (path, flags))
        # creating over a lower symlink makes a fresh upper entry, never writes through the link
        fd, err = self.open_file("escape/secret", ARM_O_RDWR | ARM_O_CREAT)
        if fd > 0:
            self.req(rfs.WRITE_FILE, struct.pack("<iI", fd, 3) + b"new")
            self.assertTrue(os.path.isfile(os.path.join(self.upper, "efs", "escape", "secret")))
        p = self.req(rfs.GET_FILE, fixed_path("secret-link") + struct.pack("<I", 100))
        self.assertEqual(struct.unpack_from("<I", p)[0], 0)
        self.assert_untouched()

    def test_symlink_planted_in_upper_is_not_followed(self):
        os.makedirs(os.path.join(self.upper, "efs", "d"), exist_ok=True)
        os.symlink(self.outside, os.path.join(self.upper, "efs", "d", "out"))
        os.symlink(os.path.join(self.outside, "secret"), os.path.join(self.upper, "efs", "sl"))
        for path in ("d/out/secret", "d/out/new", "sl"):
            fd, err = self.open_file(path, ARM_O_RDWR | ARM_O_CREAT | ARM_O_TRUNC)
            self.assertEqual(fd, -1, path)
        self.req(rfs.MAKE_DIR, path_body("d/out/x"))
        self.req(rfs.UNLINK_FILE, path_body("d/out/secret"))
        self.req(rfs.RENAME_FILE, fixed_path("sl") + path_body("d/out/moved"))
        self.assertEqual(sorted(os.listdir(self.outside)), ["secret"])
        self.assert_untouched()

    def test_dotdot_refused(self):
        for path in ("../outside/secret", "a/../../outside/x", "/data/log/../../x", "err/../../x", ".."):
            fd, err = self.open_file(path, ARM_O_RDWR | ARM_O_CREAT)
            self.assertEqual((fd, err), (-1, errno.EACCES), path)
        self.assert_untouched()


class ConfinementFuzzTest(RfsBase):
    """Random paths through every path-taking verb: nothing outside the upper dir changes."""

    SEGMENTS = ["..", ".", "", "a", "b", "efs", "root", "escape", "secret-link", "sub", "data", "log",
                "err", "%2e%2e", "...", "a" * 300, "\x01", "\x7f", "x\x00y", "\xff", "/", "//",
                "Audio_OEM", "ProtectedNVInitCause.txt", "outside", "~", "*", "\\..\\"]

    def random_path(self, rng):
        n = rng.randint(1, 6)
        parts = [rng.choice(self.SEGMENTS) for _ in range(n)]
        prefix = rng.choice(["", "/", "/data/log/", "err", "../", "/efs/root/"])
        return (prefix + "/".join(parts)).encode("latin-1")[:0x420]

    def test_fuzz(self):
        rng = random.Random(1234)
        flag_choices = [0, ARM_O_WRONLY | ARM_O_CREAT, ARM_O_RDWR | ARM_O_CREAT | ARM_O_TRUNC,
                        ARM_O_RDWR | ARM_O_CREAT | ARM_O_EXCL, ARM_O_RDWR, 0o4010002, 0xFFFFFFFF]
        opened = 0
        for i in range(2500):
            path = self.random_path(rng)
            other = self.random_path(rng)
            verb = rng.randrange(8)
            if verb == 0:
                body = struct.pack("<I", rng.choice(flag_choices)) + struct.pack("<I", len(path)) + path
                reply = self.server.handle(frame(rfs.OPEN_FILE, i & 0xFF, body))
                fd = struct.unpack_from("<i", reply, 6)[0]
                if fd > 0:
                    opened += 1
                    self.server.handle(frame(rfs.WRITE_FILE, 1, struct.pack("<iI", fd, 4) + b"fuzz"))
                    self.server.handle(frame(rfs.CLOSE_FILE, 1, struct.pack("<i", fd)))
            elif verb == 1:
                body = struct.pack("<I", rng.choice(flag_choices)) + struct.pack("<I", len(path)) \
                    + path[:0x400].ljust(0x400, b"\0") + struct.pack("<I", 4) + b"data"
                self.server.handle(frame(rfs.PUT_FILE, i & 0xFF, body))
            elif verb == 2:
                self.server.handle(frame(rfs.MAKE_DIR, 1, struct.pack("<I", len(path)) + path))
            elif verb == 3:
                self.server.handle(frame(rfs.UNLINK_FILE, 1, struct.pack("<I", len(path)) + path))
            elif verb == 4:
                body = struct.pack("<I", len(path[:0x400])) + path[:0x400].ljust(0x400, b"\0") \
                    + struct.pack("<I", len(other)) + other
                self.server.handle(frame(rfs.RENAME_FILE, 1, body))
            elif verb == 5:
                reply = self.server.handle(frame(rfs.CREATE_FILE, 1, struct.pack("<I", len(path)) + path))
                fd = struct.unpack_from("<i", reply, 6)[0]
                if fd > 0:
                    opened += 1
                    self.server.handle(frame(rfs.CLOSE_FILE, 1, struct.pack("<i", fd)))
            elif verb == 6:
                self.server.handle(frame(rfs.GET_FILE_INFO, 1, struct.pack("<I", len(path)) + path))
            else:
                body = struct.pack("<I", len(path[:0x400])) + path[:0x400].ljust(0x400, b"\0") + struct.pack("<I", 64)
                self.server.handle(frame(rfs.GET_FILE, 1, body))
        self.assertGreater(opened, 100, "the fuzz must also exercise successful opens")
        self.assertEqual(self.server.sandbox.handles, {})
        self.assert_untouched()
        # every file created lives under upper/
        top_entries = sorted(os.listdir(self.top))
        self.assertEqual(top_entries, ["efs-root", "nv", "outside", "upper"])
        for root, dirs, files in os.walk(self.upper):
            for name in files + dirs:
                self.assertFalse(os.path.islink(os.path.join(root, name)))

    def test_map_path_never_escapes(self):
        rng = random.Random(99)
        sandbox = self.server.sandbox
        for _ in range(5000):
            raw = self.random_path(rng)
            try:
                layer, comps = sandbox.map_path(raw)
            except rfs.RfsError:
                continue
            self.assertIn(layer, ("efs", "log"))
            for c in comps:
                self.assertNotIn(c, (b"..", b".", b""))
                self.assertNotIn(b"/", c)
                self.assertNotIn(b"\0", c)


if __name__ == "__main__":
    unittest.main()
