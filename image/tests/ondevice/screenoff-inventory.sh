#!/bin/sh
# screenoff-inventory.sh — what is awake while the screen is off, on battery,
# run as root ON THE TABLET as a transient unit, because it cuts USB
# (docs/hardware/BATTERY.md section 11):
#
#   scp image/tests/ondevice/screenoff-inventory.sh root@172.16.42.1:/run/
#   ssh root@172.16.42.1 systemd-run --unit=t715-inv --collect \
#       -E OUT=/var/tmp/t715-inv /run/screenoff-inventory.sh
#
# Refuses to run with the screen on.  Cuts USB by the MUIC like
# power-windows.sh (20-0025: MANSW1 0x13 and CONTROL 0x02 only, never the INT
# registers), lets the charger and the gadget settle for SETTLE seconds, then
# takes two snapshots SECS seconds apart: /proc/interrupts, /proc/softirqs,
# /proc/stat, every process's CPU time, the A53 policy's cpufreq statistics,
# the wakeup sources, and the gauge every 5 s in between.  At the end, the
# power domains, the enabled clocks, the regulators and the runtime-active
# devices.  USB always goes back.  Writes nothing but OUT, never a kernel line.
set -u
OUT=${OUT:-/var/tmp/t715-inv}
SETTLE=${SETTLE:-90}
SECS=${SECS:-120}
FG=/sys/class/power_supply/sm5703-fuelgauge
POL=/sys/devices/system/cpu/cpufreq/policy0
D=/sys/kernel/debug

[ "$(cat /sys/class/drm/card*-DSI-1/dpms | head -1)" = Off ] || { echo "screen on, not running"; exit 1; }
mountpoint -q $D || mount -t debugfs none $D
rm -rf "$OUT"; mkdir -p "$OUT"

usb_off() { i2cset -f -y 20 0x25 0x13 0x00; i2cset -f -y 20 0x25 0x02 0x1a; }
usb_on()  { i2cset -f -y 20 0x25 0x02 0x1e; i2cset -f -y 20 0x25 0x13 0x27; }
trap usb_on EXIT
trap 'exit 1' TERM INT HUP

snap() { # $1: a or b
	cp /proc/interrupts "$OUT/interrupts.$1"
	cp /proc/softirqs "$OUT/softirqs.$1"
	cp /proc/stat "$OUT/stat.$1"
	cat $POL/stats/total_trans > "$OUT/trans.$1" 2>/dev/null
	cp $POL/stats/time_in_state "$OUT/tis.$1" 2>/dev/null
	cp $D/wakeup_sources "$OUT/wakeup.$1" 2>/dev/null
	for p in /proc/[0-9]*; do
		[ -r $p/stat ] || continue
		# pid (comm) state ppid ... utime(14) stime(15): pid, comm, utime, stime
		awk '{c=$0; sub(/^[0-9]+ \(/,"",c); sub(/\) .*/,"",c); gsub(/ /,"_",c);
			n=split($0, f, ") "); split(f[n], g, " "); print $1, c, g[12], g[13]}' $p/stat 2>/dev/null
	done > "$OUT/procs.$1"
	cut -d' ' -f1 /proc/uptime > "$OUT/uptime.$1"
}

echo "start $(date -Is) usb cut, settle $SETTLE s, window $SECS s" > "$OUT/info"
usb_off
sleep "$SETTLE"
snap a
end=$(( $(cut -d. -f1 /proc/uptime) + SECS ))
while [ "$(cut -d. -f1 /proc/uptime)" -lt "$end" ]; do
	read -r ua < $FG/current_now; read -r uv < $FG/voltage_now
	echo "$(cut -d' ' -f1 /proc/uptime) $((ua / 1000)) $((uv / 1000)) $(cat /sys/devices/system/cpu/online)" >> "$OUT/gauge"
	sleep 5
done
snap b
cp $D/pm_genpd/pm_genpd_summary "$OUT/genpd"
awk 'NR > 3 && $2 + 0 > 0' $D/clk/clk_summary > "$OUT/clk-enabled"
cp $D/regulator/regulator_summary "$OUT/regulators"
for f in /sys/devices/platform/*/power/runtime_status /sys/devices/platform/*/*/power/runtime_status; do
	[ "$(cat $f 2>/dev/null)" = active ] && echo "${f%/power/runtime_status}"
done > "$OUT/rpm-active"
{
	echo "wifi power_save: $(iw dev wlp1s0 get power_save 2>/dev/null)"
	echo "aspm: $(cat /sys/module/pcie_aspm/parameters/policy)"
	rfkill list 2>/dev/null | grep -A2 -i blue | tr '\n' ' '; echo
	echo "bt powered: $(busctl get-property org.bluez /org/bluez/hci0 org.bluez.Adapter1 Powered 2>/dev/null)"
	echo "cp: $(sed -n 's/.*state=\([a-z]*\).*/\1/p' /run/shannon/cp-state 2>/dev/null)"
	ls /sys/class/devfreq/ 2>/dev/null | tr '\n' ' '; echo
	for z in /sys/class/thermal/thermal_zone*; do echo "$(cat $z/type) $(cat $z/temp) $(cat $z/policy)"; done
} > "$OUT/misc"
echo "end $(date -Is)" >> "$OUT/info"
