# SPDX-License-Identifier: GPL-2.0-or-later
"""IPC 4.1 payload codecs against the catalogue (research/modem/research/analysis/ipc41_catalogue.md).

Sizes come from §11 and the "Payload (IPC41)" columns of §1-§10; offsets are
written here from the catalogue text (p0 = first payload byte, little-endian).
Offline tests; all identifiers are fictional.
"""

import struct
import unittest

import testutil  # noqa: F401
from shannond import defs, messages as m


class EncoderSizeTest(unittest.TestCase):
    """Catalogue sizes: 92/105/127/194/85/19/9/2/1 bytes ... (SYNTHESIS v2 O5)."""

    CASES = [
        ("pwr_phone_state", lambda: m.pwr_phone_state(defs.PWR_STATE_NORMAL), 2),
        ("misc_me_version_get", m.misc_me_version_get, 1),
        ("misc_me_imsi_get", m.misc_me_imsi_get, 0),
        ("misc_me_sn_get", m.misc_me_sn_get, 1),
        ("misc_loopback_cfrm", lambda: m.misc_loopback_cfrm(0x1234), 2),
        ("sec_pin_status_get", m.sec_pin_status_get, 0),
        ("sec_pin_status_set", lambda: m.sec_pin_status_set("1234"), 19),
        ("sec_lock_info_get", m.sec_lock_info_get, 9),
        ("net_regist_get", lambda: m.net_regist_get(defs.NET_DOMAIN_CS), 2),
        ("net_serving_get", m.net_serving_get, 0),
        ("net_mode_sel_set", m.net_mode_sel_set, 1),
        ("net_plmn_sel_set", m.net_plmn_sel_set_auto, 8),
        ("disp_icon_info_get", m.disp_icon_info_get, 1),
        ("sms_deliver_report", lambda: m.sms_deliver_report(5), 5),
        ("sms_device_ready_set", m.sms_device_ready_set, 0),
        ("call_outgoing", lambda: m.call_outgoing("+447700900123"), 92),
        ("call_cont_dtmf", lambda: m.call_cont_dtmf(True, "5"), 2),
        ("call_burst_dtmf", lambda: m.call_burst_dtmf("123"), 84),
        ("ss_manage_call", lambda: m.ss_manage_call(3, 1), 85),
        ("gprs_define_pdp_context", lambda: m.gprs_define_pdp_context(1, "internet"), 127),
        ("gprs_pdp_context_set", lambda: m.gprs_pdp_context_set(1, 1), 105),
        ("gprs_lte_attach_apn_info", lambda: m.gprs_lte_attach_apn_info(1, "internet"), 194),
        ("snd_audio_path", lambda: m.snd_audio_path(defs.SND_PATH_SPEAKER), 2),
        ("snd_spkr_volume", lambda: m.snd_spkr_volume(defs.SND_VOLUME_SPEAKER, 4), 2),
        ("snd_mic_mute", lambda: m.snd_mic_mute(0), 1),
        ("snd_clock_ctrl", lambda: m.snd_clock_ctrl(True), 1),
        ("snd_two_mic", m.snd_two_mic, 2),
    ]

    def test_sizes(self):
        for name, fn, size in self.CASES:
            with self.subTest(name):
                self.assertEqual(len(fn()), size)
                self.assertEqual(m.ENCODED_SIZES[name], size)

    def test_table_covers_every_case(self):
        self.assertEqual(set(m.ENCODED_SIZES), {c[0] for c in self.CASES})


class PowerTest(unittest.TestCase):
    def test_phone_state_bytes(self):
        self.assertEqual(m.pwr_phone_state(0x0202), b"\x02\x02")
        self.assertEqual(m.pwr_phone_state(0x0001), b"\x01\x00")
        with self.assertRaises(ValueError):
            m.pwr_phone_state(0x0003)

    def test_phone_state_noti(self):
        self.assertEqual(m.dec_phone_state(b"\x01").power, "lpm")
        for v in (2, 3, 4):
            self.assertEqual(m.dec_phone_state(bytes([v])).power, "on")
        self.assertEqual(m.dec_phone_state(b"\x09").power, "unknown")

    def test_gen_phone_res(self):
        g = m.dec_gen_phone_res(bytes([0x01, 0x07, 0x01]) + struct.pack("<H", 0x8000))
        self.assertEqual((g.group, g.index, g.type, g.code), (1, 7, 1, 0x8000))


