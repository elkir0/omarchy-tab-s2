# SPDX-License-Identifier: GPL-2.0-or-later
"""Unit tests: core vocabulary -> ModemManager values (no bus, no core)."""

import datetime
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from shannond.mm import convert as C  # noqa: E402
from shannond.mm import enums as E  # noqa: E402
from shannond.mm import spec  # noqa: E402
from shannond.mm.spec import Variant  # noqa: E402


def state(**kw):
    st = {"cp": "online", "power": "on", "sim": {"state": "ready"},
          "reg": {"cs": "home", "ps": "home", "rat": "lte", "mcc": "001", "mnc": "01", "operator": "T"},
          "signal": {"percent": 50}}
    for key, value in kw.items():
        if isinstance(value, dict) and isinstance(st.get(key), dict):
            st[key] = dict(st[key], **value)
        else:
            st[key] = value
    return st


class Registration(unittest.TestCase):
    def test_combined(self):
        cases = [
            ({"cs": "home", "ps": "home"}, E.REG_HOME),
            ({"cs": "idle", "ps": "roaming"}, E.REG_ROAMING),
            ({"cs": "home", "ps": "searching"}, E.REG_HOME),
            ({"cs": "searching", "ps": "denied"}, E.REG_SEARCHING),
            ({"cs": "denied", "ps": "idle"}, E.REG_DENIED),
            ({"cs": "idle", "ps": "unknown"}, E.REG_IDLE),
            ({"cs": "unknown", "ps": "unknown"}, E.REG_UNKNOWN),
            ({}, E.REG_UNKNOWN),
            (None, E.REG_UNKNOWN),
        ]
        for reg, expected in cases:
            self.assertEqual(C.combined_registration(reg), expected, reg)

    def test_operator_code(self):
        self.assertEqual(C.operator_code({"mcc": "001", "mnc": "01"}), "00101")
        self.assertEqual(C.operator_code({"mcc": "001", "mnc": "001"}), "001001")
        self.assertEqual(C.operator_code({"mcc": 1, "mnc": 1}), "00101")
        self.assertEqual(C.operator_code({"mcc": None, "mnc": "01"}), "")
        self.assertEqual(C.operator_code({"mcc": "00x", "mnc": "01"}), "")

    def test_sim_operator_identifier(self):
        self.assertEqual(C.sim_operator_identifier("001010000000001", "00101"), "00101")
        self.assertEqual(C.sim_operator_identifier("001001000000001", "001001"), "001001")
        self.assertEqual(C.sim_operator_identifier("001010000000001", "99999"), "00101")
        self.assertEqual(C.sim_operator_identifier("", "00101"), "")


