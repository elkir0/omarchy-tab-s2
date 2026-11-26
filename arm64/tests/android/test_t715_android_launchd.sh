#!/usr/bin/env bash
# test_t715_android_launchd.sh — off-device test of the preloaded Waydroid
# launcher daemon (launchd.py), its /usr/local/bin/waydroid wrapper, its
# systemd user unit, and its global enable line in configure-omarchy.sh.
# Ported from image/tests/ of the owner's repository for the 64-bit image.
#
# Runs the real launchd.py against a temporary fake `tools` package whose
# `main()` records `sys.argv` as JSON lines, and invokes the real POSIX sh
# wrapper with T715_ANDROID_REAL_WAYDROID pointed at a stub binary. Verifies:
#   - import failure exits 3 with a message and leaves no FIFO/pid file
#   - startup creates directory (0700), FIFO (0600), and pid file
#   - the three accepted forms (`app launch PKG`, `app intent ACTION URI`,
#     `show-full-ui`) reach the daemon with quoting intact (spaces & quotes)
#   - refused forms bypass the daemon and go to the real waydroid binary
#   - direct writes of unsupported forms to the FIFO are logged and dropped
#   - children are reaped (no zombies)
#   - SIGTERM removes FIFO and pid file and exits 0
#   - stopped daemon (stale pid file + FIFO present) and stalled FIFO
#     (live pid not reading FIFO) fall back cleanly without hanging
#   - static checks of t715-android-launchd.service and configure-omarchy.sh
#
# Usage: arm64/tests/android/test_t715_android_launchd.sh
# Works on macOS (bash 3.2, python3, mkfifo) and Linux; finishes in < 60 s.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../rootfs" && pwd)
LAUNCHD="$here/overlay-omarchy/usr/local/lib/t715-android/launchd.py"
WRAPPER="$here/overlay-omarchy/usr/local/bin/waydroid"
UNIT="$here/overlay-omarchy/etc/systemd/user/t715-android-launchd.service"
CONF="$here/configure-omarchy.sh"

[ -f "$LAUNCHD" ] || { echo "SETUP ERROR: no $LAUNCHD" >&2; exit 2; }
[ -f "$WRAPPER" ] || { echo "SETUP ERROR: no $WRAPPER" >&2; exit 2; }

t=$(mktemp -d "${TMPDIR:-/tmp}/t715-android-launchd-test.XXXXXX")
DAEMON_PID=""
STALL_PID=""
cleanup() {
    if [ -n "$STALL_PID" ]; then
        kill "$STALL_PID" 2>/dev/null || true
        wait "$STALL_PID" 2>/dev/null || true
    fi
    if [ -n "$DAEMON_PID" ]; then
        kill "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
    fi
    rm -rf "$t"
}
trap cleanup EXIT

fail() {
    printf 'not ok - %s\n' "$1" >&2
    echo "--- daemon log (tools.main)" >&2; cat "$t/daemon-argv.log" 2>/dev/null || true
    echo "--- daemon stderr" >&2; cat "$t/daemon.err" 2>/dev/null || true
    echo "--- real waydroid log" >&2; cat "$t/real-argv.log" 2>/dev/null || true
    exit 1
}

# Provide a portable timeout(1) shim on macOS when GNU timeout is absent.
mkdir -p "$t/bin"
if ! command -v timeout >/dev/null 2>&1; then
    cat > "$t/bin/timeout" <<'SHIM'
#!/bin/sh
exec python3 -c '
import subprocess, sys
secs = float(sys.argv[1])
cmd = sys.argv[2:]
try:
    rc = subprocess.call(cmd, timeout=secs)
except subprocess.TimeoutExpired:
    sys.exit(124)
sys.exit(rc)
' "$@"
SHIM
    chmod +x "$t/bin/timeout"
    PATH="$t/bin:$PATH"
    export PATH
fi

# --- fake Waydroid `tools` package ----------------------------------------------
mkdir -p "$t/fake-waydroid/tools/actions" "$t/fake-waydroid/tools/interfaces"
cat > "$t/fake-waydroid/tools/__init__.py" <<'PY'
import json
import os
import sys


def main():
    log_path = os.environ["T715_TEST_DAEMON_LOG"]
    with open(log_path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(sys.argv) + "\n")
    pid_log = os.environ.get("T715_TEST_CHILD_PIDS")
    if pid_log:
        with open(pid_log, "a", encoding="utf-8") as fh:
            fh.write(f"{os.getpid()}\n")
    return 0
