# SPDX-License-Identifier: GPL-2.0-or-later
"""Payload codecs for the IPC 4.1 messages shannond uses.

Every encoder returns the exact payload size given by the catalogue
(research/modem/research/analysis/ipc41_catalogue.md, sections 1-11); the
sizes are asserted in ``ENCODED_SIZES`` and checked by the unit tests.
Decoders accept the libsamsung-ipc prefix (``MIN_SIZES``) and read the
IPC 4.1 extensions when the frame is long enough; a shorter payload raises
``DecodeError``.  All multi-byte fields are little-endian.

Decoded values that are identifiers (IMEI, IMSI, ICCID, numbers, PLMN, cell
ids, SMS PDUs) are returned to the caller but never logged by this module.
"""

import ipaddress
import struct
from dataclasses import dataclass, field

from . import defs


class DecodeError(ValueError):
    pass


def _need(payload, size, what):
    if len(payload) < size:
        raise DecodeError("%s: payload %d bytes, need >= %d" % (what, len(payload), size))


def _fixed_ascii(text, size, what):
    data = text.encode("ascii") if isinstance(text, str) else bytes(text)
    if len(data) > size:
        raise ValueError("%s longer than %d bytes" % (what, size))
    return data.ljust(size, b"\0")


def _cstr(data):
    return bytes(data).split(b"\0", 1)[0].decode("ascii", "replace").strip()


# ---------------------------------------------------------------- encoders

def pwr_phone_state(state):
    """PWR_PHONE_STATE 01/07 EXEC: u16 0x0202 radio on, 0x0001 LPM."""
    if state not in (defs.PWR_STATE_NORMAL, defs.PWR_STATE_LPM):
        raise ValueError("unsupported phone state 0x%04x" % state)
    return struct.pack("<H", state)


def misc_me_version_get():
    return b"\xff"


def misc_me_imsi_get():
    return b""


def misc_me_sn_get(sn_type=defs.MISC_SN_IMEI):
    return bytes([sn_type])


def misc_loopback_cfrm(value):
    """MISC_IPC_LOOPBACK 0A/23 CFRM: echo the CP's u16."""
    return struct.pack("<H", value & 0xFFFF)


def sec_pin_status_get():
    return b""


def sec_pin_status_set(pin1, pin2="", pin_type=defs.SEC_PIN_TYPE_PIN1):
    """SEC_PIN_STATUS 05/01 SET, 19 bytes: {type, len1, len2, pin1[8], pin2[8]}.

    For a PUK, samsung-ril puts the new PIN in pin1 and the PUK in pin2.
    Never called automatically by shannond.
    """
    for p in (pin1, pin2):
        if not p.isdigit() and p != "":
            raise ValueError("PIN must be digits")
    if not 4 <= len(pin1) <= 8 or len(pin2) > 8:
        raise ValueError("PIN length out of range")
    return (struct.pack("<BBB", pin_type, len(pin1), len(pin2))
            + _fixed_ascii(pin1, 8, "pin1") + _fixed_ascii(pin2, 8, "pin2"))


def sec_lock_info_get(lock_type=defs.SEC_PIN_TYPE_PIN1, caller=0x01):
    """SEC_LOCK_INFORMATION 05/08 GET, 9 bytes: {caller, lock type, 7 zero bytes}."""
    return bytes([caller, lock_type]) + bytes(7)


def sec_rsim_access_get(command, file_id, p1=0, p2=0, p3=0, path=defs.RSIM_PATH_ADF):
    """SEC_RSIM_ACCESS 05/05 GET: read a SIM file (37-byte IPC 4.1 header).

    Reads only. On the SS333 a file under ADF USIM needs app selector 4 and the USIM AID (the
    partial AID is enough); selector 3 without an AID answers 6A82 or 6986.
    """
    if command not in (defs.RSIM_GET_RESPONSE, defs.RSIM_READ_BINARY, defs.RSIM_READ_RECORD):
        raise ValueError("SIM access is read-only here")
    aid = defs.USIM_AID
    h = bytes([command, defs.RSIM_APP_USIM, len(aid)]) + aid + bytes(16 - len(aid))
    h += struct.pack("<HB", file_id, len(path))
    h += b"".join(struct.pack("<H", x) for x in path) + bytes(2 * (6 - len(path)))
    return h + bytes([p1, p2, p3])


def dec_rsim(p):
    """SEC_RSIM_ACCESS 05/05 RESP: returns (sw1, sw2, data)."""
    _need(p, 3, "SEC_RSIM_ACCESS")
    return p[0], p[1], bytes(p[3:3 + p[2]])


def fcp_record_length(fcp):
    """Record length from a USIM FCP (tag 0x62, file descriptor tag 0x82), or None."""
    i = fcp.find(b"\x82") if fcp[:1] == b"\x62" else -1
    if i < 0 or len(fcp) < i + 6 or fcp[i + 1] < 5:
        return None
    return int.from_bytes(fcp[i + 4:i + 6], "big")


