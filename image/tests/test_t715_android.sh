#!/usr/bin/env bash
# test_t715_android.sh — off-device test of t715-android and its pieces
# (rootfs/overlay/usr/local/bin/t715-android, its user unit, and its
# enable line in rootfs/configure-system.sh).
#
# The script runs on this machine against fake Waydroid config/binder
# paths and a temporary state directory with stand-ins first in PATH:
# waydroid (status answered from a file the test fills, or flipping to
# RUNNING after N calls; other calls logged), systemctl, hyprctl,
# omarchy-notification-send, logger and timeout. Host jq is used when
# available (apps count assertions skip cleanly when jq is missing).
# The user unit's keys and the global enable line in configure-system.sh
# are checked statically.
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
    echo "--- waydroid" >&2; cat "$t/wd-log" 2>/dev/null || true
    echo "--- waydroid status calls" >&2; cat "$t/wd-count" 2>/dev/null || true
    echo "--- hyprctl" >&2; cat "$t/hyprctl" 2>/dev/null || true
    echo "--- timeout" >&2; cat "$t/timeout" 2>/dev/null || true
    exit 1
}

# --- stand-ins -----------------------------------------------------------------
mkdir -p "$t/bin" "$t/wd-bin" "$t/hostbin" "$t/dev" "$t/state"

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

cat > "$t/wd-bin/waydroid" <<'STUB'
#!/bin/sh
if [ "${1:-}" = "status" ]; then
    c=$(cat "$T715_TEST_WD_COUNT" 2>/dev/null || echo 0)
    c=$((c + 1))
    printf '%s\n' "$c" > "$T715_TEST_WD_COUNT"
    if [ -n "${T715_TEST_WD_AFTER:-}" ] && [ "$c" -ge "$T715_TEST_WD_AFTER" ]; then
        printf 'Session:\tRUNNING\nContainer:\tRUNNING\nVendor type:\tMAINLINE\n'
        exit 0
    fi
    if [ -n "${T715_TEST_WD_RC:-}" ]; then
        printf 'ERROR: Waydroid is not initialized, run "waydroid init"\n' >&2
        exit "$T715_TEST_WD_RC"
    fi
    cat "$T715_TEST_WD_STATUS"
    exit 0
fi
printf 'waydroid %s\n' "$*" >> "$T715_TEST_WD_LOG"
exit 0
STUB

chmod +x "$t/bin/"* "$t/wd-bin/waydroid"

export T715_TEST_LOG="$t/log" \
       T715_TEST_NOTIFY="$t/notify" \
       T715_TEST_SYSTEMCTL="$t/systemctl" \
       T715_TEST_SYSTEMCTL_RC="" \
       T715_TEST_HYPRCTL="$t/hyprctl" \
       T715_TEST_HYPRCTL_RC="" \
       T715_TEST_CLIENTS="$t/clients.json" \
       T715_TEST_TIMEOUT="$t/timeout" \
       T715_TEST_WD_LOG="$t/wd-log" \
       T715_TEST_WD_STATUS="$t/wd-status" \
       T715_TEST_WD_COUNT="$t/wd-count" \
       T715_TEST_WD_AFTER="" \
       T715_TEST_WD_RC=""

clear_files() {
    : > "$t/log"
    : > "$t/notify"
    : > "$t/systemctl"
    : > "$t/hyprctl"
    : > "$t/timeout"
    : > "$t/wd-log"
    printf '0\n' > "$t/wd-count"
    T715_TEST_SYSTEMCTL_RC=""
    T715_TEST_HYPRCTL_RC=""
    T715_TEST_WD_AFTER=""
    T715_TEST_WD_RC=""
}

nlines() { [ "$(wc -l < "$1" | tr -d ' ')" = "$2" ]; }
wd_calls() { cat "$t/wd-count" | tr -d ' \n'; }

setup_installed() {
    rm -rf "${t:?}/dev" "${t:?}/state" "${t:?}/waydroid.cfg"
    mkdir -p "$t/dev" "$t/state"
    : > "$t/waydroid.cfg"
    : > "$t/dev/binder"
    printf '[]\n' > "$t/clients.json"
    clear_files
}

