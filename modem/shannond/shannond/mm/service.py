# SPDX-License-Identifier: GPL-2.0-or-later
"""python-dbus glue: exports the ``Facade`` objects as ModemManager 1.24.

Every method below has the exact name and signature of the ModemManager
1.24.2 introspection data and only forwards to ``Facade.call``; the logic
lives in ``model.py``.  Properties go through a hand-written
``org.freedesktop.DBus.Properties`` implementation typed by ``spec.py``,
and ``Introspect`` is extended with the ``<property>`` elements python-dbus
does not generate.

Like ModemManager, only modem objects are announced through the
ObjectManager at ``/org/freedesktop/ModemManager1``; SIM, bearer, SMS and
call objects are plain exported objects referenced by path.
"""

import logging

import dbus
import dbus.exceptions
import dbus.service

from . import enums as E
from . import spec
from .model import Facade, Options
from .spec import Variant, split_signature

log = logging.getLogger("shannond.mm")

PROPS = dbus.PROPERTIES_IFACE
INTROSPECTABLE = "org.freedesktop.DBus.Introspectable"
OBJMGR = E.IFACE_OBJECT_MANAGER

_INT_TYPES = {
    "y": dbus.Byte, "n": dbus.Int16, "q": dbus.UInt16, "i": dbus.Int32,
    "u": dbus.UInt32, "x": dbus.Int64, "t": dbus.UInt64,
}


class NameTakenError(RuntimeError):
    pass


def to_dbus(sig, value, variant_level=0):
    """Typed python-dbus value for plain ``value`` and D-Bus signature ``sig``.

    Values in ``v`` slots get ``variant_level=1``: python-dbus guesses the
    signature of a value placed in a variant from its elements, so a struct
    such as ``(uv)`` only keeps its inner variant when that element is
    marked as one.
    """
    kw = {"variant_level": variant_level} if variant_level else {}
    c = sig[0]
    if c == "b":
        return dbus.Boolean(bool(value), **kw)
    if c in _INT_TYPES:
        return _INT_TYPES[c](value, **kw)
    if c == "d":
        return dbus.Double(value, **kw)
    if c == "s":
        return dbus.String(value, **kw)
    if c == "o":
        return dbus.ObjectPath(value, **kw)
    if c == "g":
        return dbus.Signature(value, **kw)
    if c == "v":
        if not isinstance(value, Variant):
            raise TypeError("variant slot needs a Variant, got %r" % (value,))
        return to_dbus(value.signature, value.value, variant_level=variant_level + 1)
    if c == "a":
        inner = sig[1:]
        if inner.startswith("{"):
            ksig, vsig = split_signature(inner[1:-1])
            return dbus.Dictionary(((to_dbus(ksig, k), to_dbus(vsig, v)) for k, v in value.items()),
                                   signature=ksig + vsig, **kw)
        return dbus.Array([to_dbus(inner, item) for item in value], signature=inner, **kw)
    if c == "(":
        parts = split_signature(sig[1:-1])
        return dbus.Struct(tuple(to_dbus(p, v) for p, v in zip(parts, value)), signature=sig[1:-1], **kw)
    raise TypeError("unsupported signature %r" % sig)


def from_dbus(value):
    """Plain Python copy of a python-dbus argument (variants already unwrapped)."""
    if isinstance(value, dbus.Boolean):
        return bool(value)
    if isinstance(value, int):
        return int(value)
    if isinstance(value, float):
        return float(value)
    if isinstance(value, str):
        return str(value)
    if isinstance(value, (bytes, bytearray)):
        return bytes(value)
    if isinstance(value, dict):
        return {from_dbus(k): from_dbus(v) for k, v in value.items()}
    if isinstance(value, tuple):
        return tuple(from_dbus(v) for v in value)
    if isinstance(value, list):
        return [from_dbus(v) for v in value]
    return value


