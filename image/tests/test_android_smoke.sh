#!/usr/bin/env bash
# test_android_smoke.sh — off-device test of image/tests/ondevice/android-smoke.sh.
#
# Runs android-smoke.sh against a fake procfs, a fake cgroup directory and
# stand-in commands first in PATH (t715-android, waydroid, dmesg, timeout,
# plus a guard sudo that fails if ever called when ANDROID_SMOKE_USER_PREFIX
# is empty). Covers: full passing run (key order, values, cgroup thawed back
# to 0, session stopped), --keep, session already running, llvmpipe software
# renderer, native crashes in logcat, new GPU faults in dmesg with privacy
# filtering of "Kernel command line" and "UFW BLOCK" lines, boot timeout,
# not installed (exit 4), --report, and usage/root exit codes.
#
# Usage: bash image/tests/test_android_smoke.sh
# Prints "ok - ..." per case, "PASS" at the end; exits 1 on the first failure
# (dumping stub logs). Works on macOS (bash 3.2, BSD userland). Nothing
# outside a temporary directory.

set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SMOKE="$here/tests/ondevice/android-smoke.sh"
[ -f "$SMOKE" ] || { echo "SETUP ERROR: no $SMOKE" >&2; exit 2; }

t=$(mktemp -d "${TMPDIR:-/tmp}/android-smoke-test.XXXXXX")
cleanup() { rm -rf "$t"; }
trap cleanup EXIT

fail() {
    printf 'not ok - %s\n' "$1" >&2
    echo "--- stdout" >&2; cat "$t/out" 2>/dev/null || true
    echo "--- stderr" >&2; cat "$t/err" 2>/dev/null || true
    echo "--- t715-android calls" >&2; cat "$t/android.log" 2>/dev/null || true
    echo "--- waydroid calls" >&2; cat "$t/waydroid.log" 2>/dev/null || true
    echo "--- cgroup.freeze" >&2; cat "$t/cgroup/cgroup.freeze" 2>/dev/null || true
    exit 1
}

# --- stand-ins -----------------------------------------------------------------
mkdir -p "$t/bin" "$t/proc" "$t/cgroup" "$t/fixtures"

cat > "$t/bin/timeout" <<'STUB'
#!/bin/sh
# Minimal stand-in for GNU timeout on macOS: drop options and duration, exec command.
while [ $# -gt 0 ]; do
    case "$1" in
        -k|-s|--kill-after|--signal) shift 2 ;;
        --foreground|--preserve-status|-v|--verbose) shift ;;
        --*=*) shift ;;
        *) break ;;
    esac
done
[ $# -ge 2 ] || exit 2
shift
exec "$@"
STUB

cat > "$t/bin/sudo" <<'STUB'
#!/bin/sh
echo "ERROR: sudo must not be invoked when ANDROID_SMOKE_USER_PREFIX is empty" >&2
exit 99
STUB

cat > "$t/bin/t715-android" <<'STUB'
#!/bin/sh
printf 't715-android %s\n' "$*" >> "$SMOKE_TEST_ANDROID_LOG"
case "$1" in
    state)
        cat "$SMOKE_TEST_STATE"
        exit 0
        ;;
    start)
        if [ -n "${SMOKE_TEST_MEMINFO_AFTER:-}" ] && [ -f "$SMOKE_TEST_MEMINFO_AFTER" ]; then
            cp "$SMOKE_TEST_MEMINFO_AFTER" "$SMOKE_TEST_PROC/meminfo"
        fi
        exit "${SMOKE_TEST_START_RC:-0}"
        ;;
    stop)
        exit 0
        ;;
    *)
        exit 2
        ;;
esac
STUB

