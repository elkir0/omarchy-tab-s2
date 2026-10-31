#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""A stand-in for iio-sensor-proxy on the session bus, to test t715-rotate without
tilting the tablet: it plays orientations, and the real Hyprland turns.

    rotate-fake-sensor.py [ORIENTATION:SECONDS ...]

Run t715-rotate --session next to it. Prints what it plays; the caller reads
hyprctl to see what came of it.
"""
import sys

import gi
gi.require_version('Gio', '2.0')
from gi.repository import Gio, GLib  # noqa: E402

XML = """<node><interface name="net.hadess.SensorProxy">
  <method name="ClaimAccelerometer"/><method name="ReleaseAccelerometer"/>
  <property name="HasAccelerometer" type="b" access="read"/>
  <property name="AccelerometerOrientation" type="s" access="read"/>
</interface></node>"""
PATH = '/net/hadess/SensorProxy'
script = [a.split(':') for a in sys.argv[1:]] or [['right-up', '2'], ['normal', '2']]
state = {'orientation': 'normal', 'claims': 0}
loop = GLib.MainLoop()


def method(_conn, _sender, _path, _iface, name, _params, invocation):
    state['claims'] += 1 if name == 'ClaimAccelerometer' else -1
    print(f'{name}, claims {state["claims"]}', flush=True)
    invocation.return_value(None)


def prop(_conn, _sender, _path, _iface, name):
    return GLib.Variant('b', True) if name == 'HasAccelerometer' else GLib.Variant('s', state['orientation'])


def step(conn):
    if not script:
        loop.quit()
        return False
    orientation, seconds = script.pop(0)
    state['orientation'] = orientation
    print(f'orientation {orientation}', flush=True)
    conn.emit_signal(None, PATH, 'org.freedesktop.DBus.Properties', 'PropertiesChanged',
                     GLib.Variant('(sa{sv}as)', ('net.hadess.SensorProxy',
                                                 {'AccelerometerOrientation': GLib.Variant('s', orientation)}, [])))
    GLib.timeout_add(int(float(seconds) * 1000), step, conn)
    return False


def on_bus(conn, _name):
    node = Gio.DBusNodeInfo.new_for_xml(XML)
    conn.register_object(PATH, node.interfaces[0], method, prop, None)


Gio.bus_own_name(Gio.BusType.SESSION, 'net.hadess.SensorProxy', Gio.BusNameOwnerFlags.NONE, on_bus,
                 lambda conn, _n: GLib.timeout_add(1500, step, conn), None)
loop.run()
