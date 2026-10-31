# SPDX-License-Identifier: GPL-2.0-or-later
"""Integration test of the shannon2mm facade on a real system bus.

Runs only inside a disposable Linux container (it installs the D-Bus policy,
creates users, starts dbus-daemon and NetworkManager, and creates a dummy
``rmnet0``).  Requirements: root, ``SHANNON2MM_IT=1``, dbus, python-dbus,
python-gobject, ModemManager's mmcli and introspection files (the
modemmanager package, never started), optionally NetworkManager and the
NET_ADMIN capability.  Example (Arch Linux ARM image)::

    docker run -d --name shannon2mm-it --cap-add NET_ADMIN \
        -v "$PWD/modem/shannond:/src:ro" t715-alarm:dev-aarch64 sleep infinity
    docker exec shannon2mm-it pacman -Sy --noconfirm --needed \
        modemmanager python-dbus python-gobject networkmanager iproute2
    docker exec -e SHANNON2MM_IT=1 -w /src shannon2mm-it \
        python3 -m unittest discover -s tests -p 'test_mm_integration.py' -v
    docker rm -f shannon2mm-it

Set ``SHANNON2MM_IT_SHOW=1`` to print the mmcli outputs.  All values come
from ``shannond.mm.fake`` (test PLMN 001-01, documentation addresses).
"""

import grp
import os
import pwd
import re
import shutil
import signal
import subprocess
import sys
import time
import unittest
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
PKG_ROOT = os.path.dirname(HERE)
POLICY_SRC = os.path.join(PKG_ROOT, "dbus", "org.freedesktop.ModemManager1.conf")
POLICY_DST = "/usr/share/dbus-1/system.d/org.freedesktop.ModemManager1.conf"
MM_XML_DIR = "/usr/share/dbus-1/interfaces"
SERVICE = "org.freedesktop.ModemManager1"
ROOT = "/org/freedesktop/ModemManager1"
MODEM = ROOT + "/Modem/0"
WHEEL_USER = "s2m-desk"
OTHER_USER = "s2m-other"

ENABLED = (os.environ.get("SHANNON2MM_IT") == "1" and sys.platform.startswith("linux")
           and hasattr(os, "geteuid") and os.geteuid() == 0 and shutil.which("mmcli") is not None)
SHOW = os.environ.get("SHANNON2MM_IT_SHOW") == "1"


def run(cmd, user=None, check=True, timeout=30, input=None):
    if user is not None:
        cmd = ["runuser", "-u", user, "--"] + cmd
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, input=input)
    if SHOW:
        sys.stdout.write("\n$ %s\n%s%s" % (" ".join(cmd), proc.stdout, proc.stderr))
    if check and proc.returncode != 0:
        raise AssertionError("%s failed (%d): %s%s" % (" ".join(cmd), proc.returncode, proc.stdout, proc.stderr))
    return proc


def mmcli_kv(*args):
    """mmcli -K output as a dict (multi-value keys keep their last value)."""
    out = {}
    proc = run(["mmcli"] + list(args) + ["-K"])
    # libmm-glib warns when a property or dictionary does not match the MM API.
    for word in ("WARNING", "CRITICAL"):
        if word in proc.stderr:
            raise AssertionError("mmcli %s: %s" % (" ".join(args), proc.stderr.strip()))
    for line in proc.stdout.splitlines():
        if ":" in line:
            key, _, value = line.partition(":")
            out[key.strip()] = value.strip()
    return out


def wait_for(predicate, timeout=10.0, step=0.2):
    deadline = time.monotonic() + timeout
    while True:
        value = predicate()
        if value or time.monotonic() > deadline:
            return value
        time.sleep(step)


def introspect(path, user=None):
    xml = run(["gdbus", "introspect", "--system", "--dest", SERVICE, "--object-path", path, "--xml"],
              user=user).stdout
    return ET.fromstring(xml)


