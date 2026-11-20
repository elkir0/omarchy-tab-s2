#!/usr/bin/env bash
# android-smoke.sh — on-device measurement script for Waydroid on the SM-T715.
#
# Run as root on the tablet. Checks that Waydroid is installed, starts the
# Android session if it is stopped, waits for sys.boot_completed, inspects
# SurfaceFlinger GLES / GPU driver, measures cold launch and post-freeze thaw
# + warm launch times, reads container and host memory, counts native crashes
# in logcat, and checks dmesg for new Panfrost GPU faults.
#
# Usage:
#   android-smoke.sh [--app COMPONENT] [--boot-timeout S] [--keep] [--report FILE]
#
# Output on stdout (fixed order; every key is always emitted, empty if unknown):
#   android_smoke=1
#   session_was_running=yes|no
#   boot_completed=yes|no
#   boot_seconds=<seconds>
#   gles=<SurfaceFlinger GLES line>
#   gpu_driver=panfrost|software|unknown
#   launch_cold_ms=<am start TotalTime ms>
#   launch_thaw_ms=<wall-clock ms from cgroup thaw to end of am start>
#   launch_warm_ms=<am start TotalTime ms after thaw>
#   android_mem_mb=<container memory.current in MiB>
#   host_mem_available_before_mb=<host MemAvailable before start in MiB>
#   host_mem_available_after_mb=<host MemAvailable after tests in MiB>
#   crashes=<count of native crash lines in logcat -b crash>
#   crashed=<comma-separated sorted unique crashed process names>
#   gpu_faults=<new Panfrost GPU fault lines in dmesg since script start>
#   verdict=pass|fail
#
# Exit codes:
#   0  verdict=pass (or --help)
#   1  verdict=fail
#   2  usage / bad option
#   3  not running as root
#   4  Android (Waydroid) not installed
#
# Test hooks:
#   ANDROID_SMOKE_PROC         procfs root (default: /proc)
#   ANDROID_SMOKE_CGROUP       Waydroid cgroup dir (default: /sys/fs/cgroup/lxc.payload.waydroid)
#   ANDROID_SMOKE_ASSUME_ROOT  set to 1 to bypass the root uid check
#   ANDROID_SMOKE_USER_PREFIX  replaces the default sudo/env user-session prefix;
#                              empty string runs user commands directly
#
# Privacy: never emits or stores lines containing "Kernel command line" or
# "UFW BLOCK" from kernel logs.

set -u

APP="com.android.settings/.Settings"
BOOT_TIMEOUT=180
KEEP=0
REPORT_FILE=""

PROC_DIR="${ANDROID_SMOKE_PROC:-/proc}"
CGROUP_DIR="${ANDROID_SMOKE_CGROUP:-/sys/fs/cgroup/lxc.payload.waydroid}"

usage() {
    cat <<'EOF'
usage: android-smoke.sh [--app COMPONENT] [--boot-timeout S] [--keep] [--report FILE]
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --app)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                usage >&2
                exit 2
            fi
            APP="$2"
            shift 2
            ;;
        --app=*)
            APP="${1#--app=}"
            if [ -z "$APP" ]; then
                usage >&2
                exit 2
            fi
            shift
            ;;
        --boot-timeout)
            if [ "$#" -lt 2 ]; then
                usage >&2
                exit 2
            fi
            BOOT_TIMEOUT="$2"
            shift 2
            ;;
        --boot-timeout=*)
            BOOT_TIMEOUT="${1#--boot-timeout=}"
            shift
            ;;
        --keep)
            KEEP=1
            shift
            ;;
        --report)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                usage >&2
                exit 2
            fi
            REPORT_FILE="$2"
            shift 2
            ;;
        --report=*)
            REPORT_FILE="${1#--report=}"
            if [ -z "$REPORT_FILE" ]; then
                usage >&2
                exit 2
            fi
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
done

case "$BOOT_TIMEOUT" in
    ''|*[!0-9]*)
        usage >&2
        exit 2
        ;;
esac

if [ "${ANDROID_SMOKE_ASSUME_ROOT:-0}" != "1" ] && [ "$(id -u)" -ne 0 ]; then
    echo "android-smoke.sh: must be run as root" >&2
    exit 3