def _props_dict(mm_obj, iface):
    table = spec.PROPERTIES[iface]
    return dbus.Dictionary(((name, to_dbus(table[name], value)) for name, value in mm_obj.props[iface].items()),
                           signature="sv")


def _ifaces_dict(mm_obj):
    return dbus.Dictionary(((iface, _props_dict(mm_obj, iface)) for iface in mm_obj.interfaces),
                           signature="sa{sv}")


def add_properties_to_introspection(xml, interfaces):
    """Insert <property> elements (from spec.PROPERTIES) into python-dbus introspection XML."""
    for iface in interfaces:
        table = spec.PROPERTIES.get(iface) or {}
        if not table:
            continue
        lines = "".join('    <property name="%s" type="%s" access="read"/>\n' % (name, sig)
                        for name, sig in table.items())
        tag = '<interface name="%s">' % iface
        pos = xml.find(tag)
        if pos >= 0:
            end = xml.find("\n", pos) + 1
            xml = xml[:end] + lines + xml[end:]
        else:
            block = '  <interface name="%s">\n%s  </interface>\n' % (iface, lines)
            close = xml.rfind("</node>")
            xml = xml[:close] + block + xml[close:]
    return xml


def _method(iface, in_sig="", out_sig=""):
    return dbus.service.method(iface, in_signature=in_sig, out_signature=out_sig,
                               async_callbacks=("reply_cb", "error_cb"))


class _Exported(dbus.service.Object):
    """Common part: Properties, Introspect, forwarding to the facade."""

    def __init__(self, glue, mm_obj):
        self._glue = glue
        self.mm = mm_obj
        super().__init__(glue.bus, mm_obj.path)

    def _call(self, iface, method, args, out_sig, reply_cb, error_cb):
        plain = [from_dbus(a) for a in args]

        def cb(ok, result):
            if ok:
                if out_sig:
                    try:
                        reply_cb(to_dbus(out_sig, result))
                    except Exception as exc:  # a bug in the model: answer anyway
                        log.exception("bad return value for %s.%s", iface, method)
                        error_cb(dbus.exceptions.DBusException(str(exc), name=E.ERR_FAILED))
                else:
                    reply_cb()
            else:
                error_cb(dbus.exceptions.DBusException(result.message, name=result.name))

        self._glue.facade.call(self.mm, iface, method, plain, cb)

    # org.freedesktop.DBus.Properties

    @dbus.service.method(PROPS, in_signature="ss", out_signature="v")
    def Get(self, interface_name, property_name):
        props = self.mm.props.get(str(interface_name))
        if props is None:
            raise dbus.exceptions.DBusException("no interface %s" % interface_name,
                                                name="org.freedesktop.DBus.Error.UnknownInterface")
        if str(property_name) not in props:
            raise dbus.exceptions.DBusException("no property %s" % property_name,
                                                name="org.freedesktop.DBus.Error.UnknownProperty")
        self._glue.facade.note_read(self.mm, str(interface_name))
        sig = spec.PROPERTIES[str(interface_name)][str(property_name)]
        return to_dbus(sig, props[str(property_name)])

    @dbus.service.method(PROPS, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface_name):
        iface = str(interface_name)
        if iface not in self.mm.props:
            raise dbus.exceptions.DBusException("no interface %s" % iface,
                                                name="org.freedesktop.DBus.Error.UnknownInterface")
        self._glue.facade.note_read(self.mm, iface)
        return _props_dict(self.mm, iface)

    @dbus.service.method(PROPS, in_signature="ssv", out_signature="")
    def Set(self, interface_name, property_name, value):
        raise dbus.exceptions.DBusException("properties are read-only",
                                            name="org.freedesktop.DBus.Error.PropertyReadOnly")

    @dbus.service.signal(PROPS, signature="sa{sv}as")
    def PropertiesChanged(self, interface_name, changed_properties, invalidated_properties):
        pass

    @dbus.service.method(INTROSPECTABLE, in_signature="", out_signature="s",
                         path_keyword="object_path", connection_keyword="connection")
    def Introspect(self, object_path, connection):
        xml = dbus.service.Object.Introspect(self, object_path, connection)
        return add_properties_to_introspection(xml, self.mm.interfaces)