def dec_msisdn_record(rec):
    """EF_MSISDN record: the number, or None when the record is empty."""
    tail = rec[-14:]
    if len(tail) < 14 or tail[0] in (0, 0xFF) or tail[0] > 11:
        return None
    digits = ""
    for b in tail[2:1 + tail[0]]:
        for nibble in (b & 0x0F, b >> 4):
            if nibble < 10:
                digits += str(nibble)
    return ("+" if (tail[1] & 0x70) == 0x10 else "") + digits if digits else None


def dec_spn(data):
    """EF_SPN: the service provider name, or None. GSM 7-bit unpacked, or UCS2 (0x80)."""
    body = bytes(data[1:]).split(b"\xff", 1)[0]
    if not body:
        return None
    if body[0] == 0x80:
        return body[1:].decode("utf-16-be", "replace").strip() or None
    return body.decode("ascii", "replace").strip() or None


def sec_sim_icc_type_get():
    return b""


def net_regist_get(domain):
    """NET_REGIST 08/05 GET: {act 0xFF, domain 2 CS / 3 PS}."""
    if domain not in (defs.NET_DOMAIN_CS, defs.NET_DOMAIN_PS):
        raise ValueError("domain must be 2 (CS) or 3 (PS)")
    return bytes([0xFF, domain])


def net_serving_get():
    return b""


def net_mode_sel_set(mask=defs.NET_MODE_LTE_WCDMA_GSM):
    """NET_MODE_SEL 08/0A SET: RAT bitmask (bit0 GSM, bit1 WCDMA, bit3 LTE)."""
    if not 0 < mask <= 0x1F:
        raise ValueError("bad RAT mask")
    return bytes([mask])


def net_plmn_list_get():
    return b""


def net_plmn_sel_set_auto():
    """NET_PLMN_SEL 08/02 SET (automatic), 8 bytes."""
    return bytes([0x02]) + b"\0" * 6 + bytes([0xFF])


def net_plmn_sel_set_manual(plmn, act=0xFF):
    plmn = str(plmn)
    if not plmn.isdigit() or len(plmn) not in (5, 6):
        raise ValueError("PLMN must be 5 or 6 digits")
    return bytes([0x03]) + plmn.ljust(6, "#").encode("ascii") + bytes([act])


def disp_icon_info_get(flags=0x01):
    return bytes([flags])


def sms_send_msg(smsc_field, tpdu, more=False, domain=0x02):
    """SMS_SEND_MSG 04/01 EXEC: {fmt 0x02, msg_type, domain, len, SMSC field + TPDU}.

    ``smsc_field`` is the RP address including its own length byte (b"\\x00"
    = default SMSC).  msg_type 0x01 = more to send, 0x02 = single.
    """
    body = bytes(smsc_field) + bytes(tpdu)
    if len(body) > 255:
        raise ValueError("SMS PDU too long")
    return bytes([0x02, 0x01 if more else 0x02, domain, len(body)]) + body


def sms_deliver_report(msg_id, ack=0x0000):
    """SMS_DELIVER_REPORT 04/06 EXEC, 5 bytes: {2, u16 ack, msg id, 0}."""
    return struct.pack("<BHBB", 0x02, ack, msg_id & 0xFF, 0)


def sms_device_ready_set():
    return b""


def sms_svc_center_addr_get():
    return b""


def sms_mem_status_set(available=True):
    return bytes([1 if available else 2])


def normalize_number(number):
    """Strip separators; keep a leading '+', digits, '*', '#'."""
    if not isinstance(number, str):
        raise ValueError("number must be a string")
    raw = "".join(ch for ch in number.strip() if ch not in " -.()/")
    if raw.startswith("+"):
        body = raw[1:]
        prefix = "+"
    else:
        body = raw
        prefix = ""
    if not body or any(ch not in "0123456789*#" for ch in body):
        raise ValueError("invalid number")
    return prefix + body


def is_emergency_number(number):
    """True for the hard-coded emergency numbers (exact match, '+' ignored)."""
    try:
        norm = normalize_number(number)
    except ValueError:
        return False
    digits = norm.lstrip("+").rstrip("#")
    return digits in defs.EMERGENCY_NUMBERS


class EmergencyCallRefused(ValueError):
    pass


def call_outgoing(number, call_type=defs.CALL_TYPE_VOICE, clir=0, extra=0):
    """CALL_OUTGOING 02/01 EXEC, 92 bytes.

    {u8 subtype, u8 type, CLIR, number length, TON, number[86], extra}.  TON
    0x11 when the number starts with '+' (the '+' is not sent), else 0x21.
    Emergency numbers and emergency call types are refused here, hard-coded.
    """
    if call_type in (defs.CALL_TYPE_EMERGENCY, defs.CALL_TYPE_EMERGENCY_ALT):
        raise EmergencyCallRefused("emergency call type refused")
    if is_emergency_number(number):
        raise EmergencyCallRefused("emergency number refused")
    norm = normalize_number(number)
    intl = norm.startswith("+")
    digits = norm[1:] if intl else norm
    if len(digits) > 82:
        raise ValueError("number too long")
    return (bytes([0x00, call_type, clir, len(digits), 0x11 if intl else 0x21])
            + _fixed_ascii(digits, 86, "number") + bytes([extra & 0xFF]))


