#!/bin/sh
# linkpm.sh — the link PM test modules on the tablet (research/modem/LINK-PM.md
# section 6), as root ON THE TABLET, the owner present.  Nothing here runs at
# boot and nothing is installed: the modules stay in $DIR.
#
#   scp out/mainline-linkpm/modules/sec_modem_v1.ko \
#       out/mainline-linkpm/modules/exynos5433-mipi-lli.ko root@172.16.42.1:/var/tmp/linkpm/
#   scp image/tests/ondevice/linkpm.sh root@172.16.42.1:/run/
#
#   sh /run/linkpm.sh check        the preconditions only
#   sh /run/linkpm.sh load [MODE]  the test modules (MODE lockon, the default,
#                                  or fsm), then the CP ONLINE
#   sh /run/linkpm.sh mode MODE    CP off, pm_mode written, CP on again
#   sh /run/linkpm.sh status       the link PM lines of ss333/status, the LLI
#                                  mounts, the loader's state
#   sh /run/linkpm.sh watch SECS   a shannonctl round trip every 10 s for SECS,
#                                  then the counters; stops at the first failure
#   sh /run/linkpm.sh sends N [S]  N times, S s apart (default 30, time for the CP
#                                  to let go): shannonctl refresh, which sends
#                                  real IPC GETs to the CP; checks that each
#                                  woke the link from the AP side (HOLDING)
#   sh /run/linkpm.sh soak SECS    one sample a minute (the FSM, the mounts, one
#                                  round trip), for a screen-off soak
#   sh /run/linkpm.sh cycles N     N times: CP off at a varied moment (the FSM
#                                  state then is logged), CP on, checked
#
# "load" needs a boot without the modem modules: t715-modem-power off (which
# also leaves shannon-modem-prepare disabled at boot), then systemctl reboot.
# The way back: t715-modem-power on, then systemctl reboot (the installed
# modules load again at boot).  The modules are [permanent]: they cannot be
# unloaded, so a second load needs a reboot.  Logs states and counts only,
# never the kernel command line, a SIM or line identity.
set -u
DIR=${DIR:-/var/tmp/linkpm}
SS=/sys/kernel/debug/ss333/status
P=/sys/module/sec_modem_v1/parameters/pm_mode
FG=/sys/class/power_supply/sm5703-fuelgauge

die() { echo "linkpm: $*" >&2; exit 1; }
kmsg_fail() {
	# failures only; never the command line, never UFW lines
	dmesg | grep -v -e "Kernel command line" -e "UFW BLOCK" |
		grep -E "PM WDOG|CP_FAIL|AP_FAIL|mount refused|edge storm|irq storm|Mount failed|BUG:|WARNING:|Oops" || true
}

gates() {
	cap=$(cat $FG/capacity); temp=$(cat $FG/temp)
	[ "$cap" -ge 30 ] || die "battery at $cap %: 30 % or more"
	[ "$temp" -lt 450 ] || die "battery at $temp deci-degC: under 45.0 degC"
}

check() {
	gates
	[ -f "$DIR/sec_modem_v1.ko" ] && [ -f "$DIR/exynos5433-mipi-lli.ko" ] || die "no test modules in $DIR"
	for m in sec_modem_v1 exynos5433_mipi_lli; do
		grep -q "^$m " /proc/modules && die "$m is loaded: t715-modem-power off, then reboot"
	done
	[ "$(systemctl is-enabled shannon-modem-prepare.service)" = disabled ] ||
		die "shannon-modem-prepare is enabled: t715-modem-power off first"
	# the running kernel's own modem module gives the vermagic to match
	ref=/usr/lib/modules/$(uname -r)/kernel/drivers/misc/modem_v1/sec_modem_v1.ko
	want=$(modinfo -F vermagic "$ref" | sed 's/[[:space:]]*$//')
	[ -n "$want" ] || die "no vermagic in $ref"
	for f in "$DIR"/*.ko; do
		[ "$(modinfo -F vermagic "$f" | sed 's/[[:space:]]*$//')" = "$want" ] ||
			die "$f: vermagic is not '$want'"
	done
	echo "linkpm: ready (battery $cap %, $temp deci-degC)"
}

cp_wait() { # cp_wait STATE SECONDS (its counter is its own: cycles uses n)
	cw=0
	while ! grep -q "state=$1" /run/shannon/cp-state 2>/dev/null; do
		cw=$((cw + 1)); [ "$cw" -le "$2" ] || return 1
		sleep 1
	done
}

cp_on() {
	gates
	systemctl start shannon-loader.service shannond.service
	cp_wait online 90 || die "CP not ONLINE within 90 s"
	echo "linkpm: CP ONLINE"
}

cp_off() {
	systemctl stop shannond.service shannon-loader.service
	echo "linkpm: CP off"
}

load() {
	mode=${1:-lockon}
	check
	modprobe spi_s3c64xx
	insmod "$DIR/exynos5433-mipi-lli.ko" || die "insmod exynos5433-mipi-lli failed"
	insmod "$DIR/sec_modem_v1.ko" "pm_mode=$mode" || die "insmod sec_modem_v1 failed"
	for m in exynos5433_mipi_lli sec_modem_v1; do
		echo 1 > /sys/module/$m/parameters/allow_hw
	done
	echo "linkpm: test modules loaded, pm_mode $(cat $P)"
	cp_on
	status
}

mode() {
	case ${1:-} in lockon | fsm) ;; *) die "usage: linkpm.sh mode lockon|fsm" ;; esac
	cp_off
	echo "$1" > $P || die "pm_mode refused"
	cp_on
	status
}

status() {
	echo "pm_mode (next session): $(cat $P 2>/dev/null)"
	sed -n '/^link pm:/,$p' $SS 2>/dev/null
	sed -n 's/^  \(cp2ap_wakeup\|cp2ap_status\|lli_doorbell\)/  \1/p' $SS 2>/dev/null
	grep -h -E "mnt|mount|afc_valid" /sys/kernel/debug/mipi-lli/status 2>/dev/null | head -5
	echo "cp: $(cat /run/shannon/cp-state 2>/dev/null)"
	f=$(kmsg_fail | wc -l); echo "kernel failure lines: $f"
}

watch() {
	secs=${1:-600}; t=0; slow=0
	f0=$(kmsg_fail | wc -l)	# lines from before the watch do not count
	while [ "$t" -lt "$secs" ]; do
		gates
		a=$(cut -d' ' -f1 /proc/uptime)
		timeout 5 shannonctl status >/dev/null 2>&1 || { echo "linkpm: shannonctl status failed at ${t}s"; status; exit 1; }
		b=$(cut -d' ' -f1 /proc/uptime)
		ms=$(awk -v a="$a" -v b="$b" 'BEGIN { printf "%d", (b - a) * 1000 }')
		[ "$ms" -gt 2000 ] && slow=$((slow + 1))
		f=$(kmsg_fail | wc -l)
		[ "$f" -le "$f0" ] || { echo "linkpm: kernel failure line at ${t}s:"; kmsg_fail | tail -3; status; exit 1; }
		grep -q "state=online" /run/shannon/cp-state || { echo "linkpm: CP left ONLINE at ${t}s"; status; exit 1; }
		printf '%5ss round trip %s ms\n' "$t" "$ms"
		sleep 10; t=$((t + 10))
	done
	echo "linkpm: watch done, round trips over 2 s: $slow"
	status
}

fsm_line() {
	grep -E "fsm: (active|stopped)" $SS | sed 's/^ *//; s/, ref_cnt.*//'
}

