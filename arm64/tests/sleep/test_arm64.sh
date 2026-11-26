#!/usr/bin/env bash
# test_arm64.sh — the 64-bit image's own cases for the sleep port: how the
# 64-bit build installs and checks the 32-bit image's sleep (t715-sleep,
# t715-wifi-guard, their units), and what the on-device scripts of
# arm64/tests/sleep/ondevice/ change for the 64-bit system.  The scripts
# themselves are tested by the three suites beside this one; this one reads
# the build's scripts, the on-device scripts and the docs, and runs nothing
# of the tablet's.
#
# Usage: arm64/tests/sleep/test_arm64.sh (or arm64/tests/sleep/run.sh)
# Prints "ok - ..." per group, "PASS" at the end; exit 1 on the first
# failure.  Needs bash 3.2 or later and /bin/sh.
# shellcheck disable=SC2016  # the code searched for is literal, never expanded
set -euo pipefail

# here: arm64/; top: the repository.
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
top=$(cd -- "$here/.." && pwd)
R="$here/rootfs"
OD="$here/tests/sleep/ondevice"

fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}
# code FILE: FILE without its comment lines.
code() { grep -v '^[[:space:]]*#' "$1"; }

# --- (a) the build: the overlay's files, enabled in the Omarchy image -----------------
for f in usr/local/sbin/t715-sleep usr/local/sbin/t715-wifi-guard \
         etc/systemd/system/t715-sleep.service etc/systemd/system/t715-sleep-prepare.service \
         etc/systemd/system/t715-sleep-restore.service etc/systemd/system/t715-wifi-guard.service \
         etc/systemd/logind.conf.d/90-t715-lid.conf; do
    [ -f "$R/overlay/$f" ] || fail "(a) $f is in arm64/rootfs/overlay/"
done
for f in usr/local/sbin/t715-sleep usr/local/sbin/t715-wifi-guard; do
    [ -x "$R/overlay/$f" ] || fail "(a) $f is executable (configure-base.sh installs the overlay with its modes)"
done
CO="$R/configure-omarchy.sh"
code "$CO" | grep -qx 'systemctl enable t715-wifi-guard.service' \
    || fail "(a) configure-omarchy.sh enables t715-wifi-guard.service"
code "$CO" | grep -qx 'systemctl enable t715-sleep.service t715-sleep-prepare.service' \
    || fail "(a) configure-omarchy.sh enables t715-sleep.service and t715-sleep-prepare.service"
code "$CO" | grep -qx 'systemctl unmask suspend.target sleep.target' \
    || fail "(a) configure-omarchy.sh unmasks suspend.target and sleep.target"
if code "$CO" | grep -E 'unmask' | grep -q 'hibernate'; then
    fail "(a) configure-omarchy.sh leaves the hibernation targets masked"
fi
code "$CO" | grep -q '\[ -x /usr/local/sbin/t715-sleep \] || die' \
    || fail "(a) configure-omarchy.sh stops the build without t715-sleep"
code "$CO" | grep -q '\[ -x /usr/local/sbin/t715-wifi-guard \] || die' \
    || fail "(a) configure-omarchy.sh stops the build without t715-wifi-guard"
if sed -n '1,/^set -euo pipefail/p' "$CO" | grep -Eq 't715-sleep|t715-wifi-guard'; then
    fail "(a) configure-omarchy.sh's header no longer lists the sleep or the guard as left out"
fi
# The base image keeps its masks: it is the bring-up image.
code "$R/configure-base.sh" | grep -q '^systemctl mask suspend.target sleep.target hibernate.target' \
    || fail "(a) configure-base.sh still masks the sleep targets in the base image"
if code "$R/configure-base.sh" | grep -Eq 't715-sleep|t715-wifi-guard'; then
    fail "(a) configure-base.sh enables neither the sleep nor the guard"
fi
bash -n "$CO" || fail "(a) configure-omarchy.sh parses"
echo "ok - the build: the overlay's files, enabled and unmasked in the Omarchy image, masked in the base"

# --- (b) the image checks ----------------------------------------------------------
SC="$R/smoke-check.sh"
SCO="$R/smoke-check-omarchy"
bash -n "$SC" || fail "(b) smoke-check.sh parses"
bash -n "$SCO" || fail "(b) smoke-check-omarchy parses"
grep -q 'suspend|sleep) pacman -Q omarchy >/dev/null 2>&1 && continue' "$SC" \
    || fail "(b) smoke-check.sh leaves suspend and sleep to the Omarchy image's part"
