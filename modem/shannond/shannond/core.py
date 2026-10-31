# SPDX-License-Identifier: GPL-2.0-or-later
"""ModemCore: single owner of /dev/umts_ipc0 and /dev/umts_rfs0.

This is the internal API the ModemManager facade (``shannond.mm``) and the
control socket are written against.  Summary (details in README.md):

    core = ModemCore(loop, ipc_path="/dev/umts_ipc0", rfs_path="/dev/umts_rfs0")
    core.subscribe(cb)          # cb(event: str, data: dict)
    core.start()
    core.state                  # aggregated state dict (see README)
    core.radio_on(done)         # done(ok: bool, result_or_error)

Events: 'state', 'sms-received', 'sms-sent', 'call', 'data', 'audio', 'crash'
(plus 'sms-status-report').  Commands are asynchronous; ``done`` is always
called later from the loop (never re-entrantly), with ``(True, result)`` or
``(False, "error message")``.

Privacy: identifiers (IMEI, IMSI, ICCID, numbers, SMS text, PLMN, cell ids)
are never logged.  ``state`` carries ``imei``/``imsi``/``iccid``/
``own_number`` only after ``query_identity()``.
"""

import copy
import datetime
import fcntl
import logging
import os
import stat
import subprocess

from . import defs, messages, netcfg as netcfg_mod
from .cpstate import read_cp_state
from .ipc import FmtChannel, IpcClient, IpcError, PayloadLog
from .loop import Op, OpError, OpTimeout, sleep, spawn, wait_op

log = logging.getLogger("shannond.core")

MODEM_IOCTL_STATUS = 0x6F27
GEN_PDP_BUSY = (0x8005, 0x8001)   # first activation of a CP session, then 0x8001
PDP_CAUSE_NOT_READY = 255         # the CP's own refusal, no network cause: seen while it leaves 3G for LTE
PDP_BUSY_RETRIES = 16
PDP_BUSY_DELAY = 3.0
MODEM_STATES = {0: "offline", 1: "crash-reset", 2: "crash-exit", 3: "booting", 4: "online",
                5: "nv-rebuilding", 6: "loader-done", 7: "sim-attach", 8: "sim-detach"}

AUDIO_PATHS = {"handset": defs.SND_PATH_HANDSET, "headset": defs.SND_PATH_HEADSET,
               "speaker": defs.SND_PATH_SPEAKER, "headphone": defs.SND_PATH_HEADPHONE,
               "bt": defs.SND_PATH_BT}
AUDIO_VOLUME_TYPE = {"handset": defs.SND_VOLUME_VOICE, "headset": defs.SND_VOLUME_HEADSET,
                     "speaker": defs.SND_VOLUME_SPEAKER, "headphone": defs.SND_VOLUME_HEADSET,
                     "bt": defs.SND_VOLUME_BT}


class CommandError(OpError):
    pass


class PdpRefused(CommandError):
    def __init__(self, cause):
        super().__init__("PDP activation failed (cause %d)" % cause)
        self.cause = cause


def mask_number(number):
    """'+33639980012' -> '+*********12' (never log more than this)."""
    if not number:
        return ""
    s = str(number)
    prefix = "+" if s.startswith("+") else ""
    digits = s[len(prefix):]
    if len(digits) <= 4:
        return prefix + "*" * len(digits)
    return prefix + "*" * (len(digits) - 2) + digits[-2:]


class CoreConfig:
    """Tunables (defaults follow the catalogue / SYNTHESIS D8)."""

    def __init__(self, **kw):
        self.request_timeout = 10.0
        self.sms_timeout = 60.0
        self.data_timeout = 60.0
        self.data_down_timeout = 10.0
        self.dial_id_timeout = 10.0
        self.clock_fallback_s = 3.0      # D8: CLOCK_CTRL E {1} if no clock NOTI 3 s after connect
        self.recovery_interval = 1.0
        self.recovery_max_interval = 10.0
        self.cp_state_poll = 0.5         # restart contract: poll of the loader's session file
        self.resync_delay = 0.3          # after PWR_PHONE_PWR_UP, before the re-sync GETs
        self.restore_radio = False       # re-send radio on after a CP restart (off: GETs only, v2 D5)
        self.mode_sel_on_radio = True
        self.mode_sel_mask = defs.NET_MODE_LTE_WCDMA_GSM
        self.sms_domain = 0x02           # ConvertDomainToIPC(0) on the stock RIL
        self.smsc_mode = "cp"            # "cp": ask SVC_CENTER_ADDR; "empty": default SMSC (00)
        self.audio_path = "speaker"
        self.volume_level = 4
        self.dtmf_ms = 150
        self.protover = 2                # SS333: LTE attach APN is sent
        self.lte_attach = True
        self.lte_attach_apn = None       # sent before every radio on (docs/hardware/MODEM.md §6.7)
        self.settings = None             # shannond.settings.Settings: what the user chose wins over the above
        self.radio_on_start = False      # radio on as soon as the CP is ready (a phone must ring)
        self.ipc_stream = None           # None = auto (pty/stream sockets need reassembly)
        for key, value in kw.items():
            if not hasattr(self, key):
                raise TypeError("unknown config key %s" % key)
            setattr(self, key, value)


def _initial_state(passive):
    return {
        "cp": "offline",
        "power": "off",
        "sim": {"state": "unknown", "pin_retries": None, "puk_retries": None,
                "lock": None, "icc_type": None},
        "reg": {"cs": "unknown", "ps": "unknown", "rat": None, "mcc": None, "mnc": None,
                "operator": None},
        "signal": {"percent": None, "rssi_dbm": None},
        "calls": [],
        "data": None,
        "audio": {"open": False, "rate": 8000},
        "passive": bool(passive),
    }