fi

step() {
    printf '# %s\n' "$*" >&2
}

now_ms() {
    local ns
    ns=$(date +%s%N 2>/dev/null || true)
    case "$ns" in
        ''|*[!0-9]*)
            python3 -c 'import time; print(int(time.time()*1000))'
            ;;
        *)
            if [ "${#ns}" -gt 6 ]; then
                printf '%s\n' "${ns%??????}"
            else
                printf '%s\n' "$ns"
            fi
            ;;
    esac
}

run_as_user() {
    local limit="$1"
    shift
    if [ -z "${ANDROID_SMOKE_USER_PREFIX+x}" ]; then
        timeout "$limit" sudo -u alarm env \
            XDG_RUNTIME_DIR=/run/user/1000 \
            WAYLAND_DISPLAY=wayland-1 \
            DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
            "$@"
    elif [ -z "$ANDROID_SMOKE_USER_PREFIX" ]; then
        timeout "$limit" "$@"
    else
        local -a prefix=()
        read -r -a prefix <<< "$ANDROID_SMOKE_USER_PREFIX"
        if [ "${#prefix[@]}" -gt 0 ]; then
            timeout "$limit" "${prefix[@]}" "$@"
        else
            timeout "$limit" "$@"
        fi
    fi
}

read_mem_available_mb() {
    local meminfo="$PROC_DIR/meminfo"
    [ -r "$meminfo" ] || return 0
    awk '/^MemAvailable:/ { printf "%d\n", int($2 / 1024); exit }' "$meminfo"
}

read_dmesg_gpu_faults() {
    # Privacy rule: drop "Kernel command line" and "UFW BLOCK" before matching or output.
    timeout 15 dmesg 2>/dev/null \
        | grep -vE 'Kernel command line|UFW BLOCK' \
        | grep 'panfrost' \
        | grep -E 'js fault|gpu sched timeout|Unhandled Page fault|mmu' \
        || true
}

count_lines() {
    if [ -z "$1" ]; then
        printf '0\n'
    else
        printf '%s\n' "$1" | wc -l | tr -d ' '
    fi
}

parse_total_time() {
    printf '%s\n' "$1" \
        | tr -d '\r' \
        | awk -F: '/^[[:space:]]*TotalTime:[[:space:]]*[0-9]+/ { gsub(/[^0-9]/, "", $2); print $2; exit }'
}

read_boot_completed_prop() {
    local out
    # As the session user: waydroid prop needs the session's D-Bus service,
    # and as root it only answers "WayDroid session is stopped".
    out=$(run_as_user 20 waydroid prop get sys.boot_completed 2>/dev/null || true)
    printf '%s\n' "$out" \
        | tr -d '\r' \
        | awk 'NF { line = $0 } END { gsub(/^[[:space:]]+|[[:space:]]+$/, "", line); print line }'
}

# Cleanup state
cgroup_frozen_by_script=0
started_by_script=0
CGROUP_FREEZE="$CGROUP_DIR/cgroup.freeze"
CGROUP_EVENTS="$CGROUP_DIR/cgroup.events"
CGROUP_MEM="$CGROUP_DIR/memory.current"

thaw_cgroup() {
    if [ "$cgroup_frozen_by_script" -eq 1 ]; then
        if [ -w "$CGROUP_FREEZE" ]; then
            printf '0\n' > "$CGROUP_FREEZE" 2>/dev/null || true
        fi
        cgroup_frozen_by_script=0
    fi
}

