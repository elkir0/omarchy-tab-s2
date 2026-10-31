# SPDX-License-Identifier: GPL-2.0-or-later
"""Control socket + shannonctl tests, against the FAKE modem (mock)."""

import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest

import testutil
from testutil import Harness
from shannond.control import ControlServer, redact
from shannond.ctl import Connection

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


class ControlTest(unittest.TestCase):
    def setUp(self):
        self.h = Harness()
        self.addCleanup(self.h.close)
        self.sock_dir = tempfile.mkdtemp(prefix="shc-", dir="/tmp")  # short path for AF_UNIX
        self.addCleanup(shutil.rmtree, self.sock_dir, True)
        self.path = os.path.join(self.sock_dir, "control")
        self.server = ControlServer(self.h.loop, self.h.core, self.path)
        self.server.start()
        self.addCleanup(self.server.stop)
        self.h.boot()

    def client(self, fn):
        """Run fn(conn) in a thread while the loop runs here."""
        box = {}

        def work():
            conn = Connection(self.path, timeout=5)
            try:
                box["result"] = fn(conn)
            except Exception as exc:  # surfaced below
                box["error"] = exc
            finally:
                conn.close()
        t = threading.Thread(target=work)
        t.start()
        self.h.run_until(lambda: not t.is_alive(), timeout=10)
        t.join(1)
        if "error" in box:
            raise box["error"]
        return box["result"]

    def test_socket_mode(self):
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o660)

    def test_status_redacted_by_default(self):
        self.h.call(self.h.core.radio_on)
        self.h.run_until(lambda: self.h.core.state["reg"]["mcc"])
        r = self.client(lambda c: c.request("status"))
        self.assertTrue(r["ok"])
        self.assertEqual(r["result"]["cp"], "online")
        self.assertEqual(r["result"]["reg"]["mcc"], "<redacted>")
        r = self.client(lambda c: c.request("status", {"stats": True}, identifiers=True))
        self.assertEqual(r["result"]["reg"]["mcc"], "001")
        self.assertIn("ipc_tx", r["result"]["stats"])

    def test_commands_and_errors(self):
        import logging
        level = logging.getLogger("shannond").level
        self.addCleanup(logging.getLogger("shannond").setLevel, level)

        def script(c):
            out = {}
            out["radio"] = c.request("radio", {"on": True})
            out["dial112"] = c.request("call-dial", {"number": "112"})
            out["bad"] = c.request("nope")
            out["missing"] = c.request("sms-send", {"number": "+447700900123"})
            out["level"] = c.request("log-level", {"level": "debug"})
            out["calls"] = c.request("call-list")
            c.sock.sendall(b"not json\n")
            out["garbage"] = c.read()
            return out
        out = self.client(script)
        self.assertTrue(out["radio"]["ok"])
        self.assertFalse(out["dial112"]["ok"])
        self.assertIn("emergency", out["dial112"]["error"])
        self.assertIn("unknown command", out["bad"]["error"])
        self.assertIn("bad arguments", out["missing"]["error"])
        self.assertTrue(out["level"]["ok"])
        self.assertEqual(out["calls"]["result"], [])
        self.assertFalse(out["garbage"]["ok"])

    def test_subscribe_streams_events(self):
        def script(c):
            r = c.request("subscribe")
            first = c.read()
            c2 = Connection(self.path, timeout=5)
            c2.request("call-dial", {"number": "+447700900123"})
            c2.close()
            events = []
            deadline = time.time() + 5
            while time.time() < deadline and not any(e.get("event") == "audio" for e in events):
                events.append(c.read())
            return r, first, events
        r, first, events = self.client(script)
        self.assertTrue(r["ok"])
        self.assertEqual(first["event"], "state")
        calls = [e["data"] for e in events if e.get("event") == "call"]
        self.assertTrue(calls)
        self.assertEqual(calls[0]["number"], "+**********23", "numbers masked for non-identifier subscribers")

    @unittest.skipUnless(testutil.HAVE_SMS_PDU, "shannond.sms_pdu not available")
    def test_sms_list_masked(self):
        self.h.fake.inject_sms()
        self.h.run_until(lambda: self.h.events_of("sms-received"))
        r = self.client(lambda c: c.request("sms-list"))
        self.assertEqual(r["result"][0]["sender"], "+**********56")
        self.assertEqual(r["result"][0]["text"], "<10 chars>")
        r = self.client(lambda c: c.request("sms-list", identifiers=True))
        self.assertEqual(r["result"][0]["text"], "hellohello")

    def test_redact(self):
        data = {"number": "+33639980012", "text": "abc", "reg": {"mcc": "001", "cs": "home"},
                "ipv4": {"address": "192.0.2.10", "dns": ["192.0.2.53"], "mtu": 1430}, "imei": None}
        r = redact(data)
        self.assertEqual(r["number"], "+*********12")
        self.assertEqual(r["text"], "<3 chars>")
        self.assertEqual(r["reg"], {"mcc": "<redacted>", "cs": "home"})
        self.assertEqual(r["ipv4"]["mtu"], 1430)
        self.assertEqual(r["ipv4"]["address"], "<redacted>")
        self.assertIsNone(r["imei"])