def call_answer():
    return b""


def call_release():
    return b""


def call_list_get():
    return b""


def call_cont_dtmf(start, digit="0"):
    """CALL_CONT_DTMF 02/08 SET: start {0x01, digit}, stop {0x02, 0x00}."""
    if start:
        if len(digit) != 1 or digit not in "0123456789*#ABCD":
            raise ValueError("bad DTMF digit")
        return bytes([0x01, ord(digit)])
    return bytes([0x02, 0x00])


def call_burst_dtmf(digits, tone_type=1):
    """CALL_BURST_DTMF 02/07 EXEC, 84 bytes: {tone type, length, digits[82]}."""
    if not digits or len(digits) > 82 or any(d not in "0123456789*#ABCD" for d in digits):
        raise ValueError("bad DTMF string")
    return bytes([tone_type, len(digits)]) + _fixed_ascii(digits, 82, "digits")


def ss_manage_call(action, call_id, number=""):
    """SS_MANAGE_CALL 0C/07 SET, 85 bytes: {type, call id, number length, number[82]}.

    action 3 = release one call id (CHLD=1x), 2 = release active + accept,
    4 = swap/hold-accept, 6 = conference.
    """
    if len(number) > 82:
        raise ValueError("number too long")
    return bytes([action, call_id & 0xFF, len(number)]) + _fixed_ascii(number, 82, "number")


PDP_TYPES = {"ipv4": defs.GPRS_PDP_IP, "ipv6": defs.GPRS_PDP_IPV6, "ipv4v6": defs.GPRS_PDP_IPV4V6}
AUTH_TYPES = {"none": defs.GPRS_AUTH_NONE, "pap": defs.GPRS_AUTH_PAP, "chap": defs.GPRS_AUTH_CHAP,
              "pap-chap": defs.GPRS_AUTH_PAP}


def _apn_field(apn):
    data = apn.encode("ascii")
    if not data or len(data) > 99 or b"\0" in data:
        raise ValueError("APN must be 1..99 ASCII bytes")
    return data.ljust(100, b"\0")


def gprs_define_pdp_context(cid, apn, pdp_type=defs.GPRS_PDP_IP, enable=1):
    """GPRS_DEFINE_PDP_CONTEXT 0D/01 SET, 127 bytes.

    p0 enable, p1 cid, p2 PDP type, p3..102 APN[100], p103 0, p104..119 static
    IPv6, p120..123 static IPv4, p124..125 0, p126 flag (0).
    """
    if not 1 <= cid <= 4:
        raise ValueError("cid must be 1..4")
    return bytes([enable, cid, pdp_type]) + _apn_field(apn) + bytes(24)


def _auth_block(user, password, auth):
    user_b = (user or "").encode("utf-8")
    pass_b = (password or "").encode("utf-8")
    if len(user_b) > 32 or len(pass_b) > 32:
        raise ValueError("user/password longer than 32 bytes")
    if auth not in AUTH_TYPES:
        raise ValueError("auth must be one of %s" % sorted(AUTH_TYPES))
    return user_b.ljust(32, b"\0"), pass_b.ljust(32, b"\0"), AUTH_TYPES[auth]


def gprs_pdp_context_set(action, cid, user=None, password=None, auth="none", reason=0):
    """GPRS_PDP_CONTEXT 0D/04 SET, 105 bytes.

    p0 action (1 activate, 0 deactivate), p1 cid, p2 flags (bit0 user, bit1
    password, bit4 auth type present), p3..5 0, p6..37 user[32], p38..69
    password[32], p70..101 0, p102 auth type, p103 0, p104 deactivation reason.
    """
    user_f, pass_f, auth_v = _auth_block(user, password, auth)
    flags = 0
    if user:
        flags |= 0x01
    if password:
        flags |= 0x02
    if auth != "none":
        flags |= 0x10
    return (bytes([action, cid, flags]) + bytes(3) + user_f + pass_f + bytes(32)
            + bytes([auth_v, 0, reason & 0xFF]))


def gprs_pdp_context_get():
    return b""


def gprs_lte_attach_apn_info(cid, apn, pdp_type=defs.GPRS_PDP_IP, user=None, password=None,
                             auth="none", roaming_pdp_type=None, roaming_flag=0):
    """GPRS_LTE_ATTACH_APN_INFO 0D/14 SET, 194 bytes (sent because protover = 2).

    p0..126 as DEFINE_PDP_CONTEXT, p127..158 user[32], p159..190 password[32],
    p191 auth type, p192 roaming PDP type, p193 roaming flag.
    """
    user_f, pass_f, auth_v = _auth_block(user, password, auth)
    if roaming_pdp_type is None:
        roaming_pdp_type = pdp_type
    return (gprs_define_pdp_context(cid, apn, pdp_type) + user_f + pass_f
            + bytes([auth_v, roaming_pdp_type, roaming_flag]))