class ManagerService(_Exported):
    """/org/freedesktop/ModemManager1: Manager + ObjectManager."""

    @_method(E.IFACE_MANAGER)
    def ScanDevices(self, reply_cb, error_cb):
        self._call(E.IFACE_MANAGER, "ScanDevices", (), "", reply_cb, error_cb)

    @_method(E.IFACE_MANAGER, "s")
    def SetLogging(self, level, reply_cb, error_cb):
        self._call(E.IFACE_MANAGER, "SetLogging", (level,), "", reply_cb, error_cb)

    @_method(E.IFACE_MANAGER, "a{sv}")
    def ReportKernelEvent(self, properties, reply_cb, error_cb):
        self._call(E.IFACE_MANAGER, "ReportKernelEvent", (properties,), "", reply_cb, error_cb)

    @_method(E.IFACE_MANAGER, "sb")
    def InhibitDevice(self, uid, inhibit, reply_cb, error_cb):
        self._call(E.IFACE_MANAGER, "InhibitDevice", (uid, inhibit), "", reply_cb, error_cb)

    @dbus.service.method(OBJMGR, in_signature="", out_signature="a{oa{sa{sv}}}")
    def GetManagedObjects(self):
        out = dbus.Dictionary(signature="oa{sa{sv}}")
        modem = self._glue.facade.modem
        if modem.exported:
            self._glue.facade.note_read(modem, None)
            out[dbus.ObjectPath(modem.path)] = _ifaces_dict(modem)
        return out

    @dbus.service.signal(OBJMGR, signature="oa{sa{sv}}")
    def InterfacesAdded(self, object_path, interfaces_and_properties):
        pass

    @dbus.service.signal(OBJMGR, signature="oas")
    def InterfacesRemoved(self, object_path, interfaces):
        pass


