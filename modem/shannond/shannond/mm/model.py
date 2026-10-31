# SPDX-License-Identifier: GPL-2.0-or-later
"""Bus-independent object layer of the shannon2mm facade.

``Facade`` owns the ModemManager object tree (modem, SIM, bearers, SMS,
calls) as plain Python values, keeps it in sync with the shannond
``ModemCore`` events, and implements every method through
``Facade.call(obj, interface, method, args, cb)``.  A *sink* receives the
side effects (objects added/removed, PropertiesChanged, signals): the
python-dbus glue in ``service.py`` in production, a recorder in the tests.

Asynchronous convention: ``cb(ok, result)``; on success ``result`` is the
method's return value (plain Python, typed by the D-Bus out signature) or
None, on failure an ``MMError``.

Privacy: log lines carry states, counters and lengths, never phone numbers,
SMS text, PINs or SIM/equipment identifiers.
"""

import copy
import glob
import hashlib
import logging
import os
from collections import OrderedDict

from .. import defs
from . import convert as C
from . import enums as E
from . import spec
from .spec import Variant

log = logging.getLogger("shannond.mm")

IDENTITY_KEYS = ("imei", "imsi", "iccid", "own_number", "revision")


class MMError(Exception):
    """A ModemManager D-Bus error: ``name`` is the full error name."""

    def __init__(self, name, message):
        super().__init__(message)
        self.name = name
        self.message = message

    def __repr__(self):
        return "MMError(%r, %r)" % (self.name, self.message)


def as_mm_error(err, default=E.ERR_FAILED):
    if isinstance(err, MMError):
        return err
    text = str(err) if err not in (None, "") else "operation failed"
    return MMError(default, text)


class Options:
    """Facade settings; every attribute can be overridden by keyword."""

    def __init__(self, **kw):
        self.modem_index = 0
        self.version = "1.24.0"
        self.manufacturer = "Samsung"
        self.model = "SS333"
        self.plugin = "shannon"
        self.drivers = ["modem_v1"]
        self.primary_port = "umts_ipc0"
        # NetworkManager only needs a non-empty PrimaryPort (it becomes the
        # NM device name); "ignored" keeps clients from opening the misc node
        # with an AT/QMI parser.  See README-mm.md.
        self.primary_port_type = E.PORT_IGNORED
        self.net_ports = None          # None = rmnet* found in /sys/class/net, else rmnet0
        self.device = None             # None = sysfs path of the misc node when present
        self.identity = "eager"        # 'eager' | 'on-demand' | 'never'
        self.register_timeout = 60.0   # Simple.Connect waits this long for registration
        self.command_timeout = 30.0
        self.connect_timeout = 120.0
        self.sms_timeout = 90.0
        self.terminated_call_ttl = 120.0
        self.sysfs_root = "/sys"
        for key, value in kw.items():
            if not hasattr(self, key):
                raise TypeError("unknown option %r" % key)
            setattr(self, key, value)
        if self.identity not in ("eager", "on-demand", "never"):
            raise ValueError("identity must be eager, on-demand or never")

    def resolved_net_ports(self):
        if self.net_ports is not None:
            return list(self.net_ports)
        found = sorted(os.path.basename(p) for p in glob.glob(os.path.join(self.sysfs_root, "class/net/rmnet*")))
        return found or ["rmnet0"]

    def resolved_device(self):
        if self.device:
            return self.device
        node = os.path.join(self.sysfs_root, "class/misc", self.primary_port)
        if os.path.exists(node):
            return os.path.realpath(node)
        return "/sys/devices/virtual/misc/" + self.primary_port


class NullSink:
    def object_added(self, obj):
        pass

    def object_removed(self, obj):
        pass

    def properties_changed(self, obj, iface, changed):
        pass

    def emit(self, obj, iface, signal, *args):
        pass


class MMObject:
    """One exported object: path plus property values per interface."""

    kind = "object"

    def __init__(self, facade, path, interfaces):
        self.facade = facade
        self.path = path
        self.props = OrderedDict((iface, {}) for iface in interfaces)
        self.exported = False

    @property
    def interfaces(self):
        return list(self.props)

    def get(self, iface, name):
        return self.props[iface][name]

    def update(self, iface, values):
        table = spec.PROPERTIES[iface]
        current = self.props[iface]
        changed = OrderedDict()
        for name, value in values.items():
            if name not in table:
                raise KeyError("%s has no property %s" % (iface, name))
            spec.check_value(table[name], value)
            if name not in current or current[name] != value:
                current[name] = value
                changed[name] = value
        if changed and self.exported:
            self.facade.sink.properties_changed(self, iface, changed)
        return changed

    def emit(self, iface, signal, *args):
        if self.exported:
            self.facade.sink.emit(self, iface, signal, *args)

    def __repr__(self):
        return "<%s %s>" % (type(self).__name__, self.path)


class ModemObject(MMObject):
    kind = "modem"


class SimObject(MMObject):
    kind = "sim"


class BearerObject(MMObject):
    kind = "bearer"

    def __init__(self, facade, path, settings):
        super().__init__(facade, path, [E.IFACE_BEARER])
        self.settings = settings          # normalised request (includes password)
        self.connected = False
        self.connecting = False
        self.disconnecting = False
        self.connect_waiters = []
        self.disconnect_waiters = []
        self.disconnect_after_connect = False
        self.data = None


class SmsObject(MMObject):
    kind = "sms"

    def __init__(self, facade, path):
        super().__init__(facade, path, [E.IFACE_SMS])
        self.index = None                 # CP storage index (received messages)
        self.sending = False


class CallObject(MMObject):
    kind = "call"

    def __init__(self, facade, path):
        super().__init__(facade, path, [E.IFACE_CALL])
        self.core_id = None
        self.starting = False
        self.hangup_waiters = []
        self.delete_timer = None

    @property
    def state(self):
        return self.get(E.IFACE_CALL, "State")


def _snapshot(state):
    try:
        return copy.deepcopy(dict(state or {}))
    except Exception:  # pragma: no cover - exotic state objects
        return dict(state or {})


def _plain(value):
    """Variant-free copy of a client-supplied a{sv} entry (glue already unwrapped)."""
    return value.value if isinstance(value, Variant) else value