class IdentityTest(unittest.TestCase):
    def test_requests(self):
        self.assertEqual(m.misc_me_version_get(), b"\xff")
        self.assertEqual(m.misc_me_sn_get(), b"\x01")

    def test_decoders(self):
        self.assertEqual(m.dec_me_imsi(b"\x0f" + b"001010000000001"), "001010000000001")
        sn = m.dec_me_sn(b"\x01\x0f" + b"000000000000000")
        self.assertEqual((sn.sn_type, sn.value), (1, "000000000000000"))
        ver = m.dec_me_version(b"\x0f" + b"SW-1".ljust(32, b"\0") + b"HW-2".ljust(32, b"\0"))
        self.assertEqual((ver.sw, ver.hw, ver.cal_date), ("SW-1", "HW-2", ""))
        self.assertEqual(m.dec_iccid(b"\x0a" + bytes.fromhex("98103254769810325476")), "89012345678901234567")


class SimTest(unittest.TestCase):
    def test_pin_status_mapping(self):
        cases = {(0x00, 0): ("ready", None), (0x83, 0): ("ready", None), (0x03, 0): ("ready", None),
                 (0x03, 1): ("locked", "sim-pin"), (0x03, 2): ("locked", "sim-puk"),
                 (0x03, 5): ("locked", "blocked"), (0x05, 0): ("locked", "ph-net-pin"),
                 (0x80, 0): ("absent", None), (0x81, 0): ("error", None), (0x8B, 0): ("unknown", None)}
        for (status, fac), expected in cases.items():
            self.assertEqual(m.dec_pin_status(bytes([status, fac])).sim_state(), expected, hex(status))

    def test_pin_status_set_layout(self):
        p = m.sec_pin_status_set("1234")
        self.assertEqual(p[:3], bytes([0x03, 4, 0]))
        self.assertEqual(p[3:11], b"1234\0\0\0\0")
        self.assertEqual(p[11:19], bytes(8))
        puk = m.sec_pin_status_set("5678", "12345678")
        self.assertEqual(puk[2], 8)
        self.assertEqual(puk[11:19], b"12345678")
        for bad in ("12a4", "123", "123456789"):
            with self.assertRaises(ValueError):
                m.sec_pin_status_set(bad)

    def test_lock_info(self):
        self.assertEqual(m.sec_lock_info_get(), bytes([0x01, 0x03]) + bytes(7))
        info = m.dec_lock_info(bytes([1, 3, 1, 2]))
        self.assertEqual((info.lock_type, info.retries), (3, 2))

    def test_icc_type(self):
        self.assertEqual(m.dec_icc_type(b"\x01"), "sim")
        self.assertEqual(m.dec_icc_type(b"\x02"), "usim")


