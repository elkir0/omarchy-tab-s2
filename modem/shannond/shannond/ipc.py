# SPDX-License-Identifier: GPL-2.0-or-later
"""Samsung IPC 4.1 FMT framing for /dev/umts_ipc0.

Header (7 bytes, little-endian): ``{u16 len; u8 mseq; u8 aseq; u8 main; u8 sub;
u8 type}``; ``len`` includes the header.  The kernel adds and strips the SIPC5
link header, so userspace writes exactly one frame per ``write()`` and the
real device returns one frame per ``read()`` (0 when empty after ~100 ms).

``FmtChannel`` owns the file descriptor: it reads frames (tolerating a byte
stream such as a pty when ``stream=True``), writes one frame per call, and
logs header tuples only.  Payload bytes are never logged here; the optional
``PayloadLog`` (``--log-payload DIR``) receives them explicitly.

Sequencing, request queues and acknowledgement handling live in
``IpcClient``: AP ``mseq`` increments per frame (1..254), ``aseq`` = 0; a CP
RESP or GEN_PHONE_RES carries ``aseq`` = the request's ``mseq``.
"""

import errno
import logging
import os
import struct
from dataclasses import dataclass, field

from . import defs
from .loop import HUP, ERROR, READABLE, Op, OpError, OpTimeout

log = logging.getLogger("shannond.ipc")
frame_log = logging.getLogger("shannond.ipc.frames")  # header tuples only, INFO by default

HDR = struct.Struct("<HBBBBB")
HDR_LEN = HDR.size  # 7
MAX_FRAME = 0xFFFF
READ_SIZE = 0x10000


class IpcError(OpError):
    """A request failed (GEN_PHONE_RES error, write error, unexpected reply)."""

    def __init__(self, message, code=None, frame=None):
        super().__init__(message)
        self.code = code
        self.frame = frame


@dataclass(frozen=True)
class Frame:
    mseq: int
    aseq: int
    main: int
    sub: int
    type: int
    payload: bytes = b""

    @property
    def length(self):
        return HDR_LEN + len(self.payload)

    @property
    def command(self):
        return (self.main << 8) | self.sub

    def encode(self):
        if self.length > MAX_FRAME:
            raise ValueError("FMT frame too long (%d)" % self.length)
        return HDR.pack(self.length, self.mseq, self.aseq, self.main, self.sub, self.type) + bytes(self.payload)

    @classmethod
    def decode(cls, data):
        if len(data) < HDR_LEN:
            raise ValueError("short FMT frame (%d bytes)" % len(data))
        length, mseq, aseq, main, sub, typ = HDR.unpack_from(data)
        if length < HDR_LEN or length > len(data):
            raise ValueError("bad FMT length %d for %d bytes" % (length, len(data)))
        return cls(mseq, aseq, main, sub, typ, bytes(data[HDR_LEN:length]))

    def header_tuple(self):
        return {"len": self.length, "mseq": self.mseq, "aseq": self.aseq,
                "main": self.main, "sub": self.sub, "type": self.type}

    def describe(self, direction):
        """Header-only log line (never payload)."""
        return "%s len=%d mseq=%d aseq=%d main=0x%02x sub=0x%02x type=0x%02x (%s %s)" % (
            direction, self.length, self.mseq, self.aseq, self.main, self.sub, self.type,
            defs.command_name(self.main, self.sub), defs.type_name(self.type, direction == "TX"))


class FrameSplitter:
    """Split a read buffer into FMT frames.

    datagram mode (real device): each read holds whole frames; a trailing
    fragment is dropped (logged).  stream mode (pty / stream socket): keeps
    the fragment for the next read.
    """

    def __init__(self, stream=False):
        self.stream = stream
        self._buf = bytearray()
        self.dropped = 0

    def feed(self, data):
        self._buf += data
        frames = []
        while len(self._buf) >= HDR_LEN:
            length = self._buf[0] | (self._buf[1] << 8)
            if length < HDR_LEN:
                log.warning("FMT: invalid length %d, dropping %d buffered bytes", length, len(self._buf))
                self.dropped += len(self._buf)
                self._buf.clear()
                break
            if len(self._buf) < length:
                break
            frames.append(Frame.decode(bytes(self._buf[:length])))
            del self._buf[:length]
        if self._buf and not self.stream:
            log.warning("FMT: dropping %d-byte fragment (datagram mode)", len(self._buf))
            self.dropped += len(self._buf)
            self._buf.clear()
        return frames