class ModemService(_Exported):
    """Modem, Modem.Simple, Modem.Modem3gpp, Modem.Messaging, Modem.Voice."""

    # org.freedesktop.ModemManager1.Modem
    @_method(E.IFACE_MODEM, "b")
    def Enable(self, enable, reply_cb, error_cb):
        self._call(E.IFACE_MODEM, "Enable", (enable,), "", reply_cb, error_cb)

    @_method(E.IFACE_MODEM, "", "ao")
    def ListBearers(self, reply_cb, error_cb):
        self._call(E.IFACE_MODEM, "ListBearers", (), "ao", reply_cb, error_cb)

    @_method(E.IFACE_MODEM, "a{sv}", "o")
    def CreateBearer(self, properties, reply_cb, error_cb):
        self._call(E.IFACE_MODEM, "CreateBearer", (properties,), "o", reply_cb, error_cb)

    @_method(E.IFACE_MODEM, "o")
    def DeleteBearer(self, bearer, reply_cb, error_cb):
        self._call(E.IFACE_MODEM, "DeleteBearer", (bearer,), "", reply_cb, error_cb)

    @_method(E.IFACE_MODEM)
    def Reset(self, reply_cb, error_cb):
        self._call(E.IFACE_MODEM, "Reset", (), "", reply_cb, error_cb)

    @_method(E.IFACE_MODEM, "s")
    def FactoryReset(self, code, reply_cb, error_cb):
        self._call(E.IFACE_MODEM, "FactoryReset", (code,), "", reply_cb, error_cb)

    @_method(E.IFACE_MODEM, "u")
    def SetPowerState(self, state, reply_cb, error_cb):
        self._call(E.IFACE_MODEM, "SetPowerState", (state,), "", reply_cb, error_cb)

    @_method(E.IFACE_MODEM, "u")
    def SetCurrentCapabilities(self, capabilities, reply_cb, error_cb):
        self._call(E.IFACE_MODEM, "SetCurrentCapabilities", (capabilities,), "", reply_cb, error_cb)

    @_method(E.IFACE_MODEM, "(uu)")
    def SetCurrentModes(self, modes, reply_cb, error_cb):
        self._call(E.IFACE_MODEM, "SetCurrentModes", (modes,), "", reply_cb, error_cb)

    @_method(E.IFACE_MODEM, "au")
    def SetCurrentBands(self, bands, reply_cb, error_cb):
        self._call(E.IFACE_MODEM, "SetCurrentBands", (bands,), "", reply_cb, error_cb)

    @_method(E.IFACE_MODEM, "u")
    def SetPrimarySimSlot(self, sim_slot, reply_cb, error_cb):
        self._call(E.IFACE_MODEM, "SetPrimarySimSlot", (sim_slot,), "", reply_cb, error_cb)

    @_method(E.IFACE_MODEM, "", "aa{sv}")
    def GetCellInfo(self, reply_cb, error_cb):
        self._call(E.IFACE_MODEM, "GetCellInfo", (), "aa{sv}", reply_cb, error_cb)

    @_method(E.IFACE_MODEM, "su", "s")
    def Command(self, cmd, timeout, reply_cb, error_cb):
        self._call(E.IFACE_MODEM, "Command", (cmd, timeout), "s", reply_cb, error_cb)

    @dbus.service.signal(E.IFACE_MODEM, signature="iiu")
    def StateChanged(self, old, new, reason):
        pass

    # org.freedesktop.ModemManager1.Modem.Simple
    @_method(E.IFACE_SIMPLE, "a{sv}", "o")
    def Connect(self, properties, reply_cb, error_cb):
        self._call(E.IFACE_SIMPLE, "Connect", (properties,), "o", reply_cb, error_cb)

    @_method(E.IFACE_SIMPLE, "o")
    def Disconnect(self, bearer, reply_cb, error_cb):
        self._call(E.IFACE_SIMPLE, "Disconnect", (bearer,), "", reply_cb, error_cb)

    @_method(E.IFACE_SIMPLE, "", "a{sv}")
    def GetStatus(self, reply_cb, error_cb):
        self._call(E.IFACE_SIMPLE, "GetStatus", (), "a{sv}", reply_cb, error_cb)

    # org.freedesktop.ModemManager1.Modem.Modem3gpp
    @_method(E.IFACE_3GPP, "s")
    def Register(self, operator_id, reply_cb, error_cb):
        self._call(E.IFACE_3GPP, "Register", (operator_id,), "", reply_cb, error_cb)

    @_method(E.IFACE_3GPP, "", "aa{sv}")
    def Scan(self, reply_cb, error_cb):
        self._call(E.IFACE_3GPP, "Scan", (), "aa{sv}", reply_cb, error_cb)

    @_method(E.IFACE_3GPP, "u")
    def SetEpsUeModeOperation(self, mode, reply_cb, error_cb):
        self._call(E.IFACE_3GPP, "SetEpsUeModeOperation", (mode,), "", reply_cb, error_cb)

    @_method(E.IFACE_3GPP, "a{sv}")
    def SetInitialEpsBearerSettings(self, settings, reply_cb, error_cb):
        self._call(E.IFACE_3GPP, "SetInitialEpsBearerSettings", (settings,), "", reply_cb, error_cb)

    @_method(E.IFACE_3GPP, "a{sv}")
    def SetNr5gRegistrationSettings(self, properties, reply_cb, error_cb):
        self._call(E.IFACE_3GPP, "SetNr5gRegistrationSettings", (properties,), "", reply_cb, error_cb)

    @_method(E.IFACE_3GPP, "(us)")
    def DisableFacilityLock(self, properties, reply_cb, error_cb):
        self._call(E.IFACE_3GPP, "DisableFacilityLock", (properties,), "", reply_cb, error_cb)

    @_method(E.IFACE_3GPP, "ay")
    def SetCarrierLock(self, data, reply_cb, error_cb):
        self._call(E.IFACE_3GPP, "SetCarrierLock", (data,), "", reply_cb, error_cb)

    @_method(E.IFACE_3GPP, "u")
    def SetPacketServiceState(self, state, reply_cb, error_cb):
        self._call(E.IFACE_3GPP, "SetPacketServiceState", (state,), "", reply_cb, error_cb)

    # org.freedesktop.ModemManager1.Modem.Messaging
    @_method(E.IFACE_MESSAGING, "", "ao")
    def List(self, reply_cb, error_cb):
        self._call(E.IFACE_MESSAGING, "List", (), "ao", reply_cb, error_cb)

    @_method(E.IFACE_MESSAGING, "u")
    def SetDefaultStorage(self, storage, reply_cb, error_cb):
        self._call(E.IFACE_MESSAGING, "SetDefaultStorage", (storage,), "", reply_cb, error_cb)

    @_method(E.IFACE_MESSAGING, "o")
    def Delete(self, path, reply_cb, error_cb):
        self._call(E.IFACE_MESSAGING, "Delete", (path,), "", reply_cb, error_cb)

    @_method(E.IFACE_MESSAGING, "a{sv}", "o")
    def Create(self, properties, reply_cb, error_cb):
        self._call(E.IFACE_MESSAGING, "Create", (properties,), "o", reply_cb, error_cb)

    @dbus.service.signal(E.IFACE_MESSAGING, signature="ob")
    def Added(self, path, received):
        pass

    @dbus.service.signal(E.IFACE_MESSAGING, signature="o")
    def Deleted(self, path):
        pass

    # org.freedesktop.ModemManager1.Modem.Voice
    @_method(E.IFACE_VOICE, "", "ao")
    def ListCalls(self, reply_cb, error_cb):
        self._call(E.IFACE_VOICE, "ListCalls", (), "ao", reply_cb, error_cb)

    @_method(E.IFACE_VOICE, "o")
    def DeleteCall(self, path, reply_cb, error_cb):
        self._call(E.IFACE_VOICE, "DeleteCall", (path,), "", reply_cb, error_cb)

    @_method(E.IFACE_VOICE, "a{sv}", "o")
    def CreateCall(self, properties, reply_cb, error_cb):
        self._call(E.IFACE_VOICE, "CreateCall", (properties,), "o", reply_cb, error_cb)

    @_method(E.IFACE_VOICE)
    def HoldAndAccept(self, reply_cb, error_cb):
        self._call(E.IFACE_VOICE, "HoldAndAccept", (), "", reply_cb, error_cb)

    @_method(E.IFACE_VOICE)
    def HangupAndAccept(self, reply_cb, error_cb):
        self._call(E.IFACE_VOICE, "HangupAndAccept", (), "", reply_cb, error_cb)

    @_method(E.IFACE_VOICE)
    def HangupAll(self, reply_cb, error_cb):
        self._call(E.IFACE_VOICE, "HangupAll", (), "", reply_cb, error_cb)

    @_method(E.IFACE_VOICE)
    def Transfer(self, reply_cb, error_cb):
        self._call(E.IFACE_VOICE, "Transfer", (), "", reply_cb, error_cb)

    @_method(E.IFACE_VOICE, "b")
    def CallWaitingSetup(self, enable, reply_cb, error_cb):
        self._call(E.IFACE_VOICE, "CallWaitingSetup", (enable,), "", reply_cb, error_cb)

    @_method(E.IFACE_VOICE, "", "b")
    def CallWaitingQuery(self, reply_cb, error_cb):
        self._call(E.IFACE_VOICE, "CallWaitingQuery", (), "b", reply_cb, error_cb)

    @dbus.service.signal(E.IFACE_VOICE, signature="o")
    def CallAdded(self, path):
        pass

    @dbus.service.signal(E.IFACE_VOICE, signature="o")
    def CallDeleted(self, path):
        pass


