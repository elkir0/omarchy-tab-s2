# SPDX-License-Identifier: GPL-2.0-or-later
"""SMS PDU codec tests (offline).  Numbers are from ranges reserved for fiction."""

import datetime
import unittest

import testutil  # noqa: F401
from shannond import sms_pdu as P

SMSC_FIELD = bytes.fromhex("07913336990890F9")         # +33639980099
OA_FIELD = bytes.fromhex("0C91447700094065")           # +447700900456
SCTS = bytes.fromhex("62019212035140")                 # 2026-10-29 21:30:15 +01:00
HELLOHELLO = bytes.fromhex("E8329BFD4697D9EC37")


def deliver(ud, udl, dcs=0x00, first=0x04, oa=OA_FIELD, scts=SCTS, smsc=SMSC_FIELD):
    return smsc + bytes([first]) + oa + bytes([0x00, dcs]) + scts + bytes([udl]) + ud


class SeptetTest(unittest.TestCase):
    def test_known_packings(self):
        self.assertEqual(P.pack_septets(P.gsm7_encode("hellohello")), HELLOHELLO)
        self.assertEqual(P.gsm7_decode(P.unpack_septets(bytes.fromhex("C8329BFD06"), 5)), "Hello")

    def test_round_trips_with_fill_bits(self):
        for n in range(1, 21):
            septets = [(i * 37 + n) & 0x7F for i in range(n)]
            for fill in range(7):
                self.assertEqual(P.unpack_septets(P.pack_septets(septets, fill), n, fill), septets, (n, fill))

    def test_unpack_truncated(self):
        with self.assertRaises(ValueError):
            P.unpack_septets(b"\x00", 3)

    def test_extension_table(self):
        text = "€[]{}~\\|^"
        septets = P.gsm7_encode(text)
        self.assertEqual(len(septets), 2 * len(text))
        self.assertEqual(P.gsm7_decode(septets), text)

    def test_unknown_extension_and_lone_escape(self):
        self.assertEqual(P.gsm7_decode([0x1B, 0x41]), "A")
        self.assertEqual(P.gsm7_decode([0x41, 0x1B]), "A")

    def test_encodable(self):
        self.assertTrue(P.gsm7_encodable("@£$¥èéùìòÇ"))
        self.assertFalse(P.gsm7_encodable("Привет"))
        self.assertFalse(P.gsm7_encodable("ok \U0001F600"))
        with self.assertRaises(ValueError):
            P.gsm7_encode("Привет")


