#!/usr/bin/env bash
# test_t715_keys.sh — off-device test of t715-keys' gestures
# (rootfs/overlay/usr/local/bin/t715-keys, touch layers P1 and P2,
# docs/image/ROOTFS.md).
#
# Runs t715-keys on this machine with python3, reading a FIFO instead of the
# gpio-keys device: the test writes struct input_event records into it (fake
# evdev input, in the native layout t715-keys reads), keys and the cover's
# lid switch. Its device discovery runs on a fake sysfs tree. Stand-ins for hyprctl,
# omarchy-menu, omarchy-shell (the touch shell's IPC), brightnessctl and
# omarchy-hw-display record what was called; hyprctl answers the screen's
# DPMS state, the active workspace's windows and the open layers (Omarchy's
# menu, the touch shell's recents, drawer and quick settings) from files,
# and its dispatches change the DPMS state.
# In the style of omarchy-mobile's packages/omamobile-shell/test/keys.sh
# (5f7ba48, MIT, Copyright (c) 2026 Derek Ross).
#
# Usage: tests/test_t715_keys.sh        (PYTHON=... to pick the interpreter)
# Prints "ok - ..." per group, "PASS" at the end; exit 1 on the first
# failure (with the calls and t715-keys' log). Needs bash and python3 >= 3.6;
# works with macOS's bash 3.2. Nothing outside a temporary directory.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
KEYS="$here/rootfs/overlay/usr/local/bin/t715-keys"
PY=${PYTHON:-python3}
command -v "$PY" >/dev/null || { echo "SETUP ERROR: no $PY" >&2; exit 2; }
[ -f "$KEYS" ] || { echo "SETUP ERROR: no $KEYS" >&2; exit 2; }

t=$(mktemp -d "${TMPDIR:-/tmp}/t715-keys-test.XXXXXX")
pid=""
cleanup() {
    set +e
    [ -n "$pid" ] && kill "$pid" 2>/dev/null && wait "$pid" 2>/dev/null
    exec 3>&-
    rm -rf "$t"
}
trap cleanup EXIT
mkdir -p "$t/bin" "$t/run/hypr/test"
: > "$t/run/hypr/test/.socket.sock"
log=$t/calls

# --- stand-ins ------------------------------------------------------------------
cat > "$t/bin/hyprctl" <<STUB
#!/bin/bash
echo "hyprctl \$*" >> "$log"
[ -f "$t/hypr-down" ] && exit 1
[ -f "$t/hypr-eval-down" ] && [ "\$1" = eval ] && exit 1
[ -f "$t/hypr-slow" ] && [ "\$1" = monitors ] && sleep 0.9
case "\$1" in
  monitors) printf '[{"name": "DSI-1", "dpmsStatus": %s}]\n' "\$(cat "$t/dpms")" ;;
  activeworkspace) printf '{"id": 1, "windows": %s}\n' "\$(cat "$t/windows")" ;;
  activewindow) printf '{"class": "%s"}\n' "\$(cat "$t/window-class" 2>/dev/null)" ;;
  layers)
    ns='{"namespace": "omarchy-bar"}'
    for open in omarchy-menu omamobile-switcher omamobile-launcher omamobile-quicksettings; do
      [ -f "$t/open-\$open" ] && ns="\$ns, {\"namespace\": \"\$open\"}"
    done
    printf '{"DSI-1": {"levels": {"2": [%s]}}}\n' "\$ns" ;;
  dispatch)
    # The panel's DPMS file follows, as DRM's does, when a test has one.
    case "\$2" in
      *'action = "disable"'*) echo false > "$t/dpms"; [ -f "$t/dpms-sysfs" ] && echo Off > "$t/dpms-sysfs" ;;
      *'action = "enable"'*) echo true > "$t/dpms"; [ -f "$t/dpms-sysfs" ] && echo On > "$t/dpms-sysfs" ;;
    esac ;;
