#!/usr/bin/env bash
# test_t715_android.sh — off-device test of t715-android and its pieces
# (rootfs/overlay/usr/local/bin/t715-android, its user unit, and its
# enable line in rootfs/configure-system.sh).
#
# The script runs on this machine against fake Waydroid config/binder
# paths, a fake cgroup directory ($T715_ANDROID_CGROUP), and a temporary
# state directory with stand-ins first in PATH: busctl (exit code read
# from a file the test fills, or flipping to 0 after N calls), waydroid
# (fails the test if ever called with status; other calls logged),
# systemctl, hyprctl, omarchy-notification-send, logger and timeout.
# Host jq is used when available (apps count assertions skip cleanly
# when jq is missing). The user unit's keys and the global enable line
# in configure-system.sh are checked statically.
#
# Usage: tests/test_t715_android.sh
# Prints "ok - ..." per group, "PASS" at the end; exit 1 on the first
# failure (with what the stubs collected). Needs bash and /bin/sh; works
# with macOS's bash 3.2. Nothing outside a temporary directory.
#
# In the style of test_t715_sdcard.sh.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
AND="$here/rootfs/overlay/usr/local/bin/t715-android"
CONF="$here/rootfs/configure-system.sh"
UNIT="$here/rootfs/overlay/etc/systemd/user/t715-android.service"
[ -f "$AND" ] || { echo "SETUP ERROR: no $AND" >&2; exit 2; }

t=$(mktemp -d "${TMPDIR:-/tmp}/t715-android-test.XXXXXX")
cleanup() { rm -rf "$t"; }
trap cleanup EXIT

fail() {
    printf 'not ok - %s\n' "$1" >&2
    echo "--- notifications" >&2; cat "$t/notify" 2>/dev/null || true
    echo "--- log" >&2; cat "$t/log" 2>/dev/null || true
    echo "--- systemctl" >&2; cat "$t/systemctl" 2>/dev/null || true
    echo "--- busctl" >&2; cat "$t/busctl-log" 2>/dev/null || true
    echo "--- busctl calls" >&2; cat "$t/busctl-count" 2>/dev/null || true
    echo "--- cgroup.events" >&2; cat "$t/cgroup/cgroup.events" 2>/dev/null || true
    echo "--- waydroid" >&2; cat "$t/wd-log" 2>/dev/null || true
    echo "--- waydroid forbidden" >&2; cat "$t/wd-forbidden" 2>/dev/null || true
    echo "--- hyprctl" >&2; cat "$t/hyprctl" 2>/dev/null || true
    echo "--- timeout" >&2; cat "$t/timeout" 2>/dev/null || true
    exit 1
}

# --- stand-ins -----------------------------------------------------------------
mkdir -p "$t/bin" "$t/bus-bin" "$t/wd-bin" "$t/hostbin" "$t/dev" "$t/state" "$t/cgroup"

JQ_BIN=$(command -v jq 2>/dev/null || true)
if [ -n "$JQ_BIN" ]; then
    ln -s "$JQ_BIN" "$t/hostbin/jq"
fi

cat > "$t/bin/logger" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$T715_TEST_LOG"
STUB

cat > "$t/bin/omarchy-notification-send" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$T715_TEST_NOTIFY"
case " $* " in *" -p "*) echo 42 ;; esac
exit 0
STUB

cat > "$t/bin/systemctl" <<'STUB'
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "$T715_TEST_SYSTEMCTL"
if [ -n "${T715_TEST_SYSTEMCTL_CHECK_FILE:-}" ] && [ -f "$T715_TEST_SYSTEMCTL_CHECK_FILE" ]; then
    cp "$T715_TEST_SYSTEMCTL_CHECK_FILE" "$T715_TEST_SYSTEMCTL_SNAPSHOT"
fi
if [ -n "${T715_TEST_SYSTEMCTL_DROP_FILE:-}" ] && [ -n "${T715_TEST_SYSTEMCTL_DROP_SRC:-}" ]; then
    cp "$T715_TEST_SYSTEMCTL_DROP_SRC" "$T715_TEST_SYSTEMCTL_DROP_FILE"
fi
exit "${T715_TEST_SYSTEMCTL_RC:-0}"
STUB

cat > "$t/bin/hyprctl" <<'STUB'
#!/bin/sh
printf 'hyprctl %s\n' "$*" >> "$T715_TEST_HYPRCTL"
if [ -n "${T715_TEST_HYPRCTL_RC:-}" ]; then
    exit "$T715_TEST_HYPRCTL_RC"
fi
cat "$T715_TEST_CLIENTS"
exit 0
STUB

cat > "$t/bin/timeout" <<'STUB'
#!/bin/sh
printf 'timeout %s\n' "$*" >> "$T715_TEST_TIMEOUT"
shift
exec "$@"
STUB

cat > "$t/bus-bin/busctl" <<'STUB'
#!/bin/sh
printf 'busctl %s\n' "$*" >> "$T715_TEST_BUSCTL_LOG"
c=$(cat "$T715_TEST_BUSCTL_COUNT" 2>/dev/null || echo 0)
c=$((c + 1))
printf '%s\n' "$c" > "$T715_TEST_BUSCTL_COUNT"
if [ -n "${T715_TEST_BUSCTL_AFTER:-}" ] && [ "$c" -ge "$T715_TEST_BUSCTL_AFTER" ]; then
    exit 0