PY
: > "$t/fake-waydroid/tools/actions/__init__.py"
: > "$t/fake-waydroid/tools/actions/app_manager.py"
: > "$t/fake-waydroid/tools/interfaces/__init__.py"
: > "$t/fake-waydroid/tools/interfaces/IPlatform.py"

# --- stub real /usr/bin/waydroid ------------------------------------------------
cat > "$t/real-waydroid" <<'STUB'
#!/bin/sh
python3 -c '
import json, os, sys
with open(os.environ["T715_TEST_REAL_LOG"], "a", encoding="utf-8") as fh:
    fh.write(json.dumps(sys.argv[1:]) + "\n")
' "$@"
exit 0
STUB
chmod +x "$t/real-waydroid"

export T715_TEST_DAEMON_LOG="$t/daemon-argv.log"
export T715_TEST_CHILD_PIDS="$t/child-pids.log"
export T715_TEST_REAL_LOG="$t/real-argv.log"
: > "$T715_TEST_DAEMON_LOG"
: > "$T715_TEST_CHILD_PIDS"
: > "$T715_TEST_REAL_LOG"

wait_lines() {
    local file=$1 want=$2 i=0 n=0
    while [ "$i" -lt 50 ]; do
        n=$(wc -l < "$file" | tr -d ' ')
        [ "$n" -ge "$want" ] && return 0
        python3 -c 'import time; time.sleep(0.1)'
        i=$((i + 1))
    done
    return 1
}

run_wrapper() {
    env XDG_RUNTIME_DIR="$t/rt" \
        T715_ANDROID_REAL_WAYDROID="$t/real-waydroid" \
        "$WRAPPER" "$@"
}

# --- (a) import failure exits 3 with message, leaves no FIFO/pid ----------------
mkdir -p "$t/empty-lib" "$t/rt-bad"
rc=0
env T715_ANDROID_WAYDROID_LIB="$t/empty-lib" \
    XDG_RUNTIME_DIR="$t/rt-bad" \
    python3 "$LAUNCHD" > "$t/bad.out" 2> "$t/bad.err" || rc=$?
[ "$rc" = 3 ] || fail "(a) import failure must exit 3 (got $rc)"
[ -s "$t/bad.err" ] || fail "(a) import failure must print a message on stderr"
[ ! -e "$t/rt-bad/t715-android/launch.fifo" ] || fail "(a) import failure left FIFO behind"
[ ! -e "$t/rt-bad/t715-android/launchd.pid" ] || fail "(a) import failure left pid file behind"
echo "ok - import failure exits 3 with stderr message and leaves no runtime files"

# --- (b) start daemon, verify directory/FIFO modes and pid file -----------------
mkdir -p "$t/rt"
env T715_ANDROID_WAYDROID_LIB="$t/fake-waydroid" \
    XDG_RUNTIME_DIR="$t/rt" \
    python3 "$LAUNCHD" > "$t/daemon.out" 2> "$t/daemon.err" &
DAEMON_PID=$!

RUN_DIR="$t/rt/t715-android"
FIFO="$RUN_DIR/launch.fifo"
PID_FILE="$RUN_DIR/launchd.pid"

ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
    if [ -p "$FIFO" ] && [ -s "$PID_FILE" ]; then
        ready=1
        break
    fi
    python3 -c 'import time; time.sleep(0.1)'
done
[ "$ready" -eq 1 ] || fail "(b) daemon did not create FIFO and pid file in time"
[ "$(cat "$PID_FILE")" = "$DAEMON_PID" ] || fail "(b) pid file mismatch (got $(cat "$PID_FILE"), want $DAEMON_PID)"

python3 - "$RUN_DIR" "$FIFO" <<'PY' || fail "(b) directory/FIFO modes mismatch"
import os, stat, sys
dir_mode = stat.S_IMODE(os.stat(sys.argv[1]).st_mode)
fifo_st = os.stat(sys.argv[2])
fifo_mode = stat.S_IMODE(fifo_st.st_mode)
assert dir_mode == 0o700, oct(dir_mode)
assert stat.S_ISFIFO(fifo_st.st_mode)
assert fifo_mode == 0o600, oct(fifo_mode)
PY
echo "ok - daemon startup: dir 0700, FIFO 0600, pid file matches daemon"

