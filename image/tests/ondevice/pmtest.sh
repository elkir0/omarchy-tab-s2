#!/bin/sh
# pmtest.sh — the suspend path up to pm_test levels, with the watchdog armed,
# run as root ON THE TABLET on a TEST kernel (image mode, the CP off: the
# modem driver refuses suspend while it is powered) booted with the watchdog
# kept running across suspend (docs/hardware/BATTERY.md section 11):
#
#   ssh root@172.16.42.1 'LEVELS="freezer devices platform processors core" sh -s' \
#       < image/tests/ondevice/pmtest.sh
#
# The watchdog is armed with its 30 s timeout and fed before and after each
# level by this shell, which holds it open: a level that does not come back
# within 30 s ends in a watchdog reset (sboot boots RECOVERY again, whose
# guard goes on to BOOT), not in a dead tablet.  So does this script dying
# without its magic close: run it under systemd-run, not on an SSH tty.  Each
# level: /sys/power/pm_test, then "mem" into /sys/power/state, which the
# kernel stops short of the real sleep at that level; then the time it took,
# the suspend statistics and the kernel lines since that look wrong (the
# kernel command line excepted).  Stops at the first failure.  Refuses to run
# if pm_test is "none" after setting it (a real sleep would follow), or with
# the CP powered.  Puts "none" back and disarms the watchdog at the end.
set -u
LEVELS=${LEVELS:-"freezer devices platform processors core"}
LOG=${LOG:-/var/tmp/t715-pmtest-$(date +%Y%m%d-%H%M%S).log}
P=/sys/power

log() { echo "$(cut -d' ' -f1 /proc/uptime) $*" | tee -a "$LOG"; }
kmark() { dmesg | tail -1 | sed 's/^\[ *\([0-9.]*\)\].*/\1/'; }
klines() { # kernel lines after mark $1, the command line and user space's
	# lines forwarded to the kernel log (name[pid]: ..., this script's own)
	# excepted, and the optional files brcmfmac looks up whenever it probes
	dmesg | awk -v t="$1" '{s=$0; sub(/^\[ */,"",s); split(s,a,"]"); if (a[1]+0 > t+0) print}' |
		grep -vE 'Kernel command line|^\[ *[0-9.]+\] [^ :]+\[[0-9]+\]: |Direct firmware load for brcm/.* failed with error -2'
}
stats() { for f in success fail failed_suspend failed_resume last_failed_dev; do printf "%s=%s " $f "$(cat $P/suspend_stats/$f 2>/dev/null)"; done; }
# case-sensitive: "BUG:" must not match "PM: suspend debug:"
BAD="BUG:|WARNING:|Oops|Unhandled|[Ff]ailed|[Ee]rror|timed out|[Uu]nable|[Rr]efused|[Aa]bort"

[ -w $P/pm_test ] || { log "no $P/pm_test (CONFIG_PM_DEBUG off?)"; exit 1; }
# "none" is the whole path: only on a kernel whose sleep is a dry run (no
# SMC_CMD_SLEEP), never one that would really sleep with nobody at the tablet.
case " $LEVELS " in *" none "*)
	grep -qw "exynos5433_sleep=dryrun" /proc/cmdline || { log "level none without exynos5433_sleep=dryrun: refused"; exit 1; }
	# the runtime arm switch of the sleep test kernel turns the next dry run into a real sleep
	[ "$(cat /sys/module/exynos5433_sleep/parameters/arm 2>/dev/null)" != "Y" ] || { log "level none with the real sleep armed: refused"; exit 1; } ;;
esac
[ -e /run/shannon/cp-state ] && grep -q "state=online" /run/shannon/cp-state && { log "the CP is online: not on this kernel"; exit 1; }
log "start levels: $LEVELS; mem_sleep: $(cat $P/mem_sleep); kernel $(uname -v | cut -c1-40)"

exec 3>/dev/watchdog || { log "cannot open /dev/watchdog"; exit 1; }
log "watchdog armed, timeout $(cat /sys/class/watchdog/watchdog0/timeout) s"
finish() {
	echo none > $P/pm_test
	printf V >&3; exec 3>&-   # the magic close: disarmed
	log "end: pm_test $(cat $P/pm_test), watchdog $(cat /sys/class/watchdog/watchdog0/state)"
}
trap finish EXIT
trap 'exit 1' TERM INT HUP

for level in $LEVELS; do
	printf . >&3
	echo "$level" > $P/pm_test
	grep -q "\[$level\]" $P/pm_test || { log "pm_test did not take $level: $(cat $P/pm_test)"; exit 1; }
	m=$(kmark); t0=$(cut -d' ' -f1 /proc/uptime)
	if echo mem > $P/state; then rc=0; else rc=$?; fi
	t1=$(cut -d' ' -f1 /proc/uptime)
	printf . >&3
	n=$(klines "$m" | grep -cE "$BAD")
	log "$level: rc $rc, $(awk -v a="$t0" -v b="$t1" 'BEGIN{print b-a}') s, suspicious lines $n, stats: $(stats)"
	klines "$m" | grep -E "PM:|[Ss]uspend|[Rr]esume|$BAD" | cut -c1-160 >> "$LOG"
	[ "$rc" = 0 ] && [ "$n" = 0 ] || { log "FAIL at $level"; exit 1; }
done
log "PASS"
