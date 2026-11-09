#!/bin/sh
# autotest-wifi.sh — the Wi-Fi sleep tests, unattended, on a RECOVERY test image built
# with the initramfs knob t715.autotest=1 (test images only).  Copy it next to the root
# image on USERDATA as t715-autotest.sh, with wifi-d3.sh, wifi-cycle.sh and
# wifi-guard-test.sh beside it (and t715-wifi-guard for the part guard), and the part
# to run in t715-autotest.part (one word); the image's
# t715-autotest.service runs it once Arch is up.  Each part stops at its first failure:
#   d3      1. d3dev, mailbox through SBMBX, then through doorbell 1 (stock's): on
#              2026-11-09 the firmware acked D3_INFORM through SBMBX only
#   keep    the chip kept powered, mailbox through SBMBX, stock's handshake
#           (D0_INFORM_IN_USE after the ack, D0_INFORM on resume): 1. d3dev,
#           2. d3plat (PME_Turn_Off, PERST#, the host's PHY off), 3. suspend-to-idle
#           for 10 s, 4. for 20 s
#   cycles  the Wi-Fi power cycles with ASPM off, then with ASPM turned on 10 s late
#   phy     retry with stock's PHY power down/up (phy_exynos_pcie.stock_power) and
#           link handling (pci_exynos.stock_link: PERST# and LTSSM off before the
#           power goes, the gpr3-6 pulse)
#   full    phy, with Bluetooth taken down too at every power cycle (FULL=1): the
#           whole chip powered off, as on a reboot
#   order   full, with Bluetooth bound before the PCIe host (once its hci device is up),
#           then with Bluetooth bound after the Wi-Fi start has been judged
#   guard   t715-wifi-guard (copied next to this script) on 20 simulated boots
#           (wifi-guard-test.sh), on the daily candidate kernel
#   retry   20 power cycles of 2 s (ASPM as the daily system has it), a halt followed by
#           a fresh power cycle (CONTINUE=1): how often the start fails, and whether a
#           second power cycle recovers it
# USERDATA is read-only on this boot: the logs live in /var/tmp (RAM) and in the kernel
# log at error level, the only level the console, and so the next boot's
# /sys/fs/pstore/console-ramoops-0, keeps (console_loglevel 4).  A summary of every
# step closes it, then an immediate software restart (sysrq b), which keeps INFORM3 at
# normal: the next boot is BOOT.
set -u
D=$(dirname "$0")
L=/var/tmp/t715-autotest.log
PART=$(head -1 "$D/t715-autotest.part" 2>/dev/null)

A() { echo "<3>t715-auto: $*" > /dev/kmsg; echo "$(date +%T) $*" >> "$L"; }

finish() {
	A "summary ($PART):"
	for f in /var/tmp/t715-step-*.log; do
		[ -e "$f" ] || continue
		n=${f#/var/tmp/t715-step-}; n=${n%.log}
		grep -h -E "start:|cycle [0-9]+:|result:" "$f" | sed -E 's/^[0-9:]+ //' | cut -c1-190 |
			while read -r l; do A "  [$n] $l"; done
	done
	touch /run/t715-wcycle.stop /run/t715-wifi-d3.stop
	A "end: chip powered off, then software restart into BOOT"
	# the host's unbind cuts WLAN_EN: BOOT gets a chip powered on afresh; in the
	# background, since a stuck driver can hold the unbind
	( echo 15700000.pcie > /sys/bus/platform/drivers/exynos-pcie/unbind ) 2>/dev/null &
	sleep 10
	echo s > /proc/sysrq-trigger
	sleep 2
	echo b > /proc/sysrq-trigger
	exit 0
}

run() { # run NAME TIMEOUT SCRIPT [VAR=value ...]
	n=$1; t=$2; s=$3; shift 3
	A "step $n: $s $*"
	# --foreground: the signal goes to the script alone, not to its watchdog feeder
	env LOG="/var/tmp/t715-step-$n.log" "$@" timeout --foreground -k 30 "$t" sh "$D/$s"
	rc=$?
	A "step $n: exit $rc, $(grep -h 'result:' "/var/tmp/t715-step-$n.log" 2>/dev/null | tail -1 | sed -E 's/^[0-9:]+ //')"
	return "$rc"
}

# A hang becomes a panic: the panic dump (dmesg-ramoops) and this boot's console survive in
# pstore, and the panic's restart (software, CONFIG_PANIC_TIMEOUT) goes straight to BOOT.  A
# watchdog reset instead goes through RECOVERY's guard, whose short boot overwrites the
# console of this one (seen on 2026-11-09).
echo 1 > /proc/sys/kernel/hung_task_panic
echo 60 > /proc/sys/kernel/hung_task_timeout_secs
echo 1 > /proc/sys/kernel/softlockup_panic
A "start: part '$PART', kernel $(uname -v | cut -c1-24); hung task and soft lockup panic $(cat /proc/sys/kernel/hung_task_panic)$(cat /proc/sys/kernel/softlockup_panic), hung task timeout $(cat /proc/sys/kernel/hung_task_timeout_secs) s; 90 s for the system to settle"
sleep 90
for f in wifi-d3.sh wifi-cycle.sh wifi-guard-test.sh; do
	[ -r "$D/$f" ] || { A "missing $f next to this script"; finish; }
done

case $PART in
d3)
	run 1-d3dev-sbmbx 200 wifi-d3.sh STEP=d3dev N=1 DB1=0 || finish
	run 2-d3dev-db1 200 wifi-d3.sh STEP=d3dev N=1 DB1=1 STOCK=1 || finish ;;