cat > "$t/bin/waydroid" <<'STUB'
#!/bin/sh
printf 'waydroid %s\n' "$*" >> "$SMOKE_TEST_WAYDROID_LOG"
case "$1" in
    prop)
        if [ "$2" = "get" ] && [ "$3" = "sys.boot_completed" ]; then
            n=0
            if [ -f "$SMOKE_TEST_BOOT_CALLS" ]; then
                n=$(cat "$SMOKE_TEST_BOOT_CALLS")
            fi
            n=$((n + 1))
            printf '%s\n' "$n" > "$SMOKE_TEST_BOOT_CALLS"
            ready_at="${SMOKE_TEST_BOOT_READY_AT:-1}"
            if [ "$n" -ge "$ready_at" ]; then
                printf '[waydroid] prop lookup\n1\n'
            else
                printf '0\n'
            fi
            exit 0
        fi
        exit 1
        ;;
    shell)
        shift
        [ "${1:-}" = "--" ] && shift
        cmd="${1:-}"
        shift || true
        case "$cmd" in
            dumpsys)
                cat "$SMOKE_TEST_DUMPSYS"
                exit 0
                ;;
            am)
                case "${1:-}" in
                    force-stop)
                        exit 0
                        ;;
                    start)
                        c=0
                        if [ -f "$SMOKE_TEST_AM_CALLS" ]; then
                            c=$(cat "$SMOKE_TEST_AM_CALLS")
                        fi
                        c=$((c + 1))
                        printf '%s\n' "$c" > "$SMOKE_TEST_AM_CALLS"
                        if [ -n "${SMOKE_TEST_AM_RC:-}" ]; then
                            exit "$SMOKE_TEST_AM_RC"
                        fi
                        if [ "$c" -eq 1 ]; then
                            cat "$SMOKE_TEST_AM_COLD"
                        else
                            cat "$SMOKE_TEST_AM_WARM"
                        fi
                        exit 0
                        ;;
                    *)
                        exit 1
                        ;;
                esac
                ;;
            input)
                exit 0
                ;;
            logcat)
                if [ -n "${SMOKE_TEST_LOGCAT_RC:-}" ]; then
                    exit "$SMOKE_TEST_LOGCAT_RC"
                fi
                cat "$SMOKE_TEST_LOGCAT"
                exit 0
                ;;
            *)
                exit 1
                ;;
        esac
        ;;
    *)
        exit 1
        ;;
esac
STUB

cat > "$t/bin/dmesg" <<'STUB'
#!/bin/sh
n=0
if [ -f "$SMOKE_TEST_DMESG_CALLS" ]; then
    n=$(cat "$SMOKE_TEST_DMESG_CALLS")
fi
n=$((n + 1))
printf '%s\n' "$n" > "$SMOKE_TEST_DMESG_CALLS"
cat "$SMOKE_TEST_DMESG_BEFORE"
if [ "$n" -ge 2 ] && [ -f "$SMOKE_TEST_DMESG_NEW" ]; then
    cat "$SMOKE_TEST_DMESG_NEW"
fi
exit 0
STUB

chmod +x "$t/bin/"*

export SMOKE_TEST_ANDROID_LOG="$t/android.log"
export SMOKE_TEST_WAYDROID_LOG="$t/waydroid.log"
export SMOKE_TEST_STATE="$t/fixtures/state"
export SMOKE_TEST_DUMPSYS="$t/fixtures/dumpsys"
export SMOKE_TEST_AM_COLD="$t/fixtures/am_cold"
export SMOKE_TEST_AM_WARM="$t/fixtures/am_warm"
export SMOKE_TEST_LOGCAT="$t/fixtures/logcat"
export SMOKE_TEST_DMESG_BEFORE="$t/fixtures/dmesg_before"
export SMOKE_TEST_DMESG_NEW="$t/fixtures/dmesg_new"
export SMOKE_TEST_BOOT_CALLS="$t/boot_calls"
export SMOKE_TEST_AM_CALLS="$t/am_calls"
export SMOKE_TEST_DMESG_CALLS="$t/dmesg_calls"
export SMOKE_TEST_PROC="$t/proc"
export SMOKE_TEST_MEMINFO_AFTER="$t/fixtures/meminfo_after"
export SMOKE_TEST_BOOT_READY_AT=2
export SMOKE_TEST_START_RC=0
export SMOKE_TEST_AM_RC=""
export SMOKE_TEST_LOGCAT_RC=""