fi
rc=$(cat "$T715_TEST_BUSCTL_RC" 2>/dev/null || echo 1)
exit "${rc:-1}"
STUB

cat > "$t/wd-bin/waydroid" <<'STUB'
#!/bin/sh
if [ "${1:-}" = "status" ]; then
    printf 'FAIL: waydroid status must not be called\n' >&2
    printf 'waydroid %s\n' "$*" >> "$T715_TEST_WD_FORBIDDEN"
    printf 'waydroid %s\n' "$*" >> "$T715_TEST_WD_LOG"
    exit 99
fi
printf 'waydroid %s\n' "$*" >> "$T715_TEST_WD_LOG"
exit 0
STUB

chmod +x "$t/bin/"* "$t/bus-bin/busctl" "$t/wd-bin/waydroid"

export T715_TEST_LOG="$t/log" \
       T715_TEST_NOTIFY="$t/notify" \
       T715_TEST_SYSTEMCTL="$t/systemctl" \
       T715_TEST_SYSTEMCTL_RC="" \
       T715_TEST_SYSTEMCTL_CHECK_FILE="" \
       T715_TEST_SYSTEMCTL_SNAPSHOT="$t/systemctl-snapshot" \
       T715_TEST_SYSTEMCTL_DROP_FILE="" \
       T715_TEST_SYSTEMCTL_DROP_SRC="" \
       T715_TEST_HYPRCTL="$t/hyprctl" \
       T715_TEST_HYPRCTL_RC="" \
       T715_TEST_CLIENTS="$t/clients.json" \
       T715_TEST_TIMEOUT="$t/timeout" \
       T715_TEST_BUSCTL_LOG="$t/busctl-log" \
       T715_TEST_BUSCTL_RC="$t/busctl-rc" \
       T715_TEST_BUSCTL_COUNT="$t/busctl-count" \
       T715_TEST_BUSCTL_AFTER="" \
       T715_TEST_WD_LOG="$t/wd-log" \
       T715_TEST_WD_FORBIDDEN="$t/wd-forbidden"

clear_files() {
    [ ! -s "$t/wd-forbidden" ] || fail "waydroid status was called"
    : > "$t/log"
    : > "$t/notify"
    : > "$t/systemctl"
    rm -f "$t/systemctl-snapshot"
    : > "$t/hyprctl"
    : > "$t/timeout"
    : > "$t/busctl-log"
    printf '0\n' > "$t/busctl-count"
    : > "$t/wd-log"
    T715_TEST_SYSTEMCTL_RC=""
    T715_TEST_SYSTEMCTL_CHECK_FILE=""
    T715_TEST_SYSTEMCTL_DROP_FILE=""
    T715_TEST_SYSTEMCTL_DROP_SRC=""
    T715_TEST_HYPRCTL_RC=""
    T715_TEST_BUSCTL_AFTER=""
}

nlines() { [ "$(wc -l < "$1" | tr -d ' ')" = "$2" ]; }
busctl_calls() { cat "$t/busctl-count" | tr -d ' \n'; }

setup_installed() {
    rm -rf "${t:?}/dev" "${t:?}/state" "${t:?}/cgroup" "${t:?}/waydroid.cfg" \
           "${t:?}/xdg-data" "${t:?}/etc"
    mkdir -p "$t/dev" "$t/state"
    : > "$t/waydroid.cfg"
    : > "$t/dev/binder"
    printf '[]\n' > "$t/clients.json"
    clear_files
}

set_status_stopped() {
    printf '1\n' > "$t/busctl-rc"
    rm -rf "${t:?}/cgroup"
}

set_status_running() {
    printf '0\n' > "$t/busctl-rc"
    mkdir -p "$t/cgroup"
    printf 'populated 1\nfrozen 0\n' > "$t/cgroup/cgroup.events"
}

set_status_frozen() {
    printf '0\n' > "$t/busctl-rc"
    mkdir -p "$t/cgroup"
    printf 'populated 1\nfrozen 1\n' > "$t/cgroup/cgroup.events"
}

# run_and [args...]: run t715-android with stubs first in PATH (including busctl and waydroid).
run_and() {
    env T715_ANDROID_CFG="$t/waydroid.cfg" \
        T715_ANDROID_DEV="$t/dev" \
        T715_ANDROID_CGROUP="$t/cgroup" \
        T715_ANDROID_STATE_DIR="$t/state" \
        T715_ANDROID_ETC="$t/etc" \
        XDG_DATA_HOME="$t/xdg-data" \
        T715_ANDROID_WAIT="${T715_ANDROID_WAIT:-3}" \
        PATH="$t/bin:$t/bus-bin:$t/wd-bin:$t/hostbin:/usr/bin:/bin" \
        "$AND" "$@"
}

# run_and_no_wd [args...]: run t715-android without waydroid in PATH.
run_and_no_wd() {
    env T715_ANDROID_CFG="$t/waydroid.cfg" \
        T715_ANDROID_DEV="$t/dev" \
        T715_ANDROID_CGROUP="$t/cgroup" \
        T715_ANDROID_STATE_DIR="$t/state" \
        T715_ANDROID_ETC="$t/etc" \
        XDG_DATA_HOME="$t/xdg-data" \
        T715_ANDROID_WAIT="${T715_ANDROID_WAIT:-3}" \
        PATH="$t/bin:$t/bus-bin:$t/hostbin:/usr/bin:/bin" \
        "$AND" "$@"
}

