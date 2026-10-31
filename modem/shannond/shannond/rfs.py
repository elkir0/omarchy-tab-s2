# SPDX-License-Identifier: GPL-2.0-or-later
"""RFS server for /dev/umts_rfs0, "observe" mode (SYNTHESIS D6, phase 1).

Protocol (ril_runtime_rfs.md §5): 6-byte header ``{u32 length (whole frame,
LE); u8 cmd; u8 id}``, parameters unaligned from offset 6, frames up to
0x80000 bytes reassembled from several reads, one ``write()`` per reply with
the request's ``cmd`` and ``id`` echoed.  Commands 0x0D-0x10 and 0x12 get no
reply (as stock).

Observe mode guarantees:

* NV verbs work on an in-memory copy seeded from the verified snapshot
  (``/var/lib/shannon/nv/nv_data.bin``, opened read-only) at every CP boot;
  writes are acknowledged and discarded; NV_RESTORE re-seeds.
* File verbs are confined to a sandbox: lower = read-only copy of efs/root
  (``/var/lib/shannon/efs-root``, optional), upper = tmpfs
  (``/run/shannond/rfs``).  Every path is resolved component by component
  with ``openat``-style calls relative to a directory fd, ``O_NOFOLLOW`` on
  every component, ``..`` refused, length/depth/size caps, and handles are
  small integers from a table (never raw fds).
* Nothing is ever written outside the upper directory: never /efs, never a
  block device.

Only ``{cmd, id, offset, length, path}`` are logged by default.
"""

import errno
import logging
import os
import shutil
import stat
import struct
import time

from .loop import HUP, ERROR, READABLE

log = logging.getLogger("shannond.rfs")

HDR = struct.Struct("<IBB")
HDR_LEN = 6
MAX_FRAME = 0x80000
MAX_NV_IO = 0x80000
MAX_FILE_READ = 0x40000
NV_CAP = 0x200000
PATH_FIELD = 0x400

NV_READ_ITEM = 0x01
NV_WRITE_ITEM = 0x02
READ_FILE = 0x03
WRITE_FILE = 0x04
LSEEK_FILE = 0x05
CLOSE_FILE = 0x06
PUT_FILE = 0x07
GET_FILE = 0x08
RENAME_FILE = 0x09
GET_FILE_INFO = 0x0A
UNLINK_FILE = 0x0B
MAKE_DIR = 0x0C
REMOVE_DIR = 0x0D
OPEN_DIR = 0x0E
READ_DIR = 0x0F
CLOSE_DIR = 0x10
OPEN_FILE = 0x11
FTRUNCATE_FILE = 0x12
GET_HANDLE_INFO = 0x13
CREATE_FILE = 0x14
NV_WRITE_ALL_ITEM = 0x15
NV_BUFFER_MESSAGE = 0x16
NV_RESTORE = 0x17

NO_REPLY = frozenset({REMOVE_DIR, OPEN_DIR, READ_DIR, CLOSE_DIR, FTRUNCATE_FILE})

CMD_NAMES = {
    0x01: "NV_READ_ITEM", 0x02: "NV_WRITE_ITEM", 0x03: "READ_FILE", 0x04: "WRITE_FILE",
    0x05: "LSEEK_FILE", 0x06: "CLOSE_FILE", 0x07: "PUT_FILE", 0x08: "GET_FILE",
    0x09: "RENAME_FILE", 0x0A: "GET_FILE_INFO", 0x0B: "UNLINK_FILE", 0x0C: "MAKE_DIR",
    0x0D: "REMOVE_DIR", 0x0E: "OPEN_DIR", 0x0F: "READ_DIR", 0x10: "CLOSE_DIR",
    0x11: "OPEN_FILE", 0x12: "FTRUNCATE_FILE", 0x13: "GET_HANDLE_INFO", 0x14: "CREATE_FILE",
    0x15: "NV_WRITE_ALL_ITEM", 0x16: "NV_BUFFER_MESSAGE", 0x17: "NV_RESTORE",
}

# ARM Linux open(2) flags as sent by the CP (translated, never passed through).
ARM_O_ACCMODE = 0o3
ARM_O_CREAT = 0o100
ARM_O_EXCL = 0o200
ARM_O_TRUNC = 0o1000
ARM_O_APPEND = 0o2000

# errno numbers the CP expects (ARM Linux), mapped by name from the host's.
LINUX_ERRNO = {
    "EPERM": 1, "ENOENT": 2, "EIO": 5, "EBADF": 9, "ENOMEM": 12, "EACCES": 13, "EEXIST": 17,
    "EXDEV": 18, "ENOTDIR": 20, "EISDIR": 21, "EINVAL": 22, "ENFILE": 23, "EMFILE": 24,
    "EFBIG": 27, "ENOSPC": 28, "ESPIPE": 29, "EROFS": 30, "ENAMETOOLONG": 36, "ENOSYS": 38,
    "ENOTEMPTY": 39, "ELOOP": 40, "EOVERFLOW": 75,
}


