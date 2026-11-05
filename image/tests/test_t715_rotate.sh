#!/usr/bin/env bash
# test_t715_rotate.sh — off-device test of t715-rotate's portrait hold
# (rootfs/overlay/usr/local/bin/t715-rotate, docs/image/ROTATION.md §4).
#
# Runs the daemon's code on this machine with python3, with stub modules for
# gi / gi.repository (PyGObject is not installed on a Mac): the stubs carry
# enough of Gio, GLib and GLibUnix for the Rotator class to be built. Its
# D-Bus calls are stubbed on the instance, and the module's apply() is
# replaced by a recorder, so the test drives focus changes and sensor
# orientations through Hyprland's event lines (activewindow>>) and checks
# the transforms that would have been applied. The debounce timers fire by
# hand. In the style of test_t715_keys.sh (omarchy-mobile 5f7ba48, MIT).
#
# Usage: tests/test_t715_rotate.sh        (PYTHON=... to pick the interpreter)
# Prints "ok - ..." per group, "PASS" at the end; exit 1 on the first
# failure. Needs bash and python3 >= 3.6; works with macOS's bash 3.2.
# Nothing outside a temporary directory.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ROTATE="$here/rootfs/overlay/usr/local/bin/t715-rotate"
PY=${PYTHON:-python3}
command -v "$PY" >/dev/null || { echo "SETUP ERROR: no $PY" >&2; exit 2; }
[ -f "$ROTATE" ] || { echo "SETUP ERROR: no $ROTATE" >&2; exit 2; }

t=$(mktemp -d "${TMPDIR:-/tmp}/t715-rotate-test.XXXXXX")
cleanup() { rm -rf "$t"; }
trap cleanup EXIT

"$PY" - "$ROTATE" <<'EOF'
import importlib.machinery
import importlib.util
import sys
import types

script = sys.argv[1]
sys.dont_write_bytecode = True  # no __pycache__ beside the daemon


class _Idle:
    """A GLib main context: timers armed by timeout_add fire in run_pending()."""
    def __init__(self):
        self.armed = []

    def timeout_add(self, _ms, fn):
        self.armed.append(fn)
        return len(self.armed)  # a nonzero id, as GLib does

    def source_remove(self, tid):
        if tid:
            self.armed[tid - 1] = None

    def run_pending(self):
        while self.armed:
            fn = self.armed.pop(0)
            if fn is not None:
                fn()


# The gi modules t715-rotate imports, with just what its construction path
# calls. The real Rotator methods run; only hyprctl (apply) is recorded.
idle = _Idle()
gi = types.ModuleType('gi')
gi.require_version = lambda *a: None
repo = types.ModuleType('gi.repository')
repo.GLib = types.SimpleNamespace(
    PRIORITY_DEFAULT=0, Error=Exception, timeout_add=idle.timeout_add,
    source_remove=idle.source_remove)
repo.Gio = types.SimpleNamespace(
    BusType=types.SimpleNamespace(SYSTEM=1, SESSION=2),
    bus_get_sync=lambda *a: types.SimpleNamespace(signal_subscribe=lambda *a: None),
    signal_subscribe=lambda *a: None,
    bus_watch_name_on_connection=lambda *a: None,
    FileMonitorFlags=types.SimpleNamespace(NONE=0),
    DBusSignalFlags=types.SimpleNamespace(NONE=0),
    BusNameWatcherFlags=types.SimpleNamespace(AUTO_START=0),
    File=types.SimpleNamespace(new_for_path=lambda *a: types.SimpleNamespace(
        monitor_file=lambda *a: types.SimpleNamespace(connect=lambda *a: None))))
repo.GLibUnix = types.SimpleNamespace(signal_add=lambda *a: 0)
sys.modules['gi'] = gi
sys.modules['gi.repository'] = repo

loader = importlib.machinery.SourceFileLoader('t715_rotate', script)
spec = importlib.util.spec_from_loader('t715_rotate', loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)

failures = []


def check(label, ok):
    print(('ok' if ok else 'not ok') + ' - ' + label)
    if not ok:
        failures.append(label)


applied = []


def record_apply(transform, dry_run=False):
    applied.append(transform)
    return True


def rotator(transform, claimed, orientation=None, classes=None):
    """A Rotator with D-Bus stubbed and apply() recorded (leaves _apply real,
    so self.current follows what hyprctl would have set)."""
    r = m.Rotator(types.SimpleNamespace(dry_run=True, session=False))
    r.current = transform
    r.claimed = claimed
    r.held_orientation = orientation
    r._prop = lambda name: {'AccelerometerOrientation': orientation,
                            'HasAccelerometer': True}.get(name)
    m.apply = record_apply
    if classes is not None:
        m.PORTRAIT_CLASSES = classes
    return r