# run_and_no_busctl [args...]: run t715-android without busctl in PATH.
run_and_no_busctl() {
    env T715_ANDROID_CFG="$t/waydroid.cfg" \
        T715_ANDROID_DEV="$t/dev" \
        T715_ANDROID_CGROUP="$t/cgroup" \
        T715_ANDROID_STATE_DIR="$t/state" \
        T715_ANDROID_ETC="$t/etc" \
        XDG_DATA_HOME="$t/xdg-data" \
        T715_ANDROID_WAIT="${T715_ANDROID_WAIT:-3}" \
        PATH="$t/bin:$t/wd-bin:$t/hostbin" \
        "$AND" "$@"
}

# --- (a) state: not installed for each of the three reasons --------------------
NOT_INSTALLED_OUT="installed=no
session=stopped
container=stopped
apps="

# (a1) missing waydroid command
setup_installed
set_status_running
out=$(run_and_no_wd state) || fail "(a1) state without waydroid exits 0"
[ "$out" = "$NOT_INSTALLED_OUT" ] || fail "(a1) missing waydroid state (got:
$out)"
[ "$(busctl_calls)" = 0 ] || fail "(a1) busctl not called when missing waydroid"
nlines "$t/timeout" 0 || fail "(a1) timeout not called when missing waydroid"
nlines "$t/hyprctl" 0 || fail "(a1) hyprctl not called when missing waydroid"
nlines "$t/wd-log" 0 || fail "(a1) waydroid not called"

# (a2) missing waydroid.cfg
setup_installed
rm -f "$t/waydroid.cfg"
set_status_running
out=$(run_and state) || fail "(a2) state without waydroid.cfg exits 0"
[ "$out" = "$NOT_INSTALLED_OUT" ] || fail "(a2) missing cfg state (got:
$out)"
[ "$(busctl_calls)" = 0 ] || fail "(a2) busctl not called without cfg"
nlines "$t/timeout" 0 || fail "(a2) timeout not called without cfg"
nlines "$t/hyprctl" 0 || fail "(a2) hyprctl not called without cfg"
nlines "$t/wd-log" 0 || fail "(a2) waydroid not called without cfg"

# (a3) missing /dev/binder
setup_installed
rm -f "$t/dev/binder"
set_status_running
out=$(run_and state) || fail "(a3) state without binder exits 0"
[ "$out" = "$NOT_INSTALLED_OUT" ] || fail "(a3) missing binder state (got:
$out)"
[ "$(busctl_calls)" = 0 ] || fail "(a3) busctl not called without binder"
nlines "$t/timeout" 0 || fail "(a3) timeout not called without binder"
nlines "$t/hyprctl" 0 || fail "(a3) hyprctl not called without binder"
nlines "$t/wd-log" 0 || fail "(a3) waydroid not called without binder"
echo "ok - state: not installed for each of the three reasons, nothing called"