def linux_errno(err):
    name = errno.errorcode.get(err, "EIO")
    return LINUX_ERRNO.get(name, 5)


class RfsError(Exception):
    def __init__(self, err, message=""):
        super().__init__(message or os.strerror(err))
        self.errno = err


class RfsFramer:
    """Reassemble RFS frames from read() chunks (first chunk carries length)."""

    def __init__(self):
        self._buf = bytearray()
        self._need = None
        self.chunks = 0
        self.dropped = 0

    def feed(self, data):
        frames = []
        self._buf += data
        self.chunks += 1
        while True:
            if self._need is None:
                if len(self._buf) < HDR_LEN:
                    break
                length, cmd, _ = HDR.unpack_from(self._buf)
                if length < HDR_LEN or length > MAX_FRAME or not 1 <= cmd <= 0x17:
                    log.warning("RFS: invalid frame header (length=%d cmd=0x%02x), dropping %d bytes",
                                length, cmd, len(self._buf))
                    self.dropped += len(self._buf)
                    self._buf.clear()
                    self.chunks = 0
                    break
                self._need = length
            if len(self._buf) < self._need:
                break
            frame = bytes(self._buf[:self._need])
            del self._buf[:self._need]
            log.debug("RFS: full frame (%d chunks / %d bytes)", self.chunks, len(frame))
            self._need = None
            self.chunks = 0 if not self._buf else 1
            frames.append(frame)
        return frames

    def reset(self):
        self._buf.clear()
        self._need = None
        self.chunks = 0


class NvStore:
    """In-memory NV copy seeded from a read-only snapshot."""

    def __init__(self, seed_path):
        self.seed_path = seed_path
        self.data = None
        self.writes = []  # (cmd, offset, length) journal, observe mode
        self.buffer_mode = False

    @property
    def available(self):
        return self.data is not None

    def reseed(self):
        self.buffer_mode = False
        if not self.seed_path:
            self.data = None
            return False
        try:
            fd = os.open(self.seed_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        except OSError as exc:
            log.warning("NV snapshot %s unavailable (%s): NV verbs will fail", self.seed_path, exc.strerror)
            self.data = None
            return False
        try:
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode) or st.st_size > NV_CAP:
                log.warning("NV snapshot is not a regular file <= 2 MiB, ignoring it")
                self.data = None
                return False
            chunks = []
            while True:
                chunk = os.read(fd, 1 << 20)
                if not chunk:
                    break
                chunks.append(chunk)
        finally:
            os.close(fd)
        self.data = bytearray(b"".join(chunks))
        log.info("NV copy seeded (%d bytes)", len(self.data))
        return True

    def read(self, offset, size):
        if self.data is None or offset > len(self.data):
            return None
        return bytes(self.data[offset:offset + min(size, MAX_NV_IO)])

    def write(self, cmd, offset, data):
        """Apply to the in-memory copy; windows are limited to the snapshot size (no growth)."""
        self.writes.append((cmd, offset, len(data)))
        del self.writes[:-256]
        if self.data is None or offset + len(data) > len(self.data):
            return False
        self.data[offset:offset + len(data)] = data
        return True


