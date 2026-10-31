# SPDX-License-Identifier: GPL-2.0-or-later
"""D-Bus property types of the interfaces shannon2mm exports.

Copied by hand from the ModemManager 1.24.2 introspection files
(``/usr/share/dbus-1/interfaces/org.freedesktop.ModemManager1.*.xml``);
``tests/test_mm_integration.py`` compares the live introspection of the
facade against those files.  Method and signal signatures live next to the
python-dbus decorators in ``service.py``.

The property tables drive three things: typing of the values handed to
python-dbus (``to_dbus``), ``GetAll``/``PropertiesChanged`` payloads, and
the ``<property>`` elements added to ``Introspect``.
"""

from . import enums as E

PROPERTIES = {
    E.IFACE_MANAGER: {
        "Version": "s",
    },
    E.IFACE_MODEM: {
        "Sim": "o",
        "SimSlots": "ao",
        "PrimarySimSlot": "u",
        "Bearers": "ao",
        "SupportedCapabilities": "au",
        "CurrentCapabilities": "u",
        "MaxBearers": "u",
        "MaxActiveBearers": "u",
        "MaxActiveMultiplexedBearers": "u",
        "Manufacturer": "s",
        "Model": "s",
        "Revision": "s",
        "CarrierConfiguration": "s",
        "CarrierConfigurationRevision": "s",
        "HardwareRevision": "s",
        "DeviceIdentifier": "s",
        "Device": "s",
        "Physdev": "s",
        "Drivers": "as",
        "Plugin": "s",
        "PrimaryPort": "s",
        "Ports": "a(su)",
        "EquipmentIdentifier": "s",
        "UnlockRequired": "u",
        "UnlockRetries": "a{uu}",
        "State": "i",
        "StateFailedReason": "u",
        "AccessTechnologies": "u",
        "SignalQuality": "(ub)",
        "OwnNumbers": "as",
        "PowerState": "u",
        "SupportedModes": "a(uu)",
        "CurrentModes": "(uu)",
        "SupportedBands": "au",
        "CurrentBands": "au",
        "SupportedIpFamilies": "u",
    },
    E.IFACE_SIMPLE: {},
    E.IFACE_3GPP: {
        "Imei": "s",
        "RegistrationState": "u",
        "NetworkRejection": "a{sv}",
        "OperatorCode": "s",
        "OperatorName": "s",
        "EnabledFacilityLocks": "u",
        "SubscriptionState": "u",
        "EpsUeModeOperation": "u",
        "Pco": "a(ubay)",
        "InitialEpsBearer": "o",
        "InitialEpsBearerSettings": "a{sv}",
        "PacketServiceState": "u",
        "Nr5gRegistrationSettings": "a{sv}",
    },
    E.IFACE_MESSAGING: {
        "Messages": "ao",
        "SupportedStorages": "au",
        "DefaultStorage": "u",
    },
    E.IFACE_VOICE: {
        "Calls": "ao",
        "EmergencyOnly": "b",
    },
    E.IFACE_SIM: {
        "Active": "b",
        "SimIdentifier": "s",
        "Imsi": "s",
        "Eid": "s",
        "OperatorIdentifier": "s",
        "OperatorName": "s",
        "EmergencyNumbers": "as",
        "PreferredNetworks": "a(su)",
        "Gid1": "ay",
        "Gid2": "ay",
        "SimType": "u",
        "EsimStatus": "u",
        "Removability": "u",
    },
    E.IFACE_BEARER: {
        "Interface": "s",
        "Connected": "b",
        "ConnectionError": "(ss)",
        "Suspended": "b",
        "Multiplexed": "b",
        "Ip4Config": "a{sv}",
        "Ip6Config": "a{sv}",
        "Stats": "a{sv}",
        "ReloadStatsSupported": "b",
        "IpTimeout": "u",
        "BearerType": "u",
        "ProfileId": "i",
        "Properties": "a{sv}",
    },
    E.IFACE_SMS: {
        "State": "u",
        "PduType": "u",
        "Number": "s",
        "Text": "s",
        "Data": "ay",
        "SMSC": "s",
        "Validity": "(uv)",
        "Class": "i",
        "TeleserviceId": "u",
        "ServiceCategory": "u",
        "DeliveryReportRequest": "b",
        "MessageReference": "u",
        "Timestamp": "s",
        "DischargeTimestamp": "s",
        "DeliveryState": "u",
        "Storage": "u",
    },
    E.IFACE_CALL: {
        "State": "i",
        "StateReason": "i",
        "Direction": "i",
        "Number": "s",
        "Multiparty": "b",
        "AudioPort": "s",
        "AudioFormat": "a{sv}",
    },
}