set_status_stopped() {
    printf 'Session:\tSTOPPED\nVendor type:\tMAINLINE\n' > "$t/wd-status"
}

set_status_running() {
    printf 'Session:\tRUNNING\nContainer:\tRUNNING\nVendor type:\tMAINLINE\nWayland display:\twayland-1\n' > "$t/wd-status"
}

set_status_frozen() {
    printf 'Session:\tRUNNING\nContainer:\tFROZEN\nVendor type:\tMAINLINE\n' > "$t/wd-status"
}

# run_and [args...]: run t715-android with stubs first in PATH (including waydroid).
run_and() {
    env T715_ANDROID_CFG="$t/waydroid.cfg" \
        T715_ANDROID_DEV="$t/dev" \
        T715_ANDROID_STATE_DIR="$t/state" \
        T715_ANDROID_WAIT="${T715_ANDROID_WAIT:-3}" \
        PATH="$t/bin:$t/wd-bin:$t/hostbin:/usr/bin:/bin" \
        "$AND" "$@"
}

# run_and_no_wd [args...]: run t715-android without waydroid in PATH.
run_and_no_wd() {
    env T715_ANDROID_CFG="$t/waydroid.cfg" \
        T715_ANDROID_DEV="$t/dev" \
        T715_ANDROID_STATE_DIR="$t/state" \
        T715_ANDROID_WAIT="${T715_ANDROID_WAIT:-3}" \
        PATH="$t/bin:$t/hostbin:/usr/bin:/bin" \
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
[ "$(wd_calls)" = 0 ] || fail "(a1) waydroid not called when missing"
nlines "$t/timeout" 0 || fail "(a1) timeout not called when missing waydroid"
nlines "$t/hyprctl" 0 || fail "(a1) hyprctl not called when missing waydroid"

# (a2) missing waydroid.cfg
setup_installed
rm -f "$t/waydroid.cfg"
set_status_running
out=$(run_and state) || fail "(a2) state without waydroid.cfg exits 0"
[ "$out" = "$NOT_INSTALLED_OUT" ] || fail "(a2) missing cfg state (got:
$out)"
[ "$(wd_calls)" = 0 ] || fail "(a2) waydroid not called without cfg"
nlines "$t/timeout" 0 || fail "(a2) timeout not called without cfg"
nlines "$t/hyprctl" 0 || fail "(a2) hyprctl not called without cfg"

# (a3) missing /dev/binder
setup_installed
rm -f "$t/dev/binder"
set_status_running
out=$(run_and state) || fail "(a3) state without binder exits 0"
[ "$out" = "$NOT_INSTALLED_OUT" ] || fail "(a3) missing binder state (got:
$out)"
[ "$(wd_calls)" = 0 ] || fail "(a3) waydroid not called without binder"
nlines "$t/timeout" 0 || fail "(a3) timeout not called without binder"
nlines "$t/hyprctl" 0 || fail "(a3) hyprctl not called without binder"
echo "ok - state: not installed for each of the three reasons, nothing called"

