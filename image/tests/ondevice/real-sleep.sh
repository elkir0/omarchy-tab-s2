#!/bin/sh
# real-sleep.sh — ONE real SMC_CMD_SLEEP on the sleep test kernel, with the
# owner at the tablet.  Run as root under systemd-run (the USB link goes
# when the cable is pulled):
#
#   systemd-run --unit=t715-real-sleep -E WAKE=key sh /var/tmp/real-sleep.sh
#
# Refuses unless: the kernel is the dry run one (exynos5433_sleep=dryrun,
# whose arm switch this uses), pm_test is "none", the CP is off (CP_ON,
# gpr3-1, and CP_STATUS, gpa2-5, low), WRSTBI (gpf5-4) is set to stay high in power-down, the
# Wi-Fi's PCIe host is unbound, Bluetooth is blocked, no microSD card is
# mounted, and the arm switch is off.
#
# CHECK=1 runs the checks only.  Then DELAY seconds to pull the USB cable (the watchdog fed meanwhile),
# one arming, "mem" into /sys/power/state.  WAKE=key: the owner presses the
# power key a few seconds after the screen goes dark.  WAKE=rtc: the
# PMIC's RTC alarm, SECS after (owner's leave).  The hardware watchdog
# stays armed with its 30 s timeout: a resume that hangs once the clocks
# are back ends in a reset (sboot boots RECOVERY again, whose guard goes
# on to BOOT); a sleep that never wakes needs Power + Volume down held.
# N cycles (N=1 by default), a few seconds awake between two sleeps.
# Logs to /var/tmp, never an address or the kernel command line.
set -u
WAKE=${WAKE:-key}; SECS=${SECS:-10}; DELAY=${DELAY:-30}
LOG=${LOG:-/var/tmp/t715-real-sleep-$(date +%Y%m%d-%H%M%S).log}
P=/sys/power
ARM=/sys/module/exynos5433_sleep/parameters/arm