class AddressTest(unittest.TestCase):
    def test_encode(self):
        self.assertEqual(P.encode_address("+447700900123"), bytes.fromhex("0C91447700091032"))
        self.assertEqual(P.encode_address("0639980012"), bytes.fromhex("0A816093890021"))
        self.assertEqual(P.encode_address("12345"), bytes.fromhex("05812143F5"))
        self.assertEqual(P.encode_address("*21#"), bytes.fromhex("04812AB1"))  # nibbles A,2 | 1,B

    def test_invalid(self):
        for bad in ("", "+", "12a4", "+33 6", "1" * 21, None):
            with self.assertRaises(ValueError):
                P.encode_address(bad)

    def test_decode_round_trip(self):
        for number in ("+447700900123", "0639980012", "12345", "+33639980012"):
            field = P.encode_address(number)
            self.assertEqual(P.decode_address(b"\xAA" + field, 1), (number, 1 + len(field)))

    def test_alphanumeric(self):
        septets = P.gsm7_encode("InfoSMS")
        packed = P.pack_septets(septets)
        field = bytes([(len(septets) * 7 + 3) // 4, 0xD0]) + packed
        self.assertEqual(P.decode_address(field, 0), ("InfoSMS", len(field)))

    def test_smsc(self):
        self.assertEqual(P.encode_smsc(None), b"\x00")
        self.assertEqual(P.encode_smsc(""), b"\x00")
        self.assertEqual(P.encode_smsc("+33639980099"), SMSC_FIELD)
        self.assertEqual(P.decode_smsc(SMSC_FIELD), ("+33639980099", 8))
        self.assertEqual(P.decode_smsc(b"\x00\x04"), (None, 1))
        with self.assertRaises(ValueError):
            P.decode_smsc(b"\x07\x91\x33")


class SubmitTest(unittest.TestCase):
    def test_single_gsm7_exact(self):
        self.assertEqual(P.encode_submit("+447700900123", "hellohello"),
                         [bytes.fromhex("01000C914477000910320000" "0A") + HELLOHELLO])

    def test_validity_and_status_report(self):
        tpdu = P.encode_submit("+447700900123", "x", validity_minutes=24 * 60, request_status_report=True,
                               message_ref=0x42)[0]
        self.assertEqual(tpdu[0], 0x31)
        self.assertEqual(tpdu[1], 0x42)
        self.assertEqual(tpdu[12], 0xA7)
        for minutes, value in ((5, 0x00), (12 * 60, 0x8F), (2 * 1440, 0xA8), (5 * 7 * 1440, 0xC5),
                               (1, 0x00), (10 ** 9, 0xFF)):
            self.assertEqual(P._vp_encode(minutes), value, minutes)

    def test_ucs2_single(self):
        tpdu = P.encode_submit("+447700900123", "Привет")[0]
        self.assertEqual(tpdu[11], 0x08)
        self.assertEqual(tpdu[12], 12)
        self.assertEqual(tpdu[13:], "Привет".encode("utf-16-be"))

    def test_gsm7_concatenation(self):
        text = "".join(chr(ord("a") + i % 26) for i in range(161))
        parts = P.encode_submit("+447700900123", text, concat_ref=0x5A)
        self.assertEqual(len(parts), 2)
        texts = []
        for seq, tpdu in enumerate(parts, 1):
            self.assertEqual(tpdu[0], 0x41)
            udl = tpdu[12]
            ud = tpdu[13:]
            self.assertEqual(ud[:6], bytes([5, 0, 3, 0x5A, 2, seq]))
            texts.append(P.gsm7_decode(P.unpack_septets(ud[6:], udl - 7, 1)))
        self.assertEqual(parts[0][12], 160)
        self.assertEqual("".join(texts), text)
        self.assertEqual(len(texts[0]), 153)

    def test_escape_pair_not_split(self):
        text = "a" * 152 + "€" + "b" * 10
        enc, parts = P.split_text(text)
        self.assertEqual(enc, "gsm7")
        self.assertEqual(parts[0], "a" * 152)
        self.assertTrue(parts[1].startswith("€"))

    def test_ucs2_concatenation_and_surrogates(self):
        enc, parts = P.split_text("Ж" * 71)
        self.assertEqual((enc, [len(p) for p in parts]), ("ucs2", [67, 4]))
        self.assertEqual(len(P.split_text("Ж" * 66 + "\U0001F600" + "Ж")[1]), 1, "69 units fit in one part")
        text = "Ж" * 66 + "\U0001F600" + "Ж" * 10
        enc, parts = P.split_text(text)
        self.assertEqual(parts[0], "Ж" * 66)
        self.assertTrue(parts[1].startswith("\U0001F600"))
        tpdus = P.encode_submit("+447700900123", "Ж" * 71, concat_ref=7)
        self.assertEqual(tpdus[0][11], 0x08)
        self.assertEqual(tpdus[0][12], 6 + 134)

    def test_auto_ref_and_limits(self):
        a = P.encode_submit("+447700900123", "x" * 200)
        b = P.encode_submit("+447700900123", "x" * 200)
        self.assertNotEqual(a[0][16], b[0][16])
        self.assertEqual(len(P.split_text("x" * 160)[1]), 1)
        self.assertEqual(len(P.split_text("€" * 80)[1]), 1)
        self.assertEqual(len(P.split_text("€" * 81)[1]), 2)
        with self.assertRaises(ValueError):
            P.encode_submit("+447700900123", "x" * (153 * 256))
        self.assertEqual(P.split_text("abc", force_ucs2=True)[0], "ucs2")


class DeliverTest(unittest.TestCase):
    def test_gsm7(self):
        msg = P.decode_pdu(deliver(HELLOHELLO, 10))
        self.assertIsInstance(msg, P.SmsDeliver)
        self.assertEqual((msg.smsc, msg.originator, msg.text, msg.encoding), ("+33639980099", "+447700900456",
                                                                              "hellohello", "gsm7"))
        tz = datetime.timezone(datetime.timedelta(hours=1))
        self.assertEqual(msg.timestamp, datetime.datetime(2026, 10, 29, 21, 30, 15, tzinfo=tz))
        self.assertFalse(msg.more_messages)
        self.assertIsNone(msg.concat)

    def test_ucs2_and_8bit(self):
        body = "Привет".encode("utf-16-be")
        self.assertEqual(P.decode_pdu(deliver(body, len(body), dcs=0x08)).text, "Привет")
        msg = P.decode_pdu(deliver(b"\x01\x02\x03", 3, dcs=0x04))
        self.assertEqual((msg.encoding, msg.text, msg.data), ("8bit", "", b"\x01\x02\x03"))

    def test_alphanumeric_originator_negative_tz_no_smsc(self):
        septets = P.gsm7_encode("InfoSMS")
        oa = bytes([13, 0xD0]) + P.pack_septets(septets)
        scts = bytes.fromhex("6201921203510A")  # -05:00
        msg = P.decode_pdu(deliver(HELLOHELLO, 10, oa=oa, scts=scts, smsc=b""), has_smsc=False)
        self.assertEqual(msg.originator, "InfoSMS")
        self.assertIsNone(msg.smsc)
        self.assertEqual(msg.timestamp.utcoffset(), datetime.timedelta(hours=-5))

    def test_concat_udh_8bit_and_16bit(self):
        septets = P.gsm7_encode("Test 123")
        ud = bytes([5, 0, 3, 9, 2, 1]) + P.pack_septets(septets, 1)
        msg = P.decode_pdu(deliver(ud, 7 + len(septets), first=0x44))
        self.assertEqual((msg.text, msg.concat), ("Test 123", (9, 2, 1)))
        ud16 = bytes([6, 8, 4, 0x12, 0x34, 3, 2]) + P.pack_septets(septets, 0)
        msg = P.decode_pdu(deliver(ud16, 8 + len(septets), first=0x44))
        self.assertEqual((msg.text, msg.concat), ("Test 123", (0x1234, 3, 2)))
        body = "Bonjour".encode("utf-16-be")
        msg = P.decode_pdu(deliver(bytes([5, 0, 3, 1, 1, 1]) + body, 6 + len(body), dcs=0x08, first=0x44))
        self.assertEqual((msg.text, msg.concat), ("Bonjour", (1, 1, 1)))

    def test_message_waiting_and_reserved_dcs(self):
        self.assertEqual(P.decode_pdu(deliver(HELLOHELLO, 10, dcs=0xC0)).encoding, "gsm7")
        self.assertEqual(P.decode_pdu(deliver(b"\x00\x41", 2, dcs=0xE0)).text, "A")
        self.assertEqual(P.decode_pdu(deliver(HELLOHELLO, 10, dcs=0xF0)).text, "hellohello")
        with self.assertRaises(ValueError):
            P.decode_pdu(deliver(HELLOHELLO, 10, dcs=0x20))  # compressed

    def test_reserved_codings_read_as_gsm7(self):
        # TS 23.038 section 4: a person's message, which must not be dropped as binary.
        for dcs in (0x0C, 0x1C, 0x80, 0xB3):
            msg = P.decode_pdu(deliver(HELLOHELLO, 10, dcs=dcs))
            self.assertEqual((msg.encoding, msg.text), ("gsm7", "hellohello"), hex(dcs))
            self.assertIsNone(P.service_message(msg), hex(dcs))

    def test_invalid_timestamp_is_tolerated(self):
        msg = P.decode_pdu(deliver(HELLOHELLO, 10, scts=bytes.fromhex("62FF9212035140")))
        self.assertIsNone(msg.timestamp)
        self.assertEqual(msg.text, "hellohello")

    def test_status_report(self):
        pdu = SMSC_FIELD + bytes([0x06, 0x42]) + P.encode_address("+447700900123") + SCTS + SCTS + b"\x00"
        rep = P.decode_pdu(pdu)
        self.assertIsInstance(rep, P.SmsStatusReport)
        self.assertEqual((rep.message_ref, rep.recipient, rep.status), (0x42, "+447700900123", 0))

    def test_unsupported_mti(self):
        with self.assertRaises(ValueError):
            P.decode_pdu(SMSC_FIELD + b"\x01\x00")

    def test_truncation_always_value_error(self):
        septets = P.gsm7_encode("Test 123")
        samples = [deliver(HELLOHELLO, 10),
                   deliver(bytes([5, 0, 3, 9, 2, 1]) + P.pack_septets(septets, 1), 7 + len(septets), first=0x44),
                   SMSC_FIELD + bytes([0x06, 0x42]) + P.encode_address("+447700900123") + SCTS + SCTS + b"\x00"]
        for pdu in samples:
            for n in range(len(pdu)):
                with self.assertRaises(ValueError, msg="prefix %d" % n):
                    P.decode_pdu(pdu[:n])

    def test_inconsistent_udh(self):
        with self.assertRaises(ValueError):
            P.decode_pdu(deliver(bytes([9, 0, 3, 1, 2, 1]), 6, dcs=0x04, first=0x44))
        with self.assertRaises(ValueError):
            P.decode_pdu(deliver(bytes([5, 0, 3, 1, 2, 1]), 3, first=0x44))


class AssemblerTest(unittest.TestCase):
    def part(self, seq, text, total=3, ref=4, oa="+447700900456"):
        return P.SmsDeliver(smsc=None, originator=oa, pid=0, dcs=0, timestamp=None, encoding="gsm7",
                            text=text, data=text.encode(), concat=(ref, total, seq))

    def test_out_of_order_and_duplicates(self):
        a = P.ConcatAssembler()
        self.assertIsNone(a.feed(self.part(3, "c"), now=0))
        self.assertIsNone(a.feed(self.part(1, "a"), now=1))
        self.assertIsNone(a.feed(self.part(1, "X"), now=2))
        whole = a.feed(self.part(2, "b"), now=3)
        self.assertEqual((whole.text, whole.data, whole.concat), ("abc", b"abc", None))
        self.assertEqual(a.pending_count(), 0)

    def test_timeout_and_passthrough(self):
        a = P.ConcatAssembler(timeout_s=10)
        a.feed(self.part(1, "a"), now=0)
        self.assertEqual(a.pending_count(), 1)
        a.feed(self.part(1, "z", ref=5), now=11)
        self.assertEqual(a.pending_count(), 1)
        single = P.SmsDeliver(None, "+447700900456", 0, 0, None, "gsm7", "hi", b"hi")
        self.assertIs(a.feed(single, now=12), single)

    def test_end_to_end_with_submit_vectors(self):
        text = "Bonjour " * 30
        tpdus = P.encode_submit("+447700900456", text, concat_ref=3)
        a = P.ConcatAssembler()
        result = None
        for tpdu in reversed(tpdus):
            ud = tpdu[13:]
            pdu = deliver(ud, tpdu[12], first=0x44)
            result = a.feed(P.decode_pdu(pdu), now=0) or result
        self.assertEqual(result.text, text)


class ServiceMessageTest(unittest.TestCase):
    def deliver(self, **kw):
        values = dict(smsc=None, originator="+447700900456", pid=0, dcs=0, timestamp=None,
                      encoding="gsm7", text="hello", data=b"")
        values.update(kw)
        return P.SmsDeliver(**values)

    def test_a_person_writes(self):
        for msg in (self.deliver(), self.deliver(encoding="ucs2", dcs=8, text="Привет"),
                    self.deliver(text="see //VVM in the middle"),
                    self.deliver(text="http://vvm.example"),
                    self.deliver(udh=[(0x00, bytes([1, 2, 1]))], concat=(1, 2, 1))):
            self.assertIsNone(P.service_message(msg), msg)

    def test_service_messages(self):
        for kind, msg in (("port", self.deliver(udh=[(0x05, bytes.fromhex("0B8423F0"))], encoding="8bit", text="")),
                          ("port", self.deliver(udh=[(0x04, bytes([1, 2]))])),
                          ("silent", self.deliver(pid=0x40, text="")),
                          ("discard", self.deliver(dcs=0xC8, text="")),
                          ("binary", self.deliver(dcs=0x04, encoding="8bit", text="", data=b"\x01")),
                          ("vvm", self.deliver(text="//VVM:STATUS:st=N;rc=0")),
                          ("vvm", self.deliver(text="//vvm:sync:ev=NM")),
                          ("vvm", self.deliver(text="  //VZWVVM:SYNC:ev=NM"))):
            self.assertEqual(P.service_message(msg), kind, msg)


if __name__ == "__main__":
    unittest.main()
