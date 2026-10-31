# SPDX-License-Identifier: GPL-2.0-or-later
"""Unit tests of the shannon2mm object layer with the fake core (no D-Bus)."""

import inspect
import io
import logging
import os
import re
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from shannond.loop import SelectorLoop  # noqa: E402
from shannond.mm import enums as E  # noqa: E402
from shannond.mm import fake as F  # noqa: E402
from shannond.mm import spec  # noqa: E402
from shannond.mm.fake import FakeCore  # noqa: E402
from shannond.mm.model import Facade, MMError  # noqa: E402
from shannond.mm.spec import Variant  # noqa: E402

UNKNOWN_IP = {"method": Variant("u", E.IP_METHOD_UNKNOWN)}
PKG_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


class Recorder:
    """Sink that records everything the facade would put on the bus."""

    def __init__(self):
        self.events = []

    def object_added(self, obj):
        self.events.append(("added", obj.path))

    def object_removed(self, obj):
        self.events.append(("removed", obj.path))

    def properties_changed(self, obj, iface, changed):
        for name, value in changed.items():
            spec.check_value(spec.PROPERTIES[iface][name], value)
        self.events.append(("changed", obj.path, iface, dict(changed)))

    def emit(self, obj, iface, signal, *args):
        self.events.append(("signal", obj.path, iface, signal) + args)

    def signals(self, name):
        return [e for e in self.events if e[0] == "signal" and e[3] == name]

    def added(self):
        return [e[1] for e in self.events if e[0] == "added"]

    def removed(self):
        return [e[1] for e in self.events if e[0] == "removed"]


class Base(unittest.TestCase):
    core_kw = {}
    facade_kw = {}

    def setUp(self):
        logging.getLogger("shannond").setLevel(logging.CRITICAL)
        self.loop = SelectorLoop()
        self.core = FakeCore(self.loop, delay=0.001, **self.core_kw)
        self.sink = Recorder()
        kw = dict(net_ports=["rmnet0"], register_timeout=1.0, command_timeout=2.0, terminated_call_ttl=0)
        kw.update(self.facade_kw)
        self.f = Facade(self.core, self.loop, sink=self.sink, **kw)
        self.f.start()
        self.settle()

    def settle(self, seconds=0.05):
        self.loop.run_for(seconds)

    def call(self, obj, iface, method, *args, timeout=3.0):
        box = []
        self.f.call(obj, iface, method, list(args), lambda ok, result: box.append((ok, result)))
        self.loop.run_until(lambda: box, timeout)
        self.assertTrue(box, "%s.%s never answered" % (iface, method))
        self.assertEqual(len(box), 1)
        return box[0]

    def ok(self, obj, iface, method, *args, **kw):
        ok, result = self.call(obj, iface, method, *args, **kw)
        if not ok:
            self.fail("%s.%s failed: %r" % (iface, method, result))
        return result

    def err(self, obj, iface, method, *args, **kw):
        ok, result = self.call(obj, iface, method, *args, **kw)
        self.assertFalse(ok, "%s.%s unexpectedly succeeded" % (iface, method))
        self.assertIsInstance(result, MMError)
        return result

    def mprop(self, iface, name):
        return self.f.modem.get(iface, name)

    @property
    def state(self):
        return self.mprop(E.IFACE_MODEM, "State")

    def enable(self):
        self.ok(self.f.modem, E.IFACE_MODEM, "Enable", True)
        self.loop.run_until(lambda: self.state == E.STATE_REGISTERED, 2)
        self.assertEqual(self.state, E.STATE_REGISTERED)

    def assert_all_props_typed(self):
        for obj in [self.f.manager] + self.f.all_objects():
            for iface, props in obj.props.items():
                self.assertEqual(set(props), set(spec.PROPERTIES[iface]), (obj.path, iface))
                for name, value in props.items():
                    spec.check_value(spec.PROPERTIES[iface][name], value)


