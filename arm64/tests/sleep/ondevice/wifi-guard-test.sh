#!/bin/sh
# wifi-guard-test.sh — t715-wifi-guard against simulated boots: N times, the whole combo chip
# powered off (the PCIe host and Bluetooth unbound), then on as at boot (the host bound,
# Bluetooth 1 s later), 15 s for the start, then `t715-wifi-guard check`, and `recover` when
# it fails; networks counted after (a count only).  Counts the starts good at once, the ones
# the guard recovered (and in how many tries), and the ones it could not.  Root, on a kernel
# with pci_exynos.wifi_power_cycle=Y, the CP off, under systemd-run (autotest-wifi.sh runs
# it).  GUARD is the script under test.  Every line goes to the kernel log at error level
# ("t715-wgtest:") and to $LOG; no address is logged.
#
# In 64 bits (arm64/tests/sleep/ondevice/, from the 32-bit image's tests/ondevice/): the
# watchdog is t715-watchdog-keeper's, which holds /dev/watchdog and feeds it, so this script
# feeds nothing (the 32-bit one fed it itself); it refuses a kernel without wifi_power_cycle
# (a bind after a failed start hangs there); and it stops t715-sleep.service (a dark screen
# on battery would suspend the tablet in the middle of a cycle) and t715-wifi-guard.service
# (its watch would recover the starts this test judges) for its length, and starts them
# again on every exit, as sleep-soak.sh does with the first.
set -u
N=${N:-20}; OFF=${OFF:-2}
GUARD=${GUARD:-/usr/local/sbin/t715-wifi-guard}
LOG=${LOG:-/var/tmp/t715-wifi-guard-test.log}
HOST=15700000.pcie
DRV=/sys/bus/platform/drivers/exynos-pcie
BTDRV=/sys/bus/serial/drivers/hci_uart_bcm
CAP=/sys/module/pci_exynos/parameters/wifi_power_cycle

K() { echo "<3>t715-wgtest: $*" > /dev/kmsg; echo "$(date +%T) $*" >> "$LOG"; }
nets() { nmcli device wifi rescan >/dev/null 2>&1; sleep 4; nmcli -t -f BSSID device wifi list 2>/dev/null | grep -c .; }

[ -x "$GUARD" ] || { K "no $GUARD: refused"; exit 1; }
[ -d "$DRV" ] || { K "no exynos-pcie driver: refused"; exit 1; }
[ "$(cat "$CAP" 2>/dev/null)" = Y ] || { K "no pci_exynos.wifi_power_cycle=Y on this kernel: refused"; exit 1; }
[ -e /run/shannon/cp-state ] && grep -q "state=online" /run/shannon/cp-state && { K "the CP is online: refused"; exit 1; }
BT=
for d in "$BTDRV"/serial*-*; do [ -e "$d" ] && { BT=${d##*/}; break; }; done

# The services that would act on the chip or the tablet meanwhile: stopped, and started
# again on every exit.
STOPPED=
for u in t715-sleep.service t715-wifi-guard.service; do
	if systemctl -q is-active "$u" 2>/dev/null; then
		systemctl stop "$u" && STOPPED="$STOPPED $u"
	fi
done
# shellcheck disable=SC2329  # finish runs from the EXIT trap
finish() {
	for u in $STOPPED; do systemctl start "$u" || K "cannot start $u again"; done
}
trap finish EXIT
trap 'exit 1' TERM INT HUP
keeper=$(systemctl is-active t715-watchdog-keeper.service 2>/dev/null)

K "start: N=$N OFF=$OFF; Bluetooth ${BT:+bound}${BT:-absent}; guard $(sha256sum "$GUARD" | cut -c1-12); kernel $(uname -v | cut -c1-24); stopped:${STOPPED:- none}; watchdog keeper ${keeper:-unknown}"
good=0; recovered=0; failed=0; tries_sum=0
i=1
while [ "$i" -le "$N" ]; do
	rc=0
	# the whole chip off, as before a boot
	[ -e "$DRV/$HOST" ] && echo "$HOST" > "$DRV/unbind"
	[ -n "$BT" ] && [ -e "$BTDRV/$BT" ] && echo "$BT" > "$BTDRV/unbind"
	sleep "$OFF"
	# on, in the boot's order
	echo "$HOST" > "$DRV/bind" || K "cycle $i: bind failed"
	[ -n "$BT" ] && { sleep 1; echo "$BT" > "$BTDRV/bind" || K "cycle $i: Bluetooth bind failed"; }
	sleep 15
	if why=$("$GUARD" check 2>&1); then
		good=$((good + 1)); res="good at once"
	else
		t0=$(cut -d. -f1 /proc/uptime)
		"$GUARD" recover 4 >/dev/null 2>&1; rc=$?
		dt=$(( $(cut -d. -f1 /proc/uptime) - t0 ))
		tries=$(journalctl -t t715-wifi-guard --since "-$((dt + 5))s" -o cat 2>/dev/null | grep -c -i -E "try|attempt")
		if [ "$rc" = 0 ]; then
			recovered=$((recovered + 1)); tries_sum=$((tries_sum + tries))
			res="failed ($(echo "$why" | head -1 | cut -c1-80)), recovered in ${dt} s, $tries try lines"
		else
			failed=$((failed + 1))
			res="failed ($(echo "$why" | head -1 | cut -c1-80)), recover exit $rc after ${dt} s"
		fi
	fi
	K "cycle $i: $res; $(nets) networks"
	if [ "$rc" = 2 ]; then
		K "result: the host's unbind got stuck at cycle $i: stopping"
		exit 1
	fi
	i=$((i + 1))
done
K "result: $N starts, $good good at once, $recovered recovered by the guard, $failed not recovered"
[ "$failed" = 0 ]