class ModemState(unittest.TestCase):
    def test_table(self):
        cases = [
            (state(cp="offline"), None, False, (E.STATE_INITIALIZING, E.FAILED_NONE)),
            (state(cp="crashed"), None, False, (E.STATE_FAILED, E.FAILED_UNKNOWN)),
            (state(sim={"state": "absent"}), None, False, (E.STATE_FAILED, E.FAILED_SIM_MISSING)),
            (state(sim={"state": "error"}), None, False, (E.STATE_FAILED, E.FAILED_SIM_ERROR)),
            (state(sim={"state": "locked", "lock": "sim-pin"}), None, False, (E.STATE_LOCKED, E.FAILED_NONE)),
            (state(sim={"state": "locked", "lock": "sim-pin2"}), None, False, (E.STATE_REGISTERED, E.FAILED_NONE)),
            (state(sim={"state": "unknown"}), None, False, (E.STATE_INITIALIZING, E.FAILED_NONE)),
            (state(power="lpm"), None, False, (E.STATE_DISABLED, E.FAILED_NONE)),
            (state(power="off"), "enabling", False, (E.STATE_ENABLING, E.FAILED_NONE)),
            (state(), "disabling", False, (E.STATE_DISABLING, E.FAILED_NONE)),
            (state(), None, True, (E.STATE_CONNECTED, E.FAILED_NONE)),
            (state(), "connecting", False, (E.STATE_CONNECTING, E.FAILED_NONE)),
            (state(), "disconnecting", True, (E.STATE_DISCONNECTING, E.FAILED_NONE)),
            (state(), None, False, (E.STATE_REGISTERED, E.FAILED_NONE)),
            (state(reg={"cs": "searching", "ps": "searching"}), None, False, (E.STATE_SEARCHING, E.FAILED_NONE)),
            (state(reg={"cs": "denied", "ps": "idle"}), None, False, (E.STATE_ENABLED, E.FAILED_NONE)),
            ({}, None, False, (E.STATE_INITIALIZING, E.FAILED_NONE)),
        ]
        for st, busy, connected, expected in cases:
            self.assertEqual(C.compute_state(st, busy, connected), expected, (st, busy, connected))

    def test_power_state(self):
        self.assertEqual(C.power_state(state(power="lpm")), E.POWER_LOW)
        self.assertEqual(C.power_state(state(power="on")), E.POWER_ON)
        self.assertEqual(C.power_state(state(power="off")), E.POWER_OFF)
        self.assertEqual(C.power_state(state(cp="offline")), E.POWER_UNKNOWN)
        self.assertEqual(C.power_state(state(cp="crashed")), E.POWER_OFF)

    def test_unlock(self):
        self.assertEqual(C.unlock_required(state()), E.LOCK_NONE)
        self.assertEqual(C.unlock_required(state(sim={"state": "locked", "lock": "sim-pin"})), E.LOCK_SIM_PIN)
        self.assertEqual(C.unlock_required(state(sim={"state": "locked", "lock": "sim-puk"})), E.LOCK_SIM_PUK)
        self.assertEqual(C.unlock_required(state(sim={"state": "locked", "lock": "ph-net-pin"})), 8)
        self.assertEqual(C.unlock_required(state(sim={"state": "locked", "pin_retries": 0, "puk_retries": 9})),
                         E.LOCK_SIM_PUK)
        self.assertEqual(C.unlock_required(state(sim={"state": "locked"})), E.LOCK_SIM_PIN)
        self.assertEqual(C.unlock_required(state(sim={"state": "absent"})), E.LOCK_UNKNOWN)
        self.assertEqual(C.unlock_retries(state(sim={"state": "locked", "pin_retries": 2, "puk_retries": None})),
                         {E.LOCK_SIM_PIN: 2})
        self.assertEqual(C.unlock_retries(state(sim={"pin_retries": True})), {})

    def test_access_and_signal(self):
        self.assertEqual(C.access_technologies(state(), True), E.ACCESS_LTE)
        self.assertEqual(C.access_technologies(state(reg={"rat": "umts"}), True), E.ACCESS_UMTS)
        self.assertEqual(C.access_technologies(state(reg={"rat": "gsm"}), True), E.ACCESS_GSM)
        self.assertEqual(C.access_technologies(state(), False), E.ACCESS_UNKNOWN)
        self.assertEqual(C.signal_quality(state()), (50, True))
        self.assertEqual(C.signal_quality(state(signal={"percent": 140})), (100, True))
        self.assertEqual(C.signal_quality(state(signal={"percent": -3})), (0, True))
        self.assertEqual(C.signal_quality(state(signal={"percent": None})), (0, False))
        self.assertEqual(C.signal_quality(state(power="lpm")), (0, False))