class StartupAndModem(Base):
    def test_objects_exported(self):
        self.assertEqual(self.sink.added()[:2], [E.SIM_PREFIX + "0", E.MODEM_PREFIX + "0"])
        self.assertEqual(self.f.modem.interfaces, list(spec.MODEM_INTERFACES))
        self.assertEqual(self.mprop(E.IFACE_MODEM, "Sim"), E.SIM_PREFIX + "0")
        self.assert_all_props_typed()

    def test_static_properties(self):
        m = self.f.modem.props[E.IFACE_MODEM]
        self.assertEqual(m["Manufacturer"], "Samsung")
        self.assertEqual(m["Model"], "SS333")
        self.assertEqual(m["Plugin"], "shannon")
        self.assertEqual(m["PrimaryPort"], "umts_ipc0")
        self.assertEqual(m["Ports"], [("umts_ipc0", E.PORT_IGNORED), ("rmnet0", E.PORT_NET)])
        self.assertEqual(m["CurrentCapabilities"], E.CAP_GSM_UMTS | E.CAP_LTE)
        self.assertEqual(m["SupportedIpFamilies"], 7)
        self.assertRegex(m["DeviceIdentifier"], r"^[0-9a-f]{40}$")
        self.assertEqual(self.f.manager.get(E.IFACE_MANAGER, "Version")[:4], "1.24")

    def test_identity_eager(self):
        self.assertIn("query_identity", self.core.calls_log)
        self.assertEqual(self.mprop(E.IFACE_MODEM, "EquipmentIdentifier"), F.FAKE_IMEI)
        self.assertEqual(self.mprop(E.IFACE_3GPP, "Imei"), F.FAKE_IMEI)
        self.assertEqual(self.mprop(E.IFACE_MODEM, "OwnNumbers"), [F.FAKE_OWN_NUMBER])
        self.assertEqual(self.mprop(E.IFACE_MODEM, "Revision"), "FAKE-REV-1")
        self.assertIn("112", self.f.sim.get(E.IFACE_SIM, "EmergencyNumbers"))
        self.assertEqual(self.f.sim.get(E.IFACE_SIM, "Imsi"), F.FAKE_IMSI)
        self.assertEqual(self.f.sim.get(E.IFACE_SIM, "SimIdentifier"), F.FAKE_ICCID)
        self.assertEqual(self.core.calls_log.count("query_identity"), 1)

    def test_disabled_state(self):
        self.assertEqual(self.state, E.STATE_DISABLED)
        self.assertEqual(self.mprop(E.IFACE_MODEM, "PowerState"), E.POWER_LOW)
        self.assertEqual(self.mprop(E.IFACE_MODEM, "UnlockRequired"), E.LOCK_NONE)
        self.assertEqual(self.mprop(E.IFACE_3GPP, "RegistrationState"), E.REG_IDLE)
        self.assertEqual(self.mprop(E.IFACE_MODEM, "SignalQuality"), (0, False))

    def test_enable_disable(self):
        self.enable()
        states = [e[5] for e in self.sink.signals("StateChanged") if e[1] == self.f.modem.path]
        self.assertEqual(states[0], E.STATE_ENABLING)
        self.assertEqual(states[-1], E.STATE_REGISTERED)
        first = self.sink.signals("StateChanged")[0]
        self.assertEqual(first[4:], (E.STATE_DISABLED, E.STATE_ENABLING, E.CHANGE_USER_REQUESTED))
        self.assertEqual(self.mprop(E.IFACE_3GPP, "OperatorCode"), "00101")
        self.assertEqual(self.mprop(E.IFACE_3GPP, "OperatorName"), F.FAKE_OPERATOR)
        self.assertEqual(self.mprop(E.IFACE_3GPP, "PacketServiceState"), E.PS_ATTACHED)
        self.assertEqual(self.mprop(E.IFACE_MODEM, "AccessTechnologies"), E.ACCESS_LTE)
        self.assertEqual(self.mprop(E.IFACE_MODEM, "SignalQuality"), (72, True))
        self.ok(self.f.modem, E.IFACE_MODEM, "Enable", True)      # idempotent
        self.ok(self.f.modem, E.IFACE_MODEM, "Enable", False)
        self.settle()
        self.assertEqual(self.state, E.STATE_DISABLED)
        self.assertEqual(self.mprop(E.IFACE_3GPP, "OperatorCode"), "")
        self.assert_all_props_typed()

    def test_concurrent_enable_joins(self):
        results = []
        for _ in range(2):
            self.f.call(self.f.modem, E.IFACE_MODEM, "Enable", [True], lambda ok, r: results.append(ok))
        self.loop.run_until(lambda: len(results) == 2, 2)
        self.assertEqual(results, [True, True])
        self.assertEqual(self.core.calls_log.count("radio_on"), 1)

    def test_get_status(self):
        status = self.ok(self.f.modem, E.IFACE_SIMPLE, "GetStatus")
        self.assertEqual(status, {"state": Variant("u", E.STATE_DISABLED)})
        self.enable()
        status = self.ok(self.f.modem, E.IFACE_SIMPLE, "GetStatus")
        self.assertEqual(status["state"], Variant("u", E.STATE_REGISTERED))
        self.assertEqual(status["m3gpp-operator-code"], Variant("s", "00101"))
        self.assertEqual(status["signal-quality"], Variant("(ub)", (72, True)))
        spec.check_value("a{sv}", status)

    def test_refused_and_neutral_methods(self):
        m = self.f.modem
        self.assertEqual(self.err(m, E.IFACE_MODEM, "Reset").name, E.ERR_UNSUPPORTED)
        self.assertEqual(self.err(m, E.IFACE_MODEM, "FactoryReset", "000000").name, E.ERR_UNSUPPORTED)
        self.assertEqual(self.err(m, E.IFACE_MODEM, "Command", "ATI", 3).name, E.ERR_UNAUTHORIZED)
        self.assertEqual(self.err(m, E.IFACE_MODEM, "GetCellInfo").name, E.ERR_UNSUPPORTED)
        self.assertEqual(self.err(m, E.IFACE_3GPP, "Scan").name, E.ERR_UNSUPPORTED)
        self.ok(m, E.IFACE_3GPP, "Register", "")
        self.assertEqual(self.err(m, E.IFACE_3GPP, "Register", "00101").name, E.ERR_UNSUPPORTED)
        modes = self.mprop(E.IFACE_MODEM, "CurrentModes")
        self.ok(m, E.IFACE_MODEM, "SetCurrentModes", modes)
        self.assertEqual(self.err(m, E.IFACE_MODEM, "SetCurrentModes", (E.MODE_4G, E.MODE_NONE)).name,
                         E.ERR_UNSUPPORTED)
        self.ok(m, E.IFACE_MODEM, "SetCurrentBands", [E.BAND_ANY])
        self.ok(m, E.IFACE_MODEM, "SetPowerState", E.POWER_LOW)
        self.assertEqual(self.err(m, E.IFACE_MODEM, "SetPowerState", E.POWER_OFF).name, E.ERR_UNSUPPORTED)
        mgr = self.f.manager
        self.ok(mgr, E.IFACE_MANAGER, "ScanDevices")
        self.ok(mgr, E.IFACE_MANAGER, "ReportKernelEvent", {"action": "add"})
        self.ok(mgr, E.IFACE_MANAGER, "InhibitDevice", "uid", True)
        self.ok(mgr, E.IFACE_MANAGER, "SetLogging", "DEBUG")
        self.assertEqual(self.err(mgr, E.IFACE_MANAGER, "SetLogging", "LOUD").name, E.ERR_INVALID_ARGS)
        self.assertEqual(self.err(m, E.IFACE_MODEM, "NoSuchMethod").name, E.ERR_UNSUPPORTED)
        logging.getLogger("shannond").setLevel(logging.CRITICAL)

    def test_command_timeout(self):
        self.core.hold.add("radio_on")
        self.f.opts.command_timeout = 0.05
        error = self.err(self.f.modem, E.IFACE_MODEM, "Enable", True)
        self.assertEqual(error.name, E.ERR_TIMEOUT)
        self.assertEqual(self.state, E.STATE_DISABLED)

    def test_core_failure_is_reported(self):
        self.core.fail["radio_on"] = "CP refused"
        error = self.err(self.f.modem, E.IFACE_MODEM, "Enable", True)
        self.assertEqual(error.name, E.ERR_FAILED)
        self.assertIn("CP refused", error.message)