class Sandbox:
    """File verbs confined to lower (read-only) + upper (tmpfs) directories."""

    MAX_HANDLES = 64
    FIRST_HANDLE = 3   # SYNTHESIS v2 D6: handles numbered from 3
    MAX_DEPTH = 16
    MAX_COMPONENT = 255

    def __init__(self, upper, lower=None, max_file_size=8 << 20, max_total=32 << 20):
        self.upper_path = upper
        self.lower_path = lower
        self.max_file_size = max_file_size
        self.max_total = max_total
        self.handles = {}
        self.whiteouts = set()
        self._upper_fd = None
        self._lower_fd = None
        self._usage = None      # cached byte count of the upper layer
        self._mutations = 0

    # -- setup ---------------------------------------------------------------
    def open(self):
        os.makedirs(self.upper_path, mode=0o700, exist_ok=True)
        self._upper_fd = _open_dir(self.upper_path)
        for sub in ("efs", "log"):
            try:
                os.mkdir(sub, 0o700, dir_fd=self._upper_fd)
            except FileExistsError:
                pass
        if self.lower_path:
            try:
                self._lower_fd = _open_dir(self.lower_path)
            except OSError as exc:
                log.info("RFS lower %s not used (%s)", self.lower_path, exc.strerror)
                self._lower_fd = None

    def close(self):
        self.close_all_handles()
        for fd in (self._upper_fd, self._lower_fd):
            if fd is not None:
                os.close(fd)
        self._upper_fd = self._lower_fd = None

    def close_all_handles(self):
        for h in list(self.handles.values()):
            try:
                os.close(h["fd"])
            except OSError:
                pass
        self.handles.clear()

    def reset_upper(self):
        """New CP boot: drop the writable efs layer (the log dir is kept)."""
        self.close_all_handles()
        self.whiteouts.clear()
        self._usage = None
        if self._upper_fd is None:
            return
        try:
            efs_fd = os.open("efs", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                             dir_fd=self._upper_fd)
        except FileNotFoundError:
            efs_fd = None
        if efs_fd is not None:
            try:
                for name in os.listdir(efs_fd):
                    _remove_tree_at(efs_fd, name)
            finally:
                os.close(efs_fd)

    # -- path mapping ----------------------------------------------------------
    def map_path(self, raw):
        """CP path bytes -> (layer root name, components) or raise RfsError."""
        raw = bytes(raw).split(b"\0", 1)[0]
        if not raw or len(raw) > PATH_FIELD:
            raise RfsError(errno.ENOENT if not raw else errno.ENAMETOOLONG)
        if any(b < 0x20 or b == 0x7F for b in raw):
            raise RfsError(errno.EINVAL, "control character in path")
        parts = raw.split(b"/")
        if any(p == b".." for p in parts):
            raise RfsError(errno.EACCES, "'..' in path")
        comps = [p for p in parts if p not in (b"", b".")]
        if not comps:
            raise RfsError(errno.EISDIR)
        name = raw.lstrip(b"/")
        if raw.startswith(b"err") or raw.startswith(b"/data/log") or raw.startswith(b"data/log"):
            if comps[:2] == [b"data", b"log"]:
                comps = comps[2:]
            layer = "log"
        elif name.startswith((b"Audio_OEM", b"Audio_IFX", b"CP_AUDIO_SLSI", b"RF_NVM")):
            raise RfsError(errno.ENOENT, "/system/etc file (not provided)")
        else:
            layer = "efs"
        if not comps:
            raise RfsError(errno.EISDIR)
        if len(comps) > self.MAX_DEPTH or any(len(c) > self.MAX_COMPONENT for c in comps):
            raise RfsError(errno.ENAMETOOLONG)
        return layer, tuple(comps)

    # -- low-level walking ---------------------------------------------------
    def _layer_root(self, layer, upper):
        if upper:
            if self._upper_fd is None:
                raise RfsError(errno.EIO, "sandbox not open")
            return os.open(layer, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                           dir_fd=self._upper_fd)
        if layer != "efs" or self._lower_fd is None:
            raise FileNotFoundError(errno.ENOENT, "no lower layer")
        return os.dup(self._lower_fd)

    def _walk(self, layer, comps, upper, create=False):
        """Return (parent dir fd, leaf name); caller closes the fd."""
        fd = self._layer_root(layer, upper)
        try:
            for comp in comps[:-1]:
                try:
                    nfd = os.open(comp, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
                except FileNotFoundError:
                    if not create:
                        raise
                    os.mkdir(comp, 0o700, dir_fd=fd)
                    nfd = os.open(comp, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
                os.close(fd)
                fd = nfd
        except BaseException:
            os.close(fd)
            raise
        return fd, comps[-1]

    def _lstat(self, layer, comps, upper):
        try:
            dfd, leaf = self._walk(layer, comps, upper)
        except OSError:
            return None
        try:
            return os.stat(leaf, dir_fd=dfd, follow_symlinks=False)
        except OSError:
            return None
        finally:
            os.close(dfd)

    def _exists_lower(self, layer, comps):
        if (layer, comps) in self.whiteouts:
            return None
        return self._lstat(layer, comps, upper=False)

    def _copy_up(self, layer, comps):
        """Copy a lower regular file into upper (before modifying it)."""
        st = self._exists_lower(layer, comps)
        if st is None or self._lstat(layer, comps, upper=True) is not None:
            return
        if not stat.S_ISREG(st.st_mode):
            raise RfsError(errno.EACCES, "not a regular file")
        if st.st_size > self.max_file_size:
            raise RfsError(errno.EFBIG)
        self._check_total(st.st_size)
        ldfd, leaf = self._walk(layer, comps, upper=False)
        try:
            src = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=ldfd)
        finally:
            os.close(ldfd)
        try:
            udfd, leaf = self._walk(layer, comps, upper=True, create=True)
            try:
                dst = os.open(leaf, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                              0o600, dir_fd=udfd)
            finally:
                os.close(udfd)
            try:
                while True:
                    chunk = os.read(src, 65536)
                    if not chunk:
                        break
                    os.write(dst, chunk)
                    self._account(len(chunk))
            finally:
                os.close(dst)
        finally:
            os.close(src)

    def usage(self, refresh=False):
        """Bytes used in the upper layer (re-walked every 32 mutations)."""
        if self._upper_fd is None:
            return 0
        if self._usage is None or refresh or self._mutations >= 32:
            total = 0
            for root, dirs, files in os.walk(self.upper_path, followlinks=False):
                for name in files:
                    try:
                        total += os.lstat(os.path.join(root, name)).st_size
                    except OSError:
                        pass
            self._usage = total
            self._mutations = 0
        return self._usage

    def _account(self, delta):
        self._mutations += 1
        if self._usage is not None:
            self._usage = max(0, self._usage + delta)

    def _check_total(self, extra):
        if self.usage() + extra > self.max_total:
            raise RfsError(errno.ENOSPC, "sandbox quota")

    # -- handles ---------------------------------------------------------------
    def _new_handle(self, fd, writable, layer, comps):
        if len(self.handles) >= self.MAX_HANDLES:
            os.close(fd)
            raise RfsError(errno.EMFILE)
        h = self.FIRST_HANDLE
        while h in self.handles:
            h += 1
        self.handles[h] = {"fd": fd, "writable": writable, "layer": layer, "comps": comps}
        return h

    def _handle(self, h):
        entry = self.handles.get(h)
        if entry is None:
            raise RfsError(errno.EBADF)
        return entry

    # -- verbs -----------------------------------------------------------------
    def open_file(self, raw_path, cp_flags, create_mode=False):
        layer, comps = self.map_path(raw_path)
        acc = cp_flags & ARM_O_ACCMODE
        writable = acc in (1, 2)
        creat = bool(cp_flags & ARM_O_CREAT) or create_mode
        trunc = bool(cp_flags & ARM_O_TRUNC) or create_mode
        flags = os.O_NOFOLLOW | os.O_CLOEXEC
        if acc == 1:
            flags |= os.O_WRONLY
        elif acc == 2:
            flags |= os.O_RDWR
        else:
            flags |= os.O_RDONLY
        if cp_flags & ARM_O_APPEND:
            flags |= os.O_APPEND
        if creat:
            flags |= os.O_CREAT
            writable = True
            if acc == 0:
                flags = (flags & ~os.O_RDONLY) | os.O_RDWR
        if cp_flags & ARM_O_EXCL and creat:
            flags |= os.O_EXCL
        if trunc and writable:
            flags |= os.O_TRUNC
        upper_st = self._lstat(layer, comps, upper=True)
        if not writable:
            if upper_st is not None:
                dfd, leaf = self._walk(layer, comps, upper=True)
            elif self._exists_lower(layer, comps) is not None:
                dfd, leaf = self._walk(layer, comps, upper=False)
            else:
                raise RfsError(errno.ENOENT)
        else:
            if upper_st is None and not trunc:
                self._copy_up(layer, comps)
            if upper_st is None and (layer, comps) in self.whiteouts and not creat:
                raise RfsError(errno.ENOENT)
            dfd, leaf = self._walk(layer, comps, upper=True, create=creat)
        try:
            fd = os.open(leaf, flags, 0o600, dir_fd=dfd)
        finally:
            os.close(dfd)
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            os.close(fd)
            raise RfsError(errno.EISDIR if stat.S_ISDIR(st.st_mode) else errno.EACCES)
        if writable:
            self.whiteouts.discard((layer, comps))
            if flags & os.O_TRUNC:
                self._usage = None
        return self._new_handle(fd, writable, layer, comps)

    def read(self, h, size):
        entry = self._handle(h)
        return os.read(entry["fd"], min(size, MAX_FILE_READ))

    def write(self, h, data):
        entry = self._handle(h)
        if not entry["writable"]:
            raise RfsError(errno.EBADF)
        fd = entry["fd"]
        pos = os.lseek(fd, 0, os.SEEK_CUR)
        size = os.fstat(fd).st_size
        new_size = max(size, pos + len(data))
        if new_size > self.max_file_size:
            raise RfsError(errno.EFBIG)
        self._check_total(new_size - size)
        n = os.write(fd, data)
        self._account(max(0, pos + n - size))
        return n

    def lseek(self, h, offset, whence):
        entry = self._handle(h)
        if whence not in (0, 1, 2):
            raise RfsError(errno.EINVAL)
        return os.lseek(entry["fd"], offset, whence)

    def close_handle(self, h):
        entry = self.handles.pop(h, None)
        if entry is None:
            raise RfsError(errno.EBADF)
        os.close(entry["fd"])
        return 0

    def put_file(self, raw_path, cp_flags, data):
        h = self.open_file(raw_path, (cp_flags & ~ARM_O_ACCMODE) | 1 | ARM_O_CREAT)
        try:
            return self.write(h, data)
        finally:
            self.close_handle(h)

    def get_file(self, raw_path, size):
        h = self.open_file(raw_path, 0)
        try:
            return self.read(h, size)
        finally:
            self.close_handle(h)

    def rename(self, raw_old, raw_new):
        old_layer, old = self.map_path(raw_old)
        new_layer, new = self.map_path(raw_new)
        if old_layer != new_layer:
            raise RfsError(errno.EXDEV)
        if self._lstat(old_layer, old, upper=True) is None:
            if self._exists_lower(old_layer, old) is None:
                raise RfsError(errno.ENOENT)
            self._copy_up(old_layer, old)
        sfd, sleaf = self._walk(old_layer, old, upper=True)
        try:
            dfd, dleaf = self._walk(new_layer, new, upper=True, create=True)
            try:
                os.rename(sleaf, dleaf, src_dir_fd=sfd, dst_dir_fd=dfd)
                self._usage = None
            finally:
                os.close(dfd)
        finally:
            os.close(sfd)
        if self._exists_lower(old_layer, old) is not None:
            self.whiteouts.add((old_layer, old))
        self.whiteouts.discard((new_layer, new))
        return 0

    def unlink(self, raw_path):
        layer, comps = self.map_path(raw_path)
        found = False
        st = self._lstat(layer, comps, upper=True)
        if st is not None:
            if stat.S_ISDIR(st.st_mode):
                raise RfsError(errno.EISDIR)
            dfd, leaf = self._walk(layer, comps, upper=True)
            try:
                os.unlink(leaf, dir_fd=dfd)
            finally:
                os.close(dfd)
            self._usage = None
            found = True
        if self._exists_lower(layer, comps) is not None:
            self.whiteouts.add((layer, comps))
            found = True
        if not found:
            raise RfsError(errno.ENOENT)
        return 0

    def mkdir(self, raw_path):
        layer, comps = self.map_path(raw_path)
        dfd, leaf = self._walk(layer, comps, upper=True, create=True)
        try:
            os.mkdir(leaf, 0o700, dir_fd=dfd)
        except FileExistsError:
            pass  # stock CheckRfsDirectory tolerates existing directories
        finally:
            os.close(dfd)
        self.whiteouts.discard((layer, comps))
        return 0

    def stat_path(self, raw_path):
        layer, comps = self.map_path(raw_path)
        st = self._lstat(layer, comps, upper=True)
        if st is None:
            st = self._exists_lower(layer, comps)
        if st is None:
            raise RfsError(errno.ENOENT)
        if stat.S_ISLNK(st.st_mode):
            raise RfsError(errno.ELOOP)
        return st

    def stat_handle(self, h):
        return os.fstat(self._handle(h)["fd"])


def _open_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    return fd


def _remove_tree_at(dir_fd, name):
    st = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    if stat.S_ISDIR(st.st_mode):
        sub = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dir_fd)
        try:
            for child in os.listdir(sub):
                _remove_tree_at(sub, child)
        finally:
            os.close(sub)
        os.rmdir(name, dir_fd=dir_fd)
    else:
        os.unlink(name, dir_fd=dir_fd)