class NetworkTest(unittest.TestCase):
    def regist(self, status=2, act=0x21, domain=2, full=True):
        p = struct.pack("<BBBBHIB", act, domain, status, 0, 0x1234, 0x00ABCDEF, 7)
        if full:
            p += struct.pack("<HBBBHB", 0x5678, 1, 0, 0, 0x0042, 0)
        return p

    def test_requests(self):
        self.assertEqual(m.net_regist_get(2), b"\xff\x02")
        self.assertEqual(m.net_regist_get(3), b"\xff\x03")
        self.assertEqual(m.net_mode_sel_set(), b"\x0b")
        self.assertEqual(m.net_plmn_sel_set_auto(), b"\x02" + bytes(6) + b"\xff")
        self.assertEqual(m.net_plmn_sel_set_manual("00101"), b"\x0300101#\xff")
        with self.assertRaises(ValueError):
            m.net_regist_get(1)

    def test_regist_prefix_and_full(self):
        r = m.dec_regist(self.regist(full=False))
        self.assertEqual((r.lac, r.cell_id, r.reject_cause, r.tac), (0x1234, 0x00ABCDEF, 7, 0))
        r = m.dec_regist(self.regist())
        self.assertEqual((r.tac, r.volte, r.pci), (0x5678, 1, 0x0042))
        self.assertEqual(len(self.regist()), 19)

    def test_regist_state_and_rat(self):
        for status, name in ((1, "idle"), (2, "home"), (3, "searching"), (4, "denied"), (6, "roaming"),
                             (9, "denied"), (0x0A, "idle"), (5, "unknown")):
            self.assertEqual(m.dec_regist(self.regist(status=status)).state, name)
        for act, rat in ((0x21, "lte"), (0x04, "umts"), (0x03, "gsm"), (0x01, "gsm"), (0x13, None)):
            self.assertEqual(m.dec_regist(self.regist(act=act)).rat, rat)

    def test_serving(self):
        p = bytes([0, 2, 0x21]) + b"00101#" + struct.pack("<H", 0x1234) + bytes(15)
        self.assertEqual(len(p), 26)
        s = m.dec_serving(p)
        self.assertEqual((s.status, s.act, s.mcc, s.mnc, s.lac), (2, 0x21, "001", "01", 0x1234))
        s = m.dec_serving(bytes([0, 2, 0x21]) + b"001010" + b"\0\0")
        self.assertEqual(s.mnc, "010")

    def test_signal(self):
        rssi = m.dec_rssi_info(bytes([85, 3, 0, 0, 95, 10]) + struct.pack("<h", 212) + b"\xff")
        self.assertEqual((rssi.rssi_dbm, rssi.rsrp_dbm, rssi.rssnr), (-85, -95, 12))
        self.assertEqual(rssi.percent, round((-95 + 140) * 100 / 96))
        self.assertEqual(m.dec_rssi_info(bytes([75])).percent, round(((113 - 75) // 2) * 100 / 31))
        icon = m.dec_icon_info(bytes([1, 3, 0, 0, 0, 100, 9]) + struct.pack("<h", 200) + b"\xff")
        self.assertEqual((icon.bars, icon.rsrp_dbm), (3, -100))
        self.assertEqual(m.dec_icon_info(b"\x01\x02").percent, 50)

    def test_plmn_list_and_identity(self):
        entries = m.dec_plmn_list(bytes([2]) + bytes([2]) + b"00101#" + bytes([0x21, 0, 0])
                                  + bytes([3]) + b"001010" + bytes([0x04, 0, 0]))
        self.assertEqual([(e.status, e.plmn, e.act) for e in entries], [(2, "00101", 0x21), (3, "001010", 4)])
        p = bytearray(110)
        p[1] = 0x03
        p[3], p[4], p[5:9] = 4, 0, b"TEST"
        p[38], p[39], p[40:52] = 12, 0, b"Test network"
        p[104:110] = b"00101#"
        ident = m.dec_net_identity(bytes(p))
        self.assertEqual((ident.short_name, ident.full_name, ident.plmn), ("TEST", "Test network", "00101"))


class CallTest(unittest.TestCase):
    def test_outgoing_layout(self):
        p = m.call_outgoing("+447700900123", clir=2, extra=0x5A)
        self.assertEqual(p[0:2], b"\x00\x01")      # voice call type, LE u16 0x0100
        self.assertEqual(p[2], 2)                 # CLIR
        self.assertEqual(p[3], 12)                # length without '+'
        self.assertEqual(p[4], 0x11)              # international TON
        self.assertEqual(p[5:17], b"447700900123")
        self.assertEqual(p[17:91], bytes(74))
        self.assertEqual(p[91], 0x5A)
        self.assertEqual(m.call_outgoing("06 39 98 00 12")[3:15], b"\x0a\x210639980012")

    def test_emergency_refused(self):
        for number in ("112", "911", "15", "17", "18", "115", "119", "999", "000", "08", "110", "+112", "1 1 2",
                       "1-1-2", "112#"):
            with self.assertRaises(m.EmergencyCallRefused, msg=number):
                m.call_outgoing(number)
        for call_type in (0x07, 0x08):
            with self.assertRaises(m.EmergencyCallRefused):
                m.call_outgoing("+447700900123", call_type=call_type)
        self.assertFalse(m.is_emergency_number("0639980012"))
        self.assertFalse(m.is_emergency_number("1120"))
        with self.assertRaises(ValueError):
            m.call_outgoing("12a")

    def test_dtmf_and_manage(self):
        self.assertEqual(m.call_cont_dtmf(True, "#"), b"\x01#")
        self.assertEqual(m.call_cont_dtmf(False), b"\x02\x00")
        self.assertEqual(m.call_burst_dtmf("12")[:4], b"\x01\x0212")
        self.assertEqual(m.ss_manage_call(3, 2)[:3], b"\x03\x02\x00")
        with self.assertRaises(ValueError):
            m.call_cont_dtmf(True, "x")

    def test_status_and_list(self):
        st = m.dec_call_status(bytes([0x00, 0x01, 2, 3, 0, 16]))
        self.assertEqual((st.call_id, st.state, st.end_cause), (2, "active", 16))
        self.assertEqual(m.dec_call_status(bytes([0, 1, 2, 4, 1, 16])).state, "released")
        self.assertEqual(m.dec_call_status(bytes([0, 1, 2, 5, 0, 0])).state, "alerting")
        body = bytes([2])
        body += struct.pack("<HBBBBBB", 0x0100, 1, 1, 1, 0, 12, 0x11) + b"447700900123"
        body += struct.pack("<HBBBBBB", 0x0100, 2, 0, 5, 0, 10, 0x21) + b"0639980012"
        calls = m.dec_call_list(body)
        self.assertEqual([(c.call_id, c.direction, c.state, c.number) for c in calls],
                         [(1, "out", "active", "+447700900123"), (2, "in", "incoming", "0639980012")])
        self.assertEqual(m.dec_call_incoming(bytes([0, 1, 3, 1])).call_id, 3)


class SmsTest(unittest.TestCase):
    def test_send_msg_header(self):
        smsc = bytes.fromhex("07913336990890F9")
        tpdu = b"\x01\x00\x0a"
        p = m.sms_send_msg(smsc, tpdu)
        self.assertEqual(p[:4], bytes([0x02, 0x02, 0x02, len(smsc) + len(tpdu)]))
        self.assertEqual(p[4:], smsc + tpdu)
        self.assertEqual(m.sms_send_msg(b"\x00", tpdu, more=True, domain=0x00)[:3], b"\x02\x01\x00")

    def test_deliver_report(self):
        self.assertEqual(m.sms_deliver_report(7), b"\x02\x00\x00\x07\x00")
        self.assertEqual(m.sms_deliver_report(7, 0x8080), b"\x02\x80\x80\x07\x00")

    def test_decoders(self):
        inc = m.dec_sms_incoming(struct.pack("<BBHBB", 2, 1, 0xFFFF, 9, 3) + b"abc")
        self.assertEqual((inc.fmt, inc.msg_type, inc.sim_index, inc.msg_id, inc.pdu), (2, 1, 0xFFFF, 9, b"abc"))
        res = m.dec_sms_send_msg(struct.pack("<BHBB", 2, 0, 0x21, 2) + b"\x00\x00")
        self.assertEqual((res.ok, res.ref, res.pdu), (True, 0x21, b"\x00\x00"))
        self.assertFalse(m.dec_sms_send_msg(struct.pack("<BHB", 2, 0x8016, 1)).ok)
        self.assertEqual(m.dec_svc_center_addr(bytes.fromhex("07913336990890F9")), bytes.fromhex("07913336990890F9"))
        with self.assertRaises(m.DecodeError):
            m.dec_svc_center_addr(b"\x07\x91")
        with self.assertRaises(m.DecodeError):
            m.dec_sms_incoming(struct.pack("<BBHBB", 2, 1, 0, 9, 10) + b"abc")


class DataTest(unittest.TestCase):
    def test_define_pdp(self):
        p = m.gprs_define_pdp_context(2, "test.apn", defs.GPRS_PDP_IPV4V6)
        self.assertEqual(p[:3], bytes([1, 2, 0x06]))
        self.assertEqual(p[3:103], b"test.apn".ljust(100, b"\0"))
        self.assertEqual(p[103:], bytes(24))
        for bad in (("x" * 100,), ("",)):
            with self.assertRaises(ValueError):
                m.gprs_define_pdp_context(1, *bad)
        for cid in (0, 5):
            with self.assertRaises(ValueError):
                m.gprs_define_pdp_context(cid, "internet")

    def test_pdp_context_set(self):
        p = m.gprs_pdp_context_set(1, 1, "user", "pass", "chap")
        self.assertEqual(p[:6], bytes([1, 1, 0x13, 0, 0, 0]))
        self.assertEqual(p[6:38], b"user".ljust(32, b"\0"))
        self.assertEqual(p[38:70], b"pass".ljust(32, b"\0"))
        self.assertEqual(p[70:102], bytes(32))
        self.assertEqual(p[102:], bytes([2, 0, 0]))
        p = m.gprs_pdp_context_set(0, 3, reason=4)
        self.assertEqual((p[0], p[1], p[2], p[102], p[104]), (0, 3, 0, 0, 4))
        self.assertEqual(m.gprs_pdp_context_set(1, 1, auth="pap")[102], 1)
        with self.assertRaises(ValueError):
            m.gprs_pdp_context_set(1, 1, user="u" * 33)

    def test_lte_attach(self):
        p = m.gprs_lte_attach_apn_info(1, "internet", defs.GPRS_PDP_IP, "user", "pass", "pap",
                                       roaming_pdp_type=defs.GPRS_PDP_IPV6, roaming_flag=1)
        self.assertEqual(p[:127], m.gprs_define_pdp_context(1, "internet", defs.GPRS_PDP_IP))
        self.assertEqual(p[127:159], b"user".ljust(32, b"\0"))
        self.assertEqual(p[159:191], b"pass".ljust(32, b"\0"))
        self.assertEqual(p[191:], bytes([1, 0x05, 1]))
        self.assertEqual(m.gprs_lte_attach_apn_info(1, "internet")[192], 0x02)

    def test_ip_configuration(self):
        p = bytearray(157)
        p[0] = 1
        struct.pack_into("<H", p, 1, 0x2041)
        p[3:7], p[7:11], p[11:15] = bytes([192, 0, 2, 10]), bytes([192, 0, 2, 53]), bytes([192, 0, 2, 54])
        p[35:51] = bytes.fromhex("20010db8000000000000000000000010")
        p[99:115] = bytes.fromhex("20010db8000000000000000000000053")
        struct.pack_into("<I", p, 152, 1430)
        cfg = m.dec_ip_configuration(bytes(p))
        self.assertEqual((cfg.cid, cfg.ipv4, cfg.dns1, cfg.dns2), (1, "192.0.2.10", "192.0.2.53", "192.0.2.54"))
        self.assertEqual((cfg.ipv6, cfg.dns6_1, cfg.dns6_2, cfg.mtu), ("2001:db8::10", "2001:db8::53", None, 1430))
        short = m.dec_ip_configuration(bytes(p[:15]))
        self.assertEqual((short.ipv4, short.ipv6, short.mtu), ("192.0.2.10", None, None))

    def test_call_status_and_pdp_list(self):
        st = m.dec_gprs_call_status(bytes([1, 1, 0, 0]))
        self.assertTrue(st.up)
        self.assertFalse(m.dec_gprs_call_status(bytes([1, 0, 36])).up)
        self.assertEqual(m.dec_pdp_context(bytes([2, 1, 1, 2, 0])), {1: 1, 2: 0})


class SoundTest(unittest.TestCase):
    def test_encoders(self):
        self.assertEqual(m.snd_audio_path(defs.SND_PATH_SPEAKER), b"\x06\x00")
        self.assertEqual(m.snd_audio_path(defs.SND_PATH_HEADPHONE), b"\x07\x00")
        self.assertEqual(m.snd_spkr_volume(defs.SND_VOLUME_SPEAKER, 4), b"\x11\x04")
        self.assertEqual(m.snd_clock_ctrl(False), b"\x00")
        self.assertEqual(m.snd_clock_ctrl(True), b"\x01")

    def test_clock_noti(self):
        for raw, on in ((1, True), (2, False), (3, True), (4, False), (7, True)):
            self.assertEqual(m.dec_clock_ctrl(bytes([raw])).on, on)
        self.assertEqual(m.dec_wb_amr(b"\x00"), 0)


class MiscTest(unittest.TestCase):
    def test_loopback(self):
        self.assertEqual(m.misc_loopback_cfrm(0xBEEF), b"\xef\xbe")
        self.assertEqual(m.dec_loopback(b"\xef\xbe"), 0xBEEF)

    def test_time_info(self):
        p = bytes([1, 0, 26, 10, 29, 21, 30, 15, 4, 0, 0, 1]) + b"00101#"
        t = m.dec_time_info(p)
        self.assertEqual((t.year, t.month, t.day, t.hour, t.tz_quarters, t.plmn), (2026, 10, 29, 21, 4, "00101"))
        self.assertEqual(m.dec_time_info(bytes([1, 0, 26, 10, 29, 21, 30, 15, 0xEC, 0])).tz_quarters, -20)


class TruncationTest(unittest.TestCase):
    KEYS = {
        "GEN_PHONE_RES": (defs.GEN, 0x01), "PWR_PHONE_STATE": (defs.PWR, 0x07), "MISC_ME_VERSION": (defs.MISC, 0x01),
        "MISC_ME_SN": (defs.MISC, 0x03), "SEC_PIN_STATUS": (defs.SEC, 0x01), "SEC_LOCK_INFORMATION": (defs.SEC, 0x08),
        "NET_REGIST": (defs.NET, 0x05), "NET_SERVING_NETWORK": (defs.NET, 0x03), "DISP_RSSI_INFO": (defs.DISP, 0x06),
        "DISP_ICON_INFO": (defs.DISP, 0x01), "SMS_SEND_MSG": (defs.SMS, 0x01), "SMS_INCOMING_MSG": (defs.SMS, 0x02),
        "CALL_STATUS": (defs.CALL, 0x05), "GPRS_IP_CONFIGURATION": (defs.GPRS, 0x09),
        "GPRS_CALL_STATUS": (defs.GPRS, 0x10), "SND_CLOCK_CTRL": (defs.SND, 0x09),
    }

    def test_one_byte_short_raises_decode_error(self):
        self.assertEqual(set(self.KEYS), set(m.MIN_SIZES))
        for name, (main, sub) in self.KEYS.items():
            size = m.MIN_SIZES[name]
            with self.subTest(name):
                with self.assertRaises(m.DecodeError):
                    m.decode(main, sub, bytes(size - 1))

    def test_every_decoder_survives_random_lengths(self):
        import random
        rng = random.Random(7)
        for (main, sub) in m.DECODERS:
            for n in range(0, 200, 7):
                data = rng.randbytes(n)
                try:
                    m.decode(main, sub, data)
                except m.DecodeError:
                    pass

    def test_unknown_message(self):
        self.assertIsNone(m.decode(0x0A, 0x99, b"\x00"))
        self.assertIsNone(m.decode(0x42, 0x01, b""))


if __name__ == "__main__":
    unittest.main()
