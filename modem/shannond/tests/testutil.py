# SPDX-License-Identifier: GPL-2.0-or-later
"""Shared helpers for the shannond tests (all offline, on mocks)."""

import logging
import os
import socket
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)
if HERE not in sys.path:
    sys.path.insert(0, HERE)

logging.getLogger("shannond").setLevel(os.environ.get("SHANNOND_TEST_LOG", "CRITICAL"))

try:
    from shannond import sms_pdu  # noqa: F401
    HAVE_SMS_PDU = True
except ImportError:  # pragma: no cover - module delivered separately
    HAVE_SMS_PDU = False


def dgram_pair():
    """AF_UNIX datagram pair: one frame per read, like /dev/umts_ipc0."""
    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
    for s in (a, b):
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 16)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 18)
        except OSError:
            pass
    return a, b


def stream_pair():
    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    for s in (a, b):
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
        except OSError:
            pass
    return a, b


class Harness:
    """Core + fake modem wired with socketpairs on one SelectorLoop."""

    def __init__(self, passive=False, rfs=True, fake_kwargs=None, config=None, netcfg=None, nv_bytes=None,
                 sbd=False, cp_state=False):
        from shannond.core import CoreConfig, ModemCore
        from shannond.loop import SelectorLoop
        from fake_modem import FakeModem
        self.tmp = tempfile.TemporaryDirectory(prefix="shannond-test-")
        self.loop = SelectorLoop()
        self.ipc_ap, self.ipc_cp = dgram_pair()
        self.rfs_ap = self.rfs_cp = None
        rfs_server = None
        if rfs:
            from shannond.rfs import RfsServer
            self.rfs_ap, self.rfs_cp = stream_pair()
            nv_path = os.path.join(self.tmp.name, "nv_data.bin")
            with open(nv_path, "wb") as f:
                f.write(nv_bytes if nv_bytes is not None else bytes(range(256)) * 16)
            rfs_server = RfsServer(nv_path, os.path.join(self.tmp.name, "upper"))
        self.config = config or CoreConfig(request_timeout=2.0, clock_fallback_s=0.2, dial_id_timeout=1.0,
                                           data_timeout=2.0, data_down_timeout=0.5, recovery_interval=0.05,
                                           cp_state_poll=0.02, resync_delay=0.02)
        self.fake = FakeModem(self.loop, self.ipc_cp.fileno(), self.rfs_cp.fileno() if rfs else None,
                              **(fake_kwargs or {}))
        self.cp_state_path = None
        if cp_state:
            self.cp_state_path = os.path.join(self.tmp.name, "cp-state")
            self.set_cp_state(1, "online")
        self.core = ModemCore(self.loop, ipc_fd=self.ipc_ap.fileno(),
                              rfs_fd=self.rfs_ap.fileno() if rfs else None, passive=passive,
                              rfs_server=rfs_server, netcfg=netcfg, config=self.config,
                              writer=self.fake.sbd if sbd else None, cp_state_path=self.cp_state_path)
        self.events = []
        self.core.subscribe(lambda ev, data: self.events.append((ev, data, len(self.fake.rx))))
        self.core.start()

    def set_cp_state(self, session, state):
        tmp = self.cp_state_path + ".tmp"
        with open(tmp, "w") as f:
            f.write("session=%d state=%s\n" % (session, state))
        os.replace(tmp, self.cp_state_path)

    def run_until(self, pred, timeout=3.0):
        return self.loop.run_until(pred, timeout)

    def run_for(self, seconds):
        self.loop.run_for(seconds)

    def call(self, method, *args, timeout=3.0, **kw):
        """Invoke a callback-style core command and run the loop until done."""
        box = []
        method(*args, done=lambda ok, res: box.append((ok, res)), **kw)
        self.run_until(lambda: box, timeout)
        if not box:
            raise AssertionError("command did not complete")
        return box[0]

    def boot(self):
        self.fake.boot()
        self.run_until(lambda: self.fake.frames(0x04, 0x07, 0x03) and self.fake.frames(0x0A, 0x23, 0x04))

    def events_of(self, name):
        return [d for ev, d, _ in self.events if ev == name]

    def close(self):
        try:
            self.core.stop()
        except Exception:
            pass
        for s in (self.ipc_ap, self.ipc_cp, self.rfs_ap, self.rfs_cp):
            if s is not None:
                try:
                    s.close()
                except OSError:
                    pass
        self.tmp.cleanup()
