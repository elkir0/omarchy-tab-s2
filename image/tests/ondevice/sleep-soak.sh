#!/bin/sh
# sleep-soak.sh — N real suspends to RAM, each woken by the PMIC's RTC alarm,
# each timed and checked: the daily suspend as the system runs it (the sleep
# hook t715-sleep-prepare powers the modem's CP and the Wi-Fi/Bluetooth chip
# down before the sleep and brings them back after the wake), not a test
# kernel's hand-made sleep.  Run as root ON THE TABLET, unattended, under
# systemd-run while nobody touches it:
#
#   scp image/tests/ondevice/sleep-soak.sh root@172.16.42.1:/run/
#   ssh root@172.16.42.1 systemd-run --unit=t715-sleep-soak --collect \
#       sh /run/sleep-soak.sh 20 60
#
# usage: sh sleep-soak.sh [N [SECS]]   N cycles (20), SECS asleep each (60)
#   READY_MAX   240, seconds given the radios to come back after a wake
#   WAIT_POWER  600, seconds to wait for external power to go away at the
#               start: the hook leaves a suspend on external power a dry
#               run, so a soak on the cable would be dry runs only
#   LOG         /var/log/t715-sleep-soak/soak-YYYYmmdd-HHMMSS.log
#
# Each cycle: wait until the restore service is idle, the Wi-Fi is up
# (t715-wifi-guard's own check) and the CP settled; mark the kernel log, the
# suspend statistics and the journal cursor; set the RTC alarm to +SECS;
# systemctl suspend; wait for the wake, which the hook marks by writing the
# wall clock into /run/t715-sleep/resumed.  One line per cycle in LOG: real
# (the SMC_CMD_SLEEP line after the mark) or dry run or no suspend, the
# wall-clock seconds asleep, the wake's WAKEUP_STAT and EINT_PEND hex words,
# the suspend_stats delta, the battery, and the kernel error counts since
# the mark -- counts only.  Once the next ready wait has measured it: the
# seconds the Wi-Fi and the CP took to come back, the guard's failed
# recovery tries and what the restore said.  A summary closes the log.
#
# The policy service t715-sleep.service, which suspends by itself while the
# screen is dark, is stopped for the soak and started again at the end, on
# every exit and on TERM or INT (a trap), which also clears the alarm.  A
# ready wait that runs out of time fails its cycle; three such cycles in a
# row stop the soak.  Every LOG line also goes to the kernel log at error
# level ("t715-sleep-soak:"), the only level the console keeps, so a crash
# leaves the record in pstore.
#
# Never logged: a raw kernel or journal line, an address, an SSID, a user
# name, a serial number -- only counts, fixed words and the hex words of the
# wake line.  Written: the RTC's wakealarm, LOG and its directory, /dev/kmsg,
# systemctl stop and start of t715-sleep.service, systemctl suspend, nothing
# else: the arm switch and the radios are the sleep hook's business, not
# this test's.
#
# The pure helpers below (the median, the wake line's hex words, the JSON
# word, the kernel-log reading since a mark) are plain functions, so
# SOAK_LIB_ONLY=1 . sleep-soak.sh defines them and runs nothing
# (image/tests/test_sleep_soak_helpers.sh).
set -u

# --- the pure helpers (off-device tested) -------------------------------------

# soak_median N...: the median of the numbers given (the arguments' words):
# the middle one, and for an even count the mean of the two middle ones,
# which is always a whole number or a half.
soak_median() {
	soak_sorted=$(printf '%s\n' "$@" | sort -n)
	soak_n=$(printf '%s\n' "$soak_sorted" | grep -c .)
	if [ "$soak_n" -eq 0 ]; then
		printf '0\n'
		return 0
	fi
	if [ $((soak_n % 2)) -eq 1 ]; then
		printf '%s\n' "$soak_sorted" | sed -n "$(( (soak_n + 1) / 2 ))p"
		return 0
	fi
	soak_a=$(printf '%s\n' "$soak_sorted" | sed -n "$(( soak_n / 2 ))p")
	soak_b=$(printf '%s\n' "$soak_sorted" | sed -n "$(( (soak_n / 2) + 1 ))p")
	soak_s=$((soak_a + soak_b))
	if [ $((soak_s % 2)) -eq 0 ]; then
		printf '%s\n' "$((soak_s / 2))"
	else
		printf '%s.5\n' "$((soak_s / 2))"
	fi
}