class DataPath(unittest.TestCase):
    def test_ip4_config(self):
        cfg = C.ip4_config({"address": "192.0.2.10", "prefix": 32, "gateway": None,
                            "dns": ["192.0.2.53", "0.0.0.0", "192.0.2.53", "198.51.100.1"], "mtu": 1400})
        self.assertEqual(cfg, {
            "method": Variant("u", E.IP_METHOD_STATIC), "address": Variant("s", "192.0.2.10"),
            "prefix": Variant("u", 32), "dns1": Variant("s", "192.0.2.53"), "dns2": Variant("s", "198.51.100.1"),
            "mtu": Variant("u", 1400)})
        spec.check_value("a{sv}", cfg)

    def test_ip4_defaults_and_invalid(self):
        cfg = C.ip4_config({"address": "192.0.2.7", "prefix": None, "gateway": "192.0.2.1"})
        self.assertEqual(cfg["prefix"], Variant("u", 32))
        self.assertEqual(cfg["gateway"], Variant("s", "192.0.2.1"))
        self.assertNotIn("mtu", cfg)
        self.assertEqual(C.ip4_config({"address": b"\xc0\x00\x02\x08"})["address"], Variant("s", "192.0.2.8"))
        self.assertEqual(C.ip4_config({"address": "0.0.0.0"}),C.ip_config_unknown())
        self.assertEqual(C.ip_config_unknown(), {"method": Variant("u", E.IP_METHOD_UNKNOWN)})
        self.assertEqual(C.ip4_config({"address": "2001:db8::1"}),C.ip_config_unknown())
        self.assertEqual(C.ip4_config({"address": "not-an-ip"}),C.ip_config_unknown())
        self.assertEqual(C.ip4_config(None),C.ip_config_unknown())

    def test_link_local(self):
        self.assertEqual(C.link_local_from({"address": "2001:db8::1:0:0:a"}), "fe80::1:0:0:a")
        self.assertEqual(C.link_local_from({"address": "2001:db8:1:2:a:b:c:d"}), "fe80::a:b:c:d")
        self.assertEqual(C.link_local_from({"iid": "0011:2233:4455:6677"}), "fe80::11:2233:4455:6677")
        self.assertEqual(C.link_local_from({"iid": 0x1234}), "fe80::1234")
        self.assertEqual(C.link_local_from({"iid": bytes(range(1, 9))}), "fe80::102:304:506:708")
        self.assertIsNone(C.link_local_from({"address": "2001:db8::"}))
        self.assertIsNone(C.link_local_from({}))

    def test_ip6_config(self):
        cfg = C.ip6_config({"address": "2001:db8::1:0:0:a", "prefix": 64, "dns": ["2001:db8::53"], "mtu": 1500})
        self.assertEqual(cfg["method"], Variant("u", E.IP_METHOD_DHCP))
        self.assertEqual(cfg["address"], Variant("s", "fe80::1:0:0:a"))
        self.assertEqual(cfg["prefix"], Variant("u", 64))
        self.assertEqual(cfg["dns1"], Variant("s", "2001:db8::53"))
        self.assertEqual(C.ip6_config({"dns": []}), {"method": Variant("u", E.IP_METHOD_DHCP)})
        self.assertEqual(C.ip6_config(None),C.ip_config_unknown())

    def test_interface_and_types(self):
        self.assertEqual(C.data_interface({"interface": "rmnet2"}), "rmnet2")
        self.assertEqual(C.data_interface({"cid": 1}), "rmnet0")
        self.assertEqual(C.data_interface({"cid": 4}), "rmnet3")
        self.assertEqual(C.data_interface({"cid": 0}), "")
        self.assertEqual(C.core_ip_type(E.IP_FAMILY_IPV4), "ipv4")
        self.assertEqual(C.core_ip_type(E.IP_FAMILY_IPV6), "ipv6")
        self.assertEqual(C.core_ip_type(E.IP_FAMILY_IPV4V6), "ipv4v6")
        self.assertEqual(C.core_ip_type(E.IP_FAMILY_NONE), "ipv4v6")
        self.assertEqual(C.core_ip_type(E.IP_FAMILY_ANY), "ipv4v6")
        self.assertIsNone(C.core_auth(None))
        self.assertEqual(C.core_auth(E.AUTH_PAP), "pap")
        self.assertEqual(C.core_auth(E.AUTH_CHAP), "chap")
        self.assertEqual(C.core_auth(E.AUTH_PAP | E.AUTH_CHAP), "pap-chap")
        self.assertEqual(C.core_auth(E.AUTH_NONE), "none")


