# SPDX-License-Identifier: GPL-2.0-or-later
"""Pure conversions from the shannond core vocabulary to ModemManager values.

Nothing here touches D-Bus or the core object, so every rule can be unit
tested on any machine.
"""

import datetime
import ipaddress

from . import enums as E
from .spec import Variant

# Modem state -------------------------------------------------------------


def combined_registration(reg):
    """One MMModem3gppRegistrationState from the core's CS and PS domains.

    A registered PS domain wins (data is what NetworkManager needs), then a
    registered CS domain; otherwise the most informative of searching,
    denied, idle; else unknown.
    """
    reg = reg or {}
    ps = E.REG_FROM_CORE.get(reg.get("ps"), E.REG_UNKNOWN)
    cs = E.REG_FROM_CORE.get(reg.get("cs"), E.REG_UNKNOWN)
    for value in (ps, cs):
        if value in (E.REG_HOME, E.REG_ROAMING):
            return value
    for wanted in (E.REG_SEARCHING, E.REG_DENIED, E.REG_IDLE):
        if wanted in (ps, cs):
            return wanted
    return E.REG_UNKNOWN


def is_registered(reg_state):
    return reg_state in (E.REG_HOME, E.REG_ROAMING)


def sim_state(st):
    """Core SIM state, with a PIN2 lock counted as ready (it blocks nothing, as in MM)."""
    sim = (st or {}).get("sim") or {}
    state = sim.get("state") or "unknown"
    if state == "locked" and sim.get("lock") in ("sim-pin2", "sim-puk2"):
        return "ready"
    return state


def compute_state(st, busy=None, connected=False):
    """Return (MMModemState, MMModemStateFailedReason) for a core state.

    ``busy`` is the operation the facade has in flight: 'enabling',
    'disabling', 'connecting' or 'disconnecting'; ``connected`` tells whether
    a bearer is up.
    """
    st = st or {}
    cp = st.get("cp")
    if cp == "crashed":
        return E.STATE_FAILED, E.FAILED_UNKNOWN
    if cp != "online":
        return E.STATE_INITIALIZING, E.FAILED_NONE
    sim = sim_state(st)
    if sim == "absent":
        return E.STATE_FAILED, E.FAILED_SIM_MISSING
    if sim == "error":
        return E.STATE_FAILED, E.FAILED_SIM_ERROR
    if sim == "locked":
        return E.STATE_LOCKED, E.FAILED_NONE
    if sim != "ready":
        return E.STATE_INITIALIZING, E.FAILED_NONE
    if busy == "disabling":
        return E.STATE_DISABLING, E.FAILED_NONE
    if st.get("power") != "on":
        if busy == "enabling":
            return E.STATE_ENABLING, E.FAILED_NONE
        return E.STATE_DISABLED, E.FAILED_NONE
    if busy == "disconnecting":
        return E.STATE_DISCONNECTING, E.FAILED_NONE
    if connected:
        return E.STATE_CONNECTED, E.FAILED_NONE
    if busy == "connecting":
        return E.STATE_CONNECTING, E.FAILED_NONE
    reg = combined_registration(st.get("reg"))
    if is_registered(reg):
        return E.STATE_REGISTERED, E.FAILED_NONE
    if reg == E.REG_SEARCHING:
        return E.STATE_SEARCHING, E.FAILED_NONE
    return E.STATE_ENABLED, E.FAILED_NONE


def power_state(st):
    st = st or {}
    if st.get("cp") != "online":
        return E.POWER_UNKNOWN if st.get("cp") != "crashed" else E.POWER_OFF
    return E.POWER_FROM_CORE.get(st.get("power"), E.POWER_UNKNOWN)


LOCK_FROM_CORE = {
    "sim-pin": E.LOCK_SIM_PIN,
    "sim-puk": E.LOCK_SIM_PUK,
    "ph-net-pin": 8,      # MM_MODEM_LOCK_PH_NET_PIN
    "ph-netsub-pin": 15,  # MM_MODEM_LOCK_PH_NETSUB_PIN
    "ph-sp-pin": 6,       # MM_MODEM_LOCK_PH_SP_PIN
    "ph-corp-pin": 11,    # MM_MODEM_LOCK_PH_CORP_PIN
}


def unlock_required(st):
    sim = (st or {}).get("sim") or {}
    state = sim_state(st)
    if state == "ready":
        return E.LOCK_NONE
    if state == "locked":
        lock = sim.get("lock")
        if lock in LOCK_FROM_CORE:
            return LOCK_FROM_CORE[lock]
        if lock == "blocked":
            return E.LOCK_UNKNOWN
        if sim.get("pin_retries") == 0 and sim.get("puk_retries"):
            return E.LOCK_SIM_PUK
        return E.LOCK_SIM_PIN
    return E.LOCK_UNKNOWN