def iface_summary(iface_el):
    methods, signals, props = {}, {}, {}
    for el in iface_el:
        if el.tag == "method":
            ins = "".join(a.get("type") for a in el.findall("arg") if a.get("direction", "in") == "in")
            outs = "".join(a.get("type") for a in el.findall("arg") if a.get("direction") == "out")
            methods[el.get("name")] = (ins, outs)
        elif el.tag == "signal":
            signals[el.get("name")] = "".join(a.get("type") for a in el.findall("arg"))
        elif el.tag == "property":
            props[el.get("name")] = (el.get("type"), el.get("access"))
    return methods, signals, props


@unittest.skipUnless(ENABLED, "integration test: set SHANNON2MM_IT=1 in the root test container")
class FacadeOnSystemBus(unittest.TestCase):
    facade = None
    nm = None

    @classmethod
    def setUpClass(cls):
        shutil.copyfile(POLICY_SRC, POLICY_DST)
        # The container has the modemmanager package for mmcli and the XML
        # files; its D-Bus activation file would let NetworkManager start the
        # real ModemManager whenever the name is free.  Remove it.
        activation = "/usr/share/dbus-1/system-services/org.freedesktop.ModemManager1.service"
        if os.path.exists(activation):
            os.unlink(activation)
        subprocess.run(["pkill", "-x", "ModemManager"], check=False)
        for user, groups in ((WHEEL_USER, ["-G", "wheel"]), (OTHER_USER, [])):
            try:
                pwd.getpwnam(user)
            except KeyError:
                run(["useradd", "-M", "-s", "/usr/bin/nologin"] + groups + [user])
        os.makedirs("/run/dbus", exist_ok=True)
        if os.path.exists("/run/dbus/system_bus_socket"):
            run(["dbus-send", "--system", "--type=method_call", "--print-reply", "--dest=org.freedesktop.DBus",
                 "/org/freedesktop/DBus", "org.freedesktop.DBus.ReloadConfig"])
        else:
            run(["dbus-daemon", "--system", "--fork"])
            wait_for(lambda: os.path.exists("/run/dbus/system_bus_socket"), 5)
        subprocess.run(["pkill", "-f", "[p]ython3 -m shannond.mm"], check=False)
        wait_for(lambda: subprocess.run(["pgrep", "-f", "[p]ython3 -m shannond.mm"],
                                        capture_output=True).returncode != 0, 5)
        time.sleep(0.3)
        cls.facade = cls.start_facade()

    @classmethod
    def start_facade(cls, *extra):
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", PYTHONUNBUFFERED="1")
        proc = subprocess.Popen([sys.executable, "-m", "shannond.mm", "--fake", "--net-port", "rmnet0",
                                 "--delay", "0.05"] + list(extra),
                                cwd=PKG_ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        deadline = time.monotonic() + 15
        lines = []
        while time.monotonic() < deadline:
            line = proc.stdout.readline()
            if not line:
                break
            lines.append(line)
            if "fake facade ready" in line:
                return proc
        proc.kill()
        raise AssertionError("facade did not start:\n" + "".join(lines))

    @classmethod
    def tearDownClass(cls):
        for proc in (cls.nm, cls.facade):
            if proc is not None and proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(5)
            if proc is not None and proc.stdout is not None:
                proc.stdout.close()

    def signal_facade(self, signum):
        os.kill(self.facade.pid, signum)

    # -- 1. Manager / ObjectManager / Modem / Sim / 3GPP ----------------------

    def test_01_list(self):
        out = run(["mmcli", "-L"]).stdout
        self.assertIn(MODEM + " [Samsung] SS333", out)
        reply = run(["gdbus", "call", "--system", "--dest", SERVICE, "--object-path", ROOT, "--method",
                     "org.freedesktop.DBus.Properties.Get", SERVICE, "Version"]).stdout
        self.assertIn("1.24", reply)
        run(["gdbus", "call", "--system", "--dest", SERVICE, "--object-path", ROOT, "--method",
             SERVICE + ".ScanDevices"])

    def test_02_modem(self):
        # The identity query is answered shortly after start-up.
        kv = wait_for(lambda: (lambda d: d if d["modem.3gpp.imei"] != "--" else None)(mmcli_kv("-m", "0")), 5)
        self.assertTrue(kv, "IMEI never published")
        self.assertEqual(kv["modem.generic.manufacturer"], "Samsung")
        self.assertEqual(kv["modem.generic.model"], "SS333")
        self.assertEqual(kv["modem.generic.plugin"], "shannon")
        self.assertEqual(kv["modem.generic.primary-port"], "umts_ipc0")
        out = run(["mmcli", "-m", "0"]).stdout
        self.assertIn("umts_ipc0 (ignored), rmnet0 (net)", out)
        self.assertIn("gsm-umts, lte", out)
        self.assertEqual(kv["modem.generic.sim"], ROOT + "/SIM/0")
        self.assertIn(kv["modem.generic.state"], ("disabled", "enabling", "searching", "registered", "enabled"))
        self.assertEqual(kv["modem.3gpp.imei"], "000000000000000")
        reset = run(["mmcli", "-m", "0", "-r"], check=False)
        self.assertNotEqual(reset.returncode, 0)
        self.assertIn("Unsupported", reset.stderr)
        cmd = run(["mmcli", "-m", "0", "--command=ATI"], check=False)
        self.assertNotEqual(cmd.returncode, 0)

    def test_03_enable_and_register(self):
        run(["mmcli", "-m", "0", "-e"])
        kv = wait_for(lambda: (lambda d: d if d["modem.generic.state"] == "registered" else None)(
            mmcli_kv("-m", "0")), 10)
        self.assertTrue(kv, "modem did not register")
        self.assertEqual(kv["modem.generic.access-technologies.value[1]"], "lte")
        self.assertEqual(kv["modem.3gpp.operator-code"], "00101")
        self.assertEqual(kv["modem.3gpp.operator-name"], "Test Network")
        self.assertEqual(kv["modem.3gpp.registration-state"], "home")
        self.assertEqual(kv["modem.generic.signal-quality.value"], "72")
        self.assertEqual(kv["modem.generic.power-state"], "on")

    def test_04_simple_get_status(self):
        out = run(["gdbus", "call", "--system", "--dest", SERVICE, "--object-path", MODEM, "--method",
                   SERVICE + ".Modem.Simple.GetStatus"]).stdout
        self.assertIn("'state': <uint32 8>", out)
        self.assertIn("'signal-quality': <(uint32 72, true)>", out)
        self.assertIn("'m3gpp-operator-code': <'00101'>", out)
        self.assertIn("'access-technologies': <uint32 16384>", out)

    def test_05_sim(self):
        kv = mmcli_kv("-i", "0")
        self.assertEqual(kv["sim.properties.imsi"], "001010000000001")
        self.assertEqual(kv["sim.properties.iccid"], "8900000000000000001")
        self.assertEqual(kv["sim.properties.operator-code"], "00101")
        self.assertEqual(kv["sim.properties.active"], "yes")
        pin = run(["mmcli", "-i", "0", "--pin=1234"], check=False)
        self.assertNotEqual(pin.returncode, 0)      # SIM not locked: refused, nothing sent
        self.assertIn("WrongState", pin.stderr)

    # -- 2. Messaging + Sms ------------------------------------------------

    def test_06_messaging(self):
        out = run(["mmcli", "-m", "0", "--messaging-list-sms"]).stdout
        self.assertIn(ROOT + "/SMS/0 (received)", out)
        kv = mmcli_kv("-s", "0")
        self.assertEqual(kv["sms.properties.pdu-type"], "deliver")
        self.assertEqual(kv["sms.properties.state"], "received")
        self.assertEqual(kv["sms.content.number"], "+15555550123")
        out = run(["mmcli", "-m", "0", "--messaging-create-sms=number='+15555550199',text='hello test'"]).stdout
        path = re.search(r"(/org/freedesktop/ModemManager1/SMS/\d+)", out).group(1)
        run(["mmcli", "-s", path, "--send"])
        kv = mmcli_kv("-s", path)
        self.assertEqual(kv["sms.properties.state"], "sent")
        self.assertEqual(kv["sms.properties.pdu-type"], "submit")
        self.assertEqual(kv["sms.content.text"], "hello test")
        # A received SMS raises Added(path, true).
        monitor = subprocess.Popen(["gdbus", "monitor", "--system", "--dest", SERVICE],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            time.sleep(0.5)
            self.signal_facade(signal.SIGUSR1)
            time.sleep(1.0)
        finally:
            monitor.terminate()
        log = monitor.communicate(timeout=5)[0]
        self.assertRegex(log, r"Messaging\.Added \(objectpath '/org/freedesktop/ModemManager1/SMS/\d+', true\)")
        run(["mmcli", "-m", "0", "--messaging-delete-sms=" + path])
        self.assertNotIn(path + " ", run(["mmcli", "-m", "0", "--messaging-list-sms"]).stdout + " ")

    # -- 3. Bearer ---------------------------------------------------------

    def test_07_simple_connect_and_bearer(self):
        out = run(["mmcli", "-m", "0", "--simple-connect=apn=test"]).stdout
        path = re.search(r"(/org/freedesktop/ModemManager1/Bearer/\d+)", out).group(1)
        kv = mmcli_kv("-b", path)
        self.assertEqual(kv["bearer.status.connected"], "yes")
        self.assertEqual(kv["bearer.status.interface"], "rmnet0")
        self.assertEqual(kv["bearer.ipv4-config.method"], "static")
        self.assertEqual(kv["bearer.ipv4-config.address"], "192.0.2.10")
        self.assertEqual(kv["bearer.ipv4-config.prefix"], "32")
        self.assertEqual(kv["bearer.ipv4-config.mtu"], "1500")
        self.assertEqual(kv["bearer.ipv6-config.method"], "dhcp")
        self.assertEqual(kv["bearer.ipv6-config.address"], "fe80::1:0:0:a")
        self.assertEqual(kv["bearer.ipv6-config.prefix"], "64")
        self.assertEqual(mmcli_kv("-m", "0")["modem.generic.state"], "connected")
        run(["mmcli", "-m", "0", "--simple-disconnect"])
        self.assertEqual(mmcli_kv("-m", "0")["modem.generic.state"], "registered")
        # CreateBearer + Bearer.Connect path
        out = run(["mmcli", "-m", "0", "--create-bearer=apn=test2,ip-type=ipv4"]).stdout
        path = re.search(r"(/org/freedesktop/ModemManager1/Bearer/\d+)", out).group(1)
        run(["mmcli", "-b", path, "--connect"])
        kv = mmcli_kv("-b", path)
        self.assertEqual(kv["bearer.status.connected"], "yes")
        self.assertIn(kv.get("bearer.ipv6-config.method", "--"), ("--", "unknown"))
        run(["mmcli", "-b", path, "--disconnect"])
        self.assertEqual(mmcli_kv("-b", path)["bearer.status.connected"], "no")

    # -- 4. Voice + Call ---------------------------------------------------

    def test_08_voice(self):
        out = run(["mmcli", "-m", "0", "--voice-create-call=number=+15555550123"]).stdout
        path = re.search(r"(/org/freedesktop/ModemManager1/Call/\d+)", out).group(1)
        self.assertIn(mmcli_kv("-o", path)["call.properties.state"], ("unknown", "--"))
        run(["mmcli", "-o", path, "--start"])
        self.assertTrue(wait_for(lambda: mmcli_kv("-o", path)["call.properties.state"] == "active", 5))
        run(["mmcli", "-o", path, "--send-dtmf=1"])
        run(["mmcli", "-o", path, "--hangup"])
        kv = mmcli_kv("-o", path)
        self.assertEqual(kv["call.properties.state"], "terminated")
        run(["mmcli", "-m", "0", "--voice-delete-call=" + path])
        self.signal_facade(signal.SIGUSR2)
        calls = wait_for(lambda: re.findall(r"(/org/freedesktop/ModemManager1/Call/\d+) incoming \(ringing-in\)",
                                            run(["mmcli", "-m", "0", "--voice-list-calls"]).stdout), 5)
        self.assertTrue(calls)
        run(["mmcli", "-o", calls[0], "--accept"])
        self.assertEqual(mmcli_kv("-o", calls[0])["call.properties.state"], "active")
        run(["mmcli", "-m", "0", "--voice-hangup-all"])
        self.assertEqual(mmcli_kv("-o", calls[0])["call.properties.state"], "terminated")

    # -- introspection == ModemManager 1.24 XML -------------------------------

    def test_09_introspection_matches_modemmanager(self):
        run(["mmcli", "-m", "0", "--voice-create-call=number=+15555550123"])
        out = run(["mmcli", "-m", "0", "--create-bearer=apn=intro"]).stdout
        bearer = re.search(r"(/org/freedesktop/ModemManager1/Bearer/\d+)", out).group(1)
        calls = re.findall(r"(/org/freedesktop/ModemManager1/Call/\d+)",
                           run(["mmcli", "-m", "0", "--voice-list-calls"]).stdout)
        objects = {ROOT: ["org.freedesktop.ModemManager1"],
                   MODEM: ["org.freedesktop.ModemManager1.Modem", "org.freedesktop.ModemManager1.Modem.Simple",
                           "org.freedesktop.ModemManager1.Modem.Modem3gpp",
                           "org.freedesktop.ModemManager1.Modem.Messaging",
                           "org.freedesktop.ModemManager1.Modem.Voice"],
                   ROOT + "/SIM/0": ["org.freedesktop.ModemManager1.Sim"],
                   bearer: ["org.freedesktop.ModemManager1.Bearer"],
                   ROOT + "/SMS/0": ["org.freedesktop.ModemManager1.Sms"],
                   calls[-1]: ["org.freedesktop.ModemManager1.Call"]}
        checked = 0
        for path, ifaces in objects.items():
            node = introspect(path)
            live = {el.get("name"): el for el in node.findall("interface")}
            for iface in ifaces:
                ref_node = ET.parse(os.path.join(MM_XML_DIR, iface + ".xml")).getroot()
                ref = [el for el in ref_node.findall("interface") if el.get("name") == iface][0]
                self.assertIn(iface, live, "%s missing on %s" % (iface, path))
                self.assertEqual(iface_summary(live[iface]), iface_summary(ref), "%s on %s" % (iface, path))
                checked += 1
            if path == ROOT:
                self.assertIn("org.freedesktop.DBus.ObjectManager", live)
            self.assertIn("org.freedesktop.DBus.Properties", live)
        self.assertEqual(checked, 10)
        run(["mmcli", "-m", "0", "--delete-bearer=" + bearer])

    # -- D-Bus policy --------------------------------------------------------

    def test_10_policy(self):
        self.assertIn("SS333", run(["mmcli", "-L"], user=WHEEL_USER).stdout)
        denied = run(["mmcli", "-m", "0"], user=OTHER_USER, check=False)
        self.assertNotEqual(denied.returncode, 0)
        self.assertNotIn("SS333", denied.stdout)
        get = run(["gdbus", "call", "--system", "--dest", SERVICE, "--object-path", MODEM, "--method",
                   "org.freedesktop.DBus.Properties.Get", SERVICE + ".Modem.Modem3gpp", "Imei"],
                  user=OTHER_USER, check=False)
        self.assertNotEqual(get.returncode, 0)
        self.assertIn("AccessDenied", get.stderr)
        node = introspect(MODEM, user=OTHER_USER)        # introspection stays open
        self.assertTrue(node.findall("interface"))
        own = run([sys.executable, "-c", "import dbus; dbus.SystemBus().request_name(%r)" % SERVICE],
                  user=WHEEL_USER, check=False)
        self.assertNotEqual(own.returncode, 0)
        self.assertIn("AccessDenied", own.stderr)

    def test_11_name_taken(self):
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        proc = subprocess.run([sys.executable, "-m", "shannond.mm", "--fake"], cwd=PKG_ROOT, env=env,
                              capture_output=True, text=True, timeout=20)
        self.assertEqual(proc.returncode, 2)
        self.assertIn("already owned", proc.stderr)

    # -- NetworkManager ------------------------------------------------------

    def test_12_networkmanager(self):
        if shutil.which("NetworkManager") is None or shutil.which("nmcli") is None:
            self.skipTest("NetworkManager not installed")
        if not os.path.exists("/sys/class/net/rmnet0"):
            if run(["ip", "link", "add", "rmnet0", "type", "dummy"], check=False).returncode != 0:
                self.skipTest("cannot create a dummy rmnet0 (needs NET_ADMIN)")
        os.makedirs("/etc/NetworkManager/conf.d", exist_ok=True)
        with open("/etc/NetworkManager/conf.d/shannon2mm-it.conf", "w") as f:
            f.write("[main]\nplugins=keyfile\n[keyfile]\nunmanaged-devices=interface-name:eth*;"
                    "interface-name:lo\n")
        for d in ("/var/lib/NetworkManager", "/run/NetworkManager"):
            os.makedirs(d, exist_ok=True)
        if run(["nmcli", "-t", "general", "status"], check=False).returncode != 0:
            with open("/tmp/shannon2mm-it-nm.log", "w") as nm_log:
                type(self).nm = subprocess.Popen(["NetworkManager", "--no-daemon"], stdout=nm_log,
                                                 stderr=subprocess.STDOUT)
        devices = wait_for(lambda: "umts_ipc0:gsm" in run(["nmcli", "-t", "-f", "DEVICE,TYPE", "device"],
                                                           check=False).stdout, 20)
        self.assertTrue(devices, "NetworkManager does not list the modem")
        self.assertNotIn("rmnet0:", run(["nmcli", "-t", "-f", "DEVICE,TYPE", "device"]).stdout)
        run(["nmcli", "connection", "delete", "s2m-it"], check=False)
        run(["nmcli", "connection", "add", "type", "gsm", "ifname", "umts_ipc0", "con-name", "s2m-it",
             "gsm.apn", "test", "ipv6.method", "auto"])
        run(["nmcli", "connection", "up", "s2m-it"], timeout=90)
        self.assertIn("umts_ipc0:connected", run(["nmcli", "-t", "-f", "DEVICE,STATE", "device"]).stdout)
        v4 = run(["ip", "-4", "addr", "show", "rmnet0"]).stdout
        self.assertIn("192.0.2.10/32", v4)
        v6 = run(["ip", "-6", "addr", "show", "rmnet0"]).stdout
        self.assertIn("fe80::1:0:0:a/64", v6)
        self.assertIn("default", run(["ip", "route", "show", "dev", "rmnet0"]).stdout)
        run(["nmcli", "connection", "down", "s2m-it"], timeout=60)
        self.assertNotIn("192.0.2.10", run(["ip", "-4", "addr", "show", "rmnet0"]).stdout)
        run(["nmcli", "connection", "delete", "s2m-it"], check=False)

    # -- crash and recovery (last: it resets the fake modem) -------------------

    def test_99_crash_and_recovery(self):
        self.signal_facade(signal.SIGHUP)
        self.assertTrue(wait_for(lambda: mmcli_kv("-m", "0")["modem.generic.state"] == "failed", 3))
        self.assertTrue(wait_for(lambda: mmcli_kv("-m", "0")["modem.generic.state"] == "disabled", 6))


@unittest.skipUnless(ENABLED, "integration test: set SHANNON2MM_IT=1 in the root test container")
class RealCoreOnSystemBus(unittest.TestCase):
    """``shannond --mm`` (real ModemCore + facade) against tests/fake_modem.py over ptys."""

    procs = []

    @classmethod
    def setUpClass(cls):
        if not os.path.exists(os.path.join(HERE, "fake_modem.py")) or not os.path.exists(
                os.path.join(PKG_ROOT, "shannond", "daemon.py")):
            raise unittest.SkipTest("shannond daemon or fake modem not available")
        subprocess.run(["pkill", "-f", "[p]ython3 -m shannond"], check=False)
        wait_for(lambda: subprocess.run(["pgrep", "-f", "[p]ython3 -m shannond"],
                                        capture_output=True).returncode != 0, 5)
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", PYTHONUNBUFFERED="1")
        ptys = "/tmp/shannon2mm-it-pty"
        os.makedirs(ptys, exist_ok=True)
        fake = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_modem.py"), "--dir", ptys], cwd=PKG_ROOT,
                                env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        cls.procs.append(fake)
        if not wait_for(lambda: os.path.exists(os.path.join(ptys, "ipc")), 5):
            raise AssertionError("fake modem did not start")
        cls.log = open("/tmp/shannon2mm-it-shannond.log", "w")
        daemon = subprocess.Popen([sys.executable, "-m", "shannond", "--ipc", os.path.join(ptys, "ipc"), "--no-rfs",
                                   "--no-control", "--mm"], cwd=PKG_ROOT, env=env, stdout=cls.log,
                                  stderr=subprocess.STDOUT)
        cls.procs.append(daemon)
        listed = wait_for(lambda: "SS333" in run(["mmcli", "-L"], check=False).stdout, 10)
        if not listed:
            raise AssertionError("shannond --mm did not export the modem")
        wait_for(lambda: mmcli_kv("-m", "0")["modem.generic.state"] == "disabled", 10)

    @classmethod
    def tearDownClass(cls):
        for proc in reversed(cls.procs):
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(5)
            if proc is not None and proc.stdout is not None:
                proc.stdout.close()
        cls.procs = []
        if getattr(cls, "log", None):
            cls.log.close()

    def test_1_identity_and_state(self):
        kv = mmcli_kv("-m", "0")
        self.assertEqual(kv["modem.generic.state"], "disabled")
        self.assertEqual(kv["modem.3gpp.imei"], "000000000000000")
        self.assertEqual(mmcli_kv("-i", "0")["sim.properties.imsi"], "001010000000001")

    def test_2_enable_connect_call(self):
        run(["mmcli", "-m", "0", "-e"])
        self.assertTrue(wait_for(lambda: mmcli_kv("-m", "0")["modem.generic.state"] == "registered", 10))
        self.assertEqual(mmcli_kv("-m", "0")["modem.3gpp.operator-code"], "00101")
        out = run(["mmcli", "-m", "0", "--simple-connect=apn=test"], timeout=60).stdout
        bearer = re.search(r"(/org/freedesktop/ModemManager1/Bearer/\d+)", out).group(1)
        kv = mmcli_kv("-b", bearer)
        self.assertEqual(kv["bearer.status.connected"], "yes")
        self.assertEqual(kv["bearer.status.interface"], "rmnet0")
        self.assertEqual(kv["bearer.ipv4-config.method"], "static")
        self.assertEqual(kv["bearer.ipv4-config.prefix"], "32")
        out = run(["mmcli", "-m", "0", "--voice-create-call=number=+15555550123"]).stdout
        call = re.search(r"(/org/freedesktop/ModemManager1/Call/\d+)", out).group(1)
        run(["mmcli", "-o", call, "--start"], timeout=30)
        self.assertTrue(wait_for(lambda: mmcli_kv("-o", call)["call.properties.state"] == "active", 10))
        run(["mmcli", "-o", call, "--hangup"])
        self.assertEqual(mmcli_kv("-o", call)["call.properties.state"], "terminated")
        run(["mmcli", "-m", "0", "--simple-disconnect"], timeout=60)
        self.assertEqual(mmcli_kv("-m", "0")["modem.generic.state"], "registered")

    def test_3_sms(self):
        import importlib.util
        if importlib.util.find_spec("shannond.sms_pdu") is None:
            self.skipTest("shannond.sms_pdu not delivered yet")
        out = run(["mmcli", "-m", "0", "--messaging-create-sms=number='+15555550123',text='hello test'"]).stdout
        path = re.search(r"(/org/freedesktop/ModemManager1/SMS/\d+)", out).group(1)
        run(["mmcli", "-s", path, "--send"], timeout=60)
        self.assertEqual(mmcli_kv("-s", path)["sms.properties.state"], "sent")


if __name__ == "__main__":
    unittest.main()