def snd_audio_path(path, extra=0):
    """SND_AUDIO_PATH_CTRL 09/03 SET, 2 bytes: {path, extra}. Speaker 0x06, headphone 0x07."""
    return bytes([path, extra])


def snd_spkr_volume(vol_type, level):
    """SND_SPKR_VOLUME_CTRL 09/01 SET: {type 0x01/0x11/0x31/0x41, level}."""
    return bytes([vol_type, level])


def snd_mic_mute(mute):
    """SND_MIC_MUTE_CTRL 09/02 SET: {0..5} (0 = TX unmute, 1 = TX mute)."""
    return bytes([int(mute)])


def snd_clock_ctrl(start):
    """SND_CLOCK_CTRL 09/09 EXEC: {0 stop, 1 start}."""
    return bytes([1 if start else 0])


def snd_two_mic(device=0, state=0):
    """SND_TWO_MIC_SOL_CTRL 09/0B SET, 2 bytes (raw OEM values)."""
    return bytes([device, state])


# Payload sizes from the catalogue, checked by the tests.
ENCODED_SIZES = {
    "pwr_phone_state": 2, "misc_me_version_get": 1, "misc_me_imsi_get": 0, "misc_me_sn_get": 1,
    "misc_loopback_cfrm": 2, "sec_pin_status_get": 0, "sec_pin_status_set": 19,
    "sec_lock_info_get": 9, "net_regist_get": 2, "net_serving_get": 0, "net_mode_sel_set": 1,
    "net_plmn_sel_set": 8, "disp_icon_info_get": 1, "sms_deliver_report": 5,
    "sms_device_ready_set": 0, "call_outgoing": 92, "call_cont_dtmf": 2, "call_burst_dtmf": 84,
    "ss_manage_call": 85, "gprs_define_pdp_context": 127, "gprs_pdp_context_set": 105,
    "gprs_lte_attach_apn_info": 194, "snd_audio_path": 2, "snd_spkr_volume": 2, "snd_mic_mute": 1,
    "snd_clock_ctrl": 1, "snd_two_mic": 2,
}


# ---------------------------------------------------------------- decoders

@dataclass
class PhoneState:
    state: int

    @property
    def power(self):
        """'lpm' for 1, 'on' for 2/3/4 (catalogue table [1,2,2,2])."""
        if self.state == 1:
            return "lpm"
        if self.state in (2, 3, 4):
            return "on"
        return "unknown"


def dec_phone_state(p):
    _need(p, 1, "PWR_PHONE_STATE")
    return PhoneState(p[0])


@dataclass
class PhoneReset:
    reset_type: int
    cause: int


def dec_phone_reset(p):
    return PhoneReset(p[0] if len(p) > 0 else 0, p[1] if len(p) > 1 else 0)


@dataclass
class GenRes:
    group: int
    index: int
    type: int
    code: int


def dec_gen_phone_res(p):
    _need(p, 5, "GEN_PHONE_RES")
    return GenRes(*struct.unpack_from("<BBBH", p))


@dataclass
class MeVersion:
    mask: int
    sw: str = ""
    hw: str = ""
    cal_date: str = ""
    misc: str = ""


def dec_me_version(p):
    _need(p, 1, "MISC_ME_VERSION")
    out = MeVersion(p[0])
    fields = ("sw", "hw", "cal_date", "misc")
    for i, name in enumerate(fields):
        start = 1 + 32 * i
        if len(p) >= start + 32:
            setattr(out, name, _cstr(p[start:start + 32]))
    return out


def dec_me_imsi(p):
    _need(p, 1, "MISC_ME_IMSI")
    n = min(p[0], 15, len(p) - 1)
    return bytes(p[1:1 + n]).decode("ascii", "replace")


@dataclass
class MeSn:
    sn_type: int
    value: str


def dec_me_sn(p):
    _need(p, 2, "MISC_ME_SN")
    n = min(p[1], 32, len(p) - 2)
    return MeSn(p[0], _cstr(p[2:2 + n]))


def dec_loopback(p):
    if len(p) >= 2:
        return struct.unpack_from("<H", p)[0]
    return p[0] if p else 0


@dataclass
class TimeInfo:
    valid: int
    year: int
    month: int
    day: int
    hour: int
    minute: int
    second: int
    tz_quarters: int
    dst: int
    plmn: str = ""


def dec_time_info(p):
    _need(p, 10, "MISC_TIME_INFO")
    tz = p[8] - 256 if p[8] > 127 else p[8]
    plmn = ""
    if len(p) >= 18:
        plmn = bytes(p[12:18]).decode("ascii", "replace").rstrip("#\0")
    return TimeInfo(p[0], 2000 + p[2], p[3], p[4], p[5], p[6], p[7], tz, p[9], plmn)


