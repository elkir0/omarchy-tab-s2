#!/bin/sh
# soak-sample.sh — read-only samples of a candidate kernel's soak, run as root
# ON THE TABLET as a transient unit (docs/hardware/BATTERY.md section 10):
#
#   scp image/tests/ondevice/soak-sample.sh root@172.16.42.1:/run/
#   ssh root@172.16.42.1 systemd-run --unit=t715-soak --collect \
#       -E SECS=7200 -E OUT=/var/tmp/t715-soak.log /run/soak-sample.sh
#
# Every DT seconds (default 30) for SECS seconds: the online CPUs, the A53
# clock, the G3D domain and its power-off count, the GPU's runtime state,
# the zones' temperatures, the battery, the CP's state, the screen, the
# Wi-Fi's state and one ping of the gateway through it (ms, or "lost"), the
# failed units, and the kernel lines since the start that look wrong
# (user-space lines forwarded to the kernel log are skipped, and so is the
# kernel command line, which holds the serial number).  Writes nothing but
# OUT, and never a kernel line itself, only their count.
set -u
DT=${DT:-30}
SECS=${SECS:-7200}
OUT=${OUT:-/var/tmp/t715-soak-$(date +%Y%m%d-%H%M%S).log}
G3D=/sys/kernel/debug/pm_genpd/G3D
FG=/sys/class/power_supply/sm5703-fuelgauge
BAD='unable to kill|still powered|spurious|did not leave|timed out|BUG:|WARNING:|Oops|Unhandled|panfrost.*(fault|timeout|reset)|flip_done|call trace|hung task|soft lockup'

mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
read -r t0 _ < /proc/uptime
echo "# start $(date -Is) uptime $t0 kernel $(uname -v)" >> "$OUT"

kbad() {
	dmesg | awk -v t="$t0" '{s=$0; sub(/^\[ */,"",s); split(s,a,"]"); if (a[1]+0 > t+0) print}' |
		grep -vE '^\[ *[0-9.]+\] [^ :]+\[[0-9]+\]: |Kernel command line|ramoops' | grep -ciE "$BAD"
}

GW=$(ip -4 route show default dev wlp1s0 2>/dev/null | awk '{print $3; exit}')

end=$(( ${t0%.*} + SECS ))
while :; do
	read -r up _ < /proc/uptime
	read -r cpus < /sys/devices/system/cpu/online
	read -r f0 < /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq
	g=-; [ -r $G3D/current_state ] && read -r g < $G3D/current_state
	gu=$(tail -1 $G3D/idle_states 2>/dev/null | awk '{print $3}')
	read -r gpu < /sys/bus/platform/devices/14ac0000.gpu/power/runtime_status
	tz=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | awk '{printf "%d,", $1 / 1000}')
	read -r cap < $FG/capacity; read -r ua < $FG/current_now
	cp=$(sed -n 's/.*state=\([a-z]*\).*/\1/p' /run/shannon/cp-state 2>/dev/null)
	dpms=$(cat /sys/class/drm/card*-DSI-1/dpms 2>/dev/null | head -1)
	failed=$(systemctl --failed --no-legend 2>/dev/null | wc -l)
	wifi=$(nmcli -t -f DEVICE,STATE dev 2>/dev/null | sed -n 's/^wlp1s0://p')
	rtt=-; [ -n "$GW" ] && { rtt=$(LC_ALL=C ping -c1 -W2 -I wlp1s0 "$GW" 2>/dev/null | sed -n 's/.*time=\([0-9.]*\).*/\1/p'); [ -n "$rtt" ] || rtt=lost; }
	echo "$up cpus=$cpus f0=$f0 g3d=$g g3doffs=$gu gpu=$gpu tz=$tz cap=$cap ma=$((ua / 1000)) cp=${cp:--} dpms=$dpms wifi=${wifi:--} gw=$rtt failed=$failed kbad=$(kbad)" >> "$OUT"
	[ "${up%.*}" -ge "$end" ] && break
	sleep "$DT"
done
echo "# end $(date -Is)" >> "$OUT"