cleanup() {
    thaw_cgroup
    if [ "$started_by_script" -eq 1 ] && [ "$KEEP" -eq 0 ]; then
        step "stop session"
        run_as_user 60 t715-android stop >/dev/null 2>&1 || true
        started_by_script=0
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Report variables (all emitted in fixed order)
session_was_running="no"
boot_completed="no"
boot_seconds=""
gles=""
gpu_driver="unknown"
launch_cold_ms=""
launch_thaw_ms=""
launch_warm_ms=""
android_mem_mb=""
host_mem_available_before_mb=""
host_mem_available_after_mb=""
crashes=""
crashed=""
gpu_faults="0"
verdict="fail"

# Step (a): preconditions
step "preconditions"
state_out=$(run_as_user 30 t715-android state 2>/dev/null || true)
installed=$(printf '%s\n' "$state_out" | tr -d '\r' | awk -F= '$1 == "installed" { print $2; exit }')
session_state=$(printf '%s\n' "$state_out" | tr -d '\r' | awk -F= '$1 == "session" { print $2; exit }')

if [ "$installed" != "yes" ]; then
    printf 'android-smoke.sh: Android (Waydroid) is not installed (installed=%s)\n' "${installed:-unknown}" >&2
    exit 4
fi

# Baseline GPU fault count in dmesg before touching Android
faults_before_lines=$(read_dmesg_gpu_faults)
gpu_faults_before=$(count_lines "$faults_before_lines")

# Step (b): host memory before
step "host memory before"
host_mem_available_before_mb=$(read_mem_available_mb)

# Step (c): start session if stopped and wait for boot_completed
step "boot"
if [ "$session_state" = "running" ]; then
    session_was_running="yes"
    if [ "$(read_boot_completed_prop)" = "1" ]; then
        boot_completed="yes"
    else
        boot_completed="no"
    fi
    boot_seconds=""
else
    session_was_running="no"
    boot_t0=$(date +%s)
    started_by_script=1
    if run_as_user 60 t715-android start >/dev/null 2>&1; then
        while :; do
            if [ "$(read_boot_completed_prop)" = "1" ]; then
                boot_completed="yes"
                break
            fi
            boot_now=$(date +%s)
            if [ $((boot_now - boot_t0)) -ge "$BOOT_TIMEOUT" ]; then
                break
            fi
            sleep 1
        done
    fi
    boot_t1=$(date +%s)
    boot_seconds=$((boot_t1 - boot_t0))
fi

android_ready=0
if [ "$boot_completed" = "yes" ] || [ "$session_was_running" = "yes" ]; then
    android_ready=1
fi

if [ "$android_ready" -eq 1 ]; then
    # Step (d): SurfaceFlinger GLES and GPU driver
    step "gles"
    sf_out=$(timeout 20 waydroid shell -- dumpsys SurfaceFlinger 2>/dev/null || true)
    gles=$(printf '%s\n' "$sf_out" \
        | tr -d '\r' \
        | awk '/^[[:space:]]*GLES:[[:space:]]*/ { sub(/^[[:space:]]*GLES:[[:space:]]*/, ""); print; exit }')
    if printf '%s\n' "$gles" | grep -qi 'panfrost'; then
        gpu_driver="panfrost"
    elif printf '%s\n' "$gles" | grep -qiE 'llvmpipe|softpipe|swiftshader'; then
        gpu_driver="software"
    else
        gpu_driver="unknown"
    fi

    # Step (e): cold launch
    step "cold launch"
    app_pkg="${APP%%/*}"
    timeout 20 waydroid shell -- am force-stop "$app_pkg" >/dev/null 2>&1 || true
    cold_rc=0
    cold_out=$(timeout 60 waydroid shell -- am start -W -n "$APP" 2>/dev/null) || cold_rc=$?
    if [ "$cold_rc" -eq 0 ]; then
        launch_cold_ms=$(parse_total_time "$cold_out")
    fi

    # Step (f): launch after freeze
    step "freeze and thaw launch"
    timeout 15 waydroid shell -- input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
    if [ -w "$CGROUP_FREEZE" ]; then
        cgroup_frozen_by_script=1
        if printf '1\n' > "$CGROUP_FREEZE" 2>/dev/null; then
            freeze_t0=$(date +%s)
            while :; do
                if [ -r "$CGROUP_EVENTS" ] && grep -Eq '^frozen[[:space:]]+1[[:space:]]*$' "$CGROUP_EVENTS" 2>/dev/null; then
                    break
                fi
                freeze_now=$(date +%s)
                if [ $((freeze_now - freeze_t0)) -ge 10 ]; then
                    break
                fi
                sleep 0.2 2>/dev/null || sleep 1
            done
            thaw_t0=$(now_ms)
            printf '0\n' > "$CGROUP_FREEZE" 2>/dev/null || true
            cgroup_frozen_by_script=0
            warm_rc=0
            warm_out=$(timeout 60 waydroid shell -- am start -W -n "$APP" 2>/dev/null) || warm_rc=$?
            thaw_t1=$(now_ms)
            if [ "$warm_rc" -eq 0 ]; then
                launch_warm_ms=$(parse_total_time "$warm_out")
                if [ -n "$launch_warm_ms" ] && [ -n "$thaw_t0" ] && [ -n "$thaw_t1" ]; then
                    launch_thaw_ms=$((thaw_t1 - thaw_t0))
                    if [ "$launch_thaw_ms" -lt 0 ]; then
                        launch_thaw_ms=0
                    fi
                fi
            fi
        else
            cgroup_frozen_by_script=0
        fi
    fi
fi

# Step (g): memory
step "memory"
if [ -r "$CGROUP_MEM" ]; then
    mem_bytes=$(tr -d '[:space:]' < "$CGROUP_MEM" 2>/dev/null || true)
    case "$mem_bytes" in
        ''|*[!0-9]*) ;;
        *) android_mem_mb=$(awk -v b="$mem_bytes" 'BEGIN { printf "%d\n", int(b / 1048576) }') ;;
    esac
