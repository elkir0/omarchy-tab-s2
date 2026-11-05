#!/bin/sh
# power-windows.sh — screen-off power windows on battery, run as root ON THE
# TABLET as a transient unit, because it cuts USB for its whole length
# (docs/hardware/BATTERY.md section 10):
#
#   scp image/tests/ondevice/power-windows.sh root@172.16.42.1:/run/
#   ssh root@172.16.42.1 systemd-run --unit=t715-powerwin --collect \
#       -E OUT=/var/tmp/t715-power.log /run/power-windows.sh \
#       settle:300:aspm_on A1:420:aspm_on B1:420:aspm_off ...
#
# Each phase is label:seconds:action[+action...]; actions: aspm_on (L1 and its
# substates, no L0s), aspm_l1, aspm_off, a57_off, a57_on, gpu_off (panfrost
# rt_clk_off=1, the G3D domain off while idle), gpu_on, a53_cap (the A53
# policy held at its lowest level), a53_free, a53_off (cpu1-3 offline, on a
# kernel that allows it), a53_on, wifi_off (NetworkManager's radio), wifi_on,
# and on a brcmfmac with ps_mode/ps_timeout/bcn_li_dtim: wps_fast2000 (PM_FAST,
# pm2_sleep_ret 2 s: the stock driver), wps_fast100 (PM_FAST, 100 ms),
# wps_max3 (PM_MAX, every third DTIM); modem_off (shannond and shannon-loader
# stopped: the loader powers the CP off), modem_on (shannon-modem-prepare
# started: the CP boots again), wwan_off and wwan_on (NetworkManager's WWAN
# radio: the CP's radio off or on, as airplane mode does); none.  Cuts USB by
# the MUIC (20-0025: MANSW1 0x13 = 0x00, CONTROL 0x02 = 0x1a), samples the
# gauge every DT seconds (default 5) with
# shell builtins only, then always puts USB back (0x02 = 0x1e, 0x13 = 0x27)
# and the online CPUs, the A53 limit, the Wi-Fi radio and its power save
# settings, and the modem as it found them.
# NOUSB=1 keeps USB.  Never reads the MUIC INT registers (0x03-0x04).
# Analyse with image/tests/power-stats.py.
set -u
DT=${DT:-5}
OUT=${OUT:-/var/tmp/t715-power-$(date +%Y%m%d-%H%M%S).log}
NOUSB=${NOUSB:-0}
FG=/sys/class/power_supply/sm5703-fuelgauge
PCI=/sys/bus/pci/devices/0000:01:00.0
POL=/sys/module/pcie_aspm/parameters/policy
GPU=/sys/bus/platform/devices/14ac0000.gpu
CPU=/sys/devices/system/cpu
POL0=$CPU/cpufreq/policy0
G3D=/sys/kernel/debug/pm_genpd/G3D/current_state
CPUS0=""; for n in 1 2 3 4 5 6 7; do [ -r $CPU/cpu$n/online ] && CPUS0="$CPUS0 $n:$(cat $CPU/cpu$n/online)"; done
read -r LIMIT0 < $POL0/scaling_max_freq
WIFI0=$(nmcli radio wifi 2>/dev/null)
WWAN0=$(nmcli radio wwan 2>/dev/null)
MODEM0=$(systemctl is-active shannon-loader.service)
BRCMF=/sys/module/brcmfmac/parameters
PS0=""; [ -r $BRCMF/ps_mode ] && PS0="$(cat $BRCMF/ps_mode) $(cat $BRCMF/ps_timeout) $(cat $BRCMF/bcn_li_dtim)"

wps() { # power save mode, pm2_sleep_ret, bcn_li_dtim; applied by power save off and on
	[ -w $BRCMF/ps_mode ] || return
	echo "$1" > $BRCMF/ps_mode; echo "$2" > $BRCMF/ps_timeout; echo "$3" > $BRCMF/bcn_li_dtim
	iw dev wlp1s0 set power_save off; iw dev wlp1s0 set power_save on
}

usb_off() { [ "$NOUSB" = 1 ] && return; i2cset -f -y 20 0x25 0x13 0x00; i2cset -f -y 20 0x25 0x02 0x1a; }
usb_on()  { [ "$NOUSB" = 1 ] && return; i2cset -f -y 20 0x25 0x02 0x1e; i2cset -f -y 20 0x25 0x13 0x27; }