# soak_hex_words TEXT: the hex words of TEXT (0x-prefixed or bare), in their
# order, space separated on one line -- the only kernel-line values this
# test ever logs.
soak_hex_words() {
	printf '%s\n' "$1" | tr ' ' '\n' | tr -d ',' |
		LC_ALL=C sed -n '/^\(0x\)\{0,1\}[0-9a-fA-F][0-9a-fA-F]*$/p' |
		tr '\n' ' ' | sed 's/ $//'
}

# soak_wake_words LINE: the hex words that follow WAKEUP_STAT on a wake
# line, EINT_PEND's own word included: the stat's word first, then the
# EINT_PEND words.
soak_wake_words() {
	soak_hex_words "$(printf '%s\n' "$1" | LC_ALL=C sed -n 's/^.*WAKEUP_STAT//p')"
}

# soak_wake_stat LINE: the WAKEUP_STAT word of a wake line.
soak_wake_stat() { soak_wake_words "$1" | cut -d' ' -f1; }

# soak_wake_eint LINE: the EINT_PEND words of a wake line: everything past
# the stat's word, and nothing when the line has only that one.
soak_wake_eint() { soak_wake_words "$1" | sed 's/^[^ ]* \{0,1\}//'; }

# soak_json_word JSON KEY: the value of the quoted key KEY when it is a
# word of lowercase letters, bare or quoted in the JSON
# (t715-modem-power's "cp", as modem-switch.sh reads it); nothing otherwise.
soak_json_word() {
	printf '%s\n' "$1" | sed -n "s/.*\"$2\":[ ]*\"\{0,1\}\([a-z][a-z]*\).*/\1/p"
}

# soak_sleep_kind TEXT: what the kernel log since the mark says happened:
# "real" (the SMC_CMD_SLEEP line), "dry run" or "no suspend".  The dry run
# line holds the word SMC_CMD_SLEEP too, so it is looked for first.
soak_sleep_kind() {
	case $1 in
	*"dry run, no SMC_CMD_SLEEP"*) printf 'dry run\n' ;;
	*SMC_CMD_SLEEP*) printf 'real\n' ;;
	*) printf 'no suspend\n' ;;
	esac
}

# soak_klog_mark TEXT: the kernel timestamp of the last line of TEXT that
# starts with one.
soak_klog_mark() {
	printf '%s\n' "$1" | LC_ALL=C sed -n 's/^\[ *\([0-9][0-9]*\.[0-9][0-9]*\)\].*/\1/p' |
		tail -n 1
}

# soak_klog_since TEXT MARK: the lines of TEXT after the last line stamped
# MARK.  When no line is stamped MARK it has left the ring buffer, and every
# line still in TEXT was logged after it -- t715-wifi-guard judges the same
# way.  An empty MARK gives all of TEXT.
soak_klog_since() {
	soak_pat="^\[ *$(printf '%s\n' "$2" | sed 's/[.]/\\./g')]"
	soak_ln=$(printf '%s\n' "$1" | LC_ALL=C grep -n "$soak_pat" | tail -n 1 | cut -d: -f1)
	if [ -n "$soak_ln" ]; then
		printf '%s\n' "$1" | LC_ALL=C sed -n "$((soak_ln + 1)),\$p"
	else
		printf '%s\n' "$1"
	fi
}

# soak_count TEXT WORD: how many lines of TEXT hold WORD, a fixed string,
# case-sensitive ("BUG:" must not match a lower-case bug).
soak_count() {
	printf '%s\n' "$1" | grep -cF -- "$2" || true
}

