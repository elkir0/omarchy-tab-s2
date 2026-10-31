# SPDX-License-Identifier: GPL-2.0-or-later
"""End-to-end tests of ModemCore against the FAKE modem (tests/fake_modem.py).

These run on a mock: they prove shannond's sequencing, mandatory replies and
state handling against the catalogue's description, not the real CP.
"""

import io
import json
import logging
import os
import struct
import unittest
from unittest import mock

import testutil
from testutil import Harness
from shannond import core as core_mod, defs, messages
from shannond.netcfg import NetConfig
from shannond.rfs import HDR
from shannond.core import CoreConfig, ModemCore
from shannond.settings import Settings
import fake_modem

S, C, E, G, V = defs.TYPE_SET, defs.TYPE_CFRM, defs.TYPE_EXEC, defs.TYPE_GET, defs.TYPE_EVENT
MANDATORY = {(defs.SMS, defs.SMS_DEVICE_READY, S), (defs.MISC, defs.MISC_IPC_LOOPBACK, C)}


def keys(frames):
    return [(f.main, f.sub, f.type) for f in frames]


class CoreTestBase(unittest.TestCase):
    harness_kwargs = {}

    def setUp(self):
        self.h = Harness(**self.harness_kwargs)
        self.addCleanup(self.h.close)
        self.core, self.fake = self.h.core, self.h.fake


class BootTest(CoreTestBase):
    def test_mandatory_replies_and_nothing_else(self):
        self.h.boot()
        self.h.run_for(0.2)
        sent = keys(self.fake.rx)
        self.assertIn((defs.SMS, defs.SMS_DEVICE_READY, S), sent)
        self.assertIn((defs.MISC, defs.MISC_IPC_LOOPBACK, C), sent)
        self.assertEqual(set(sent), MANDATORY, "before 'radio on' only the mandatory replies are sent")
        cfrm = self.fake.frames(defs.MISC, defs.MISC_IPC_LOOPBACK, C)[0]
        self.assertEqual(cfrm.payload, struct.pack("<H", 0xBEEF), "LOOPBACK CFRM echoes the u16")
        self.assertEqual(self.fake.frames(defs.SMS, defs.SMS_DEVICE_READY, S)[0].payload, b"")

    def test_state_after_boot(self):
        self.h.boot()
        self.h.run_until(lambda: self.core.state["sim"]["state"] == "ready")
        st = self.core.state
        self.assertEqual(st["cp"], "online")
        self.assertEqual(st["power"], "lpm")
        self.assertEqual(st["sim"]["icc_type"], "usim")
        self.assertTrue(self.h.events_of("state"), "'state' events are emitted")
        for k in ("imei", "imsi", "iccid", "own_number"):
            self.assertNotIn(k, st, "identifiers only after query_identity()")

    def test_sequence_numbers(self):
        self.h.boot()
        self.h.call(self.core.radio_on)
        self.h.run_for(0.1)
        mseqs = [f.mseq for f in self.fake.rx]
        self.assertTrue(all(1 <= m <= 254 for m in mseqs))
        self.assertEqual(mseqs, list(range(mseqs[0], mseqs[0] + len(mseqs))), "AP mseq increments per frame")
        self.assertTrue(all(f.aseq == 0 for f in self.fake.rx), "AP aseq is 0")

    def test_unknown_and_malformed_frames_are_ignored(self):
        self.h.boot()
        self.fake.send(defs.NET, defs.NET_REGIST, defs.TYPE_NOTI, b"\x21\x02")  # too short
        self.fake.send(0x77, 0x77, defs.TYPE_NOTI, b"")
        self.fake.send(defs.GEN, defs.GEN_PHONE_RES_SUB, defs.TYPE_RESP, b"\x01\x07\x01\x00\x80", aseq=200)
        self.fake.send(defs.GEN, defs.GEN_PHONE_RES_SUB, defs.TYPE_RESP, b"\x01", aseq=201)
        os.write(self.fake.ipc_fd, b"\x03\x00")  # fragment: dropped in datagram mode
        self.h.run_for(0.1)
        ok = self.h.call(self.core.radio_on)
        self.assertEqual(ok, (True, {"power": "on"}))


class PassiveTest(CoreTestBase):
    harness_kwargs = {"passive": True}

    def test_passive_sends_only_mandatory(self):
        self.h.boot()
        self.fake.inject_sms()
        self.fake.incoming_call()
        self.fake.send(defs.SND, defs.SND_CLOCK_CTRL, defs.TYPE_NOTI, b"\x01")
        self.fake.send(defs.SEC, defs.SEC_PIN_STATUS, defs.TYPE_NOTI, b"\x03\x01")
        self.fake.boot()  # a second boot: mandatory replies again
        self.h.run_for(0.3)
        for name, args in (("radio_on", ()), ("dial", ("+447700900123",)), ("send_sms", ("+447700900123", "x")),
                           ("data_connect", ("internet",)), ("query_identity", ()),
                           ("raw", (0x0A, 0x50, G, b""))):
            ok, err = self.h.call(getattr(self.core, name), *args)
            self.assertFalse(ok, name)
            self.assertIn("passive", err)
        self.h.run_for(0.1)
        self.assertEqual(set(keys(self.fake.rx)), MANDATORY)
        self.assertEqual(len(self.fake.rx), 4)
        self.assertEqual(self.core.state["calls"][0]["state"], "incoming", "state still tracked passively")