class ModemCore:
    def __init__(self, loop, ipc_path=None, rfs_path=None, *, ipc_fd=None, rfs_fd=None,
                 passive=False, rfs_server=None, netcfg=None, payload_log_dir=None,
                 audio_hook_cmd=None, config=None, cp_state_path=None, rfs_threaded=True, writer=None):
        self.loop = loop
        self.ipc_path = ipc_path
        self.rfs_path = rfs_path
        self._ipc_fd = ipc_fd
        self._rfs_fd = rfs_fd
        self.passive = passive
        self.rfs_server = rfs_server
        self.netcfg = netcfg or netcfg_mod.NetConfig("external", state_dir=None)
        self.config = config or CoreConfig()
        self.audio_hook_cmd = audio_hook_cmd
        self.cp_state_path = cp_state_path
        self.rfs_threaded = rfs_threaded
        self.writer = writer             # None = os.write; tests inject an SBD-truncating writer
        self.rfs_service = None
        self._restart_phase = None       # None | "waiting" (for the loader) | "discarding" (until PWR_UP)
        self._crashed_session = None
        self._session = None
        self._radio_wanted = False
        self.state = _initial_state(passive)
        self.ipc = IpcClient(loop, default_timeout=self.config.request_timeout)
        self.ipc.handlers.append(self._on_frame)
        self.ipc_channel = None
        self.rfs_channel = None
        self._payload_ipc = PayloadLog(payload_log_dir, "ipc") if payload_log_dir else None
        self._payload_rfs = PayloadLog(payload_log_dir, "rfs") if payload_log_dir else None
        self._subscribers = []
        self._state_dirty = False
        self._last_state = None
        # internal (never logged)
        self._identity = {}
        self._reg_detail = {}
        self._signal = messages.Signal()
        self._pin_noti_seen = False
        self._smsc_field = None
        self._sms_store = {}
        self._sms_next_index = 1
        self._concat = None
        self._calls = {}
        self._dial_waiters = []
        self._dialing_number = None
        self._data = None
        self._data_cache = {}
        self._data_waiters = []
        self._audio_prepared = False
        self._cp_clock = False
        self._clock_fallback_timer = None
        self._wb = False
        self._rfs_needs_reseed = False
        self._resync_pending = False
        self._recovery_timer = None
        self._recovery_interval = self.config.recovery_interval
        self.network_time = None
        self.mandatory_sent = {"device_ready": 0, "loopback": 0}
        # The SS333 answers every SMS_DEVICE_READY SET with a new NOTI (seen on the tablet,
        # ~250 Hz ping-pong): answer the first NOTI of each CP session only.
        self._device_ready_done = False
        self._regist_reread = False
        self._radio_on_pending = False
        # LTE attach profile: what to send, and what this CP session already has.
        self._attach_profile = None
        self.settings = self.config.settings
        saved = self.settings.get("attach") if self.settings else None
        if saved:
            self._attach_profile = messages.gprs_lte_attach_apn_info(1, saved["apn"], messages.PDP_TYPES[saved["ip_type"]],
                                                                     saved["user"], saved["password"], saved["auth"])
        elif self.config.lte_attach_apn:
            self._attach_profile = messages.gprs_lte_attach_apn_info(1, self.config.lte_attach_apn)
        if self.settings and self.settings.get("modes"):
            self.config.mode_sel_mask = self.settings.get("modes")
        self.state["modes"] = self.config.mode_sel_mask
        self._attach_sent = None
        self._handlers = {
            (defs.PWR, defs.PWR_PHONE_PWR_UP): self._h_pwr_up,
            (defs.PWR, defs.PWR_PHONE_STATE): self._h_phone_state,
            (defs.PWR, defs.PWR_PHONE_RESET): self._h_phone_reset,
            (defs.MISC, defs.MISC_IPC_LOOPBACK): self._h_loopback,
            (defs.MISC, defs.MISC_TIME_INFO): self._h_time,
            (defs.SMS, defs.SMS_DEVICE_READY): self._h_device_ready,
            (defs.SMS, defs.SMS_DELIVER_REPORT): self._h_deliver_report_ack,
            (defs.SMS, defs.SMS_INCOMING_MSG): self._h_sms_incoming,
            (defs.SMS, defs.SMS_SEND_MSG): self._h_sms_send_noti,
            (defs.SEC, defs.SEC_PIN_STATUS): self._h_pin_status,
            (defs.SEC, defs.SEC_SIM_ICC_TYPE): self._h_icc_type,
            (defs.SEC, defs.SEC_SIM_ICCID): self._h_iccid,
            (defs.NET, defs.NET_REGIST): self._h_regist,
            (defs.NET, defs.NET_SERVING_NETWORK): self._h_serving,
            (defs.NET, defs.NET_IDENTITY): self._h_identity,
            (defs.DISP, defs.DISP_RSSI_INFO): self._h_rssi,
            (defs.DISP, defs.DISP_ICON_INFO): self._h_icon,
            (defs.CALL, defs.CALL_INCOMING): self._h_call_incoming,
            (defs.CALL, defs.CALL_STATUS): self._h_call_status,
            (defs.CALL, defs.CALL_LIST): self._h_call_list,
            (defs.GPRS, defs.GPRS_CALL_STATUS): self._h_gprs_call_status,
            (defs.GPRS, defs.GPRS_IP_CONFIGURATION): self._h_ip_config,
            (defs.GPRS, defs.GPRS_PS): self._h_gprs_ps,
            (defs.SND, defs.SND_CLOCK_CTRL): self._h_clock_ctrl,
            (defs.SND, defs.SND_WB_AMR_RPT): self._h_wb_amr,
        }

    # ------------------------------------------------------------------ lifecycle
    def start(self):
        if self._ipc_fd is None:
            if not self.ipc_path:
                raise ValueError("no IPC device")
            self._ipc_fd = os.open(self.ipc_path, os.O_RDWR | os.O_NOCTTY | os.O_CLOEXEC)
        self.ipc_channel = FmtChannel(self.loop, self._ipc_fd, self._on_raw_frame, on_hup=self._on_hup,
                                      stream=self.config.ipc_stream, payload_log=self._payload_ipc)
        if self.writer is not None:
            self.ipc_channel.writer = self.writer
        self.ipc.attach(self.ipc_channel)
        self.ipc_channel.start()
        self._session, cp_state = read_cp_state(self.cp_state_path)
        if self.rfs_server is not None:
            from .rfs import RfsService
            if self._rfs_fd is None:
                self._rfs_fd = os.open(self.rfs_path, os.O_RDWR | os.O_NOCTTY | os.O_CLOEXEC)
            self.rfs_service = RfsService(self.rfs_server, self._rfs_fd, payload_log=self._payload_rfs,
                                          writer=self.writer)
            self.rfs_service.start(threaded=self.rfs_threaded)
            self.rfs_channel = self.rfs_service.channel
        log.info("shannond core started (passive=%s, rfs=%s)", self.passive, self.rfs_server is not None)
        if cp_state == "online" and not self.passive:
            # Started while the CP runs (daemon restart): PWR_PHONE_PWR_UP and the SIM NOTIs of
            # this session are gone, so ask for the state instead of waiting for them.
            self.loop.call_later(self.config.resync_delay, self._attach_running)

    def _attach_running(self):
        if self.ipc_channel is None or self.state["cp"] == "crashed":
            return
        log.info("CP already online (session %s): querying its state", self._session)
        self._pin_noti_seen = True
        self._fire(defs.PWR, defs.PWR_PHONE_STATE, defs.TYPE_GET, b"", what="PWR_PHONE_STATE")
        self.refresh()
        self._schedule_radio_on()

    def _schedule_radio_on(self):
        if not self.config.radio_on_start or self.passive or self._radio_on_pending:
            return
        if self.settings and self.settings.get("radio_off"):
            log.info("radio left off (airplane mode)")
            return
        self._radio_on_pending = True

        def go():
            self._radio_on_pending = False
            if self.state["cp"] == "online" and self.state["power"] != "on":
                log.info("radio on (--radio-on)")
                self.radio_on()
        self.loop.call_later(self.config.resync_delay + 0.5, go)

    def stop(self):
        if self._recovery_timer is not None:
            self._recovery_timer.cancel()
        self.ipc.fail_all("daemon stopping")
        if self.ipc_channel is not None:
            self.ipc_channel.close()
        if self.rfs_service is not None:
            self.rfs_service.stop()
            self.rfs_service = None
        for fd in (self._ipc_fd, self._rfs_fd):
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass
        self._ipc_fd = self._rfs_fd = None
        for pl in (self._payload_ipc, self._payload_rfs):
            if pl is not None:
                pl.close()

    # ------------------------------------------------------------------ events
    def subscribe(self, cb):
        """Register cb(event, data); returns a function that unsubscribes."""
        self._subscribers.append(cb)

        def unsubscribe():
            try:
                self._subscribers.remove(cb)
            except ValueError:
                pass
        return unsubscribe

    def _emit(self, event, data):
        for cb in list(self._subscribers):
            try:
                cb(event, copy.deepcopy(data))
            except Exception:
                log.exception("subscriber failed on %s", event)

    def _touch(self):
        if not self._state_dirty:
            self._state_dirty = True
            self.loop.call_soon(self._flush_state)

    def _flush_state(self):
        self._state_dirty = False
        snap = copy.deepcopy(self.state)
        if snap != self._last_state:
            self._last_state = snap
            self._emit("state", snap)

    def _set(self, section, key, value):
        target = self.state if section is None else self.state[section]
        if target.get(key) != value:
            target[key] = value
            self._touch()

    # ------------------------------------------------------------------ command helpers
    def _complete(self, op, done):
        if done is None:
            return op

        def fin(o):
            exc = o.exception()
            if exc is not None:
                self.loop.call_soon(done, False, str(exc) or exc.__class__.__name__)
            else:
                self.loop.call_soon(done, True, o._result)
        op.add_done_callback(fin)
        return op

    def _command(self, gen_fn, done, name, *args, allow_passive=False, need_cp=True):
        if self.passive and not allow_passive:
            return self._complete(Op.failed(CommandError("passive mode: command refused"), name), done)
        if need_cp and self.ipc_channel is None:
            return self._complete(Op.failed(CommandError("IPC channel not open"), name), done)
        if need_cp and self.state["cp"] == "crashed":
            return self._complete(Op.failed(CommandError("modem crashed"), name), done)
        try:
            gen = gen_fn(*args)
        except (ValueError, CommandError) as exc:
            return self._complete(Op.failed(exc if isinstance(exc, CommandError) else CommandError(str(exc)),
                                            name), done)
        return self._complete(spawn(gen, name), done)

    def _req(self, main, sub, typ, payload=b"", **kw):
        return self.ipc.send(main, sub, typ, payload, **kw)

    def _fire(self, main, sub, typ, payload=b"", what=None):
        """Send a request whose failure is only logged (background queries)."""
        op = self._req(main, sub, typ, payload)

        def fin(o):
            if o.exception() is not None:
                log.info("%s: %s", what or o.name, o.exception())
        op.add_done_callback(fin)
        return op

    # ------------------------------------------------------------------ frame dispatch
    def _on_raw_frame(self, frame):
        """Restart contract step 6: drop everything before the next PWR_PHONE_PWR_UP NOTI."""
        if self._restart_phase is not None:
            if (frame.main, frame.sub, frame.type) == (defs.PWR, defs.PWR_PHONE_PWR_UP, defs.TYPE_NOTI):
                log.info("CP back: PWR_PHONE_PWR_UP after restart")
                self._restart_phase = None
                self._recovery_interval = self.config.recovery_interval
            else:
                log.debug("discarded during restart: %s", frame.describe("RX"))
                return
        self.ipc.on_frame(frame)

    def _on_frame(self, frame):
        if self.state["cp"] != "online" and frame.main != defs.GEN:
            self._set(None, "cp", "online")
            self._recovery_interval = self.config.recovery_interval
        key = (frame.main, frame.sub)
        if frame.main == defs.GEN:
            return
        handler = self._handlers.get(key)
        if handler is None:
            log.info("ignored %s (no handler)", frame.describe("RX"))
            return
        try:
            obj = messages.decode(frame.main, frame.sub, frame.payload)
        except messages.DecodeError as exc:
            log.warning("cannot decode %s: %s", frame.describe("RX"), exc)
            return
        handler(frame, obj)

    # ---- power / boot
    def _h_pwr_up(self, frame, _obj):
        log.info("CP announced PWR_PHONE_PWR_UP")
        self._device_ready_done = False
        self._attach_sent = None
        resync = self._rfs_needs_reseed or self._resync_pending
        if self._rfs_needs_reseed and self.rfs_service is not None and not self._resync_pending:
            log.info("CP restart without hang-up: re-seeding the RFS sandbox")
            self.rfs_service.cp_restarted()
        self._rfs_needs_reseed = True
        self._set(None, "cp", "online")
        if self.state["power"] == "off":
            self._set(None, "power", "lpm")
        self._schedule_radio_on()
        if resync and not self.passive:
            self._resync_pending = False
            self.loop.call_later(self.config.resync_delay, self._resync)

    def _resync(self):
        """After a CP restart: re-read state with GETs (PIN, REGIST, CALL_LIST)."""
        if self.state["cp"] != "online" or self.passive:
            return
        log.info("re-synchronising after CP restart")
        self._fire(defs.CALL, defs.CALL_LIST, defs.TYPE_GET, messages.call_list_get(), what="CALL_LIST")
        if self.config.restore_radio and self._radio_wanted:
            self.radio_on()
        else:
            self.refresh()

    def _h_phone_state(self, frame, obj):
        power = obj.power
        if power != "unknown":
            self._set(None, "power", power)

    def _h_phone_reset(self, frame, obj):
        log.warning("PWR_PHONE_RESET type=%d cause=%d", obj.reset_type, obj.cause)

    def _h_loopback(self, frame, value):
        # Mandatory (also in passive mode): echo the u16 in a CFRM.
        self.mandatory_sent["loopback"] += 1
        self._req(defs.MISC, defs.MISC_IPC_LOOPBACK, defs.TYPE_CFRM, messages.misc_loopback_cfrm(value))

    def _h_device_ready(self, frame, _obj):
        if frame.type != defs.TYPE_NOTI and frame.aseq:
            return  # an answer to our own SET
        if self._device_ready_done:
            log.debug("SMS_DEVICE_READY NOTI again: already answered this session")
            return
        self._device_ready_done = True
        # Mandatory (also in passive mode): answer with SMS_DEVICE_READY SET.
        self.mandatory_sent["device_ready"] += 1
        self._fire(defs.SMS, defs.SMS_DEVICE_READY, defs.TYPE_SET, messages.sms_device_ready_set())

    def _h_deliver_report_ack(self, frame, ack):
        log.info("SMS deliver report acknowledged by the CP (0x%04x)", ack)

    def _h_time(self, frame, t):
        try:
            tz = datetime.timezone(datetime.timedelta(minutes=15 * t.tz_quarters))
            self.network_time = {"time": datetime.datetime(t.year, t.month, t.day, t.hour, t.minute, t.second,
                                                           tzinfo=tz).isoformat(),
                                 "tz_minutes": 15 * t.tz_quarters, "dst": t.dst}
        except ValueError:
            log.info("MISC_TIME_INFO with an invalid date ignored")

    # ---- SIM
    def _h_pin_status(self, frame, obj):
        first = not self._pin_noti_seen
        if frame.type == defs.TYPE_NOTI:
            self._pin_noti_seen = True
        sim_state, lock = obj.sim_state()
        changed = (self.state["sim"]["state"], self.state["sim"]["lock"]) != (sim_state, lock)
        self._set("sim", "state", sim_state)
        self._set("sim", "lock", lock)
        log.info("SIM status 0x%02x/%d -> %s%s", obj.status, obj.facility, sim_state,
                 " (%s)" % lock if lock else "")
        if lock in ("sim-pin", "sim-puk") and (changed or first) and not self.passive:
            self._query_lock_info()

    def _query_lock_info(self):
        op = self._req(defs.SEC, defs.SEC_LOCK_INFORMATION, defs.TYPE_GET, messages.sec_lock_info_get())

        def fin(o):
            if o.exception() is not None:
                log.info("lock info query failed: %s", o.exception())
                return
            try:
                info = messages.dec_lock_info(o._result.frame.payload)
            except messages.DecodeError as exc:
                log.info("%s", exc)
                return
            key = "puk_retries" if self.state["sim"]["lock"] == "sim-puk" else "pin_retries"
            self._set("sim", key, info.retries)
        op.add_done_callback(fin)

    def _h_icc_type(self, frame, icc):
        self._set("sim", "icc_type", icc)

    def _h_iccid(self, frame, iccid):
        self._identity["iccid"] = iccid  # exposed only through query_identity()

    # ---- network
    def _update_rat(self):
        ps = self._reg_detail.get("ps")
        cs = self._reg_detail.get("cs")
        rat = None
        for r in (ps, cs):
            if r is not None and r.state in ("home", "roaming") and r.rat:
                rat = r.rat
                break
        if rat is None and self._reg_detail.get("serving_rat"):
            rat = self._reg_detail["serving_rat"]
        self._set("reg", "rat", rat)

    def _h_regist(self, frame, r):
        if r.domain == defs.NET_DOMAIN_CS:
            dom = "cs"
        elif r.domain == defs.NET_DOMAIN_PS:
            dom = "ps"
        else:
            # The SS333 reports LTE (re)registrations with domain 1, whose CS/PS meaning is
            # unknown: re-read both domains instead of guessing (debounced).
            log.info("NET_REGIST with domain %d: re-reading CS and PS", r.domain)
            if not self.passive and not self._regist_reread:
                self._regist_reread = True

                def reread():
                    self._regist_reread = False
                    for d in (defs.NET_DOMAIN_CS, defs.NET_DOMAIN_PS):
                        self._fire(defs.NET, defs.NET_REGIST, defs.TYPE_GET, messages.net_regist_get(d))
                self.loop.call_later(1.0, reread)
            return
        self._reg_detail[dom] = r
        self._set("reg", dom, r.state)
        self._update_rat()
        if r.state not in ("home", "roaming") and self.state["reg"]["cs"] not in ("home", "roaming") \
                and self.state["reg"]["ps"] not in ("home", "roaming"):
            self._set("reg", "mcc", None)
            self._set("reg", "mnc", None)

    def _h_serving(self, frame, s):
        self._reg_detail["serving_rat"] = messages.rat_name(s.act)
        if s.mcc:
            self._set("reg", "mcc", s.mcc)
            self._set("reg", "mnc", s.mnc)
        self._update_rat()

    def _h_identity(self, frame, ident):
        name = ident.full_name or ident.short_name
        if name:
            self._set("reg", "operator", name)

    def _h_rssi(self, frame, sig):
        self._signal.rssi_dbm = sig.rssi_dbm
        if sig.rsrp_dbm is not None:
            self._signal.rsrp_dbm = sig.rsrp_dbm
        self._publish_signal()

    def _h_icon(self, frame, sig):
        self._signal.bars = sig.bars
        if sig.rsrp_dbm is not None:
            self._signal.rsrp_dbm = sig.rsrp_dbm
        self._publish_signal()

    def _publish_signal(self):
        self._set("signal", "percent", self._signal.percent)
        self._set("signal", "rssi_dbm", self._signal.rssi_dbm)

    # ---- SMS
    def _h_sms_incoming(self, frame, inc):
        from . import sms_pdu
        msg = None
        error = None
        try:
            msg = sms_pdu.decode_pdu(inc.pdu, has_smsc=True)
        except ValueError as exc:
            error = "undecodable PDU: %s" % exc
        if not self.passive:
            # The SS333 answers with a SMS_DELIVER_REPORT NOTI (aseq 0), not a GEN_PHONE_RES:
            # send without waiting, the NOTI handler logs the CP's ack.
            self._req(defs.SMS, defs.SMS_DELIVER_REPORT, defs.TYPE_EXEC,
                      messages.sms_deliver_report(inc.msg_id, 0x0000), expect="none")
        if isinstance(msg, sms_pdu.SmsStatusReport):
            log.info("SMS status report for ref %d: status 0x%02x", msg.message_ref, msg.status)
            self._emit("sms-status-report", {"ref": msg.message_ref, "status": msg.status,
                                             "delivered": msg.status < 0x20})
            return
        if msg is not None:
            kind = sms_pdu.service_message(msg)
            if kind is not None:
                log.info("service SMS dropped: %s", kind)
                return
            if self._concat is None:
                self._concat = sms_pdu.ConcatAssembler()
            whole = self._concat.feed(msg, now=self.loop.time())
            parts = self._pending_parts(msg, inc.pdu)
            if whole is None:
                log.info("SMS part received (%d/%d)", msg.concat[2] if msg.concat else 1,
                         msg.concat[1] if msg.concat else 1)
                return
            kind = sms_pdu.service_message(whole)
            if kind is not None:
                log.info("service SMS dropped: %s", kind)
                return
            entry = {"sender": whole.originator, "text": whole.text,
                     "timestamp": whole.timestamp.isoformat() if whole.timestamp else None,
                     "pdu_hex": parts[0], "parts_hex": parts, "encoding": whole.encoding}
        else:
            entry = {"sender": None, "text": None, "timestamp": None, "pdu_hex": inc.pdu.hex(),
                     "parts_hex": [inc.pdu.hex()], "error": error}
        index = self._sms_next_index
        self._sms_next_index += 1
        entry["index"] = index
        self._sms_store[index] = entry
        log.info("SMS received: index=%d from=%s chars=%s", index, mask_number(entry["sender"]),
                 len(entry["text"]) if entry["text"] is not None else "?")
        self._emit("sms-received", entry)

    def _pending_parts(self, msg, pdu):
        """Keep raw PDUs of concatenated parts until the message is complete."""
        if not hasattr(self, "_part_pdus"):
            self._part_pdus = {}
        if not msg.concat:
            return [pdu.hex()]
        ref, total, seq = msg.concat
        key = (msg.originator, ref, total)
        bucket = self._part_pdus.setdefault(key, {})
        bucket[seq] = pdu.hex()
        if len(bucket) >= total:
            del self._part_pdus[key]
            return [bucket[k] for k in sorted(bucket)]
        return [pdu.hex()]

    def _h_sms_send_noti(self, frame, res):
        if frame.type == defs.TYPE_NOTI or not frame.aseq:
            self.ipc.complete_oldest(defs.SMS, defs.SMS_SEND_MSG, frame)

    # ---- calls
    def _calls_changed(self):
        calls = []
        for c in sorted(self._calls.values(), key=lambda x: x["id"]):
            calls.append(dict(c))
        if self.state["calls"] != calls:
            self.state["calls"] = calls
            self._touch()

    def _call_event(self, call, reason=None):
        data = {"id": call["id"], "state": call["state"], "number": call.get("number"),
                "direction": call["direction"], "reason": reason}
        log.info("call %d %s (%s) %s", call["id"], call["state"], call["direction"],
                 mask_number(call.get("number")))
        self._emit("call", data)

    def _update_call(self, call_id, state, direction=None, number=None, reason=None, call_type=None):
        call = self._calls.get(call_id)
        is_new = call is None
        if is_new:
            if state == "released":
                return
            if number is None and (direction or "out") == "out" and self._dialing_number:
                number = self._dialing_number  # CALL_STATUS carries no number: use the pending dial's
            call = {"id": call_id, "state": state, "direction": direction or "out",
                    "number": number, "type": call_type}
            self._calls[call_id] = call
        changed = is_new or call["state"] != state or (number and call.get("number") != number)
        if direction and is_new:
            call["direction"] = direction
        if number:
            call["number"] = number
        call["state"] = state
        if state == "released":
            del self._calls[call_id]
        if changed:
            self._call_event(call, reason)
        self._calls_changed()
        if is_new and call["direction"] == "out":
            for w in list(self._dial_waiters):
                w.set_result(call_id)
            self._dial_waiters.clear()
        self._audio_on_call_change(call_id, state)

    def _h_call_incoming(self, frame, inc):
        call_id = inc.call_id or 1
        self._update_call(call_id, "incoming", direction="in")
        if not self.passive:
            self._fire(defs.CALL, defs.CALL_LIST, defs.TYPE_GET, messages.call_list_get(), what="CALL_LIST")

    def _h_call_status(self, frame, st):
        call_id = st.call_id
        state = st.state
        if state == "ignoring" or state == "unknown":
            log.info("CALL_STATUS id=%d status=%d", call_id, st.status)
            return
        direction = None
        existing = self._calls.get(call_id)
        if existing is None:
            direction = "out" if state in ("dialing", "alerting") else "in"
        reason = None
        if state == "released":
            reason = "cause %d/%d" % (st.cause_type, st.end_cause)
        self._update_call(call_id, state, direction=direction, reason=reason)

    def _h_call_list(self, frame, entries):
        seen = set()
        for e in entries:
            seen.add(e.call_id)
            self._update_call(e.call_id, e.state, direction=e.direction, number=e.number or None)
        if frame.type == defs.TYPE_RESP:
            for call_id in [c for c in self._calls if c not in seen]:
                self._update_call(call_id, "released", reason="not in call list")

    # ---- audio (SYNTHESIS D8, IPC side only; ALSA is the hook's job)
    def _audio_on_call_change(self, call_id, state):
        if self.passive:
            return
        if state in ("dialing", "alerting", "active"):
            self._audio_prepare()
        if state == "active" and not self._cp_clock and self._clock_fallback_timer is None:
            self._clock_fallback_timer = self.loop.call_later(self.config.clock_fallback_s, self._clock_fallback)
        if not self._calls:
            self._audio_end_of_calls()

    def _audio_prepare(self):
        if self._audio_prepared:
            return
        self._audio_prepared = True
        path = self.config.audio_path
        self._fire(defs.SND, defs.SND_AUDIO_PATH_CTRL, defs.TYPE_SET,
                   messages.snd_audio_path(AUDIO_PATHS[path], 0))
        self._fire(defs.SND, defs.SND_SPKR_VOLUME_CTRL, defs.TYPE_SET,
                   messages.snd_spkr_volume(AUDIO_VOLUME_TYPE[path], self.config.volume_level))
        self._fire(defs.SND, defs.SND_TWO_MIC_SOL_CTRL, defs.TYPE_SET, messages.snd_two_mic(0, 0))
        self._fire(defs.SND, defs.SND_MIC_MUTE_CTRL, defs.TYPE_SET, messages.snd_mic_mute(0))

    def _clock_fallback(self):
        self._clock_fallback_timer = None
        if self._cp_clock or not self._calls:
            return
        log.warning("no SND_CLOCK_CTRL NOTI %.1f s after connect: sending CLOCK_CTRL start",
                    self.config.clock_fallback_s)
        op = self._req(defs.SND, defs.SND_CLOCK_CTRL, defs.TYPE_EXEC, messages.snd_clock_ctrl(True))

        def fin(o):
            if o.exception() is None and self._calls:
                self._audio_open(fallback=True)
            elif o.exception() is not None:
                log.warning("CLOCK_CTRL start failed: %s", o.exception())
        op.add_done_callback(fin)

    def _audio_open(self, fallback=False):
        rate = 16000 if self._wb else 8000
        if self.state["audio"]["open"] and self.state["audio"]["rate"] == rate:
            return
        self.state["audio"] = {"open": True, "rate": rate}
        self._touch()
        self._audio_hook({"open": True, "rate": rate, "fallback": fallback})

    def _audio_close(self):
        if not self.state["audio"]["open"]:
            return
        self.state["audio"] = {"open": False, "rate": self.state["audio"]["rate"]}
        self._touch()
        self._audio_hook({"open": False, "rate": self.state["audio"]["rate"]})

    def _audio_hook(self, data):
        log.info("audio %s rate=%d", "open" if data["open"] else "close", data["rate"])
        self._emit("audio", data)
        if self.audio_hook_cmd:
            env = dict(os.environ, SHANNON_AUDIO_OPEN="1" if data["open"] else "0",
                       SHANNON_AUDIO_RATE=str(data["rate"]), SHANNON_AUDIO_PATH=self.config.audio_path)
            try:
                subprocess.run([self.audio_hook_cmd, "open" if data["open"] else "close", str(data["rate"]),
                                self.config.audio_path], env=env, timeout=5, check=False,
                               stdin=subprocess.DEVNULL)
            except (OSError, subprocess.TimeoutExpired) as exc:
                log.warning("audio hook failed: %s", exc)

    def _audio_end_of_calls(self):
        if self._clock_fallback_timer is not None:
            self._clock_fallback_timer.cancel()
            self._clock_fallback_timer = None
        was_prepared = self._audio_prepared
        self._audio_prepared = False
        self._audio_close()  # D8: AP route (pins) off first ...
        if was_prepared and self.state["cp"] == "online":
            # ... then, after CALL_STATUS released, ask the CP to stop the PCM clock.
            self._fire(defs.SND, defs.SND_CLOCK_CTRL, defs.TYPE_EXEC, messages.snd_clock_ctrl(False))
        self._cp_clock = False

    def _h_clock_ctrl(self, frame, clk):
        if frame.type == defs.TYPE_RESP and frame.aseq:
            return
        self._cp_clock = clk.on
        log.info("CP PCM clock %s (raw %d)", "on" if clk.on else "off", clk.raw)
        if clk.on:
            if self._clock_fallback_timer is not None:
                self._clock_fallback_timer.cancel()
                self._clock_fallback_timer = None
            if self._calls:
                self._audio_open()
        else:
            self._audio_close()

    def _h_wb_amr(self, frame, value):
        wb = value != 0
        if wb != self._wb:
            self._wb = wb
            log.info("voice codec %s", "wide band" if wb else "narrow band")
            if self.state["audio"]["open"]:
                self._audio_open()  # rate change: the hook re-runs pins off -> rate -> pins on

    # ---- data
    def _h_gprs_call_status(self, frame, st):
        self._data_cache.setdefault(st.cid, {})["status"] = st
        log.info("PDP cid=%d status=0x%02x cause=%d", st.cid, st.status, st.fail_cause)
        self._wake_data_waiters()
        if self._data and self._data["cid"] == st.cid and not st.up and self._data.get("connected"):
            self._data_lost("network: cause %d" % st.fail_cause)

    def _h_ip_config(self, frame, cfg):
        self._data_cache.setdefault(cfg.cid, {})["ip"] = cfg
        log.info("PDP cid=%d IP configuration received (flags 0x%04x)", cfg.cid, cfg.flags)
        self._wake_data_waiters()

    def _h_gprs_ps(self, frame, ps):
        log.info("PS %s (cause %d)", "attached" if ps.attached else "detached", ps.cause)

    def _wake_data_waiters(self):
        for w in list(self._data_waiters):
            w()

    def _data_lost(self, reason):
        data = self._data
        self._data = None
        if data is None:
            return
        iface = data["interface"]
        try:
            self.netcfg.down(iface)
        except OSError as exc:
            log.warning("deconfigure %s: %s", iface, exc)
        event = {"connected": False, "cid": data["cid"], "interface": iface, "ipv4": None, "ipv6": None,
                 "reason": reason}
        self.state["data"] = None
        self._touch()
        self._emit("data", event)

    # ------------------------------------------------------------------ crash / recovery
    def _modem_status(self):
        fd = self._ipc_fd
        try:
            if fd is None or not stat.S_ISCHR(os.fstat(fd).st_mode) or os.isatty(fd):
                return None
            return fcntl.ioctl(fd, MODEM_IOCTL_STATUS, 0)
        except OSError:
            return None

    def _on_hup(self, flags):
        """POLLHUP on umts_ipc0: SIM change, or the SYNTHESIS v2 D5 restart contract."""
        status = self._modem_status()
        if status in (7, 8):
            # STATUS consumed the SIM event; SIM presence comes from SEC_PIN_STATUS NOTIs only.
            log.info("SIM %s signalled by the kernel", "attach" if status == 7 else "detach")
            return
        if status == 4:
            return  # spurious; the device is online
        self.ipc_channel.pause()
        if self._restart_phase is None:
            self._begin_restart(status)
        self._schedule_restart_check()

    def _begin_restart(self, status):
        log.warning("CP crash or restart (modem state %s): restart contract", MODEM_STATES.get(status, status))
        # (1) call audio off first (the hook switches the Modem RX/TX pins off)
        if self._clock_fallback_timer is not None:
            self._clock_fallback_timer.cancel()
            self._clock_fallback_timer = None
        self._audio_close()
        self._audio_prepared = False
        self._cp_clock = False
        # (2) end calls and bearers
        for call_id in list(self._calls):
            self._update_call(call_id, "released", reason="modem restart")
        self._data_lost("modem restart")
        self.ipc.fail_all("modem restart")
        for w in list(self._dial_waiters):
            w.set_exception(CommandError("modem restart"))
        self._dial_waiters.clear()
        self._set(None, "cp", "crashed")
        self._set(None, "power", "off")
        self.state["sim"].update({"state": "unknown", "lock": None, "pin_retries": None, "puk_retries": None})
        self.state["reg"].update({"cs": "unknown", "ps": "unknown", "rat": None, "mcc": None, "mnc": None,
                                  "operator": None})
        self.state["signal"].update({"percent": None, "rssi_dbm": None})
        self._signal = messages.Signal()
        self._reg_detail = {}
        self._touch()
        self._emit("crash", {})
        # (3) drain the RX queue, (4) reset mseq
        dropped = self.ipc_channel.drain()
        self.ipc.reset_sequence()
        log.info("restart: %d stale frames drained, mseq reset", dropped)
        self._pin_noti_seen = False
        self._smsc_field = None
        if self.rfs_service is not None:
            self.rfs_service.cp_restarted()
        self._rfs_needs_reseed = False
        self._resync_pending = True
        # (5) wait for the loader's next session, (6) then discard until PWR_PHONE_PWR_UP
        self._crashed_session = read_cp_state(self.cp_state_path)[0] if self.cp_state_path else None
        self._restart_phase = "waiting"

    def _schedule_restart_check(self):
        if self._recovery_timer is None:
            delay = self.config.cp_state_poll if self.cp_state_path else self._recovery_interval
            self._recovery_timer = self.loop.call_later(delay, self._check_restart)

    def _check_restart(self):
        self._recovery_timer = None
        if self._restart_phase is None:
            return
        if self.cp_state_path:
            session, state = read_cp_state(self.cp_state_path)
            if session is None or session == self._crashed_session or state != "online":
                self._schedule_restart_check()
                return
            log.info("loader session %s online: waiting for PWR_PHONE_PWR_UP", session)
            self._session = session
        else:
            # no loader session file: re-arm the fd with a backoff (POLLHUP pauses it again)
            self._recovery_interval = min(self._recovery_interval * 2, self.config.recovery_max_interval)
        self._restart_phase = "discarding"
        self.ipc_channel.resume()

    def _on_rfs_hup(self, flags):
        if self.rfs_channel is not None:
            self.rfs_channel.pause()

    # ------------------------------------------------------------------ public commands
    def radio_on(self, done=None):
        return self._command(self._gen_radio, done, "radio_on", True)

    def radio_off(self, done=None):
        return self._command(self._gen_radio, done, "radio_off", False)

    def _mode_mask(self):
        """NET_MODE_SEL mask: no LTE until an attach APN is known (LTE then leaves the CP in
        limited service, without calls, and 3G works without one)."""
        mask = self.config.mode_sel_mask
        if self._attach_profile is None and self.config.lte_attach and self.config.protover == 2:
            mask &= ~defs.NET_MODE_LTE
        return mask or self.config.mode_sel_mask

    def _send_attach(self):
        """Op sending the LTE attach profile, or None if it is not needed.

        Without it the network rejects the CP's LTE attach (status 4/7, reject 0x0a) and the
        CP stays in limited service, so it has to go before radio on, once per CP session and
        profile; the CP takes it in low-power mode. A failure is logged only: 2G and 3G work
        without it.
        """
        if (not self._attach_profile or self._attach_profile == self._attach_sent
                or not self.config.lte_attach or self.config.protover != 2
                or not self.config.mode_sel_mask & defs.NET_MODE_LTE):
            return None
        profile = self._attach_profile
        op = self._req(defs.GPRS, defs.GPRS_LTE_ATTACH_APN_INFO, defs.TYPE_SET, profile)

        def fin(o):
            if o.exception() is None:
                self._attach_sent = profile
            else:
                log.warning("LTE attach APN rejected (%s), continuing", o.exception())
        op.add_done_callback(fin)
        return op

    def set_attach_apn(self, apn, ip_type="ipv4", user=None, password=None, done=None, auth=None, cid=1):
        """Use this LTE attach profile from now on and send it unless the CP already has it."""
        return self._command(self._gen_set_attach, done, "set_attach_apn", apn, ip_type, user, password,
                             auth, cid)

    def _gen_set_attach(self, apn, ip_type, user, password, auth, cid):
        if ip_type not in messages.PDP_TYPES:
            raise CommandError("ip_type must be ipv4, ipv6 or ipv4v6")
        if auth is None:
            auth = "chap" if (user or password) else "none"
        had_profile = self._attach_profile is not None
        self._attach_profile = messages.gprs_lte_attach_apn_info(cid, apn, messages.PDP_TYPES[ip_type],
                                                                 user, password, auth)
        if self.settings:
            self.settings.save(attach={"apn": apn, "ip_type": ip_type, "user": user, "password": password,
                                       "auth": auth})

        def gen():
            op = self._send_attach()
            if op is not None:
                try:
                    yield op
                except IpcError:
                    pass  # logged by _send_attach
            if not had_profile and self.config.mode_sel_on_radio and self.state["power"] == "on":
                self._fire(defs.NET, defs.NET_MODE_SEL, defs.TYPE_SET,
                           messages.net_mode_sel_set(self._mode_mask()))
            return {}
        return gen()

    def set_modes(self, mask, done=None):
        """The technologies the CP may use (NET_MODE_* bits), from now on and after a restart."""
        return self._command(self._gen_set_modes, done, "set_modes", mask)

    def _gen_set_modes(self, mask):
        if not mask or mask & ~defs.NET_MODE_LTE_WCDMA_GSM:
            raise CommandError("bad technology mask 0x%x" % mask)
        self.config.mode_sel_mask = mask
        self.state["modes"] = mask
        self._touch()
        if self.settings:
            self.settings.save(modes=mask)

        def gen():
            if self.config.mode_sel_on_radio and self.state["power"] == "on":
                yield self._req(defs.NET, defs.NET_MODE_SEL, defs.TYPE_SET, messages.net_mode_sel_set(self._mode_mask()))
            return {}
        return gen()

    def _gen_radio(self, on):
        state = defs.PWR_STATE_NORMAL if on else defs.PWR_STATE_LPM
        if on and self.state["power"] == "on":
            return {"power": "on"}   # the CP answers GEN 0x8005 to a second radio on
        if on:
            op = self._send_attach()
            if op is not None:
                try:
                    yield op
                except IpcError:
                    pass  # logged by _send_attach
        yield self._req(defs.PWR, defs.PWR_PHONE_STATE, defs.TYPE_EXEC, messages.pwr_phone_state(state))
        self._radio_wanted = on
        if self.settings and bool(self.settings.get("radio_off")) == on:
            self.settings.save(radio_off=not on)
        self._set(None, "power", "on" if on else "lpm")
        if on:
            self.refresh()
        return {"power": self.state["power"]}

    def refresh(self, done=None):
        """Re-query SIM, registration, operator and signal (background)."""
        if self.passive or self.ipc_channel is None:
            return self._complete(Op.failed(CommandError("passive mode: command refused")), done)
        ops = []
        if self._pin_noti_seen:  # gate: no PIN_STATUS GET before the first NOTI
            ops.append(self._fire(defs.SEC, defs.SEC_PIN_STATUS, defs.TYPE_GET, messages.sec_pin_status_get()))
        ops.append(self._fire(defs.NET, defs.NET_REGIST, defs.TYPE_GET, messages.net_regist_get(defs.NET_DOMAIN_CS)))
        ops.append(self._fire(defs.NET, defs.NET_REGIST, defs.TYPE_GET, messages.net_regist_get(defs.NET_DOMAIN_PS)))
        ops.append(self._fire(defs.NET, defs.NET_SERVING_NETWORK, defs.TYPE_GET, messages.net_serving_get()))
        ops.append(self._fire(defs.DISP, defs.DISP_ICON_INFO, defs.TYPE_GET, messages.disp_icon_info_get()))
        if self.config.mode_sel_on_radio and self.state["power"] == "on":
            ops.append(self._fire(defs.NET, defs.NET_MODE_SEL, defs.TYPE_SET,
                                  messages.net_mode_sel_set(self._mode_mask())))

        def gen():
            for op in ops:
                try:
                    yield op
                except OpError:
                    pass
            return copy.deepcopy(self.state)
        return self._complete(spawn(gen(), "refresh"), done)

    def pin_status(self, done=None):
        """GET SEC_PIN_STATUS (only after the CP's first PIN_STATUS NOTI) + retries."""
        def gen():
            if not self._pin_noti_seen:
                return copy.deepcopy(self.state["sim"])
            reply = yield self._req(defs.SEC, defs.SEC_PIN_STATUS, defs.TYPE_GET, messages.sec_pin_status_get())
            del reply
            if self.state["sim"]["state"] == "locked":
                try:
                    r = yield self._req(defs.SEC, defs.SEC_LOCK_INFORMATION, defs.TYPE_GET,
                                        messages.sec_lock_info_get())
                    info = messages.dec_lock_info(r.frame.payload)
                    key = "puk_retries" if self.state["sim"]["lock"] == "sim-puk" else "pin_retries"
                    self._set("sim", key, info.retries)
                except (OpError, messages.DecodeError) as exc:
                    log.info("lock info: %s", exc)
            return copy.deepcopy(self.state["sim"])
        return self._command(gen, done, "pin_status")

    def enter_pin(self, pin, done=None):
        """Explicit user action only; the PIN is never logged nor stored."""
        def gen():
            payload = messages.sec_pin_status_set(str(pin))
            yield self._req(defs.SEC, defs.SEC_PIN_STATUS, defs.TYPE_SET, payload)
            log.info("PIN accepted by the CP")
            if self._pin_noti_seen:
                self._fire(defs.SEC, defs.SEC_PIN_STATUS, defs.TYPE_GET, messages.sec_pin_status_get())
            return {}
        return self._command(gen, done, "enter_pin")

    def enter_puk(self, puk, new_pin, done=None):
        def gen():
            payload = messages.sec_pin_status_set(str(new_pin), str(puk))
            yield self._req(defs.SEC, defs.SEC_PIN_STATUS, defs.TYPE_SET, payload)
            return {}
        return self._command(gen, done, "enter_puk")

    def send_sms(self, number, text, done=None, request_status_report=False):
        return self._command(self._gen_send_sms, done, "send_sms", number, text, request_status_report)

    def _gen_send_sms(self, number, text, srr):
        from . import sms_pdu
        number = messages.normalize_number(number)
        tpdus = sms_pdu.encode_submit(number, text, request_status_report=srr)

        def gen():
            smsc = b"\x00"
            if self.config.smsc_mode == "cp":
                if self._smsc_field is None:
                    try:
                        r = yield self._req(defs.SMS, defs.SMS_SVC_CENTER_ADDR, defs.TYPE_GET,
                                            messages.sms_svc_center_addr_get())
                        self._smsc_field = messages.dec_svc_center_addr(r.frame.payload)
                    except (OpError, messages.DecodeError) as exc:
                        log.info("SMSC query failed (%s): using the default SMSC", exc)
                        self._smsc_field = b"\x00"
                smsc = self._smsc_field
            log.info("SMS send: to=%s parts=%d first=0x%02x", mask_number(number), len(tpdus), tpdus[0][0])
            refs = []
            try:
                for i, tpdu in enumerate(tpdus):
                    payload = messages.sms_send_msg(smsc, tpdu, more=i < len(tpdus) - 1,
                                                    domain=self.config.sms_domain)
                    r = yield self._req(defs.SMS, defs.SMS_SEND_MSG, defs.TYPE_EXEC, payload, expect="resp",
                                        timeout=self.config.sms_timeout)
                    res = messages.dec_sms_send_msg(r.frame.payload)
                    if not res.ok:
                        raise CommandError("SMS rejected (ack 0x%04x)" % res.ack)
                    refs.append(res.ref)
            except (OpError, messages.DecodeError) as exc:
                self._emit("sms-sent", {"ref": refs[-1] if refs else None, "ok": False, "error": str(exc)})
                raise
            result = {"ref": refs[-1], "refs": refs, "parts": len(tpdus)}
            self._emit("sms-sent", {"ref": refs[-1], "ok": True, "error": None})
            return result
        return gen()

    def list_sms(self, done=None):
        msgs = [dict(m) for _, m in sorted(self._sms_store.items())]
        return self._complete(Op.completed(msgs, "list_sms"), done)

    def delete_sms(self, index, done=None):
        if self._sms_store.pop(int(index), None) is None:
            return self._complete(Op.failed(CommandError("no SMS with index %s" % index)), done)
        return self._complete(Op.completed({"index": int(index)}), done)

    def dial(self, number, done=None):
        return self._command(self._gen_dial, done, "dial", number)

    def _gen_dial(self, number):
        try:
            payload = messages.call_outgoing(number)
        except messages.EmergencyCallRefused:
            log.warning("dial refused: emergency number or emergency call type")
            raise CommandError("emergency calls are refused by shannond: use a certified phone")

        def gen():
            known = set(self._calls)
            waiter = Op("dial-id")
            self._dial_waiters.append(waiter)
            self._dialing_number = messages.normalize_number(number)
            log.info("dialing %s", mask_number(self._dialing_number))
            try:
                yield self._req(defs.CALL, defs.CALL_OUTGOING, defs.TYPE_EXEC, payload)
            except OpError:
                if waiter in self._dial_waiters:
                    self._dial_waiters.remove(waiter)
                self._dialing_number = None
                raise
            self._audio_prepare()
            try:
                call_id = yield wait_op(self.loop, waiter, self.config.dial_id_timeout)
            except OpTimeout:
                if waiter in self._dial_waiters:
                    self._dial_waiters.remove(waiter)
                try:
                    yield self._req(defs.CALL, defs.CALL_LIST, defs.TYPE_GET, messages.call_list_get())
                finally:
                    self._dialing_number = None
                new = [c for c in self._calls.values() if c["id"] not in known and c["direction"] == "out"]
                if not new:
                    raise CommandError("the CP reported no call id")
                call_id = new[0]["id"]
            self._dialing_number = None
            call = self._calls.get(call_id)
            if call is not None and not call.get("number"):
                call["number"] = messages.normalize_number(number)
                self._calls_changed()
            return {"id": call_id}
        return gen()

    def answer(self, call_id=None, done=None):
        def gen():
            yield self._req(defs.CALL, defs.CALL_ANSWER, defs.TYPE_EXEC, messages.call_answer())
            self._audio_prepare()
            return {"id": call_id}
        return self._command(gen, done, "answer")

    def hangup(self, call_id=None, done=None):
        def gen():
            ids = list(self._calls)
            if call_id is None or len(ids) <= 1 or (ids == [call_id]):
                yield self._req(defs.CALL, defs.CALL_RELEASE, defs.TYPE_EXEC, messages.call_release())
            else:
                if call_id not in self._calls:
                    raise CommandError("no call with id %s" % call_id)
                yield self._req(defs.SS, defs.SS_MANAGE_CALL, defs.TYPE_SET, messages.ss_manage_call(3, call_id))
            return {"id": call_id}
        return self._command(gen, done, "hangup")

    def list_calls(self, done=None):
        return self._complete(Op.completed([dict(c) for c in self.state["calls"]], "list_calls"), done)

    def send_dtmf(self, call_id, digits, done=None):
        def gen():
            for d in str(digits):
                yield self._req(defs.CALL, defs.CALL_CONT_DTMF, defs.TYPE_SET, messages.call_cont_dtmf(True, d))
                yield sleep(self.loop, self.config.dtmf_ms / 1000.0)
                yield self._req(defs.CALL, defs.CALL_CONT_DTMF, defs.TYPE_SET, messages.call_cont_dtmf(False))
                yield sleep(self.loop, 0.05)
            return {"id": call_id, "digits": len(str(digits))}
        for d in str(digits):
            if d not in "0123456789*#ABCD":
                return self._complete(Op.failed(CommandError("bad DTMF digit")), done)
        return self._command(gen, done, "send_dtmf")

    def set_audio_path(self, path, done=None):
        if path not in AUDIO_PATHS:
            return self._complete(Op.failed(CommandError("path must be one of %s" % sorted(AUDIO_PATHS))), done)

        def gen():
            self.config.audio_path = path
            yield self._req(defs.SND, defs.SND_AUDIO_PATH_CTRL, defs.TYPE_SET,
                            messages.snd_audio_path(AUDIO_PATHS[path], 0))
            yield self._req(defs.SND, defs.SND_SPKR_VOLUME_CTRL, defs.TYPE_SET,
                            messages.snd_spkr_volume(AUDIO_VOLUME_TYPE[path], self.config.volume_level))
            return {"path": path}
        return self._command(gen, done, "set_audio_path")

    def set_mic_mute(self, mute, done=None):
        def gen():
            yield self._req(defs.SND, defs.SND_MIC_MUTE_CTRL, defs.TYPE_SET, messages.snd_mic_mute(1 if mute else 0))
            return {"mute": bool(mute)}
        return self._command(gen, done, "set_mic_mute")

    def data_connect(self, apn, ip_type="ipv4", user=None, password=None, done=None, auth=None, cid=1):
        return self._command(self._gen_data_connect, done, "data_connect", apn, ip_type, user, password,
                             auth, cid)

    def _gen_data_connect(self, apn, ip_type, user, password, auth, cid):
        if ip_type not in messages.PDP_TYPES:
            raise CommandError("ip_type must be ipv4, ipv6 or ipv4v6")
        if auth is None:
            auth = "chap" if (user or password) else "none"
        pdp_type = messages.PDP_TYPES[ip_type]
        define = messages.gprs_define_pdp_context(cid, apn, pdp_type)
        activate = messages.gprs_pdp_context_set(1, cid, user, password, auth)
        if self._data is not None and self._data.get("connected"):
            raise CommandError("a data connection is already up (cid %d)" % self._data["cid"])

        def gen():
            self._data_cache.pop(cid, None)
            self._data = {"cid": cid, "connected": False, "interface": netcfg_mod.interface_for_cid(cid)}
            log.info("data connect: cid=%d type=%s auth=%s", cid, ip_type, auth)
            try:
                self._attach_profile = messages.gprs_lte_attach_apn_info(cid, apn, pdp_type, user,
                                                                         password, auth)
                op = self._send_attach()
                if op is not None:
                    try:
                        yield op
                    except IpcError:
                        pass  # logged by _send_attach
                # The first activation of a CP session fails with GEN 0x8005, and an activation
                # alone then keeps failing with 0x8001 until the definition is sent again (seen
                # on the device; the CP's reason is not known). Retry the two together. So does
                # the first connection with no APN known yet: the attach APN brings LTE into the
                # mode mask, and while the CP moves there it refuses the activation (cause 255).
                for attempt in range(1, PDP_BUSY_RETRIES + 1):
                    try:
                        yield self._req(defs.GPRS, defs.GPRS_DEFINE_PDP_CONTEXT, defs.TYPE_SET, define)
                        yield self._req(defs.GPRS, defs.GPRS_PDP_CONTEXT, defs.TYPE_SET, activate)
                        activated = True
                        yield self._wait_data_up(cid)
                        break
                    except (IpcError, PdpRefused) as exc:
                        busy = (exc.cause == PDP_CAUSE_NOT_READY if isinstance(exc, PdpRefused)
                                else exc.code in GEN_PDP_BUSY)
                        if not busy or attempt == PDP_BUSY_RETRIES:
                            raise
                        log.info("PDP activation not ready (%s), retry %d in %.1f s",
                                 exc, attempt, PDP_BUSY_DELAY)
                        self._data_cache.pop(cid, None)
                        yield sleep(self.loop, PDP_BUSY_DELAY)
            except BaseException:
                self._data = None
                if locals().get("activated") and self.state["cp"] == "online":
                    self._fire(defs.GPRS, defs.GPRS_PDP_CONTEXT, defs.TYPE_SET,
                               messages.gprs_pdp_context_set(0, cid), what="PDP deactivation after failure")
                raise
            entry = self._data_cache.get(cid, {})
            event = self._data_event(cid, entry.get("ip"))
            try:
                self.netcfg.up(event["interface"], event)
            except OSError as exc:
                log.warning("interface configuration failed: %s", exc)
                event["error"] = str(exc)
            self._data = dict(event)
            self.state["data"] = {k: v for k, v in event.items()}
            self._touch()
            self._emit("data", event)
            return event
        return gen()

    def _wait_data_up(self, cid):
        op = Op("data-up")

        def check():
            entry = self._data_cache.get(cid, {})
            st = entry.get("status")
            if st is not None and not st.up and st.status not in (0x0A, 0x0B):
                op.set_exception(PdpRefused(st.fail_cause))
            elif st is not None and st.up and entry.get("ip") is not None:
                op.set_result(True)
            if op.done() and check in self._data_waiters:
                self._data_waiters.remove(check)
        self._data_waiters.append(check)
        check()
        out = wait_op(self.loop, op, self.config.data_timeout)

        def cleanup(_o):
            if check in self._data_waiters:
                self._data_waiters.remove(check)
        out.add_done_callback(cleanup)
        return out

    @staticmethod
    def _data_event(cid, ip):
        iface = netcfg_mod.interface_for_cid(cid)
        v4 = v6 = None
        # rmnet uplink slots are 2048 B and longer skbs are truncated: MTU = min(network MTU, 1500)
        mtu = min(ip.mtu, 1500) if ip is not None and ip.mtu else 1500
        if ip is not None and ip.ipv4:
            v4 = {"address": ip.ipv4, "prefix": 32, "gateway": None,
                  "dns": [d for d in (ip.dns1, ip.dns2) if d], "mtu": mtu}
        if ip is not None and ip.ipv6:
            v6 = {"address": ip.ipv6, "prefix": 64, "gateway": None,
                  "dns": [d for d in (ip.dns6_1, ip.dns6_2) if d], "mtu": mtu}
        return {"connected": True, "cid": cid, "interface": iface, "ipv4": v4, "ipv6": v6}

    def data_disconnect(self, done=None):
        def gen():
            data = self._data
            if data is None:
                return {"connected": False}
            cid = data["cid"]
            yield self._req(defs.GPRS, defs.GPRS_PDP_CONTEXT, defs.TYPE_SET, messages.gprs_pdp_context_set(0, cid))
            op = Op("data-down")

            def check():
                st = self._data_cache.get(cid, {}).get("status")
                if st is not None and not st.up:
                    op.set_result(True)
            self._data_cache.setdefault(cid, {}).pop("status", None)
            self._data_waiters.append(check)
            try:
                yield wait_op(self.loop, op, self.config.data_down_timeout)
            except OpTimeout:
                log.info("no CALL_STATUS down after deactivation; tearing down anyway")
            finally:
                if check in self._data_waiters:
                    self._data_waiters.remove(check)
            self._data_lost("user request")
            return {"connected": False, "cid": cid}
        return self._command(gen, done, "data_disconnect")

    def query_identity(self, done=None):
        """IMEI, IMSI, ICCID (from the CP's NOTI), own number and revision; never logged.

        Also reads the service provider name from the SIM, for the networks that send none.
        """
        def gen():
            result = {"imei": None, "imsi": None, "iccid": self._identity.get("iccid"), "own_number": None,
                      "revision": None}
            try:
                r = yield self._req(defs.MISC, defs.MISC_ME_SN, defs.TYPE_GET, messages.misc_me_sn_get())
                result["imei"] = messages.dec_me_sn(r.frame.payload).value or None
            except (OpError, messages.DecodeError) as exc:
                log.info("IMEI query failed: %s", exc)
            try:
                r = yield self._req(defs.MISC, defs.MISC_ME_IMSI, defs.TYPE_GET, messages.misc_me_imsi_get())
                result["imsi"] = messages.dec_me_imsi(r.frame.payload) or None
            except (OpError, messages.DecodeError) as exc:
                log.info("IMSI query failed: %s", exc)
            try:
                r = yield self._req(defs.MISC, defs.MISC_ME_VERSION, defs.TYPE_GET, messages.misc_me_version_get())
                result["revision"] = messages.dec_me_version(r.frame.payload).sw or None
            except (OpError, messages.DecodeError) as exc:
                log.info("version query failed: %s", exc)
            try:
                fcp = yield from self._rsim(defs.RSIM_GET_RESPONSE, defs.EF_MSISDN, p3=0x0F)
                length = messages.fcp_record_length(fcp)
                if length:
                    record = yield from self._rsim(defs.RSIM_READ_RECORD, defs.EF_MSISDN, 1, 4, length)
                    result["own_number"] = messages.dec_msisdn_record(record)
            except (OpError, messages.DecodeError):
                log.info("EF_MSISDN not readable")
            try:
                spn = messages.dec_spn((yield from self._rsim(defs.RSIM_READ_BINARY, defs.EF_SPN, p3=17)))
                if spn and not self.state["reg"]["operator"]:
                    self._set("reg", "operator", spn)
            except (OpError, messages.DecodeError):
                log.info("EF_SPN not readable")
            for key in ("imei", "imsi", "iccid", "own_number", "revision"):
                self.state[key] = result[key]
            self._touch()
            return result
        return self._command(gen, done, "query_identity")

    def _rsim(self, command, file_id, p1=0, p2=0, p3=0):
        """Generator: read a SIM file, returning its data (SW other than 90xx/91xx is an error)."""
        r = yield self._req(defs.SEC, defs.SEC_RSIM_ACCESS, defs.TYPE_GET,
                            messages.sec_rsim_access_get(command, file_id, p1, p2, p3))
        sw1, sw2, data = messages.dec_rsim(r.frame.payload)
        if sw1 not in (0x90, 0x91):
            raise messages.DecodeError("SIM file %04x: SW %02x%02x" % (file_id, sw1, sw2))
        return data

    def scan_networks(self, done=None):
        def gen():
            r = yield self._req(defs.NET, defs.NET_PLMN_LIST, defs.TYPE_GET, messages.net_plmn_list_get(),
                                timeout=180.0)
            entries = messages.dec_plmn_list(r.frame.payload)
            return [{"status": e.status, "plmn": e.plmn, "rat": messages.rat_name(e.act)} for e in entries]
        return self._command(gen, done, "scan_networks")

    def raw(self, main, sub, typ, payload=b"", done=None):
        """Debug: send any frame; result {main, sub, type, payload_hex, gen_code}."""
        def gen():
            expect = "resp" if typ == defs.TYPE_GET else ("gen" if typ in (defs.TYPE_EXEC, defs.TYPE_SET) else "none")
            try:
                r = yield self._req(main, sub, typ, bytes(payload), expect=expect)
            except IpcError as exc:
                return {"ok": False, "gen_code": exc.code, "error": str(exc)}
            out = {"ok": True, "gen_code": r.gen.code if r.gen else None}
            if r.frame is not None:
                out.update({"main": r.frame.main, "sub": r.frame.sub, "type": r.frame.type,
                            "payload_hex": r.frame.payload.hex()})
            return out
        if not all(0 <= v <= 0xFF for v in (main, sub, typ)):
            return self._complete(Op.failed(CommandError("main/sub/type must be bytes")), done)
        return self._command(gen, done, "raw")

    # ------------------------------------------------------------------ introspection
    def stats(self):
        out = {"ipc_rx": self.ipc_channel.rx_count if self.ipc_channel else 0,
               "ipc_tx": self.ipc_channel.tx_count if self.ipc_channel else 0,
               "pending": self.ipc.pending_count, "mandatory": dict(self.mandatory_sent)}
        out["restart_phase"] = self._restart_phase
        out["cp_session"] = self._session
        if self.rfs_server is not None:
            out["rfs"] = dict(self.rfs_server.stats)
            out["rfs_nv_writes"] = [{"cmd": c, "offset": o, "length": n}
                                    for c, o, n in list(self.rfs_server.nv.writes)[-32:]]
        return out