class LockedSim(Base):
    core_kw = {"sim_locked": True}

    def test_locked(self):
        self.assertEqual(self.state, E.STATE_LOCKED)
        self.assertEqual(self.mprop(E.IFACE_MODEM, "UnlockRequired"), E.LOCK_SIM_PIN)
        self.assertEqual(self.mprop(E.IFACE_MODEM, "UnlockRetries"), {E.LOCK_SIM_PIN: 3, E.LOCK_SIM_PUK: 10})
        self.assertEqual(self.err(self.f.modem, E.IFACE_MODEM, "Enable", True).name, E.ERR_WRONG_STATE)
        self.assertNotIn("enter_pin", self.core.calls_log)     # never sent on our own

    def test_send_pin(self):
        sim = self.f.sim
        self.assertEqual(self.err(sim, E.IFACE_SIM, "SendPin", "12").name, E.ERR_INVALID_ARGS)
        self.assertEqual(self.err(sim, E.IFACE_SIM, "SendPin", "0000").name, E.ERR_ME_INCORRECT_PASSWORD)
        self.settle()
        self.assertEqual(self.mprop(E.IFACE_MODEM, "UnlockRetries")[E.LOCK_SIM_PIN], 2)
        self.ok(sim, E.IFACE_SIM, "SendPin", "1234")
        self.settle()
        self.assertEqual(self.state, E.STATE_DISABLED)
        self.assertEqual(self.mprop(E.IFACE_3GPP, "EnabledFacilityLocks"), E.FACILITY_SIM)
        self.assertEqual(self.err(sim, E.IFACE_SIM, "SendPin", "1234").name, E.ERR_WRONG_STATE)
        self.assertEqual(self.err(sim, E.IFACE_SIM, "SendPuk", "12345678", "1234").name, E.ERR_UNSUPPORTED)

    def test_simple_connect_needs_pin(self):
        error = self.err(self.f.modem, E.IFACE_SIMPLE, "Connect", {"apn": "test"})
        self.assertEqual(error.name, E.ERR_ME_SIM_PIN)
        path = self.ok(self.f.modem, E.IFACE_SIMPLE, "Connect", {"apn": "test", "pin": "1234"})
        self.assertEqual(self.f.bearers[path].get(E.IFACE_BEARER, "Connected"), True)
        self.assertEqual(self.state, E.STATE_CONNECTED)


class NoSim(Base):
    core_kw = {"sim_present": False}

    def test_failed(self):
        self.assertEqual(self.state, E.STATE_FAILED)
        self.assertEqual(self.mprop(E.IFACE_MODEM, "StateFailedReason"), E.FAILED_SIM_MISSING)
        self.assertEqual(self.mprop(E.IFACE_MODEM, "Sim"), E.NO_PATH)
        self.assertIsNone(self.f.sim)
        self.assertEqual(self.err(self.f.modem, E.IFACE_MODEM, "Enable", True).name, E.ERR_ME_SIM_NOT_INSERTED)
        self.assertTrue(self.mprop(E.IFACE_VOICE, "EmergencyOnly"))
        self.assertEqual(self.mprop(E.IFACE_3GPP, "Imei"), F.FAKE_IMEI)   # IMEI needs no SIM

    def test_sim_inserted_later(self):
        self.core.set(sim={"state": "ready"})
        self.settle()
        self.assertIsNotNone(self.f.sim)
        self.assertIn(self.f.sim.path, self.sink.added())
        self.assertEqual(self.state, E.STATE_DISABLED)
        self.assertEqual(self.f.sim.get(E.IFACE_SIM, "Imsi"), F.FAKE_IMSI)   # re-queried with the SIM