esac
exit 0
STUB
cat > "$t/bin/omarchy-menu" <<STUB
#!/bin/bash
echo "omarchy-menu \$*" >> "$log"
STUB
cat > "$t/bin/omarchy-shell" <<STUB
#!/bin/bash
echo "omarchy-shell \$*" >> "$log"
[ "\$*" = "lock isLocked" ] && cat "$t/locked" 2>/dev/null
exit 0
STUB
cat > "$t/bin/omarchy-system-lock" <<STUB
#!/bin/bash
echo "omarchy-system-lock" >> "$log"
[ -f "$t/lock-broken" ] || echo true > "$t/locked"
STUB
cat > "$t/bin/busctl" <<STUB
#!/bin/bash
printf 's "%s"\n' "\$(cat "$t/inhibited" 2>/dev/null)"
STUB
cat > "$t/bin/omarchy-hw-display" <<STUB
#!/bin/bash
echo s6e3ha2_tabs2
STUB
cat > "$t/bin/brightnessctl" <<STUB
#!/bin/bash
echo "brightnessctl \$*" >> "$log"
case "\$*" in
  *" get") cat "$t/brightness" ;;
  *" set "*) for v; do :; done; case "\$v" in *%) v=\$(( \${v%\%} * 255 / 100 )) ;; esac; echo "\$v" > "$t/brightness" ;;