# --- (b) state: stopped, running, frozen, busctl/cgroup edge cases -------------
setup_installed
set_status_stopped
out=$(run_and state) || fail "(b1) state when stopped exits 0"
[ "$out" = "installed=yes
session=stopped
container=stopped
apps=" ] || fail "(b1) stopped state (got:
$out)"
[ "$(busctl_calls)" = 1 ] || fail "(b1) exactly one busctl call (got: $(busctl_calls))"
grep -qx 'busctl --user status id.waydro.Session' "$t/busctl-log" \
    || fail "(b1) busctl queried id.waydro.Session on user bus"
grep -qx 'timeout 2 busctl --user status id.waydro.Session' "$t/timeout" \
    || fail "(b1) busctl bounded with timeout 2"
nlines "$t/hyprctl" 0 || fail "(b1) hyprctl not called when stopped"
nlines "$t/wd-log" 0 || fail "(b1) state ran no waydroid process"

setup_installed
set_status_running
out=$(run_and state) || fail "(b2) state when running exits 0"
[ "$(printf '%s\n' "$out" | sed -n '1,3p')" = "installed=yes
session=running
container=running" ] || fail "(b2) running state (got:
$out)"
[ "$(busctl_calls)" = 1 ] || fail "(b2) exactly one busctl call"
nlines "$t/wd-log" 0 || fail "(b2) state ran no waydroid process"

setup_installed
set_status_frozen
out=$(run_and state) || fail "(b3) state when frozen exits 0"
[ "$(printf '%s\n' "$out" | sed -n '1,3p')" = "installed=yes
session=running
container=frozen" ] || fail "(b3) frozen state (got:
$out)"
nlines "$t/wd-log" 0 || fail "(b3) state ran no waydroid process"

setup_installed
set_status_frozen
printf '2\n' > "$t/busctl-rc"
out=$(run_and state) || fail "(b4) state when busctl fails exits 0"
[ "$out" = "installed=yes
session=stopped
container=stopped
apps=" ] || fail "(b4) failed busctl treated as stopped even with populated cgroup (got:
$out)"
nlines "$t/wd-log" 0 || fail "(b4) state ran no waydroid process"

setup_installed
set_status_running
rm -rf "${t:?}/cgroup"
out=$(run_and state) || fail "(b5) state with missing cgroup dir exits 0"
[ "$(printf '%s\n' "$out" | sed -n '1,3p')" = "installed=yes
session=running
container=stopped" ] || fail "(b5) missing cgroup dir gives container=stopped (got:
$out)"
nlines "$t/wd-log" 0 || fail "(b5) state ran no waydroid process"

setup_installed
set_status_running
printf 'populated 0\nfrozen 0\n' > "$t/cgroup/cgroup.events"
out=$(run_and state) || fail "(b6a) state with populated 0 exits 0"
[ "$(printf '%s\n' "$out" | sed -n '1,3p')" = "installed=yes
session=running
container=stopped" ] || fail "(b6a) populated 0 gives container=stopped (got:
$out)"
printf 'populated 0\nfrozen 1\n' > "$t/cgroup/cgroup.events"
out=$(run_and state) || fail "(b6b) state with populated 0 and frozen 1 exits 0"
[ "$(printf '%s\n' "$out" | sed -n '1,3p')" = "installed=yes
session=running
container=stopped" ] || fail "(b6b) populated 0 and frozen 1 gives container=stopped (got:
$out)"
nlines "$t/wd-log" 0 || fail "(b6) state ran no waydroid process"

setup_installed
set_status_running
out=$(run_and_no_busctl state) || fail "(b7) state without busctl exits 0"
[ "$out" = "installed=yes
session=stopped
container=stopped
apps=" ] || fail "(b7) missing busctl gives session=stopped container=stopped (got:
$out)"
nlines "$t/timeout" 0 || fail "(b7) timeout not called when busctl is missing"
nlines "$t/hyprctl" 0 || fail "(b7) hyprctl not called when busctl is missing"
nlines "$t/wd-log" 0 || fail "(b7) state ran no waydroid process"
echo "ok - state: stopped, running, frozen, busctl failure/missing, and cgroup edge cases (no waydroid)"

# --- (c) state: apps count -----------------------------------------------------
if [ -n "$JQ_BIN" ]; then
    setup_installed
    set_status_running
    cat > "$t/clients.json" <<'JSON'
[
  {"class": "kitty", "title": "term"},
  {"class": "waydroid.com.android.settings", "title": "Settings"},
  {"class": "org.gnome.Nautilus", "title": "Files"},
  {"class": "waydroid.org.fdroid.fdroid", "title": "F-Droid"},
  {"class": "waydroid", "title": "not-a-dotted-prefix"}
]
JSON
    out=$(run_and state) || fail "(c1) state with two waydroid clients exits 0"
    [ "$out" = "installed=yes
session=running
container=running
apps=2" ] || fail "(c1) two waydroid.* clients counted (got:
$out)"
    grep -qx 'hyprctl clients -j' "$t/hyprctl" || fail "(c1) hyprctl clients -j called"
    nlines "$t/wd-log" 0 || fail "(c1) state ran no waydroid process"

    clear_files
    T715_TEST_HYPRCTL_RC=1
    out=$(run_and state) || fail "(c2) state when hyprctl fails exits 0"
    [ "$(printf '%s\n' "$out" | sed -n '4p')" = "apps=" ] || fail "(c2) apps empty on hyprctl failure (got:
$out)"
    nlines "$t/wd-log" 0 || fail "(c2) state ran no waydroid process"
    echo "ok - state: apps count with two waydroid.* clients, empty on hyprctl failure"
else
    echo "skip - state: apps count assertions (jq not installed on host)"
fi

# --- (d) start: when stopped (marker removed, systemctl start, polled) ---------
setup_installed
set_status_stopped
: > "$t/state/off"
T715_TEST_BUSCTL_AFTER=3
T715_ANDROID_WAIT=3 run_and start >/dev/null 2>&1 || fail "(d) start from stopped exits 0"
[ ! -e "$t/state/off" ] || fail "(d) off marker removed by start"
grep -qx 'systemctl --user start t715-android.service' "$t/systemctl" \
    || fail "(d) systemctl --user start called"
nlines "$t/systemctl" 1 || fail "(d) exactly one systemctl call"
[ "$(busctl_calls)" = 3 ] || fail "(d) polled busctl until running (calls: $(busctl_calls))"
grep -q -- '-t t715-android' "$t/log" || fail "(d) logger called with -t t715-android"
nlines "$t/log" 1 || fail "(d) one log line for start transition"
nlines "$t/notify" 0 || fail "(d) no error notification on successful start"
echo "ok - start: marker removed, systemctl start called, polled until RUNNING"

# --- (e) start: already running (no systemctl call) ----------------------------
setup_installed
set_status_running
run_and start >/dev/null 2>&1 || fail "(e) start when already running exits 0"
nlines "$t/systemctl" 0 || fail "(e) no systemctl call when already running"
nlines "$t/notify" 0 || fail "(e) no notification when already running"
nlines "$t/log" 0 || fail "(e) no transition log when already running"
echo "ok - start: already running is a no-op, no systemctl call"

# --- (f) start: timeout and not installed (exit 1, stderr, one notification) ---
setup_installed
set_status_stopped
err=$(T715_ANDROID_WAIT=2 run_and start 2>&1 >/dev/null; echo "RC=$?")
case "$err" in
*"RC=1"*) ;;
*) fail "(f1) start timeout exits 1 (got: $err)" ;;
esac
[ -n "${err%RC=1}" ] || fail "(f1) start timeout writes to stderr"
nlines "$t/notify" 1 || fail "(f1) exactly one notification on timeout"
grep -q -- '-p -r 0 -u normal' "$t/notify" || fail "(f1) notification uses omarchy-notification-send form"

setup_installed
rm -f "$t/waydroid.cfg"
err=$(run_and start 2>&1 >/dev/null; echo "RC=$?")
case "$err" in
*"RC=1"*) ;;
*) fail "(f2) start when not installed exits 1 (got: $err)" ;;
esac
[ -n "${err%RC=1}" ] || fail "(f2) start when not installed writes to stderr"
nlines "$t/notify" 1 || fail "(f2) one notification when not installed"
nlines "$t/systemctl" 0 || fail "(f2) no systemctl call when not installed"
echo "ok - start: timeout and not installed exit 1 with stderr and one notification"

# --- (g) stop: marker created, systemctl stop, exits 0 also when stopped -------
setup_installed
set_status_running
rm -rf "$t/state"
run_and stop >/dev/null 2>&1 || fail "(g1) stop exits 0"
[ -f "$t/state/off" ] || fail "(g1) off marker created (including state dir)"
grep -qx 'systemctl --user stop t715-android.service' "$t/systemctl" \
    || fail "(g1) systemctl --user stop called"
grep -q -- '-t t715-android' "$t/log" || fail "(g1) logger called for stop"
nlines "$t/log" 1 || fail "(g1) one log line for stop"

setup_installed
set_status_stopped
run_and stop >/dev/null 2>&1 || fail "(g2) stop when already stopped exits 0"
[ -f "$t/state/off" ] || fail "(g2) off marker created when already stopped"
grep -qx 'systemctl --user stop t715-android.service' "$t/systemctl" \
    || fail "(g2) systemctl --user stop called when already stopped"
echo "ok - stop: off marker created, systemctl stop called, exits 0 when stopped"

# --- (h) toggle: both ways -----------------------------------------------------
setup_installed
set_status_running
run_and toggle >/dev/null 2>&1 || fail "(h1) toggle from running exits 0"
[ -f "$t/state/off" ] || fail "(h1) toggle from running creates off marker"
grep -qx 'systemctl --user stop t715-android.service' "$t/systemctl" \
    || fail "(h1) toggle from running stops unit"

setup_installed
set_status_stopped
: > "$t/state/off"
T715_TEST_BUSCTL_AFTER=2
T715_ANDROID_WAIT=3 run_and toggle >/dev/null 2>&1 || fail "(h2) toggle from stopped exits 0"
[ ! -e "$t/state/off" ] || fail "(h2) toggle from stopped removes off marker"
grep -qx 'systemctl --user start t715-android.service' "$t/systemctl" \
    || fail "(h2) toggle from stopped starts unit"
echo "ok - toggle: running stops, stopped starts"

# --- (i) settings: launches com.android.settings (starts first when stopped) ---
setup_installed
set_status_running
run_and settings >/dev/null 2>&1 || fail "(i1) settings when running exits 0"
nlines "$t/systemctl" 0 || fail "(i1) settings does not restart a running session"
grep -qx 'waydroid app launch com.android.settings' "$t/wd-log" \
    || fail "(i1) settings launches com.android.settings"

setup_installed
set_status_stopped
T715_TEST_BUSCTL_AFTER=2
T715_ANDROID_WAIT=3 run_and settings >/dev/null 2>&1 || fail "(i2) settings when stopped starts then launches"
grep -qx 'systemctl --user start t715-android.service' "$t/systemctl" \
    || fail "(i2) settings started the session first"
grep -qx 'waydroid app launch com.android.settings' "$t/wd-log" \
    || fail "(i2) settings launched com.android.settings after start"

setup_installed
set_status_stopped
T715_ANDROID_WAIT=1 run_and settings >/dev/null 2>&1 && fail "(i3) settings fails if start fails"
nlines "$t/wd-log" 0 || fail "(i3) app launch not called when start fails"

# (i4) settings routed through the real /usr/local/bin/waydroid wrapper in PATH
setup_installed
set_status_running
mkdir -p "$t/wrap-bin"
ln -sf "$here/rootfs/overlay/usr/local/bin/waydroid" "$t/wrap-bin/waydroid"
env T715_ANDROID_CFG="$t/waydroid.cfg" \
    T715_ANDROID_DEV="$t/dev" \
    T715_ANDROID_CGROUP="$t/cgroup" \
    T715_ANDROID_STATE_DIR="$t/state" \
    T715_ANDROID_ETC="$t/etc" \
    XDG_DATA_HOME="$t/xdg-data" \
    XDG_RUNTIME_DIR="$t/rt-none" \
    T715_ANDROID_REAL_WAYDROID="$t/wd-bin/waydroid" \
    PATH="$t/wrap-bin:$t/bin:$t/bus-bin:$t/hostbin:/usr/bin:/bin" \
    "$AND" settings >/dev/null 2>&1 || fail "(i4) settings through waydroid wrapper exits 0"
grep -qx 'waydroid app launch com.android.settings' "$t/wd-log" \
    || fail "(i4) settings through wrapper reaches waydroid app launch com.android.settings"
echo "ok - settings: launches com.android.settings, starting first when stopped, works through wrapper"

# --- (j) apps: visibility apply, list, overrides, start integration ------------
APPS="$t/xdg-data/applications"

# (j0) no applications directory
setup_installed
out=$(run_and apps 2>"$t/apps-err") || fail "(j0a) apps without applications dir exits 0"
[ ! -s "$t/apps-err" ] || fail "(j0a) apps without applications dir writes nothing to stderr"
[ -n "$out" ] || fail "(j0a) apps without applications dir prints a message"
[ ! -d "$APPS" ] || fail "(j0a) apps does not create missing applications dir"
list_out=$(run_and apps list 2>"$t/apps-err") || fail "(j0b) apps list without dir exits 0"
[ -z "$list_out" ] || fail "(j0b) apps list without dir prints nothing (got: $list_out)"

# Empty applications directory with only a non-waydroid desktop file
mkdir -p "$APPS"
cat > "$APPS/org.gnome.Nautilus.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Linux Files
NoDisplay=true
DESKTOP
cp "$APPS/org.gnome.Nautilus.desktop" "$t/nautilus.orig"
out=$(run_and apps apply 2>"$t/apps-err") || fail "(j0c) apps with no waydroid files exits 0"
[ -n "$out" ] || fail "(j0c) apps with no waydroid files prints a message"
cmp -s "$t/nautilus.orig" "$APPS/org.gnome.Nautilus.desktop" || fail "(j0c) non-waydroid file untouched"

# (j1) fixture desktop files covering all editing edge cases
# 1. SHOW package with existing NoDisplay=true
cat > "$APPS/waydroid.com.android.documentsui.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Files
Exec=waydroid app launch com.android.documentsui
Icon=/var/lib/waydroid/data/icons/com.android.documentsui.png
NoDisplay=true
Categories=X-WayDroid-App;
DESKTOP

# 2. SHOW package with two groups and NoDisplay=true ONLY in the action group
cat > "$APPS/waydroid.org.lineageos.jelly.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Browser
Exec=waydroid app launch org.lineageos.jelly

[Desktop Action new-tab]
Name=New Tab
NoDisplay=true
Exec=waydroid app launch org.lineageos.jelly
DESKTOP

# 3. HIDE package with NO NoDisplay key at all
cat > "$APPS/waydroid.org.lineageos.aperture.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Camera
Exec=waydroid app launch org.lineageos.aperture
DESKTOP

# 4. HIDE package (Google) with NoDisplay=false
cat > "$APPS/waydroid.com.google.android.dialer.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Phone
NoDisplay=false
Exec=waydroid app launch com.google.android.dialer
DESKTOP

# 5. SHOW package already correct -> mtime must stay unchanged
cat > "$APPS/waydroid.com.android.settings.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Settings
NoDisplay=false
Exec=waydroid app launch com.android.settings
DESKTOP
cp "$APPS/waydroid.com.android.settings.desktop" "$t/settings.orig"
touch -t 202001010000 "$APPS/waydroid.com.android.settings.desktop" "$t/ref-mtime"

# 6. Non-listed package -> completely untouched (content and mtime)
cat > "$APPS/waydroid.org.fdroid.fdroid.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=F-Droid
Exec=waydroid app launch org.fdroid.fdroid
DESKTOP
cp "$APPS/waydroid.org.fdroid.fdroid.desktop" "$t/fdroid.orig"
touch -t 202001010000 "$APPS/waydroid.org.fdroid.fdroid.desktop"

out=$(run_and apps 2>"$t/apps-err") || fail "(j1) apps exits 0"
[ ! -s "$t/apps-err" ] || fail "(j1) apps writes nothing to stderr (got: $(cat "$t/apps-err"))"
printf '%s\n' "$out" > "$t/apps-out"
nlines "$t/apps-out" 4 || fail "(j1) four changed lines printed (got:
$out)"
grep -Fqx 'shown Files (com.android.documentsui)' "$t/apps-out" \
    || fail "(j1) reported shown Files (got: $out)"
grep -Fqx 'shown Browser (org.lineageos.jelly)' "$t/apps-out" \
    || fail "(j1) reported shown Browser (got: $out)"
grep -Fqx 'hidden Camera (org.lineageos.aperture)' "$t/apps-out" \
    || fail "(j1) reported hidden Camera (got: $out)"
grep -Fqx 'hidden Phone (com.google.android.dialer)' "$t/apps-out" \
    || fail "(j1) reported hidden Phone (got: $out)"

# Verify documentsui: NoDisplay replaced in place, other keys preserved
want_docs='[Desktop Entry]
Type=Application
Name=Files
Exec=waydroid app launch com.android.documentsui
Icon=/var/lib/waydroid/data/icons/com.android.documentsui.png
NoDisplay=false
Categories=X-WayDroid-App;'
[ "$(cat "$APPS/waydroid.com.android.documentsui.desktop")" = "$want_docs" ] \
    || fail "(j1) documentsui desktop content mismatch"

# Verify jelly: NoDisplay=false added right after [Desktop Entry], action group untouched
want_jelly='[Desktop Entry]
NoDisplay=false
Type=Application
Name=Browser
Exec=waydroid app launch org.lineageos.jelly

[Desktop Action new-tab]
Name=New Tab
NoDisplay=true
Exec=waydroid app launch org.lineageos.jelly'
[ "$(cat "$APPS/waydroid.org.lineageos.jelly.desktop")" = "$want_jelly" ] \
    || fail "(j1) jelly two-group desktop content mismatch (got:
$(cat "$APPS/waydroid.org.lineageos.jelly.desktop"))"

# Verify aperture: NoDisplay=true added right after [Desktop Entry]
want_aperture='[Desktop Entry]
NoDisplay=true
Type=Application
Name=Camera
Exec=waydroid app launch org.lineageos.aperture'
[ "$(cat "$APPS/waydroid.org.lineageos.aperture.desktop")" = "$want_aperture" ] \
    || fail "(j1) aperture desktop content mismatch"

# Verify dialer: NoDisplay=false replaced with NoDisplay=true
want_dialer='[Desktop Entry]
Type=Application
Name=Phone
NoDisplay=true
Exec=waydroid app launch com.google.android.dialer'
[ "$(cat "$APPS/waydroid.com.google.android.dialer.desktop")" = "$want_dialer" ] \
    || fail "(j1) dialer desktop content mismatch"

# Verify already-correct settings: mtime and content unchanged
cmp -s "$t/settings.orig" "$APPS/waydroid.com.android.settings.desktop" \
    || fail "(j1) already-correct settings content changed"
[ ! "$APPS/waydroid.com.android.settings.desktop" -nt "$t/ref-mtime" ] \
    && [ ! "$APPS/waydroid.com.android.settings.desktop" -ot "$t/ref-mtime" ] \
    || fail "(j1) already-correct settings mtime changed"

# Verify non-listed package and non-waydroid file: completely untouched
cmp -s "$t/fdroid.orig" "$APPS/waydroid.org.fdroid.fdroid.desktop" \
    || fail "(j1) non-listed package content changed"
[ ! "$APPS/waydroid.org.fdroid.fdroid.desktop" -nt "$t/ref-mtime" ] \
    && [ ! "$APPS/waydroid.org.fdroid.fdroid.desktop" -ot "$t/ref-mtime" ] \
    || fail "(j1) non-listed package mtime changed"
cmp -s "$t/nautilus.orig" "$APPS/org.gnome.Nautilus.desktop" \
    || fail "(j1) non-waydroid desktop file changed"

# Second run -> nothing to change, no mtimes bumped
touch -t 202001010000 "$APPS/waydroid.com.android.documentsui.desktop"
out2=$(run_and apps apply 2>"$t/apps-err") || fail "(j1b) second apps apply exits 0"
[ "$out2" = "nothing to change" ] || fail "(j1b) second run says 'nothing to change' (got: $out2)"
[ ! "$APPS/waydroid.com.android.documentsui.desktop" -nt "$t/ref-mtime" ] \
    || fail "(j1b) second run touched already-correct file mtime"

# (j2) apps list: tab-separated shown|hidden, package, Name sorted by Name
tab=$(printf '\t')
list_out=$(run_and apps list 2>"$t/apps-err") || fail "(j2) apps list exits 0"
[ ! -s "$t/apps-err" ] || fail "(j2) apps list writes nothing to stderr"
want_list="shown${tab}org.lineageos.jelly${tab}Browser
hidden${tab}org.lineageos.aperture${tab}Camera
shown${tab}org.fdroid.fdroid${tab}F-Droid
shown${tab}com.android.documentsui${tab}Files
hidden${tab}com.google.android.dialer${tab}Phone
shown${tab}com.android.settings${tab}Settings"
[ "$list_out" = "$want_list" ] || fail "(j2) apps list mismatch (got:
$list_out)"

# (j3) override files in T715_ANDROID_ETC (with # comments and blank lines)
mkdir -p "$t/etc"
cat > "$t/etc/apps-show" <<'OVR'
# Show Camera instead of defaults
  org.lineageos.aperture  # inline comment

OVR
cat > "$t/etc/apps-hide" <<'OVR'
# Hide Files
com.android.documentsui
OVR
out_ovr=$(run_and apps 2>"$t/apps-err") || fail "(j3) apps with override files exits 0"
printf '%s\n' "$out_ovr" > "$t/apps-out"
nlines "$t/apps-out" 2 || fail "(j3) override changed exactly two files (got:
$out_ovr)"
grep -Fqx 'hidden Files (com.android.documentsui)' "$t/apps-out" \
    || fail "(j3) override hid Files"