# --- (c) three accepted request forms through wrapper (with URI spaces/quote) ---
run_wrapper app launch com.android.settings || fail "(c1) app launch exited nonzero"
run_wrapper app intent android.intent.action.VIEW "https://example.com/my folder/it's a test?a=1&b=2" \
    || fail "(c2) app intent exited nonzero"
run_wrapper show-full-ui || fail "(c3) show-full-ui exited nonzero"

wait_lines "$T715_TEST_DAEMON_LOG" 3 || fail "(c) daemon did not record 3 requests"
[ ! -s "$T715_TEST_REAL_LOG" ] || fail "(c) accepted forms must not call real waydroid"

python3 - "$T715_TEST_DAEMON_LOG" <<'PY' || fail "(c) recorded argv mismatch"
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    got = [json.loads(line) for line in fh]
want = [
    ["waydroid", "app", "launch", "com.android.settings"],
    ["waydroid", "app", "intent", "android.intent.action.VIEW", "https://example.com/my folder/it's a test?a=1&b=2"],
    ["waydroid", "show-full-ui"],
]
assert got == want, f"got={got!r}\nwant={want!r}"
PY
echo "ok - accepted forms: app launch, app intent (spaces + quote), show-full-ui routed to daemon"

# --- (d) refused forms go to real waydroid instead ------------------------------
run_wrapper status || fail "(d1) refused status exited nonzero"
run_wrapper session start || fail "(d2) refused session start exited nonzero"
run_wrapper app install "/tmp/my app.apk" || fail "(d3) refused app install exited nonzero"
run_wrapper app launch --help || fail "(d4) refused app launch --help exited nonzero"

python3 - "$T715_TEST_REAL_LOG" "$T715_TEST_DAEMON_LOG" <<'PY' || fail "(d) refused forms mismatch"
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    real_got = [json.loads(line) for line in fh]
with open(sys.argv[2], encoding="utf-8") as fh:
    daemon_got = [json.loads(line) for line in fh]
want_real = [
    ["status"],
    ["session", "start"],
    ["app", "install", "/tmp/my app.apk"],
    ["app", "launch", "--help"],
]
assert real_got == want_real, f"real_got={real_got!r}"
assert len(daemon_got) == 3, f"daemon should still have 3 entries, got {len(daemon_got)}"
PY
echo "ok - refused forms routed to real waydroid, not daemon"

# --- (e) direct FIFO write of refused form is logged and dropped ----------------
printf 'session start\napp install /tmp/evil.apk\n' > "$FIFO"
# Send a valid barrier request so we know the daemon processed the dropped lines.
run_wrapper show-full-ui || fail "(e) barrier show-full-ui failed"
wait_lines "$T715_TEST_DAEMON_LOG" 4 || fail "(e) barrier request not recorded"

python3 - "$T715_TEST_DAEMON_LOG" <<'PY' || fail "(e) daemon executed a refused FIFO request"
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    got = [json.loads(line) for line in fh]
assert len(got) == 4, f"expected 4 entries, got {got!r}"
assert got[3] == ["waydroid", "show-full-ui"], got[3]
PY
grep -q 'dropping unsupported request' "$t/daemon.err" \
    || fail "(e) daemon did not log dropped request"
echo "ok - direct unsupported FIFO request logged and dropped"

# --- (f) children reaped (no zombies) -------------------------------------------
# An unreaped zombie still answers kill -0 (it stays in the process table); once
# the daemon reaps its children with waitpid, every recorded child PID is gone.
python3 - "$T715_TEST_CHILD_PIDS" <<'PY' || fail "(f) unreaped zombie child(ren) found"
import errno, os, sys, time

with open(sys.argv[1], encoding="utf-8") as fh:
    pids = [int(line.strip()) for line in fh if line.strip()]
assert len(pids) == 4, f"expected 4 child pids, got {pids!r}"

deadline = time.monotonic() + 3.0
alive = list(pids)
while alive and time.monotonic() < deadline:
    still = []
    for pid in alive:
        try:
            os.kill(pid, 0)
            still.append(pid)
        except OSError as exc:
            if exc.errno != errno.ESRCH:
                still.append(pid)
    alive = still
    if alive:
        time.sleep(0.05)

assert not alive, f"child pids still present (zombies): {alive!r}"
PY
echo "ok - children reaped (all 4 child PIDs gone, 0 zombies)"