def _tm6(ts):
    t = time.localtime(ts)
    return bytes([(t.tm_year - 2000) & 0xFF, t.tm_mon, t.tm_mday, t.tm_hour, t.tm_min, t.tm_sec])


def _file_info(st):
    """32-byte GET_FILE_INFO payload tail (after the header): ret, type, size, ctime, mtime, errno."""
    ftype = 1 if stat.S_ISDIR(st.st_mode) else 2
    return (struct.pack("<iHI", 0, ftype, st.st_size & 0xFFFFFFFF)
            + _tm6(st.st_ctime) + _tm6(st.st_mtime) + struct.pack("<I", 0))


class RfsServer:
    """Dispatch RFS requests; ``handle(frame) -> reply bytes | None`` is pure enough to test."""

    def __init__(self, nv_seed_path, upper_dir, lower_dir=None, max_file_size=8 << 20,
                 max_total=32 << 20):
        self.nv = NvStore(nv_seed_path)
        self.sandbox = Sandbox(upper_dir, lower_dir, max_file_size, max_total)
        self.stats = {"requests": 0, "replies": 0, "errors": 0, "no_reply": 0,
                      "max_nv_read": 0, "max_read_file": 0, "cp_restarts": 0}  # U22: largest sizes asked
        self.last = []  # recent request headers {cmd, id, offset, length, path}

    def open(self):
        self.sandbox.open()
        self.reseed()

    def close(self):
        self.sandbox.close()

    def reseed(self):
        """Called at every CP boot: fresh NV copy, all handles dropped, clean efs upper layer."""
        self.nv.reseed()
        self.sandbox.reset_upper()

    # -- logging ---------------------------------------------------------------
    def _note(self, cmd, rid, offset=None, length=None, path=None):
        entry = {"cmd": CMD_NAMES.get(cmd, "0x%02x" % cmd), "id": rid}
        if offset is not None:
            entry["offset"] = offset
        if length is not None:
            entry["length"] = length
        if path is not None:
            entry["path"] = path.decode("ascii", "backslashreplace")
        self.last.append(entry)
        del self.last[:-64]
        log.info("RFS %s", " ".join("%s=%s" % kv for kv in entry.items()))

    # -- helpers -----------------------------------------------------------------
    @staticmethod
    def _reply(cmd, rid, body):
        return HDR.pack(HDR_LEN + len(body), cmd, rid) + body

    def _ret_errno(self, cmd, rid, ret, err=0):
        return self._reply(cmd, rid, struct.pack("<iI", ret, err))

    @staticmethod
    def _path_at(frame, len_off, path_off, fixed=False):
        if len(frame) < len_off + 4:
            raise RfsError(errno.EINVAL, "truncated")
        plen = struct.unpack_from("<I", frame, len_off)[0]
        if plen > PATH_FIELD:
            raise RfsError(errno.ENAMETOOLONG)
        if len(frame) < path_off + plen:
            raise RfsError(errno.EINVAL, "truncated path")
        return bytes(frame[path_off:path_off + plen])

    # -- dispatch ------------------------------------------------------------------
    def handle(self, frame):
        if len(frame) < HDR_LEN:
            return None
        length, cmd, rid = HDR.unpack_from(frame)
        self.stats["requests"] += 1
        if cmd in NO_REPLY:
            self._note(cmd, rid)
            self.stats["no_reply"] += 1
            return None
        try:
            reply = self._dispatch(cmd, rid, frame)
        except RfsError as exc:
            self.stats["errors"] += 1
            reply = self._error_reply(cmd, rid, exc.errno)
        except OSError as exc:
            self.stats["errors"] += 1
            reply = self._error_reply(cmd, rid, exc.errno or errno.EIO)
        except (struct.error, IndexError, ValueError):
            self.stats["errors"] += 1
            reply = self._error_reply(cmd, rid, errno.EINVAL)
        if reply is not None:
            self.stats["replies"] += 1
        return reply

    def _error_reply(self, cmd, rid, err):
        e = linux_errno(err)
        if cmd in (NV_READ_ITEM, NV_WRITE_ITEM):
            return self._reply(cmd, rid, struct.pack("<BII", 0, 0, 0))
        if cmd in (NV_WRITE_ALL_ITEM, NV_BUFFER_MESSAGE):
            return self._reply(cmd, rid, struct.pack("<BIH", 0, 0, 0))
        if cmd in (READ_FILE, GET_FILE):
            return self._reply(cmd, rid, struct.pack("<II", 0, e))
        if cmd in (LSEEK_FILE, PUT_FILE):
            return self._reply(cmd, rid, struct.pack("<IiI", 0, -1, e))
        if cmd in (GET_FILE_INFO, GET_HANDLE_INFO):
            return self._reply(cmd, rid, struct.pack("<iHI", -1, 0, 0) + bytes(12) + struct.pack("<I", e))
        return self._ret_errno(cmd, rid, -1, e)

    def _dispatch(self, cmd, rid, f):
        if cmd == NV_READ_ITEM:
            off, size = struct.unpack_from("<II", f, 6)
            self._note(cmd, rid, off, size)
            self.stats["max_nv_read"] = max(self.stats["max_nv_read"], size)
            data = self.nv.read(off, size)
            if data is None:
                return self._reply(cmd, rid, struct.pack("<BII", 0, off, 0))
            return self._reply(cmd, rid, struct.pack("<BII", 1, off, len(data)) + data)
        if cmd in (NV_WRITE_ITEM, NV_WRITE_ALL_ITEM):
            off, size = struct.unpack_from("<II", f, 6)
            data = bytes(f[14:14 + min(size, MAX_NV_IO)])
            self._note(cmd, rid, off, len(data))
            ok = self.nv.write(cmd, off, data)
            if cmd == NV_WRITE_ITEM:
                return self._reply(cmd, rid, struct.pack("<BII", 1 if ok else 0, off, len(data) if ok else 0))
            return self._reply(cmd, rid, struct.pack("<BIH", 1 if ok else 0, off, (len(data) if ok else 0) & 0xFFFF))
        if cmd == NV_BUFFER_MESSAGE:
            mode, off, size = struct.unpack_from("<BII", f, 6)
            self._note(cmd, rid, off, size)
            self.nv.buffer_mode = mode == 1
            ok = self.nv.available
            return self._reply(cmd, rid, struct.pack("<BIH", 1 if ok else 0, off, size & 0xFFFF))
        if cmd == NV_RESTORE:
            self._note(cmd, rid)
            ok = self.nv.reseed()
            return self._ret_errno(cmd, rid, 0 if ok else -1, 0 if ok else linux_errno(errno.ENOENT))
        if cmd == READ_FILE:
            h, size = struct.unpack_from("<iI", f, 6)
            self._note(cmd, rid, None, size)
            self.stats["max_read_file"] = max(self.stats["max_read_file"], size)
            data = self.sandbox.read(h, size)
            err = 0 if data else 0
            return self._reply(cmd, rid, struct.pack("<II", len(data), err) + data)
        if cmd == WRITE_FILE:
            h, size = struct.unpack_from("<iI", f, 6)
            data = bytes(f[14:14 + size])
            self._note(cmd, rid, None, len(data))
            return self._ret_errno(cmd, rid, self.sandbox.write(h, data), 0)
        if cmd == LSEEK_FILE:
            h, off, whence = struct.unpack_from("<iiI", f, 6)
            self._note(cmd, rid, off, None)
            pos = self.sandbox.lseek(h, off, whence)
            return self._reply(cmd, rid, struct.pack("<IiI", 0, pos, 0))
        if cmd == CLOSE_FILE:
            (h,) = struct.unpack_from("<i", f, 6)
            self._note(cmd, rid)
            return self._ret_errno(cmd, rid, self.sandbox.close_handle(h), 0)
        if cmd == PUT_FILE:
            flags = struct.unpack_from("<I", f, 6)[0]
            path = self._path_at(f, 0x0A, 0x0E)
            dlen = struct.unpack_from("<I", f, 0x40E)[0]
            data = bytes(f[0x412:0x412 + dlen])
            self._note(cmd, rid, None, len(data), path)
            n = self.sandbox.put_file(path, flags, data)
            return self._reply(cmd, rid, struct.pack("<IiI", 0, n, 0))
        if cmd == GET_FILE:
            path = self._path_at(f, 0x06, 0x0A)
            size = struct.unpack_from("<I", f, 0x40A)[0]
            self._note(cmd, rid, None, size, path)
            data = self.sandbox.get_file(path, size)
            return self._reply(cmd, rid, struct.pack("<II", len(data), 0) + data)
        if cmd == RENAME_FILE:
            old = self._path_at(f, 0x06, 0x0A)
            new = self._path_at(f, 0x40A, 0x40E)
            self._note(cmd, rid, None, None, old + b" -> " + new)
            return self._ret_errno(cmd, rid, self.sandbox.rename(old, new), 0)
        if cmd == GET_FILE_INFO:
            path = self._path_at(f, 0x06, 0x0A)
            self._note(cmd, rid, None, None, path)
            return self._reply(cmd, rid, _file_info(self.sandbox.stat_path(path)))
        if cmd == UNLINK_FILE:
            path = self._path_at(f, 0x06, 0x0A)
            self._note(cmd, rid, None, None, path)
            return self._ret_errno(cmd, rid, self.sandbox.unlink(path), 0)
        if cmd == MAKE_DIR:
            path = self._path_at(f, 0x06, 0x0A)
            self._note(cmd, rid, None, None, path)
            return self._ret_errno(cmd, rid, self.sandbox.mkdir(path), 0)
        if cmd == OPEN_FILE:
            flags = struct.unpack_from("<I", f, 6)[0]
            path = self._path_at(f, 0x0A, 0x0E)
            self._note(cmd, rid, None, None, path)
            return self._ret_errno(cmd, rid, self.sandbox.open_file(path, flags), 0)
        if cmd == CREATE_FILE:
            path = self._path_at(f, 0x06, 0x0A)
            self._note(cmd, rid, None, None, path)
            return self._ret_errno(cmd, rid, self.sandbox.open_file(path, 2 | ARM_O_CREAT, create_mode=True), 0)
        if cmd == GET_HANDLE_INFO:
            (h,) = struct.unpack_from("<i", f, 6)
            self._note(cmd, rid)
            return self._reply(cmd, rid, _file_info(self.sandbox.stat_handle(h)))
        raise RfsError(errno.ENOSYS)


