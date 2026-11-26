#!/bin/sh
# autotest-wifi.sh — the Wi-Fi guard's test, unattended, on the 64-bit system.  Run as root
# ON THE TABLET, the CP off, nobody touching it, with wifi-guard-test.sh beside it (and,
# to test another guard than the installed one, a t715-wifi-guard too):
#
#   systemd-run --unit=t715-autotest-wifi --collect sh /root/t715-test/autotest-wifi.sh guard
#
# The part to run is the first argument, else the one word of t715-autotest.part beside
# this script:
#   guard   t715-wifi-guard on 20 simulated boots (wifi-guard-test.sh): the one beside this
#           script when there is one, the installed /usr/local/sbin/t715-wifi-guard else
#
# In 64 bits (arm64/tests/sleep/ondevice/, from the 32-bit image's tests/ondevice/): the
# 32-bit script ran on a RECOVERY test image, started by the 32-bit initramfs's knob
# t715.autotest=1, and ended with a software restart into BOOT.  The 64-bit initramfs has no
# such knob and the 64-bit system boots from the loader, so this one is started by hand
# (above), changes nothing it does not put back, and leaves the tablet running: at its end
# the Wi-Fi is brought back if it is down and the kernel's hang settings are restored.  The
# 32-bit parts d3, keep, cycles, retry, phy, full and order need wifi-d3.sh, wifi-cycle.sh
# and the 32-bit kernel's phy_exynos_pcie.stock_power and pci_exynos.stock_link, which the
# 64-bit tree does not have: they are refused with one line.  The installed guard is never
# replaced: a guard beside this script is run from where it is.
#
# The logs live in /var/tmp and in the kernel log at error level ("t715-auto:"), so a crash
# leaves them in pstore; a summary of every step closes the run.
set -u
D=$(cd "$(dirname "$0")" && pwd)
L=/var/tmp/t715-autotest.log
PART=${1:-$(head -1 "$D/t715-autotest.part" 2>/dev/null)}
WG=/usr/local/sbin/t715-wifi-guard

A() { echo "<3>t715-auto: $*" > /dev/kmsg; echo "$(date +%T) $*" >> "$L"; }

# The kernel's hang settings as they were, put back at the end.
HTP=$(cat /proc/sys/kernel/hung_task_panic 2>/dev/null)
HTT=$(cat /proc/sys/kernel/hung_task_timeout_secs 2>/dev/null)
SLP=$(cat /proc/sys/kernel/softlockup_panic 2>/dev/null)

finish() {
	A "summary ($PART):"
	for f in /var/tmp/t715-step-*.log; do
		[ -e "$f" ] || continue
		n=${f#/var/tmp/t715-step-}; n=${n%.log}
		grep -h -E "start:|cycle [0-9]+:|result:" "$f" | sed -E 's/^[0-9:]+ //' | cut -c1-190 |
			while read -r l; do A "  [$n] $l"; done
	done
	# The Wi-Fi back if the last cycle left it down: the tablet goes on running.
	if ! "$WG" check >/dev/null 2>&1; then
		"$WG" recover >/dev/null 2>&1
		A "end: the Wi-Fi was down: recover exit $?"
	fi
	[ -n "$HTP" ] && echo "$HTP" > /proc/sys/kernel/hung_task_panic
	[ -n "$HTT" ] && echo "$HTT" > /proc/sys/kernel/hung_task_timeout_secs
	[ -n "$SLP" ] && echo "$SLP" > /proc/sys/kernel/softlockup_panic
	A "end: hung task and soft lockup panic back to $HTP$SLP, hung task timeout $HTT s"
	exit "${1:-0}"
}

run() { # run NAME TIMEOUT SCRIPT [VAR=value ...]
	n=$1; t=$2; s=$3; shift 3
	A "step $n: $s $*"
	# --foreground: the signal goes to the script alone, not to the children it waits for
	env LOG="/var/tmp/t715-step-$n.log" "$@" timeout --foreground -k 30 "$t" sh "$D/$s"
	rc=$?
	A "step $n: exit $rc, $(grep -h 'result:' "/var/tmp/t715-step-$n.log" 2>/dev/null | tail -1 | sed -E 's/^[0-9:]+ //')"
	return "$rc"
}

[ "$(id -u)" = 0 ] || { echo "autotest-wifi.sh: root only" >&2; exit 1; }
rm -f /var/tmp/t715-step-*.log
# A hang becomes a panic: the panic dump (dmesg-ramoops) and this boot's console survive in
# pstore, and panic=5 on the 64-bit kernel's command line restarts the tablet.
echo 1 > /proc/sys/kernel/hung_task_panic
echo 60 > /proc/sys/kernel/hung_task_timeout_secs
echo 1 > /proc/sys/kernel/softlockup_panic
A "start: part '$PART', kernel $(uname -v | cut -c1-24); hung task and soft lockup panic $(cat /proc/sys/kernel/hung_task_panic)$(cat /proc/sys/kernel/softlockup_panic), hung task timeout $(cat /proc/sys/kernel/hung_task_timeout_secs) s; 90 s for the system to settle"
sleep 90
[ -r "$D/wifi-guard-test.sh" ] || { A "missing wifi-guard-test.sh next to this script"; finish 1; }

case $PART in
guard)
	# t715-wifi-guard on simulated boots: the one beside this script, else the installed one
	g=$WG
	[ -x "$D/t715-wifi-guard" ] && g=$D/t715-wifi-guard
	run 1-guard 1500 wifi-guard-test.sh N=20 GUARD="$g" || finish 1 ;;
d3|keep|cycles|retry|phy|full|order)
	A "part '$PART': not ported to 64 bits (it needs wifi-d3.sh or wifi-cycle.sh and the 32-bit kernel's stock_power and stock_link)"
	finish 1 ;;
*)
	A "no part to run (the first argument, or t715-autotest.part: guard)"
	finish 1 ;;
esac
finish 0