reset_case() {
    : > "$t/out"
    : > "$t/err"
    : > "$t/android.log"
    : > "$t/waydroid.log"
    rm -f "$t/boot_calls" "$t/am_calls" "$t/dmesg_calls" "$t/report.txt"

    cat > "$t/fixtures/state" <<'EOF'
installed=yes
session=stopped
container=stopped
apps=3
EOF
    cat > "$t/proc/meminfo" <<'EOF'
MemTotal:        3072000 kB
MemFree:          512000 kB
MemAvailable:    1536000 kB
EOF
    cat > "$t/fixtures/meminfo_after" <<'EOF'
MemTotal:        3072000 kB
MemFree:          300000 kB
MemAvailable:    1024000 kB
EOF
    printf '0\n' > "$t/cgroup/cgroup.freeze"
    printf 'populated 1\nfrozen 1\n' > "$t/cgroup/cgroup.events"
    # 536870912 bytes = 512 MiB
    printf '536870912\n' > "$t/cgroup/memory.current"

    cat > "$t/fixtures/dumpsys" <<'EOF'
Build configuration: [sf PRESENT_TIME_OFFSET=0]
GLES: Mesa, Mali-T760 MC6 (Panfrost), OpenGL ES 3.1 Mesa 26.0.8
Wide-Color information:
EOF
    cat > "$t/fixtures/am_cold" <<'EOF'
Starting: Intent { cmp=com.android.settings/.Settings }
Status: ok
LaunchState: COLD
Activity: com.android.settings/.Settings
TotalTime: 842
WaitTime: 860
Complete
EOF
    cat > "$t/fixtures/am_warm" <<'EOF'
Starting: Intent { cmp=com.android.settings/.Settings }
Status: ok
LaunchState: WARM
Activity: com.android.settings/.Settings
TotalTime: 195
WaitTime: 210
Complete
EOF
    cat > "$t/fixtures/logcat" <<'EOF'
--------- beginning of crash
EOF
    cat > "$t/fixtures/dmesg_before" <<'EOF'
[    0.000000] Booting Linux on physical CPU 0x0
[    0.000000] Kernel command line: console=tty0 androidboot.serialno=REDACTED_SERIAL_BASELINE
[    1.200000] panfrost 14ac0000.gpu: Features: L2:0x07120206 MMU:0x00002830
[    5.100000] panfrost 14ac0000.gpu: js fault, js=0, status=DATA_INVALID_FAULT
EOF
    : > "$t/fixtures/dmesg_new"

    SMOKE_TEST_BOOT_READY_AT=2
    SMOKE_TEST_START_RC=0
    SMOKE_TEST_AM_RC=""
    SMOKE_TEST_LOGCAT_RC=""
}

run_smoke() {
    local rc=0
    env PATH="$t/bin:$PATH" \
        ANDROID_SMOKE_PROC="$t/proc" \
        ANDROID_SMOKE_CGROUP="$t/cgroup" \
        ANDROID_SMOKE_ASSUME_ROOT=1 \
        ANDROID_SMOKE_USER_PREFIX="" \
        "$SMOKE" "$@" >"$t/out" 2>"$t/err" || rc=$?
    return "$rc"
}

get_val() {
    awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$t/out"
}

EXPECTED_KEYS="android_smoke
session_was_running
boot_completed
boot_seconds
gles
gpu_driver
launch_cold_ms
launch_thaw_ms
launch_warm_ms
android_mem_mb
host_mem_available_before_mb
host_mem_available_after_mb
crashes
crashed
gpu_faults
verdict"

# --- (a) full passing run -------------------------------------------------------
reset_case
rc=0
run_smoke || rc=$?
[ "$rc" -eq 0 ] || fail "(a) expected exit 0, got $rc"

keys=$(awk -F= '{ print $1 }' "$t/out")
[ "$keys" = "$EXPECTED_KEYS" ] || fail "(a) key order mismatch:
$keys"