@dataclass
class PinStatus:
    status: int
    facility: int = 0

    def sim_state(self):
        """Map to (sim state, lock) with sim in absent|locked|ready|error|unknown."""
        s, f = self.status, self.facility
        if s in (0x00, 0x82, 0x83):
            return "ready", None
        if s == 0x03:
            return {0: ("ready", None), 1: ("locked", "sim-pin"), 2: ("locked", "sim-puk"),
                    5: ("locked", "blocked")}.get(f, ("locked", "unknown"))
        if s == 0x04:
            return "locked", "sim-pin2"
        if s in (0x05, 0x06, 0x07, 0x08):
            return "locked", {5: "ph-net-pin", 6: "ph-netsub-pin", 7: "ph-sp-pin", 8: "ph-corp-pin"}[s]
        if s == 0x80:
            return "absent", None
        if s in (0x01, 0x02, 0x81):
            return "error", None
        return "unknown", None


def dec_pin_status(p):
    _need(p, 1, "SEC_PIN_STATUS")
    return PinStatus(p[0], p[1] if len(p) > 1 else 0)


ICC_TYPES = {1: "sim", 2: "usim", 3: "ruim", 4: "other"}


def dec_icc_type(p):
    _need(p, 1, "SEC_SIM_ICC_TYPE")
    return ICC_TYPES.get(p[0], "unknown")


@dataclass
class LockInfo:
    num: int
    lock_type: int
    key_state: int
    retries: int


def dec_lock_info(p):
    _need(p, 4, "SEC_LOCK_INFORMATION")
    return LockInfo(p[0], p[1], p[2], p[3])


def dec_iccid(p):
    _need(p, 1, "SEC_SIM_ICCID")
    n = min(p[0], len(p) - 1)
    raw = bytes(p[1:1 + n])
    if raw and all(0x30 <= b <= 0x39 or b in (0x46, 0x66) for b in raw):
        return raw.decode("ascii").rstrip("Ff")
    # BCD, nibble-swapped
    digits = []
    for b in raw:
        for nib in (b & 0x0F, b >> 4):
            if nib <= 9:
                digits.append(str(nib))
    return "".join(digits)


RAT_NAMES = {0x01: "gsm", 0x02: "gsm", 0x03: "gsm", 0x04: "umts", 0x05: "umts", 0x21: "lte",
             0x22: "umts"}
RAT_DETAIL = {0x01: "gsm", 0x02: "gprs", 0x03: "edge", 0x04: "umts", 0x05: "umts", 0x21: "lte",
              0x22: "td-scdma", 0x30: "iwlan", 0xFF: "any"}


def rat_name(act):
    return RAT_NAMES.get(act)


REG_STATES = {0x01: "idle", 0x08: "idle", 0x02: "home", 0x03: "searching", 0x04: "denied",
              0x09: "denied", 0x06: "roaming", 0x07: "idle", 0x0A: "idle"}


def reg_state_name(status):
    return REG_STATES.get(status, "unknown")


@dataclass
class Regist:
    act: int
    domain: int
    status: int
    edge: int
    lac: int
    cell_id: int
    reject_cause: int
    tac: int = 0
    volte: int = 0
    ims_emergency: int = 0
    pci: int = 0

    @property
    def state(self):
        return reg_state_name(self.status)

    @property
    def rat(self):
        return rat_name(self.act)


def dec_regist(p):
    """NET_REGIST 08/05 RESP/NOTI: 11-byte libsamsung-ipc prefix, 19 bytes in IPC 4.1."""
    _need(p, 11, "NET_REGIST")
    act, domain, status, edge, lac, cell, rej = struct.unpack_from("<BBBBHIB", p)
    r = Regist(act, domain, status, edge, lac, cell, rej)
    if len(p) >= 19:
        r.tac, r.volte, r.ims_emergency = struct.unpack_from("<HBB", p, 11)
        r.pci = struct.unpack_from("<H", p, 16)[0]
    return r


@dataclass
class Serving:
    status: int
    act: int
    plmn: str
    lac: int

    @property
    def mcc(self):
        return self.plmn[:3] if len(self.plmn) >= 5 else None

    @property
    def mnc(self):
        return self.plmn[3:] if len(self.plmn) >= 5 else None


def dec_serving(p):
    """NET_SERVING_NETWORK 08/03: 11-byte prefix (26 bytes in IPC 4.1)."""
    _need(p, 11, "NET_SERVING_NETWORK")
    plmn = bytes(p[3:9]).decode("ascii", "replace").replace("#", "").strip("\0 ")
    if not plmn.isdigit():
        plmn = ""
    return Serving(p[1], p[2], plmn, struct.unpack_from("<H", p, 9)[0])


def _decode_name(data, coding):
    data = bytes(data)
    if coding == 2:
        return data.decode("utf-16-be", "replace").rstrip("\0")
    if coding == 1:
        from . import sms_pdu
        count = len(data) * 8 // 7
        return sms_pdu.gsm7_decode(sms_pdu.unpack_septets(data, count)).rstrip("@\0\r")
    return data.split(b"\0", 1)[0].decode("latin-1", "replace")


@dataclass
class NetIdentity:
    short_name: str = ""
    full_name: str = ""
    plmn: str = ""


