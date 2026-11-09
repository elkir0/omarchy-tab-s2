#!/bin/sh
# wifi-d3.sh — a ladder of suspend tests for the Wi-Fi kept powered through a
# suspend: brcmfmac's own D3 handshake (the firmware told by mailbox, DB1 the
# PCIe doorbell 1, acked or not), the PCIe host's PME_Turn_Off and PERST#, and
# the hot resume (the firmware's contexts kept, no fresh probe).  One depth
# per run, STEP:
#   d3dev   pm_test's devices level: every driver's suspend and resume, no
#           platform code, no power cut
#   d3plat  the platform level: the PCIe host's own suspend/resume too, its
#           PERST# and PME_Turn_Off, still no power cut
#   freeze  a real suspend-to-idle, woken by the PMIC's RTC alarm SECS s
#           later, the chip powered only while pci_exynos's keep_power holds
# Run as root on the sleep test kernel, the CP off, under systemd-run:
#
#   systemd-run --unit=t715-wifi-d3-$$ -E STEP=d3dev -E DB1=1 sh /var/tmp/wifi-d3.sh
#
# N cycles (3 by default).  DB1, STOCK, KEEP, CONSOLE (each 0|1, 0): the
# switches written before the first cycle and read back in the start line —
# brcmfmac's pcie_mb_db1 (the D3 mailbox through doorbell 1), pcie_stock_d3
# (the vendor driver's D3 handshake and hot resume), pci_exynos's keep_power
# (the host keeps the chip powered across the suspend) and brcmfmac's
# pcie_console (the firmware's own console in the kernel log); all four back
# to N at the end.  Each cycle: the suspend, the Wi-Fi ready again within
# 60 s and finding networks (a count only), the kernel lines since it (the
# D3, the resume, the host's sleep, the firmware's console), the host's elbi
# registers, then whether the D3 was acked by the firmware, found late in
# dtoh_mb_data (a warm ack) or not acked at all, and whether the resume was
# hot.  Stops at the first failure.  Refuses unless: the exynos-pcie driver
# is there, the CP is off, pm_test is none, the kernel is the dry run one
# with its arm switch off, and the Wi-Fi is ready; freeze also needs the
# PMIC's RTC and SECS at most 20 (the hardware watchdog's 30 s), which the
# feeder keeps fed across the suspend.  Every line goes to the kernel log
# ("t715-wifid3:"), which pstore keeps, and to $LOG (/var/tmp/t715-wifi-d3.log
# by default).  No address of any kind is logged, nor SSIDs, nor the kernel
# command line.
set -u
STEP=${STEP:-}
N=${N:-3}; SECS=${SECS:-10}
DB1=${DB1:-0}; STOCK=${STOCK:-0}; KEEP=${KEEP:-0}; CONSOLE=${CONSOLE:-0}
LOG=${LOG:-/var/tmp/t715-wifi-d3.log}
P=/sys/power
HOST=15700000.pcie
DRV=/sys/bus/platform/drivers/exynos-pcie
STOP=/run/t715-wifi-d3.stop
DB1P=/sys/module/brcmfmac/parameters/pcie_mb_db1
STOCKP=/sys/module/brcmfmac/parameters/pcie_stock_d3
CONP=/sys/module/brcmfmac/parameters/pcie_console
KEEPP=/sys/module/pci_exynos/parameters/keep_power
ARM=/sys/module/exynos5433_sleep/parameters/arm
SHOW='D3:|resume:|sleep: |all ones|Firmware has halted|Timeout on response|past its depth|probe after resume|PM: '
BAD='all ones|Firmware has halted|Timeout on response|past its depth|probe after resume failed'

K() { echo "<3>t715-wifid3: $*" > /dev/kmsg; echo "$(date +%T) $*" >> "$LOG"; }
kmark() { dmesg | tail -1 | sed 's/^\[ *\([0-9.]*\)\].*/\1/'; }
since() { dmesg | awk -v t="$1" '{s=$0; sub(/^\[ */,"",s); split(s,a,"]"); if (a[1]+0 > t+0) print}'; }
kmask() { # kernel lines from stdin: no SSIDs (any case) nor the Kernel command line,
	# addresses masked, the [  123.456] time prefix removed
	grep -viE 'ssid|Kernel command line|NetworkManager|wpa_supplicant|UFW BLOCK' |
		sed -E 's/^\[ *[0-9.]+\] //; s/([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}/<addr>/g'
}
elbi() { # the PCIe host's elbi registers (debugfs), a line each
	if [ -r "/sys/kernel/debug/$HOST/elbi" ]; then
		while read -r l || [ -n "$l" ]; do K "  elbi: $l"; done < "/sys/kernel/debug/$HOST/elbi"
	else
		K "  elbi: unreadable"
	fi
}
wifi_state() { nmcli -t -f TYPE,STATE device 2>/dev/null | awk -F: '$1=="wifi"{print $2}' | head -1; }
wifi_ready() { case $(wifi_state) in connected | disconnected) return 0 ;; esac; return 1; }
nets() { nmcli device wifi rescan >/dev/null 2>&1; sleep 4; nmcli -t -f BSSID device wifi list 2>/dev/null | grep -c .; }
set_sw() { # $1: 0|1, $2: the parameter file, 1 -> Y, 0 -> N
	case $1 in 1) echo Y > "$2" ;; *) echo N > "$2" ;; esac
}
gomem() { echo mem > $P/state; } # its own function: rc=$? is this write's status
no() { K "$*: refused"; exit 1; }

mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
[ -d "$DRV" ] || no "no exynos-pcie driver"
[ -e /run/shannon/cp-state ] && grep -q "state=online" /run/shannon/cp-state && no "the CP is online"
[ "$(sed -E 's/.*\[([a-z]+)\].*/\1/' $P/pm_test 2>/dev/null)" = none ] || no "pm_test is not none"
grep -qw "exynos5433_sleep=dryrun" /proc/cmdline || no "not the dry run sleep test kernel"
[ "$(cat "$ARM" 2>/dev/null)" != "Y" ] || no "the real sleep is armed"
case $STEP in d3dev | d3plat | freeze) ;; *) no "STEP d3dev, d3plat or freeze" ;; esac
bad=0
case $DB1 in 0 | 1) ;; *) bad=1 ;; esac
case $STOCK in 0 | 1) ;; *) bad=1 ;; esac
case $KEEP in 0 | 1) ;; *) bad=1 ;; esac
case $CONSOLE in 0 | 1) ;; *) bad=1 ;; esac
[ "$bad" = 0 ] || no "DB1, STOCK, KEEP and CONSOLE are each 0 or 1"
[ "$SECS" -le 20 ] || no "SECS above 20: the watchdog's 30 s would fire"
RTC=
if [ "$STEP" = freeze ]; then
	for r in /sys/class/rtc/rtc*; do grep -qiE 's2mps|s5m' "$r/name" 2>/dev/null && RTC=${r##*/}; done
	[ -n "$RTC" ] || no "no PMIC RTC"
fi

rm -f "$STOP"
( trap '' TERM INT HUP
  exec 3>/dev/watchdog || exit 1
  while [ ! -e "$STOP" ]; do printf . >&3; sleep 5; done
  printf V >&3 ) &
FEED=$!
finish() {
	touch "$STOP"; wait "$FEED" 2>/dev/null
	echo none > $P/pm_test 2>/dev/null
	set_sw 0 "$DB1P"; set_sw 0 "$STOCKP"; set_sw 0 "$KEEPP"; set_sw 0 "$CONP"
}
trap finish EXIT
trap 'exit 1' TERM INT HUP
echo 1 > /sys/module/s3c2410_wdt/parameters/keep_running_in_suspend
echo N > /sys/module/printk/parameters/console_suspend

w=0; while ! wifi_ready && [ "$w" -lt 30 ]; do sleep 1; w=$((w + 1)); done
wifi_ready || no "the Wi-Fi is not ready at the start ($(wifi_state))"
set_sw "$DB1" "$DB1P"; set_sw "$STOCK" "$STOCKP"; set_sw "$KEEP" "$KEEPP"; set_sw "$CONSOLE" "$CONP"
K "start: STEP=$STEP N=$N SECS=$SECS; db1 $(cat "$DB1P" 2>/dev/null), stock $(cat "$STOCKP" 2>/dev/null), keep $(cat "$KEEPP" 2>/dev/null), console $(cat "$CONP" 2>/dev/null); $(nets) networks; kernel $(uname -v | cut -c1-24)"

i=1
while [ "$i" -le "$N" ]; do
	m=$(kmark)
	case $STEP in
	d3dev | d3plat)
		lvl=devices
		[ "$STEP" = d3plat ] && lvl=platform
		echo "$lvl" > $P/pm_test
		# as pmtest.sh: a level that did not take would send "mem" down the
		# whole dry-run path instead of this level
		grep -q "\[$lvl\]" $P/pm_test || no "pm_test did not take $lvl"
		gomem; rc=$?
		echo none > $P/pm_test ;;
	freeze) rtcwake -d "$RTC" -m freeze -s "$SECS" >/dev/null 2>&1; rc=$? ;;
	esac
	w=0
	while ! wifi_ready && [ "$w" -lt 60 ]; do sleep 2; w=$((w + 2)); done
	x=$(nets)
	since "$m" | grep -E "$SHOW" | kmask | cut -c1-160 | while read -r l; do K "  $l"; done
	elbi
	d3=none
	since "$m" | grep -q 'ack found in dtoh_mb_data' && d3=war
	[ "$d3" = none ] && since "$m" | grep -q 'D3: acked by the firmware' && d3=acked
	[ "$d3" = none ] && since "$m" | grep -q 'no D3 ack from the firmware' && d3=noack
	if since "$m" | grep -q 'resume: hot'; then res=hot; else res=other; fi
	K "cycle $i: rc $rc, Wi-Fi back in $w s, $x networks, D3 $d3, resume $res"
	ok=1
	[ "$rc" = 0 ] || ok=0
	wifi_ready || ok=0
	[ "$x" -gt 0 ] || ok=0
	since "$m" | grep -qE "$BAD" && ok=0
	[ "$ok" = 1 ] || { K "result: FAIL at cycle $i"; exit 1; }
	i=$((i + 1))
done
K "result: all $N cycles OK"