class Bearers(Base):
    def test_simple_connect_sends_the_attach_apn_first(self):
        self.ok(self.f.modem, E.IFACE_SIMPLE, "Connect", {"apn": "test"})
        log = self.core.calls_log
        self.assertLess(log.index("set_attach_apn"), log.index("radio_on"))
        self.assertLess(log.index("radio_on"), log.index("data_connect"))
        self.assertEqual(self.core.last_attach_request["apn"], "test")

    def test_set_current_modes(self):
        self.ok(self.f.modem, E.IFACE_MODEM, "SetCurrentModes", (E.MODE_2G | E.MODE_3G, E.MODE_NONE))
        self.assertEqual(self.core.state["modes"], 0x03)
        self.core.push_state()
        self.assertEqual(tuple(self.f.modem.get(E.IFACE_MODEM, "CurrentModes")), (E.MODE_2G | E.MODE_3G, E.MODE_NONE))

    def test_set_current_modes_refuses_what_is_not_supported(self):
        self.err(self.f.modem, E.IFACE_MODEM, "SetCurrentModes", (E.MODE_4G, E.MODE_NONE))
        self.assertNotIn("set_modes", self.core.calls_log)

    def test_simple_connect_survives_a_refused_attach_apn(self):
        self.core.fail["set_attach_apn"] = "refused"
        path = self.ok(self.f.modem, E.IFACE_SIMPLE, "Connect", {"apn": "test"})
        self.assertEqual(self.f.bearers[path].get(E.IFACE_BEARER, "Connected"), True)

    def test_simple_connect_from_disabled(self):
        path = self.ok(self.f.modem, E.IFACE_SIMPLE, "Connect", {"apn": "test"})
        bearer = self.f.bearers[path]
        b = bearer.props[E.IFACE_BEARER]
        self.assertTrue(b["Connected"])
        self.assertEqual(b["Interface"], "rmnet0")
        self.assertEqual(b["Ip4Config"]["method"], Variant("u", E.IP_METHOD_STATIC))
        self.assertEqual(b["Ip4Config"]["address"], Variant("s", "192.0.2.10"))
        self.assertEqual(b["Ip4Config"]["prefix"], Variant("u", 32))
        self.assertEqual(b["Ip6Config"]["method"], Variant("u", E.IP_METHOD_DHCP))
        self.assertEqual(b["Ip6Config"]["address"], Variant("s", "fe80::1:0:0:a"))
        self.assertEqual(self.state, E.STATE_CONNECTED)
        self.assertEqual(self.mprop(E.IFACE_MODEM, "Bearers"), [path])
        self.assertEqual(self.core.last_data_request["ip_type"], "ipv4v6")
        self.assertIsNone(self.core.last_data_request["user"])
        self.assertIsNone(self.core.last_data_request["auth"])
        self.assert_all_props_typed()

    def test_password_not_published(self):
        props = {"apn": "test", "user": "u", "password": "secret", "allowed-auth": E.AUTH_CHAP,
                 "ip-type": E.IP_FAMILY_IPV4}
        path = self.ok(self.f.modem, E.IFACE_SIMPLE, "Connect", props)
        exported = self.f.bearers[path].get(E.IFACE_BEARER, "Properties")
        self.assertNotIn("password", exported)
        self.assertEqual(exported["user"], Variant("s", "u"))
        self.assertTrue(self.core.last_data_request["password_set"])
        self.assertEqual(self.core.last_data_request["auth"], "chap")
        self.assertEqual(self.f.bearers[path].get(E.IFACE_BEARER, "Ip6Config"), UNKNOWN_IP)

    def test_reuse_and_disconnect(self):
        path = self.ok(self.f.modem, E.IFACE_SIMPLE, "Connect", {"apn": "test"})
        self.assertEqual(self.ok(self.f.modem, E.IFACE_SIMPLE, "Connect", {"apn": "test"}), path)
        self.ok(self.f.modem, E.IFACE_SIMPLE, "Disconnect", E.NO_PATH)
        self.assertEqual(self.f.bearers, {})
        self.assertIn(path, self.sink.removed())
        self.assertEqual(self.state, E.STATE_REGISTERED)

    def test_create_bearer_and_connect(self):
        self.enable()
        path = self.ok(self.f.modem, E.IFACE_MODEM, "CreateBearer", {"apn": "a", "ip-type": E.IP_FAMILY_IPV4})
        bearer = self.f.bearers[path]
        self.assertFalse(bearer.get(E.IFACE_BEARER, "Connected"))
        self.assertEqual(self.ok(self.f.modem, E.IFACE_MODEM, "ListBearers"), [path])
        self.ok(bearer, E.IFACE_BEARER, "Connect")
        self.assertTrue(bearer.get(E.IFACE_BEARER, "Connected"))
        # max one bearer: a new one cannot replace a connected one
        self.assertEqual(self.err(self.f.modem, E.IFACE_MODEM, "CreateBearer", {"apn": "b"}).name, E.ERR_TOO_MANY)
        self.ok(bearer, E.IFACE_BEARER, "Disconnect")
        self.assertFalse(bearer.get(E.IFACE_BEARER, "Connected"))
        self.assertEqual(bearer.get(E.IFACE_BEARER, "Ip4Config"), UNKNOWN_IP)
        # ... but replaces a disconnected one
        other = self.ok(self.f.modem, E.IFACE_MODEM, "CreateBearer", {"apn": "b"})
        self.assertEqual(list(self.f.bearers), [other])
        self.ok(self.f.modem, E.IFACE_MODEM, "DeleteBearer", other)
        self.assertEqual(self.err(self.f.modem, E.IFACE_MODEM, "DeleteBearer", other).name, E.ERR_NOT_FOUND)

    def test_bearer_settings_validation(self):
        m = self.f.modem
        self.assertEqual(self.err(m, E.IFACE_MODEM, "CreateBearer", {"apn": 3}).name, E.ERR_INVALID_ARGS)
        self.assertEqual(self.err(m, E.IFACE_MODEM, "CreateBearer", {"ip-type": 8}).name, E.ERR_UNSUPPORTED)
        self.assertEqual(self.err(m, E.IFACE_MODEM, "CreateBearer", {"profile-id": 2}).name, E.ERR_UNSUPPORTED)
        self.assertEqual(self.err(m, E.IFACE_MODEM, "CreateBearer", {"multiplex": 3}).name, E.ERR_UNSUPPORTED)

    def test_connect_requires_registration(self):
        path = self.ok(self.f.modem, E.IFACE_MODEM, "CreateBearer", {"apn": "a"})
        self.assertEqual(self.err(self.f.bearers[path], E.IFACE_BEARER, "Connect").name, E.ERR_WRONG_STATE)

    def test_connect_failure(self):
        self.enable()
        self.core.fail["data_connect"] = "PDP activation failed (cause 33)"
        error = self.err(self.f.modem, E.IFACE_SIMPLE, "Connect", {"apn": "bad"})
        self.assertIn("cause 33", error.message)
        bearer = list(self.f.bearers.values())[0]
        self.assertEqual(bearer.get(E.IFACE_BEARER, "ConnectionError")[0], E.ERR_FAILED)
        self.assertFalse(bearer.get(E.IFACE_BEARER, "Connected"))
        self.assertEqual(self.state, E.STATE_REGISTERED)

    def test_registration_timeout(self):
        self.core._register = lambda: None         # the network never answers
        self.f.opts.register_timeout = 0.1
        error = self.err(self.f.modem, E.IFACE_SIMPLE, "Connect", {"apn": "test"})
        self.assertEqual(error.name, E.ERR_ME_NO_NETWORK)
        self.assertEqual(self.state, E.STATE_SEARCHING)

    def test_network_drop(self):
        path = self.ok(self.f.modem, E.IFACE_SIMPLE, "Connect", {"apn": "test"})
        self.core.emit("data", {"connected": False, "cid": 1, "interface": "rmnet0", "ipv4": None, "ipv6": None})
        self.settle()
        bearer = self.f.bearers[path]
        self.assertFalse(bearer.get(E.IFACE_BEARER, "Connected"))
        self.assertEqual(bearer.get(E.IFACE_BEARER, "Ip4Config"), UNKNOWN_IP)
        self.assertEqual(self.state, E.STATE_REGISTERED)

    def test_disconnect_while_connecting(self):
        self.enable()
        path = self.ok(self.f.modem, E.IFACE_MODEM, "CreateBearer", {"apn": "a"})
        bearer = self.f.bearers[path]
        results = []
        self.f.call(bearer, E.IFACE_BEARER, "Connect", [], lambda ok, r: results.append(("connect", ok)))
        self.f.call(bearer, E.IFACE_BEARER, "Disconnect", [], lambda ok, r: results.append(("disconnect", ok)))
        self.loop.run_until(lambda: len(results) == 2, 2)
        self.assertEqual(results, [("connect", True), ("disconnect", True)])
        self.assertFalse(bearer.get(E.IFACE_BEARER, "Connected"))
        self.assertIn("data_disconnect", self.core.calls_log)

    def test_radio_off_drops_bearer(self):
        path = self.ok(self.f.modem, E.IFACE_SIMPLE, "Connect", {"apn": "test"})
        self.ok(self.f.modem, E.IFACE_MODEM, "Enable", False)
        self.settle()
        self.assertFalse(self.f.bearers[path].get(E.IFACE_BEARER, "Connected"))
        self.assertEqual(self.state, E.STATE_DISABLED)


