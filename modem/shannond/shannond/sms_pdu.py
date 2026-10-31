# SPDX-License-Identifier: GPL-2.0-or-later
"""SMS PDU codec (3GPP TS 23.040 / 23.038), standard library only.

Encoding:
    encode_submit(number, text, ...) -> [TPDU, ...]   SMS-SUBMIT, GSM 7-bit or UCS2,
                                                      automatic concatenation (8-bit ref UDH)
    encode_smsc(number | None) -> RP address field    b"\\x00" = default SMSC
    split_text(text) -> ("gsm7" | "ucs2", [part, ...])
Decoding:
    decode_pdu(pdu, has_smsc=True) -> SmsDeliver | SmsStatusReport
    ConcatAssembler().feed(msg) -> whole message or None
Helpers: gsm7_encode/gsm7_decode, pack_septets/unpack_septets, encode_address/
decode_address, decode_smsc.

Malformed input raises ValueError.  Nothing here logs numbers or text.
"""

import datetime
import itertools
import re
from dataclasses import dataclass, field, replace

# GSM 03.38 default alphabet, index = septet value (0x1B = escape to the extension table).
GSM7_BASIC = (
    "@£$¥èéùìòÇ\nØø\rÅå"
    "Δ_ΦΓΛΩΠΨΣΘΞ\x1bÆæßÉ"
    " !\"#¤%&'()*+,-./"
    "0123456789:;<=>?"
    "¡ABCDEFGHIJKLMNO"
    "PQRSTUVWXYZÄÖÑÜ§"
    "¿abcdefghijklmno"
    "pqrstuvwxyzäöñüà"
)
assert len(GSM7_BASIC) == 128

GSM7_EXT = {0x0A: "\x0c", 0x14: "^", 0x28: "{", 0x29: "}", 0x2F: "\\", 0x3C: "[", 0x3D: "~",
            0x3E: "]", 0x40: "|", 0x65: "€"}

_BASIC_INDEX = {ch: i for i, ch in enumerate(GSM7_BASIC) if i != 0x1B}
_EXT_INDEX = {ch: code for code, ch in GSM7_EXT.items()}

_SEMI = "0123456789*#abc"  # nibble values 0..14; 15 = padding


# ------------------------------------------------------------------ GSM 7-bit
def gsm7_encodable(text):
    return all(ch in _BASIC_INDEX or ch in _EXT_INDEX for ch in text)


def gsm7_encode(text):
    out = []
    for ch in text:
        if ch in _BASIC_INDEX:
            out.append(_BASIC_INDEX[ch])
        elif ch in _EXT_INDEX:
            out.extend((0x1B, _EXT_INDEX[ch]))
        else:
            raise ValueError("character U+%04X is not in the GSM 7-bit alphabet" % ord(ch))
    return out


def gsm7_decode(septets):
    out = []
    it = iter(septets)
    for s in it:
        s &= 0x7F
        if s == 0x1B:
            nxt = next(it, None)
            if nxt is None:
                break
            nxt &= 0x7F
            # TS 23.038 6.2.1.1: an unknown extension code shows the basic character
            out.append(GSM7_EXT.get(nxt, GSM7_BASIC[nxt] if nxt != 0x1B else " "))
        else:
            out.append(GSM7_BASIC[s])
    return "".join(out)


def _septet_len(ch):
    return 2 if ch in _EXT_INDEX else 1