class RfsChannel:
    """Owns the RFS fd on one loop: reassembles requests, writes each reply with a short-write loop."""

    def __init__(self, loop, fd, server, payload_log=None, on_hup=None, eof_is_hup=None, writer=None):
        from .ipc import eof_means_hangup
        self.loop = loop
        self.fd = fd
        self.server = server
        self.framer = RfsFramer()
        self.payload_log = payload_log
        self.on_hup = on_hup
        self.eof_is_hup = eof_means_hangup(fd) if eof_is_hup is None else eof_is_hup
        self.writer = writer or os.write
        self.paused = False

    def start(self):
        self.loop.add_reader(self.fd, self._on_ready)

    def close(self):
        self.loop.remove_reader(self.fd)

    def pause(self):
        self.paused = True
        self.loop.remove_reader(self.fd)

    def resume(self):
        self.framer.reset()
        if self.paused:
            self.paused = False
            self.loop.add_reader(self.fd, self._on_ready)

    def drain(self, limit=4096):
        """Drop requests queued by the previous CP session."""
        dropped = 0
        was_blocking = os.get_blocking(self.fd)
        try:
            os.set_blocking(self.fd, False)
            for _ in range(limit):
                try:
                    data = os.read(self.fd, MAX_FRAME + 0x1000)
                except (BlockingIOError, InterruptedError, OSError):
                    break
                if not data:
                    break
                dropped += len(data)
        finally:
            try:
                os.set_blocking(self.fd, was_blocking)
            except OSError:
                pass
        self.framer.reset()
        return dropped

    def _on_ready(self, flags):
        if flags & READABLE:
            try:
                data = os.read(self.fd, MAX_FRAME + 0x1000)
            except BlockingIOError:
                return
            except OSError as exc:
                log.warning("RFS read failed: %s", exc)
                data = b""
                flags |= ERROR
            if data:
                for frame in self.framer.feed(data):
                    if self.payload_log is not None:
                        self.payload_log.write("RX", "rfs", frame)
                    reply = self.server.handle(frame)
                    if reply is not None:
                        self._write(reply)
                return
            if data == b"" and self.eof_is_hup:
                flags |= HUP  # EOF on a socket/pty peer; the real device returns 0 when idle
        if flags & (HUP | ERROR):
            if self.on_hup is not None:
                self.on_hup(flags)
            else:
                self.pause()

    def _write(self, reply):
        from .ipc import write_all
        if self.payload_log is not None:
            self.payload_log.write("TX", "rfs", reply)
        try:
            write_all(self.fd, reply, self.writer)
        except OSError as exc:
            log.warning("RFS reply write failed: %s", exc)