class Messaging(Base):
    def setUp(self):
        self.stored = None
        super().setUp()

    def test_stored_and_received(self):
        # FakeCore starts with an empty store here: inject one and check Added(received=true)
        index = self.core.inject_sms(text="fake text")
        self.settle()
        added = self.sink.signals("Added")
        self.assertEqual(len(added), 1)
        path, received = added[0][4:]
        self.assertTrue(received)
        sms = self.f.messages[path]
        self.assertEqual(sms.index, index)
        s = sms.props[E.IFACE_SMS]
        self.assertEqual((s["PduType"], s["State"]), (E.PDU_DELIVER, E.SMS_RECEIVED))
        self.assertEqual(s["Number"], F.FAKE_PEER)
        self.assertEqual(s["Text"], "fake text")
        self.assertEqual(s["Timestamp"], "2026-01-01T12:00:00+00:00")
        self.assertEqual(self.ok(self.f.modem, E.IFACE_MESSAGING, "List"), [path])
        self.ok(self.f.modem, E.IFACE_MESSAGING, "Delete", path)
        self.assertIn("delete_sms", self.core.calls_log)
        self.assertEqual(self.sink.signals("Deleted")[0][4], path)
        self.assertEqual(self.mprop(E.IFACE_MESSAGING, "Messages"), [])

    def test_create_and_send(self):
        self.enable()
        path = self.ok(self.f.modem, E.IFACE_MESSAGING, "Create", {"number": F.FAKE_PEER, "text": "hi"})
        sms = self.f.messages[path]
        self.assertEqual(sms.get(E.IFACE_SMS, "State"), E.SMS_UNKNOWN)
        self.assertEqual(sms.get(E.IFACE_SMS, "PduType"), E.PDU_SUBMIT)
        self.assertEqual(self.sink.signals("Added")[-1][4:], (path, False))
        self.ok(sms, E.IFACE_SMS, "Send")
        self.assertEqual(sms.get(E.IFACE_SMS, "State"), E.SMS_SENT)
        self.assertEqual(sms.get(E.IFACE_SMS, "MessageReference"), 1)
        self.core.emit("sms-status-report", {"ref": 1, "status": 0, "delivered": True})
        self.settle()
        self.assertEqual(sms.get(E.IFACE_SMS, "DeliveryState"), 0)
        self.ok(self.f.modem, E.IFACE_MESSAGING, "Delete", path)
        self.assertNotIn("delete_sms", self.core.calls_log)       # local message

    def test_delivery_report_reaches_the_core(self):
        self.enable()
        for wanted in (True, False):
            path = self.ok(self.f.modem, E.IFACE_MESSAGING, "Create",
                           {"number": F.FAKE_PEER, "text": "hi", "delivery-report-request": wanted})
            self.ok(self.f.messages[path], E.IFACE_SMS, "Send")
            self.assertIs(self.core.last_status_report, wanted)

    def test_send_failure_restores_state(self):
        self.enable()
        path = self.ok(self.f.modem, E.IFACE_MESSAGING, "Create", {"number": F.FAKE_PEER, "text": "hi"})
        self.core.fail["send_sms"] = "SMS rejected (ack 0x8001)"
        self.err(self.f.messages[path], E.IFACE_SMS, "Send")
        self.assertEqual(self.f.messages[path].get(E.IFACE_SMS, "State"), E.SMS_UNKNOWN)

    def test_send_requires_enabled(self):
        path = self.ok(self.f.modem, E.IFACE_MESSAGING, "Create", {"number": F.FAKE_PEER, "text": "hi"})
        self.assertEqual(self.err(self.f.messages[path], E.IFACE_SMS, "Send").name, E.ERR_WRONG_STATE)

    def test_create_validation(self):
        m = self.f.modem
        self.assertEqual(self.err(m, E.IFACE_MESSAGING, "Create", {"text": "x"}).name, E.ERR_INVALID_ARGS)
        self.assertEqual(self.err(m, E.IFACE_MESSAGING, "Create", {"number": "abc", "text": "x"}).name,
                         E.ERR_INVALID_ARGS)
        self.assertEqual(self.err(m, E.IFACE_MESSAGING, "Create", {"number": F.FAKE_PEER, "data": [1]}).name,
                         E.ERR_UNSUPPORTED)
        self.assertEqual(self.err(m, E.IFACE_MESSAGING, "Delete", E.SMS_PREFIX + "99").name, E.ERR_NOT_FOUND)