grep -Fqx 'shown Camera (org.lineageos.aperture)' "$t/apps-out" \
    || fail "(j3) override showed Camera"
grep -qx 'NoDisplay=false' "$APPS/waydroid.org.lineageos.aperture.desktop" \
    || fail "(j3) aperture desktop now NoDisplay=false"
grep -qx 'NoDisplay=true' "$APPS/waydroid.com.android.documentsui.desktop" \
    || fail "(j3) documentsui desktop now NoDisplay=true"
# Settings was not in override apps-show or apps-hide, so it stayed untouched
grep -qx 'NoDisplay=false' "$APPS/waydroid.com.android.settings.desktop" \
    || fail "(j3) settings stayed untouched under override"
# Single-file override (only apps-hide exists): overrides default SHOW for Browser
rm -f "$t/etc/apps-show"
printf 'org.lineageos.jelly\n' > "$t/etc/apps-hide"
out_ovr2=$(run_and apps 2>"$t/apps-err") || fail "(j3b) single override exits 0"
printf '%s\n' "$out_ovr2" > "$t/apps-out"
grep -Fqx 'hidden Browser (org.lineageos.jelly)' "$t/apps-out" \
    || fail "(j3b) single apps-hide override hid Browser (got: $out_ovr2)"
grep -Fqx 'shown Files (com.android.documentsui)' "$t/apps-out" \
    || fail "(j3b) removing apps-show restored default SHOW for Files"