# soak_bad_digest TEXT: the kernel error counts of TEXT, counts only, one
# line: name=N for each of the eight watched words.
soak_bad_digest() {
	soak_t=$1
	printf 'bug=%s warn=%s oops=%s trace=%s timeout=%s probe=%s halt=%s mmio=%s\n' \
		"$(soak_count "$soak_t" 'BUG:')" \
		"$(soak_count "$soak_t" 'WARNING:')" \
		"$(soak_count "$soak_t" 'Oops')" \
		"$(soak_count "$soak_t" 'Call trace')" \
		"$(soak_count "$soak_t" 'timed out')" \
		"$(soak_count "$soak_t" 'brcmf_pcie_probe: failed')" \
		"$(soak_count "$soak_t" 'Firmware has halted')" \
		"$(soak_count "$soak_t" 'MMIO read failed')"
}

# soak_digest_total DIGEST: the sum of a digest's counts.
soak_digest_total() {
	soak_sum=0
	# shellcheck disable=SC2086
	for soak_f in $1; do
		soak_v=${soak_f#*=}
		case $soak_v in '' | *[!0-9]*) continue ;; esac
		soak_sum=$((soak_sum + soak_v))
	done
	printf '%s\n' "$soak_sum"
}

# --- the device ----------------------------------------------------------------

# log TEXT: one line into LOG, on stdout (the journal, under systemd-run)
# and into the kernel log at error level, so a crash leaves it in pstore.
# The kmsg write sits in its own subshell: a refused write (a kernel without
# /dev/kmsg open to us) says nothing, the record still reaches LOG.
log() {
	( printf '<3>t715-sleep-soak: %s\n' "$*" > /dev/kmsg ) 2>/dev/null || true
	printf '%s %s\n' "$(date +%T)" "$*" >> "$LOG" 2>/dev/null || true
	printf '%s %s\n' "$(date +%T)" "$*"
}

# refuse TEXT: one line and exit 1.
refuse() {
	log "refused: $*"
	exit 1
}

