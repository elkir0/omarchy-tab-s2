#!/bin/sh
# hotplug-a57.sh — CPU hot-unplug cycles with integrity checks, run as root
# ON THE TABLET on a kernel with the t715-power hot-unplug
# (docs/hardware/BATTERY.md sections 10 and 11):
#
#   ssh root@172.16.42.1 'N=30 sh -s' < image/tests/ondevice/hotplug-a57.sh
#
# A57 stages: one core, two cores, the whole cluster (its last core asks the
# monitor for the cluster), the whole cluster under load on the A53s, then a
# long off.  A53 stages (a kernel that lets cpu1-3 go, CPU0 never does): one
# core, two, all three, all three under load on CPU0, then a long off.  The
# A57 stages need the four A57s online; the A53 stages work either way.
# After every stage: the CPUs online as at the start, sha256 of a fixed
# buffer on each CPU of the stage equal to the reference, and no suspicious
# kernel line.  Stops at the first fault; the log is in
# /var/tmp/t715-hotplug-*.log.
set -u
CPU=/sys/devices/system/cpu
LOG=${LOG:-/var/tmp/t715-hotplug-$(date +%Y%m%d-%H%M%S).log}
N=${N:-30}
BUF=/run/t715-hp.buf

log() { echo "$(cut -d' ' -f1 /proc/uptime) $*" >> "$LOG"; }
die() { log "FAIL: $*"; dmesg | grep -v "Kernel command line" | tail -40 >> "$LOG"; exit 1; }

kmark() { dmesg | tail -1 | sed 's/^\[ *\([0-9.]*\)\].*/\1/'; }
kcheck() { # kernel lines after mark $1 that look wrong; user-space lines
	# forwarded to the kernel log (name[pid]: ..., t715.returnafter) are
	# skipped, and so is the kernel command line (it holds the serial number)
	dmesg | awk -v t="$1" '{s=$0; sub(/^\[ */,"",s); split(s,a,"]"); if (a[1]+0 > t+0) print}' |
		grep -vE '^\[ *[0-9.]+\] [^ :]+\[[0-9]+\]: |Kernel command line' |
		grep -E "unable to kill|still powered|spurious|did not leave|timed out|BUG:|WARNING:|Oops|Unhandled|failed" && return 1
	return 0
}

off() { for c in "$@"; do echo 0 > $CPU/cpu$c/online || die "offline cpu$c"; done; }
on()  { for c in "$@"; do echo 1 > $CPU/cpu$c/online || die "online cpu$c"; done; }

hashes() { # sha256 of the buffer on each given CPU
	for c in "$@"; do taskset -c "$c" sha256sum "$BUF" | cut -c1-16; done | sort -u
}

head -c 33554432 /dev/urandom > "$BUF"
REF=$(taskset -c 0 sha256sum "$BUF" | cut -c1-16)
ONLINE0=$(cat $CPU/online)
log "start N=$N ref=$REF online=$ONLINE0"

stage() { # name, then the CPUs to take down (in that order)
	name=$1; shift
	[ "$(hashes "$@")" = "$REF" ] || die "$name: hash before any cycle"
	m=$(kmark); t0=$(cut -d' ' -f1 /proc/uptime)
	i=0
	while [ $i -lt "$N" ]; do
		off "$@"
		ol=$(cat $CPU/online)
		up=""; for c in "$@"; do up="$c $up"; done
		on $up
		[ "$(cat $CPU/online)" = "$ONLINE0" ] || die "$name cycle $i: online $(cat $CPU/online)"
		i=$((i + 1))
	done
	t1=$(cut -d' ' -f1 /proc/uptime)
	[ "$(hashes "$@")" = "$REF" ] || die "$name: hash after $N cycles"
	kcheck "$m" >> "$LOG" || die "$name: kernel lines above"
	log "ok $name: $N cycles in $(awk -v a="$t0" -v b="$t1" "BEGIN{print b-a}") s (down: $ol)"
}

# load CPUS...: sha256 loops on those CPUs until unload
load() { for c in "$@"; do (while :; do taskset -c $c sha256sum "$BUF" >/dev/null; done) & done; }
unload() { kill $(jobs -p) 2>/dev/null; wait 2>/dev/null; }

long_off() { # name, then the CPUs to take down
	name=$1; shift
	m=$(kmark); off "$@"; log "$name: off for 120 s, online $(cat $CPU/online)"
	sleep 120
	up=""; for c in "$@"; do up="$c $up"; done
	on $up
	[ "$(cat $CPU/online)" = "$ONLINE0" ] || die "$name: online $(cat $CPU/online)"
	[ "$(hashes "$@")" = "$REF" ] || die "$name: hash"
	kcheck "$m" >> "$LOG" || die "$name: kernel lines above"
	log "ok $name"
}

STAGES=${STAGES:-"core7 cores76 cluster cluster-load long-off"}
want() { case " $STAGES " in *" $1 "*) return 0 ;; esac; return 1; }

want core7 && stage core7 7
want cores76 && stage cores76 7 6
want cluster && stage cluster 7 6 5 4
if want cluster-load; then
	load 0 1 2 3; stage cluster-load 7 6 5 4; unload
fi
want long-off && long_off long-off 7 6 5 4

want a53-core3 && stage a53-core3 3
want a53-cores32 && stage a53-cores32 3 2
want a53-all && stage a53-all 3 2 1
if want a53-all-load; then
	load 0; stage a53-all-load 3 2 1; unload
fi
want a53-long-off && long_off a53-long-off 3 2 1

rm -f "$BUF"
log "PASS"