class RadioTest(CoreTestBase):
    def test_radio_on_sequence(self):
        self.h.boot()
        self.fake.rx.clear()
        ok, res = self.h.call(self.core.radio_on)
        self.assertTrue(ok)
        self.h.run_until(lambda: self.core.state["reg"]["mcc"] and self.core.state["signal"]["rssi_dbm"] is not None)
        sent = keys(self.fake.rx)
        self.assertEqual(sent[0], (defs.PWR, defs.PWR_PHONE_STATE, E))
        self.assertEqual(self.fake.rx[0].payload, b"\x02\x02")
        for k in ((defs.SEC, defs.SEC_PIN_STATUS, G), (defs.NET, defs.NET_REGIST, G),
                  (defs.NET, defs.NET_SERVING_NETWORK, G), (defs.DISP, defs.DISP_ICON_INFO, G),
                  (defs.NET, defs.NET_MODE_SEL, S)):
            self.assertIn(k, sent)
        doms = sorted(f.payload for f in self.fake.frames(defs.NET, defs.NET_REGIST, G))
        self.assertEqual(doms, [b"\xff\x02", b"\xff\x03"])
        self.assertEqual(self.fake.frames(defs.NET, defs.NET_MODE_SEL, S)[0].payload, b"\x03")  # no APN yet
        st = self.core.state
        self.assertEqual((st["power"], st["reg"]["cs"], st["reg"]["ps"], st["reg"]["rat"]), ("on", "home", "home", "lte"))
        self.assertEqual((st["reg"]["mcc"], st["reg"]["mnc"]), ("001", "01"))
        self.assertIsInstance(st["signal"]["percent"], int)
        self.assertEqual(st["signal"]["rssi_dbm"], -75)

    def test_attach_apn_goes_before_radio_on(self):
        self.core._attach_profile = messages.gprs_lte_attach_apn_info(1, "internet")
        self.h.boot()
        self.fake.rx.clear()
        ok, res = self.h.call(self.core.radio_on)
        self.assertTrue(ok, res)
        sent = keys(self.fake.rx)
        self.assertEqual(sent[0], (defs.GPRS, defs.GPRS_LTE_ATTACH_APN_INFO, S))
        self.assertEqual(sent[1], (defs.PWR, defs.PWR_PHONE_STATE, E))
        # once per CP session, and a data call with the same profile does not repeat it
        ok, res = self.h.call(self.core.radio_on)
        self.assertTrue(ok, res)
        ok, res = self.h.call(self.core.data_connect, "internet", "ipv4", None, None)
        self.assertTrue(ok, res)
        self.assertEqual(len(self.fake.frames(defs.GPRS, defs.GPRS_LTE_ATTACH_APN_INFO, S)), 1)

    def test_no_attach_apn_without_lte(self):
        self.core._attach_profile = messages.gprs_lte_attach_apn_info(1, "internet")
        self.core.config.mode_sel_mask = defs.NET_MODE_WCDMA | defs.NET_MODE_GSM
        self.h.boot()
        self.fake.rx.clear()
        ok, res = self.h.call(self.core.radio_on)
        self.assertTrue(ok, res)
        self.assertEqual(self.fake.frames(defs.GPRS, defs.GPRS_LTE_ATTACH_APN_INFO, S), [])

    def test_no_lte_in_the_mask_until_an_attach_apn_is_known(self):
        self.h.boot()
        self.h.call(self.core.radio_on)
        self.h.run_until(lambda: self.fake.frames(defs.NET, defs.NET_MODE_SEL, S))
        self.assertEqual(self.fake.frames(defs.NET, defs.NET_MODE_SEL, S)[-1].payload, b"\x03")
        self.fake.rx.clear()
        ok, res = self.h.call(self.core.set_attach_apn, "internet")
        self.assertTrue(ok, res)
        self.h.run_until(lambda: self.fake.frames(defs.NET, defs.NET_MODE_SEL, S))
        self.assertEqual(self.fake.frames(defs.NET, defs.NET_MODE_SEL, S)[-1].payload, b"\x0b")

    def test_set_modes_reaches_the_cp_and_lte_still_waits_for_an_apn(self):
        self.h.boot()
        self.h.call(self.core.radio_on)
        self.fake.rx.clear()
        ok, res = self.h.call(self.core.set_modes, 0x02)
        self.assertTrue(ok, res)
        self.assertEqual(self.fake.frames(defs.NET, defs.NET_MODE_SEL, S)[-1].payload, b"\x02")
        self.fake.rx.clear()
        ok, res = self.h.call(self.core.set_modes, 0x0b)
        self.assertTrue(ok, res)
        self.assertEqual(self.fake.frames(defs.NET, defs.NET_MODE_SEL, S)[-1].payload, b"\x03")

    def test_settings_keep_the_apn_and_the_technologies(self):
        path = os.path.join(self.h.tmp.name, "settings.json")
        self.core.settings = Settings(path)
        self.h.boot()
        self.h.call(self.core.set_attach_apn, "internet", "ipv4", "user", "secret")
        self.h.call(self.core.set_modes, 0x03)
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        saved = Settings(path)
        self.assertEqual(saved.get("modes"), 0x03)
        self.assertEqual(saved.get("attach")["apn"], "internet")

    def test_saved_settings_win_at_start(self):
        path = os.path.join(self.h.tmp.name, "settings.json")
        Settings(path).save(modes=0x03, attach={"apn": "saved", "ip_type": "ipv4", "user": None,
                                                "password": None, "auth": "none"})
        core = ModemCore(self.h.loop, "/nonexistent", None, config=CoreConfig(settings=Settings(path), lte_attach_apn="cli"))
        self.assertEqual(core.config.mode_sel_mask, 0x03)
        self.assertEqual(core.state["modes"], 0x03)
        self.assertEqual(core._attach_profile, messages.gprs_lte_attach_apn_info(1, "saved"))

    def test_set_modes_refuses_a_bad_mask(self):
        self.h.boot()
        ok, _ = self.h.call(self.core.set_modes, 0)
        self.assertFalse(ok)
        ok, _ = self.h.call(self.core.set_modes, 0x10)
        self.assertFalse(ok)

    def test_radio_on_twice_sends_it_once(self):
        self.h.boot()
        self.h.call(self.core.radio_on)
        ok, res = self.h.call(self.core.radio_on)
        self.assertTrue(ok, res)
        self.assertEqual(len(self.fake.frames(defs.PWR, defs.PWR_PHONE_STATE, E)), 1)

    def test_radio_on_start(self):
        self.core.config.radio_on_start = True
        self.core._schedule_radio_on()   # the daemon started while the CP runs, then PWR_UP
        self.h.boot()
        self.h.run_until(lambda: self.core.state["power"] == "on")
        self.assertEqual(len(self.fake.frames(defs.PWR, defs.PWR_PHONE_STATE, E)), 1)

    def test_radio_off(self):
        self.h.boot()
        ok, _ = self.h.call(self.core.radio_off)
        self.assertTrue(ok)
        self.assertEqual(self.fake.frames(defs.PWR, defs.PWR_PHONE_STATE, E)[-1].payload, b"\x01\x00")
        self.h.run_until(lambda: self.core.state["power"] == "lpm")

    def test_airplane_mode_survives_a_restart(self):
        path = os.path.join(self.h.tmp.name, "settings.json")
        self.core.settings = Settings(path)
        self.h.boot()
        self.h.call(self.core.radio_off)
        self.assertTrue(Settings(path).get("radio_off"))
        before = len(self.fake.frames(defs.PWR, defs.PWR_PHONE_STATE, E))
        self.core.config.radio_on_start = True
        self.core._schedule_radio_on()
        self.h.run_for(self.core.config.resync_delay + 1)
        self.assertEqual(len(self.fake.frames(defs.PWR, defs.PWR_PHONE_STATE, E)), before)
        self.assertEqual(self.core.state["power"], "lpm")
        self.h.call(self.core.radio_on)
        self.assertFalse(Settings(path).get("radio_off"))

    def test_pin_status_gate(self):
        # no PIN_STATUS NOTI yet: radio on must not GET SEC_PIN_STATUS
        self.fake.send(defs.PWR, defs.PWR_PHONE_PWR_UP)
        self.h.run_for(0.05)
        self.h.call(self.core.radio_on)
        self.h.run_for(0.1)
        self.assertEqual(self.fake.frames(defs.SEC, defs.SEC_PIN_STATUS, G), [])
        self.fake.send(defs.SEC, defs.SEC_PIN_STATUS, defs.TYPE_NOTI, b"\x00\x00")
        self.h.run_for(0.05)
        self.h.call(self.core.refresh)
        self.assertEqual(len(self.fake.frames(defs.SEC, defs.SEC_PIN_STATUS, G)), 1)

    def test_gen_error_fails_command(self):
        self.h.boot()
        self.fake.fail_next[(defs.PWR, defs.PWR_PHONE_STATE)] = 0x8011
        ok, err = self.h.call(self.core.radio_on)
        self.assertFalse(ok)
        self.assertIn("0x8011", err)