for s in /usr/local/sbin/t715-wifi-guard /usr/local/sbin/t715-sleep; do
    grep -q "$s" "$SC" || fail "(b) smoke-check.sh parses $s with the overlay's scripts"
done
for w in '== Wi-Fi guard (' '== Sleep (' 'multi-user.target.wants/t715-wifi-guard.service' \
         'multi-user.target.wants/t715-sleep.service' 'sleep.target.wants/t715-sleep-prepare.service' \
         'not masked' 'HandleLidSwitch=ignore' '"$SL" status' "WG_BOOST_DEFAULT=''"; do
    grep -qF -- "$w" "$SCO" || fail "(b) smoke-check-omarchy checks: $w"
done
# The smoke check's loop, as smoke-check.sh runs it, with pacman and the
# targets stood in: the Omarchy image skips suspend and sleep, the base does not.
t=$(mktemp -d "${TMPDIR:-/tmp}/t715-arm64-sleep.XXXXXX")
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin"
printf '#!/bin/sh\n[ -n "${T715_TEST_OMARCHY:-}" ]\n' > "$t/bin/pacman"
chmod +x "$t/bin/pacman"
loop=$(sed -n '/^for target in suspend sleep hibernate/,/^done/p' "$SC")
[ -n "$loop" ] || fail "(b) smoke-check.sh has its targets loop"
run_loop() {
    PATH="$t/bin:$PATH" bash -c 'pass() { echo "PASS $*"; }; fail() { echo "FAIL $*"; }; '"$loop"
}
out=$(T715_TEST_OMARCHY=1 run_loop)
if printf '%s\n' "$out" | grep -Eq '^(PASS|FAIL) (suspend|sleep)\.target'; then
    fail "(b) the Omarchy image's loop skips suspend and sleep (got: $out)"
fi
[ "$(printf '%s\n' "$out" | grep -Ec '^(PASS|FAIL) (hibernate|hybrid-sleep|suspend-then-hibernate)\.target')" = 3 ] \
    || fail "(b) the Omarchy image still checks the three hibernation targets (got: $out)"
out=$(run_loop)
printf '%s\n' "$out" | grep -q '^FAIL suspend\.target is not masked' \
    || fail "(b) the base image wants suspend masked (got: $out)"
printf '%s\n' "$out" | grep -q '^FAIL sleep\.target is not masked' \
    || fail "(b) the base image wants sleep masked (got: $out)"
echo "ok - the image checks: the base keeps suspend and sleep masked, the Omarchy part checks the sleep"

# --- (c) the on-device scripts, made for the 64-bit system --------------------------
for f in sleep-display.sh sleep-soak.sh wifi-guard-test.sh autotest-wifi.sh; do
    [ -x "$OD/$f" ] || fail "(c) ondevice/$f is there and executable"
    sh -n "$OD/$f" || fail "(c) ondevice/$f parses"
    grep -q '^# In 64 bits' "$OD/$f" || fail "(c) ondevice/$f says what differs in 64 bits"
done
# wifi-guard-test.sh: the keeper feeds the watchdog, never this script; no
# kernel without wifi_power_cycle; the services stopped and started again.
if code "$OD/wifi-guard-test.sh" | grep -q '/dev/watchdog'; then
    fail "(c) wifi-guard-test.sh never opens /dev/watchdog (t715-watchdog-keeper holds it)"
fi
code "$OD/wifi-guard-test.sh" | grep -q 'wifi_power_cycle' \
    || fail "(c) wifi-guard-test.sh refuses a kernel without wifi_power_cycle"
code "$OD/wifi-guard-test.sh" | grep -q 'for u in t715-sleep.service t715-wifi-guard.service' \
    || fail "(c) wifi-guard-test.sh stops t715-sleep and the guard's watch"
code "$OD/wifi-guard-test.sh" | grep -q 'systemctl start "$u"' \
    || fail "(c) wifi-guard-test.sh starts them again"
code "$OD/wifi-guard-test.sh" | grep -q '^trap finish EXIT' \
    || fail "(c) wifi-guard-test.sh starts them again on every exit"
# sleep-display.sh: t715-keys by the user's uid, not by the name alarm.
code "$OD/sleep-display.sh" | grep -q 'pgrep -u 1000 -f /usr/local/bin/t715-keys' \
    || fail "(c) sleep-display.sh finds t715-keys by uid 1000"
if code "$OD/sleep-display.sh" | grep -q 'pgrep -u alarm'; then
    fail "(c) sleep-display.sh does not name the user alarm"