# --- active_class: one prefix, not the v2 one -------------------------------------
check('active_class: the class of an activewindow line, not of the v2 one',
      m.active_class('activewindow>>omacam,Camera') == 'omacam'
      and m.active_class('activewindowv2>>deadbeef') is None
      and m.active_class('activewindow>>,') is None
      and m.active_class('activewindow>>omacam') == 'omacam'
      and m.active_class('configreloaded') is None)

# --- focus to omacam from transform 3 applies 0 -----------------------------------
r = rotator(3, claimed=True)
r.on_event_line('activewindow>>omacam,Camera')
check('focus to omacam from transform 3 applies 0 (and records 3 to restore)',
      applied == [0] and r.held_transform == 3 and r.current == 0)

# --- a sensor change during the hold applies nothing -------------------------------
applied.clear()
r = rotator(3, claimed=True, orientation='right-up')
r.on_event_line('activewindow>>omacam,Camera')
applied.clear()
r._orientation('left-up')
idle.run_pending()  # even a debounce that fires during the hold applies nothing
check('a sensor change during the hold applies nothing (only remembered)',
      applied == [] and r.held_orientation == 'left-up')

# --- focus to another class applies the latest orientation ------------------------
r.on_event_line('activewindow>>other,Other')
check('leaving the hold with the sensor claimed applies 1 (the latest orientation)',
      applied == [1] and r.current == 1)

# --- with the sensor unclaimed, leaving restores the recorded transform ------------
applied.clear()
r = rotator(3, claimed=False)
r.on_event_line('activewindow>>omacam,Camera')
applied.clear()
r.on_event_line('activewindow>>other,Other')
check('leaving the hold with the sensor unclaimed restores the recorded transform',
      applied == [3] and r.current == 3)

# ... and entering the hold already in portrait applies nothing, and leaves
# nothing to restore
applied.clear()
r = rotator(0, claimed=False)
r.on_event_line('activewindow>>omacam,Camera')
check('entering the hold in portrait applies 0 to nothing',
      applied == [] and r.held_transform == 0)
r.on_event_line('activewindow>>other,Other')
check('leaving a hold that started in portrait restores nothing',
      applied == [])

# --- an orientation that maps to nothing applies nothing ---------------------------
applied.clear()
r = rotator(3, claimed=True, orientation=None)
r.on_event_line('activewindow>>omacam,Camera')
applied.clear()
r.on_event_line('activewindow>>other,Other')
check('leaving with no orientation known applies nothing',
      applied == [] and r.current == 0)

# --- a transform lost to a failed apply does not come back ------------------------
applied.clear()
r = rotator(3, claimed=False)
m.apply = lambda transform, dry_run=False: applied.append(transform) or False  # hyprctl down
r.on_event_line('activewindow>>omacam,Camera')  # records 3, the apply of 0 fails
applied.clear()
r.on_event_line('activewindow>>other,Other')
check('a hold whose portrait never landed restores nothing (the screen never left 3)',
      applied == [] and r.current == 3)

# --- activewindowv2 and other event lines change nothing ---------------------------
applied.clear()
r = rotator(3, claimed=True)
r.on_event_line('activewindow>>omacam,Camera')
applied.clear()
for line in ('activewindowv2>>deadbeef', 'workspace>>1', 'activewindow>>omacam,Again',
             'activewindowtitle>>omacam,Camera'):
    r.on_event_line(line)
check('activewindowv2 and other lines change nothing, a repeated hold neither',
      applied == [] and r.held_class is True)

# --- the hold ends on empty focus too, from the sensor if none was seen -------------
applied.clear()
r = rotator(3, claimed=True, orientation='bottom-up')
r.on_event_line('activewindow>>omacam,Camera')
applied.clear()
r.on_event_line('activewindow>>,')
check('empty focus ends the hold (the sensor orientation comes back)',
      applied == [2] and r.held_class is False)

# --- T715_ROTATE_PORTRAIT_CLASSES= (empty) disables the hold ------------------------
applied.clear()
r = rotator(3, claimed=True, classes=frozenset())
r.on_event_line('activewindow>>omacam,Camera')
r._orientation('left-up')
check('T715_ROTATE_PORTRAIT_CLASSES= (empty) disables the hold',
      applied == [] and r.held_class is False and r.pending == 1)

if failures:
    print('%d check(s) failed' % len(failures))
    sys.exit(1)
print('PASS')
EOF