# battery: the supply of type Battery, its percent and its millivolts in
# b_cap and b_mv (- when it cannot be read).
battery() {
	b_cap=-
	b_mv=-
	for b in /sys/class/power_supply/*; do
		[ -r "$b/type" ] || continue
		[ "$(cat "$b/type")" = Battery ] || continue
		if [ -r "$b/capacity" ]; then
			b_cap=$(cat "$b/capacity")
		fi
		if [ -r "$b/voltage_now" ]; then
			b_uv=$(cat "$b/voltage_now")
			case $b_uv in
			'' | *[!0-9-]*) ;;
			*) b_mv=$((b_uv / 1000)) ;;
			esac
		fi
		return
	done
}

# ext_power: any supply that is not the battery and is online (the cable).
ext_power() {
	for p in /sys/class/power_supply/*; do
		[ -r "$p/type" ] || continue
		[ "$(cat "$p/type")" = Battery ] && continue
		[ -r "$p/online" ] || continue
		if [ "$(cat "$p/online")" = 1 ]; then
			return 0
		fi
	done
	return 1
}

# cp_state: the CP's state word, or nothing when it cannot be read.
cp_state() {
	soak_json_word "$(t715-modem-power status --json 2>/dev/null)" cp
}

# restore_active: the sleep hook's restore service still working.  A
# oneshot reads "activating" while its ExecStart runs, never "active".
restore_active() {
	case $(systemctl is-active t715-sleep-restore.service 2>/dev/null) in
	active | activating | reloading) return 0 ;;
	esac
	return 1
}

# ready_wait [FROM_EPOCH]: wait for the radios to be back after a wake: the
# restore service idle, the Wi-Fi up by the guard's own judgment, and the CP
# settled (online, offline, off or crashed -- not booting, waiting or
# stopping).  Polls every 2 s, up to READY_MAX.  Sets rw_wifi and rw_cp to
# the seconds from FROM_EPOCH (default: the wait's start) to the Wi-Fi being
# up and to the CP settled (empty when they never were), and rw_why when the
# time ran out.  0 ready, 1 not.  FROM_EPOCH before the wait measures from
# the wake itself: the guard may already have the Wi-Fi up when the wait
# begins, and its answer is the seconds since the wake.
ready_wait() {
	rw_from=$1
	rw_wifi=''
	rw_cp=''
	rw_why=''
	rw_state=''
	rw_waited=0
	while :; do
		rw_now=$(date +%s)
		if [ -z "$rw_wifi" ] && "$GUARD" check > /dev/null 2>&1; then
			rw_wifi=$((rw_now - rw_from))
		fi
		rw_state=$(cp_state)
		if [ -z "$rw_cp" ]; then
			case $rw_state in
			online | offline | off | crashed)
				rw_cp=$((rw_now - rw_from)) ;;
			esac
		fi
		if [ -n "$rw_wifi" ] && [ -n "$rw_cp" ] && ! restore_active; then
			return 0
		fi
		if [ "$rw_waited" -ge "$READY_MAX" ]; then
			break
		fi
		sleep 2
		rw_waited=$((rw_waited + 2))
	done
	rw_why="not ready within $READY_MAX s"
	if [ -z "$rw_wifi" ]; then
		rw_why="$rw_why: the Wi-Fi not up"
	fi
	if [ -z "$rw_cp" ]; then
		rw_why="$rw_why: the CP ${rw_state:-unknown}"
	fi
	if restore_active; then
		rw_why="$rw_why: the restore service still active"
	fi
	return 1
}

# after_line CYCLE CURSOR KIND: the line about CYCLE's wake, written once
# the NEXT ready wait has measured the radios' return (rw_wifi and rw_cp).
# The journal since the cursor says the guard's failed recovery tries and
# what the restore said -- counts and fixed words only, never a journal
# line.  Sums the soak's tallies; a cycle that did not suspend never adds
# its Wi-Fi time to the wake statistics, there was no wake.
after_line() {
	af_text=$(journalctl -b -o cat -t t715-wifi-guard -t t715-sleep \
		--after-cursor "$2" 2>/dev/null || true)
	af_fail=$(printf '%s\n' "$af_text" | grep -c 'recovery try .*failed' || true)
	case ${af_fail:-0} in '' | *[!0-9]*) af_fail=0 ;; esac
	af_verdict='no restore line'
	case $af_text in
	*'restore: the Wi-Fi did not come back'*)
		af_verdict='the Wi-Fi did not come back' ;;
	*'restore: the Wi-Fi came back'*)
		af_verdict='the Wi-Fi came back' ;;
	esac
	af_tries=$(printf '%s\n' "$af_text" |
		sed -n 's/.*recovery try \([0-9][0-9]*\) of.*/\1/p' | sort -n | tail -n 1)
	case ${af_tries:-0} in '' | *[!0-9]*) af_tries=0 ;; esac
	af_w="not within $READY_MAX s"
	if [ -n "$rw_wifi" ]; then
		af_w="${rw_wifi} s"
	fi
	af_c="not within $READY_MAX s"
	if [ -n "$rw_cp" ]; then
		af_c="${rw_cp} s"
	fi
	af_word=tries
	if [ "$af_fail" = 1 ]; then
		af_word=try
	fi
	log "cycle $1 after: the Wi-Fi up in $af_w, the CP settled in $af_c, $af_fail failed recovery $af_word, restore: $af_verdict"
	FAIL_TRIES=$((FAIL_TRIES + af_fail))
	if [ "$af_tries" -gt 1 ]; then
		MULTI_TRY=$((MULTI_TRY + 1))
	fi
	if [ "$3" != 'no suspend' ] && [ -n "$rw_wifi" ]; then
		WIFI_TIMES="$WIFI_TIMES${rw_wifi} "
	fi
}

# --- the soak -------------------------------------------------------------------