esac
STUB
chmod +x "$t"/bin/*

# --- helpers ----------------------------------------------------------------------
K_POWER=116 K_HOME=172 K_VOLDOWN=114 K_VOLUP=115

fail() {
    printf 'not ok - %s\n' "$1" >&2
    echo "--- calls" >&2; cat "$log" >&2 2>/dev/null || true
    echo "--- t715-keys log" >&2; cat "$t/daemon.log" >&2 2>/dev/null || true
    exit 1
}
has() { grep -qF -- "$1" "$log"; }
# eventually TEXT: the calls get TEXT within 3 s (omarchy-menu and
# omarchy-shell are started without waiting for them).
eventually() {
    local i=0
    until has "$1"; do
        i=$((i + 1)); [ "$i" -lt 60 ] || return 1
        sleep 0.05
    done
}
# held KEY: how many long presses of KEY t715-keys has fired (its log line is
# written when the timer fires, so it tells "while the key was still down").
held() { grep -c "^t715-keys: $1: held" "$t/daemon.log" || true; }
line_of() { grep -nF -- "$1" "$log" | head -n1 | cut -d: -f1; }
reset() { : > "$log"; }

# start [VAR=VALUE...]: t715-keys on a fresh FIFO, with the stand-ins.
start() {
    stop
    rm -f "$t/fifo" "$t/daemon.log"
    mkfifo "$t/fifo"
    # Read-write, so neither side's open blocks and t715-keys never sees EOF.
    exec 3<>"$t/fifo"
    env PATH="$t/bin:$PATH" XDG_RUNTIME_DIR="$t/run" HOME="$t" HYPRLAND_INSTANCE_SIGNATURE=test \
        T715_KEYS_BIG_CORES="$t/cpu%d-online" \
        T715_KEYS_DPMS="$t/no-dpms" \
        "$@" "$PY" "$KEYS" --device "$t/fifo" 2> "$t/daemon.log" &
    pid=$!
    local i=0
    until grep -q 'reading ' "$t/daemon.log" 2>/dev/null; do
        i=$((i + 1)); [ "$i" -lt 100 ] || fail "t715-keys did not start"
        sleep 0.05
    done
}
stop() {
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        pid=""
    fi
    exec 3>&-
}

# ev CODE VALUE [TYPE]: one input event (EV_KEY unless TYPE) and its
# SYN_REPORT, as the kernel writes them.
ev() {
    "$PY" -c 'import os, struct, sys
e = struct.Struct("@llHHi")
os.write(3, e.pack(0, 0, int(sys.argv[3]), int(sys.argv[1]), int(sys.argv[2])) + e.pack(0, 0, 0, 0, 0))' "$1" "$2" "${3:-1}"
}
EV_SW=5 SW_LID=0 SW_TABLET_MODE=1
# cover closed|opened: the lid switch, as the cover's Hall sensor reports it.
cover() { case "$1" in closed) ev $SW_LID 1 $EV_SW ;; opened) ev $SW_LID 0 $EV_SW ;; esac; sleep 0.5; }
press() { ev "$1" 1; }
release() { ev "$1" 0; }
# tap KEY: a short press (0.1 s), then time for t715-keys and what it started.
tap() { press "$1"; sleep 0.1; release "$1"; sleep 0.5; }

lit() { echo true > "$t/dpms"; }
dark() { echo false > "$t/dpms"; }

TOUCH_OFF='touchdevice = { enabled = false }'
TOUCH_ON='touchdevice = { enabled = true }'
DPMS_OFF='hl.dsp.dpms({ action = "disable" })'
DPMS_ON='hl.dsp.dpms({ action = "enable" })'
GO_HOME='hl.dsp.focus({ workspace = "empty" })'
HOME_PAGE='omarchy-shell shell call omamobile.home goHome'
RECENTS='omarchy-shell shell toggle omamobile.switcher {}'
opened() { touch "$t/open-$1"; }
closed() { rm -f "$t"/open-*; }

echo 2 > "$t/windows"
echo 122 > "$t/brightness"
rm -f "$t/hypr-down"; closed

# --- --check -------------------------------------------------------------------------
PATH="$t/bin:$PATH" "$PY" "$KEYS" --check > "$t/check.out" 2>&1 || { cat "$t/check.out" >&2; fail "--check passes with every command present"; }
grep -q 'input_event is' "$t/check.out" || fail "--check reports the event size"
echo "ok - --check: event size reported, commands found"

# --- device discovery: gpio-keys by name, and whatever reports a lid switch ------------
mkdir -p "$t/sys"
fake_event() {  # fake_event N NAME [SW-BITMAP]
    mkdir -p "$t/sys/event$1/device/capabilities"
    echo "$2" > "$t/sys/event$1/device/name"
    [ -z "${3:-}" ] || echo "$3" > "$t/sys/event$1/device/capabilities/sw"
}
fake_event 0 gpio-keys 0
fake_event 1 hall-sensor 1
fake_event 2 synaptics-s5806
fake_event 3 tablet-mode 2
fake_event 4 multi-word "0 1"
found=$(env -u T715_KEYS_DEVICES "$PY" -c 'import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("t715_keys", sys.argv[1])
spec = importlib.util.spec_from_loader("t715_keys", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
print(" ".join(m.find_devices(sys.argv[2])))' "$KEYS" "$t/sys") || fail "find_devices runs"
[ "$found" = "/dev/input/event0 /dev/input/event1 /dev/input/event4" ] \
    || fail "devices: gpio-keys and the lid switches (bit 0 of the last word), not touch or other switches (got: $found)"
echo "ok - devices: gpio-keys by name, any device with a lid switch"

start

# --- Power, short ----------------------------------------------------------------------
# (eventually: the first press after start also pays for the first spawns.)
lit; reset; tap $K_POWER
eventually "$TOUCH_OFF" || fail "lit: a short press turns the touchscreen off"
eventually "$DPMS_OFF" || fail "lit: a short press turns the screen off (DPMS)"
[ "$(line_of "$TOUCH_OFF")" -lt "$(line_of "$DPMS_OFF")" ] || fail "lit: the touchscreen goes off before the panel"
has "omarchy-menu" && fail "lit: a short press opens no menu"
[ "$(cat "$t/dpms")" = false ] || fail "lit: the screen is dark after a short press"

reset; tap $K_POWER
has "$DPMS_ON" || fail "dark: a short press lights the screen"
has "$TOUCH_ON" || fail "dark: a short press turns the touchscreen back on"
has "$DPMS_OFF" && fail "dark: a short press does not turn the screen off again"
has "omarchy-menu" && fail "dark: a short press opens no menu"
echo "ok - power, short: screen and touchscreen off when lit, on when dark"

# The A57 cores follow the screen, on a kernel that has their online files.
cores() { cat "$t"/cpu4-online "$t"/cpu5-online "$t"/cpu6-online "$t"/cpu7-online | tr -d '\n'; }
for n in 4 5 6 7; do echo 1 > "$t/cpu$n-online"; done
lit; reset; tap $K_POWER
eventually "$DPMS_OFF" || fail "cores: the screen goes off"
[ "$(cores)" = 0000 ] || fail "cores: cpu4-7 offline with the screen (got $(cores))"
reset; tap $K_POWER
eventually "$DPMS_ON" || fail "cores: the screen comes back"
[ "$(cores)" = 1111 ] || fail "cores: cpu4-7 online with the screen (got $(cores))"
rm -f "$t"/cpu?-online
lit; reset; tap $K_POWER; reset; tap $K_POWER
grep -q "did not go" "$t/daemon.log" && fail "cores: no files, no complaint"
echo "ok - power, short: the A57 cores offline while dark, online when lit, nothing without the files"

# The A57s come back before the screen lights: hyprctl's stand-in records
# cpu4's online file at DPMS on.
for n in 4 5 6 7; do echo 1 > "$t/cpu$n-online"; done
lit; reset; tap $K_POWER
eventually "$DPMS_OFF" || fail "wake order: the screen goes off"
cp "$t/bin/hyprctl" "$t/hyprctl.real"
cat > "$t/bin/hyprctl" <<STUB
#!/bin/bash
case "\$*" in *'action = "enable"'*) echo "cpu4 at wake \$(cat "$t/cpu4-online")" >> "$log" ;; esac
exec "$t/hyprctl.real" "\$@"
STUB
chmod +x "$t/bin/hyprctl"
reset; tap $K_POWER
eventually "$DPMS_ON" || fail "wake order: the screen comes back"
has "cpu4 at wake 1" || fail "wake order: the A57s online before the screen lights"
mv "$t/hyprctl.real" "$t/bin/hyprctl"
rm -f "$t"/cpu?-online
echo "ok - power, short: the A57s come back before the screen lights"

# A saved brightness of 0 would wake to the panel's dimmest level.
dark; echo 0 > "$t/brightness"; reset; tap $K_POWER
has "brightnessctl -q -d s6e3ha2_tabs2 set 40%" || fail "dark, brightness 0: the wake sets 40 %"
echo 122 > "$t/brightness"
lit; reset; tap $K_POWER; reset; tap $K_POWER
has "brightnessctl -q -d s6e3ha2_tabs2 set" && fail "dark, brightness kept: the wake leaves it"
echo "ok - power, wake: a brightness of 0 comes back at 40 %, any other is kept"

# --- Power, held -----------------------------------------------------------------------
# The long press must fire while the key is down, at 0.6 s: by 0.9 s after
# the press (nothing may need a key held for a second or more).
lit; reset; n=$(held power)
press $K_POWER; sleep 0.35
[ "$(held power)" = "$n" ] || fail "held: nothing before 0.6 s"
sleep 0.55
[ "$(held power)" = $((n + 1)) ] || fail "held 0.6 s: the long press fires while the key is still down"
release $K_POWER
eventually "omarchy-menu toggle system" || fail "held 0.6 s: the system menu opens"
sleep 0.3
has "$DPMS_OFF" && fail "held: the release does not turn the screen off"
[ "$(grep -c 'omarchy-menu' "$log")" = 1 ] || fail "held: the menu opens once"

dark; reset; n=$(held power)
press $K_POWER; sleep 0.25
has "$DPMS_ON" || fail "dark, held: the press lights the screen at once"
sleep 0.65
[ "$(held power)" = $((n + 1)) ] || fail "dark, held: the long press fires too"
release $K_POWER
eventually "omarchy-menu toggle system" || fail "dark, held: the system menu opens"
sleep 0.3
has "$DPMS_OFF" && fail "dark, held: the release does not turn the screen off"
echo "ok - power, held 0.6 s: the system menu while held (lit or dark), never a screen-off"

# --- Home: the touch shell's home and recent apps (touch layer P2) ------------------------
lit; echo 2 > "$t/windows"; closed; reset; tap $K_HOME
has "$GO_HOME" || fail "home: a short press on a workspace with windows goes to an empty one"
eventually "$HOME_PAGE" || fail "home: the home screens go back to their home page (omamobile.home goHome)"
[ "$(line_of "$GO_HOME")" -lt "$(line_of "$HOME_PAGE")" ] || fail "home: the empty workspace first, then the home page"
has "omarchy-menu" && fail "home: no menu to close"
has "shell hide" && fail "home: no sheet to close"
echo 0 > "$t/windows"; reset; tap $K_HOME
has "$GO_HOME" && fail "home: on an empty workspace already, it stays there"
eventually "$HOME_PAGE" || fail "home: on an empty workspace, the home page still comes back (from another page)"
echo 2 > "$t/windows"; opened omarchy-menu; reset; tap $K_HOME
eventually "omarchy-menu close" || fail "home: an open Omarchy menu closes"
has "$GO_HOME" || fail "home: with the menu open, it still goes home"
eventually "$HOME_PAGE" || fail "home: with the menu open, the home page too"
closed; opened omamobile-switcher; opened omamobile-launcher; opened omamobile-quicksettings; reset; tap $K_HOME
for sheet in omamobile.switcher omamobile.launcher omamobile.quicksettings; do
    eventually "omarchy-shell shell hide $sheet" || fail "home: an open $sheet closes"
done
eventually "$HOME_PAGE" || fail "home: with the shell's sheets open, the home page too"
has "omarchy-menu" && fail "home: Omarchy's menu was not open, nothing to close"
closed; opened omamobile-launcher; reset; tap $K_HOME
eventually "omarchy-shell shell hide omamobile.launcher" || fail "home: the drawer closes"
has "hide omamobile.switcher" && fail "home: only what is open is closed"
closed

reset; n=$(held home)
press $K_HOME; sleep 0.9
[ "$(held home)" = $((n + 1)) ] || fail "home held 0.6 s: the long press fires while held"
release $K_HOME
eventually "$RECENTS" || fail "home held 0.6 s: recent apps (omamobile.switcher)"
sleep 0.3
has "$GO_HOME" && fail "home held: the release does not go home"
has "$HOME_PAGE" && fail "home held: no home page"
has "omarchy-menu" && fail "home held: no Omarchy menu (Omarchy's app launcher is no longer Home's)"
[ "$(grep -c 'omamobile.switcher' "$log")" = 1 ] || fail "home held: recents asked once"
opened omarchy-menu; reset; n=$(held home)
press $K_HOME; sleep 0.9; release $K_HOME
eventually "$RECENTS" || fail "home held, menu open: recent apps"
eventually "omarchy-menu close" || fail "home held, menu open: Omarchy's menu closes first"
closed

dark; reset; tap $K_HOME
has "$DPMS_ON" || fail "dark: Home lights the screen"
has "$TOUCH_ON" || fail "dark: Home turns the touchscreen on"
sleep 0.3
has "$GO_HOME" && fail "dark: Home only wakes"
has "omarchy-shell" && fail "dark: Home only wakes, no home page"
dark; reset; n=$(held home)
press $K_HOME; sleep 0.9; release $K_HOME; sleep 0.5
[ "$(held home)" = "$n" ] && ! has "omarchy-menu" && ! has "omarchy-shell" || fail "dark: a held Home only wakes, no recents"
echo "ok - home: home page (empty workspace, menu and sheets closed), recents when held, wake when dark"

# --- no chord, volume keys left alone --------------------------------------------------------
lit; reset
tap $K_VOLDOWN; tap $K_VOLUP
[ ! -s "$log" ] || fail "the volume keys call nothing (Omarchy's bindings keep them)"
press $K_POWER; sleep 0.05; press $K_VOLDOWN; sleep 0.1; release $K_VOLDOWN; release $K_POWER; sleep 0.5
has "$DPMS_OFF" || fail "power + volume down: an ordinary short power press"
grep -q 'capture\|screenshot' "$log" && fail "power + volume down: no screenshot chord"
echo "ok - no Power + Volume chord; the volume keys call nothing"

# --- a Hyprland that does not answer reads as lit --------------------------------------------
dark; touch "$t/hypr-down"; reset; tap $K_POWER
has "$DPMS_ON" && fail "no answer from Hyprland: the press never wakes blind"
has "$DPMS_OFF" || fail "no answer from Hyprland: the press acts as on a lit screen"
rm -f "$t/hypr-down"
echo "ok - an unanswered screen state reads as lit"

# --- a slow Hyprland at the press: the queued release still makes it short ----------------
# (hyprctl takes 0.9 s to answer the press's screen check; the release
# arrives meanwhile and must be seen before the 0.6 s hold timer.)
lit; touch "$t/hypr-slow"; reset; tap $K_POWER
eventually "$DPMS_OFF" || fail "slow Hyprland: a short press still turns the screen off"
sleep 0.5
has "omarchy-menu" && fail "slow Hyprland: a short press never opens the system menu"
rm -f "$t/hypr-slow"; lit
echo "ok - a slow screen check at the press does not turn a short press into a long one"

# --- the touchscreen follows the screen -------------------------------------------------------
lit; reset; tap $K_POWER
has "$TOUCH_OFF" || fail "resync: the touchscreen is off with the screen"
stop; start T715_KEYS_RESYNC=0.3
reset; lit; sleep 1
has "$TOUCH_ON" || fail "resync: lit by something else, the touchscreen comes back"
reset; sleep 0.8
has "$TOUCH_ON" && fail "resync: once only"
# A restart finds the touchscreen it turned off and a lit screen.
tap $K_POWER; [ "$(cat "$t/dpms")" = false ] || fail "resync: dark again"
lit; reset; start
has "$TOUCH_ON" || fail "restart: a lit screen gets its touchscreen back"
echo "ok - the touchscreen comes back when something else lit the screen, and after a restart"

# With the panel's DPMS file, the resync reads it and asks Hyprland nothing.
echo On > "$t/dpms-sysfs"
start T715_KEYS_RESYNC=0.2 T715_KEYS_DPMS="$t/dpms-sysfs"
lit; reset; tap $K_POWER
eventually "$DPMS_OFF" || fail "dpms file: the screen goes off"
reset; sleep 1
has "hyprctl monitors" && fail "dpms file: no hyprctl while dark"
has "$TOUCH_ON" && fail "dpms file: still dark, the touchscreen stays off"
echo On > "$t/dpms-sysfs"; sleep 0.8
has "$TOUCH_ON" || fail "dpms file: lit by something else, the touchscreen comes back"
tap $K_POWER; rm -f "$t/dpms-sysfs"
echo "ok - the panel's DPMS file replaces hyprctl for the screen checks"
start

# --- backlight mode (T715_KEYS_SCREEN_OFF=backlight) ---------------------------------------
start T715_KEYS_SCREEN_OFF=backlight
lit; echo 122 > "$t/brightness"; reset; tap $K_POWER
has "brightnessctl -q -d s6e3ha2_tabs2 set 0" || fail "backlight: a short press sets brightness 0"
has "$TOUCH_OFF" || fail "backlight: the touchscreen goes off"
has "$DPMS_OFF" && fail "backlight: no DPMS"
reset; tap $K_POWER
has "brightnessctl -q -d s6e3ha2_tabs2 set 122" || fail "backlight: the next press puts the brightness back"
has "$TOUCH_ON" || fail "backlight: and the touchscreen"
echo "ok - backlight mode: brightness 0 and back, touchscreen with it, no DPMS"

# --- a release with no press (a key held when it started) ------------------------------------
start
lit; reset; release $K_POWER; release $K_HOME; sleep 0.4
[ ! -s "$log" ] || fail "a release with no press does nothing"
echo "ok - a release with no press does nothing"

# --- the cover (lid switch) ---------------------------------------------------------------
lit; reset; cover closed
has "$TOUCH_OFF" || fail "cover closed, lit: the touchscreen goes off"
has "$DPMS_OFF" || fail "cover closed, lit: the screen goes off (DPMS)"
[ "$(line_of "$TOUCH_OFF")" -lt "$(line_of "$DPMS_OFF")" ] || fail "cover closed: the touchscreen goes off before the panel"
has "omarchy-menu" && fail "cover closed: no menu"
reset; cover closed
has "$DPMS_ON" && fail "cover closed again, dark: it stays dark"
has "$DPMS_OFF" && fail "cover closed again, dark: nothing to turn off"
reset; cover opened
has "$DPMS_ON" || fail "cover opened, dark: the screen comes on"
has "$TOUCH_ON" || fail "cover opened, dark: the touchscreen comes on"
reset; cover opened
has "$DPMS_OFF" && fail "cover opened, lit: it stays lit"
has "$DPMS_ON" && fail "cover opened, lit: nothing to turn on"
dark; reset; cover opened
has "$DPMS_ON" || fail "cover opened on a screen Power turned off: the screen comes on"
lit; reset; ev $SW_TABLET_MODE 1 $EV_SW; sleep 0.4
[ ! -s "$log" ] || fail "another switch (SW_TABLET_MODE) does nothing"
has "omarchy-shell" && fail "the cover never goes home"
echo "ok - cover: closed turns screen and touchscreen off, opened on, only on a change; other switches ignored"

# --- idle (SIGUSR1 from t715-idle.service) -------------------------------------------------
lit; reset; kill -USR1 "$pid"; sleep 0.5
has "$TOUCH_OFF" || fail "idle, lit: the touchscreen goes off"
has "$DPMS_OFF" || fail "idle, lit: the screen goes off (DPMS)"
[ "$(line_of "$TOUCH_OFF")" -lt "$(line_of "$DPMS_OFF")" ] || fail "idle: the touchscreen goes off before the panel"
dark; reset; kill -USR1 "$pid"; sleep 0.5
has "$DPMS_OFF" && fail "idle, dark: nothing to turn off"
kill -0 "$pid" 2>/dev/null || fail "idle: t715-keys survives SIGUSR1"
echo "ok - idle: SIGUSR1 turns a lit screen off (touch first), a dark one is left alone"

# --- a glance (SIGUSR2 for a message, or a screen lit from outside) --------------------------
mkfifo "$t/touch"
exec 4<>"$t/touch"
start T715_KEYS_GLANCE=1 T715_KEYS_RESYNC=0.3 T715_KEYS_TOUCH="$t/touch"
dark; reset; kill -USR2 "$pid"; sleep 0.4
has "$DPMS_ON" || fail "glance: a message lights a dark screen"
has "$TOUCH_ON" || fail "glance: and the touchscreen"
sleep 1.1
has "$DPMS_OFF" || fail "glance: the screen goes off again by itself"
dark; reset; kill -USR2 "$pid"; sleep 0.4
echo x >&4
sleep 1.3
has "$DPMS_OFF" && fail "glance: a touch keeps the screen lit"
grep -q "touch: the glance ends" "$t/daemon.log" || fail "glance: the touch is seen"
lit; reset; kill -USR2 "$pid"; sleep 1.4
has "$DPMS_ON" && fail "glance: a lit screen is left as it is"
has "$DPMS_OFF" && fail "glance: a screen in use does not go off"
tap $K_POWER; [ "$(cat "$t/dpms")" = false ] || fail "glance: dark for the next check"
reset; lit; sleep 2
has "$TOUCH_ON" || fail "glance: lit from outside, the touchscreen comes back"
has "$DPMS_OFF" || fail "glance: lit from outside, the screen goes off again"
[ "$(cat "$t/dpms")" = false ] || fail "glance: dark for the inhibitor"
echo "idle:sleep" > "$t/inhibited"; reset; lit; sleep 2
has "$DPMS_OFF" && fail "glance: a call's idle inhibitor keeps the screen lit"
echo "sleep" > "$t/inhibited"; sleep 5.5
has "$DPMS_OFF" || fail "glance: the screen goes off once the call is over"
rm -f "$t/inhibited"
dark; reset; kill -USR2 "$pid"; sleep 0.2; tap $K_POWER; sleep 1.3
has "$DPMS_ON" || fail "glance: lit before the press"
reset; dark; cover closed; reset; kill -USR2 "$pid"; sleep 0.4
has "$DPMS_ON" && fail "glance: a closed cover stays dark"
cover opened
kill -0 "$pid" 2>/dev/null || fail "glance: t715-keys survives SIGUSR2"
echo "ok - glance: a message or an outside light turns the screen on for a moment, a touch or a call keeps it"

# --- Back and Recent, the touch keys -----------------------------------------------------------
K_BACK=158 K_RECENT=120
BACK_CALL='key = "code:9"'
start
lit; reset; press $K_BACK; sleep 0.3; release $K_BACK; sleep 0.3
eventually "$BACK_CALL" || fail "touch keys: Back goes back on a lit screen"
reset; press $K_RECENT; sleep 0.3; release $K_RECENT; sleep 0.3
eventually "$RECENTS" || fail "touch keys: Recent opens recent apps"
dark; reset; press $K_BACK; release $K_BACK; press $K_RECENT; release $K_RECENT; sleep 0.5
has "$BACK_CALL" && fail "touch keys: nothing on a dark screen"
has "$RECENTS" && fail "touch keys: nothing on a dark screen"
has "$DPMS_ON" && fail "touch keys: they never wake the screen"
lit; echo true > "$t/locked"; reset; press $K_BACK; release $K_BACK; sleep 0.4
has "$BACK_CALL" && fail "touch keys: nothing while locked"
rm -f "$t/locked"
echo "ok - touch keys: Back and Recent on a lit, unlocked screen, nothing otherwise"

PAGE_BACK='key = "code:166"'
for class in chromium chrome-example.org__-Default firefox; do
    echo "$class" > "$t/window-class"; reset; press $K_BACK; release $K_BACK; sleep 0.3
    eventually "$PAGE_BACK" || fail "touch keys: Back in $class is the previous page"
    has "$BACK_CALL" && fail "touch keys: no Escape in $class"
done
echo org.gnome.Nautilus > "$t/window-class"; reset; press $K_BACK; release $K_BACK; sleep 0.3
eventually "$BACK_CALL" || fail "touch keys: Back in another app is Escape"
has "$PAGE_BACK" && fail "touch keys: no page back in another app"
echo chromium > "$t/window-class"; opened omamobile-quicksettings; reset; press $K_BACK; release $K_BACK; sleep 0.3
eventually 'omarchy-shell shell hide omamobile.quicksettings' || fail "touch keys: Back over a sheet closes the sheet"
has "$PAGE_BACK" && fail "touch keys: a sheet over a browser takes Back"
has "$BACK_CALL" && fail "touch keys: no Escape over a sheet"
rm -f "$t/open-omamobile-quicksettings" "$t/window-class"
echo "ok - touch keys: Back closes a sheet, or is the previous page in a browser, or Escape elsewhere"

echo chromium > "$t/window-class"; reset; kill -HUP "$pid"; sleep 0.3
eventually "$PAGE_BACK" || fail "edge swipe: SIGHUP is Back"
dark; reset; kill -HUP "$pid"; sleep 0.4
has "$PAGE_BACK" && fail "edge swipe: nothing on a dark screen"
lit; echo true > "$t/locked"; reset; kill -HUP "$pid"; sleep 0.4
has "$PAGE_BACK" && fail "edge swipe: nothing while locked"
kill -0 "$pid" 2>/dev/null || fail "edge swipe: t715-keys survives SIGHUP"
rm -f "$t/locked" "$t/window-class"
echo "ok - edge swipe: SIGHUP is the Back key, under the same conditions"

# --- the lock, once a PIN is set -------------------------------------------------------------
lit; reset; tap $K_POWER
has "omarchy-system-lock" && fail "lock: no PIN, no lock"
lit
mkdir -p "$t/.local/state/omarchy/toggles"; : > "$t/.local/state/omarchy/toggles/lock-on-start"
reset; tap $K_POWER
has "omarchy-system-lock" || fail "lock: Power locks before the screen goes off"
[ "$(line_of "omarchy-system-lock")" -lt "$(line_of "$DPMS_OFF")" ] || fail "lock: locked before the panel goes dark"
reset; tap $K_POWER
has "omarchy-shell lock wake" || fail "lock: waking shows the PIN pad"
reset; kill -USR1 "$pid"; sleep 0.5
has "omarchy-system-lock" && fail "lock: already locked, not locked again"
rm -f "$t/locked"; lit; reset; kill -USR1 "$pid"; sleep 0.5
has "omarchy-system-lock" || fail "lock: idle locks too"
rm -f "$t/locked"; lit; reset; cover closed
has "omarchy-system-lock" || fail "lock: the cover locks too"
rm -f "$t/locked"; cover opened
# A shell that cannot lock: the screen stays lit, with its touchscreen.
: > "$t/lock-broken"; lit; reset; tap $K_POWER; sleep 2
has "$DPMS_OFF" && fail "lock: not locked, the screen stays on"
has "$TOUCH_ON" || fail "lock: not locked, the touchscreen comes back"
rm -f "$t/lock-broken" "$t/.local/state/omarchy/toggles/lock-on-start"
echo "ok - lock: with a PIN, every way off locks first, and waking shows the pad"

# --- hyprctl fails on a wake: the touchscreen must not stay off for good -----------------
start T715_KEYS_RESYNC=0.3
lit; tap $K_POWER
: > "$t/hypr-eval-down"; reset; tap $K_POWER; sleep 0.2
has "$TOUCH_ON" || fail "touch retry: the wake tries"
[ -n "$(find "$t" -name touch-off -print -quit)" ] || fail "touch retry: the flag stays"
rm -f "$t/hypr-eval-down"; reset; sleep 1
has "$TOUCH_ON" || fail "touch retry: the resync gets it back"
[ -z "$(find "$t" -name touch-off -print -quit)" ] || fail "touch retry: and the flag goes"
echo "ok - a touchscreen that did not follow stays flagged, for the resync"

# --- a key ends a glance whose touch fd is ready in the same batch ----------------------
start T715_KEYS_GLANCE=5 T715_KEYS_TOUCH="$t/touch"
dark; reset; kill -USR2 "$pid"; sleep 0.4
kill -STOP "$pid"
echo x >&4
press $K_POWER; release $K_POWER
kill -CONT "$pid"; sleep 0.6
grep -q "read: " "$t/daemon.log" && fail "glance: the touch fd the key closed is read"
reset; tap $K_POWER
has "$DPMS_OFF" || has "$DPMS_ON" || fail "glance: the daemon survives a key and a touch together"
echo "ok - a key and a touch in one batch during a glance"

stop
echo "PASS"