class SimLockedTest(CoreTestBase):
    harness_kwargs = {"fake_kwargs": {"pin_status": (0x03, 0x01)}}

    def test_locked_sim_reports_retries_and_never_sends_pin(self):
        self.h.boot()
        self.h.run_until(lambda: self.core.state["sim"]["pin_retries"] is not None)
        sim = self.core.state["sim"]
        self.assertEqual((sim["state"], sim["lock"], sim["pin_retries"]), ("locked", "sim-pin", 3))
        lock = self.fake.frames(defs.SEC, defs.SEC_LOCK_INFORMATION, G)[0]
        self.assertEqual(len(lock.payload), 9)
        self.assertEqual(self.fake.frames(defs.SEC, defs.SEC_PIN_STATUS, S), [], "PIN never sent automatically")

    def test_enter_pin(self):
        self.h.boot()
        ok, _ = self.h.call(self.core.enter_pin, "1234")
        self.assertTrue(ok)
        f = self.fake.frames(defs.SEC, defs.SEC_PIN_STATUS, S)[0]
        self.assertEqual(len(f.payload), 19)
        self.assertEqual(f.payload[:3], b"\x03\x04\x00")
        self.h.run_until(lambda: self.core.state["sim"]["state"] == "ready")


@unittest.skipUnless(testutil.HAVE_SMS_PDU, "shannond.sms_pdu not available")
class SmsTest(CoreTestBase):
    def test_send_sms(self):
        self.h.boot()
        self.h.call(self.core.radio_on)
        ok, res = self.h.call(self.core.send_sms, "+447700900123", "hellohello")
        self.assertTrue(ok, res)
        self.assertEqual(res["parts"], 1)
        self.assertIsInstance(res["ref"], int)
        self.assertEqual(len(self.fake.frames(defs.SMS, defs.SMS_SVC_CENTER_ADDR, G)), 1)
        f = self.fake.frames(defs.SMS, defs.SMS_SEND_MSG, E)[0]
        p = f.payload
        self.assertEqual(p[0:3], b"\x02\x02\x02", "fmt 3GPP, single, domain")
        self.assertEqual(p[3], len(p) - 4)
        self.assertEqual(p[4:12], fake_modem.FAKE_SMSC_FIELD, "SMSC provided by the CP")
        tpdu = p[12:]
        self.assertEqual(tpdu, bytes.fromhex("01000C914477000910320000" "0A" "E8329BFD4697D9EC37"))
        sent = self.h.events_of("sms-sent")
        self.assertEqual(sent[-1]["ok"], True)
        # second SMS reuses the cached SMSC
        self.h.call(self.core.send_sms, "+447700900123", "x")
        self.assertEqual(len(self.fake.frames(defs.SMS, defs.SMS_SVC_CENTER_ADDR, G)), 1)

    def test_send_long_sms_uses_more_to_send(self):
        self.h.boot()
        ok, res = self.h.call(self.core.send_sms, "+447700900123", "a" * 200)
        self.assertTrue(ok, res)
        frames = self.fake.frames(defs.SMS, defs.SMS_SEND_MSG, E)
        self.assertEqual([f.payload[1] for f in frames], [0x01, 0x02])
        self.assertEqual(res["parts"], 2)

    def test_send_sms_empty_smsc_mode(self):
        self.core.config.smsc_mode = "empty"
        self.h.boot()
        self.h.call(self.core.send_sms, "0639980012", "Test 123")
        p = self.fake.frames(defs.SMS, defs.SMS_SEND_MSG, E)[0].payload
        self.assertEqual(p[4], 0x00)
        self.assertEqual(self.fake.frames(defs.SMS, defs.SMS_SVC_CENTER_ADDR, G), [])

    def test_receive_sms_ack_list_delete(self):
        self.h.boot()
        self.fake.inject_sms(msg_id=7)
        self.h.run_until(lambda: self.h.events_of("sms-received"))
        msg = self.h.events_of("sms-received")[0]
        self.assertEqual(msg["sender"], fake_modem.FAKE_PEER)
        self.assertEqual(msg["text"], "hellohello")
        self.assertTrue(msg["timestamp"].startswith("2026-10-29T21:30:15"))
        self.assertEqual(msg["pdu_hex"], fake_modem.FAKE_DELIVER_PDU.hex())
        self.h.run_until(lambda: self.fake.frames(defs.SMS, defs.SMS_DELIVER_REPORT, E))
        ack = self.fake.frames(defs.SMS, defs.SMS_DELIVER_REPORT, E)[0]
        self.assertEqual(ack.payload, b"\x02\x00\x00\x07\x00")
        ok, lst = self.h.call(self.core.list_sms)
        self.assertEqual([m["index"] for m in lst], [msg["index"]])
        ok, _ = self.h.call(self.core.delete_sms, msg["index"])
        self.assertTrue(ok)
        self.assertEqual(self.h.call(self.core.list_sms)[1], [])

    def test_undecodable_sms_is_acked_and_reported(self):
        self.h.boot()
        self.fake.inject_sms(pdu=b"\x00\x04\x01", msg_id=9)
        self.h.run_until(lambda: self.h.events_of("sms-received"))
        self.assertIsNone(self.h.events_of("sms-received")[0]["text"])
        self.h.run_until(lambda: self.fake.frames(defs.SMS, defs.SMS_DELIVER_REPORT, E))

    def test_service_sms_is_acked_and_dropped(self):
        self.h.boot()
        header = bytes.fromhex("07913336990890F9" "44" "0C91447700094065" "00" "04" "62012912035100")
        ud = bytes.fromhex("0605040B8423F0") + b"\x01\x06\x03"
        self.fake.inject_sms(pdu=header + bytes([len(ud)]) + ud, msg_id=5)
        self.h.run_until(lambda: self.fake.frames(defs.SMS, defs.SMS_DELIVER_REPORT, E))
        self.assertEqual(self.h.events_of("sms-received"), [])
        self.assertEqual(self.h.call(self.core.list_sms)[1], [])


