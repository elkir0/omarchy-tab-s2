#!/bin/sh
# wifi-sleep.sh — the Wi-Fi through a sleep, its PCIe host unbound before
# and probed afresh after (on the sleep test kernel WLAN_EN is switchable:
# the host's remove cuts the chip's power, its probe powers it again, the
# reload that works where brcmfmac's own D3 does not).  N cycles, the
# hardware watchdog kept running across each sleep.  Run as root on the
# sleep test kernel, CP off, under systemd-run (the USB link drops while it
# sleeps):
#
#   systemd-run --unit=t715-wifi-sleep -E MODE=freeze -E N=5 sh /var/tmp/wifi-sleep.sh
#
# MODE=freeze  suspend-to-idle woken by the PMIC's RTC alarm after SECS
# MODE=dryrun  the 5433 sleep entry up to the SMC (exynos5433_sleep=dryrun,
#              refused while the real sleep is armed), back at once
# After each wake: the Wi-Fi device ready again and finding networks (a
# count only: the test root has no saved network), Bluetooth powered, the
# microSD card still mounted if it was, the sound cards and input devices
# still there, and the kernel lines since the cycle.  Stops at the first failure.
# No address of any kind is logged.
set -u
MODE=${MODE:-freeze}; N=${N:-3}; SECS=${SECS:-15}
LOG=${LOG:-/var/tmp/t715-wifi-sleep-$(date +%Y%m%d-%H%M%S).log}
P=/sys/power
HOST=15700000.pcie
DRV=/sys/bus/platform/drivers/exynos-pcie

log() { echo "$(cut -d' ' -f1 /proc/uptime) $*" | tee -a "$LOG"; }
kmark() { dmesg | tail -1 | sed 's/^\[ *\([0-9.]*\)\].*/\1/'; }
klines() { # kernel lines after mark $1: no command line, no firewall lines, addresses masked
	dmesg | awk -v t="$1" '{s=$0; sub(/^\[ */,"",s); split(s,a,"]"); if (a[1]+0 > t+0) print}' |
		grep -vE 'Kernel command line|UFW BLOCK|^\[ *[0-9.]+\] [^ :]+\[[0-9]+\]: |Direct firmware load for brcm/.* failed with error -2' |
		sed -E 's/([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}/<addr>/g'
}
BAD="BUG:|WARNING:|Oops|Unhandled|[Ff]ailed|[Ee]rror|timed out|[Uu]nable|[Rr]efused|[Aa]bort"

wifi_state() { nmcli -t -f TYPE,STATE device 2>/dev/null | awk -F: '$1=="wifi"{print $2; f=1} END{if (!f) print "absent"}' | head -1; }
wifi_ready() { case $(wifi_state) in connected | disconnected) return 0 ;; esac; return 1; }
wifi_count() { nmcli device wifi rescan >/dev/null 2>&1; sleep 4; nmcli -t -f BSSID device wifi list 2>/dev/null | grep -c .; }
bt_state() { btmgmt info 2>/dev/null | grep -q 'current settings:.* powered' && echo powered || echo off; }
sd_state() { grep -q '^/dev/mmcblk[1-9]' /proc/mounts && echo mounted || echo none; }
state() { echo "wifi=$(wifi_state) bt=$(bt_state) sd=$(sd_state) cards=$(grep -c '^ *[0-9]' /proc/asound/cards) inputs=$(grep -c '^N:' /proc/bus/input/devices)"; }

[ -e /run/shannon/cp-state ] && grep -q "state=online" /run/shannon/cp-state && { log "the CP is online: not on this kernel"; exit 1; }
[ -d "$DRV" ] || { log "no exynos-pcie driver"; exit 1; }
[ "$(sed -E 's/.*\[([a-z]+)\].*/\1/' $P/pm_test 2>/dev/null)" = none ] || { log "pm_test is not none"; exit 1; }
case $MODE in
freeze)
	RTC=
	for r in /sys/class/rtc/rtc*; do grep -qiE 's2mps|s5m' "$r/name" 2>/dev/null && RTC=${r##*/}; done
	[ -n "$RTC" ] || { log "no PMIC RTC"; exit 1; }
	[ "$SECS" -le 20 ] || { log "SECS above 20: the watchdog's 30 s would fire"; exit 1; } ;;
dryrun)
	grep -qw "exynos5433_sleep=dryrun" /proc/cmdline || { log "dryrun without exynos5433_sleep=dryrun: refused"; exit 1; }
	[ "$(cat /sys/module/exynos5433_sleep/parameters/arm 2>/dev/null)" != "Y" ] || { log "the real sleep is armed: refused"; exit 1; } ;;
*) log "MODE freeze or dryrun"; exit 1 ;;
esac

echo 1 > /sys/module/s3c2410_wdt/parameters/keep_running_in_suspend
echo N > /sys/module/printk/parameters/console_suspend
exec 3>/dev/watchdog || { log "cannot open /dev/watchdog"; exit 1; }
finish() { printf V >&3; exec 3>&-; log "end: watchdog $(cat /sys/class/watchdog/watchdog0/state)"; }
trap finish EXIT
trap 'exit 1' TERM INT HUP
wifi_ready || { log "the Wi-Fi is not ready before the first cycle: $(state)"; exit 1; }
log "start: MODE=$MODE N=$N SECS=$SECS; $(state), $(wifi_count) networks; kernel $(uname -v | cut -c1-40)"
before=$(state)

i=1
while [ "$i" -le "$N" ]; do
	printf . >&3
	m=$(kmark)
	echo "$HOST" > "$DRV/unbind" || { log "cycle $i: unbind failed"; exit 1; }
	t0=$(cut -d' ' -f1 /proc/uptime)
	printf . >&3
	if [ "$MODE" = freeze ]; then
		rtcwake -d "$RTC" -m freeze -s "$SECS" >/dev/null 2>&1; rc=$?
	else
		echo mem > $P/state; rc=$?
	fi
	t1=$(cut -d' ' -f1 /proc/uptime)
	printf . >&3
	echo "$HOST" > "$DRV/bind" || { log "cycle $i: bind failed"; exit 1; }
	w=0
	while ! wifi_ready && [ "$w" -lt 60 ]; do sleep 2; w=$((w + 2)); printf . >&3; done
	nets=$(wifi_count); printf . >&3
	after=$(state)
	n=$(klines "$m" | grep -cE "$BAD")
	log "cycle $i: rc $rc, asleep $(awk -v a="$t0" -v b="$t1" 'BEGIN{print b-a}') s, Wi-Fi back in ${w} s, $nets networks; $after; suspicious kernel lines $n"
	klines "$m" | grep -E "PM:|[Ss]uspend|[Rr]esume|EXYNOS5433|brcmf|pcie|$BAD" | cut -c1-160 >> "$LOG"
	[ "$rc" = 0 ] && [ "$after" = "$before" ] && [ "$nets" -gt 0 ] && [ "$n" = 0 ] || { log "FAIL at cycle $i (before: $before)"; exit 1; }
	i=$((i + 1))
done
log "PASS"