keep)
	run 1-d3dev-stock 200 wifi-d3.sh STEP=d3dev N=2 STOCK=1 || finish
	run 2-d3plat-keep 300 wifi-d3.sh STEP=d3plat N=2 STOCK=1 KEEP=1 || finish
	run 3-freeze10-keep 300 wifi-d3.sh STEP=freeze N=2 SECS=10 STOCK=1 KEEP=1 || finish
	run 4-freeze20-keep 400 wifi-d3.sh STEP=freeze N=2 SECS=20 STOCK=1 KEEP=1 || finish ;;
cycles)
	run 1-cycle-aspm-off 1500 wifi-cycle.sh ASPM=off CONSOLE=1 WAITS="1 5 15 1 5 15 1 5 15 1 5 15" || finish
	run 2-cycle-aspm-late 1500 wifi-cycle.sh ASPM=late CONSOLE=1 WAITS="1 5 15 1 5 15 1 5 15 1 5 15" || finish ;;
retry)
	run 1-cycle-retry 900 wifi-cycle.sh CONTINUE=1 CONSOLE=1 WAITS="2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2" || finish ;;
phy)
	echo Y > /sys/module/phy_exynos_pcie/parameters/stock_power
	echo Y > /sys/module/pci_exynos/parameters/stock_link
	A "stock_power $(cat /sys/module/phy_exynos_pcie/parameters/stock_power), stock_link $(cat /sys/module/pci_exynos/parameters/stock_link)"
	run 1-cycle-phy 900 wifi-cycle.sh CONTINUE=1 CONSOLE=1 WAITS="2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2" || finish ;;
full)
	echo Y > /sys/module/phy_exynos_pcie/parameters/stock_power
	echo Y > /sys/module/pci_exynos/parameters/stock_link
	A "stock_power $(cat /sys/module/phy_exynos_pcie/parameters/stock_power), stock_link $(cat /sys/module/pci_exynos/parameters/stock_link), Bluetooth power-cycled too"
	run 1-cycle-full 900 wifi-cycle.sh FULL=1 CONTINUE=1 CONSOLE=1 WAITS="2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2" || finish ;;
order)
	echo Y > /sys/module/phy_exynos_pcie/parameters/stock_power
	echo Y > /sys/module/pci_exynos/parameters/stock_link
	A "stock_power $(cat /sys/module/phy_exynos_pcie/parameters/stock_power), stock_link $(cat /sys/module/pci_exynos/parameters/stock_link): the whole chip, Bluetooth first, then Bluetooth last"
	run 1-order-before 900 wifi-cycle.sh FULL=1 BTORDER=before CONTINUE=1 CONSOLE=1 WAITS="2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2"
	run 2-order-late 900 wifi-cycle.sh FULL=1 BTORDER=late CONTINUE=1 CONSOLE=1 WAITS="2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2" ;;
guard)
	# t715-wifi-guard (next to this script) on simulated boots, on the daily candidate kernel
	install -m 0755 "$D/t715-wifi-guard" /usr/local/sbin/t715-wifi-guard ||
		{ A "no t715-wifi-guard next to this script"; finish; }
	run 1-guard 1500 wifi-guard-test.sh N=20 || finish ;;
*)
	A "no part to run (t715-autotest.part: d3, keep, cycles, retry, phy, full, order or guard)" ;;
esac
finish