class StoredSms(Base):
    def setUp(self):
        logging.getLogger("shannond").setLevel(logging.CRITICAL)
        self.loop = SelectorLoop()
        self.core = FakeCore(self.loop, delay=0.001)
        self.core.store_sms(text="old")
        self.sink = Recorder()
        self.f = Facade(self.core, self.loop, sink=self.sink, net_ports=["rmnet0"])
        self.f.start()
        self.settle()

    def test_loaded_once(self):
        added = self.sink.signals("Added")
        self.assertEqual(len(added), 1)
        self.assertFalse(added[0][5])
        self.core.push_state()
        self.settle()
        self.assertEqual(self.core.calls_log.count("list_sms"), 1)
        self.assertEqual(len(self.f.messages), 1)


class Voice(Base):
    def test_outgoing(self):
        self.enable()
        path = self.ok(self.f.modem, E.IFACE_VOICE, "CreateCall", {"number": F.FAKE_PEER})
        call = self.f.calls[path]
        self.assertEqual(self.sink.signals("CallAdded")[0][4], path)
        self.assertEqual(call.get(E.IFACE_CALL, "Direction"), E.DIRECTION_OUTGOING)
        self.assertEqual(call.state, E.CALL_UNKNOWN)
        self.ok(call, E.IFACE_CALL, "Start")
        self.loop.run_until(lambda: call.state == E.CALL_ACTIVE, 2)
        transitions = [e[5] for e in self.sink.signals("StateChanged") if e[1] == path]
        self.assertEqual(transitions, [E.CALL_DIALING, E.CALL_RINGING_OUT, E.CALL_ACTIVE])
        self.assertEqual(self.err(call, E.IFACE_CALL, "Start").name, E.ERR_WRONG_STATE)
        self.ok(call, E.IFACE_CALL, "SendDtmf", "12#")
        self.assertEqual(self.err(call, E.IFACE_CALL, "SendDtmf", "x").name, E.ERR_INVALID_ARGS)
        self.ok(call, E.IFACE_CALL, "Hangup")
        self.assertEqual(call.state, E.CALL_TERMINATED)
        self.assertEqual(call.get(E.IFACE_CALL, "StateReason"), E.REASON_TERMINATED)
        self.ok(self.f.modem, E.IFACE_VOICE, "DeleteCall", path)
        self.assertEqual(self.sink.signals("CallDeleted")[0][4], path)
        self.assertEqual(self.mprop(E.IFACE_VOICE, "Calls"), [])

    def test_incoming(self):
        self.enable()
        self.core.incoming_call()
        self.settle()
        path = self.sink.signals("CallAdded")[0][4]
        call = self.f.calls[path]
        self.assertEqual(call.get(E.IFACE_CALL, "Direction"), E.DIRECTION_INCOMING)
        self.assertEqual(call.state, E.CALL_RINGING_IN)
        self.assertEqual(call.get(E.IFACE_CALL, "StateReason"), E.REASON_INCOMING_NEW)
        self.assertEqual(call.get(E.IFACE_CALL, "Number"), F.FAKE_PEER)
        self.ok(call, E.IFACE_CALL, "Accept")
        self.assertEqual(call.state, E.CALL_ACTIVE)
        self.core.emit("audio", {"open": True, "rate": 16000})
        self.settle()
        self.assertEqual(call.get(E.IFACE_CALL, "AudioFormat")["rate"], Variant("u", 16000))
        self.core.remote_hangup(call.core_id, reason="user busy")
        self.settle()
        self.assertEqual(call.state, E.CALL_TERMINATED)
        self.assertEqual(call.get(E.IFACE_CALL, "StateReason"), E.REASON_REFUSED_OR_BUSY)

    def test_hangup_before_dial_returns(self):
        self.enable()
        path = self.ok(self.f.modem, E.IFACE_VOICE, "CreateCall", {"number": F.FAKE_PEER})
        call = self.f.calls[path]
        results = []
        self.f.call(call, E.IFACE_CALL, "Start", [], lambda ok, r: results.append(("start", ok)))
        self.f.call(call, E.IFACE_CALL, "Hangup", [], lambda ok, r: results.append(("hangup", ok)))
        self.loop.run_until(lambda: len(results) == 2, 2)
        self.assertEqual(sorted(results), [("hangup", True), ("start", True)])
        self.assertEqual(call.state, E.CALL_TERMINATED)
        self.assertIn("hangup", self.core.calls_log)

    def test_hangup_all_and_accept_waiting(self):
        self.enable()
        self.core.incoming_call()
        self.settle()
        first = self.f.calls[self.sink.signals("CallAdded")[0][4]]
        self.ok(first, E.IFACE_CALL, "Accept")
        self.core.incoming_call()
        self.settle()
        second = self.f.calls[self.sink.signals("CallAdded")[1][4]]
        self.ok(self.f.modem, E.IFACE_VOICE, "HangupAndAccept")
        self.assertEqual(first.state, E.CALL_TERMINATED)
        self.assertEqual(second.state, E.CALL_ACTIVE)
        self.ok(self.f.modem, E.IFACE_VOICE, "HangupAll")
        self.assertEqual(second.state, E.CALL_TERMINATED)
        self.assertEqual(self.err(self.f.modem, E.IFACE_VOICE, "HoldAndAccept").name, E.ERR_UNSUPPORTED)

    def test_start_requires_enabled(self):
        path = self.ok(self.f.modem, E.IFACE_VOICE, "CreateCall", {"number": F.FAKE_PEER})
        self.assertEqual(self.err(self.f.calls[path], E.IFACE_CALL, "Start").name, E.ERR_WRONG_STATE)
        self.assertEqual(self.err(self.f.modem, E.IFACE_VOICE, "CreateCall", {"number": ""}).name,
                         E.ERR_INVALID_ARGS)

    def test_terminated_calls_expire(self):
        self.f.opts.terminated_call_ttl = 0.05
        self.enable()
        self.core.incoming_call()
        self.settle()
        path = self.sink.signals("CallAdded")[0][4]
        self.core.remote_hangup(self.f.calls[path].core_id)
        self.loop.run_for(0.2)
        self.assertNotIn(path, self.f.calls)
        self.assertEqual(self.sink.signals("CallDeleted")[0][4], path)