fi
# autotest-wifi.sh: started by hand (no t715.autotest knob in the 64-bit
# initramfs), no software restart, the installed guard never replaced, the
# 32-bit-only parts refused.
if code "$OD/autotest-wifi.sh" | grep -Eq 'sysrq-trigger|install .*t715-wifi-guard|wifi-d3\.sh"|wifi-cycle\.sh"|stock_power >|stock_link >'; then
    fail "(c) autotest-wifi.sh restarts nothing, installs nothing and runs no 32-bit-only part"
fi
code "$OD/autotest-wifi.sh" | grep -q 'd3|keep|cycles|retry|phy|full|order)' \
    || fail "(c) autotest-wifi.sh refuses the 32-bit-only parts by name"
if ! code "$OD/autotest-wifi.sh" | grep -q 'echo "$HTP" > /proc/sys/kernel/hung_task_panic'; then
    fail "(c) autotest-wifi.sh puts the kernel's hang settings back"
fi
# sleep-soak.sh: the clock's judgment wired in; the RTC by its name.
code "$OD/sleep-soak.sh" | grep -q 'kind=$(soak_kind_by_clock "$kind"' \
    || fail "(c) sleep-soak.sh asks the clock when the kernel's sleep line is missing"
code "$OD/sleep-soak.sh" | grep -q "grep -qiE 's2mps|s5m'" \
    || fail "(c) sleep-soak.sh finds the PMIC's RTC by its name"
# Never the kernel command line (it holds the serial number): what reads the
# whole kernel log either drops that line or only counts.
code "$OD/sleep-display.sh" | grep -q "grep -v -i 'kernel command line'" \
    || fail "(c) sleep-display.sh drops the kernel command line from what it reads"
echo "ok - the on-device scripts: the keeper's watchdog, the user's uid, no restart, the clock's judgment"

# --- (d) the docs ------------------------------------------------------------------
grep -q 'rootfs/overlay/usr/local/sbin/t715-sleep' "$here/README.md" \
    || fail "(d) arm64/README.md lists the sleep with the image's contents"
grep -qx 'bash arm64/tests/sleep/run.sh' "$here/README.md" \
    || fail "(d) arm64/README.md runs this suite"
para=$(awk '/^## Sleep/ {s = 1; next} /^## / {s = 0} s' "$top/docs/image/ROOTFS.md" \
       | awk '/^\*\*In 64 bits\.\*\*/ {p = 1} p && /^$/ {exit} p')
[ -n "$para" ] || fail "(d) docs/image/ROOTFS.md's Sleep section has its paragraph In 64 bits"
for w in 'arm64/rootfs/overlay/' 'configure-omarchy.sh' 'T715_WG_BOOST_CPUS' \
         'tested on the tablet on 2026-11-26' 'the whole chain on battery'; do
    printf '%s\n' "$para" | tr '\n' ' ' | grep -qF -- "$w" \
        || fail "(d) the paragraph In 64 bits says: $w"
done
grep -qF 'omarchy-sleep-lock.service.d/t715-sleep.conf' "$top/docs/image/ROOTFS.md" \
    || fail "(d) docs/image/ROOTFS.md explains the drop-in that keeps Omarchy's sleep lock alive"
[ -f "$here/rootfs/overlay-omarchy/etc/systemd/user/omarchy-sleep-lock.service.d/t715-sleep.conf" ] \
    || fail "(d) the overlay has the omarchy-sleep-lock drop-in"
if grep -n 'not ported' "$here/docs/ROOTFS.md" | grep -Eq 'suspend|t715-wifi-guard'; then
    fail "(d) arm64/docs/ROOTFS.md no longer calls the sleep or the guard not ported"
fi
echo "ok - the docs: the README's line and test, the paragraph In 64 bits, arm64/docs/ROOTFS.md"

# --- (e) nothing that identifies a tablet in what this port added -------------------
# No MAC or Bluetooth address outside a comment in the overlay's scripts and
# units (the image's smoke check greps /usr/local for them), and none at all
# in the on-device scripts.
for f in "$R/overlay/usr/local/sbin/t715-sleep" "$R/overlay/usr/local/sbin/t715-wifi-guard" \
         "$R/overlay/etc/systemd/system/t715-sleep.service" \
         "$R/overlay/etc/systemd/system/t715-sleep-prepare.service" \
         "$R/overlay/etc/systemd/system/t715-sleep-restore.service" \
         "$R/overlay/etc/systemd/system/t715-wifi-guard.service" \
         "$OD"/*.sh; do
    if grep -Eq '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' "$f"; then
        fail "(e) $f holds something like a MAC address"
    fi
done
echo "ok - privacy: no address in the overlay's files or the on-device scripts"

echo "PASS"