class SmsAndCalls(unittest.TestCase):
    def test_timestamp(self):
        self.assertEqual(C.sms_timestamp("2026-01-01T12:00:00+01:00"), "2026-01-01T12:00:00+01:00")
        aware = datetime.datetime(2026, 1, 1, 12, 0, 0, tzinfo=datetime.timezone(datetime.timedelta(hours=2)))
        self.assertEqual(C.sms_timestamp(aware), "2026-01-01T12:00:00+02:00")
        self.assertRegex(C.sms_timestamp(0), r"^19(69|70)-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d$")
        self.assertEqual(C.sms_timestamp(None), "")

    def test_call_mapping(self):
        self.assertEqual(C.call_state("dialing"), E.CALL_DIALING)
        self.assertEqual(C.call_state("alerting"), E.CALL_RINGING_OUT)
        self.assertEqual(C.call_state("incoming"), E.CALL_RINGING_IN)
        self.assertEqual(C.call_state("waiting"), E.CALL_WAITING)
        self.assertEqual(C.call_state("held"), E.CALL_HELD)
        self.assertEqual(C.call_state("released"), E.CALL_TERMINATED)
        self.assertEqual(C.call_state("bogus"), E.CALL_UNKNOWN)
        self.assertEqual(C.call_reason("released", "user busy"), E.REASON_REFUSED_OR_BUSY)
        self.assertEqual(C.call_reason("released", "modem crashed"), E.REASON_ERROR)
        self.assertEqual(C.call_reason("released", None), E.REASON_TERMINATED)
        self.assertEqual(C.call_reason("active", None), E.REASON_ACCEPTED)
        self.assertEqual(C.call_reason("incoming", None), E.REASON_INCOMING_NEW)
        self.assertEqual(C.call_reason("alerting", None), E.REASON_OUTGOING_STARTED)
        self.assertEqual(C.call_reason("held", None, E.REASON_ACCEPTED), E.REASON_ACCEPTED)

    def test_validation(self):
        self.assertTrue(C.valid_pin("1234"))
        self.assertTrue(C.valid_pin("12345678"))
        self.assertFalse(C.valid_pin("123"))
        self.assertFalse(C.valid_pin("12a4"))
        self.assertTrue(C.valid_number("+15555550123"))
        self.assertTrue(C.valid_number("*100#"))
        self.assertFalse(C.valid_number("+"))
        self.assertFalse(C.valid_number("555 0123"))
        self.assertFalse(C.valid_number(None))


class Signatures(unittest.TestCase):
    def test_split(self):
        self.assertEqual(spec.split_signature("a{sv}u(ub)as"), ["a{sv}", "u", "(ub)", "as"])
        self.assertEqual(spec.split_signature("a{oa{sa{sv}}}"), ["a{oa{sa{sv}}}"])
        self.assertEqual(spec.split_signature("a(ubay)"), ["a(ubay)"])
        with self.assertRaises(ValueError):
            spec.split_signature("(u")

    def test_check_value(self):
        spec.check_value("(ub)", (5, True))
        spec.check_value("a(su)", [("rmnet0", 2)])
        spec.check_value("a{uu}", {2: 3})
        spec.check_value("(uv)", (0, Variant("b", False)))
        for sig, bad in (("u", -1), ("u", True), ("b", 1), ("i", 1 << 31), ("o", "x"), ("(ub)", (1,)),
                         ("a{sv}", {"k": 1}), ("v", 3)):
            with self.assertRaises(TypeError, msg=(sig, bad)):
                spec.check_value(sig, bad)

    def test_property_tables(self):
        for iface, table in spec.PROPERTIES.items():
            for name, sig in table.items():
                self.assertEqual(spec.split_signature(sig), [sig], (iface, name))


if __name__ == "__main__":
    unittest.main()