class RfsService:
    """RFS server with its own fd and its own loop.

    ``threaded=True`` (shannond default) runs it on a private SelectorLoop in a
    daemon thread, so big NV replies and short-write retries never stall the
    FMT side.  ``run()`` runs it in the calling thread (``shannon-rfsd``, the
    separate-process form SYNTHESIS v2 D6 recommends).  ``cp_restarted()`` is
    thread-safe: it drops the previous session's queued requests and handles
    and re-seeds the NV copy.
    """

    def __init__(self, server, fd, payload_log=None, writer=None, cp_state_path=None):
        from .loop import SelectorLoop
        self.server = server
        self.fd = fd
        self.loop = SelectorLoop()
        self.loop.enable_threadsafe()
        self.channel = RfsChannel(self.loop, fd, server, payload_log=payload_log, writer=writer,
                                  on_hup=self._on_hup)
        self.cp_state_path = cp_state_path
        self._session = None
        self._thread = None

    @property
    def stats(self):
        return dict(self.server.stats)

    def _on_hup(self, flags):
        # umts_rfs0 does not raise POLLHUP on a CP crash; EOF here means a test peer went away.
        self.channel.pause()

    def _restart(self):
        dropped = self.channel.drain()
        self.server.reseed()
        self.server.stats["cp_restarts"] += 1
        self.channel.resume()
        log.info("RFS: CP restart, %d queued bytes dropped, NV re-seeded, handles closed", dropped)

    def cp_restarted(self):
        if self._thread is not None and self._thread.is_alive():
            self.loop.call_soon_threadsafe(self._restart)
        else:
            self._restart()

    def _watch_cp_state(self):
        from .cpstate import read_cp_state
        session, state = read_cp_state(self.cp_state_path)
        if session is not None:
            if self._session is not None and session != self._session:
                log.info("RFS: loader session %s -> %s", self._session, session)
                self._restart()
            self._session = session
        self.loop.call_later(1.0, self._watch_cp_state)

    def start(self, threaded=True):
        import threading
        self.server.open()
        self.channel.start()
        if self.cp_state_path:
            self.loop.call_soon(self._watch_cp_state)
        if threaded:
            self._thread = threading.Thread(target=self.loop.run, name="shannond-rfs", daemon=True)
            self._thread.start()

    def run(self):
        self.start(threaded=False)
        self.loop.run()

    def stop(self):
        if self._thread is not None and self._thread.is_alive():
            self.loop.call_soon_threadsafe(self.loop.stop)
            self._thread.join(2.0)
        else:
            self.loop.stop()
        self.channel.close()
        self.server.close()
        self.loop.close()