class Facade:
    """ModemManager object model bound to one ``ModemCore``."""

    def __init__(self, core, loop, options=None, sink=None, **kw):
        self.core = core
        self.loop = loop
        self.opts = options if options is not None else Options(**kw)
        self.sink = sink or NullSink()
        self.st = {}
        self.busy = None                  # 'enabling' | 'disabling' | 'connecting' | 'disconnecting'
        self._radio_op = None             # {'target': 'on'|'off', 'waiters': [cb]}
        self._settle_timer = None
        self._reg_waiters = []            # [(cb, timer)]
        self._session = 0                 # increments each time the CP comes online
        self._was_online = False
        self._identity_done = set()       # keys already queried
        self._identity_inflight = False
        self._sms_loaded_session = None
        self._sms_loading = False
        self._sim_lock_seen = False
        self._audio = None
        self._counters = {"Bearer": 0, "SMS": 0, "Call": 0}
        self._last_state = None
        self._started = False
        self._unsubscribe = None

        base = E.ROOT_PATH
        self.manager = MMObject(self, base, [E.IFACE_MANAGER])
        self.manager.update(E.IFACE_MANAGER, {"Version": self.opts.version})
        self.modem = ModemObject(self, E.MODEM_PREFIX + str(self.opts.modem_index), spec.MODEM_INTERFACES)
        self.sim = None
        self.bearers = OrderedDict()
        self.messages = OrderedDict()
        self.calls = OrderedDict()
        self._handlers = self._build_handlers()

    # ------------------------------------------------------------------
    # life cycle

    def start(self):
        """Fill the static properties, export the modem, follow the core."""
        if self._started:
            return
        self._started = True
        self._init_static()
        self.st = _snapshot(getattr(self.core, "state", {}) or {})
        self._note_online()
        self._sync_sim()
        self._recompute(emit_signal=False)
        if self.sim is not None:
            self._export(self.sim)       # before the modem that points at it
        self._export(self.modem)
        unsubscribe = self.core.subscribe(self._on_core_event)
        self._unsubscribe = unsubscribe if callable(unsubscribe) else None
        self._after_state()
        log.info("facade started: modem %s, state %s", self.modem.path, self._state_name())

    def stop(self):
        for obj in list(self.calls.values()) + list(self.messages.values()) + list(self.bearers.values()):
            self._unexport(obj)
        if self.sim is not None:
            self._unexport(self.sim)
        self._unexport(self.modem)
        try:
            if self._unsubscribe is not None:
                self._unsubscribe()
            elif hasattr(self.core, "unsubscribe"):
                self.core.unsubscribe(self._on_core_event)
        except Exception:
            log.debug("unsubscribing from the core failed", exc_info=True)
        self._unsubscribe = None

    def all_objects(self):
        objs = [self.modem]
        if self.sim is not None:
            objs.append(self.sim)
        objs.extend(self.bearers.values())
        objs.extend(self.messages.values())
        objs.extend(self.calls.values())
        return objs

    def object_at(self, path):
        for obj in [self.manager] + self.all_objects():
            if obj.path == path:
                return obj
        return None

    def _export(self, obj):
        if not obj.exported:
            obj.exported = True
            self.sink.object_added(obj)

    def _unexport(self, obj):
        if obj.exported:
            obj.exported = False
            self.sink.object_removed(obj)

    def _new_path(self, kind):
        n = self._counters[kind]
        self._counters[kind] = n + 1
        prefix = {"Bearer": E.BEARER_PREFIX, "SMS": E.SMS_PREFIX, "Call": E.CALL_PREFIX}[kind]
        return prefix + str(n)

    # ------------------------------------------------------------------
    # static and derived properties

    def _init_static(self):
        o = self.opts
        ports = [(o.primary_port, int(o.primary_port_type))]
        ports += [(name, E.PORT_NET) for name in o.resolved_net_ports()]
        device = o.resolved_device()
        digest = hashlib.sha1(("shannon2mm:%s:%s:%s" % (o.plugin, o.model, o.primary_port)).encode()).hexdigest()
        caps = E.CAP_GSM_UMTS | E.CAP_LTE
        modes = E.MODE_2G | E.MODE_3G | E.MODE_4G
        supported = [(m, E.MODE_NONE) for m in (modes, E.MODE_2G | E.MODE_3G, E.MODE_3G, E.MODE_2G)]
        self.modem.update(E.IFACE_MODEM, OrderedDict([
            ("SimSlots", []),
            ("PrimarySimSlot", 0),
            ("SupportedCapabilities", [caps]),
            ("CurrentCapabilities", caps),
            ("MaxBearers", 1),
            ("MaxActiveBearers", 1),
            ("MaxActiveMultiplexedBearers", 0),
            ("Manufacturer", o.manufacturer),
            ("Model", o.model),
            ("CarrierConfiguration", ""),
            ("CarrierConfigurationRevision", ""),
            ("HardwareRevision", ""),
            ("DeviceIdentifier", digest),
            ("Device", device),
            ("Physdev", device),
            ("Drivers", list(o.drivers)),
            ("Plugin", o.plugin),
            ("PrimaryPort", o.primary_port),
            ("Ports", ports),
            ("SupportedModes", supported),
            ("CurrentModes", (modes, E.MODE_NONE)),
            ("SupportedBands", [E.BAND_UNKNOWN]),
            ("CurrentBands", [E.BAND_UNKNOWN]),
            ("SupportedIpFamilies", E.IP_FAMILY_IPV4 | E.IP_FAMILY_IPV6 | E.IP_FAMILY_IPV4V6),
            ("Bearers", []),
        ]))
        self.modem.update(E.IFACE_3GPP, OrderedDict([
            ("NetworkRejection", {}),
            ("SubscriptionState", E.SUBSCRIPTION_UNKNOWN),
            ("EpsUeModeOperation", E.EPS_UE_MODE_UNKNOWN),
            ("Pco", []),
            ("InitialEpsBearer", E.NO_PATH),
            ("InitialEpsBearerSettings", {}),
            ("Nr5gRegistrationSettings", {}),
        ]))
        self.modem.update(E.IFACE_MESSAGING, OrderedDict([
            ("Messages", []),
            ("SupportedStorages", []),
            ("DefaultStorage", E.STORAGE_UNKNOWN),
        ]))
        self.modem.update(E.IFACE_VOICE, {"Calls": []})

    def _connected_bearer(self):
        for bearer in self.bearers.values():
            if bearer.connected:
                return bearer
        return None

    def _state_name(self, value=None):
        value = self._last_state if value is None else value
        for name in dir(E):
            if name.startswith("STATE_") and getattr(E, name) == value:
                return name[6:].lower()
        return str(value)

    def _recompute(self, reason=E.CHANGE_UNKNOWN, emit_signal=True):
        st = self.st
        connected = self._connected_bearer() is not None
        state, failed = C.compute_state(st, self.busy, connected)
        powered = st.get("cp") == "online" and st.get("power") == "on"
        reg = C.combined_registration(st.get("reg")) if powered else E.REG_IDLE
        registered = C.is_registered(reg)
        regd = st.get("reg") or {}
        code = C.operator_code(regd) if registered else ""
        name = str(regd.get("operator") or "") if registered else ""
        imei = str(st.get("imei") or "")
        own = st.get("own_number")
        sim_st = C.sim_state(st)
        self.modem.update(E.IFACE_MODEM, OrderedDict([
            ("Sim", self.sim.path if self.sim is not None else E.NO_PATH),
            ("Revision", str(st.get("revision") or "")),
            ("EquipmentIdentifier", imei),
            ("UnlockRequired", C.unlock_required(st)),
            ("UnlockRetries", C.unlock_retries(st)),
            ("StateFailedReason", failed),
            ("CurrentModes", C.current_modes(st)),
            ("AccessTechnologies", C.access_technologies(st, registered)),
            ("SignalQuality", C.signal_quality(st)),
            ("OwnNumbers", [str(own)] if own else []),
            ("PowerState", C.power_state(st)),
        ]))
        if registered:
            ps = E.PS_ATTACHED if C.is_registered(E.REG_FROM_CORE.get(regd.get("ps"))) else E.PS_DETACHED
        else:
            ps = E.PS_DETACHED if powered else E.PS_UNKNOWN
        self.modem.update(E.IFACE_3GPP, OrderedDict([
            ("Imei", imei),
            ("RegistrationState", reg),
            ("OperatorCode", code),
            ("OperatorName", name),
            ("EnabledFacilityLocks", E.FACILITY_SIM if self._sim_lock_seen else E.FACILITY_NONE),
            ("PacketServiceState", ps),
        ]))
        self.modem.update(E.IFACE_VOICE, {"EmergencyOnly": sim_st in ("absent", "locked", "error")})
        if self.sim is not None:
            imsi = str(st.get("imsi") or "")
            self.sim.update(E.IFACE_SIM, OrderedDict([
                ("SimIdentifier", str(st.get("iccid") or "")),
                ("Imsi", imsi),
                ("OperatorIdentifier", C.sim_operator_identifier(imsi, C.operator_code(regd) if registered else "")),
            ]))
        old = self._last_state
        self.modem.update(E.IFACE_MODEM, {"State": state})
        self._last_state = state
        if old is not None and old != state:
            log.info("modem state %s -> %s", self._state_name(old), self._state_name(state))
            if emit_signal:
                self.modem.emit(E.IFACE_MODEM, "StateChanged", old, state, reason)
        if registered and self._reg_waiters:
            self._fire_reg_waiters(True)

    def _sync_sim(self):
        sim_st = C.sim_state(self.st)
        if sim_st == "locked":
            self._sim_lock_seen = True
        if sim_st in ("locked", "ready") and self.sim is None:
            sim = SimObject(self, E.SIM_PREFIX + str(self.opts.modem_index), [E.IFACE_SIM])
            sim.update(E.IFACE_SIM, OrderedDict([
                ("Active", True),
                ("SimIdentifier", ""),
                ("Imsi", ""),
                ("Eid", ""),
                ("OperatorIdentifier", ""),
                ("OperatorName", ""),
                ("EmergencyNumbers", sorted(defs.EMERGENCY_NUMBERS)),
                ("PreferredNetworks", []),
                ("Gid1", []),
                ("Gid2", []),
                ("SimType", 1),          # MM_SIM_TYPE_PHYSICAL
                ("EsimStatus", 0),
                ("Removability", 1),     # MM_SIM_REMOVABILITY_REMOVABLE
            ]))
            self.sim = sim
            if self.modem.exported:
                self._export(sim)
        elif sim_st in ("absent", "error") and self.sim is not None:
            sim, self.sim = self.sim, None
            self._unexport(sim)
            for key in ("imsi", "iccid", "own_number"):
                self.st.pop(key, None)
            self._identity_done = {k for k in self._identity_done if k[1] == "nosim"}
        if self.sim is not None and not self.sim.exported and self.modem.exported:
            self._export(self.sim)

    def _note_online(self):
        online = self.st.get("cp") == "online"
        if online and not self._was_online:
            self._session += 1
        self._was_online = online

    def _after_state(self):
        """Background work that depends on the state: identity, stored SMS."""
        if self.st.get("cp") != "online":
            return
        if self.opts.identity == "eager":
            self.request_identity()
        if (C.sim_state(self.st) == "ready" and not self._sms_loading
                and self._sms_loaded_session != self._session):
            self._load_sms()

    # ------------------------------------------------------------------
    # identity

    def _identity_key(self):
        sim_st = C.sim_state(self.st)
        return (self._session, "ready" if sim_st == "ready" else ("nosim" if sim_st in ("absent", "error") else "sim"))

    def request_identity(self):
        """Ask the core for IMEI/IMSI/ICCID/MSISDN once per CP session and SIM phase."""
        if self.opts.identity == "never" or self._identity_inflight:
            return
        if self.st.get("cp") != "online" or C.sim_state(self.st) == "unknown":
            return
        key = self._identity_key()
        if key in self._identity_done:
            return
        self._identity_done.add(key)
        self._identity_inflight = True
        log.debug("querying identity")

        def done(ok, result):
            self._identity_inflight = False
            if not ok:
                log.warning("identity query failed: %s", as_mm_error(result).message)
                return
            fresh = {}
            try:
                fresh.update({k: v for k, v in (getattr(self.core, "state", {}) or {}).items() if k in IDENTITY_KEYS})
            except Exception:
                pass
            if isinstance(result, dict):
                fresh.update({k: v for k, v in result.items() if k in IDENTITY_KEYS and v})
            for k, v in fresh.items():
                if v:
                    self.st[k] = v
            log.info("identity received (%s)", ", ".join(sorted(k for k in fresh if fresh[k])) or "empty")
            self._recompute()

        self._core_call("query_identity", (), done, self.opts.command_timeout)

    def note_read(self, obj, iface):
        """Called by the glue when a client reads properties ('on-demand' identity)."""
        if self.opts.identity != "on-demand":
            return
        if iface in (E.IFACE_MODEM, E.IFACE_3GPP, E.IFACE_SIM, None):
            self.request_identity()

    # ------------------------------------------------------------------
    # core plumbing

    def _core_call(self, name, args, cb, timeout, **kwargs):
        """Call ``core.<name>(*args, done=done)`` with a timeout; cb(ok, result) runs once."""
        state = {"done": False, "timer": None}

        def finish(ok, result):
            if state["done"]:
                return
            state["done"] = True
            if state["timer"] is not None:
                state["timer"].cancel()
            try:
                cb(ok, result)
            except Exception:
                log.exception("completion of %s failed", name)

        def done(ok=True, result=None):
            finish(bool(ok), result)

        def expired():
            finish(False, MMError(E.ERR_TIMEOUT, "%s timed out" % name))

        fn = getattr(self.core, name, None)
        if fn is None:
            finish(False, MMError(E.ERR_UNSUPPORTED, "core has no %s" % name))
            return
        if timeout:
            state["timer"] = self.loop.call_later(timeout, expired)
        try:
            fn(*args, done=done, **kwargs)
        except Exception as exc:
            log.warning("core.%s raised %s", name, type(exc).__name__)
            finish(False, MMError(E.ERR_FAILED, "%s: %s" % (name, exc)))

    def _on_core_event(self, event, data):
        try:
            handler = {
                "state": self._ev_state,
                "crash": self._ev_crash,
                "sms-received": self._ev_sms_received,
                "sms-sent": self._ev_sms_sent,
                "call": self._ev_call,
                "data": self._ev_data,
                "audio": self._ev_audio,
                "sms-status-report": self._ev_sms_status_report,
            }.get(event)
            if handler is None:
                log.debug("ignoring core event %s", event)
                return
            handler(data or {})
        except Exception:
            log.exception("handling core event %s failed", event)

    def _ev_state(self, data):
        new = _snapshot(data)
        for key in IDENTITY_KEYS:
            if key not in new and key in self.st:
                new[key] = self.st[key]
        was_online = self.st.get("cp") == "online"
        self.st = new
        self._note_online()
        if was_online and new.get("cp") != "online":
            self._link_lost(new.get("cp") == "crashed")
        reason = E.CHANGE_FAILURE if new.get("cp") == "crashed" else E.CHANGE_UNKNOWN
        if new.get("power") != "on":
            self._radio_lost()
        self._settled_by_state()
        self._sync_sim()
        self._recompute(reason=reason)
        self._after_state()

    def _ev_crash(self, data):
        log.warning("core reports a CP crash")
        self.st["cp"] = "crashed"
        self._was_online = False
        self._link_lost(True)
        self._recompute(reason=E.CHANGE_FAILURE)

    def _link_lost(self, crashed):
        """CP gone: calls end, bearers drop, waiters for registration fail."""
        for call in list(self.calls.values()):
            if call.state != E.CALL_TERMINATED:
                self._set_call_state(call, E.CALL_TERMINATED, E.REASON_ERROR if crashed else E.REASON_TERMINATED)
        self._radio_lost()
        self._fire_reg_waiters(False, MMError(E.ERR_ME_NO_NETWORK, "modem went offline"))

    def _radio_lost(self):
        for bearer in self.bearers.values():
            if bearer.connected and not bearer.disconnecting:
                self._mark_disconnected(bearer)

    # ------------------------------------------------------------------
    # method dispatch

    def call(self, obj, iface, method, args, cb):
        """Run a D-Bus method on ``obj``; cb(ok, result) is called exactly once."""
        once = {"done": False}

        def reply(ok, result=None):
            if once["done"]:
                return
            once["done"] = True
            if not ok:
                result = as_mm_error(result)
            cb(ok, result)

        handler = self._handlers.get((iface, method))
        if handler is None:
            reply(False, MMError(E.ERR_UNSUPPORTED, "%s.%s is not supported by shannon2mm" % (iface, method)))
            return
        try:
            handler(obj, *args, reply)
        except MMError as err:
            reply(False, err)
        except Exception as exc:
            log.exception("%s.%s failed", iface, method)
            reply(False, MMError(E.ERR_FAILED, str(exc)))

    def _build_handlers(self):
        M, S, G, MSG, V = E.IFACE_MODEM, E.IFACE_SIMPLE, E.IFACE_3GPP, E.IFACE_MESSAGING, E.IFACE_VOICE
        unsupported = self._unsupported
        return {
            (E.IFACE_MANAGER, "ScanDevices"): lambda o, cb: cb(True, None),
            (E.IFACE_MANAGER, "SetLogging"): self._set_logging,
            (E.IFACE_MANAGER, "ReportKernelEvent"): lambda o, props, cb: cb(True, None),
            (E.IFACE_MANAGER, "InhibitDevice"): lambda o, uid, inhibit, cb: cb(True, None),
            (M, "Enable"): self._modem_enable,
            (M, "ListBearers"): lambda o, cb: cb(True, list(self.bearers)),
            (M, "CreateBearer"): self._modem_create_bearer,
            (M, "DeleteBearer"): self._modem_delete_bearer,
            (M, "Reset"): unsupported,
            (M, "FactoryReset"): unsupported,
            (M, "SetPowerState"): self._modem_set_power_state,
            (M, "SetCurrentCapabilities"): self._modem_set_caps,
            (M, "SetCurrentModes"): self._modem_set_modes,
            (M, "SetCurrentBands"): self._modem_set_bands,
            (M, "SetPrimarySimSlot"): unsupported,
            (M, "GetCellInfo"): unsupported,
            (M, "Command"): self._modem_command,
            (S, "Connect"): self._simple_connect,
            (S, "Disconnect"): self._simple_disconnect,
            (S, "GetStatus"): self._simple_get_status,
            (G, "Register"): self._3gpp_register,
            (G, "Scan"): unsupported,
            (G, "SetEpsUeModeOperation"): unsupported,
            (G, "SetInitialEpsBearerSettings"): unsupported,
            (G, "SetNr5gRegistrationSettings"): unsupported,
            (G, "DisableFacilityLock"): unsupported,
            (G, "SetCarrierLock"): unsupported,
            (G, "SetPacketServiceState"): unsupported,
            (MSG, "List"): lambda o, cb: cb(True, list(self.messages)),
            (MSG, "SetDefaultStorage"): unsupported,
            (MSG, "Delete"): self._messaging_delete,
            (MSG, "Create"): self._messaging_create,
            (V, "ListCalls"): lambda o, cb: cb(True, list(self.calls)),
            (V, "DeleteCall"): self._voice_delete_call,
            (V, "CreateCall"): self._voice_create_call,
            (V, "HoldAndAccept"): unsupported,
            (V, "HangupAndAccept"): self._voice_hangup_and_accept,
            (V, "HangupAll"): self._voice_hangup_all,
            (V, "Transfer"): unsupported,
            (V, "CallWaitingSetup"): unsupported,
            (V, "CallWaitingQuery"): unsupported,
            (E.IFACE_SIM, "SendPin"): self._sim_send_pin,
            (E.IFACE_SIM, "SendPuk"): unsupported,
            (E.IFACE_SIM, "EnablePin"): unsupported,
            (E.IFACE_SIM, "ChangePin"): unsupported,
            (E.IFACE_SIM, "SetPreferredNetworks"): unsupported,
            (E.IFACE_BEARER, "Connect"): self._bearer_connect,
            (E.IFACE_BEARER, "Disconnect"): self._bearer_disconnect,
            (E.IFACE_SMS, "Send"): self._sms_send,
            (E.IFACE_SMS, "Store"): unsupported,
            (E.IFACE_CALL, "Start"): self._call_start,
            (E.IFACE_CALL, "Accept"): self._call_accept,
            (E.IFACE_CALL, "Deflect"): unsupported,
            (E.IFACE_CALL, "JoinMultiparty"): unsupported,
            (E.IFACE_CALL, "LeaveMultiparty"): unsupported,
            (E.IFACE_CALL, "Hangup"): self._call_hangup,
            (E.IFACE_CALL, "SendDtmf"): self._call_send_dtmf,
        }

    @staticmethod
    def _unsupported(obj, *args):
        cb = args[-1]
        cb(False, MMError(E.ERR_UNSUPPORTED, "not supported by the Shannon IPC facade"))

    # ------------------------------------------------------------------
    # Manager

    def _set_logging(self, obj, level, cb):
        value = E.LOG_LEVELS.get(str(level).upper())
        if value is None:
            cb(False, MMError(E.ERR_INVALID_ARGS, "unknown log level"))
            return
        log.setLevel(value)
        cb(True, None)

    # ------------------------------------------------------------------
    # Modem

    def _require_initialized(self):
        state = self._last_state
        if state == E.STATE_FAILED:
            reason = self.modem.get(E.IFACE_MODEM, "StateFailedReason")
            if reason == E.FAILED_SIM_MISSING:
                raise MMError(E.ERR_ME_SIM_NOT_INSERTED, "SIM missing")
            raise MMError(E.ERR_WRONG_STATE, "modem failed")
        if state in (E.STATE_UNKNOWN, E.STATE_INITIALIZING):
            raise MMError(E.ERR_WRONG_STATE, "modem not fully initialized yet")
        if state == E.STATE_LOCKED:
            raise MMError(E.ERR_WRONG_STATE, "modem locked")

    def _modem_enable(self, obj, enable, cb):
        self._require_initialized()
        self._radio(bool(enable), cb)

    def _radio(self, on, cb):
        target = "on" if on else "off"
        op = self._radio_op
        if op is not None:
            if op["target"] == target:
                op["waiters"].append(cb)
                return
            cb(False, MMError(E.ERR_IN_PROGRESS, "radio %s in progress" % op["target"]))
            return
        if on and self.st.get("power") == "on":
            cb(True, None)
            return
        if not on and self.st.get("power") != "on":
            cb(True, None)
            return
        self._radio_op = op = {"target": target, "waiters": [cb]}
        self.busy = "enabling" if on else "disabling"
        self._recompute(reason=E.CHANGE_USER_REQUESTED)

        def done(ok, result):
            self._radio_op = None
            self.busy = None
            if ok:
                if not on:
                    self._radio_lost()
                # The command succeeded; until the core's 'state' event confirms
                # the new power state, keep showing the transition.
                if on and self.st.get("power") != "on":
                    self._settle("enabling")
                elif not on and self.st.get("power") == "on":
                    self._settle("disabling")
            self._recompute(reason=E.CHANGE_USER_REQUESTED)
            for waiter in op["waiters"]:
                waiter(ok, None if ok else as_mm_error(result))

        self._core_call("radio_on" if on else "radio_off", (), done, self.opts.command_timeout)

    def _settle(self, kind):
        self.busy = kind
        if self._settle_timer is not None:
            self._settle_timer.cancel()

        def expired():
            self._settle_timer = None
            if self.busy == kind and self._radio_op is None:
                self.busy = None
                self._recompute()

        self._settle_timer = self.loop.call_later(self.opts.command_timeout, expired)

    def _settled_by_state(self):
        """A 'state' event confirmed (or contradicted) the pending power transition."""
        if self._radio_op is not None or self.busy not in ("enabling", "disabling"):
            return
        power_on = self.st.get("power") == "on"
        if (self.busy == "enabling" and power_on) or (self.busy == "disabling" and not power_on):
            self.busy = None
            if self._settle_timer is not None:
                self._settle_timer.cancel()
                self._settle_timer = None

    def _modem_set_power_state(self, obj, state, cb):
        self._require_initialized()
        if state == E.POWER_OFF:
            cb(False, MMError(E.ERR_UNSUPPORTED, "power off is handled by shannond"))
        elif state == E.POWER_LOW:
            if self._last_state is not None and self._last_state > E.STATE_DISABLED:
                cb(False, MMError(E.ERR_WRONG_STATE, "modem must be disabled first"))
            elif self.st.get("power") == "lpm":
                cb(True, None)
            else:
                self._core_call("radio_off", (), lambda ok, res: cb(ok, None if ok else res), self.opts.command_timeout)
        elif state == E.POWER_ON:
            if self.st.get("power") == "on" or self._last_state == E.STATE_DISABLED:
                cb(True, None)   # the radio itself goes up with Enable(true)
            else:
                cb(False, MMError(E.ERR_WRONG_STATE, "modem must be disabled first"))
        else:
            cb(False, MMError(E.ERR_INVALID_ARGS, "unknown power state"))

    def _modem_set_caps(self, obj, caps, cb):
        if caps == self.modem.get(E.IFACE_MODEM, "CurrentCapabilities"):
            cb(True, None)
        else:
            cb(False, MMError(E.ERR_UNSUPPORTED, "capabilities cannot be changed"))

    def _modem_set_modes(self, obj, modes, cb):
        if tuple(modes) not in [tuple(m) for m in self.modem.get(E.IFACE_MODEM, "SupportedModes")]:
            cb(False, MMError(E.ERR_UNSUPPORTED, "this combination of modes is not supported"))
            return
        self._core_call("set_modes", (C.core_modes(modes[0]),), lambda ok, res: cb(ok, None if ok else res),
                        self.opts.command_timeout)

    def _modem_set_bands(self, obj, bands, cb):
        if list(bands) in ([E.BAND_ANY], list(self.modem.get(E.IFACE_MODEM, "CurrentBands"))):
            cb(True, None)
        else:
            cb(False, MMError(E.ERR_UNSUPPORTED, "band selection is not implemented"))

    @staticmethod
    def _modem_command(obj, cmd, timeout, cb):
        cb(False, MMError(E.ERR_UNAUTHORIZED, "the Shannon modem has no AT command port"))

    def _3gpp_register(self, obj, operator_id, cb):
        if operator_id:
            cb(False, MMError(E.ERR_UNSUPPORTED, "manual network selection is not implemented"))
        else:
            cb(True, None)

    # ------------------------------------------------------------------
    # Bearers

    @staticmethod
    def _bearer_settings(props):
        props = {str(k): _plain(v) for k, v in (props or {}).items()}
        out = {}

        def take(key, kind):
            if key in props:
                value = props[key]
                if kind is bool:
                    if not isinstance(value, bool):
                        raise MMError(E.ERR_INVALID_ARGS, "%s must be a boolean" % key)
                elif kind is int:
                    if isinstance(value, bool) or not isinstance(value, int):
                        raise MMError(E.ERR_INVALID_ARGS, "%s must be an integer" % key)
                elif not isinstance(value, str):
                    raise MMError(E.ERR_INVALID_ARGS, "%s must be a string" % key)
                out[key] = value

        take("apn", str)
        take("ip-type", int)
        take("allowed-auth", int)
        take("user", str)
        take("password", str)
        take("allow-roaming", bool)
        take("profile-id", int)
        take("multiplex", int)
        if out.get("multiplex") == 3:  # MM_BEARER_MULTIPLEX_SUPPORT_REQUIRED
            raise MMError(E.ERR_UNSUPPORTED, "multiplexed bearers are not supported")
        if out.get("profile-id", -1) not in (-1,):
            raise MMError(E.ERR_UNSUPPORTED, "3GPP profiles are not supported")
        ip_type = out.get("ip-type", E.IP_FAMILY_NONE)
        if ip_type not in (E.IP_FAMILY_NONE, E.IP_FAMILY_IPV4, E.IP_FAMILY_IPV6, E.IP_FAMILY_IPV4V6, E.IP_FAMILY_ANY):
            raise MMError(E.ERR_UNSUPPORTED, "unsupported ip-type")
        return out

    @staticmethod
    def _bearer_exported_properties(settings):
        out = OrderedDict()
        out["apn"] = Variant("s", settings.get("apn", ""))
        if "ip-type" in settings:
            out["ip-type"] = Variant("u", settings["ip-type"])
        if "allowed-auth" in settings:
            out["allowed-auth"] = Variant("u", settings["allowed-auth"])
        if settings.get("user"):
            out["user"] = Variant("s", settings["user"])
        if "allow-roaming" in settings:
            out["allow-roaming"] = Variant("b", settings["allow-roaming"])
        return out   # the password is deliberately not published

    def _create_bearer(self, settings):
        if len(self.bearers) >= self.modem.get(E.IFACE_MODEM, "MaxBearers"):
            for path, bearer in list(self.bearers.items()):
                if not (bearer.connected or bearer.connecting or bearer.disconnecting):
                    self._remove_bearer(bearer)
                    break
            else:
                raise MMError(E.ERR_TOO_MANY, "cannot create more bearers")
        bearer = BearerObject(self, self._new_path("Bearer"), settings)
        bearer.update(E.IFACE_BEARER, OrderedDict([
            ("Interface", ""),
            ("Connected", False),
            ("ConnectionError", ("", "")),
            ("Suspended", False),
            ("Multiplexed", False),
            ("Ip4Config", C.ip_config_unknown()),
            ("Ip6Config", C.ip_config_unknown()),
            ("Stats", {}),
            ("ReloadStatsSupported", False),
            ("IpTimeout", 20),
            ("BearerType", E.BEARER_TYPE_DEFAULT),
            ("ProfileId", -1),
            ("Properties", self._bearer_exported_properties(settings)),
        ]))
        self.bearers[bearer.path] = bearer
        self._export(bearer)
        self.modem.update(E.IFACE_MODEM, {"Bearers": list(self.bearers)})
        log.info("bearer %s created", bearer.path.rsplit("/", 1)[-1])
        return bearer

    def _remove_bearer(self, bearer):
        if self.bearers.pop(bearer.path, None) is None:
            return
        self._unexport(bearer)
        self.modem.update(E.IFACE_MODEM, {"Bearers": list(self.bearers)})

    def _modem_create_bearer(self, obj, props, cb):
        bearer = self._create_bearer(self._bearer_settings(props))
        cb(True, bearer.path)

    def _modem_delete_bearer(self, obj, path, cb):
        bearer = self.bearers.get(path)
        if bearer is None:
            cb(False, MMError(E.ERR_NOT_FOUND, "no such bearer"))
            return
        if bearer.connected or bearer.connecting:
            def after(ok, result):
                self._remove_bearer(bearer)
                cb(True, None)
            self._bearer_disconnect(bearer, after)
        else:
            self._remove_bearer(bearer)
            cb(True, None)

    def _bearer_connect(self, bearer, cb):
        if bearer.connected:
            cb(True, None)
            return
        if bearer.connecting:
            bearer.connect_waiters.append(cb)
            return
        for other in self.bearers.values():
            if other is not bearer and (other.connected or other.connecting):
                cb(False, MMError(E.ERR_TOO_MANY, "only one active bearer is supported"))
                return
        try:
            self._require_initialized()
        except MMError as err:
            cb(False, err)
            return
        if self.st.get("power") != "on":
            cb(False, MMError(E.ERR_WRONG_STATE, "modem not enabled"))
            return
        reg = C.combined_registration(self.st.get("reg"))
        if not C.is_registered(reg):
            cb(False, MMError(E.ERR_WRONG_STATE, "not registered in the network"))
            return
        if reg == E.REG_ROAMING and bearer.settings.get("allow-roaming") is False:
            cb(False, MMError(E.ERR_UNAUTHORIZED, "roaming not allowed"))
            return
        s = bearer.settings
        bearer.connecting = True
        bearer.connect_waiters.append(cb)
        bearer.update(E.IFACE_BEARER, {"ConnectionError": ("", "")})
        self.busy = "connecting"
        self._recompute(reason=E.CHANGE_USER_REQUESTED)
        log.info("bearer %s connecting (ip type %s)", bearer.path.rsplit("/", 1)[-1],
                 C.core_ip_type(s.get("ip-type", E.IP_FAMILY_NONE)))

        def done(ok, result):
            bearer.connecting = False
            if self.busy == "connecting":
                self.busy = None
            error = None
            if ok:
                if isinstance(result, dict) and result.get("connected") is not False:
                    self._apply_data(bearer, result)
                elif isinstance(result, dict):
                    ok, error = False, MMError(E.ERR_CONN_NO_CARRIER, "data call not established")
                else:
                    self._apply_data(bearer, {"connected": True})
            else:
                error = as_mm_error(result)
            if not ok:
                bearer.update(E.IFACE_BEARER, {"ConnectionError": (error.name, error.message)})
                log.warning("bearer %s connect failed: %s", bearer.path.rsplit("/", 1)[-1], error.message)
            self._recompute(reason=E.CHANGE_USER_REQUESTED)
            waiters, bearer.connect_waiters = bearer.connect_waiters, []
            for waiter in waiters:
                waiter(ok, None if ok else error)
            if bearer.disconnect_after_connect:
                bearer.disconnect_after_connect = False
                self._do_disconnect(bearer)

        extra = {}
        auth = C.core_auth(s.get("allowed-auth"))
        if auth is not None:
            extra["auth"] = auth
        self._core_call("data_connect", (s.get("apn", ""), C.core_ip_type(s.get("ip-type", E.IP_FAMILY_NONE)),
                                         s.get("user") or None, s.get("password") or None),
                        done, self.opts.connect_timeout, **extra)

    def _bearer_disconnect(self, bearer, cb):
        if bearer.connecting:
            bearer.disconnect_after_connect = True
            bearer.disconnect_waiters.append(cb)
            return
        if not bearer.connected:
            cb(True, None)
            return
        bearer.disconnect_waiters.append(cb)
        if not bearer.disconnecting:
            self._do_disconnect(bearer)

    def _do_disconnect(self, bearer):
        if not bearer.connected:
            waiters, bearer.disconnect_waiters = bearer.disconnect_waiters, []
            for waiter in waiters:
                waiter(True, None)
            return
        bearer.disconnecting = True
        self.busy = "disconnecting"
        self._recompute(reason=E.CHANGE_USER_REQUESTED)

        def done(ok, result):
            bearer.disconnecting = False
            if self.busy == "disconnecting":
                self.busy = None
            if ok:
                self._mark_disconnected(bearer)
            self._recompute(reason=E.CHANGE_USER_REQUESTED)
            waiters, bearer.disconnect_waiters = bearer.disconnect_waiters, []
            for waiter in waiters:
                waiter(ok, None if ok else as_mm_error(result))

        self._core_call("data_disconnect", (), done, self.opts.command_timeout)

    def _apply_data(self, bearer, data):
        bearer.data = dict(data)
        bearer.connected = True
        bearer.update(E.IFACE_BEARER, OrderedDict([
            ("Interface", C.data_interface(data) or bearer.get(E.IFACE_BEARER, "Interface")),
            ("Ip4Config", C.ip4_config(data.get("ipv4"))),
            ("Ip6Config", C.ip6_config(data.get("ipv6"))),
            ("Connected", True),
        ]))

    def _mark_disconnected(self, bearer):
        was = bearer.connected
        bearer.connected = False
        bearer.data = None
        bearer.update(E.IFACE_BEARER, OrderedDict([
            ("Connected", False),
            ("Ip4Config", C.ip_config_unknown()),
            ("Ip6Config", C.ip_config_unknown()),
            ("Interface", ""),
        ]))
        if was:
            log.info("bearer %s disconnected", bearer.path.rsplit("/", 1)[-1])

    def _ev_data(self, data):
        bearer = self._connected_bearer()
        if data.get("connected"):
            if bearer is None:
                candidates = [b for b in self.bearers.values() if b.connecting] or list(self.bearers.values())
                if not candidates:
                    log.warning("data call up without a bearer; ignoring")
                    return
                bearer = candidates[-1]
                if bearer.connecting:
                    return  # the data_connect completion will apply it
            self._apply_data(bearer, data)
        elif bearer is not None and not bearer.disconnecting:
            self._mark_disconnected(bearer)
        self._recompute()

    # ------------------------------------------------------------------
    # Simple

    def _simple_connect(self, obj, props, cb):
        props = {str(k): _plain(v) for k, v in (props or {}).items()}
        settings = self._bearer_settings(props)
        pin = props.get("pin")
        operator_id = props.get("operator-id")
        if operator_id:
            raise MMError(E.ERR_UNSUPPORTED, "manual network selection is not implemented")

        def step_unlock():
            if C.sim_state(self.st) == "locked":
                if not pin:
                    cb(False, MMError(E.ERR_ME_SIM_PIN, "SIM PIN required"))
                    return
                # The PIN came with this explicit connect request.
                self._sim_send_pin(self.sim, str(pin), lambda ok, res: step_enable() if ok else cb(False, res))
                return
            step_enable()

        def step_enable():
            try:
                self._require_initialized()
            except MMError as err:
                cb(False, err)
                return
            step_attach()

        def step_attach():
            # Before the radio and the registration wait: on some networks LTE only registers
            # once the CP has this APN, so waiting first would never end. A refused APN is not
            # fatal (2G and 3G do not need it).
            def go(ok, res):
                if not ok:
                    log.warning("attach APN not accepted: %s", res)
                self._radio(True, lambda ok2, res2: step_register() if ok2 else cb(False, res2))
            apn = settings.get("apn", "")
            if not apn:
                go(True, None)
                return
            extra = {}
            auth = C.core_auth(settings.get("allowed-auth"))
            if auth is not None:
                extra["auth"] = auth
            self._core_call("set_attach_apn", (apn, C.core_ip_type(settings.get("ip-type", E.IP_FAMILY_NONE)),
                                               settings.get("user") or None, settings.get("password") or None),
                            go, self.opts.command_timeout, **extra)

        def step_register():
            self._wait_registered(lambda ok, res: step_bearer() if ok else cb(False, res))

        def step_bearer():
            bearer = None
            for candidate in self.bearers.values():
                if self._same_settings(candidate.settings, settings):
                    bearer = candidate
                    break
            try:
                if bearer is None:
                    bearer = self._create_bearer(settings)
            except MMError as err:
                cb(False, err)
                return
            self._bearer_connect(bearer, lambda ok, res: cb(ok, bearer.path if ok else res))

        step_unlock()

    @staticmethod
    def _same_settings(a, b):
        keys = ("apn", "ip-type", "user", "password", "allowed-auth")
        return all(a.get(k) == b.get(k) for k in keys)

    def _wait_registered(self, cb):
        if C.is_registered(C.combined_registration(self.st.get("reg"))) and self.st.get("power") == "on":
            cb(True, None)
            return
        waiter = {"cb": cb, "timer": None}

        def expired():
            if waiter in self._reg_waiters:
                self._reg_waiters.remove(waiter)
                cb(False, MMError(E.ERR_ME_NO_NETWORK, "network registration timed out"))

        waiter["timer"] = self.loop.call_later(self.opts.register_timeout, expired)
        self._reg_waiters.append(waiter)

    def _fire_reg_waiters(self, ok, error=None):
        waiters, self._reg_waiters = self._reg_waiters, []
        for waiter in waiters:
            if waiter["timer"] is not None:
                waiter["timer"].cancel()
            waiter["cb"](ok, error)

    def _simple_disconnect(self, obj, path, cb):
        if path in ("", E.NO_PATH):
            targets = list(self.bearers.values())
        else:
            bearer = self.bearers.get(path)
            if bearer is None:
                cb(False, MMError(E.ERR_NOT_FOUND, "no such bearer"))
                return
            targets = [bearer]
        if not targets:
            cb(True, None)
            return
        pending = {"n": len(targets), "error": None}

        def one_done(bearer):
            def done(ok, result):
                if ok:
                    self._remove_bearer(bearer)   # as ModemManager's Simple.Disconnect
                elif pending["error"] is None:
                    pending["error"] = result
                pending["n"] -= 1
                if pending["n"] == 0:
                    cb(pending["error"] is None, pending["error"])
            return done

        for bearer in targets:
            self._bearer_disconnect(bearer, one_done(bearer))

    def _simple_get_status(self, obj, cb):
        state = self._last_state if self._last_state is not None else E.STATE_UNKNOWN
        out = OrderedDict([("state", Variant("u", state & 0xFFFFFFFF))])
        if state >= E.STATE_ENABLED:
            m = self.modem.props[E.IFACE_MODEM]
            g = self.modem.props[E.IFACE_3GPP]
            out["signal-quality"] = Variant("(ub)", m["SignalQuality"])
            out["current-bands"] = Variant("au", list(m["CurrentBands"]))
            out["access-technologies"] = Variant("u", m["AccessTechnologies"])
            out["m3gpp-registration-state"] = Variant("u", g["RegistrationState"])
            out["m3gpp-operator-code"] = Variant("s", g["OperatorCode"])
            out["m3gpp-operator-name"] = Variant("s", g["OperatorName"])
        cb(True, out)

    # ------------------------------------------------------------------
    # SIM

    def _sim_send_pin(self, obj, pin, cb):
        if C.sim_state(self.st) != "locked":
            cb(False, MMError(E.ERR_WRONG_STATE, "SIM is not waiting for a PIN"))
            return
        if not C.valid_pin(pin):
            cb(False, MMError(E.ERR_INVALID_ARGS, "a PIN has 4 to 8 digits"))
            return
        log.info("sending SIM PIN at the user's request")

        def done(ok, result):
            if ok:
                cb(True, None)
                return
            err = as_mm_error(result)
            text = err.message.lower()
            if err.name == E.ERR_FAILED and ("incorrect" in text or "wrong" in text or "password" in text):
                err = MMError(E.ERR_ME_INCORRECT_PASSWORD, err.message)
            elif err.name == E.ERR_FAILED and "puk" in text:
                err = MMError(E.ERR_ME_SIM_PUK, err.message)
            log.warning("SIM PIN rejected")
            cb(False, err)

        self._core_call("enter_pin", (pin,), done, self.opts.command_timeout)

    # ------------------------------------------------------------------
    # Messaging

    def _new_sms(self, values):
        sms = SmsObject(self, self._new_path("SMS"))
        base = OrderedDict([
            ("State", E.SMS_UNKNOWN),
            ("PduType", E.PDU_UNKNOWN),
            ("Number", ""),
            ("Text", ""),
            ("Data", []),
            ("SMSC", ""),
            ("Validity", (E.VALIDITY_UNKNOWN, Variant("b", False))),
            ("Class", -1),
            ("TeleserviceId", 0),
            ("ServiceCategory", 0),
            ("DeliveryReportRequest", False),
            ("MessageReference", 0),
            ("Timestamp", ""),
            ("DischargeTimestamp", ""),
            ("DeliveryState", E.DELIVERY_UNKNOWN),
            ("Storage", E.STORAGE_UNKNOWN),
        ])
        base.update(values)
        sms.update(E.IFACE_SMS, base)
        return sms

    def _add_sms(self, sms, received):
        self.messages[sms.path] = sms
        self._export(sms)
        self.modem.update(E.IFACE_MESSAGING, {"Messages": list(self.messages)})
        self.modem.emit(E.IFACE_MESSAGING, "Added", sms.path, bool(received))

    def _remove_sms(self, sms):
        if self.messages.pop(sms.path, None) is None:
            return
        self._unexport(sms)
        self.modem.update(E.IFACE_MESSAGING, {"Messages": list(self.messages)})
        self.modem.emit(E.IFACE_MESSAGING, "Deleted", sms.path)

    def _sms_by_index(self, index):
        if index is None:
            return None
        for sms in self.messages.values():
            if sms.index == index:
                return sms
        return None

    def _messaging_create(self, obj, props, cb):
        props = {str(k): _plain(v) for k, v in (props or {}).items()}
        number, text = props.get("number"), props.get("text")
        if not C.valid_number(number):
            raise MMError(E.ERR_INVALID_ARGS, "a valid 'number' is required")
        if not isinstance(text, str) or text == "":
            if props.get("data"):
                raise MMError(E.ERR_UNSUPPORTED, "binary SMS are not supported")
            raise MMError(E.ERR_INVALID_ARGS, "'text' is required")
        values = OrderedDict([("PduType", E.PDU_SUBMIT), ("Number", number), ("Text", text)])
        if isinstance(props.get("delivery-report-request"), bool):
            values["DeliveryReportRequest"] = props["delivery-report-request"]
        if isinstance(props.get("smsc"), str):
            values["SMSC"] = props["smsc"]
        sms = self._new_sms(values)
        self._add_sms(sms, False)
        log.info("SMS %s created (%d characters)", sms.path.rsplit("/", 1)[-1], len(text))
        cb(True, sms.path)

    def _messaging_delete(self, obj, path, cb):
        sms = self.messages.get(path)
        if sms is None:
            cb(False, MMError(E.ERR_NOT_FOUND, "no such SMS"))
            return
        if sms.index is None:
            self._remove_sms(sms)
            cb(True, None)
            return

        def done(ok, result):
            if ok:
                self._remove_sms(sms)
                cb(True, None)
            else:
                cb(False, result)

        self._core_call("delete_sms", (sms.index,), done, self.opts.command_timeout)

    def _sms_send(self, sms, cb):
        state = sms.get(E.IFACE_SMS, "State")
        if sms.get(E.IFACE_SMS, "PduType") != E.PDU_SUBMIT:
            cb(False, MMError(E.ERR_WRONG_STATE, "only SMS-SUBMIT messages can be sent"))
            return
        if sms.sending or state == E.SMS_SENDING:
            cb(False, MMError(E.ERR_IN_PROGRESS, "SMS already being sent"))
            return
        if self.st.get("power") != "on" or C.sim_state(self.st) != "ready":
            cb(False, MMError(E.ERR_WRONG_STATE, "modem not enabled"))
            return
        previous = state
        sms.sending = True
        sms.update(E.IFACE_SMS, {"State": E.SMS_SENDING})
        text = sms.get(E.IFACE_SMS, "Text")
        log.info("SMS %s sending (%d characters)", sms.path.rsplit("/", 1)[-1], len(text))

        def done(ok, result):
            sms.sending = False
            if ok:
                values = {"State": E.SMS_SENT}
                ref = result.get("ref") if isinstance(result, dict) else None
                if isinstance(ref, int) and not isinstance(ref, bool) and 0 <= ref <= 0xFFFFFFFF:
                    values["MessageReference"] = ref
                sms.update(E.IFACE_SMS, values)
                log.info("SMS %s sent", sms.path.rsplit("/", 1)[-1])
                cb(True, None)
            else:
                sms.update(E.IFACE_SMS, {"State": previous})
                err = as_mm_error(result)
                log.warning("SMS %s not sent: %s", sms.path.rsplit("/", 1)[-1], type(result).__name__)
                cb(False, err)

        self._core_call("send_sms", (sms.get(E.IFACE_SMS, "Number"), text), done, self.opts.sms_timeout,
                        request_status_report=bool(sms.get(E.IFACE_SMS, "DeliveryReportRequest")))

    def _ev_sms_sent(self, data):
        ref = data.get("ref")
        for sms in self.messages.values():
            if (sms.get(E.IFACE_SMS, "PduType") == E.PDU_SUBMIT and ref is not None
                    and sms.get(E.IFACE_SMS, "MessageReference") == ref):
                if data.get("ok", True) and sms.get(E.IFACE_SMS, "State") in (E.SMS_SENDING, E.SMS_SENT):
                    sms.update(E.IFACE_SMS, {"State": E.SMS_SENT})
                elif not data.get("ok", True):
                    log.warning("network reported a failure for SMS %s", sms.path.rsplit("/", 1)[-1])
                return

    def _ev_sms_status_report(self, data):
        ref, status = data.get("ref"), data.get("status")
        if not isinstance(status, int) or isinstance(status, bool) or not 0 <= status <= 0xFF:
            return
        for sms in reversed(list(self.messages.values())):
            if sms.get(E.IFACE_SMS, "PduType") == E.PDU_SUBMIT and sms.get(E.IFACE_SMS, "MessageReference") == ref:
                # MMSmsDeliveryState values are the 3GPP TP-Status codes.
                sms.update(E.IFACE_SMS, {"DeliveryState": status})
                return

    def _received_values(self, data):
        values = OrderedDict([
            ("PduType", E.PDU_DELIVER),
            ("State", E.SMS_RECEIVED),
            ("Number", str(data.get("sender") or data.get("number") or "")),
            ("Text", str(data.get("text") or "")),
            ("Timestamp", C.sms_timestamp(data.get("timestamp"))),
        ])
        smsc = data.get("smsc")
        if isinstance(smsc, str):
            values["SMSC"] = smsc
        return values

    def _ev_sms_received(self, data):
        index = data.get("index")
        existing = self._sms_by_index(index)
        values = self._received_values(data)
        if existing is not None:
            existing.update(E.IFACE_SMS, values)
            return
        sms = self._new_sms(values)
        sms.index = index
        self._add_sms(sms, True)
        log.info("SMS %s received (%d characters)", sms.path.rsplit("/", 1)[-1], len(values["Text"]))

    def _load_sms(self):
        self._sms_loading = True
        session = self._session

        def done(ok, result):
            self._sms_loading = False
            if not ok:
                log.warning("listing stored SMS failed: %s", as_mm_error(result).message)
                return
            self._sms_loaded_session = session
            count = 0
            for entry in result or []:
                if not isinstance(entry, dict):
                    continue
                index = entry.get("index")
                if self._sms_by_index(index) is not None:
                    continue
                if entry.get("sender") or entry.get("pdu_type", "deliver") == "deliver":
                    values = self._received_values(entry)
                else:
                    values = OrderedDict([("PduType", E.PDU_SUBMIT), ("State", E.SMS_STORED),
                                          ("Number", str(entry.get("number") or "")),
                                          ("Text", str(entry.get("text") or ""))])
                sms = self._new_sms(values)
                sms.index = index
                self._add_sms(sms, False)
                count += 1
            log.info("%d stored SMS loaded", count)

        self._core_call("list_sms", (), done, self.opts.command_timeout)

    # ------------------------------------------------------------------
    # Voice

    def _new_call(self, direction, number, state=E.CALL_UNKNOWN, reason=E.REASON_UNKNOWN):
        call = CallObject(self, self._new_path("Call"))
        call.update(E.IFACE_CALL, OrderedDict([
            ("State", state),
            ("StateReason", reason),
            ("Direction", direction),
            ("Number", number or ""),
            ("Multiparty", False),
            ("AudioPort", ""),
            ("AudioFormat", self._audio_format()),
        ]))
        self.calls[call.path] = call
        self._export(call)
        self.modem.update(E.IFACE_VOICE, {"Calls": list(self.calls)})
        self.modem.emit(E.IFACE_VOICE, "CallAdded", call.path)
        return call

    def _remove_call(self, call):
        if self.calls.pop(call.path, None) is None:
            return
        if call.delete_timer is not None:
            call.delete_timer.cancel()
            call.delete_timer = None
        self._unexport(call)
        self.modem.update(E.IFACE_VOICE, {"Calls": list(self.calls)})
        self.modem.emit(E.IFACE_VOICE, "CallDeleted", call.path)

    def _set_call_state(self, call, state, reason):
        old = call.state
        if old == state:
            if reason != call.get(E.IFACE_CALL, "StateReason"):
                call.update(E.IFACE_CALL, {"StateReason": reason})
            return
        call.update(E.IFACE_CALL, OrderedDict([("State", state), ("StateReason", reason)]))
        call.emit(E.IFACE_CALL, "StateChanged", old, state, reason)
        log.info("call %s: state %d -> %d (reason %d)", call.path.rsplit("/", 1)[-1], old, state, reason)
        if state == E.CALL_TERMINATED:
            waiters, call.hangup_waiters = call.hangup_waiters, []
            for waiter in waiters:
                waiter(True, None)
            ttl = self.opts.terminated_call_ttl
            if ttl and call.delete_timer is None:
                call.delete_timer = self.loop.call_later(ttl, self._remove_call, call)

    def _audio_format(self):
        if self._audio and self._audio.get("open"):
            rate = self._audio.get("rate")
            fmt = OrderedDict([("encoding", Variant("s", "pcm")), ("resolution", Variant("s", "s16le"))])
            if isinstance(rate, int) and not isinstance(rate, bool) and rate > 0:
                fmt["rate"] = Variant("u", rate)
            return fmt
        return {}

    def _ev_audio(self, data):
        self._audio = dict(data)
        fmt = self._audio_format()
        for call in self.calls.values():
            if call.state != E.CALL_TERMINATED:
                call.update(E.IFACE_CALL, {"AudioFormat": fmt})

    def _call_by_core_id(self, core_id):
        if core_id is None:
            return None
        for call in self.calls.values():
            if call.core_id == core_id:
                return call
        return None

    def _ev_call(self, data):
        core_id = data.get("id")
        core_state = data.get("state")
        direction = E.CALL_DIRECTION_FROM_CORE.get(data.get("direction"), E.DIRECTION_UNKNOWN)
        number = data.get("number") or ""
        call = self._call_by_core_id(core_id)
        if call is None and direction == E.DIRECTION_OUTGOING:
            for candidate in self.calls.values():
                if candidate.starting and candidate.core_id is None:
                    call = candidate
                    call.core_id = core_id
                    break
        if call is None:
            if core_state == "released":
                return
            state = C.call_state(core_state)
            call = self._new_call(direction, str(number), state, C.call_reason(core_state, data.get("reason")))
            call.core_id = core_id
            if state == E.CALL_RINGING_IN:
                log.info("incoming call %s", call.path.rsplit("/", 1)[-1])
            return
        if number and not call.get(E.IFACE_CALL, "Number"):
            call.update(E.IFACE_CALL, {"Number": str(number)})
        state = C.call_state(core_state)
        if state == E.CALL_UNKNOWN:
            return
        reason = C.call_reason(core_state, data.get("reason"), call.get(E.IFACE_CALL, "StateReason"))
        self._set_call_state(call, state, reason)

    def _voice_create_call(self, obj, props, cb):
        props = {str(k): _plain(v) for k, v in (props or {}).items()}
        number = props.get("number")
        if not C.valid_number(number):
            raise MMError(E.ERR_INVALID_ARGS, "a valid 'number' is required")
        call = self._new_call(E.DIRECTION_OUTGOING, number)
        log.info("call %s created", call.path.rsplit("/", 1)[-1])
        cb(True, call.path)

    def _voice_delete_call(self, obj, path, cb):
        call = self.calls.get(path)
        if call is None:
            cb(False, MMError(E.ERR_NOT_FOUND, "no such call"))
            return
        if call.state not in (E.CALL_TERMINATED, E.CALL_UNKNOWN) and call.core_id is not None:
            self._core_call("hangup", (call.core_id,), lambda ok, res: None, self.opts.command_timeout)
        self._remove_call(call)
        cb(True, None)

    def _voice_hangup_all(self, obj, cb):
        live = [c for c in self.calls.values() if c.state not in (E.CALL_TERMINATED, E.CALL_UNKNOWN)]
        self._hangup_many(live, cb)

    def _hangup_many(self, calls, cb):
        if not calls:
            cb(True, None)
            return
        pending = {"n": len(calls), "error": None}

        def done(ok, result):
            if not ok and pending["error"] is None:
                pending["error"] = result
            pending["n"] -= 1
            if pending["n"] == 0:
                cb(pending["error"] is None, pending["error"])

        for call in calls:
            self._call_hangup(call, done)

    def _voice_hangup_and_accept(self, obj, cb):
        active = [c for c in self.calls.values() if c.state in (E.CALL_ACTIVE, E.CALL_HELD)]
        waiting = [c for c in self.calls.values() if c.state in (E.CALL_WAITING, E.CALL_RINGING_IN)]

        def after(ok, result):
            if not ok:
                cb(False, result)
            elif waiting:
                self._call_accept(waiting[0], cb)
            else:
                cb(True, None)

        self._hangup_many(active, after)

    def _call_start(self, call, cb):
        if call.get(E.IFACE_CALL, "Direction") != E.DIRECTION_OUTGOING or call.state != E.CALL_UNKNOWN:
            cb(False, MMError(E.ERR_WRONG_STATE, "call already started"))
            return
        if self.st.get("power") != "on":
            cb(False, MMError(E.ERR_WRONG_STATE, "modem not enabled"))
            return
        call.starting = True
        self._set_call_state(call, E.CALL_DIALING, E.REASON_OUTGOING_STARTED)

        def done(ok, result):
            call.starting = False
            if ok:
                if isinstance(result, dict) and result.get("id") is not None:
                    call.core_id = result["id"]
                cb(True, None)
                if call.hangup_waiters and call.core_id is not None and call.state != E.CALL_TERMINATED:
                    self._core_call("hangup", (call.core_id,), self._hangup_done(call), self.opts.command_timeout)
            else:
                self._set_call_state(call, E.CALL_TERMINATED, E.REASON_ERROR)
                cb(False, result)

        self._core_call("dial", (call.get(E.IFACE_CALL, "Number"),), done, self.opts.command_timeout)

    def _hangup_done(self, call):
        def done(ok, result):
            if ok:
                self._set_call_state(call, E.CALL_TERMINATED, E.REASON_TERMINATED)
            else:
                waiters, call.hangup_waiters = call.hangup_waiters, []
                for waiter in waiters:
                    waiter(False, result)
        return done

    def _call_accept(self, call, cb):
        if call.get(E.IFACE_CALL, "Direction") != E.DIRECTION_INCOMING or call.state not in (
                E.CALL_RINGING_IN, E.CALL_WAITING):
            cb(False, MMError(E.ERR_WRONG_STATE, "call is not ringing"))
            return

        def done(ok, result):
            if ok:
                if call.state in (E.CALL_RINGING_IN, E.CALL_WAITING):
                    self._set_call_state(call, E.CALL_ACTIVE, E.REASON_ACCEPTED)
                cb(True, None)
            else:
                cb(False, result)

        self._core_call("answer", (call.core_id,), done, self.opts.command_timeout)

    def _call_hangup(self, call, cb):
        if call.state == E.CALL_TERMINATED:
            cb(False, MMError(E.ERR_WRONG_STATE, "call already terminated"))
            return
        if call.core_id is None:
            if call.starting:
                call.hangup_waiters.append(cb)     # sent once dial() returns the id
                return
            self._set_call_state(call, E.CALL_TERMINATED, E.REASON_TERMINATED)
            cb(True, None)
            return
        call.hangup_waiters.append(cb)
        self._core_call("hangup", (call.core_id,), self._hangup_done(call), self.opts.command_timeout)

    def _call_send_dtmf(self, call, digits, cb):
        if call.state != E.CALL_ACTIVE or call.core_id is None:
            cb(False, MMError(E.ERR_WRONG_STATE, "call is not active"))
            return
        if not digits or any(c not in "0123456789*#ABCDabcd" for c in digits):
            cb(False, MMError(E.ERR_INVALID_ARGS, "invalid DTMF digits"))
            return
        self._core_call("send_dtmf", (call.core_id, digits), lambda ok, res: cb(ok, None if ok else res),
                        self.opts.command_timeout)