class Crash(Base):
    def test_crash_and_recovery(self):
        path = self.ok(self.f.modem, E.IFACE_SIMPLE, "Connect", {"apn": "test"})
        self.core.incoming_call()
        self.settle()
        call = self.f.calls[self.sink.signals("CallAdded")[0][4]]
        self.core.crash()
        self.settle()
        self.assertEqual(self.state, E.STATE_FAILED)
        self.assertEqual(self.mprop(E.IFACE_MODEM, "StateFailedReason"), E.FAILED_UNKNOWN)
        self.assertEqual(call.state, E.CALL_TERMINATED)
        self.assertEqual(call.get(E.IFACE_CALL, "StateReason"), E.REASON_ERROR)
        self.assertFalse(self.f.bearers[path].get(E.IFACE_BEARER, "Connected"))
        failure = [e for e in self.sink.signals("StateChanged") if e[1] == self.f.modem.path][-1]
        self.assertEqual(failure[4:], (E.STATE_CONNECTED, E.STATE_FAILED, E.CHANGE_FAILURE))
        self.assertEqual(self.err(self.f.modem, E.IFACE_MODEM, "Enable", True).name, E.ERR_WRONG_STATE)
        self.core.recover()
        self.settle()
        self.assertEqual(self.state, E.STATE_DISABLED)
        self.assertEqual(self.core.calls_log.count("query_identity"), 2)   # new CP session
        self.enable()