def main(argv=None):
    """shannon-rfsd: the RFS server as a separate process (SYNTHESIS v2 D6)."""
    import argparse
    import signal
    import sys
    p = argparse.ArgumentParser(prog="shannon-rfsd", description="RFS server for umts_rfs0 (observe mode)")
    p.add_argument("--rfs", default="/dev/umts_rfs0")
    p.add_argument("--nv-seed", default="/var/lib/shannon/nv/nv_data.bin")
    p.add_argument("--efs-lower", default="/var/lib/shannon/efs-root")
    p.add_argument("--rfs-upper", default="/run/shannon/rfs")
    p.add_argument("--cp-state", default="/run/shannon/cp-state",
                   help="loader session file; a new session re-seeds the sandbox")
    p.add_argument("--log-payload", metavar="DIR")
    p.add_argument("--log-level", default="info", choices=("debug", "info", "warning", "error"))
    args = p.parse_args(argv)
    logging.basicConfig(level=getattr(logging, args.log_level.upper()), stream=sys.stderr,
                        format="%(levelname)s %(name)s: %(message)s")
    payload_log = None
    if args.log_payload:
        from .ipc import PayloadLog
        payload_log = PayloadLog(args.log_payload, "rfs")
    fd = os.open(args.rfs, os.O_RDWR | os.O_NOCTTY | os.O_CLOEXEC)
    server = RfsServer(None if args.nv_seed == "none" else args.nv_seed, args.rfs_upper, args.efs_lower or None)
    service = RfsService(server, fd, payload_log=payload_log, cp_state_path=args.cp_state)
    service.loop.add_signal_handler(signal.SIGTERM, service.loop.stop)
    service.loop.add_signal_handler(signal.SIGINT, service.loop.stop)
    try:
        service.run()
    finally:
        service.stop()
        os.close(fd)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