# --- (b) state: stopped, running, frozen, status failure -----------------------
setup_installed
set_status_stopped
out=$(run_and state) || fail "(b1) state when stopped exits 0"
[ "$out" = "installed=yes
session=stopped
container=stopped
apps=" ] || fail "(b1) stopped state (got:
$out)"
[ "$(wd_calls)" = 1 ] || fail "(b1) exactly one waydroid status call (got: $(wd_calls))"
grep -qx 'timeout 5 waydroid status' "$t/timeout" || fail "(b1) waydroid status bounded with timeout 5"
nlines "$t/hyprctl" 0 || fail "(b1) hyprctl not called when stopped"

setup_installed
set_status_running
out=$(run_and state) || fail "(b2) state when running exits 0"
[ "$(printf '%s\n' "$out" | sed -n '1,3p')" = "installed=yes
session=running
container=running" ] || fail "(b2) running state (got:
$out)"
[ "$(wd_calls)" = 1 ] || fail "(b2) exactly one waydroid status call"

setup_installed
set_status_frozen
out=$(run_and state) || fail "(b3) state when frozen exits 0"
[ "$(printf '%s\n' "$out" | sed -n '1,3p')" = "installed=yes
session=running
container=frozen" ] || fail "(b3) frozen state (got:
$out)"

setup_installed
T715_TEST_WD_RC=1
out=$(run_and state) || fail "(b4) state when waydroid status fails exits 0"
[ "$out" = "installed=yes
session=stopped
container=stopped
apps=" ] || fail "(b4) failed status treated as stopped (got:
$out)"
echo "ok - state: stopped, running, frozen, and waydroid status failure"

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

    clear_files
    T715_TEST_HYPRCTL_RC=1
    out=$(run_and state) || fail "(c2) state when hyprctl fails exits 0"
    [ "$(printf '%s\n' "$out" | sed -n '4p')" = "apps=" ] || fail "(c2) apps empty on hyprctl failure (got:
$out)"
    echo "ok - state: apps count with two waydroid.* clients, empty on hyprctl failure"
else
    echo "skip - state: apps count assertions (jq not installed on host)"
fi

# --- (d) start: when stopped (marker removed, systemctl start, polled) ---------
setup_installed
set_status_stopped
: > "$t/state/off"
T715_TEST_WD_AFTER=3
T715_ANDROID_WAIT=3 run_and start >/dev/null 2>&1 || fail "(d) start from stopped exits 0"
[ ! -e "$t/state/off" ] || fail "(d) off marker removed by start"
grep -qx 'systemctl --user start t715-android.service' "$t/systemctl" \
    || fail "(d) systemctl --user start called"
nlines "$t/systemctl" 1 || fail "(d) exactly one systemctl call"
[ "$(wd_calls)" = 3 ] || fail "(d) polled waydroid status until RUNNING (calls: $(wd_calls))"
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
T715_TEST_WD_AFTER=2
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
T715_TEST_WD_AFTER=2
T715_ANDROID_WAIT=3 run_and settings >/dev/null 2>&1 || fail "(i2) settings when stopped starts then launches"
grep -qx 'systemctl --user start t715-android.service' "$t/systemctl" \
    || fail "(i2) settings started the session first"
grep -qx 'waydroid app launch com.android.settings' "$t/wd-log" \
    || fail "(i2) settings launched com.android.settings after start"

setup_installed
set_status_stopped
T715_ANDROID_WAIT=1 run_and settings >/dev/null 2>&1 && fail "(i3) settings fails if start fails"
nlines "$t/wd-log" 0 || fail "(i3) app launch not called when start fails"
echo "ok - settings: launches com.android.settings, starting first when stopped"

# --- (j) usage and exit codes --------------------------------------------------
run_and frobnicate >/dev/null 2>&1 && fail "(j1) unknown verb exits nonzero"
[ "$(run_and frobnicate >/dev/null 2>&1; echo $?)" = 2 ] || fail "(j1) unknown verb exits 2"
run_and >/dev/null 2>&1 && fail "(j2) no argument exits nonzero"
[ "$(run_and 2>/dev/null; echo $?)" = 2 ] || fail "(j2) no argument exits 2"
case "$(run_and 2>&1 >/dev/null)" in
usage:*) ;;
*) fail "(j3) usage goes to stderr on no argument" ;;
esac
help_out=$(run_and --help 2>/dev/null) || fail "(j4) --help exits 0"
case "$help_out" in
usage:*) ;;
*) fail "(j4) --help prints usage on stdout (got: $help_out)" ;;
esac
help_short=$(run_and -h 2>/dev/null) || fail "(j5) -h exits 0"
case "$help_short" in
usage:*) ;;
*) fail "(j5) -h prints usage on stdout (got: $help_short)" ;;
esac
echo "ok - usage: --help/-h exit 0 on stdout, missing/unknown exit 2 on stderr"

# --- (k) user unit and configure-system.sh, statically -------------------------
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

echo "PASS"