gpu_cycle() { # apply rt_clk_off now: resume, then let it autosuspend
	echo on > $GPU/power/control; sleep 1; echo auto > $GPU/power/control
}

act() {
	case "$1" in
	aspm_on)  echo powersupersave > $POL; echo 0 > $PCI/link/l0s_aspm ;;
	aspm_l1)  echo 0 > $PCI/link/l0s_aspm; echo powersave > $POL ;;
	aspm_off) echo performance > $POL ;;
	a57_off)  for c in 7 6 5 4; do echo 0 > $CPU/cpu$c/online; done ;;
	a57_on)   for c in 4 5 6 7; do echo 1 > $CPU/cpu$c/online; done ;;
	gpu_off)  echo 1 > /sys/module/panfrost/parameters/rt_clk_off; gpu_cycle ;;
	gpu_on)   echo 0 > /sys/module/panfrost/parameters/rt_clk_off; gpu_cycle ;;
	a53_cap)  cat $POL0/cpuinfo_min_freq > $POL0/scaling_max_freq ;;
	a53_free) cat $POL0/cpuinfo_max_freq > $POL0/scaling_max_freq ;;
	a53_off)  for c in 3 2 1; do echo 0 > $CPU/cpu$c/online; done ;;
	a53_on)   for c in 1 2 3; do echo 1 > $CPU/cpu$c/online; done ;;
	wifi_off) nmcli radio wifi off ;;
	wifi_on)  nmcli radio wifi on ;;
	wps_fast2000) wps 2 -1 0 ;;
	wps_fast100)  wps 2 100 0 ;;
	wps_max3)     wps 1 -1 3 ;;
	modem_off) systemctl stop shannond.service shannon-loader.service ;;
	modem_on)  systemctl start shannon-modem-prepare.service ;;
	wwan_off)  nmcli radio wwan off ;;
	wwan_on)   nmcli radio wwan on ;;
	none) ;;
	*) echo "# unknown action $1" >> "$OUT" ;;
	esac
}

sample() {
	read -r up _ < /proc/uptime
	read -r ua < $FG/current_now; read -r uv < $FG/voltage_now
	read -r cap < $FG/capacity; read -r bt < $FG/temp
	read -r t0 < /sys/class/thermal/thermal_zone0/temp
	read -r t1 < /sys/class/thermal/thermal_zone1/temp
	read -r on < $CPU/online
	g3d=-; [ -r $G3D ] && read -r g3d < $G3D
	cp=-; [ -r /run/shannon/cp-state ] && { read -r _ cp < /run/shannon/cp-state; cp=${cp#state=}; }
	{ read -r _ u n s i _; while read -r k v _; do [ "$k" = intr ] && break; done; } < /proc/stat
	echo "$up ph=$PH ma=$((ua / 1000)) mv=$((uv / 1000)) cap=$cap t=$bt tz=$t0,$t1 user=$u sys=$s idle=$i intr=$v cpus=$on g3d=$g3d cp=$cp" >> "$OUT"
}

finish() {
	usb_on
	for e in $CPUS0; do echo "${e#*:}" > $CPU/cpu${e%:*}/online 2>/dev/null; done
	echo "$LIMIT0" > $POL0/scaling_max_freq
	[ "$WIFI0" = enabled ] && act wifi_on
	[ "$WWAN0" = enabled ] && act wwan_on
	[ "$MODEM0" = active ] && [ "$(systemctl is-active shannon-loader.service)" != active ] && act modem_on
	[ -n "$PS0" ] && wps $PS0
	echo "# end $(cut -d' ' -f1 /proc/uptime)" >> "$OUT"
}
trap finish EXIT
trap 'exit 1' TERM INT HUP

echo "# start $(date -Is) phases: $*" >> "$OUT"
PH=usb; sample
usb_off
for spec in "$@"; do
	PH=${spec%%:*}; rest=${spec#*:}; secs=${rest%%:*}; actions=${rest#*:}
	IFS=+; for a in $actions; do IFS=' '; act "$a"; done; IFS=' '
	read -r now _ < /proc/uptime
	echo "# phase $PH $secs s $actions at $now" >> "$OUT"
	end=$(( ${now%.*} + secs ))
	while :; do
		sample
		read -r now _ < /proc/uptime
		[ "${now%.*}" -ge "$end" ] && break
		sleep "$DT"
	done
done
