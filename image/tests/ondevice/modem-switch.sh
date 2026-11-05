#!/bin/sh
# modem-switch.sh — the modem's switch on the tablet (t715-modem-power,
# docs/hardware/MODEM.md §5.4), run as root ON THE TABLET:
#
#   scp image/tests/ondevice/modem-switch.sh root@172.16.42.1:/run/
#   ssh root@172.16.42.1 sh /run/modem-switch.sh [USER]
#
# Every verb is started in USER's (default alarm) systemd user manager, as
# t715-keys and the shell's tile start it, so it goes through polkit
# (50-t715-modem-power.rules) the same way. Steps: off (CP off, the prepare
# unit disabled), on (CP ONLINE again), the standby set to off, dark (the
# timer), a minute later the cut (CP off, the mark), lit (CP ONLINE again),
# dark then lit within the minute (no cut), the standby kept again; then a
# verb from root's SSH session as USER, which polkit must refuse (not the
# active local session). Puts the switch and the setting back as it found
# them. Prints one "ok"/"FAIL" line per check and a summary; exit 1 on a
# failure. Logs only states, never what shannonctl knows of the SIM or line.
set -u
U=${1:-alarm}
STANDBY=/var/lib/t715-modem-power/standby
CUT=/run/t715-modem-power/cut
fails=0
t0=$(cut -d' ' -f1 /proc/uptime)

say() { printf '%s %s\n' "$(awk -v t0="$t0" '{printf "%6.1f", $1 - t0}' /proc/uptime)" "$*"; }
ok() { say "ok   $*"; }
bad() { say "FAIL $*"; fails=$((fails + 1)); }
check() { d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
field() { t715-modem-power status --json | sed -n "s/.*\"$1\":\"\{0,1\}\([a-z]*\).*/\1/p"; }
as_user() { systemd-run --user -M "$U@" --wait --collect --quiet t715-modem-power "$@"; }
# wait_cp STATE SECONDS: the CP's state reaches STATE
wait_cp() {
	n=0
	while [ "$(field cp)" != "$1" ]; do
		n=$((n + 1)); [ "$n" -le "$2" ] || return 1
		sleep 1
	done
}

modem0=$(field modem); standby0=$(cat "$STANDBY" 2>/dev/null || echo absent)
say "start: modem=$modem0 cp=$(field cp) standby=$standby0"
[ "$(field installed)" = true ] || { bad "t715-modem-power installed on a modem kernel"; exit 1; }

as_user off; check "off: the verb ends well through polkit" test $? -eq 0
check "off: the switch says off" test "$(field modem)" = off
check "off: shannon-modem-prepare disabled" test "$(systemctl is-enabled shannon-modem-prepare.service)" = disabled
check "off: the loader and shannond stopped" sh -c '! systemctl -q is-active shannon-loader.service shannond.service'
check "off: the loader's state file says offline" grep -q 'state=offline' /run/shannon/cp-state
check "off: the loader logged its MODEM_OFF" sh -c 'journalctl -u shannon-loader.service --since "-2 min" -o cat | grep -q "stop requested: closing holders, MODEM_OFF"'
sleep 5

as_user on; check "on: the verb ends well" test $? -eq 0
check "on: shannon-modem-prepare enabled" test "$(systemctl is-enabled shannon-modem-prepare.service)" = enabled
if wait_cp online 90; then ok "on: CP ONLINE again"; else bad "on: CP ONLINE within 90 s (cp=$(field cp))"; fi
check "on: shannond running" systemctl -q is-active shannond.service

as_user standby-off; check "standby-off: the setting written" test "$(cat "$STANDBY")" = off
as_user dark
check "dark: the standby timer armed" systemctl -q is-active t715-modem-standby.timer
say "waiting for the timer's minute"
if wait_cp off 90; then ok "cut: CP off a minute after dark"; else bad "cut: CP off within 90 s (cp=$(field cp))"; fi
check "cut: the mark is there" test -e "$CUT"
check "cut: the switch still says on" test "$(field modem)" = on
as_user lit
check "lit: the mark gone" test ! -e "$CUT"
check "lit: the timer stopped" sh -c '! systemctl -q is-active t715-modem-standby.timer'
if wait_cp online 90; then ok "lit: CP ONLINE again"; else bad "lit: CP ONLINE within 90 s (cp=$(field cp))"; fi

as_user dark; sleep 10; as_user lit; sleep 60
check "dark then lit within the minute: no cut" test "$(field cp)" = online
check "  and no mark" test ! -e "$CUT"
as_user standby-keep; check "standby-keep: the setting written" test "$(cat "$STANDBY")" = keep

runuser -u "$U" -- t715-modem-power off >/dev/null 2>&1
check "polkit: a verb from root's SSH session as $U is refused" test "$(field modem)" = on

# As found.
[ "$(field modem)" = "$modem0" ] || as_user "$modem0"
if [ "$standby0" = absent ]; then rm -f "$STANDBY"; else echo "$standby0" > "$STANDBY"; fi
say "end: modem=$(field modem) cp=$(field cp) standby=$(cat "$STANDBY" 2>/dev/null || echo absent)"
journalctl -u 't715-modem-power@*' -u t715-modem-standby.service --since "-15 min" -o cat -p warning | grep -v "Kernel command line" | sed 's/^/journal: /'
[ "$fails" -eq 0 ] && { echo "PASS"; exit 0; }
echo "FAIL: $fails"; exit 1
