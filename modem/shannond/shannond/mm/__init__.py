# SPDX-License-Identifier: GPL-2.0-or-later
"""shannon2mm: ModemManager 1.24 D-Bus facade for the shannond core.

The facade runs inside the shannond process, on the same GLib main loop,
and owns ``org.freedesktop.ModemManager1`` (ModemManager itself must be
stopped and masked).  Entry point used by shannond for ``--mm``::

    from shannond import mm
    handle = mm.attach(core, loop)          # after creating the core, before loop.run()
    ...
    handle.close()                          # optional, at shutdown

``attach`` raises ``NameTakenError`` when another process (ModemManager)
owns the name, and ``RuntimeError`` when ``loop`` is not the GLib loop.

Modules:
    enums    ModemManager constants (API values, error names)
    spec     property signatures, signature helpers, Variant
    convert  pure conversions from the core vocabulary to MM values
    model    bus-independent object tree and method logic (Facade)
    service  python-dbus glue (imported only by attach)
    fake     FakeCore, a scripted ModemCore for tests and demos
"""


def attach(core, loop, bus="system", **options):
    """Export the facade for ``core``; see ``model.Options`` for ``options``.

    ``bus`` is 'system' (default), 'session' or a ``dbus.Bus`` instance.
    Returns a ``service.Shannon2MM`` handle with ``facade`` and ``close()``.
    """
    from .service import serve  # python-dbus is only needed here
    return serve(core, loop, bus=bus, **options)


def __getattr__(name):
    if name == "NameTakenError":
        from .service import NameTakenError
        return NameTakenError
    raise AttributeError(name)