log() { echo "$(date +%H:%M:%S) $*" | tee -a "$LOG"; }
kmark() { dmesg | tail -1 | sed 's/^\[ *\([0-9.]*\)\].*/\1/'; }
klines() {
	dmesg | awk -v t="$1" '{s=$0; sub(/^\[ */,"",s); split(s,a,"]"); if (a[1]+0 > t+0) print}' |
		grep -vE 'Kernel command line|UFW BLOCK' |
		sed -E 's/([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}/<addr>/g'
}
pinline() { # the debugfs line of pin $1 in controller $2
	mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
	grep -E "\($1\)" "$(ls -d /sys/kernel/debug/pinctrl/$2.pinctrl* | head -1)/pins"
}
no() { log "refused: $*"; exit 1; }
battery() { for b in /sys/class/power_supply/*; do grep -qx Battery "$b/type" 2>/dev/null && { cat "$b/capacity"; return; }; done; echo "?"; }

grep -qw "exynos5433_sleep=dryrun" /proc/cmdline || no "not the dry run sleep test kernel"
[ -w "$ARM" ] || no "no arm switch"
[ "$(cat $ARM)" = N ] || no "already armed"
[ "$(sed -E 's/.*\[([a-z]+)\].*/\1/' $P/pm_test)" = none ] || no "pm_test is not none"
grep -q '\[deep\]' $P/mem_sleep || no "mem_sleep is not deep: $(cat $P/mem_sleep)"
pinline gpr3-1 15690000 | grep -q 'DAT(0x0)' || no "CP_ON is high: the CP is powered"
pinline gpa2-5 10580000 | grep -q 'DAT(0x0)' || no "CP_STATUS is high: the CP runs"
pinline gpf5-4 10580000 | grep -q 'CON_PDN(0x1)' || no "WRSTBI is not set to stay high in power-down"
[ ! -e /sys/bus/platform/devices/15700000.pcie/driver ] || no "the Wi-Fi's PCIe host is bound"
# Bluetooth off: its driver unbound (no adapter at all) or its radio soft-blocked
ls /sys/class/bluetooth 2>/dev/null | grep -q '^hci' &&
	! rfkill list bluetooth 2>/dev/null | grep -q 'Soft blocked: yes' && no "Bluetooth is on"
! grep -q '^/dev/mmcblk[1-9]' /proc/mounts || no "a microSD card is mounted"
[ "$WAKE" = key ] || [ "$WAKE" = rtc ] || no "WAKE is key or rtc"
if [ "$WAKE" = rtc ]; then
	RTC=
	for r in /sys/class/rtc/rtc*; do grep -qiE 's2mps|s5m' "$r/name" 2>/dev/null && RTC=${r##*/}; done
	[ -n "$RTC" ] || no "no PMIC RTC"
	# Up to 20 s by default.  LONG=1 allows up to 300 s: in a real sleep the
	# watchdog block loses its state (it does not count), measured on
	# 2026-11-09; only an early wake back into a running system would let it count.
	if [ "${LONG:-0}" = 1 ]; then [ "$SECS" -le 300 ] || no "SECS above 300"
	else [ "$SECS" -le 20 ] || no "SECS above 20 (LONG=1 for a real sleep up to 300 s)"; fi
fi

if [ "${CHECK:-0}" = 1 ]; then log "check only: every precondition holds (WAKE=$WAKE)"; exit 0; fi
K() { echo "t715-real: $*" > /dev/kmsg; }
echo 1 > /sys/module/s3c2410_wdt/parameters/keep_running_in_suspend
echo N > /sys/module/printk/parameters/console_suspend
exec 3>/dev/watchdog || no "cannot open /dev/watchdog"
finish() { echo N > "$ARM" 2>/dev/null; printf V >&3; exec 3>&-; log "end: armed $(cat $ARM), watchdog $(cat /sys/class/watchdog/watchdog0/state)"; }
trap finish EXIT
trap 'exit 1' TERM INT HUP

# WAIT_UNPLUG=1: the owner starts the sleep by pulling the cable; DELAY then counts from that
usb_in() { grep -q . /sys/class/udc/*/state 2>/dev/null && ! grep -q 'not attached' /sys/class/udc/*/state; }
if [ "${WAIT_UNPLUG:-0}" = 1 ]; then
	log "ready: WAKE=$WAKE; battery $(battery) %; waiting for the USB cable to be pulled"
	while usb_in; do printf . >&3; sleep 1; done
	log "cable out; sleep in $DELAY s"
else
	log "ready: WAKE=$WAKE; battery $(battery) %; $DELAY s to pull the USB cable"
fi
d=0
while [ "$d" -lt "$DELAY" ]; do printf . >&3; sleep 2; d=$((d + 2)); done
usb_in && no "the USB cable is still in"

N=${N:-1}
c=1
while [ "$c" -le "$N" ]; do
	m=$(kmark)
	[ "$WAKE" = rtc ] && { echo 0 > /sys/class/rtc/$RTC/wakealarm; echo "+$SECS" > /sys/class/rtc/$RTC/wakealarm; }
	printf . >&3
	echo 1 > "$ARM"
	K "cycle $c/$N armed, WAKE=$WAKE: real sleep now"
	t0=$(date +%s); u0=$(cut -d' ' -f1 /proc/uptime)
	echo mem > $P/state; rc=$?
	t1=$(date +%s); u1=$(cut -d' ' -f1 /proc/uptime)
	printf . >&3
	K "cycle $c back: rc $rc"
	log "cycle $c/$N back: rc $rc, $((t1 - t0)) s by the clock, $(awk -v a="$u0" -v b="$u1" 'BEGIN{print b-a}') s of uptime; armed now $(cat $ARM); battery $(battery) %"
	if [ "$N" = 1 ]; then
		klines "$m" | grep -E 'EXYNOS5433|PM:|[Ss]uspend|[Rr]esume|wake|BUG:|WARNING:|Oops|[Ff]ailed|[Ee]rror|timed out' | cut -c1-200 | tee -a "$LOG"
	else
		klines "$m" | grep -E 'woke up|no sleep|BUG:|WARNING:|Oops|[Ff]ailed|[Ee]rror|timed out|lost its state' | cut -c1-200 | tee -a "$LOG"
	fi
	[ "$rc" = 0 ] || { log "cycle $c failed: stop"; break; }
	c=$((c + 1))
	# a few seconds awake between two sleeps
	if [ "$c" -le "$N" ]; then d=0; while [ "$d" -lt 4 ]; do printf . >&3; sleep 1; d=$((d + 1)); done; fi
done
cat $P/suspend_stats/success $P/suspend_stats/fail 2>/dev/null | tr '\n' ' ' | sed 's/^/suspend_stats success fail: /' | tee -a "$LOG"; echo | tee -a "$LOG"
log "touchscreen interrupts so far: $(awk '/rmi4|synaptics|s5806/ {n=0; for (i=2; i<=NF; i++) if ($i ~ /^[0-9]+$/) n+=$i; else break; print n; exit}' /proc/interrupts)"