def pack_septets(septets, fill_bits=0):
    if not 0 <= fill_bits <= 6:
        raise ValueError("fill_bits must be 0..6")
    value = 0
    for i, s in enumerate(septets):
        if not 0 <= s <= 0x7F:
            raise ValueError("septet out of range")
        value |= s << (fill_bits + 7 * i)
    nbits = fill_bits + 7 * len(septets)
    return value.to_bytes((nbits + 7) // 8, "little")


def unpack_septets(data, count, fill_bits=0):
    if not 0 <= fill_bits <= 6 or count < 0:
        raise ValueError("bad septet count or fill bits")
    need = (fill_bits + 7 * count + 7) // 8
    if len(data) < need:
        raise ValueError("user data truncated (%d < %d octets)" % (len(data), need))
    value = int.from_bytes(bytes(data[:need]), "little")
    return [(value >> (fill_bits + 7 * i)) & 0x7F for i in range(count)]


# ------------------------------------------------------------------ addresses
def _bcd(digits):
    nibbles = []
    for ch in digits:
        if ch.isdigit():
            nibbles.append(int(ch))
        elif ch == "*":
            nibbles.append(0xA)
        elif ch == "#":
            nibbles.append(0xB)
        else:
            raise ValueError("invalid character in number")
    if len(nibbles) % 2:
        nibbles.append(0xF)
    return bytes(nibbles[i] | (nibbles[i + 1] << 4) for i in range(0, len(nibbles), 2))


def _split_number(number):
    if not isinstance(number, str):
        raise ValueError("number must be a string")
    intl = number.startswith("+")
    digits = number[1:] if intl else number
    if not digits or len(digits) > 20 or any(ch not in "0123456789*#" for ch in digits):
        raise ValueError("invalid number")
    return intl, digits


def encode_address(number):
    """TP-DA/TP-OA: digit count, type of address (0x91 '+', else 0x81), BCD."""
    intl, digits = _split_number(number)
    return bytes([len(digits), 0x91 if intl else 0x81]) + _bcd(digits)


def _semi_octets(field, count):
    out = []
    for b in field:
        for nib in (b & 0x0F, b >> 4):
            if len(out) >= count or nib == 0xF:
                return "".join(out)
            out.append(_SEMI[nib])
    return "".join(out)


def decode_address(data, offset):
    """Parse a TP address at ``offset``; return (number_or_text, offset_after)."""
    if len(data) < offset + 2:
        raise ValueError("address truncated")
    ndig, toa = data[offset], data[offset + 1]
    nbytes = (ndig + 1) // 2
    end = offset + 2 + nbytes
    if len(data) < end or ndig > 40:
        raise ValueError("address truncated")
    raw = bytes(data[offset + 2:end])
    ton = (toa >> 4) & 0x07
    if ton == 0b101:
        text = gsm7_decode(unpack_septets(raw, ndig * 4 // 7))
        return text, end
    number = _semi_octets(raw, ndig)
    if ton == 0b001 and number:
        number = "+" + number
    return number, end


def encode_smsc(number):
    """RP address before a TPDU: b"\\x00" (default SMSC) or length + TOA + BCD."""
    if number is None or number == "":
        return b"\x00"
    intl, digits = _split_number(number)
    bcd = _bcd(digits)
    return bytes([1 + len(bcd), 0x91 if intl else 0x81]) + bcd


def decode_smsc(data, offset=0):
    if len(data) < offset + 1:
        raise ValueError("SMSC field truncated")
    length = data[offset]
    if length == 0:
        return None, offset + 1
    end = offset + 1 + length
    if len(data) < end or length > 11:
        raise ValueError("SMSC field truncated")
    toa = data[offset + 1]
    number = _semi_octets(bytes(data[offset + 2:end]), 2 * (length - 1))
    if ((toa >> 4) & 0x07) == 0b001 and number:
        number = "+" + number
    return number or None, end


# ------------------------------------------------------------------ timestamps
def _swapped(b):
    lo, hi = b & 0x0F, b >> 4
    if lo > 9 or hi > 9:
        raise ValueError("bad BCD")
    return lo * 10 + hi


def _decode_scts(data, offset):
    """7-octet service centre time stamp -> aware datetime (None if the date is invalid)."""
    if len(data) < offset + 7:
        raise ValueError("timestamp truncated")
    raw = data[offset:offset + 7]
    try:
        year, month, day, hour, minute, second = (_swapped(b) for b in raw[:6])
        tzb = raw[6]
        quarters = (tzb & 0x07) * 10 + (tzb >> 4)
        if tzb >> 4 > 9:
            raise ValueError("bad tz")
        if tzb & 0x08:
            quarters = -quarters
        tz = datetime.timezone(datetime.timedelta(minutes=15 * quarters))
        ts = datetime.datetime(2000 + year, month, day, hour, minute, second, tzinfo=tz)
    except ValueError:
        ts = None
    return ts, offset + 7


# ------------------------------------------------------------------ SMS-SUBMIT
_concat_counter = itertools.count(1)


def _next_concat_ref():
    return next(_concat_counter) & 0xFF


def split_text(text, force_ucs2=False):
    """Return (encoding, parts) with the SUBMIT splitting rules."""
    if not force_ucs2 and gsm7_encodable(text):
        if sum(_septet_len(ch) for ch in text) <= 160:
            return "gsm7", [text]
        limit, size_of = 153, _septet_len
        encoding = "gsm7"
    else:
        if len(text.encode("utf-16-be")) <= 140:
            return "ucs2", [text]
        limit, size_of = 67, (lambda ch: 2 if ord(ch) > 0xFFFF else 1)
        encoding = "ucs2"
    parts, cur, used = [], [], 0
    for ch in text:  # characters are never split: escape pairs and surrogate pairs stay whole
        n = size_of(ch)
        if used + n > limit:
            parts.append("".join(cur))
            cur, used = [], 0
        cur.append(ch)
        used += n
    if cur:
        parts.append("".join(cur))
    return encoding, parts


def _vp_minutes(v):
    if v <= 143:
        return (v + 1) * 5
    if v <= 167:
        return 720 + (v - 143) * 30
    if v <= 196:
        return (v - 166) * 1440
    return (v - 192) * 7 * 1440


def _vp_encode(minutes):
    for v in range(256):
        if _vp_minutes(v) >= minutes:
            return v
    return 255


def encode_submit(number, text, *, request_status_report=False, validity_minutes=None,
                  message_ref=0, concat_ref=None, force_ucs2=False):
    """SMS-SUBMIT TPDUs (no SMSC prefix), one per part."""
    da = encode_address(number)
    encoding, parts = split_text(text, force_ucs2)
    total = len(parts)
    if total > 255:
        raise ValueError("message needs more than 255 parts")
    if total > 1 and concat_ref is None:
        concat_ref = _next_concat_ref()
    out = []
    for seq, part in enumerate(parts, 1):
        first = 0x01
        if validity_minutes is not None:
            first |= 0x10
        if request_status_report:
            first |= 0x20
        udh = b""
        if total > 1:
            first |= 0x40
            udh = bytes([0x05, 0x00, 0x03, concat_ref & 0xFF, total, seq])
        if encoding == "gsm7":
            septets = gsm7_encode(part)
            if udh:
                ud = udh + pack_septets(septets, fill_bits=1)
                udl = 7 + len(septets)
            else:
                ud = pack_septets(septets)
                udl = len(septets)
            dcs = 0x00
        else:
            body = part.encode("utf-16-be")
            ud = udh + body
            udl = len(ud)
            dcs = 0x08
        tpdu = bytes([first, message_ref & 0xFF]) + da + bytes([0x00, dcs])
        if validity_minutes is not None:
            tpdu += bytes([_vp_encode(validity_minutes)])
        out.append(tpdu + bytes([udl]) + ud)
    return out


# ------------------------------------------------------------------ decoding
_VVM = re.compile(r"\s*//[A-Z0-9]*VVM", re.IGNORECASE)


@dataclass
class SmsDeliver:
    smsc: object
    originator: str
    pid: int
    dcs: int
    timestamp: object
    encoding: str
    text: str
    data: bytes
    udh: list = field(default_factory=list)
    concat: object = None
    more_messages: bool = False
    status_report_indication: bool = False
    reply_path: bool = False


@dataclass
class SmsStatusReport:
    smsc: object
    message_ref: int
    recipient: str
    scts: object
    discharge_time: object
    status: int


def _dcs_alphabet(dcs):
    """TS 23.038 §4: a receiver reads any reserved coding as the GSM 7-bit alphabet."""
    group = dcs >> 4
    if group <= 0x7:  # general data coding (00xx) and automatic deletion (01xx)
        if dcs & 0x20:
            raise ValueError("compressed text is not supported")
        return {0: "gsm7", 1: "8bit", 2: "ucs2", 3: "gsm7"}[(dcs >> 2) & 0x03]
    if group in (0xC, 0xD):
        return "gsm7"
    if group == 0xE:
        return "ucs2"
    if group == 0xF:
        return "8bit" if dcs & 0x04 else "gsm7"
    return "gsm7"  # reserved groups 1000..1011


def _parse_udh(header):
    ies, concat, i = [], None, 0
    while i < len(header):
        if i + 2 > len(header):
            raise ValueError("UDH truncated")
        iei, ln = header[i], header[i + 1]
        if i + 2 + ln > len(header):
            raise ValueError("UDH element truncated")
        value = bytes(header[i + 2:i + 2 + ln])
        ies.append((iei, value))
        if iei == 0x00 and ln == 3:
            ref, total, seq = value
            if total and 1 <= seq <= total:
                concat = (ref, total, seq)
        elif iei == 0x08 and ln == 4:
            ref, total, seq = (value[0] << 8) | value[1], value[2], value[3]
            if total and 1 <= seq <= total:
                concat = (ref, total, seq)
        i += 2 + ln
    return ies, concat


def _decode_user_data(pdu, offset, udl, alphabet, udhi):
    rest = bytes(pdu[offset:])
    ies, concat = [], None
    if alphabet == "gsm7":
        need = (udl * 7 + 7) // 8
        if len(rest) < need:
            raise ValueError("user data truncated")
        rest = rest[:need]
        fill, skip_septets, body = 0, 0, rest
        if udhi:
            if not rest:
                raise ValueError("UDH missing")
            udhl = rest[0]
            if udhl + 1 > len(rest):
                raise ValueError("UDH longer than user data")
            ies, concat = _parse_udh(rest[1:1 + udhl])
            hbits = (udhl + 1) * 8
            fill = (7 - hbits % 7) % 7
            skip_septets = (hbits + fill) // 7
            body = rest[udhl + 1:]
        count = udl - skip_septets
        if count < 0:
            raise ValueError("UDL smaller than the UDH")
        septets = unpack_septets(body, count, fill)
        return gsm7_decode(septets), bytes(body), ies, concat
    if len(rest) < udl:
        raise ValueError("user data truncated")
    ud = rest[:udl]
    if udhi:
        if not ud:
            raise ValueError("UDH missing")
        udhl = ud[0]
        if udhl + 1 > len(ud):
            raise ValueError("UDH longer than user data")
        ies, concat = _parse_udh(ud[1:1 + udhl])
        ud = ud[udhl + 1:]
    if alphabet == "ucs2":
        if len(ud) % 2:
            raise ValueError("odd UCS2 length")
        return ud.decode("utf-16-be", "replace"), bytes(ud), ies, concat
    return "", bytes(ud), ies, concat


def decode_pdu(pdu, has_smsc=True):
    """Decode an SMS-DELIVER or SMS-STATUS-REPORT (optionally after the RP SMSC field)."""
    pdu = bytes(pdu)
    smsc, off = (decode_smsc(pdu, 0) if has_smsc else (None, 0))
    if len(pdu) < off + 1:
        raise ValueError("TPDU truncated")
    first = pdu[off]
    mti = first & 0x03
    off += 1
    if mti == 0x00:
        originator, off = decode_address(pdu, off)
        if len(pdu) < off + 2:
            raise ValueError("TPDU truncated")
        pid, dcs = pdu[off], pdu[off + 1]
        ts, off = _decode_scts(pdu, off + 2)
        if len(pdu) < off + 1:
            raise ValueError("UDL missing")
        udl = pdu[off]
        alphabet = _dcs_alphabet(dcs)
        text, data, ies, concat = _decode_user_data(pdu, off + 1, udl, alphabet, bool(first & 0x40))
        return SmsDeliver(smsc=smsc, originator=originator, pid=pid, dcs=dcs, timestamp=ts,
                          encoding=alphabet, text=text, data=data, udh=ies, concat=concat,
                          more_messages=not (first & 0x04), status_report_indication=bool(first & 0x20),
                          reply_path=bool(first & 0x80))
    if mti == 0x02:
        if len(pdu) < off + 1:
            raise ValueError("TPDU truncated")
        mr = pdu[off]
        recipient, off = decode_address(pdu, off + 1)
        scts, off = _decode_scts(pdu, off)
        dt, off = _decode_scts(pdu, off)
        if len(pdu) < off + 1:
            raise ValueError("status missing")
        return SmsStatusReport(smsc=smsc, message_ref=mr, recipient=recipient, scts=scts,
                               discharge_time=dt, status=pdu[off])
    raise ValueError("unsupported TP-MTI %d" % mti)


def service_message(msg):
    """What an SMS-DELIVER is when it is meant for a service and not for a person, or None.

    These are acknowledged and never reach a client, which would show a blank bubble or
    a false conversation. Port-addressed and binary messages are WAP push (an MMS notice)
    and the like; the CP stores nothing for us, and no MMS client exists here. A //VVM
    message drives visual voicemail and a STATUS one can carry IMAP credentials, so its
    text must not sit on the bus. TP-PID 0x40 is a "silent" SMS and DCS group 1100 says
    "discard": 3GPP TS 23.040 §9.2.3.9 and TS 23.038 §4.
    """
    if any(iei in (0x04, 0x05) for iei, _ in msg.udh):
        return "port"
    if msg.pid == 0x40:
        return "silent"
    if msg.dcs >> 4 == 0xC:
        return "discard"
    if msg.encoding == "8bit":
        return "binary"
    if _VVM.match(msg.text):
        return "vvm"
    return None


class ConcatAssembler:
    """Reassemble concatenated SMS-DELIVER parts keyed by (originator, ref, total)."""

    def __init__(self, timeout_s=3600.0):
        self.timeout_s = timeout_s
        self._groups = {}

    def pending_count(self):
        return len(self._groups)

    def feed(self, msg, now=None):
        import time
        now = time.monotonic() if now is None else now
        for key in [k for k, g in self._groups.items() if now - g["t"] > self.timeout_s]:
            del self._groups[key]
        if not msg.concat:
            return msg
        ref, total, seq = msg.concat
        key = (msg.originator, ref, total)
        group = self._groups.setdefault(key, {"t": now, "parts": {}})
        group["parts"].setdefault(seq, msg)
        if len(group["parts"]) < total:
            return None
        del self._groups[key]
        parts = [group["parts"][i] for i in sorted(group["parts"])]
        return replace(parts[0], text="".join(p.text for p in parts),
                       data=b"".join(p.data for p in parts), concat=None)