class CallTest(CoreTestBase):
    def test_dial_audio_hangup(self):
        self.h.boot()
        self.h.call(self.core.radio_on)
        ok, res = self.h.call(self.core.dial, "+447700900123")
        self.assertTrue(ok, res)
        call_id = res["id"]
        out = self.fake.frames(defs.CALL, defs.CALL_OUTGOING, E)[0]
        self.assertEqual(len(out.payload), 92)
        self.assertEqual(out.payload[:5], bytes([0x00, 0x01, 0x00, 12, 0x11]))
        self.assertEqual(out.payload[5:17], b"447700900123")
        self.h.run_until(lambda: self.h.events_of("audio"))
        states = [c["state"] for c in self.h.events_of("call") if c["id"] == call_id]
        self.assertEqual(states[:3], ["dialing", "alerting", "active"])
        self.assertEqual(self.h.events_of("call")[0]["direction"], "out")
        # D8 ordering on the IPC side
        self.assertEqual(self.fake.frames(defs.SND, defs.SND_AUDIO_PATH_CTRL, S)[0].payload, b"\x06\x00")
        self.assertEqual(self.fake.frames(defs.SND, defs.SND_SPKR_VOLUME_CTRL, S)[0].payload, b"\x11\x04")
        self.assertEqual(self.fake.frames(defs.SND, defs.SND_MIC_MUTE_CTRL, S)[0].payload, b"\x00")
        self.assertEqual(len(self.fake.frames(defs.SND, defs.SND_TWO_MIC_SOL_CTRL, S)), 1)
        self.assertEqual(self.h.events_of("audio")[0], {"open": True, "rate": 8000, "fallback": False})
        self.assertEqual(self.fake.frames(defs.SND, defs.SND_CLOCK_CTRL, E), [], "no fallback when the CP clocks")
        ok, _ = self.h.call(self.core.hangup, call_id)
        self.assertTrue(ok)
        self.h.run_until(lambda: self.fake.frames(defs.SND, defs.SND_CLOCK_CTRL, E))
        self.assertEqual(len(self.fake.frames(defs.CALL, defs.CALL_RELEASE, E)), 1)
        close = [(d, n) for ev, d, n in self.h.events if ev == "audio" and not d["open"]]
        self.assertTrue(close)
        stop = self.fake.frames(defs.SND, defs.SND_CLOCK_CTRL, E)[0]
        self.assertEqual(stop.payload, b"\x00")
        self.assertLess(close[0][1], self.fake.rx.index(stop) + 1, "audio closed before CLOCK_CTRL stop")
        self.assertEqual(self.core.state["calls"], [])
        released = [c for c in self.h.events_of("call") if c["state"] == "released"]
        self.assertTrue(released and released[0]["reason"])

    def test_emergency_numbers_refused(self):
        self.h.boot()
        for number in ("112", "911", "15", "17", "18", "115", "119", "999", "000", "08", "110",
                       "+112", "1 1 2", "911#"):
            ok, err = self.h.call(self.core.dial, number)
            self.assertFalse(ok, number)
            self.assertIn("emergency", err)
        self.assertEqual(self.fake.frames(defs.CALL, defs.CALL_OUTGOING, E), [])

    def test_clock_fallback(self):
        self.fake.send_clock = False
        self.h.boot()
        ok, res = self.h.call(self.core.dial, "0639980012")
        self.assertTrue(ok)
        self.h.run_until(lambda: self.h.events_of("audio"), timeout=3)
        start = self.fake.frames(defs.SND, defs.SND_CLOCK_CTRL, E)
        self.assertEqual(start[0].payload, b"\x01")
        self.assertTrue(self.h.events_of("audio")[0]["fallback"])
        self.assertEqual(self.fake.frames(defs.CALL, defs.CALL_OUTGOING, E)[0].payload[4], 0x21)

    def test_wide_band_rate_change(self):
        self.h.boot()
        self.h.call(self.core.dial, "+447700900123")
        self.h.run_until(lambda: self.h.events_of("audio"))
        self.fake.send(defs.SND, defs.SND_WB_AMR_RPT, defs.TYPE_NOTI, b"\x01")
        self.h.run_until(lambda: len(self.h.events_of("audio")) >= 2)
        self.assertEqual(self.h.events_of("audio")[1]["rate"], 16000)

    def test_incoming_answer_remote_hangup(self):
        self.h.boot()
        cid = self.fake.incoming_call()
        self.h.run_until(lambda: any(c.get("number") for c in self.core.state["calls"]))
        ev = self.h.events_of("call")
        self.assertEqual((ev[0]["state"], ev[0]["direction"]), ("incoming", "in"))
        self.assertEqual(self.core.state["calls"][0]["number"], fake_modem.FAKE_PEER)
        ok, _ = self.h.call(self.core.answer, cid)
        self.assertTrue(ok)
        self.h.run_until(lambda: self.core.state["audio"]["open"])
        self.fake.remote_hangup(cid)
        self.h.run_until(lambda: not self.core.state["calls"] and not self.core.state["audio"]["open"])

    def test_hangup_one_of_two_uses_manage_call(self):
        self.h.boot()
        self.h.call(self.core.dial, "+447700900123")
        cid2 = self.fake.incoming_call()
        self.h.run_until(lambda: len(self.core.state["calls"]) == 2)
        ok, _ = self.h.call(self.core.hangup, cid2)
        self.assertTrue(ok)
        mc = self.fake.frames(defs.SS, defs.SS_MANAGE_CALL, S)[0]
        self.assertEqual((len(mc.payload), mc.payload[0], mc.payload[1]), (85, 3, cid2))

    def test_dtmf(self):
        self.core.config.dtmf_ms = 5
        self.h.boot()
        self.h.call(self.core.dial, "+447700900123")
        ok, _ = self.h.call(self.core.send_dtmf, 1, "1#")
        self.assertTrue(ok)
        payloads = [f.payload for f in self.fake.frames(defs.CALL, defs.CALL_CONT_DTMF, S)]
        self.assertEqual(payloads, [b"\x011", b"\x02\x00", b"\x01#", b"\x02\x00"])


