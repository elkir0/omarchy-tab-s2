# SPDX-License-Identifier: GPL-2.0-or-later
"""Unit tests of the python-dbus glue (typing, introspection); need python-dbus, no bus."""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

try:
    import dbus
    import dbus.service  # noqa: F401  (a bare "dbus" may be the policy directory)
    HAVE_DBUS = True
except ImportError:
    HAVE_DBUS = False

from shannond.mm import enums as E  # noqa: E402
from shannond.mm.spec import Variant  # noqa: E402


@unittest.skipUnless(HAVE_DBUS, "python-dbus not installed")
class Typing(unittest.TestCase):
    def setUp(self):
        from shannond.mm import service
        self.s = service

    def test_scalars(self):
        to = self.s.to_dbus
        self.assertIsInstance(to("u", 3), dbus.UInt32)
        self.assertIsInstance(to("i", -1), dbus.Int32)
        self.assertIsInstance(to("b", True), dbus.Boolean)
        self.assertIsInstance(to("o", "/x"), dbus.ObjectPath)
        self.assertIsInstance(to("s", "x"), dbus.String)

    def test_containers(self):
        to = self.s.to_dbus
        ports = to("a(su)", [("umts_ipc0", 9), ("rmnet0", 2)])
        self.assertEqual(ports.signature, "(su)")
        self.assertIsInstance(ports[0][1], dbus.UInt32)
        empty = to("ao", [])
        self.assertEqual(empty.signature, "o")
        retries = to("a{uu}", {2: 3})
        self.assertEqual(retries.signature, "uu")

    def test_variants(self):
        to = self.s.to_dbus
        cfg = to("a{sv}", {"method": Variant("u", 2), "address": Variant("s", "192.0.2.10")})
        self.assertEqual(cfg.signature, "sv")
        self.assertIsInstance(cfg["method"], dbus.UInt32)
        self.assertEqual(cfg["method"].variant_level, 1)
        validity = to("(uv)", (0, Variant("b", False)))
        self.assertEqual(validity.signature, "uv")
        self.assertEqual(validity[1].variant_level, 1)   # keeps (uv) when guessed inside a variant
        with self.assertRaises(TypeError):
            to("v", 3)

    def test_marshalling_roundtrip(self):
        # Serialise through libdbus to catch signature mistakes.
        from dbus.lowlevel import SignalMessage
        reply = SignalMessage("/org/example", "org.example", "S")
        value = self.s.to_dbus("a{sv}", {"Validity": Variant("(uv)", (0, Variant("b", False))),
                                         "Ports": Variant("a(su)", [("rmnet0", 2)])})
        reply.append(value, signature="a{sv}")
        self.assertEqual(reply.get_signature(), "a{sv}")
        back = reply.get_args_list()[0]
        self.assertEqual(self.s.from_dbus(back["Ports"]), [("rmnet0", 2)])
        self.assertEqual(self.s.from_dbus(back["Validity"]), (0, False))

    def test_from_dbus(self):
        plain = self.s.from_dbus(dbus.Dictionary({"apn": dbus.String("x", variant_level=1),
                                                  "allow-roaming": dbus.Boolean(False, variant_level=1),
                                                  "ip-type": dbus.UInt32(4, variant_level=1)}))
        self.assertEqual(plain, {"apn": "x", "allow-roaming": False, "ip-type": 4})
        self.assertIs(type(plain["allow-roaming"]), bool)

    def test_introspection_properties(self):
        xml = ('<node name="/x">\n  <interface name="%s">\n    <method name="Send">\n    </method>\n'
               '  </interface>\n</node>\n' % E.IFACE_SMS)
        out = self.s.add_properties_to_introspection(xml, [E.IFACE_SMS, E.IFACE_SIMPLE])
        self.assertIn('<property name="Validity" type="(uv)" access="read"/>', out)
        self.assertEqual(out.count("<interface "), 1)       # Simple has no properties


if __name__ == "__main__":
    unittest.main()