def unlock_retries(st):
    sim = (st or {}).get("sim") or {}
    out = {}
    for key, lock in (("pin_retries", E.LOCK_SIM_PIN), ("puk_retries", E.LOCK_SIM_PUK)):
        value = sim.get(key)
        if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
            out[lock] = value
    return out


def access_technologies(st, registered):
    if not registered:
        return E.ACCESS_UNKNOWN
    rat = ((st or {}).get("reg") or {}).get("rat")
    return E.ACCESS_FROM_RAT.get(rat, E.ACCESS_UNKNOWN)


def signal_quality(st):
    st = st or {}
    if st.get("cp") != "online" or st.get("power") != "on":
        return (0, False)
    percent = (st.get("signal") or {}).get("percent")
    if not isinstance(percent, (int, float)) or isinstance(percent, bool):
        return (0, False)
    return (int(max(0, min(100, round(percent)))), True)


def operator_code(reg):
    """'MCCMNC' string; integer MNCs are printed on two digits (three need a string)."""
    reg = reg or {}
    mcc, mnc = reg.get("mcc"), reg.get("mnc")
    if mcc is None or mnc is None or mcc == "" or mnc == "":
        return ""
    mcc_s = "%03d" % mcc if isinstance(mcc, int) else str(mcc)
    mnc_s = "%02d" % mnc if isinstance(mnc, int) else str(mnc)
    if not (mcc_s + mnc_s).isdigit():
        return ""
    return mcc_s + mnc_s


def sim_operator_identifier(imsi, registered_code):
    """MCCMNC of the SIM: the registered code when the IMSI starts with it, else 5 digits."""
    if not imsi or not str(imsi).isdigit():
        return ""
    imsi = str(imsi)
    if registered_code and imsi.startswith(registered_code):
        return registered_code
    return imsi[:5]


# Data path ---------------------------------------------------------------


def _ip_text(value, version):
    if value is None or value == "":
        return None
    try:
        if isinstance(value, (bytes, bytearray)):
            addr = ipaddress.ip_address(bytes(value))
        elif isinstance(value, int) and not isinstance(value, bool):
            addr = ipaddress.IPv4Address(value) if version == 4 else ipaddress.IPv6Address(value)
        else:
            addr = ipaddress.ip_address(str(value).split("/")[0])
    except ValueError:
        return None
    if addr.version != version or addr.is_unspecified:
        return None
    return str(addr)


def _uint(value, default=None):
    if isinstance(value, bool):
        return default
    try:
        value = int(value)
    except (TypeError, ValueError):
        return default
    return value if 0 <= value <= 0xFFFFFFFF else default


def _dns_list(cfg, version):
    raw = cfg.get("dns") or []
    if isinstance(raw, (str, bytes, bytearray)):
        raw = [raw]
    out = []
    for item in raw:
        text = _ip_text(item, version)
        if text and text not in out:
            out.append(text)
    return out


def ip_config_unknown():
    """What ModemManager publishes for an unconfigured family (libmm-glib needs 'method')."""
    return {"method": Variant("u", E.IP_METHOD_UNKNOWN)}


def ip4_config(ipv4):
    """Bearer Ip4Config for a core 'ipv4' dict: method STATIC, address/prefix, DNS, MTU."""
    if not ipv4:
        return ip_config_unknown()
    address = _ip_text(ipv4.get("address"), 4)
    if not address:
        return ip_config_unknown()
    prefix = _uint(ipv4.get("prefix"), 32)
    if prefix is None or not 1 <= prefix <= 32:
        prefix = 32
    out = {
        "method": Variant("u", E.IP_METHOD_STATIC),
        "address": Variant("s", address),
        "prefix": Variant("u", prefix),
    }
    gateway = _ip_text(ipv4.get("gateway"), 4)
    if gateway:
        out["gateway"] = Variant("s", gateway)
    for i, dns in enumerate(_dns_list(ipv4, 4)[:3]):
        out["dns%d" % (i + 1)] = Variant("s", dns)
    mtu = _uint(ipv4.get("mtu"))
    if mtu:
        out["mtu"] = Variant("u", mtu)
    return out


def link_local_from(ipv6):
    """fe80::/64 address whose interface identifier is the network-assigned one.

    Accepts the core's 'iid' (int, 8 bytes or hex string) or the low 64 bits
    of 'address'.  Returns None when no identifier is available.
    """
    iid = ipv6.get("iid")
    value = None
    if isinstance(iid, (bytes, bytearray)) and len(iid) == 8:
        value = int.from_bytes(bytes(iid), "big")
    elif isinstance(iid, int) and not isinstance(iid, bool):
        value = iid & 0xFFFFFFFFFFFFFFFF
    elif isinstance(iid, str) and iid:
        try:
            value = int(iid.replace(":", ""), 16) & 0xFFFFFFFFFFFFFFFF
        except ValueError:
            value = None
    if value is None:
        text = _ip_text(ipv6.get("address"), 6)
        if not text:
            return None
        value = int(ipaddress.IPv6Address(text)) & 0xFFFFFFFFFFFFFFFF
    if value == 0:
        return None
    return str(ipaddress.IPv6Address((0xFE80 << 112) | value))