class PayloadLog:
    """Explicit payload logger (``--log-payload DIR``); files are 0600."""

    def __init__(self, directory, prefix):
        import time
        os.makedirs(directory, mode=0o700, exist_ok=True)
        name = "%s-%s-%d.log" % (prefix, time.strftime("%Y%m%d-%H%M%S"), os.getpid())
        path = os.path.join(directory, name)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        self._f = os.fdopen(fd, "a", buffering=1)
        self.path = path
        log.warning("payload logging enabled: %s (contains identifiers, keep it private)", path)

    def write(self, direction, header, payload, limit=4096):
        import time
        data = bytes(payload[:limit])
        more = "" if len(payload) <= limit else " (+%d bytes)" % (len(payload) - limit)
        self._f.write("%.3f %s %s %s%s\n" % (time.time(), direction, header, data.hex(), more))

    def close(self):
        try:
            self._f.close()
        except OSError:
            pass


class FmtChannel:
    """Owns the FMT fd: reads frames, writes one frame per write()."""

    def __init__(self, loop, fd, on_frame, on_hup=None, stream=None, payload_log=None, name="ipc",
                 eof_is_hup=None):
        self.loop = loop
        self.fd = fd
        self.on_frame = on_frame
        self.on_hup = on_hup
        self.name = name
        if stream is None:
            stream = is_stream_fd(fd)
        self.splitter = FrameSplitter(stream=stream)
        self.eof_is_hup = eof_means_hangup(fd) if eof_is_hup is None else eof_is_hup
        self.writer = os.write  # tests swap in an SBD-truncating writer
        self.payload_log = payload_log
        self.rx_count = 0
        self.tx_count = 0
        self.paused = False

    def start(self):
        self.loop.add_reader(self.fd, self._on_ready)

    def pause(self):
        self.paused = True
        self.loop.remove_reader(self.fd)

    def resume(self):
        if self.paused:
            self.paused = False
            self.loop.add_reader(self.fd, self._on_ready)

    def close(self):
        self.loop.remove_reader(self.fd)

    def _on_ready(self, flags):
        if flags & READABLE:
            try:
                data = os.read(self.fd, READ_SIZE)
            except BlockingIOError:
                data = None
            except OSError as exc:
                log.warning("%s: read failed: %s", self.name, exc)
                data = b""
                flags |= ERROR
            if data:
                for frame in self.splitter.feed(data):
                    self.rx_count += 1
                    frame_log.info(frame.describe("RX"))
                    if self.payload_log is not None:
                        self.payload_log.write("RX", frame.describe("RX"), frame.payload)
                    self.on_frame(frame)
                return
            if data == b"" and self.eof_is_hup:
                # EOF on a socket/pty peer; the real device returns 0 when idle
                flags |= HUP
        if flags & (HUP | ERROR):
            log.warning("%s: hang-up/error on fd (flags=%d)", self.name, flags)
            if self.on_hup is not None:
                self.on_hup(flags)

    def write_frame(self, frame):
        data = frame.encode()
        frame_log.info(frame.describe("TX"))
        if self.payload_log is not None:
            self.payload_log.write("TX", frame.describe("TX"), frame.payload)
        written = write_all(self.fd, data, self.writer)
        self.tx_count += 1
        return written

    def drain(self, limit=10000):
        """Discard everything queued on the fd (restart contract step 3)."""
        dropped = 0
        was_blocking = os.get_blocking(self.fd)
        try:
            os.set_blocking(self.fd, False)
            for _ in range(limit):
                try:
                    data = os.read(self.fd, READ_SIZE)
                except (BlockingIOError, InterruptedError):
                    break
                except OSError:
                    break
                if not data:
                    break
                dropped += 1
        finally:
            try:
                os.set_blocking(self.fd, was_blocking)
            except OSError:
                pass
        self.splitter = FrameSplitter(stream=self.splitter.stream)
        return dropped