class SimService(_Exported):
    @_method(E.IFACE_SIM, "s")
    def SendPin(self, pin, reply_cb, error_cb):
        self._call(E.IFACE_SIM, "SendPin", (pin,), "", reply_cb, error_cb)

    @_method(E.IFACE_SIM, "ss")
    def SendPuk(self, puk, pin, reply_cb, error_cb):
        self._call(E.IFACE_SIM, "SendPuk", (puk, pin), "", reply_cb, error_cb)

    @_method(E.IFACE_SIM, "sb")
    def EnablePin(self, pin, enabled, reply_cb, error_cb):
        self._call(E.IFACE_SIM, "EnablePin", (pin, enabled), "", reply_cb, error_cb)

    @_method(E.IFACE_SIM, "ss")
    def ChangePin(self, old_pin, new_pin, reply_cb, error_cb):
        self._call(E.IFACE_SIM, "ChangePin", (old_pin, new_pin), "", reply_cb, error_cb)

    @_method(E.IFACE_SIM, "a(su)")
    def SetPreferredNetworks(self, preferred_networks, reply_cb, error_cb):
        self._call(E.IFACE_SIM, "SetPreferredNetworks", (preferred_networks,), "", reply_cb, error_cb)


class BearerService(_Exported):
    @_method(E.IFACE_BEARER)
    def Connect(self, reply_cb, error_cb):
        self._call(E.IFACE_BEARER, "Connect", (), "", reply_cb, error_cb)

    @_method(E.IFACE_BEARER)
    def Disconnect(self, reply_cb, error_cb):
        self._call(E.IFACE_BEARER, "Disconnect", (), "", reply_cb, error_cb)