# (j4) start runs apply silently before starting and again once session is running
setup_installed
set_status_stopped
mkdir -p "$APPS"
cat > "$APPS/waydroid.com.android.documentsui.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Files
NoDisplay=true
DESKTOP
cat > "$t/drop-camera.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Camera
NoDisplay=false
DESKTOP
T715_TEST_SYSTEMCTL_CHECK_FILE="$APPS/waydroid.com.android.documentsui.desktop"
T715_TEST_SYSTEMCTL_DROP_FILE="$APPS/waydroid.org.lineageos.aperture.desktop"
T715_TEST_SYSTEMCTL_DROP_SRC="$t/drop-camera.desktop"
T715_TEST_BUSCTL_AFTER=2
start_out=$(T715_ANDROID_WAIT=3 run_and start 2>"$t/start-err") || fail "(j4) start exits 0"
[ -z "$start_out" ] || fail "(j4) start apply is silent on stdout (got: $start_out)"
[ ! -s "$t/start-err" ] || fail "(j4) start apply is silent on stderr (got: $(cat "$t/start-err"))"
grep -qx 'NoDisplay=false' "$t/systemctl-snapshot" \
    || fail "(j4) documentsui was already updated BEFORE systemctl start"
grep -qx 'NoDisplay=true' "$APPS/waydroid.org.lineageos.aperture.desktop" \
    || fail "(j4) newly appeared camera desktop was updated AFTER session running"