def dec_net_identity(p):
    """NET_IDENTITY 08/0C NOTI (operator names); layout chosen by length."""
    out = NetIdentity()
    try:
        if len(p) + 7 >= 0x46:
            flags = p[1]
            if flags & 1:
                out.short_name = _decode_name(p[5:5 + min(p[3], 32)], p[4])
            if flags & 2 and len(p) > 40:
                out.full_name = _decode_name(p[40:40 + min(p[38], 64)], p[39])
            if len(p) >= 110:
                out.plmn = bytes(p[104:110]).decode("ascii", "replace").replace("#", "").strip("\0")
        elif len(p) >= 62:
            out.short_name = _decode_name(p[5:5 + min(p[3], 17)], p[4])
            out.full_name = _decode_name(p[24:24 + min(p[22], 32)], p[23])
            out.plmn = bytes(p[56:62]).decode("ascii", "replace").replace("#", "").strip("\0")
        else:
            raise DecodeError("NET_IDENTITY: %d bytes" % len(p))
    except (IndexError, ValueError) as exc:
        raise DecodeError("NET_IDENTITY: %s" % exc)
    return out


@dataclass
class PlmnEntry:
    status: int
    plmn: str
    act: int


def dec_plmn_list(p):
    _need(p, 1, "NET_PLMN_LIST")
    count = p[0]
    _need(p, 1 + 10 * count, "NET_PLMN_LIST entries")
    out = []
    for i in range(count):
        e = p[1 + 10 * i:11 + 10 * i]
        out.append(PlmnEntry(e[0], bytes(e[1:7]).decode("ascii", "replace").replace("#", ""), e[7]))
    return out


def dec_mode_sel(p):
    _need(p, 1, "NET_MODE_SEL")
    return p[0]


def dec_plmn_sel(p):
    _need(p, 1, "NET_PLMN_SEL")
    return p[0]