class DataTest(CoreTestBase):
    def setUp(self):
        super().setUp()
        self.state_dir = os.path.join(self.h.tmp.name, "data")
        self.core.netcfg = NetConfig("external", state_dir=self.state_dir)

    def test_data_up_down(self):
        self.h.boot()
        ok, res = self.h.call(self.core.data_connect, "internet", "ipv4", None, None)
        self.assertTrue(ok, res)
        seq = [(f.sub, len(f.payload)) for f in self.fake.rx if f.main == defs.GPRS]
        self.assertEqual(seq, [(defs.GPRS_LTE_ATTACH_APN_INFO, 194), (defs.GPRS_DEFINE_PDP_CONTEXT, 127),
                               (defs.GPRS_PDP_CONTEXT, 105)])
        self.assertEqual(self.fake.frames(defs.GPRS, defs.GPRS_PDP_CONTEXT, S)[0].payload[:2], b"\x01\x01")
        self.assertEqual(res["interface"], "rmnet0")
        self.assertEqual(res["ipv4"], {"address": "192.0.2.10", "prefix": 32, "gateway": None,
                                       "dns": ["192.0.2.53", "192.0.2.54"], "mtu": 1430})
        self.assertIsNone(res["ipv6"])
        self.assertTrue(res["connected"])
        self.assertEqual(self.h.events_of("data")[-1]["ipv4"]["address"], "192.0.2.10")
        with open(os.path.join(self.state_dir, "rmnet0.json")) as f:
            self.assertEqual(json.load(f)["ipv4"]["mtu"], 1430)
        self.assertEqual(self.core.state["data"]["interface"], "rmnet0")
        ok, res = self.h.call(self.core.data_disconnect)
        self.assertTrue(ok)
        self.assertEqual(self.fake.frames(defs.GPRS, defs.GPRS_PDP_CONTEXT, S)[-1].payload[:2], b"\x00\x01")
        self.assertFalse(self.h.events_of("data")[-1]["connected"])
        self.assertFalse(os.path.exists(os.path.join(self.state_dir, "rmnet0.json")))
        self.assertIsNone(self.core.state["data"])

    def test_configure_ip_commands(self):
        cmds = []
        self.core.netcfg = NetConfig("iproute2", state_dir=None, route_metric=700, runner=cmds.append)
        self.h.boot()
        ok, res = self.h.call(self.core.data_connect, "internet", "ipv4", "user", "pass")
        self.assertTrue(ok, res)
        self.assertIn(["ip", "-4", "addr", "add", "192.0.2.10/32", "dev", "rmnet0"], cmds)
        self.assertIn(["ip", "-4", "route", "replace", "default", "dev", "rmnet0", "metric", "700"], cmds)
        self.assertIn(["ip", "link", "set", "dev", "rmnet0", "mtu", "1430"], cmds)
        act = self.fake.frames(defs.GPRS, defs.GPRS_PDP_CONTEXT, S)[0].payload
        self.assertEqual(act[2], 0x13, "user + password + auth flags")
        self.assertEqual(act[102], 2, "CHAP by default when credentials are given")

    def test_network_drop(self):
        self.h.boot()
        self.h.call(self.core.data_connect, "internet", "ipv4", None, None)
        self.fake.send(defs.GPRS, defs.GPRS_CALL_STATUS, defs.TYPE_NOTI, bytes([1, 0, 36, 0]))
        self.h.run_until(lambda: self.h.events_of("data") and not self.h.events_of("data")[-1]["connected"])
        self.assertIn("36", self.h.events_of("data")[-1]["reason"])

    def test_activation_refused_while_the_cp_changes_mode_is_retried(self):
        self.h.boot()
        self.fake.pdp_refuse = [255, 255]
        with mock.patch.object(core_mod, "PDP_BUSY_DELAY", 0.01):
            ok, res = self.h.call(self.core.data_connect, "internet", "ipv4", None, None)
        self.assertTrue(ok, res)
        self.assertEqual(res["interface"], "rmnet0")
        self.assertEqual(len(self.fake.frames(defs.GPRS, defs.GPRS_DEFINE_PDP_CONTEXT, S)), 3)
        self.assertEqual(len(self.fake.frames(defs.GPRS, defs.GPRS_PDP_CONTEXT, S)), 3)
        self.assertEqual(self.core.state["data"]["interface"], "rmnet0")

    def test_activation_refused_by_the_network_is_not_retried(self):
        self.h.boot()
        self.fake.pdp_refuse = [27]   # missing or unknown APN
        with mock.patch.object(core_mod, "PDP_BUSY_DELAY", 0.01):
            ok, err = self.h.call(self.core.data_connect, "internet", "ipv4", None, None)
        self.assertFalse(ok)
        self.assertIn("cause 27", str(err))
        activations = [f for f in self.fake.frames(defs.GPRS, defs.GPRS_PDP_CONTEXT, S)
                       if f.payload[:1] == b"\x01"]
        self.assertEqual(len(activations), 1)
        self.assertIsNone(self.core.state["data"])

    def test_activation_failure(self):
        self.h.boot()
        self.fake.fail_next[(defs.GPRS, defs.GPRS_DEFINE_PDP_CONTEXT)] = 0x8003
        ok, err = self.h.call(self.core.data_connect, "internet", "ipv4", None, None)
        self.assertFalse(ok)
        self.assertIsNone(self.core.state["data"])