class DaemonProcessTest(unittest.TestCase):
    """The real entry point against the standalone fake modem on two ptys (mock)."""

    def test_daemon_and_shannonctl_status(self):
        tmp = tempfile.mkdtemp(prefix="shd-", dir="/tmp")
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        fake = subprocess.Popen([sys.executable, os.path.join(ROOT, "tests", "fake_modem.py"), "--dir", tmp,
                                 "--boot-delay", "0.3"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                text=True, env=env)
        daemon = None
        try:
            line = fake.stdout.readline()
            self.assertIn("fake modem ready", line)
            control = os.path.join(tmp, "control")
            daemon = subprocess.Popen(
                [sys.executable, os.path.join(ROOT, "bin", "shannond"), "--ipc", os.path.join(tmp, "ipc"),
                 "--rfs", os.path.join(tmp, "rfs"), "--control", control, "--rfs-upper", os.path.join(tmp, "upper"),
                 "--nv-seed", "none", "--efs-lower", "", "--data-state-dir", os.path.join(tmp, "data"),
                 "--loop", "selectors", "--log-level", "warning"],
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, env=env)
            deadline = time.time() + 10
            result = None
            while time.time() < deadline:
                if os.path.exists(control):
                    out = subprocess.run([sys.executable, os.path.join(ROOT, "bin", "shannonctl"), "--socket", control,
                                          "status"], capture_output=True, text=True, env=env, timeout=10)
                    if out.returncode == 0:
                        result = json.loads(out.stdout)
                        if result["cp"] == "online" and result["sim"]["state"] == "ready":
                            break
                time.sleep(0.1)
            self.assertIsNotNone(result, "shannonctl status never answered")
            self.assertEqual(result["cp"], "online")
            self.assertEqual(result["sim"]["state"], "ready")
            out = subprocess.run([sys.executable, os.path.join(ROOT, "bin", "shannonctl"), "--socket", control,
                                  "radio", "on"], capture_output=True, text=True, env=env, timeout=10)
            self.assertEqual(out.returncode, 0, out.stderr)
            out = subprocess.run([sys.executable, os.path.join(ROOT, "bin", "shannonctl"), "--socket", control,
                                  "call", "dial", "112"], capture_output=True, text=True, env=env, timeout=10)
            self.assertEqual(out.returncode, 1)
            self.assertIn("emergency", out.stderr)
        finally:
            for p in (daemon, fake):
                if p is not None and p.poll() is None:
                    p.send_signal(signal.SIGTERM)
                    try:
                        p.wait(5)
                    except subprocess.TimeoutExpired:
                        p.kill()
                        p.wait()
            if daemon is not None:
                err = daemon.stderr.read()
                daemon.stderr.close()
                self.assertNotIn("Traceback", err)
            fake.stdout.close()
            subprocess.run(["rm", "-rf", tmp])
        self.assertEqual(daemon.returncode, 0, "SIGTERM stops the daemon cleanly")


class MmAttachFailureTest(unittest.TestCase):
    """--mm: a facade that fails at attach (bus name taken, no bus) must not take shannond down."""

    def test_attach_error_keeps_core_alive(self):
        tmp = tempfile.mkdtemp(prefix="shm-", dir="/tmp")
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        fake = subprocess.Popen([sys.executable, os.path.join(ROOT, "tests", "fake_modem.py"), "--dir", tmp],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=env)
        control = os.path.join(tmp, "control")
        script = (
            "import sys, types; sys.path.insert(0, %r)\n"
            "mod = types.ModuleType('shannond.mm')\n"
            "class NameTakenError(RuntimeError): pass\n"
            "def attach(core, loop): raise NameTakenError('org.freedesktop.ModemManager1 is taken')\n"
            "mod.attach = attach\n"
            "import shannond; sys.modules['shannond.mm'] = mod; shannond.mm = mod\n"
            "from shannond.daemon import main\n"
            "sys.exit(main(sys.argv[1:]))\n" % ROOT)
        daemon = None
        try:
            self.assertIn("ready", fake.stdout.readline())
            daemon = subprocess.Popen(
                [sys.executable, "-c", script, "--mm", "--loop", "selectors", "--ipc", os.path.join(tmp, "ipc"),
                 "--rfs", os.path.join(tmp, "rfs"), "--control", control, "--rfs-upper", os.path.join(tmp, "upper"),
                 "--nv-seed", "none", "--efs-lower", "", "--cp-state", "", "--data-state-dir", os.path.join(tmp, "d")],
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, env=env)
            ok = False
            deadline = time.time() + 10
            while time.time() < deadline and not ok:
                if os.path.exists(control):
                    out = subprocess.run([sys.executable, os.path.join(ROOT, "bin", "shannonctl"), "--socket",
                                          control, "ping"], capture_output=True, text=True, env=env, timeout=10)
                    ok = out.returncode == 0
                time.sleep(0.1)
            self.assertTrue(ok, "control socket alive after the facade failed")
            self.assertIsNone(daemon.poll())
        finally:
            for p in (daemon, fake):
                if p is not None and p.poll() is None:
                    p.send_signal(signal.SIGTERM)
                    try:
                        p.wait(5)
                    except subprocess.TimeoutExpired:
                        p.kill()
                        p.wait()
            err = daemon.stderr.read() if daemon is not None else ""
            if daemon is not None:
                daemon.stderr.close()
            fake.stdout.close()
            subprocess.run(["rm", "-rf", tmp])
        self.assertIn("ModemManager facade not started (NameTakenError", err)
        self.assertNotIn("Traceback", err)


if __name__ == "__main__":
    unittest.main()
