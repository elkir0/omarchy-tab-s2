#!/usr/bin/env bash
# shellcheck disable=SC2086  # $D is a list of settings that sl splits on purpose
# test_t715_sleep.sh — off-device test of t715-sleep
# (rootfs/overlay/usr/local/sbin/t715-sleep, its three units, its enabling
# in rootfs/configure-system.sh and its checks in tests/verify-rootfs.sh).
#
# Runs the script on this machine against a temporary fake root: a sys with
# the kernel's arm switch, mem_sleep, the panel's dpms file, the two power
# supplies (Mains and Battery, with capacity) and the PMIC's RTC wakealarm;
# a proc with an ALSA card's pcm status; run, var and home trees.  The
# commands are stubs that append their arguments to a calls file and answer
# from files the scenario writes; the clock stub prints a fake epoch and
# the sleep stub advances it by its argument, so a run scenario drives time
# and the screen (a per-poll script may switch the dpms file from On to Off
# at a given poll) without waiting.
#
# In the style of tests/test_t715_wifi_guard.sh (omarchy-tab-s2, MIT).
#
# Usage: tests/test_t715_sleep.sh
# Prints "ok - ..." per group, "PASS" at the end; exit 1 on the first
# failure (with what the stubs collected).  Needs bash 3.2 or later;
# nothing outside a temporary directory.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SL="$here/rootfs/overlay/usr/local/sbin/t715-sleep"
[ -f "$SL" ] || { echo "SETUP ERROR: no $SL" >&2; exit 2; }
for u in t715-sleep t715-sleep-prepare t715-sleep-restore; do
    [ -f "$here/rootfs/overlay/etc/systemd/system/$u.service" ] \
        || { echo "SETUP ERROR: no $u.service" >&2; exit 2; }
done

t=$(mktemp -d "${TMPDIR:-/tmp}/t715-sleep-test.XXXXXX")
cleanup() { rm -rf "$t"; }
trap cleanup EXIT

fail() {
    printf 'not ok - %s\n' "$1" >&2
    echo "--- logger" >&2; cat "$t/log" 2>/dev/null || true
    echo "--- calls" >&2; cat "$t/calls" 2>/dev/null || true
    echo "--- stdout" >&2; cat "$t/out" 2>/dev/null || true
    exit 1
}

# --- stand-ins --------------------------------------------------------------------
mkdir -p "$t/bin"
# logger: the script's decision lines land here, whatever they say, and in
# a copy kept over all the scenarios, for the privacy check (j).
cat > "$t/bin/logger" <<'STUB'
#!/bin/sh
[ "${1:-}" = "-t" ] && shift 2
printf '%s\n' "$*" >> "$T715_TEST_LOG"
printf '%s\n' "$*" >> "$T715_TEST_LOG_ALL"
STUB
# date: the fake epoch, which only the sleep stub advances.
cat > "$t/bin/date" <<'STUB'
#!/bin/sh
cat "$T715_TEST_CLOCK" 2>/dev/null || printf '1000\n'
STUB
# sleep: advance the fake clock by its argument and run the per-poll
# script, so a run scenario can switch the screen or the world at a poll.
cat > "$t/bin/sleep" <<'STUB'
#!/bin/sh
n=$(cat "$T715_TEST_CLOCK" 2>/dev/null)
case $n in ''|*[!0-9]*) n=1000 ;; esac
case $1 in ''|*[!0-9]*) : ;; *) n=$((n + $1)) ;; esac
printf '%s\n' "$n" > "$T715_TEST_CLOCK"
if [ -n "${T715_TEST_POLL_SCRIPT:-}" ] && [ -f "$T715_TEST_POLL_SCRIPT" ]; then
    sh "$T715_TEST_POLL_SCRIPT"
fi
exit 0
STUB
# id: the scenario's answer (the switch is root only).
cat > "$t/bin/id" <<'STUB'
#!/bin/sh
cat "$T715_TEST_UID" 2>/dev/null || printf '0\n'
STUB
# systemctl: every call recorded; the answers come from files the scenario
# writes.  `suspend` answers systemctl.suspend.rc; `poweroff` records and
# answers 0; is-enabled from systemctl.is-enabled; is-active likewise, and a
# unit started --no-block reads activating from then on.
cat > "$t/bin/systemctl" <<'STUB'
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "$T715_TEST_CALLS"
case "$1" in
    suspend)  [ -f "$T715_TEST_ST/suspend.rc" ] && exit "$(cat "$T715_TEST_ST/suspend.rc")"
              exit 0 ;;
    poweroff) exit 0 ;;
    is-enabled)
        if [ -f "$T715_TEST_ST/is-enabled.$2" ]; then cat "$T715_TEST_ST/is-enabled.$2"; exit 0; fi
        if [ -f "$T715_TEST_ST/is-enabled" ]; then cat "$T715_TEST_ST/is-enabled"; exit 0; fi
        exit 1 ;;
    is-active)
        if [ -f "$T715_TEST_ST/is-active.$2" ]; then cat "$T715_TEST_ST/is-active.$2"; exit 0; fi
        if [ -f "$T715_TEST_ST/is-active" ]; then cat "$T715_TEST_ST/is-active"; exit 0; fi
        exit 3 ;;
    start)
        # A unit started --no-block reads activating from then on, as
        # systemd shows a oneshot while its ExecStart runs.
        [ "$2" = --no-block ] && printf 'activating\n' > "$T715_TEST_ST/is-active.$3"
        exit 0 ;;
    stop) exit 0 ;;
esac
exit 0
STUB
# loginctl: list-sessions prints the sessions file; show-session answers
# Remote and State from per-session files (session.N.remote, session.N.state).
cat > "$t/bin/loginctl" <<'STUB'
#!/bin/sh
printf 'loginctl %s\n' "$*" >> "$T715_TEST_CALLS"
case "$1" in
    list-sessions) cat "$T715_TEST_ST/sessions" 2>/dev/null || true; exit 0 ;;
    show-session)
        id=""; prop=""
        while [ $# -gt 0 ]; do
            case "$1" in
                -p) shift; prop=${1#-p=} ;;
                --value) : ;;
                show-session) : ;;
                *) id=$1 ;;
            esac
            shift
        done
        f="$T715_TEST_ST/session.$id.$prop"
        [ -f "$f" ] && { cat "$f"; exit 0; }
        exit 1 ;;