# state must not modify desktop files or call waydroid
cat > "$APPS/waydroid.com.android.documentsui.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Files
NoDisplay=true
DESKTOP
set_status_running
clear_files
run_and state >/dev/null || fail "(j4b) state exits 0"
grep -qx 'NoDisplay=true' "$APPS/waydroid.com.android.documentsui.desktop" \
    || fail "(j4b) state did not touch desktop files"
nlines "$t/wd-log" 0 || fail "(j4b) state called no waydroid"
echo "ok - apps: apply, two-group/missing/unchanged/unlisted fixtures, overrides, list, silent start hook"

# --- (k) usage and exit codes --------------------------------------------------
run_and frobnicate >/dev/null 2>&1 && fail "(k1) unknown verb exits nonzero"
[ "$(run_and frobnicate >/dev/null 2>&1; echo $?)" = 2 ] || fail "(k1) unknown verb exits 2"
run_and >/dev/null 2>&1 && fail "(k2) no argument exits nonzero"
[ "$(run_and 2>/dev/null; echo $?)" = 2 ] || fail "(k2) no argument exits 2"
case "$(run_and 2>&1 >/dev/null)" in
usage:*) ;;
*) fail "(k3) usage goes to stderr on no argument" ;;
esac
help_out=$(run_and --help 2>/dev/null) || fail "(k4) --help exits 0"
case "$help_out" in
usage:*apps*) ;;
*) fail "(k4) --help prints usage including apps on stdout (got: $help_out)" ;;
esac
help_short=$(run_and -h 2>/dev/null) || fail "(k5) -h exits 0"
case "$help_short" in
usage:*) ;;
*) fail "(k5) -h prints usage on stdout (got: $help_short)" ;;
esac
[ "$(run_and apps bogus >/dev/null 2>&1; echo $?)" = 2 ] || fail "(k6) apps bogus exits 2"
[ "$(run_and apps list extra >/dev/null 2>&1; echo $?)" = 2 ] || fail "(k7) apps list extra exits 2"
[ "$(run_and state extra >/dev/null 2>&1; echo $?)" = 2 ] || fail "(k8) state extra exits 2"
echo "ok - usage: --help/-h exit 0 on stdout, missing/unknown/bad apps args exit 2 on stderr"