fi
host_mem_available_after_mb=$(read_mem_available_mb)

# Step (h): crashes in logcat -b crash
step "crashes"
if [ "$android_ready" -eq 1 ]; then
    logcat_rc=0
    logcat_out=$(timeout 20 waydroid shell -- logcat -d -b crash 2>/dev/null) || logcat_rc=$?
    if [ "$logcat_rc" -eq 0 ]; then
        crash_procs=$(printf '%s\n' "$logcat_out" \
            | tr -d '\r' \
            | awk '/>>>.*<<</ {
                s = $0
                sub(/^.*>>>[[:space:]]*/, "", s)
                sub(/[[:space:]]*<<<.*$/, "", s)
                if (s != "") print s
            }')
        crashes=$(count_lines "$crash_procs")
        if [ -n "$crash_procs" ]; then
            crashed=$(printf '%s\n' "$crash_procs" | LC_ALL=C sort -u | paste -sd ',' -)
        else
            crashed=""
        fi
    fi
fi

# Step (i): GPU faults in dmesg
step "gpu faults"
faults_after_lines=$(read_dmesg_gpu_faults)
faults_after_count=$(count_lines "$faults_after_lines")
if [ "$faults_after_count" -gt "$gpu_faults_before" ]; then
    gpu_faults=$((faults_after_count - gpu_faults_before))
    printf '%s\n' "$faults_after_lines" | tail -n +"$((gpu_faults_before + 1))" | head -n 5 >&2
else
    gpu_faults=0
fi

# Verdict
if { [ "$boot_completed" = "yes" ] || [ "$session_was_running" = "yes" ]; } \
    && [ "$gpu_driver" = "panfrost" ] \
    && [ "$crashes" = "0" ] \
    && [ "$gpu_faults" = "0" ]; then
    verdict="pass"
    exit_code=0
else
    verdict="fail"
    exit_code=1
fi

report=$(cat <<EOF
android_smoke=1
session_was_running=$session_was_running
boot_completed=$boot_completed
boot_seconds=$boot_seconds
gles=$gles
gpu_driver=$gpu_driver
launch_cold_ms=$launch_cold_ms
launch_thaw_ms=$launch_thaw_ms
launch_warm_ms=$launch_warm_ms
android_mem_mb=$android_mem_mb
host_mem_available_before_mb=$host_mem_available_before_mb
host_mem_available_after_mb=$host_mem_available_after_mb
crashes=$crashes
crashed=$crashed
gpu_faults=$gpu_faults
verdict=$verdict
EOF
)

printf '%s\n' "$report"
if [ -n "$REPORT_FILE" ]; then
    if ! printf '%s\n' "$report" > "$REPORT_FILE"; then
        printf 'android-smoke.sh: failed to write report to %s\n' "$REPORT_FILE" >&2
    fi
fi

exit "$exit_code"