def _fd_kind(fd):
    import socket
    import stat as _stat
    mode = os.fstat(fd).st_mode
    if _stat.S_ISSOCK(mode):
        try:
            sock = socket.socket(fileno=os.dup(fd))
        except OSError:
            return "stream-socket"
        try:
            return "dgram-socket" if sock.type in (socket.SOCK_DGRAM, socket.SOCK_SEQPACKET) else "stream-socket"
        finally:
            sock.close()
    if os.isatty(fd):
        return "tty"
    if _stat.S_ISCHR(mode):
        return "device"
    return "other"


def is_stream_fd(fd):
    """Byte-stream transports (pty, stream socket, pipe) need FMT reassembly."""
    return _fd_kind(fd) in ("tty", "stream-socket", "other")


def eof_means_hangup(fd):
    """A 0-byte read is EOF on sockets/ptys/pipes, but "idle" on the modem device."""
    return _fd_kind(fd) != "device"


def write_all(fd, data, writer=os.write, max_wait=5.0):
    """Write a whole frame, looping like the stock IoChannel::Write.

    The kernel truncates every write() on umts_ipc0/umts_rfs0 to the 2048-byte
    SBD uplink slot and returns the short count, and returns -EBUSY when 1024
    skbs are queued (SYNTHESIS v2 §2.9, §2.12, C54).  Loop over short writes;
    retry EINTR, EAGAIN and EBUSY with 10 ms pauses, up to ``max_wait`` s.
    """
    import select
    import time
    view = memoryview(bytes(data))
    total = 0
    waited = 0.0
    while total < len(view):
        try:
            n = writer(fd, view[total:])
        except InterruptedError:
            continue
        except BlockingIOError:
            n = None
        except OSError as exc:
            if exc.errno != errno.EBUSY:
                raise
            n = None
        if n is None:
            if waited >= max_wait:
                raise OSError(errno.EAGAIN, "device busy for %.1f s" % waited)
            try:
                select.select([], [fd], [], 0.01)
            except (OSError, ValueError):
                pass
            time.sleep(0.01)
            waited += 0.01
            continue
        if n <= 0:
            raise OSError(errno.EIO, "write() returned %d" % n)
        total += n
    return total


_write_all_once = write_all  # backward-compatible name


@dataclass
class GenPhoneRes:
    group: int
    index: int
    type: int
    code: int

    @property
    def ok(self):
        return self.code == defs.GEN_OK


@dataclass
class Reply:
    """Outcome of a request: the CP's frame and, for GEN, the decoded result."""
    request: Frame
    frame: Frame = None
    gen: GenPhoneRes = None

    @property
    def ok(self):
        if self.gen is not None:
            return self.gen.ok
        return self.frame is not None


@dataclass
class _Pending:
    frame: Frame
    op: Op
    expect_resp: bool
    timer: object = None
    extra: dict = field(default_factory=dict)