entries() { # entries STATE: how often the FSM entered it
	sed -n "s/.*fsm entries:.* $1 \([0-9]*\).*/\1/p" $SS | head -1
}

sends() {
	n=${1:-20}; gap=${2:-30}; i=1; woke=0; slow=0
	f0=$(kmsg_fail | wc -l)
	while [ "$i" -le "$n" ]; do
		sleep "$gap"
		gates
		before=$(fsm_line)
		h0=$(entries HOLDING); h0=${h0:-0}
		a=$(cut -d' ' -f1 /proc/uptime)
		timeout 15 shannonctl refresh >/dev/null 2>&1 || { echo "linkpm: refresh $i failed"; status; exit 1; }
		b=$(cut -d' ' -f1 /proc/uptime)
		ms=$(awk -v a="$a" -v b="$b" 'BEGIN { printf "%d", (b - a) * 1000 }')
		h1=$(entries HOLDING); h1=${h1:-0}
		[ "$h1" -gt "$h0" ] && woke=$((woke + 1))
		[ "$ms" -gt 2000 ] && slow=$((slow + 1))
		f=$(kmsg_fail | wc -l)
		printf 'send %2d: %5s ms, before: %s, HOLDING %s -> %s\n' "$i" "$ms" "$before" "$h0" "$h1"
		[ "$f" -le "$f0" ] || { echo "linkpm: kernel failure line after send $i:"; kmsg_fail | tail -3; status; exit 1; }
		grep -q "state=online" /run/shannon/cp-state || { echo "linkpm: CP left ONLINE after send $i"; status; exit 1; }
		i=$((i + 1))
	done
	echo "linkpm: $n sends, $woke woke the link from the AP side, $slow over 2 s"
	status
}

soak() {
	secs=${1:-3600}; t=0
	f0=$(kmsg_fail | wc -l)
	while [ "$t" -lt "$secs" ]; do
		gates
		rt=ok
		timeout 5 shannonctl status >/dev/null 2>&1 || rt=FAIL
		f=$(kmsg_fail | wc -l)
		printf '%5ss %s | %s | round trip %s | %s\n' "$t" "$(fsm_line)" \
			"$(grep -E '^mount' /sys/kernel/debug/mipi-lli/status)" "$rt" \
			"$(cat /run/shannon/cp-state 2>/dev/null)"
		[ "$rt" = ok ] && [ "$f" -le "$f0" ] && grep -q "state=online" /run/shannon/cp-state ||
			{ echo "linkpm: soak stopped at ${t}s"; kmsg_fail | tail -3; status; exit 1; }
		sleep 60; t=$((t + 60))
	done
	echo "linkpm: soak done"
	status
}

cycles() {
	n=${1:-10}; i=1
	f0=$(kmsg_fail | wc -l)
	while [ "$i" -le "$n" ]; do
		# a varied moment: right after a send (link up), or after an idle
		case $((i % 3)) in
			0) timeout 5 shannonctl status >/dev/null 2>&1 ;;
			1) sleep 40 ;;
			2) sleep 7 ;;
		esac
		echo "cycle $i: CP off in $(fsm_line)"
		cp_off
		cp_on
		f=$(kmsg_fail | wc -l)
		[ "$f" -le "$f0" ] || { echo "linkpm: kernel failure line after cycle $i:"; kmsg_fail | tail -3; status; exit 1; }
		sleep 5
		i=$((i + 1))
	done
	echo "linkpm: $n cycles done"
	status
}

case ${1:-} in
	check) check ;;
	load) load "${2:-lockon}" ;;
	mode) mode "${2:-}" ;;
	status) status ;;
	watch) watch "${2:-600}" ;;
	sends) sends "${2:-20}" "${3:-30}" ;;
	soak) soak "${2:-3600}" ;;
	cycles) cycles "${2:-10}" ;;
	*) sed -n '2,32p' "$0"; exit 2 ;;
esac