esac
exit 0
STUB
# busctl: the tree listing from bluez.tree; a get-property answer from the
# per-path file, so only the paths the scenario lists are ever asked.
cat > "$t/bin/busctl" <<'STUB'
#!/bin/sh
printf 'busctl %s\n' "$*" >> "$T715_TEST_CALLS"
if [ "$1" = "--system" ] && [ "$2" = "--list" ]; then
    cat "$T715_TEST_ST/bluez.tree" 2>/dev/null || true
    exit 0
fi
if [ "$1" = "--json=short" ] && [ "$2" = "call" ] && [ "$6" = "ListInhibitors" ]; then
    # logind's inhibitors: inhibitors.json, else none
    if [ -f "$T715_TEST_ST/inhibitors.json" ]; then cat "$T715_TEST_ST/inhibitors.json"
    else printf '{"type":"a(ssssuu)","data":[[]]}\n'; fi
    exit 0
fi
if [ "$1" = "--system" ] && [ "$2" = "get-property" ]; then
    path=$4
    f="$T715_TEST_ST/bluez.path$(printf '%s' "$path" | sed 's|/|_|g')"
    [ -f "$f" ] && { cat "$f"; exit 0; }
    exit 1
fi
exit 1
STUB
# The Wi-Fi guard stub: every subcommand recorded, its exit code from a
# per-verb file (guard.off.rc, guard.check.rc, guard.recover.rc).
cat > "$t/bin/guard" <<'STUB'
#!/bin/sh
printf 'guard %s\n' "$*" >> "$T715_TEST_CALLS"
[ -f "$T715_TEST_ST/guard.$1.rc" ] && exit "$(cat "$T715_TEST_ST/guard.$1.rc")"
exit 0
STUB
# The modem command: the calls recorded; status --json answers one line per
# call from modem.seq (the last line repeating; a missing file means no
# modem: nothing printed, exit 1).
cat > "$t/bin/modem" <<'STUB'
#!/bin/sh
printf 'modem %s\n' "$*" >> "$T715_TEST_CALLS"
if [ "$1" = status ]; then
    [ -f "$T715_TEST_ST/modem.seq" ] || exit 1
    n=$(cat "$T715_TEST_ST/modem.calls" 2>/dev/null)
    case $n in ''|*[!0-9]*) n=0 ;; esac
    n=$((n + 1))
    printf '%s\n' "$n" > "$T715_TEST_ST/modem.calls"
    line=$(sed -n "${n}p" "$T715_TEST_ST/modem.seq" 2>/dev/null)
    [ -n "$line" ] || line=$(tail -n 1 "$T715_TEST_ST/modem.seq" 2>/dev/null)
    [ -n "$line" ] || exit 1
    printf '%s\n' "$line"
    exit 0
fi
exit 0
STUB
# shannonctl: status answers from shannonctl.json; a missing file means a
# failing command (no call up).
cat > "$t/bin/shannonctl" <<'STUB'
#!/bin/sh
printf 'shannonctl %s\n' "$*" >> "$T715_TEST_CALLS"
if [ "$1" = status ]; then
    [ -f "$T715_TEST_ST/shannonctl.json" ] && { cat "$T715_TEST_ST/shannonctl.json"; exit 0; }
    exit 1