# --- (g) SIGTERM removes FIFO and pid file and exits 0 --------------------------
DEAD_PID=$DAEMON_PID
kill -TERM "$DAEMON_PID"
term_rc=0
wait "$DAEMON_PID" || term_rc=$?
DAEMON_PID=""
[ "$term_rc" = 0 ] || fail "(g) SIGTERM must exit 0 (got $term_rc)"
[ ! -e "$FIFO" ] || fail "(g) SIGTERM did not remove FIFO"
[ ! -e "$PID_FILE" ] || fail "(g) SIGTERM did not remove pid file"
echo "ok - SIGTERM cleans up FIFO and pid file and exits 0"

# --- (h) stopped daemon (stale pid + FIFO present) falls back without hanging ---
: > "$T715_TEST_REAL_LOG"
mkfifo -m 0600 "$FIFO"
printf '%s\n' "$DEAD_PID" > "$PID_FILE"

start_s=$SECONDS
run_wrapper app launch com.android.deskclock || fail "(h1) fallback on dead pid failed"
elapsed=$((SECONDS - start_s))
[ "$elapsed" -lt 2 ] || fail "(h1) stale pid fallback took too long (${elapsed} s)"
python3 - "$T715_TEST_REAL_LOG" <<'PY' || fail "(h1) stale pid did not fall back to real waydroid"
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    got = [json.loads(line) for line in fh]
assert got == [["app", "launch", "com.android.deskclock"]], got
PY

# Also verify stalled FIFO (live pid in pidfile, nobody reading FIFO) times out
# cleanly via `timeout 2` and falls back to real waydroid without hanging.
: > "$T715_TEST_REAL_LOG"
sleep 30 &
STALL_PID=$!
printf '%s\n' "$STALL_PID" > "$PID_FILE"
start_s=$SECONDS
run_wrapper app launch com.android.documentsui || fail "(h2) fallback on stalled FIFO failed"
elapsed=$((SECONDS - start_s))
kill "$STALL_PID" 2>/dev/null || true
wait "$STALL_PID" 2>/dev/null || true
STALL_PID=""
[ "$elapsed" -le 6 ] || fail "(h2) stalled FIFO fallback took too long (${elapsed} s)"
python3 - "$T715_TEST_REAL_LOG" <<'PY' || fail "(h2) stalled FIFO did not fall back to real waydroid"
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    got = [json.loads(line) for line in fh]
assert got == [["app", "launch", "com.android.documentsui"]], got
PY
echo "ok - fallback: stale pid (immediate) and stalled FIFO (timeout 2) reach real waydroid without hanging"

# --- (i) static checks of unit, wrapper mode, and configure-omarchy.sh ----------
[ -x "$WRAPPER" ] || fail "(i) $WRAPPER must be executable (mode 755)"
! grep -qE '(^|[[:space:];|&])eval([[:space:]]|$)' "$WRAPPER" || fail "(i) wrapper must not use eval"
[ -f "$UNIT" ] || fail "(i) missing $UNIT"
head -n1 "$UNIT" | grep -q '^#' || fail "(i) unit must carry a header comment"
grep -qx 'Description=.*' "$UNIT" || fail "(i) unit missing Description="
grep -qx 'PartOf=graphical-session.target' "$UNIT" || fail "(i) unit missing PartOf="
grep -qx 'After=graphical-session.target' "$UNIT" || fail "(i) unit missing After="
grep -qx 'ConditionPathExists=/var/lib/waydroid/waydroid.cfg' "$UNIT" \
    || fail "(i) unit missing ConditionPathExists=waydroid.cfg"
grep -qx 'ConditionPathExists=/dev/binder' "$UNIT" \
    || fail "(i) unit missing ConditionPathExists=/dev/binder"
! grep -q 't715-android/off' "$UNIT" \
    || fail "(i) unit must NOT check the off marker"
grep -qx 'ExecStart=/usr/bin/python3 /usr/local/lib/t715-android/launchd.py' "$UNIT" \
    || fail "(i) unit missing ExecStart="
grep -qx 'Restart=on-failure' "$UNIT" || fail "(i) unit missing Restart=on-failure"
grep -qx 'RestartSec=5' "$UNIT" || fail "(i) unit missing RestartSec=5"
grep -qx 'WantedBy=graphical-session.target' "$UNIT" || fail "(i) unit missing WantedBy="
grep -qx 'systemctl --global enable t715-android-launchd.service' "$CONF" \
    || fail "(i) configure-omarchy.sh must globally enable t715-android-launchd.service"
echo "ok - static checks: unit keys, wrapper executable, configure-omarchy.sh global enable"

echo "PASS"