class SmsService(_Exported):
    @_method(E.IFACE_SMS)
    def Send(self, reply_cb, error_cb):
        self._call(E.IFACE_SMS, "Send", (), "", reply_cb, error_cb)

    @_method(E.IFACE_SMS, "u")
    def Store(self, storage, reply_cb, error_cb):
        self._call(E.IFACE_SMS, "Store", (storage,), "", reply_cb, error_cb)


class CallService(_Exported):
    @_method(E.IFACE_CALL)
    def Start(self, reply_cb, error_cb):
        self._call(E.IFACE_CALL, "Start", (), "", reply_cb, error_cb)

    @_method(E.IFACE_CALL)
    def Accept(self, reply_cb, error_cb):
        self._call(E.IFACE_CALL, "Accept", (), "", reply_cb, error_cb)

    @_method(E.IFACE_CALL, "s")
    def Deflect(self, number, reply_cb, error_cb):
        self._call(E.IFACE_CALL, "Deflect", (number,), "", reply_cb, error_cb)

    @_method(E.IFACE_CALL)
    def JoinMultiparty(self, reply_cb, error_cb):
        self._call(E.IFACE_CALL, "JoinMultiparty", (), "", reply_cb, error_cb)

    @_method(E.IFACE_CALL)
    def LeaveMultiparty(self, reply_cb, error_cb):
        self._call(E.IFACE_CALL, "LeaveMultiparty", (), "", reply_cb, error_cb)

    @_method(E.IFACE_CALL)
    def Hangup(self, reply_cb, error_cb):
        self._call(E.IFACE_CALL, "Hangup", (), "", reply_cb, error_cb)

    @_method(E.IFACE_CALL, "s")
    def SendDtmf(self, dtmf, reply_cb, error_cb):
        self._call(E.IFACE_CALL, "SendDtmf", (dtmf,), "", reply_cb, error_cb)

    @dbus.service.signal(E.IFACE_CALL, signature="s")
    def DtmfReceived(self, dtmf):
        pass

    @dbus.service.signal(E.IFACE_CALL, signature="iiu")
    def StateChanged(self, old, new, reason):
        pass


