# SPDX-License-Identifier: GPL-2.0-or-later
"""A fake ``ModemCore`` for the facade's tests and for desktop demos.

It follows the contract of ``shannond.core.ModemCore`` (subscribe, state,
commands with a final ``done(ok, result_or_error)`` callback, events) and
answers with obviously fake values: the 001-01 test PLMN, an all-zero IMEI,
fictional +1 555 01xx numbers and documentation IP prefixes (RFC 5737,
RFC 3849).  No real identifier ever appears here.
"""

import copy
import logging

log = logging.getLogger("shannond.mm.fake")

FAKE_IMEI = "000000000000000"
FAKE_IMSI = "001010000000001"
FAKE_ICCID = "8900000000000000001"
FAKE_OWN_NUMBER = "+15555550100"
FAKE_PEER = "+15555550123"
FAKE_OPERATOR = "Test Network"


class FakeCore:
    """Scriptable stand-in for ModemCore.

    ``delay`` is the latency of every simulated modem answer (seconds, via
    ``loop.call_later``); 0 answers through ``call_soon``.  ``pin`` is the
    SIM PIN when ``sim_locked`` is true.
    """

    def __init__(self, loop, delay=0.05, sim_locked=False, sim_present=True, pin="1234",
                 power="lpm", auto_answer_outgoing=True):
        self.loop = loop
        self.delay = delay
        self.pin = pin
        self.auto_answer_outgoing = auto_answer_outgoing
        self.calls_log = []
        self._subs = []
        self._sms_store = {}
        self._next_index = 0
        self._next_ref = 1
        self._next_call = 1
        self._calls = {}
        self._data = None
        self.last_data_request = None
        self.fail = {}                  # command name -> error text to fail with
        self.hold = set()               # command names whose done() is never called
        sim_state = "absent" if not sim_present else ("locked" if sim_locked else "ready")
        self.state = {
            "power": power,
            "sim": {"state": sim_state, "pin_retries": 3, "puk_retries": 10},
            "reg": {"cs": "idle", "ps": "idle", "rat": None, "mcc": None, "mnc": None, "operator": None},
            "signal": {"percent": None, "rssi_dbm": None},
            "cp": "online",
        }

    # -- contract -------------------------------------------------------

    def subscribe(self, cb):
        self._subs.append(cb)

    def unsubscribe(self, cb):
        if cb in self._subs:
            self._subs.remove(cb)

    def radio_on(self, done):
        self._cmd("radio_on", done, self._do_radio_on)

    def radio_off(self, done):
        self._cmd("radio_off", done, self._do_radio_off)

    def enter_pin(self, pin, done):
        self._cmd("enter_pin", done, lambda: self._do_enter_pin(pin))

    def send_sms(self, number, text, done, request_status_report=False):
        self.last_status_report = request_status_report
        self._cmd("send_sms", done, lambda: self._do_send_sms(number, text))

    def list_sms(self, done):
        self._cmd("list_sms", done, lambda: (True, [dict(v) for v in self._sms_store.values()]))

    def delete_sms(self, index, done):
        def run():
            if self._sms_store.pop(index, None) is None:
                return False, "no SMS at index %s" % index
            return True, None
        self._cmd("delete_sms", done, run)

    def dial(self, number, done):
        self._cmd("dial", done, lambda: self._do_dial(number))

    def answer(self, call_id, done):
        self._cmd("answer", done, lambda: self._do_call_change(call_id, "active", None))

    def hangup(self, call_id, done):
        self._cmd("hangup", done, lambda: self._do_call_change(call_id, "released", "local"))

    def send_dtmf(self, call_id, digits, done):
        self._cmd("send_dtmf", done, lambda: (call_id in self._calls, None if call_id in self._calls else "no call"))

    def set_modes(self, mask, done):
        self.state["modes"] = mask
        self._cmd("set_modes", done, lambda: (True, {}))

    def set_attach_apn(self, apn, ip_type="ipv4", user=None, password=None, done=None, auth=None, cid=1):
        self.last_attach_request = {"apn": apn, "ip_type": ip_type, "auth": auth}
        self._cmd("set_attach_apn", done, lambda: (True, {}))

    def data_connect(self, apn, ip_type="ipv4", user=None, password=None, done=None, auth=None, cid=1):
        self.last_data_request = {"apn": apn, "ip_type": ip_type, "user": user, "auth": auth,
                                  "password_set": bool(password)}
        self._cmd("data_connect", done, lambda: self._do_data_connect(apn, ip_type))

    def data_disconnect(self, done):
        self._cmd("data_disconnect", done, self._do_data_disconnect)

    def query_identity(self, done):
        def run():
            ident = {"imei": FAKE_IMEI, "revision": "FAKE-REV-1"}
            if self.state["sim"]["state"] in ("ready", "locked"):
                ident["iccid"] = FAKE_ICCID
            if self.state["sim"]["state"] == "ready":
                ident["imsi"] = FAKE_IMSI
                ident["own_number"] = FAKE_OWN_NUMBER
            self.state.update(ident)
            return True, dict(ident)
        self._cmd("query_identity", done, run)

    def raw(self, main, sub, type_, payload, done):
        self._cmd("raw", done, lambda: (False, "raw IPC is not simulated"))

    # -- test helpers -----------------------------------------------------

    def emit(self, event, data):
        for cb in list(self._subs):
            cb(event, copy.deepcopy(data))

    def push_state(self):
        self.emit("state", self.state)

    def set(self, **changes):
        """Update top-level state keys (dicts are merged) and emit 'state'."""
        for key, value in changes.items():
            if isinstance(value, dict) and isinstance(self.state.get(key), dict):
                self.state[key].update(value)
            else:
                self.state[key] = value
        self.push_state()

    def inject_sms(self, text="hello from the fake core", sender=FAKE_PEER, timestamp=None):
        index = self._next_index
        self._next_index += 1
        entry = {"index": index, "sender": sender, "text": text,
                 "timestamp": timestamp or "2026-01-01T12:00:00+00:00", "pdu_hex": ""}
        self._sms_store[index] = entry
        self.emit("sms-received", entry)
        return index

    def store_sms(self, text="stored message", sender=FAKE_PEER):
        index = self._next_index
        self._next_index += 1
        self._sms_store[index] = {"index": index, "sender": sender, "text": text,
                                  "timestamp": "2026-01-01T08:00:00+00:00", "pdu_hex": ""}
        return index

    def incoming_call(self, number=FAKE_PEER):
        call_id = self._next_call
        self._next_call += 1
        self._calls[call_id] = {"id": call_id, "state": "incoming", "number": number, "direction": "in",
                                "reason": None}
        self.emit("call", self._calls[call_id])
        return call_id

    def remote_hangup(self, call_id, reason="remote"):
        self._do_call_change(call_id, "released", reason)

    def crash(self):
        self.state["cp"] = "crashed"
        self._calls.clear()
        self._data = None
        self.emit("crash", {})
        self.push_state()

    def recover(self):
        self.state.update(cp="online", power="lpm")
        self.state["reg"].update(cs="idle", ps="idle", rat=None, mcc=None, mnc=None, operator=None)
        self.state["signal"].update(percent=None, rssi_dbm=None)
        self.push_state()

    # -- internals --------------------------------------------------------

    def _later(self, fn, *args, scale=1.0):
        if self.delay:
            self.loop.call_later(self.delay * scale, fn, *args)
        else:
            self.loop.call_soon(fn, *args)

    def _cmd(self, name, done, run):
        self.calls_log.append(name)

        def finish():
            if name in self.fail:
                done(False, self.fail[name])
                return
            ok, result = run()
            done(ok, result)

        if name in self.hold:
            return
        self._later(finish)

    def _do_radio_on(self):
        if self.state["cp"] != "online":
            return False, "CP offline"
        self.state["power"] = "on"
        self.state["reg"].update(cs="searching", ps="searching")
        self.push_state()
        self._later(self._register, scale=2)
        return True, None

    def _register(self):
        if self.state["power"] != "on":
            return
        self.state["reg"].update(cs="home", ps="home", rat="lte", mcc="001", mnc="01", operator=FAKE_OPERATOR)
        self.state["signal"].update(percent=72, rssi_dbm=-71)
        self.push_state()

    def _do_radio_off(self):
        self.state["power"] = "lpm"
        self.state["reg"].update(cs="idle", ps="idle", rat=None, mcc=None, mnc=None, operator=None)
        self.state["signal"].update(percent=None, rssi_dbm=None)
        if self._data:
            self._data = None
            self.emit("data", {"connected": False, "cid": 1, "interface": "rmnet0", "ipv4": None, "ipv6": None})
        self.push_state()
        return True, None

    def _do_enter_pin(self, pin):
        sim = self.state["sim"]
        if sim["state"] != "locked":
            return False, "SIM not locked"
        if pin == self.pin:
            sim.update(state="ready", pin_retries=3)
            self.push_state()
            return True, None
        sim["pin_retries"] = max(0, sim["pin_retries"] - 1)
        self.push_state()
        return False, "incorrect PIN"

    def _do_send_sms(self, number, text):
        if self.state["power"] != "on":
            return False, "radio off"
        ref = self._next_ref
        self._next_ref = (self._next_ref + 1) % 256
        self._later(self.emit, "sms-sent", {"ref": ref, "ok": True, "error": None})
        return True, {"ref": ref}

    def _do_dial(self, number):
        call_id = self._next_call
        self._next_call += 1
        call = {"id": call_id, "state": "dialing", "number": number, "direction": "out", "reason": None}
        self._calls[call_id] = call
        self.emit("call", call)
        if self.auto_answer_outgoing:
            self._later(self._do_call_change, call_id, "alerting", None, scale=2)
            self._later(self._do_call_change, call_id, "active", None, scale=4)
        return True, {"id": call_id}

    def _do_call_change(self, call_id, state, reason):
        call = self._calls.get(call_id)
        if call is None:
            return False, "no such call"
        if call["state"] == "released":
            return True, None
        call.update(state=state, reason=reason)
        self.emit("call", call)
        if state == "released":
            self._calls.pop(call_id, None)
        return True, None

    def _do_data_connect(self, apn, ip_type):
        if self.state["power"] != "on" or self.state["reg"]["ps"] not in ("home", "roaming"):
            return False, "not attached"
        data = {"connected": True, "cid": 1, "interface": "rmnet0", "ipv4": None, "ipv6": None}
        if ip_type in ("ipv4", "ipv4v6"):
            data["ipv4"] = {"address": "192.0.2.10", "prefix": 32, "gateway": None,
                            "dns": ["192.0.2.53", "192.0.2.54"], "mtu": 1500}
        if ip_type in ("ipv6", "ipv4v6"):
            data["ipv6"] = {"address": "2001:db8::1:0:0:a", "prefix": 64, "gateway": None,
                            "dns": ["2001:db8::53"], "mtu": 1500}
        self._data = data
        self.emit("data", data)          # like ModemCore: the event precedes done()
        return True, dict(data)

    def _do_data_disconnect(self):
        if self._data is None:
            return True, None
        self._data = None
        self.emit("data", {"connected": False, "cid": 1, "interface": "rmnet0", "ipv4": None, "ipv6": None})
        return True, None