[ "$(get_val android_smoke)" = "1" ] || fail "(a) android_smoke=1"
[ "$(get_val session_was_running)" = "no" ] || fail "(a) session_was_running=no"
[ "$(get_val boot_completed)" = "yes" ] || fail "(a) boot_completed=yes"
case "$(get_val boot_seconds)" in
    ''|*[!0-9]*) fail "(a) boot_seconds must be numeric" ;;
esac
[ "$(get_val gles)" = "Mesa, Mali-T760 MC6 (Panfrost), OpenGL ES 3.1 Mesa 26.0.8" ] || fail "(a) gles value"
[ "$(get_val gpu_driver)" = "panfrost" ] || fail "(a) gpu_driver=panfrost"
[ "$(get_val launch_cold_ms)" = "842" ] || fail "(a) launch_cold_ms=842"
case "$(get_val launch_thaw_ms)" in
    ''|*[!0-9]*) fail "(a) launch_thaw_ms must be numeric" ;;
esac
[ "$(get_val launch_warm_ms)" = "195" ] || fail "(a) launch_warm_ms=195"
[ "$(get_val android_mem_mb)" = "512" ] || fail "(a) android_mem_mb=512"
[ "$(get_val host_mem_available_before_mb)" = "1500" ] || fail "(a) host_mem_available_before_mb=1500"
[ "$(get_val host_mem_available_after_mb)" = "1000" ] || fail "(a) host_mem_available_after_mb=1000"
[ "$(get_val crashes)" = "0" ] || fail "(a) crashes=0"
[ "$(get_val crashed)" = "" ] || fail "(a) crashed empty"
[ "$(get_val gpu_faults)" = "0" ] || fail "(a) gpu_faults=0"
[ "$(get_val verdict)" = "pass" ] || fail "(a) verdict=pass"

[ "$(tr -d '[:space:]' < "$t/cgroup/cgroup.freeze")" = "0" ] || fail "(a) cgroup.freeze must end at 0"
grep -qx 't715-android start' "$t/android.log" || fail "(a) session was started"
grep -qx 't715-android stop' "$t/android.log" || fail "(a) session was stopped at the end"
grep -qx 'waydroid shell -- am force-stop com.android.settings' "$t/waydroid.log" || fail "(a) force-stop package"
grep -qx 'waydroid shell -- input keyevent KEYCODE_HOME' "$t/waydroid.log" || fail "(a) sent KEYCODE_HOME"
grep -q '^# preconditions$' "$t/err" || fail "(a) stderr logs # <step>"
echo "ok - full passing run: all keys in order, verdict=pass, thawed, session stopped"

# --- (b) --keep and --app -------------------------------------------------------
reset_case
rc=0
run_smoke --keep --app org.example.demo/.MainActivity || rc=$?
[ "$rc" -eq 0 ] || fail "(b) expected exit 0, got $rc"
grep -qx 't715-android start' "$t/android.log" || fail "(b) session was started"
grep -qx 't715-android stop' "$t/android.log" && fail "(b) --keep must not stop session"
grep -qx 'waydroid shell -- am force-stop org.example.demo' "$t/waydroid.log" || fail "(b) custom package force-stopped"
grep -qx 'waydroid shell -- am start -W -n org.example.demo/.MainActivity' "$t/waydroid.log" || fail "(b) custom component launched"
echo "ok - --keep preserves session and --app launches the requested component"

# --- (c) session already running ------------------------------------------------
reset_case
cat > "$t/fixtures/state" <<'EOF'
installed=yes
session=running
container=running
apps=3
EOF
SMOKE_TEST_BOOT_READY_AT=1
rc=0
run_smoke || rc=$?
[ "$rc" -eq 0 ] || fail "(c) expected exit 0, got $rc"
[ "$(get_val session_was_running)" = "yes" ] || fail "(c) session_was_running=yes"
[ "$(get_val boot_seconds)" = "" ] || fail "(c) boot_seconds must be empty when already running"
[ "$(get_val verdict)" = "pass" ] || fail "(c) verdict=pass"
grep -qx 't715-android start' "$t/android.log" && fail "(c) must not start already-running session"
grep -qx 't715-android stop' "$t/android.log" && fail "(c) must not stop already-running session"
echo "ok - session already running: no start, no stop, session_was_running=yes"