class IdentityPolicies(Base):
    facade_kw = {"identity": "on-demand"}

    def test_on_demand(self):
        self.assertNotIn("query_identity", self.core.calls_log)
        self.assertEqual(self.mprop(E.IFACE_3GPP, "Imei"), "")
        self.f.note_read(self.f.modem, E.IFACE_3GPP)
        self.settle()
        self.assertEqual(self.mprop(E.IFACE_3GPP, "Imei"), F.FAKE_IMEI)
        self.f.note_read(self.f.modem, E.IFACE_3GPP)
        self.settle()
        self.assertEqual(self.core.calls_log.count("query_identity"), 1)


class IdentityNever(Base):
    facade_kw = {"identity": "never"}

    def test_never(self):
        self.f.note_read(self.f.modem, E.IFACE_MODEM)
        self.settle()
        self.assertNotIn("query_identity", self.core.calls_log)
        self.assertEqual(self.mprop(E.IFACE_MODEM, "EquipmentIdentifier"), "")


class CoreContract(unittest.TestCase):
    """The facade's expectations against the real shannond.core.ModemCore, when present."""

    COMMANDS = {"radio_on": 0, "radio_off": 0, "enter_pin": 1, "send_sms": 2, "list_sms": 0, "delete_sms": 1,
                "dial": 1, "answer": 1, "hangup": 1, "send_dtmf": 2, "data_connect": 4, "data_disconnect": 0,
                "query_identity": 0}

    def check(self, cls):
        self.assertTrue(callable(getattr(cls, "subscribe", None)))
        for name, nargs in self.COMMANDS.items():
            fn = getattr(cls, name, None)
            self.assertTrue(callable(fn), name)
            params = inspect.signature(fn).parameters
            self.assertIn("done", params, name)
            positional = [p for p in params.values() if p.name not in ("self", "done")
                          and p.kind in (p.POSITIONAL_ONLY, p.POSITIONAL_OR_KEYWORD)]
            self.assertGreaterEqual(len(positional), nargs, name)
        if "auth" not in inspect.signature(cls.data_connect).parameters:
            self.fail("data_connect has no auth keyword")

    def test_fake_core(self):
        self.check(FakeCore)

    def test_real_core(self):
        try:
            from shannond.core import ModemCore
        except ImportError as exc:  # pragma: no cover - core delivered separately
            self.skipTest("shannond.core not importable: %s" % exc)
        self.check(ModemCore)

    def test_subscribe_returning_unsubscribe(self):
        loop = SelectorLoop()
        core = FakeCore(loop, delay=0)
        removed = []
        original = core.subscribe

        def subscribe(cb):
            original(cb)
            return lambda: removed.append(cb)
        core.subscribe = subscribe
        f = Facade(core, loop, net_ports=["rmnet0"])
        f.start()
        f.stop()
        self.assertEqual(len(removed), 1)


class Privacy(Base):
    SECRETS = (F.FAKE_PEER, F.FAKE_IMSI, F.FAKE_ICCID, F.FAKE_OWN_NUMBER, "1234", "secret-text",
               "pw-value")

    def test_logs_carry_no_identifier(self):
        stream = io.StringIO()
        handler = logging.StreamHandler(stream)
        logger = logging.getLogger("shannond")
        logger.addHandler(handler)
        logger.setLevel(logging.DEBUG)
        try:
            self.core.state["sim"].update(state="locked")
            self.core.push_state()
            self.settle()
            self.ok(self.f.sim, E.IFACE_SIM, "SendPin", "1234")
            self.settle()
            self.ok(self.f.modem, E.IFACE_SIMPLE, "Connect", {"apn": "test", "user": "u", "password": "pw-value"})
            path = self.ok(self.f.modem, E.IFACE_MESSAGING, "Create", {"number": F.FAKE_PEER, "text": "secret-text"})
            self.ok(self.f.messages[path], E.IFACE_SMS, "Send")
            self.core.inject_sms(text="secret-text")
            self.core.incoming_call()
            self.settle()
            call = self.ok(self.f.modem, E.IFACE_VOICE, "CreateCall", {"number": F.FAKE_PEER})
            self.ok(self.f.calls[call], E.IFACE_CALL, "Start")
            self.settle(0.1)
        finally:
            logger.removeHandler(handler)
            logger.setLevel(logging.CRITICAL)
        text = stream.getvalue()
        self.assertIn("SMS", text)                       # the scenario did log
        for secret in self.SECRETS:
            self.assertNotIn(secret, text)

    def test_no_real_identifiers_in_files(self):
        allowed_digits = {F.FAKE_IMEI, F.FAKE_IMSI, F.FAKE_ICCID, "001001000000001"}
        files = []
        for base, names in ((os.path.join(PKG_ROOT, "shannond", "mm"), None), (os.path.join(PKG_ROOT, "tests"),
                                                                             "test_mm"),
                            (os.path.join(PKG_ROOT, "dbus"), None), (PKG_ROOT, "README-mm")):
            if not os.path.isdir(base):
                continue
            for name in os.listdir(base):
                if names and not name.startswith(names):
                    continue
                if name.endswith((".py", ".md", ".conf")):
                    files.append(os.path.join(base, name))
        self.assertTrue(files)
        for path in files:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
            for run in re.findall(r"(?<![\d.])\d{14,20}(?![\d.])", text):
                self.assertIn(run, allowed_digits, "%s: long digit run %s" % (path, run))
            for number in re.findall(r"\+\d{8,15}", text):
                self.assertRegex(number, r"^\+1555555\d{4}$", "%s: phone number %s" % (path, number))


if __name__ == "__main__":
    unittest.main()