class MiscTest(CoreTestBase):
    def test_query_identity_never_logged(self):
        self.h.boot()
        stream = io.StringIO()
        handler = logging.StreamHandler(stream)
        root = logging.getLogger("shannond")
        old = root.level
        root.setLevel(logging.DEBUG)
        root.addHandler(handler)
        try:
            ok, res = self.h.call(self.core.query_identity)
            self.h.call(self.core.dial, "+447700900123")
            self.fake.inject_sms()
            self.h.run_for(0.2)
            if testutil.HAVE_SMS_PDU:
                self.h.call(self.core.send_sms, "+447700900123", "hellohello")
        finally:
            root.removeHandler(handler)
            root.setLevel(old)
        self.assertTrue(ok)
        self.assertEqual(res["imei"], fake_modem.FAKE_IMEI.decode())
        self.assertEqual(res["imsi"], fake_modem.FAKE_IMSI.decode())
        self.assertEqual(res["revision"], "FAKE-SW-1")
        self.assertEqual(res["own_number"], fake_modem.FAKE_OWN_NUMBER)
        self.assertEqual(self.core.state["reg"]["operator"], fake_modem.FAKE_SPN)
        self.assertEqual(self.core.state["imei"], res["imei"])
        text = stream.getvalue()
        self.assertIn("main=0x0a sub=0x03", text, "header tuples are logged")
        for secret in (fake_modem.FAKE_IMEI.decode(), fake_modem.FAKE_IMSI.decode(), "447700900123",
                       "447700900456", "hellohello", "00101", fake_modem.FAKE_DELIVER_PDU.hex()[:20]):
            self.assertNotIn(secret, text)

    def test_raw_get_answered_by_gen(self):
        self.h.boot()
        ok, res = self.h.call(self.core.raw, 0x0A, 0x50, G, b"")
        self.assertTrue(ok)
        self.assertEqual((res["ok"], res["gen_code"]), (False, 0x8002))
        ok, res = self.h.call(self.core.raw, 0x08, 0x03, G, b"")
        self.assertEqual(res["payload_hex"][6:18], fake_modem.FAKE_PLMN.hex())

    def test_crash_and_recovery_without_loader_file(self):
        self.h.boot()
        self.h.call(self.core.dial, "+447700900123")
        self.h.run_until(lambda: self.core.state["audio"]["open"])
        self.core._modem_status = lambda: 2       # STATUS = CRASH_EXIT
        self.core.ipc_channel.on_hup(2)           # what the loop delivers on POLLHUP
        self.h.run_until(lambda: self.h.events_of("crash"))
        st = self.core.state
        self.assertEqual((st["cp"], st["power"], st["calls"], st["audio"]["open"]), ("crashed", "off", [], False))
        ok, err = self.h.call(self.core.radio_on)
        self.assertFalse(ok)
        self.assertIn("crashed", err)
        self.h.run_until(lambda: self.core._restart_phase == "discarding")  # no session file: backoff re-arm
        self.core.ipc_channel.on_hup(2)           # still hung up: pause again, no second crash event
        self.h.run_for(0.2)
        self.assertEqual(len(self.h.events_of("crash")), 1)
        self.fake.boot()
        self.h.run_until(lambda: self.core.state["cp"] == "online" and self.core.state["sim"]["state"] == "ready")
        ok, _ = self.h.call(self.core.radio_on)
        self.assertTrue(ok)

    def test_rfs_served_through_core(self):
        self.h.boot()
        self.fake.send_rfs(HDR.pack(14, 0x01, 0x5A) + struct.pack("<II", 16, 8))
        self.h.run_until(lambda: len(self.fake.rfs_rx) >= 23)
        length, cmd, rid = HDR.unpack_from(self.fake.rfs_rx)
        self.assertEqual((length, cmd, rid), (23, 0x01, 0x5A))
        self.assertEqual(self.fake.rfs_rx[6], 1)
        self.assertEqual(self.fake.rfs_rx[15:23], bytes(range(16, 24)))
        self.fake.send_rfs(HDR.pack(6 + 8, 0x0E, 0x01) + bytes(8))  # OPEN_DIR: no reply
        self.fake.send_rfs(HDR.pack(14, 0x01, 0x5B) + struct.pack("<II", 0, 1))
        self.h.run_until(lambda: len(self.fake.rfs_rx) >= 23 + 16)
        self.assertEqual(HDR.unpack_from(self.fake.rfs_rx, 23)[2], 0x5B)

    def test_scan_networks(self):
        self.h.boot()
        ok, res = self.h.call(self.core.scan_networks)
        self.assertTrue(ok)
        self.assertEqual(res, [{"status": 2, "plmn": "00101", "rat": "lte"}])