_SERVICE_FOR_KIND = {
    "modem": ModemService,
    "sim": SimService,
    "bearer": BearerService,
    "sms": SmsService,
    "call": CallService,
}


class DBusGlue:
    """Sink of the facade: keeps one python-dbus object per model object."""

    def __init__(self, facade, bus):
        self.facade = facade
        self.bus = bus
        self.services = {}
        self.bus_name = None
        self.root = ManagerService(self, facade.manager)
        facade.manager.exported = True
        self.services[facade.manager.path] = self.root

    # sink interface
    def object_added(self, obj):
        if obj.path in self.services:
            return
        service = _SERVICE_FOR_KIND[obj.kind](self, obj)
        self.services[obj.path] = service
        if obj.kind == "modem":
            self.root.InterfacesAdded(dbus.ObjectPath(obj.path), _ifaces_dict(obj))

    def object_removed(self, obj):
        service = self.services.pop(obj.path, None)
        if obj.kind == "modem":
            self.root.InterfacesRemoved(dbus.ObjectPath(obj.path), dbus.Array(obj.interfaces, signature="s"))
        if service is not None:
            service.remove_from_connection()

    def properties_changed(self, obj, iface, changed):
        service = self.services.get(obj.path)
        if service is None:
            return
        table = spec.PROPERTIES[iface]
        payload = dbus.Dictionary(((k, to_dbus(table[k], v)) for k, v in changed.items()), signature="sv")
        service.PropertiesChanged(iface, payload, dbus.Array([], signature="s"))

    def emit(self, obj, iface, signal, *args):
        service = self.services.get(obj.path)
        if service is None:
            return
        getattr(service, signal)(*args)

    def request_name(self):
        try:
            self.bus_name = dbus.service.BusName(E.SERVICE, self.bus, allow_replacement=False,
                                                 replace_existing=False, do_not_queue=True)
        except dbus.exceptions.NameExistsException:
            raise NameTakenError("%s is already owned: stop and mask ModemManager before starting the "
                                 "facade" % E.SERVICE) from None

    def close(self):
        for path, service in list(self.services.items()):
            try:
                service.remove_from_connection()
            except Exception:
                pass
        self.services.clear()
        if self.bus_name is not None:
            try:
                self.bus.release_name(E.SERVICE)
            except Exception:
                pass
            self.bus_name = None


class Shannon2MM:
    """Handle returned by ``attach``: ``facade`` (model) and ``glue`` (D-Bus)."""

    def __init__(self, facade, glue):
        self.facade = facade
        self.glue = glue

    def close(self):
        self.facade.stop()
        self.glue.close()


def _is_glib_loop(loop):
    return type(loop).__name__ == "GLibLoop" or getattr(loop, "_GLib", None) is not None


def serve(core, loop, bus="system", options=None, **kw):
    """Export the facade for ``core`` on ``bus`` ('system', 'session' or a dbus.Bus)."""
    if not _is_glib_loop(loop):
        raise RuntimeError("shannon2mm needs shannond's GLib loop (python-dbus dispatches through the "
                           "default GLib main context); start shannond with the GLib loop")
    from dbus.mainloop.glib import DBusGMainLoop
    DBusGMainLoop(set_as_default=True)
    if bus in (None, "system"):
        bus = dbus.SystemBus()
    elif bus == "session":
        bus = dbus.SessionBus()
    if options is None:
        options = Options(**kw)
    facade = Facade(core, loop, options=options)
    glue = DBusGlue(facade, bus)
    facade.sink = glue
    facade.start()
    try:
        glue.request_name()
    except Exception:
        facade.stop()
        glue.close()
        raise
    log.info("%s acquired", E.SERVICE)
    return Shannon2MM(facade, glue)