def ip6_config(ipv6):
    """Bearer Ip6Config: method DHCP (NetworkManager runs SLAAC) with a link-local address."""
    if not ipv6:
        return ip_config_unknown()
    out = {"method": Variant("u", E.IP_METHOD_DHCP)}
    link_local = link_local_from(ipv6)
    if link_local:
        out["address"] = Variant("s", link_local)
        out["prefix"] = Variant("u", 64)
    for i, dns in enumerate(_dns_list(ipv6, 6)[:3]):
        out["dns%d" % (i + 1)] = Variant("s", dns)
    mtu = _uint(ipv6.get("mtu"))
    if mtu:
        out["mtu"] = Variant("u", mtu)
    return out


def data_interface(data):
    """rmnet interface of a core 'data' dict: explicit name, else rmnet(cid-1)."""
    name = (data or {}).get("interface")
    if name:
        return str(name)
    cid = _uint((data or {}).get("cid"))
    if cid and cid >= 1:
        return "rmnet%d" % (cid - 1)
    return ""


def core_auth(allowed_auth):
    """MMBearerAllowedAuth bitmask -> core auth word (None: let the core decide)."""
    if not allowed_auth or allowed_auth == E.AUTH_UNKNOWN:
        return None
    if allowed_auth & E.AUTH_CHAP and allowed_auth & E.AUTH_PAP:
        return "pap-chap"
    if allowed_auth & E.AUTH_CHAP:
        return "chap"
    if allowed_auth & E.AUTH_PAP:
        return "pap"
    if allowed_auth & E.AUTH_NONE:
        return "none"
    return None


def core_ip_type(mm_ip_type):
    """MMBearerIpFamily requested by a client -> word for core.data_connect()."""
    if mm_ip_type in E.IP_TYPE_TO_CORE:
        return E.IP_TYPE_TO_CORE[mm_ip_type]
    return "ipv4v6"  # NONE / ANY: what ModemManager picks on a dual-stack modem


# SMS and calls -------------------------------------------------------------


def sms_timestamp(value):
    """ISO 8601 text as ModemManager publishes it ('' when unknown)."""
    if value is None or value == "":
        return ""
    if isinstance(value, datetime.datetime):
        dt = value if value.tzinfo else value.astimezone()
        return dt.isoformat(timespec="seconds")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        dt = datetime.datetime.fromtimestamp(value, tz=datetime.timezone.utc).astimezone()
        return dt.isoformat(timespec="seconds")
    return str(value)


def call_state(core_state):
    return E.CALL_STATE_FROM_CORE.get(core_state, E.CALL_UNKNOWN)


def call_reason(core_state, core_reason, previous=E.REASON_UNKNOWN):
    """MMCallStateReason for a core call transition."""
    if core_state == "released":
        text = str(core_reason or "").lower()
        if any(word in text for word in ("busy", "refus", "reject", "declin")):
            return E.REASON_REFUSED_OR_BUSY
        if any(word in text for word in ("error", "fail", "crash")):
            return E.REASON_ERROR
        return E.REASON_TERMINATED
    if core_state == "active":
        return E.REASON_ACCEPTED
    if core_state in ("incoming", "waiting"):
        return E.REASON_INCOMING_NEW
    if core_state in ("dialing", "alerting"):
        return E.REASON_OUTGOING_STARTED
    return previous


def valid_pin(pin):
    return isinstance(pin, str) and pin.isdigit() and 4 <= len(pin) <= 8


def valid_number(number):
    if not isinstance(number, str) or not number:
        return False
    body = number[1:] if number.startswith("+") else number
    return bool(body) and all(c in "0123456789*#pwPW," for c in body) and len(body) <= 40


# NET_MODE_SEL bits (shannond.defs) of each ModemManager mode
RAT_BITS = ((E.MODE_2G, 0x01), (E.MODE_3G, 0x02), (E.MODE_4G, 0x08))


def core_modes(modes):
    """ModemManager's allowed modes as a NET_MODE_SEL mask."""
    return sum(bit for mode, bit in RAT_BITS if modes & mode)


def current_modes(st):
    """(allowed, preferred) from the core's mask."""
    mask = st.get("modes", 0x0B)
    return (sum(mode for mode, bit in RAT_BITS if mask & bit), E.MODE_NONE)