if __name__ == "__main__":
    unittest.main()


class SbdTruncationTest(CoreTestBase):
    """Kernel uplink semantics emulated by fake_modem.SbdWriter: 2048-byte writes, EBUSY."""
    harness_kwargs = {"sbd": True, "nv_bytes": bytes(range(256)) * 4096}  # 1 MiB snapshot

    def test_large_nv_reply_goes_out_in_chunks(self):
        self.fake.sbd.busy_every = 7
        self.h.boot()
        self.fake.send_rfs(HDR.pack(14, 0x01, 0x33) + struct.pack("<II", 0x100, 0x80000))
        total = 15 + 0x80000
        self.h.run_until(lambda: len(self.fake.rfs_rx) >= total, timeout=10)
        self.assertEqual(len(self.fake.rfs_rx), total)
        length, cmd, rid = HDR.unpack_from(self.fake.rfs_rx)
        self.assertEqual((length, cmd, rid), (total, 0x01, 0x33))
        confirm, off, n = struct.unpack_from("<BII", self.fake.rfs_rx, 6)
        self.assertEqual((confirm, off, n), (1, 0x100, 0x80000))
        expected = (bytes(range(256)) * 4096)[0x100:0x100 + 0x80000]
        self.assertEqual(self.fake.rfs_rx[15:], expected)
        sbd = self.fake.sbd
        self.assertEqual(sbd.max_chunk, 2048)
        self.assertGreaterEqual(sbd.calls, total // 2048)
        self.assertGreater(sbd.busy, 0, "EBUSY was retried")
        self.assertEqual(self.core.stats()["rfs"]["max_nv_read"], 0x80000)

    def test_ipc_survives_ebusy(self):
        self.fake.sbd.busy_every = 2
        self.h.boot()
        ok, res = self.h.call(self.core.radio_on)
        self.assertTrue(ok, res)
        self.assertGreater(self.fake.sbd.busy, 0)
        self.assertEqual(self.fake.frames(defs.PWR, defs.PWR_PHONE_STATE, E)[0].payload, b"\x02\x02")


class RestartContractTest(CoreTestBase):
    """SYNTHESIS v2 D5 restart contract against the fake modem (mock)."""
    harness_kwargs = {"cp_state": True}

    def _crash(self, status=2):
        self.core._modem_status = lambda: status
        self.core.ipc_channel.on_hup(2)  # what the loop delivers on POLLHUP

    def test_restart_contract(self):
        self.h.boot()
        self.h.call(self.core.radio_on)
        ok, res = self.h.call(self.core.dial, "+447700900123")
        self.assertTrue(ok)
        self.h.run_until(lambda: self.core.state["audio"]["open"])
        self.core.netcfg = NetConfig("external", state_dir=None)
        ok, _ = self.h.call(self.core.data_connect, "internet", "ipv4", None, None)
        self.assertTrue(ok)
        # stale frames sit in the RX queue (the loader keeps the fd open)
        self.fake.send(defs.NET, defs.NET_REGIST, defs.TYPE_NOTI, fake_modem.regist_payload(2))
        self.fake.send(defs.GEN, defs.GEN_PHONE_RES_SUB, defs.TYPE_RESP, b"\x01\x07\x01\x00\x80", aseq=1)
        n_events = len(self.h.events)
        self._crash(2)
        new = [(ev, d) for ev, d, _ in self.h.events[n_events:]]
        names = [ev for ev, _ in new]
        # (1) audio closed first, (2) call released and bearer down, then crash
        self.assertEqual(names[0], "audio")
        self.assertFalse(new[0][1]["open"])
        self.assertIn("call", names)
        self.assertEqual([d for ev, d in new if ev == "call"][-1]["state"], "released")
        self.assertFalse([d for ev, d in new if ev == "data"][-1]["connected"])
        self.assertIn("crash", names)
        self.assertLess(names.index("audio"), names.index("crash"))
        self.assertEqual(self.core.state["cp"], "crashed")
        self.assertEqual(self.core.state["sim"]["state"], "unknown")
        # (5) nothing resumes until the loader publishes a new online session
        before = len(self.fake.rx)
        self.fake.send(defs.SMS, defs.SMS_DEVICE_READY)      # not PWR_UP: discarded on resume
        self.fake.send(defs.MISC, defs.MISC_IPC_LOOPBACK, defs.TYPE_INDI, b"\x01\x00")
        self.h.run_for(0.1)
        self.assertEqual(self.core.state["cp"], "crashed")
        self.assertEqual(len(self.fake.rx), before, "nothing sent while waiting")
        self.h.set_cp_state(1, "booting")
        self.h.run_for(0.1)
        self.assertEqual(self.core._restart_phase, "waiting")
        self.h.set_cp_state(2, "online")
        self.h.run_until(lambda: self.core._restart_phase == "discarding")
        # (6) everything before PWR_PHONE_PWR_UP is discarded: no mandatory reply to the frames above
        self.h.run_for(0.05)
        self.assertEqual(len(self.fake.rx), before)
        self.fake.send(defs.SMS, defs.SMS_DEVICE_READY)
        self.fake.send(defs.SEC, defs.SEC_PIN_STATUS, defs.TYPE_NOTI, b"\x00\x00")
        self.h.run_for(0.1)
        self.assertEqual(self.core.state["sim"]["state"], "unknown")
        self.assertEqual(self.core._restart_phase, "discarding")
        self.fake.rx.clear()
        self.fake.boot()
        self.h.run_until(lambda: self.core.state["cp"] == "online" and self.fake.frames(defs.NET, defs.NET_REGIST, G))
        self.h.run_until(lambda: self.fake.frames(defs.CALL, defs.CALL_LIST, G))
        # (4) mseq restarted at 1; re-sync with GETs, no radio EXEC by default
        self.assertEqual(self.fake.rx[0].mseq, 1)
        self.assertEqual(self.fake.frames(defs.PWR, defs.PWR_PHONE_STATE, E), [])
        self.assertEqual(self.core.state["sim"]["state"], "ready", "SIM state from the new PIN_STATUS NOTI")
        self.assertEqual(len(self.h.events_of("crash")), 1)

    def test_sim_change_is_not_a_crash(self):
        self.h.boot()
        self._crash(7)
        self.assertEqual(self.core.state["cp"], "online")
        self.assertEqual(self.h.events_of("crash"), [])
        self.assertIsNone(self.core._restart_phase)

    def test_restore_radio_option(self):
        self.core.config.restore_radio = True
        self.h.boot()
        self.h.call(self.core.radio_on)
        self._crash(0)
        self.h.set_cp_state(2, "online")
        self.h.run_until(lambda: self.core._restart_phase == "discarding")
        self.fake.rx.clear()
        self.fake.boot()
        self.h.run_until(lambda: self.fake.frames(defs.PWR, defs.PWR_PHONE_STATE, E))
        self.assertEqual(self.fake.frames(defs.PWR, defs.PWR_PHONE_STATE, E)[0].payload, b"\x02\x02")

    def test_rfs_reseeded_and_handles_dropped_on_restart(self):
        self.h.boot()
        sandbox = self.core.rfs_server.sandbox
        body = struct.pack("<I", 0o102) + struct.pack("<I", 5) + b"a.txt"
        self.fake.send_rfs(HDR.pack(6 + len(body), 0x11, 0x01) + body)
        self.h.run_until(lambda: len(self.fake.rfs_rx) >= 14)
        self.assertEqual(struct.unpack_from("<i", self.fake.rfs_rx, 6)[0], 3)
        self._crash(2)
        self.h.run_until(lambda: self.core.rfs_server.stats["cp_restarts"] == 1)
        self.assertEqual(sandbox.handles, {})


class MtuTest(CoreTestBase):
    def test_mtu_clamped_to_1500(self):
        self.core.netcfg = NetConfig("external", state_dir=None)
        self.fake.pdp_mtu = 2000
        self.h.boot()
        ok, res = self.h.call(self.core.data_connect, "internet", "ipv4", None, None)
        self.assertTrue(ok, res)
        self.assertEqual(res["ipv4"]["mtu"], 1500)