@dataclass
class Signal:
    rssi_dbm: int = None
    bars: int = None
    rsrp_dbm: int = None
    rsrq: int = None
    rssnr: int = None

    @property
    def percent(self):
        if self.rsrp_dbm is not None:
            return max(0, min(100, round((self.rsrp_dbm + 140) * 100 / 96)))
        if self.rssi_dbm is not None:
            asu = max(0, min(31, (113 + self.rssi_dbm) // 2))
            return round(asu * 100 / 31)
        if self.bars is not None:
            return max(0, min(100, self.bars * 25))
        return None


def dec_rssi_info(p):
    """DISP_RSSI_INFO 07/06 NOTI: p0 RSSI as -dBm; 9 bytes with LTE fields."""
    _need(p, 1, "DISP_RSSI_INFO")
    sig = Signal()
    if 0 < p[0] < 0xFF:
        sig.rssi_dbm = -p[0]
    if len(p) >= 9:
        if 0 < p[4] < 0xFF:
            sig.rsrp_dbm = -p[4]
        sig.rsrq = p[5]
        sig.rssnr = struct.unpack_from("<h", p, 6)[0] - 200
    return sig


def dec_icon_info(p):
    """DISP_ICON_INFO 07/01: {flags, bars, ...}; 10 bytes with LTE fields."""
    _need(p, 2, "DISP_ICON_INFO")
    sig = Signal(bars=p[1])
    if len(p) >= 10 and 0 < p[5] < 0xFF:
        sig.rsrp_dbm = -p[5]
        sig.rsrq = p[6]
        sig.rssnr = struct.unpack_from("<h", p, 7)[0] - 200
    return sig


@dataclass
class SmsSendResult:
    fmt: int
    ack: int
    ref: int
    pdu: bytes = b""

    @property
    def ok(self):
        return self.ack == 0


def dec_sms_send_msg(p):
    _need(p, 4, "SMS_SEND_MSG")
    fmt, ack, ref = struct.unpack_from("<BHB", p)
    pdu = b""
    if len(p) >= 5:
        pdu = bytes(p[5:5 + p[4]])
    return SmsSendResult(fmt, ack, ref, pdu)


@dataclass
class SmsIncoming:
    fmt: int
    msg_type: int
    sim_index: int
    msg_id: int
    pdu: bytes


def dec_sms_incoming(p):
    """SMS_INCOMING_MSG 04/02 NOTI: {fmt, type, u16 SIM index, msg id, len, SMSC+TPDU}."""
    _need(p, 6, "SMS_INCOMING_MSG")
    fmt, typ, idx, mid, length = struct.unpack_from("<BBHBB", p)
    if len(p) < 6 + length:
        raise DecodeError("SMS_INCOMING_MSG: PDU truncated")
    return SmsIncoming(fmt, typ, idx, mid, bytes(p[6:6 + length]))


def dec_sms_deliver_report(p):
    _need(p, 2, "SMS_DELIVER_REPORT")
    return struct.unpack_from("<H", p)[0]


def dec_svc_center_addr(p):
    """SMS_SVC_CENTER_ADDR 04/0A RESP: {len, SMSC address bytes}; returns the RP field."""
    _need(p, 1, "SMS_SVC_CENTER_ADDR")
    n = p[0]
    if n == 0 or n > len(p) - 1:
        raise DecodeError("SMS_SVC_CENTER_ADDR: bad length")
    return bytes(p[:1 + n])


def dec_sms_mem_status(p):
    _need(p, 1, "SMS_MEM_STATUS")
    return p[-1]


CALL_STATUS_NAMES = {1: "dialing", 2: "ignoring", 3: "active", 4: "released", 5: "alerting"}


@dataclass
class CallStatus:
    call_type: int
    call_id: int
    status: int
    cause_type: int
    end_cause: int

    @property
    def state(self):
        """1 dialing, 2 ignoring, 3 connected, 4 released, 5 connecting (alerting)."""
        return CALL_STATUS_NAMES.get(self.status, "unknown")


def dec_call_status(p):
    _need(p, 6, "CALL_STATUS")
    return CallStatus(p[1], p[2], p[3], p[4], p[5])


@dataclass
class CallIncoming:
    call_type: int = 0
    call_id: int = 0
    line: int = 0


def dec_call_incoming(p):
    """CALL_INCOMING 02/02 NOTI: libsamsung-ipc {unknown, type, id, line} (unverified)."""
    out = CallIncoming()
    if len(p) >= 3:
        out.call_type, out.call_id = p[1], p[2]
    if len(p) >= 4:
        out.line = p[3]
    return out


CALL_LIST_STATES = {1: "active", 2: "held", 3: "dialing", 4: "alerting", 5: "incoming", 6: "waiting"}


@dataclass
class CallEntry:
    call_type: int
    call_id: int
    direction: str
    state: str
    mpty: int
    number: str


def dec_call_list(p):
    """CALL_LIST 02/06 RESP: {count, entries {u16 type, id, term, status, mpty, len, TON, number}}."""
    _need(p, 1, "CALL_LIST")
    count = p[0]
    off = 1
    out = []
    for _ in range(count):
        _need(p, off + 8, "CALL_LIST entry")
        typ, cid, term, status, mpty, nlen, ton = struct.unpack_from("<HBBBBBB", p, off)
        off += 8
        _need(p, off + nlen, "CALL_LIST number")
        number = bytes(p[off:off + nlen]).split(b"\0", 1)[0].decode("ascii", "replace")
        off += nlen
        if (ton & 0x70) == 0x10 and number and not number.startswith("+"):
            number = "+" + number
        out.append(CallEntry(typ >> 8, cid, "out" if term == 1 else "in",
                             CALL_LIST_STATES.get(status, "unknown"), mpty, number))
    return out


@dataclass
class IpConfig:
    cid: int
    flags: int
    ipv4: str = None
    dns1: str = None
    dns2: str = None
    ipv6: str = None
    dns6_1: str = None
    dns6_2: str = None
    mtu: int = None


def _ip4(b):
    v = ipaddress.IPv4Address(bytes(b))
    return None if int(v) == 0 else str(v)


def _ip6(b):
    v = ipaddress.IPv6Address(bytes(b))
    return None if int(v) == 0 else str(v)


def dec_ip_configuration(p):
    """GPRS_IP_CONFIGURATION 0D/09 NOTI.

    p0 cid, p1..2 u16 flags (0x0001 IPv4, 0x0040 IPv6, 0x2000 MTU), p3 IPv4,
    p7 DNS1, p11 DNS2, p35 IPv6, p99/p115 IPv6 DNS, p152 u32 MTU.
    """
    _need(p, 15, "GPRS_IP_CONFIGURATION")
    cid, flags = struct.unpack_from("<BH", p)
    cfg = IpConfig(cid, flags)
    cfg.ipv4 = _ip4(p[3:7])
    cfg.dns1 = _ip4(p[7:11])
    cfg.dns2 = _ip4(p[11:15])
    if len(p) >= 51:
        cfg.ipv6 = _ip6(p[35:51])
    if len(p) >= 131:
        cfg.dns6_1 = _ip6(p[99:115])
        cfg.dns6_2 = _ip6(p[115:131])
    if (flags & 0x2000) and len(p) >= 156:
        mtu = struct.unpack_from("<I", p, 152)[0]
        cfg.mtu = mtu if 576 <= mtu <= 9000 else None
    return cfg


@dataclass
class GprsCallStatus:
    cid: int
    status: int
    fail_cause: int

    @property
    def up(self):
        return self.status == 0x01


def dec_gprs_call_status(p):
    _need(p, 3, "GPRS_CALL_STATUS")
    return GprsCallStatus(p[0], p[1], p[2])


def dec_pdp_context(p):
    _need(p, 1, "GPRS_PDP_CONTEXT")
    out = {}
    for i in range(p[0]):
        if len(p) >= 3 + 2 * i:
            out[p[1 + 2 * i]] = p[2 + 2 * i]
    return out


@dataclass
class PsState:
    attached: bool
    cause: int


def dec_gprs_ps(p):
    _need(p, 1, "GPRS_PS")
    return PsState(p[0] == 1, p[2] if len(p) > 2 else 0)


@dataclass
class ClockCtrl:
    raw: int

    @property
    def on(self):
        """p0 1..7 -> table [1,0,3,0,5,0,7]: odd = clock on, even = off."""
        return bool(self.raw & 1)


def dec_clock_ctrl(p):
    _need(p, 1, "SND_CLOCK_CTRL")
    return ClockCtrl(p[0])


def dec_wb_amr(p):
    """SND_WB_AMR_RPT 09/0A: 0 = narrow band, 1..8 = wide-band variants (inferred)."""
    _need(p, 1, "SND_WB_AMR_RPT")
    return p[0]


def dec_mic_mute(p):
    _need(p, 1, "SND_MIC_MUTE_CTRL")
    return p[0]


# (main, sub) -> decoder; frames without an entry are logged by header and ignored.
DECODERS = {
    (defs.GEN, defs.GEN_PHONE_RES_SUB): dec_gen_phone_res,
    (defs.PWR, defs.PWR_PHONE_STATE): dec_phone_state,
    (defs.PWR, defs.PWR_PHONE_RESET): dec_phone_reset,
    (defs.PWR, defs.PWR_PHONE_PWR_UP): lambda p: None,
    (defs.MISC, defs.MISC_ME_VERSION): dec_me_version,
    (defs.MISC, defs.MISC_ME_IMSI): dec_me_imsi,
    (defs.MISC, defs.MISC_ME_SN): dec_me_sn,
    (defs.MISC, defs.MISC_TIME_INFO): dec_time_info,
    (defs.MISC, defs.MISC_IPC_LOOPBACK): dec_loopback,
    (defs.SEC, defs.SEC_PIN_STATUS): dec_pin_status,
    (defs.SEC, defs.SEC_SIM_ICC_TYPE): dec_icc_type,
    (defs.SEC, defs.SEC_LOCK_INFORMATION): dec_lock_info,
    (defs.SEC, defs.SEC_SIM_ICCID): dec_iccid,
    (defs.NET, defs.NET_REGIST): dec_regist,
    (defs.NET, defs.NET_SERVING_NETWORK): dec_serving,
    (defs.NET, defs.NET_IDENTITY): dec_net_identity,
    (defs.NET, defs.NET_PLMN_LIST): dec_plmn_list,
    (defs.NET, defs.NET_MODE_SEL): dec_mode_sel,
    (defs.NET, defs.NET_PLMN_SEL): dec_plmn_sel,
    (defs.DISP, defs.DISP_RSSI_INFO): dec_rssi_info,
    (defs.DISP, defs.DISP_ICON_INFO): dec_icon_info,
    (defs.SMS, defs.SMS_SEND_MSG): dec_sms_send_msg,
    (defs.SMS, defs.SMS_INCOMING_MSG): dec_sms_incoming,
    (defs.SMS, defs.SMS_DELIVER_REPORT): dec_sms_deliver_report,
    (defs.SMS, defs.SMS_SVC_CENTER_ADDR): dec_svc_center_addr,
    (defs.SMS, defs.SMS_MEM_STATUS): dec_sms_mem_status,
    (defs.SMS, defs.SMS_DEVICE_READY): lambda p: None,
    (defs.CALL, defs.CALL_STATUS): dec_call_status,
    (defs.CALL, defs.CALL_INCOMING): dec_call_incoming,
    (defs.CALL, defs.CALL_LIST): dec_call_list,
    (defs.GPRS, defs.GPRS_IP_CONFIGURATION): dec_ip_configuration,
    (defs.GPRS, defs.GPRS_CALL_STATUS): dec_gprs_call_status,
    (defs.GPRS, defs.GPRS_PDP_CONTEXT): dec_pdp_context,
    (defs.GPRS, defs.GPRS_PS): dec_gprs_ps,
    (defs.SND, defs.SND_CLOCK_CTRL): dec_clock_ctrl,
    (defs.SND, defs.SND_WB_AMR_RPT): dec_wb_amr,
    (defs.SND, defs.SND_MIC_MUTE_CTRL): dec_mic_mute,
}

# Minimum payload sizes accepted by the decoders (libsamsung-ipc prefixes).
MIN_SIZES = {
    "GEN_PHONE_RES": 5, "PWR_PHONE_STATE": 1, "MISC_ME_VERSION": 1, "MISC_ME_SN": 2,
    "SEC_PIN_STATUS": 1, "SEC_LOCK_INFORMATION": 4, "NET_REGIST": 11, "NET_SERVING_NETWORK": 11,
    "DISP_RSSI_INFO": 1, "DISP_ICON_INFO": 2, "SMS_SEND_MSG": 4, "SMS_INCOMING_MSG": 6,
    "CALL_STATUS": 6, "GPRS_IP_CONFIGURATION": 15, "GPRS_CALL_STATUS": 3, "SND_CLOCK_CTRL": 1,
}


def decode(main, sub, payload):
    """Decode a payload; returns None for messages without a decoder."""
    fn = DECODERS.get((main, sub))
    if fn is None:
        return None
    try:
        return fn(bytes(payload))
    except DecodeError:
        raise
    except (struct.error, IndexError, ValueError) as exc:
        raise DecodeError("%s: %s" % (defs.command_name(main, sub), exc))