soak_main() {
	N=${1:-20}
	SECS=${2:-60}
	READY_MAX=${READY_MAX:-240}
	WAIT_POWER=${WAIT_POWER:-600}
	LOG=${LOG:-/var/log/t715-sleep-soak/soak-$(date +%Y%m%d-%H%M%S).log}
	GUARD=${GUARD:-/usr/local/sbin/t715-wifi-guard}
	case $N in '' | *[!0-9]*)
		printf 'usage: sh sleep-soak.sh [N [SECS]], N and SECS are numbers\n'
		exit 1 ;;
	esac
	case $SECS in '' | *[!0-9]*)
		printf 'usage: sh sleep-soak.sh [N [SECS]], N and SECS are numbers\n'
		exit 1 ;;
	esac

	# the refusals, one line each
	ARM=/sys/module/exynos5433_sleep/parameters/arm
	[ -e "$ARM" ] || refuse "no arm switch: the kernel has no system sleep"
	grep -q '\[deep\]' /sys/power/mem_sleep 2>/dev/null ||
		refuse "no deep system sleep in /sys/power/mem_sleep"
	[ "$(id -u)" = 0 ] || refuse "not root"
	RTC=
	for r in /sys/class/rtc/rtc*; do
		grep -qiE 's2mps|s5m' "$r/name" 2>/dev/null && RTC=${r##*/}
	done
	[ -n "$RTC" ] || refuse "no PMIC RTC"
	mkdir -p "$(dirname "$LOG")" || refuse "cannot create $(dirname "$LOG")"

	# the start: the settings, the battery, the policy service out of the way
	log "soak: N=$N SECS=$SECS, READY_MAX=$READY_MAX, WAIT_POWER=$WAIT_POWER, RTC $RTC"
	battery
	cap0=$b_cap
	mv0=$b_mv
	if systemctl -q is-active t715-sleep.service 2>/dev/null; then
		POLICY=1
	else
		POLICY=0
	fi
	pol=inactive
	if [ "$POLICY" = 1 ]; then
		pol=active
	fi
	log "start: battery $b_cap %, $b_mv mV; t715-sleep.service $pol"
	# the trap first, so a TERM between the stop and the end still restores it
	# (the EXIT trap runs finish, which shellcheck cannot see)
	# shellcheck disable=SC2329
	finish() {
		if [ -n "$RTC" ]; then
			echo 0 > "/sys/class/rtc/$RTC/wakealarm" 2>/dev/null || true
		fi
		if [ "$POLICY" = 1 ]; then
			systemctl start t715-sleep.service || true
			log "t715-sleep.service started again"
		fi
	}
	trap finish EXIT
	trap 'exit 1' TERM INT HUP
	if [ "$POLICY" = 1 ]; then
		systemctl stop t715-sleep.service || refuse "cannot stop t715-sleep.service"
		log "t715-sleep.service stopped for the soak"
	fi

	# a real sleep happens only on battery: wait for the cable to be pulled
	if ext_power; then
		log "waiting for the cable to be pulled"
		pw=0
		while ext_power; do
			if [ "$pw" -ge "$WAIT_POWER" ]; then
				log "external power still on after $WAIT_POWER s: a soak on external power would be dry runs only"
				exit 1
			fi
			sleep 5
			pw=$((pw + 5))
		done
	fi
	log "on battery: the soak begins"

	cycles=0
	n_real=0
	n_dry=0
	n_none=0
	n_readyfail=0
	consec=0
	aborted=0
	FAIL_TRIES=0
	MULTI_TRY=0
	ERR_TOTAL=0
	WIFI_TIMES=''
	pending=0    # the cycle whose after-line the next ready wait owes
	pend_cursor=''

	i=1
	wake_t=$(date +%s)    # the wake whose radios the NEXT ready wait measures
	while [ "$i" -le "$N" ]; do
		cycles=$((cycles + 1))
		if ready_wait "$wake_t"; then
			rw_ok=0
		else
			rw_ok=1
		fi
		if [ "$pending" -gt 0 ]; then
			after_line "$pending" "$pend_cursor" "$pend_kind"
			pending=0
		elif [ "$i" = 1 ]; then
			# cycle 1 starts awake: its wait is the start, not a wake's
			st_w="not within $READY_MAX s"
			if [ -n "$rw_wifi" ]; then
				st_w="${rw_wifi} s"
			fi
			st_c="not within $READY_MAX s"
			if [ -n "$rw_cp" ]; then
				st_c="${rw_cp} s"
			fi
			log "start: the Wi-Fi up after $st_w, the CP settled after $st_c"
		fi
		if [ "$rw_ok" != 0 ]; then
			n_readyfail=$((n_readyfail + 1))
			consec=$((consec + 1))
			log "cycle $i: $rw_why"
			if [ "$consec" -ge 3 ]; then
				log "stopping: 3 cycles in a row not ready"
				aborted=1
				break
			fi
			i=$((i + 1))
			continue
		fi
		consec=0

		# the marks: the kernel log, the statistics, the hook's resumed file,
		# the wall clock and the journal cursor
		kmark=$(soak_klog_mark "$(dmesg 2>/dev/null)")
		if [ -z "$kmark" ]; then
			# without a mark the whole log would read as this cycle's: the
			# previous cycles' sleep lines would pass for this one's
			log "cycle $i: no kernel-log mark: the cycle cannot be judged"
			i=$((i + 1))
			continue
		fi
		s0=$(cat /sys/power/suspend_stats/success 2>/dev/null || printf '0')
		f0=$(cat /sys/power/suspend_stats/fail 2>/dev/null || printf '0')
		case $s0 in '' | *[!0-9]*) s0=0 ;; esac
		case $f0 in '' | *[!0-9]*) f0=0 ;; esac
		resumed0=$(cat /run/t715-sleep/resumed 2>/dev/null || printf '')
		mark_t=$(date +%s)
		cursor=$(journalctl -n 0 --show-cursor 2>/dev/null | sed -n 's/^-- cursor: //p')
		if [ -z "$cursor" ]; then
			log "cycle $i: no journal cursor: this cycle's recovery lines cannot be read"
		fi

		# the alarm: cleared, then SECS away
		alarm_ok=0
		echo 0 > "/sys/class/rtc/$RTC/wakealarm" 2>/dev/null || alarm_ok=1
		echo "+$SECS" > "/sys/class/rtc/$RTC/wakealarm" 2>/dev/null || alarm_ok=1

		# the suspend, then the wake: the hook's resumed file changes, or the
		# suspend statistics grow
		woke=0
		sc_rc=0
		if [ "$alarm_ok" = 0 ]; then
			log "cycle $i: the alarm set for +$SECS s, suspending"
			systemctl suspend || sc_rc=$?
			ww=0
			while [ "$ww" -le "$((SECS + 180))" ]; do
				r_now=$(cat /run/t715-sleep/resumed 2>/dev/null || printf '')
				if [ "$r_now" != "$resumed0" ]; then
					woke=1
					break
				fi
				s1=$(cat /sys/power/suspend_stats/success 2>/dev/null || printf '%s' "$s0")
				f1=$(cat /sys/power/suspend_stats/fail 2>/dev/null || printf '%s' "$f0")
				case $s1 in '' | *[!0-9]*) s1=$s0 ;; esac
				case $f1 in '' | *[!0-9]*) f1=$f0 ;; esac
				if [ "$s1" != "$s0" ] || [ "$f1" != "$f0" ]; then
					woke=1
					break
				fi
				sleep 1
				ww=$((ww + 1))
			done
		else
			log "cycle $i: the RTC alarm cannot be set: not suspending"
		fi
		wake_t=$(date +%s)

		# the record, from the kernel log since the mark; our own lines in
		# it never count as errors
		ktext=$(dmesg 2>/dev/null)
		since=$(soak_klog_since "$ktext" "$kmark" |
			grep -v 't715-sleep-soak:' || true)
		kind=$(soak_sleep_kind "$since")
		if [ "$kind" = real ]; then
			n_real=$((n_real + 1))
		elif [ "$kind" = 'dry run' ]; then
			n_dry=$((n_dry + 1))
		else
			kind='no suspend'
			n_none=$((n_none + 1))
		fi
		wline=$(printf '%s\n' "$since" | grep 'woke up:' | head -n 1)
		ws=$(soak_wake_stat "$wline")
		if [ -z "$ws" ]; then
			ws='-'
		fi
		ep=$(soak_wake_eint "$wline")
		if [ -z "$ep" ]; then
			ep='-'
		fi
		if [ "$woke" = 1 ]; then
			dur="asleep $((wake_t - mark_t)) s"
		elif [ "$alarm_ok" = 0 ]; then
			dur="no wake within $((SECS + 180)) s"
		else
			dur="not suspended: the alarm could not be set"
		fi
		s1=$(cat /sys/power/suspend_stats/success 2>/dev/null || printf '%s' "$s0")
		f1=$(cat /sys/power/suspend_stats/fail 2>/dev/null || printf '%s' "$f0")
		case $s1 in '' | *[!0-9]*) s1=$s0 ;; esac
		case $f1 in '' | *[!0-9]*) f1=$f0 ;; esac
		sc_note=''
		if [ "$sc_rc" != 0 ]; then
			sc_note=", systemctl exit $sc_rc"
		fi
		battery
		digest=$(soak_bad_digest "$since")
		ERR_TOTAL=$((ERR_TOTAL + $(soak_digest_total "$digest")))
		log "cycle $i: $kind, $dur, WAKEUP_STAT $ws, EINT_PEND $ep, suspend_stats success +$((s1 - s0)) fail +$((f1 - f0)), battery $b_cap % $b_mv mV, kernel errors $digest$sc_note"

		pending=$i
		pend_cursor=$cursor
		pend_kind=$kind
		i=$((i + 1))
	done

	# the last cycle's wake measured too: one more ready wait, no suspend
	# after it
	if [ "$pending" -gt 0 ]; then
		if ready_wait "$wake_t"; then
			rw_ok=0
		else
			rw_ok=1
		fi
		after_line "$pending" "$pend_cursor" "$pend_kind"
		pending=0
		if [ "$rw_ok" != 0 ]; then
			n_readyfail=$((n_readyfail + 1))
			log "after the last cycle: $rw_why"
		fi
	fi

	# the summary
	log "summary: $cycles cycles, $n_real real sleeps, $n_dry dry runs, $n_none suspends that did not happen, $n_readyfail ready-wait failures"
	if [ -n "$WIFI_TIMES" ]; then
		# shellcheck disable=SC2086
		t_min=$(printf '%s\n' $WIFI_TIMES | sort -n | head -n 1)
		# shellcheck disable=SC2086
		t_max=$(printf '%s\n' $WIFI_TIMES | sort -n | tail -n 1)
		# shellcheck disable=SC2086
		t_med=$(soak_median $WIFI_TIMES)
		# shellcheck disable=SC2086
		t_n=$(printf '%s\n' $WIFI_TIMES | grep -c .)
		log "summary: the Wi-Fi back after the wake: min $t_min s, median $t_med s, max $t_max s ($t_n wakes)"
	else
		log "summary: the Wi-Fi back after the wake: no wake to measure"
	fi
	log "summary: the Wi-Fi guard's recovery: $FAIL_TRIES failed tries in all, $MULTI_TRY cycles needed more than one try"
	log "summary: kernel errors summed: $ERR_TOTAL"
	battery
	log "summary: battery $cap0 % $mv0 mV at the start, $b_cap % $b_mv mV at the end"
	exit "$aborted"
}

if [ -z "${SOAK_LIB_ONLY:-}" ]; then
	soak_main "$@"
fi