fi
exit 0
STUB
# nmcli: the active connections, one name per line.
cat > "$t/bin/nmcli" <<'STUB'
#!/bin/sh
printf 'nmcli %s\n' "$*" >> "$T715_TEST_CALLS"
cat "$T715_TEST_ST/nmcli" 2>/dev/null || true
exit 0
STUB
chmod +x "$t/bin"/*
export T715_TEST_LOG="$t/log" T715_TEST_LOG_ALL="$t/log.all" \
       T715_TEST_CLOCK="$t/clock" T715_TEST_CALLS="$t/calls" \
       T715_TEST_ST="$t/st" T715_TEST_UID="$t/uid"
: > "$t/log.all"
# Everything the script prints, over all the scenarios, for the privacy
# check (j): the log (the logger stub's copy), stdout and stderr.
: > "$t/out.all"
: > "$t/err.all"

# --- the fake root ------------------------------------------------------------------
S=$t/root/sys
R=$t/root/run
V=$t/root/var/lib/t715-sleep
H=$t/root/home
ARM_F=$S/module/exynos5433_sleep/parameters/arm
MEM_SLEEP=$S/power/mem_sleep
DPMS=$S/class/drm/card0-DSI-1/dpms
CHG=$S/class/power_supply/sm5703-charger
BAT=$S/class/power_supply/sm5703-fuelgauge
ALARM=$S/class/rtc/rtc0/wakealarm
ALSA=$t/root/proc/asound/card0/pcm0p/sub0/status

mk_root() {
    rm -rf "$t/root" "$t/st"
    mkdir -p "$t/st"
    mkdir -p "$S/module/exynos5433_sleep/parameters" "$S/power" \
             "$S/class/drm/card0-DSI-1" "$CHG" "$BAT" "$S/class/rtc/rtc0" \
             "$(dirname "$ALSA")" "$R" "$V" "$H/alice/.local/state/omarchy/indicators"
    printf 'N\n' > "$ARM_F"
    printf 's2idle [deep]\n' > "$MEM_SLEEP"
    printf 'On\n' > "$DPMS"
    printf 'Mains\n' > "$CHG/type"
    printf '0\n' > "$CHG/online"
    printf 'Battery\n' > "$BAT/type"
    printf '80\n' > "$BAT/capacity"
    printf 'Discharging\n' > "$BAT/status"
    printf '0\n' > "$ALARM"
    printf 'closed\n' > "$ALSA"
    printf '1000\n' > "$t/clock"
    : > "$t/calls"
    : > "$t/log"
}

# sl [NAME=VALUE...] -- t715-sleep args...: the script on the fake root,
# with the stubs first in PATH, stdout and stderr kept, and SL_RC its exit
# code; everything it printed also accumulates, for the privacy check.
sl() {
    local envs cmd
    envs=""
    while [ $# -gt 0 ]; do
        case $1 in
            *=*) envs="$envs $1"; shift ;;
            *) break ;;
        esac
    done
    : > "$t/out"
    : > "$t/err"
    SL_RC=0
    cmd="env$envs
T715_SLEEP_SYS=$S T715_SLEEP_PROC=$t/root/proc
T715_SLEEP_RUN=$R T715_SLEEP_VAR=$V T715_SLEEP_HOME=$H
T715_SLEEP_PACMAN_LOCK=$t/root/var/lib/pacman/db.lck
T715_SLEEP_GUARD=guard T715_SLEEP_GUARD_LOCK=$t/st/guard.lock
T715_SLEEP_MODEM=modem T715_SLEEP_SHANNONCTL=shannonctl
T715_SLEEP_NMCLI=nmcli T715_SLEEP_SYSTEMCTL=systemctl
T715_SLEEP_LOGINCTL=loginctl T715_SLEEP_BUSCTL=busctl
T715_SLEEP_NOW=date T715_SLEEP_SLEEP=sleep
T715_SLEEP_LOGGER=logger T715_SLEEP_RTC=rtc0"
    # shellcheck disable=SC2086
    $cmd PATH="$t/bin:$PATH" "$SL" "$@" > "$t/out" 2> "$t/err" || SL_RC=$?
    cat "$t/out" >> "$t/out.all"
    cat "$t/err" >> "$t/err.all"
    return 0
}

# The default numbers, small enough that a scenario runs no real time.
D="T715_SLEEP_AFTER=10 T715_SLEEP_QUICK=5 T715_SLEEP_POLL=5 \
T715_SLEEP_CHECK_HOURS=12 T715_SLEEP_LOW=5 T715_SLEEP_MAX_POLLS=20"

dark_screen()   { printf 'Off\n' > "$DPMS"; }
lit_screen()    { printf 'On\n' > "$DPMS"; }
n_lines()       { wc -l < "$1" | tr -d ' '; }
log_has()       { grep -qF "$1" "$t/log"; }
log_count()     { grep -cF "$1" "$t/log" || true; }
calls_has()     { grep -qF "$1" "$t/calls"; }
calls_count()   { grep -cF "$1" "$t/calls" || true; }

# --- (a) the kernel gate: no arm file, no sleep, nothing prepared ---------------------
mk_root
rm -f "$ARM_F"
sl $D run
[ "$SL_RC" = 0 ] || fail "(a) run without the arm file exits 0 (got $SL_RC)"
log_has 'this kernel has no system sleep: suspend masked until the next boot' \
    || fail "(a) run logs the gate line (log: $(cat "$t/log"))"
calls_has 'systemctl mask --runtime sleep.target suspend.target' \
    || fail "(a) run masks the sleep targets until the next boot (calls: $(cat "$t/calls"))"
[ "$(calls_count 'systemctl suspend')" = 0 ] \
    || fail "(a) run without the arm file suspends nothing"
# The same gate from mem_sleep without [deep], for prepare and resume: they
# write nothing at all, not even the arm switch.
printf 'N\n' > "$ARM_F"
printf 's2idle deep\n' > "$MEM_SLEEP"
sl prepare
[ "$SL_RC" = 0 ] || fail "(a) prepare without deep exits 0 (got $SL_RC)"
[ ! -e "$R/asleep-at" ] && [ ! -e "$R/cp" ] && [ ! -e "$R/wifi" ] && [ ! -e "$R/alarm" ] \
    || fail "(a) prepare without deep writes nothing (run: $(ls "$R"))"
[ "$(cat "$ARM_F" 2>/dev/null)" = N ] \
    || fail "(a) prepare without deep does not touch the arm switch"
sl resume
[ "$SL_RC" = 0 ] || fail "(a) resume without deep exits 0 (got $SL_RC)"
[ "$(n_lines "$t/log")" = 1 ] \
    || fail "(a) prepare and resume stay silent (log: $(cat "$t/log"))"
sl $D run
log_has 'this kernel has no system sleep: suspend masked until the next boot' \
    || fail "(a) mem_sleep without [deep] is no system sleep either (log: $(cat "$t/log"))"
echo "ok - kernel gate: no arm file or no deep: run masks suspend and says so, prepare and resume do nothing"

# --- (b) the dark count: no sleep before AFTER, exactly one, reset by a lit screen ----
mk_root
sl $D run
[ "$SL_RC" = 0 ] || fail "(b) run exits 0 (got $SL_RC)"
[ "$(calls_count 'systemctl suspend --check-inhibitors=no')" = 0 ] \
    || fail "(b) a lit screen never suspends (calls: $(cat "$t/calls"))"
# The per-poll script: dark from the second poll on.
printf '%s\n' 'printf "Off\n" > "'"$DPMS"'"' > "$t/poll.sh"
mk_root
T715_TEST_POLL_SCRIPT="$t/poll.sh" sl $D run
# Poll 1 reads the screen lit (the script runs after the first sleep); the
# count 5, 10, 10... reaches AFTER=10 at poll 3, and suspends there.
[ "$(calls_count 'systemctl suspend --check-inhibitors=no')" -ge 1 ] \
    || fail "(b) a dark screen suspends once AFTER (calls: $(cat "$t/calls"))"
log_has 'screen off for 10 s on battery: suspending' \
    || fail "(b) the suspend line carries the count (log: $(cat "$t/log"))"
echo "ok - the dark count: lit never sleeps, dark sleeps after AFTER, with the count in the line"

# --- (c) each reason holds the sleep, and is logged once ------------------------------
# reason NAME LINE: the world is set up by hand before the call; the reason
# holds the sleep and its fixed line is logged once.
reason() {
    local name=$1 line=$2
    printf '%s\n' 'exit 0' > "$t/poll.sh"
    T715_TEST_POLL_SCRIPT="$t/poll.sh" sl $D run
    [ "$(calls_count 'systemctl suspend --check-inhibitors=no')" = 0 ] \
        || fail "($name) no suspend while the reason holds (calls: $(cat "$t/calls"))"
    [ "$(log_count "not sleeping: $line")" = 1 ] \
        || fail "($name) logged once (log: $(cat "$t/log"))"
    echo "ok - $name holds the sleep, its line logged once"
}
mk_root
dark_screen
printf '1\n' > "$CHG/online"
reason c1 'external power'
mk_root
dark_screen
printf 'state: RUNNING\n' > "$ALSA"
reason c2 'audio playing'
mk_root
dark_screen
mkdir -p "$t/st"
printf '/org/bluez/hci0/dev_11_22_33_44_55_66/fd1\n' > "$t/st/bluez.tree"
printf 's "active"\n' > "$t/st/bluez.path_org_bluez_hci0_dev_11_22_33_44_55_66_fd1"
reason c3 'Bluetooth audio playing'
# A transport that is not active does not hold the sleep.
mk_root
dark_screen
mkdir -p "$t/st"
printf '/org/bluez/hci0/dev_11_22_33_44_55_66/fd1\n' > "$t/st/bluez.tree"
printf 's "idle"\n' > "$t/st/bluez.path_org_bluez_hci0_dev_11_22_33_44_55_66_fd1"
printf '%s\n' 'exit 0' > "$t/poll.sh"
T715_TEST_POLL_SCRIPT="$t/poll.sh" sl $D run
[ "$(calls_count 'systemctl suspend --check-inhibitors=no')" -ge 1 ] \
    || fail "(c3) an idle transport holds nothing (calls: $(cat "$t/calls"))"
# A call.
mk_root
dark_screen
mkdir -p "$t/st"
printf '{"calls":["+33612345678"]}\n' > "$t/st/shannonctl.json"
reason c4 'a call'                 true
mk_root
dark_screen
printf '%s\n' 'exit 0' > "$t/poll.sh"
printf '{"calls":[]}\n' > "$t/st/shannonctl.json"
T715_TEST_POLL_SCRIPT="$t/poll.sh" sl $D run
[ "$(calls_count 'systemctl suspend --check-inhibitors=no')" -ge 1 ] \
    || fail "(c4) no call, no hold (calls: $(cat "$t/calls"))"
# The hotspot.
mk_root
dark_screen
printf 'Hotspot\n' > "$t/st/nmcli"
reason c5 'the hotspot'            true
mk_root
dark_screen
printf 'wlan0\n' > "$t/st/nmcli"
printf '%s\n' 'exit 0' > "$t/poll.sh"
T715_TEST_POLL_SCRIPT="$t/poll.sh" sl $D run
[ "$(calls_count 'systemctl suspend --check-inhibitors=no')" -ge 1 ] \
    || fail "(c5) another connection name holds nothing (calls: $(cat "$t/calls"))"
# A remote session.
mk_root
dark_screen
printf '2 0 uid0\n3 0 uid1000\n' > "$t/st/sessions"
printf 'yes\n' > "$t/st/session.2.Remote"
printf 'active\n' > "$t/st/session.2.State"
reason c6 'a remote login session'
# A block-mode sleep inhibitor in logind; delay locks (NetworkManager, the
# lock screen) hold nothing.
mk_root
dark_screen
printf '%s\n' '{"type":"a(ssssuu)","data":[[["sleep","NetworkManager","turn off networks","delay",0,787],["sleep:shutdown","Player","playing","block",1000,99]]]}' > "$t/st/inhibitors.json"
reason c6b 'a sleep inhibitor'
mk_root
dark_screen
printf '%s\n' '{"type":"a(ssssuu)","data":[[["sleep","NetworkManager","turn off networks","delay",0,787],["shutdown","Updater","writing","block",0,98]]]}' > "$t/st/inhibitors.json"
printf '%s\n' 'exit 0' > "$t/poll.sh"
T715_TEST_POLL_SCRIPT="$t/poll.sh" sl $D run
[ "$(calls_count 'systemctl suspend --check-inhibitors=no')" -ge 1 ] \
    || fail "(c6b) delay locks and a shutdown-only block hold nothing (calls: $(cat "$t/calls"))"
mk_root
dark_screen
printf '2 0 uid0\n3 0 uid1000\n' > "$t/st/sessions"
printf 'yes\n' > "$t/st/session.2.Remote"
printf 'closing\n' > "$t/st/session.2.State"
printf '%s\n' 'exit 0' > "$t/poll.sh"
T715_TEST_POLL_SCRIPT="$t/poll.sh" sl T715_SLEEP_AFTER=10 T715_SLEEP_QUICK=5 \
    T715_SLEEP_POLL=5 T715_SLEEP_CHECK_HOURS=12 T715_SLEEP_LOW=5 \
    T715_SLEEP_REMOTE=ignore T715_SLEEP_MAX_POLLS=8 run
[ "$(calls_count 'systemctl suspend --check-inhibitors=no')" -ge 1 ] \
    || fail "(c6) REMOTE=ignore lets it sleep (calls: $(cat "$t/calls"))"
# Stay awake.
mk_root
dark_screen
touch "$H/alice/.local/state/omarchy/indicators/stay-awake"
reason c7 'stay-awake'             true
# A package transaction.
mk_root
dark_screen
mkdir -p "$t/root/var/lib/pacman"
touch "$t/root/var/lib/pacman/db.lck"
reason c8 'a package transaction'  true
# A Wi-Fi recovery holding the guard's lock.
if command -v flock >/dev/null 2>&1; then
    mk_root
    dark_screen
    printf '%s\n' 'exit 0' > "$t/poll.sh"
    (
        flock -x 9
        printf 'held\n' > "$t/st/holder"
        /bin/sleep 2
    ) 9>"$t/st/guard.lock" &
    holder=$!
    i=0
    while [ ! -f "$t/st/holder" ] && [ "$i" -lt 50 ]; do /bin/sleep 0.1; i=$((i + 1)); done
    T715_TEST_POLL_SCRIPT="$t/poll.sh" sl $D run
    wait "$holder" || true
    [ "$(log_count 'not sleeping: a Wi-Fi recovery')" = 1 ] \
        || fail "(c9) the held lock is logged once (log: $(cat "$t/log"))"
    [ "$(calls_count 'systemctl suspend --check-inhibitors=no')" = 0 ] \
        || fail "(c9) no suspend over a recovery (calls: $(cat "$t/calls"))"
else
    echo "ok - no flock here: the recovery check is skipped, as it is without util-linux"
fi
# The CP between states.
mk_root
dark_screen
printf '{"cp":"booting"}\n' > "$t/st/modem.seq"
reason c10 'the CP between states' true
mk_root
dark_screen
printf '{"cp":"online"}\n' > "$t/st/modem.seq"
printf '%s\n' 'exit 0' > "$t/poll.sh"
T715_TEST_POLL_SCRIPT="$t/poll.sh" sl $D run
[ "$(calls_count 'systemctl suspend --check-inhibitors=no')" -ge 1 ] \
    || fail "(c10) an online CP holds nothing (calls: $(cat "$t/calls"))"
# A suspend logind refuses is itself a reason, logged once.
mk_root
dark_screen
printf '1\n' > "$t/st/suspend.rc"
printf '%s\n' 'exit 0' > "$t/poll.sh"
T715_TEST_POLL_SCRIPT="$t/poll.sh" sl $D run
[ "$(log_count 'suspend refused by logind')" = 1 ] \
    || fail "(c) the refused suspend is logged once (log: $(cat "$t/log"))"
[ "$(log_count 'not sleeping: suspend refused by logind')" = 0 ] \
    || fail "(c) the refusal is not doubled (log: $(cat "$t/log"))"
[ "$(calls_count 'systemctl suspend --check-inhibitors=no')" -ge 2 ] \
    || fail "(c) a refused suspend is tried again after another AFTER (calls: $(cat "$t/calls"))"
[ "$(log_count 'screen off for')" = 1 ] \
    || fail "(c) the suspending line said once while the refusals go on (log: $(cat "$t/log"))"
echo "ok - reasons: each holds the sleep and is logged once; ignore and online drop theirs"

# --- (d) the switch ------------------------------------------------------------------
mk_root
dark_screen
printf 'off\n' > "$V/mode"
printf '%s\n' 'exit 0' > "$t/poll.sh"
T715_TEST_POLL_SCRIPT="$t/poll.sh" sl $D run
[ "$(log_count 'sleep is switched off')" = 1 ] \
    || fail "(d) the switched-off line, once (log: $(cat "$t/log"))"
[ "$(calls_count 'systemctl suspend --check-inhibitors=no')" = 0 ] \
    || fail "(d) off stops sleeping (calls: $(cat "$t/calls"))"
# On again: the sleep comes back within one poll.
mk_root
dark_screen
printf '%s\n' 'exit 0' > "$t/poll.sh"
printf '%s\n' 'printf "off\n" > "'"$V/mode"'"' > "$t/poll.sh"
T715_TEST_POLL_SCRIPT="$t/poll.sh" sl $D run
[ "$(log_count 'sleep is switched off')" -ge 1 ] \
    || fail "(d) the off read at every poll (log: $(cat "$t/log"))"
# The switch is root only: a non-root id is refused, root writes it.
mk_root
printf '1000\n' > "$t/uid"
sl off
[ "$SL_RC" = 1 ] || fail "(d) off as non-root exits 1 (got $SL_RC)"
[ ! -e "$V/mode" ] || fail "(d) off as non-root writes nothing"
sl on
[ "$SL_RC" = 1 ] || fail "(d) on as non-root exits 1 (got $SL_RC)"
[ ! -e "$V/mode" ] || fail "(d) on as non-root writes nothing"
printf '0\n' > "$t/uid"
sl on
[ "$SL_RC" = 0 ] || fail "(d) on as root exits 0 (got $SL_RC)"
[ "$(cat "$V/mode")" = on ] || fail "(d) on writes on"
sl off
[ "$SL_RC" = 0 ] || fail "(d) off as root exits 0 (got $SL_RC)"
[ "$(cat "$V/mode")" = off ] || fail "(d) off writes off"
echo "ok - the switch: off stops sleeping with one line, on brings it back, root only"

# --- (e) prepare, the normal case ------------------------------------------------------
mk_root
printf 'enabled\n' > "$t/st/is-enabled.shannon-modem-prepare.service"
# online before the stop, off once the units are stopped: the stub answers
# off from its second call on.
cat > "$t/st/modem.seq" <<'SEQ'
{"cp":"online"}
{"cp":"off"}
SEQ
sl $D prepare
[ "$SL_RC" = 0 ] || fail "(e) prepare exits 0 (got $SL_RC)"
want='systemctl stop shannon-modem-prepare.service
systemctl stop shannond.service shannon-loader.service
guard off'
[ "$(printf '%s\n' "$want")" = "$(grep -Ex 'systemctl stop.*|guard off' "$t/calls" | head -n 3)" ] \
    || fail "(e) the stop calls in order, prepare first (calls: $(cat "$t/calls"))"
[ -e "$R/cp" ] || fail "(e) the cp marker"
[ -e "$R/wifi" ] || fail "(e) the wifi marker"
[ "$(cat "$ARM_F")" = 1 ] || fail "(e) armed (arm reads $(cat "$ARM_F"))"
log_has 'prepare: CP off' || fail "(e) CP off is logged (log: $(cat "$t/log"))"
log_has 'prepare: CP, Wi-Fi and Bluetooth off: this suspend sleeps' \
    || fail "(e) the armed line (log: $(cat "$t/log"))"
[ "$(cat "$ALARM")" -gt 1000 ] 2>/dev/null \
    || fail "(e) the alarm written as +43200 (wakealarm reads $(cat "$ALARM" 2>/dev/null))"
[ -e "$R/alarm" ] && [ "$(cat "$R/alarm")" = "$(cat "$ALARM")" ] \
    || fail "(e) the alarm read back into run (alarm: $(cat "$R/alarm" 2>/dev/null))"
[ "$(cat "$R/asleep-at" 2>/dev/null)" -gt 0 ] || fail "(e) asleep-at written"
echo "ok - prepare: the CP stopped first, the chip down, the alarm set and read back, armed"

# --- (e2) prepare on external power: the radios down, not armed ------------------------
# A dry run with the Wi-Fi up would put brcmfmac through a suspend it cannot
# keep: the CP and the chip go down as on battery, the markers say so (the
# restore brings them back at the resume), and only the arming is left out.
mk_root
printf '1\n' > "$CHG/online"
printf 'enabled\n' > "$t/st/is-enabled.shannon-modem-prepare.service"
cat > "$t/st/modem.seq" <<'SEQ'
{"cp":"online"}
{"cp":"off"}
SEQ
sl $D prepare
[ "$SL_RC" = 0 ] || fail "(e2) prepare exits 0 (got $SL_RC)"
calls_has 'systemctl stop shannond.service shannon-loader.service' \
    || fail "(e2) the CP stopped all the same (calls: $(cat "$t/calls"))"
calls_has 'guard off' || fail "(e2) the chip powered down all the same (calls: $(cat "$t/calls"))"
[ -e "$R/cp" ] && [ -e "$R/wifi" ] || fail "(e2) the markers (run: $(ls "$R"))"
[ "$(cat "$ARM_F")" = 0 ] || fail "(e2) the arm switch at 0 (reads $(cat "$ARM_F"))"
log_has 'prepare: on external power: this suspend stays a dry run' \
    || fail "(e2) the dry-run line (log: $(cat "$t/log"))"
log_count 'prepare: CP, Wi-Fi and Bluetooth off: this suspend sleeps' | grep -qx 0 \
    || fail "(e2) no armed line (log: $(cat "$t/log"))"
echo "ok - prepare on external power: the CP and the chip down, the markers, arm 0"

# --- (e3) guard off fails: not armed, no wifi marker -----------------------------------
mk_root
printf 'enabled\n' > "$t/st/is-enabled.shannon-modem-prepare.service"
printf '{"cp":"online"}\n' > "$t/st/modem.seq"
printf '1\n' > "$t/st/guard.off.rc"
sl $D prepare
[ "$SL_RC" = 0 ] || fail "(e3) prepare still exits 0 (got $SL_RC)"
[ "$(cat "$ARM_F")" = 0 ] || fail "(e3) not armed (arm reads $(cat "$ARM_F"))"
[ ! -e "$R/wifi" ] || fail "(e3) no wifi marker"
log_has 'prepare: the Wi-Fi/Bluetooth chip did not power down (exit 1)' \
    || fail "(e3) the chip's refusal is logged (log: $(cat "$t/log"))"
log_has 'prepare: this suspend stays a dry run' \
    || fail "(e3) the dry-run line (log: $(cat "$t/log"))"
echo "ok - prepare with the chip refusing: dry run, no wifi marker"

# --- (e4) an alarm already pending is left as it is ------------------------------------
mk_root
printf 'enabled\n' > "$t/st/is-enabled.shannon-modem-prepare.service"
printf '{"cp":"off"}\n' > "$t/st/modem.seq"
printf '999999\n' > "$ALARM"
sl $D prepare
[ "$(cat "$ALARM")" = 999999 ] \
    || fail "(e4) someone else's alarm untouched (wakealarm reads $(cat "$ALARM"))"
[ ! -e "$R/alarm" ] || fail "(e4) no alarm marker of ours"
[ "$(cat "$ARM_F")" = 1 ] || fail "(e4) the CP already off: armed anyway"
[ ! -e "$R/cp" ] || fail "(e4) no cp marker for a CP already off"
[ "$(calls_count 'systemctl stop')" = 0 ] \
    || fail "(e4) a CP already off is not stopped again (calls: $(cat "$t/calls"))"
echo "ok - prepare: a pending alarm left alone, a CP already off left running off"

# --- (e5) the modem disabled: no stop calls, no marker, armed ---------------------------
mk_root
printf 'disabled\n' > "$t/st/is-enabled.shannon-modem-prepare.service"
printf '{"cp":"online"}\n' > "$t/st/modem.seq"
sl $D prepare
[ "$(calls_count 'systemctl stop')" = 0 ] \
    || fail "(e5) a disabled modem stops nothing (calls: $(cat "$t/calls"))"
[ ! -e "$R/cp" ] || fail "(e5) no cp marker"
[ "$(cat "$ARM_F")" = 1 ] || fail "(e5) armed (arm reads $(cat "$ARM_F"))"
echo "ok - prepare with the modem disabled: no stop, no marker, armed"

# --- (f) resume after a key wake --------------------------------------------------------
mk_root
printf '500\n' > "$R/asleep-at"
printf '0\n' > "$R/resumed"
printf '999999\n' > "$ALARM"
printf '999999\n' > "$R/alarm"
sl resume
[ "$SL_RC" = 0 ] || fail "(f) resume exits 0 (got $SL_RC)"
[ "$(cat "$ARM_F")" = 0 ] || fail "(f) disarmed (arm reads $(cat "$ARM_F"))"
log_has 'woke up after 500 s' || fail "(f) the sleep's length (log: $(cat "$t/log"))"
[ "$(cat "$R/resumed")" = 1000 ] || fail "(f) the resumed marker (reads $(cat "$R/resumed"))"
[ "$(cat "$ALARM" 2>/dev/null)" = 0 ] \
    || fail "(f) the alarm cleared (wakealarm reads $(cat "$ALARM" 2>/dev/null))"
[ ! -e "$R/alarm" ] || fail "(f) the alarm marker dropped"
[ ! -e "$R/check" ] || fail "(f) no check marker"
calls_has 'systemctl start --no-block t715-sleep-restore.service' \
    || fail "(f) the restore unit started (calls: $(cat "$t/calls"))"
echo "ok - resume after a key wake: disarmed, timed, alarm cleared, restore started"

# --- (f2) resume after the battery check -----------------------------------------------
mk_root
printf '400\n' > "$R/asleep-at"
printf '0\n' > "$R/resumed"
printf '1050\n' > "$ALARM"
printf '1050\n' > "$R/alarm"
sl resume
[ "$SL_RC" = 0 ] || fail "(f2) resume exits 0 (got $SL_RC)"
[ -e "$R/check" ] || fail "(f2) the check marker"
log_has 'woke up for the battery check: the radios stay off' \
    || fail "(f2) the battery-check line (log: $(cat "$t/log"))"
[ "$(calls_count 'start --no-block t715-sleep-restore.service')" = 0 ] \
    || fail "(f2) no restore at a battery check (calls: $(cat "$t/calls"))"
echo "ok - resume at the alarm: the check marker, the radios left off"

# --- (g) restore -----------------------------------------------------------------------
mk_root
: > "$R/cp"
: > "$R/wifi"
: > "$R/check"
printf 'enabled\n' > "$t/st/is-enabled.shannon-modem-prepare.service"
printf '0\n' > "$t/st/guard.check.rc"
sl restore
[ "$SL_RC" = 0 ] || fail "(g) restore exits 0 (got $SL_RC)"
calls_has 'systemctl start --no-block shannon-modem-prepare.service' \
    || fail "(g) the CP started (calls: $(cat "$t/calls"))"
log_has 'restore: CP starting' || fail "(g) the CP line (log: $(cat "$t/log"))"
[ "$(calls_count 'guard recover')" = 0 ] \
    || fail "(g) no recover while the Wi-Fi is up (calls: $(cat "$t/calls"))"
log_has 'restore: the Wi-Fi is already up' \
    || fail "(g) the already-up line (log: $(cat "$t/log"))"
[ ! -e "$R/cp" ] && [ ! -e "$R/wifi" ] && [ ! -e "$R/check" ] \
    || fail "(g) the markers removed (run: $(ls "$R"))"
mk_root
: > "$R/wifi"
printf '1\n' > "$t/st/guard.check.rc"
printf '0\n' > "$t/st/guard.recover.rc"
sl restore
calls_has 'guard recover' || fail "(g2) recover when the check fails (calls: $(cat "$t/calls"))"
log_has 'restore: the Wi-Fi came back' || fail "(g2) the came-back line (log: $(cat "$t/log"))"
mk_root
: > "$R/wifi"
printf '1\n' > "$t/st/guard.check.rc"
printf '2\n' > "$t/st/guard.recover.rc"
sl restore
log_has 'restore: the Wi-Fi did not come back (exit 2)' \
    || fail "(g3) the failure line (log: $(cat "$t/log"))"
[ ! -e "$R/wifi" ] || fail "(g3) the marker removed even on failure"
mk_root
: > "$R/cp"
printf 'disabled\n' > "$t/st/is-enabled.shannon-modem-prepare.service"
sl restore
[ "$(calls_count 'start --no-block shannon-modem-prepare.service')" = 0 ] \
    || fail "(g4) a disabled modem is not started (calls: $(cat "$t/calls"))"
[ ! -e "$R/cp" ] || fail "(g4) the cp marker still dropped"
# (g5) the CP started first (--no-block), then the chip through recover.
mk_root
: > "$R/cp"
: > "$R/wifi"
printf 'enabled\n' > "$t/st/is-enabled.shannon-modem-prepare.service"
printf '1\n' > "$t/st/guard.check.rc"
printf '0\n' > "$t/st/guard.recover.rc"
sl restore
rec=$(grep -n '^guard recover' "$t/calls" | head -n 1 | cut -d: -f1)
cp=$(grep -n '^systemctl start --no-block shannon-modem-prepare.service' "$t/calls" | head -n 1 | cut -d: -f1)
[ -n "$rec" ] && [ -n "$cp" ] && [ "$cp" -lt "$rec" ] \
    || fail "(g5) the CP start before the recover (calls: $(cat "$t/calls"))"
echo "ok - restore: the CP per the modem's choice, the chip through recover, markers gone"

# --- (h) a lit screen with markers starts the restore once ------------------------------
mk_root
dark_screen
: > "$R/cp"
: > "$R/wifi"
printf '%s\n' 'printf "On\n" > "'"$DPMS"'"' > "$t/poll.sh"
printf '%s\n' 'exit 0' > "$t/poll.sh"
T715_TEST_POLL_SCRIPT="$t/poll.sh" sl $D run
[ "$(calls_count 'systemctl start --no-block t715-sleep-restore.service')" = 0 ] \
    || fail "(h) a dark screen restores nothing (calls: $(cat "$t/calls"))"
mk_root
: > "$R/cp"
printf '%s\n' 'printf "On\n" > "'"$DPMS"'"' > "$t/poll.sh"
T715_TEST_POLL_SCRIPT="$t/poll.sh" sl $D run
# poll 1 dark: no restore; poll 2 lit: one restore; poll 3+: is-active says
# activating (the stub's start made it so), so no second one.
[ "$(calls_count 'systemctl start --no-block t715-sleep-restore.service')" = 1 ] \
    || fail "(h) the restore started once, at the lit poll (calls: $(cat "$t/calls"))"
log_has 'the screen lit: bringing the radios back' \
    || fail "(h) the lit line (log: $(cat "$t/log"))"
[ ! -e "$R/check" ] || fail "(h) the check marker dropped at a lit screen"
echo "ok - a lit screen with markers: one restore, and none while it is dark"

# --- (i) low battery at a check wake: poweroff ------------------------------------------
mk_root
dark_screen
printf '4\n' > "$BAT/capacity"
: > "$R/check"
printf '%s\n' 'exit 0' > "$t/poll.sh"
T715_TEST_POLL_SCRIPT="$t/poll.sh" sl $D run
[ "$SL_RC" = 0 ] || fail "(i) run exits 0 (got $SL_RC)"
calls_has 'systemctl poweroff' || fail "(i) poweroff (calls: $(cat "$t/calls"))"
log_has 'battery at 4 %: powering off' \
    || fail "(i) the poweroff line carries the percent (log: $(cat "$t/log"))"
[ "$(calls_count 'systemctl suspend --check-inhibitors=no')" = 0 ] \
    || fail "(i) a low battery does not sleep first (calls: $(cat "$t/calls"))"
mk_root
dark_screen
printf '4\n' > "$BAT/capacity"
printf '1\n' > "$CHG/online"
printf '%s\n' 'exit 0' > "$t/poll.sh"
T715_TEST_POLL_SCRIPT="$t/poll.sh" sl $D run
[ "$(calls_count 'systemctl poweroff')" = 0 ] \
    || fail "(i2) no poweroff on external power (calls: $(cat "$t/calls"))"
echo "ok - low battery at a check wake: powered off, and never on a charger"

# --- (j) privacy: no address, no path, no user name in anything the script says ---------
if grep -Eq '([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}' "$t/log.all" "$t/out.all" "$t/err.all"; then
    grep -En '([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}' "$t/log.all" "$t/out.all" "$t/err.all" >&2 || true
    fail "(j) something the script said matches a MAC address"
fi
if grep -q '/org/bluez' "$t/log.all" "$t/out.all" "$t/err.all"; then
    grep -n '/org/bluez' "$t/log.all" "$t/out.all" "$t/err.all" >&2 || true
    fail "(j) a BlueZ object path was printed"
fi
if grep -q 'dev_' "$t/log.all" "$t/out.all" "$t/err.all"; then
    grep -n 'dev_' "$t/log.all" "$t/out.all" "$t/err.all" >&2 || true
    fail "(j) a BlueZ device name was printed"
fi
if grep -Eq 'alice|alarm|root' "$t/log.all"; then
    grep -En 'alice|alarm|root' "$t/log.all" >&2 || true
    fail "(j) a user name was printed"
fi
echo "ok - privacy: no MAC address, no BlueZ path, no device name, no user name anywhere"

# --- (k) the units, the enabling and the checks -----------------------------------------
U="$here/rootfs/overlay/etc/systemd/system"
grep -qx 'Type=simple' "$U/t715-sleep.service" || fail "(k) t715-sleep.service is Type=simple"
grep -qx 'ExecStart=/usr/local/sbin/t715-sleep run' "$U/t715-sleep.service" \
    || fail "(k) t715-sleep.service runs run"
grep -qx 'After=t715-wifi-guard.service' "$U/t715-sleep.service" \
    || fail "(k) t715-sleep.service comes after the guard"
grep -qx 'Restart=on-failure' "$U/t715-sleep.service" \
    || fail "(k) t715-sleep.service restarts on failure"
grep -qx 'RestartSec=10' "$U/t715-sleep.service" || fail "(k) t715-sleep.service waits 10 s"
grep -qx 'WantedBy=multi-user.target' "$U/t715-sleep.service" \
    || fail "(k) t715-sleep.service is wanted by multi-user.target"
grep -qx 'Before=sleep.target' "$U/t715-sleep-prepare.service" \
    || fail "(k) the prepare unit is before sleep.target"
grep -qx 'StopWhenUnneeded=yes' "$U/t715-sleep-prepare.service" \
    || fail "(k) the prepare unit is StopWhenUnneeded"
grep -qx 'Type=oneshot' "$U/t715-sleep-prepare.service" \
    || fail "(k) the prepare unit is oneshot"
grep -qx 'RemainAfterExit=yes' "$U/t715-sleep-prepare.service" \
    || fail "(k) the prepare unit remains after exit"
grep -qx 'ExecStart=/usr/local/sbin/t715-sleep prepare' "$U/t715-sleep-prepare.service" \
    || fail "(k) the prepare unit runs prepare"
grep -qx 'ExecStop=/usr/local/sbin/t715-sleep resume' "$U/t715-sleep-prepare.service" \
    || fail "(k) the prepare unit stops with resume"
grep -qx 'TimeoutSec=120' "$U/t715-sleep-prepare.service" \
    || fail "(k) the prepare unit's timeout"
grep -qx 'WantedBy=sleep.target' "$U/t715-sleep-prepare.service" \
    || fail "(k) the prepare unit is wanted by sleep.target"
grep -qx 'After=t715-sleep-prepare.service' "$U/t715-sleep-restore.service" \
    || fail "(k) the restore unit comes after the prepare unit"
grep -qx 'Type=oneshot' "$U/t715-sleep-restore.service" \
    || fail "(k) the restore unit is oneshot"
grep -qx 'ExecStart=/usr/local/sbin/t715-sleep restore' "$U/t715-sleep-restore.service" \
    || fail "(k) the restore unit runs restore"
if grep -q '^\[Install\]' "$U/t715-sleep-restore.service"; then
    fail "(k) the restore unit has no Install section"
fi
grep -q 'systemctl enable.*t715-sleep.service.*t715-sleep-prepare.service' \
    "$here/rootfs/configure-system.sh" \
    || fail "(k) configure-system.sh enables both units"
grep -q '== Sleep ==' "$here/tests/verify-rootfs.sh" \
    || fail "(k) verify-rootfs.sh has a Sleep section"
echo "ok - the three units, configure-system.sh and verify-rootfs.sh all carry it"

# --- (l) status -------------------------------------------------------------------------
mk_root
printf '1000\n' > "$t/clock"
printf '400\n' > "$R/asleep-at"
printf '700\n' > "$R/resumed"
: > "$R/cp"
sl $D status
[ "$SL_RC" = 0 ] || fail "(l) status exits 0 (got $SL_RC)"
log_has 'sleep: on' || true
grep -q '^sleep: on$' "$t/out" || fail "(l) status says the switch is on (out: $(cat "$t/out"))"
grep -q '^a sleep after 10 s of dark screen' "$t/out" \
    || fail "(l) status carries AFTER (out: $(cat "$t/out"))"
grep -q '^kernel: can suspend to RAM' "$t/out" \
    || fail "(l) status says the kernel can sleep (out: $(cat "$t/out"))"
grep -q 'the CP is off for the sleep' "$t/out" \
    || fail "(l) status says the CP marker in plain words (out: $(cat "$t/out"))"
grep -q 'last wake: 300 s ago, after 300 s asleep' "$t/out" \
    || fail "(l) status times the last wake (out: $(cat "$t/out"))"
printf 'off\n' > "$V/mode"
sl status
grep -q '^sleep: switched off' "$t/out" || fail "(l) status says the switch is off"
rm -f "$ARM_F"
sl status
grep -q 'no system sleep' "$t/out" || fail "(l) status says the kernel cannot sleep"
echo "ok - status: the switch, AFTER, the kernel, the markers, the last wake"

echo "PASS"