# --- (l) user unit and configure-system.sh, statically -------------------------
[ -f "$UNIT" ] || fail "(k) no $UNIT"
head -n1 "$UNIT" | grep -q '^#' || fail "(k) unit carries a header comment"
grep -qx 'Description=.*' "$UNIT" || fail "(k) Description= missing"
grep -qx 'PartOf=graphical-session.target' "$UNIT" || fail "(k) PartOf= missing"
grep -qx 'After=graphical-session.target' "$UNIT" || fail "(k) After= missing"
grep -qx 'ConditionPathExists=/var/lib/waydroid/waydroid.cfg' "$UNIT" \
    || fail "(k) ConditionPathExists=waydroid.cfg missing"
grep -qx 'ConditionPathExists=/dev/binder' "$UNIT" \
    || fail "(k) ConditionPathExists=/dev/binder missing"
grep -qx 'ConditionPathExists=!%h/.local/state/t715-android/off' "$UNIT" \
    || fail "(k) ConditionPathExists=!off missing"
grep -qx 'ExecStart=/usr/bin/waydroid session start' "$UNIT" || fail "(k) ExecStart= missing"
grep -qx 'ExecStop=/usr/bin/waydroid session stop' "$UNIT" || fail "(k) ExecStop= missing"
grep -qx 'Restart=no' "$UNIT" || fail "(k) Restart=no missing"
grep -qx 'TimeoutStopSec=30' "$UNIT" || fail "(k) TimeoutStopSec=30 missing"
grep -qx 'WantedBy=graphical-session.target' "$UNIT" || fail "(k) WantedBy= missing"
grep -Fqx '[ -x /usr/local/bin/t715-android ] || die "no /usr/local/bin/t715-android"' "$CONF" \
    || fail "(k) configure-system.sh checks for t715-android"
grep -qx 'systemctl --global enable t715-android.service' "$CONF" \
    || fail "(k) configure-system.sh enables t715-android.service globally"
echo "ok - user unit keys and configure-system.sh global enable"

[ ! -s "$t/wd-forbidden" ] || fail "waydroid status was called"
echo "PASS"