# --- (d) llvmpipe software renderer --------------------------------------------
reset_case
cat > "$t/fixtures/dumpsys" <<'EOF'
GLES: Mesa, llvmpipe (LLVM 19.1.7, 128 bits), OpenGL ES 3.2 Mesa 26.0.8
EOF
SMOKE_TEST_BOOT_READY_AT=1
rc=0
run_smoke || rc=$?
[ "$rc" -eq 1 ] || fail "(d) expected exit 1 for software renderer, got $rc"
[ "$(get_val gpu_driver)" = "software" ] || fail "(d) gpu_driver=software"
[ "$(get_val verdict)" = "fail" ] || fail "(d) verdict=fail"
echo "ok - llvmpipe: gpu_driver=software, verdict=fail, exit 1"

# --- (e) crash lines in logcat -b crash ----------------------------------------
reset_case
SMOKE_TEST_BOOT_READY_AT=1
cat > "$t/fixtures/logcat" <<'EOF'
--------- beginning of crash
11-20 10:00:01.100  1111  1111 F DEBUG   : pid: 1020, tid: 1020, name: main  >>> com.example.crasher <<<
EOF
rc=0
run_smoke || rc=$?
[ "$rc" -eq 1 ] || fail "(e) expected exit 1 on crash, got $rc"
[ "$(get_val crashes)" = "1" ] || fail "(e) crashes=1"
[ "$(get_val crashed)" = "com.example.crasher" ] || fail "(e) crashed=com.example.crasher"
[ "$(get_val verdict)" = "fail" ] || fail "(e) verdict=fail"

# Also check multiple crashes (sorted, unique)
reset_case
SMOKE_TEST_BOOT_READY_AT=1
cat > "$t/fixtures/logcat" <<'EOF'
--------- beginning of crash
11-20 10:00:01.100  1111  1111 F DEBUG   : >>> com.zeta.app <<<
11-20 10:00:02.200  1112  1112 F DEBUG   : >>> com.alpha.app <<<
11-20 10:00:03.300  1113  1113 F DEBUG   : >>> com.zeta.app <<<
EOF
rc=0
run_smoke || rc=$?
[ "$rc" -eq 1 ] || fail "(e2) expected exit 1 on multiple crashes, got $rc"
[ "$(get_val crashes)" = "3" ] || fail "(e2) crashes=3"
[ "$(get_val crashed)" = "com.alpha.app,com.zeta.app" ] || fail "(e2) crashed sorted and unique"
echo "ok - crash detection: count, process name, sorted unique list, verdict=fail"

# --- (f) new GPU faults + privacy filtering + --report -------------------------
reset_case
SMOKE_TEST_BOOT_READY_AT=1
cat > "$t/fixtures/dmesg_new" <<'EOF'
[   20.000000] Kernel command line: console=tty0 androidboot.serialno=REDACTED_SERIAL_NEW panfrost js fault
[   21.000000] [UFW BLOCK] IN=wlan0 SRC=REDACTED_SRC MAC=REDACTED_MAC_NEW panfrost mmu fault
[   22.000000] panfrost 14ac0000.gpu: js fault, js=0, status=DATA_INVALID_FAULT
[   23.000000] panfrost 14ac0000.gpu: gpu sched timeout, js=1
[   24.000000] panfrost 14ac0000.gpu: Unhandled Page fault in AS0
[   25.000000] panfrost 14ac0000.gpu: mmu irq status=1
[   26.000000] panfrost 14ac0000.gpu: js fault, js=2, status=JOB_BUS_FAULT
[   27.000000] panfrost 14ac0000.gpu: gpu sched timeout, js=0
EOF
rc=0
run_smoke --report "$t/report.txt" || rc=$?
[ "$rc" -eq 1 ] || fail "(f) expected exit 1 on GPU faults, got $rc"
[ "$(get_val gpu_faults)" = "6" ] || fail "(f) expected gpu_faults=6, got $(get_val gpu_faults)"
[ "$(get_val verdict)" = "fail" ] || fail "(f) verdict=fail"
[ -f "$t/report.txt" ] || fail "(f) --report file created"
cmp -s "$t/out" "$t/report.txt" || fail "(f) --report file matches stdout"