class IpcClient:
    """Sequencing, request/answer matching, timeouts and dispatch."""

    def __init__(self, loop, channel_factory=None, default_timeout=10.0):
        self.loop = loop
        self.channel = None
        self._mseq = 0
        self._pending = {}
        self.default_timeout = default_timeout
        self.handlers = []  # callables(frame) for every received frame
        self.on_tx = None   # optional hook(frame) after each write

    def attach(self, channel):
        self.channel = channel

    def reset_sequence(self):
        """Restart contract step 4: the next request uses mseq 1."""
        self._mseq = 0

    def next_mseq(self):
        self._mseq = self._mseq % 254 + 1  # 1..254: 0 is "no request", 0xFF avoided
        while self._mseq in self._pending:
            self._mseq = self._mseq % 254 + 1
        return self._mseq

    def send(self, main, sub, typ, payload=b"", expect=None, timeout=None, name=None):
        """Send a frame; return an Op resolving to a ``Reply``.

        expect: ``"gen"`` (EXEC/SET: GEN_PHONE_RES or a RESP with our aseq),
        ``"resp"`` (GET, or EXEC answered by a RESP such as SMS_SEND_MSG: a GEN
        error aborts, a GEN OK keeps waiting), ``None`` (CFRM/EVENT: no answer).
        A GEN error resolves the Op with an ``IpcError`` carrying ``code``.
        """
        if expect is None and typ in (defs.TYPE_EXEC, defs.TYPE_SET):
            expect = "gen"
        elif expect is None and typ == defs.TYPE_GET:
            expect = "resp"
        name = name or defs.command_name(main, sub)
        op = Op(name)
        if self.channel is None:
            op.set_exception(IpcError("IPC channel not open"))
            return op
        frame = Frame(self.next_mseq(), 0, main, sub, typ, bytes(payload))
        try:
            self.channel.write_frame(frame)
        except OSError as exc:
            log.warning("TX %s failed: %s", name, exc)
            op.set_exception(IpcError("write failed: %s" % exc))
            return op
        if self.on_tx is not None:
            self.on_tx(frame)
        if expect not in ("gen", "resp"):
            op.set_result(Reply(frame))
            return op
        pending = _Pending(frame, op, expect == "resp")
        timeout = self.default_timeout if timeout is None else timeout
        pending.timer = self.loop.call_later(timeout, self._expire, frame.mseq, op)
        self._pending[frame.mseq] = pending
        return op

    def _expire(self, mseq, op):
        pending = self._pending.get(mseq)
        if pending is not None and pending.op is op:
            del self._pending[mseq]
            log.info("request %s mseq=%d timed out", op.name, mseq)
            op.set_exception(OpTimeout("%s: no answer" % op.name))

    def fail_all(self, reason):
        pending, self._pending = self._pending, {}
        for p in pending.values():
            if p.timer is not None:
                p.timer.cancel()
            p.op.set_exception(IpcError(reason))

    @property
    def pending_count(self):
        return len(self._pending)

    def complete_oldest(self, main, sub, frame):
        """Resolve the oldest pending request for main/sub with ``frame``.

        Used when the CP answers in NOTI form (aseq 0), e.g. SMS_SEND_MSG.
        Returns True if a request was completed.
        """
        for mseq, p in sorted(self._pending.items(), key=lambda kv: kv[1].timer.when if kv[1].timer else 0):
            if (p.frame.main, p.frame.sub) == (main, sub):
                self._finish(mseq, Reply(p.frame, frame=frame))
                return True
        return False

    def on_frame(self, frame):
        """Entry point for every received frame."""
        if frame.main == defs.GEN and frame.sub == defs.GEN_PHONE_RES_SUB:
            self._on_gen(frame)
        elif frame.type == defs.TYPE_RESP and frame.aseq:
            p = self._pending.get(frame.aseq)
            if p is not None and (p.frame.main, p.frame.sub) == (frame.main, frame.sub):
                self._finish(frame.aseq, Reply(p.frame, frame=frame))
            elif p is not None:
                log.warning("RESP main=0x%02x sub=0x%02x aseq=%d does not match request %s",
                            frame.main, frame.sub, frame.aseq, p.op.name)
        for handler in list(self.handlers):
            try:
                handler(frame)
            except Exception:
                log.exception("handler failed for %s", frame.describe("RX"))

    def _on_gen(self, frame):
        if len(frame.payload) < 5:
            log.warning("short GEN_PHONE_RES (%d bytes)", len(frame.payload))
            return
        group, index, typ, code = struct.unpack_from("<BBBH", frame.payload)
        gen = GenPhoneRes(group, index, typ, code)
        p = self._pending.get(frame.aseq)
        if p is None:
            log.info("GEN_PHONE_RES for unknown aseq=%d (0x%02x%02x code=0x%04x)", frame.aseq, group, index, code)
            return
        if (p.frame.main, p.frame.sub) != (group, index):
            log.warning("GEN_PHONE_RES aseq=%d names 0x%02x%02x, request was %s",
                        frame.aseq, group, index, p.op.name)
        if gen.ok and p.expect_resp:
            return  # e.g. SMS_SEND_MSG: OK GEN first, the RESP follows
        if gen.ok:
            self._finish(frame.aseq, Reply(p.frame, frame=frame, gen=gen))
        else:
            self._finish(frame.aseq, None,
                         IpcError("%s failed: GEN code 0x%04x" % (p.op.name, code), code=code, frame=frame))

    def _finish(self, mseq, reply, exc=None):
        p = self._pending.pop(mseq, None)
        if p is None:
            return
        if p.timer is not None:
            p.timer.cancel()
        if exc is not None:
            p.op.set_exception(exc)
        else:
            p.op.set_result(reply)