# Interfaces of the modem object, in the order ModemManager lists them.
MODEM_INTERFACES = (E.IFACE_MODEM, E.IFACE_SIMPLE, E.IFACE_3GPP, E.IFACE_MESSAGING, E.IFACE_VOICE)


class Variant:
    """A value with an explicit D-Bus signature, for ``v`` slots (a{sv})."""

    __slots__ = ("signature", "value")

    def __init__(self, signature, value):
        self.signature = signature
        self.value = value

    def __eq__(self, other):
        return (isinstance(other, Variant) and other.signature == self.signature
                and other.value == self.value)

    def __ne__(self, other):
        return not self == other

    def __hash__(self):
        return hash((self.signature, repr(self.value)))

    def __repr__(self):
        return "Variant(%r, %r)" % (self.signature, self.value)


def split_signature(sig):
    """Split a D-Bus signature into its complete types: 'a{sv}u' -> ['a{sv}', 'u']."""
    out = []
    i = 0
    while i < len(sig):
        j = _end_of_type(sig, i)
        out.append(sig[i:j])
        i = j
    return out


def _end_of_type(sig, i):
    c = sig[i]
    if c == "a":
        return _end_of_type(sig, i + 1)
    if c in "({":
        close = ")" if c == "(" else "}"
        depth = 0
        j = i
        while j < len(sig):
            if sig[j] in "({":
                depth += 1
            elif sig[j] in ")}":
                depth -= 1
                if depth == 0:
                    if sig[j] != close:
                        raise ValueError("bad signature %r" % sig)
                    return j + 1
            j += 1
        raise ValueError("unbalanced signature %r" % sig)
    if c in "ybnqiuxtdsogvh":
        return i + 1
    raise ValueError("bad signature character %r in %r" % (c, sig))


def check_value(sig, value):
    """Raise TypeError if ``value`` does not fit ``sig`` (plain Python model values)."""
    c = sig[0]
    if c == "b":
        if not isinstance(value, bool):
            raise TypeError("expected bool for %s, got %r" % (sig, value))
    elif c in "ynqiuxt":
        if isinstance(value, bool) or not isinstance(value, int):
            raise TypeError("expected int for %s, got %r" % (sig, value))
        lo, hi = _INT_RANGES[c]
        if not lo <= value <= hi:
            raise TypeError("value %r out of range for %s" % (value, sig))
    elif c == "d":
        if not isinstance(value, (int, float)) or isinstance(value, bool):
            raise TypeError("expected float for %s, got %r" % (sig, value))
    elif c in "sog":
        if not isinstance(value, str):
            raise TypeError("expected str for %s, got %r" % (sig, value))
        if c == "o" and not value.startswith("/"):
            raise TypeError("bad object path %r" % value)
    elif c == "v":
        if not isinstance(value, Variant):
            raise TypeError("expected Variant for v, got %r" % (value,))
        check_value(value.signature, value.value)
    elif c == "a":
        inner = sig[1:]
        if inner.startswith("{"):
            if not isinstance(value, dict):
                raise TypeError("expected dict for %s, got %r" % (sig, value))
            ktype, vtype = split_signature(inner[1:-1])
            for k, v in value.items():
                check_value(ktype, k)
                check_value(vtype, v)
        elif inner == "y" and isinstance(value, (bytes, bytearray)):
            return
        else:
            if not isinstance(value, (list, tuple)):
                raise TypeError("expected list for %s, got %r" % (sig, value))
            for v in value:
                check_value(inner, v)
    elif c == "(":
        parts = split_signature(sig[1:-1])
        if not isinstance(value, (list, tuple)) or len(value) != len(parts):
            raise TypeError("expected %d-tuple for %s, got %r" % (len(parts), sig, value))
        for p, v in zip(parts, value):
            check_value(p, v)
    else:
        raise TypeError("unsupported signature %r" % sig)


_INT_RANGES = {
    "y": (0, 0xFF),
    "n": (-0x8000, 0x7FFF),
    "q": (0, 0xFFFF),
    "i": (-0x80000000, 0x7FFFFFFF),
    "u": (0, 0xFFFFFFFF),
    "x": (-(1 << 63), (1 << 63) - 1),
    "t": (0, (1 << 64) - 1),
}