# At most 5 new GPU fault lines printed on stderr (line at 27.000000 is the 6th)
fault_err_count=$(grep -c 'panfrost 14ac0000.gpu:' "$t/err" || true)
[ "$fault_err_count" -eq 5 ] || fail "(f) expected 5 fault lines on stderr, got $fault_err_count"

# Privacy: neither "Kernel command line" nor "UFW BLOCK" nor their payloads anywhere
for f in "$t/out" "$t/err" "$t/report.txt"; do
    grep -q 'Kernel command line' "$f" && fail "(f) Kernel command line leaked into $f"
    grep -q 'REDACTED_SERIAL' "$f" && fail "(f) serial placeholder leaked into $f"
    grep -q 'UFW BLOCK' "$f" && fail "(f) UFW BLOCK leaked into $f"
    grep -q 'REDACTED_MAC' "$f" && fail "(f) MAC placeholder leaked into $f"
done
echo "ok - new GPU faults counted and capped at 5 on stderr, privacy filtered, --report matches stdout"

# --- (g) boot timeout -----------------------------------------------------------
reset_case
SMOKE_TEST_BOOT_READY_AT=999
rc=0
run_smoke --boot-timeout 2 || rc=$?
[ "$rc" -eq 1 ] || fail "(g) expected exit 1 on boot timeout, got $rc"
[ "$(get_val boot_completed)" = "no" ] || fail "(g) boot_completed=no"
[ "$(get_val verdict)" = "fail" ] || fail "(g) verdict=fail"
grep -qx 't715-android stop' "$t/android.log" || fail "(g) session stopped after boot timeout"
echo "ok - boot timeout: boot_completed=no, verdict=fail, exit 1"

# --- (h) not installed ----------------------------------------------------------
reset_case
cat > "$t/fixtures/state" <<'EOF'
installed=no
session=stopped
container=stopped
apps=0
EOF
rc=0
run_smoke || rc=$?
[ "$rc" -eq 4 ] || fail "(h) expected exit 4 when not installed, got $rc"
echo "ok - not installed exits 4"

# --- (i) usage and root exit codes ----------------------------------------------
reset_case
rc=0
run_smoke --help || rc=$?
[ "$rc" -eq 0 ] || fail "(i) --help expected exit 0, got $rc"
grep -q '^usage: android-smoke.sh' "$t/out" || fail "(i) --help prints usage on stdout"

rc=0
run_smoke --no-such-option || rc=$?
[ "$rc" -eq 2 ] || fail "(i) unknown option expected exit 2, got $rc"
grep -q '^usage: android-smoke.sh' "$t/err" || fail "(i) unknown option prints usage on stderr"

rc=0
run_smoke --boot-timeout abc || rc=$?
[ "$rc" -eq 2 ] || fail "(i) non-numeric --boot-timeout expected exit 2, got $rc"

# Non-root check (stub id -> 1000, ANDROID_SMOKE_ASSUME_ROOT=0)
cat > "$t/bin/id" <<'STUB'
#!/bin/sh
echo 1000
STUB
chmod +x "$t/bin/id"
rc=0
env PATH="$t/bin:$PATH" \
    ANDROID_SMOKE_PROC="$t/proc" \
    ANDROID_SMOKE_CGROUP="$t/cgroup" \
    ANDROID_SMOKE_ASSUME_ROOT=0 \
    ANDROID_SMOKE_USER_PREFIX="" \
    "$SMOKE" >"$t/out" 2>"$t/err" || rc=$?
rm -f "$t/bin/id"
[ "$rc" -eq 3 ] || fail "(i) non-root expected exit 3, got $rc"
grep -qi 'root' "$t/err" || fail "(i) non-root prints message on stderr"
echo "ok - usage (--help exit 0, unknown option exit 2) and non-root (exit 3)"

echo "PASS"
