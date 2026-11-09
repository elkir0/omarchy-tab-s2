#!/bin/sh
# wifi-guard-test.sh — t715-wifi-guard against simulated boots: N times, the whole combo chip
# powered off (the PCIe host and Bluetooth unbound), then on as at boot (the host bound,
# Bluetooth 1 s later), 15 s for the start, then `t715-wifi-guard check`, and `recover` when
# it fails; networks counted after (a count only).  Counts the starts good at once, the ones
# the guard recovered (and in how many tries), and the ones it could not.  Root, on a kernel
# with the switchable WLAN_EN and the PHY power-off (the daily candidate #11 or later), the
# CP off, under systemd-run or t715.autotest.  GUARD is the script under test.  Every line
# goes to the kernel log at error level ("t715-wgtest:") and to $LOG; no address is logged.
set -u
N=${N:-20}; OFF=${OFF:-2}
GUARD=${GUARD:-/usr/local/sbin/t715-wifi-guard}
LOG=${LOG:-/var/tmp/t715-wifi-guard-test.log}
HOST=15700000.pcie
DRV=/sys/bus/platform/drivers/exynos-pcie
BTDRV=/sys/bus/serial/drivers/hci_uart_bcm
STOP=/run/t715-wgtest.stop

K() { echo "<3>t715-wgtest: $*" > /dev/kmsg; echo "$(date +%T) $*" >> "$LOG"; }
nets() { nmcli device wifi rescan >/dev/null 2>&1; sleep 4; nmcli -t -f BSSID device wifi list 2>/dev/null | grep -c .; }

[ -x "$GUARD" ] || { K "no $GUARD: refused"; exit 1; }
[ -d "$DRV" ] || { K "no exynos-pcie driver: refused"; exit 1; }
[ -e /run/shannon/cp-state ] && grep -q "state=online" /run/shannon/cp-state && { K "the CP is online: refused"; exit 1; }
BT=
for d in "$BTDRV"/serial*-*; do [ -e "$d" ] && { BT=${d##*/}; break; }; done

rm -f "$STOP"
( trap '' TERM INT HUP
  exec 3>/dev/watchdog || exit 1
  while [ ! -e "$STOP" ]; do printf . >&3; sleep 5; done
  printf V >&3 ) &
FEED=$!
trap 'touch "$STOP"; wait "$FEED" 2>/dev/null' EXIT
trap 'exit 1' TERM INT HUP

K "start: N=$N OFF=$OFF; Bluetooth ${BT:+bound}${BT:-absent}; guard $(sha256sum "$GUARD" | cut -c1-12); kernel $(uname -v | cut -c1-24)"
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
