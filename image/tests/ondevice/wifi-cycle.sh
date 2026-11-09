#!/bin/sh
# wifi-cycle.sh — how reliable the Wi-Fi's power cycle and fresh probe are, with no sleep at
# all.  Cycles of: the PCIe host unbound (WLAN_EN switchable: the chip off), WAITS[i]
# seconds awake, the host bound again, 12 s watched for a firmware halt, networks counted
# (a count only).  Stops at the first halt unless CONTINUE=1 (below): until the PHY's
# power-down (the t715-wifi-recovery series), a halted chip stayed broken until a reboot.
# Around each cycle: DIV_TOP_FSYS2 (CMU_TOP 0x634, div_sclk_pcie_100 in bits 14:12), the
# PMU's PCIE_PHY_CONTROL (0x105c0730), both read-only through /dev/mem, and the S2MPS13's
# RTCCTRL (32 kHz outputs).  Every line goes to the kernel log ("t715-wcycle:"), which pstore
# keeps, and to $LOG.  Root, on the sleep test kernel with brcmfmac's ring guard, the CP off,
# under systemd-run.  The hardware watchdog is fed by a helper until the end.
#
# ASPM=keep (the default): as things are, the udev rule's L0s off and powersupersave
# whenever the Wi-Fi's interface appears, a moment after every bind.  ASPM=off: the rule
# moved aside before the first cycle (put back at the end), performance written to
# /sys/module/pcie_aspm/parameters/policy before every bind, the policy found at the
# start restored at the end.  ASPM=late: the same before the bind, then ASPM_DELAY s
# (10 by default) after it the rule's own L0s off and powersupersave, and the 12 s watch
# starts again from there.  CONSOLE=0|1 (0): brcmfmac's pcie_console, the firmware's own
# console in the kernel log, on before the first cycle, off at the end.  A halt also logs
# the PCIe host's elbi registers, the ASPM policy and the Wi-Fi's kernel lines since the
# bind.  No address of any kind is logged, nor the kernel command line.
#
# CONTINUE=0|1 (0): with 1 a halt does not end the run: the host is unbound again
# (WLAN_EN off, in the background, given UNBIND_MAX s, 60 by default), and the next
# cycle powers the chip on afresh; the result line counts the halts and how many the
# next power cycle recovered.
#
# FULL=0|1 (0): with 1 every power cycle also takes Bluetooth down (hci_uart_bcm
# unbound: BT_REG_ON low), so the whole combo chip loses power, as on a reboot; the
# PCIe host is bound first, then Bluetooth 1 s later (BTORDER=after1, the default);
# BTORDER=before binds Bluetooth first and the host once an hci device is up;
# BTORDER=late binds Bluetooth once the Wi-Fi start has been judged.  The OK line counts
# the networks after that, and the result counts the OK starts that found none.  The
# watchdog feeder ignores TERM: a step timeout that signals the process group leaves it
# to the STOP file.
set -u
WAITS=${WAITS:-"1 5 15 30 60 120 1 5 15 30 60 120"}
LOG=${LOG:-/var/tmp/t715-wifi-cycle.log}
ASPM=${ASPM:-keep}
ASPM_DELAY=${ASPM_DELAY:-10}
CONSOLE=${CONSOLE:-0}
CONTINUE=${CONTINUE:-0}
UNBIND_MAX=${UNBIND_MAX:-60}
FULL=${FULL:-0}
BTORDER=${BTORDER:-after1}
BTDRV=/sys/bus/serial/drivers/hci_uart_bcm
BT=
HOST=15700000.pcie
DRV=/sys/bus/platform/drivers/exynos-pcie
STOP=/run/t715-wcycle.stop
POLICY=/sys/module/pcie_aspm/parameters/policy
RULE=/etc/udev/rules.d/60-t715-wifi-aspm.rules
SAVED=/run/t715-wifi-aspm.rules.saved
CONP=/sys/module/brcmfmac/parameters/pcie_console
FAIL='Firmware has halted|Timeout on response|MMIO read failed|past its depth|probe: failed|mailbox status reads all ones'
POL0=
moved=0

K() { echo "<3>t715-wcycle: $*" > /dev/kmsg; echo "$(date +%T) $*" >> "$LOG"; }
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
regs() { python3 -c 'import mmap,os,struct
fd=os.open("/dev/mem",os.O_RDONLY|os.O_SYNC)
def rd(base,off):
    m=mmap.mmap(fd,4096,mmap.MAP_SHARED,mmap.PROT_READ,offset=base); v=struct.unpack("<I",m[off:off+4])[0]; m.close(); return v
d=rd(0x10030000,0x634); p=rd(0x105C0000,0x730)
print("DIV_TOP_FSYS2 0x%08x (pcie div %d) PCIE_PHY_CONTROL 0x%08x" % (d, (d>>12)&7, p))' 2>/dev/null || echo "regs ?"; }
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
R=$(ls -d /sys/kernel/debug/regmap/*-0066 | head -1)
lpo() { echo "RTCCTRL $(dd if="$R/registers" bs=7 skip=12 count=1 2>/dev/null | sed 's/^0c: //' | tr -d '\n')"; }
wifi_state() { nmcli -t -f TYPE,STATE device 2>/dev/null | awk -F: '$1=="wifi"{print $2}' | head -1; }
wifi_ready() { case $(wifi_state) in connected | disconnected) return 0 ;; esac; return 1; }
nets() { nmcli device wifi rescan >/dev/null 2>&1; sleep 4; nmcli -t -f BSSID device wifi list 2>/dev/null | grep -c .; }
watch() { # $1 s a second at a time until a failure line; t keeps counting since the bind
	ws=0
	while [ "$ws" -lt "$1" ] && [ "$halted" = 0 ]; do
		sleep 1; t=$((t + 1)); ws=$((ws + 1))
		since "$m" | grep -qE "$FAIL" && halted=1
	done
}

[ -d "$DRV" ] || { K "no exynos-pcie driver: refused"; exit 1; }
[ -e /run/shannon/cp-state ] && grep -q "state=online" /run/shannon/cp-state && { K "the CP is online: refused"; exit 1; }
case $ASPM in
keep) aspmd=keep ;;
off) aspmd="off, performance at every bind" ;;
late) aspmd="late, on $ASPM_DELAY s after every bind" ;;
*) K "ASPM keep, off or late: refused"; exit 1 ;;
esac
case $CONSOLE in
0 | 1) ;;
*) K "CONSOLE 0 or 1: refused"; exit 1 ;;
esac
case $BTORDER in
after1 | before | late) ;;
*) K "BTORDER after1, before or late: refused"; exit 1 ;;
esac
bt_bind() { echo "$BT" > "$BTDRV/bind" 2>/dev/null || K "cycle $n: Bluetooth bind failed"; }
bt_wait() { # until an hci device exists, at most 10 s
	b=0
	while [ "$b" -lt 10 ]; do
		for h in /sys/class/bluetooth/hci*; do [ -e "$h" ] && return 0; done
		sleep 1; b=$((b + 1))
	done
	return 1
}
if [ "$FULL" = 1 ]; then
	for d in "$BTDRV"/serial*-*; do [ -e "$d" ] && { BT=${d##*/}; break; }; done
	[ -n "$BT" ] || { K "FULL=1 without Bluetooth bound to hci_uart_bcm: refused"; exit 1; }
fi

rm -f "$STOP"
( trap '' TERM INT HUP
  exec 3>/dev/watchdog || exit 1
  while [ ! -e "$STOP" ]; do printf . >&3; sleep 5; done
  printf V >&3 ) &
FEED=$!
finish() {
	touch "$STOP"; wait "$FEED" 2>/dev/null
	[ "$CONSOLE" = 1 ] && echo N > "$CONP" 2>/dev/null
	if [ "$moved" = 1 ]; then mv "$SAVED" "$RULE" 2>/dev/null; udevadm control --reload; fi
	if [ "$ASPM" != keep ] && [ -n "$POL0" ]; then echo "$POL0" > "$POLICY" 2>/dev/null; fi
}
trap finish EXIT
trap 'exit 1' TERM INT HUP

w=0; while ! wifi_ready && [ "$w" -lt 30 ]; do sleep 1; w=$((w + 1)); done
wifi_ready || { K "the Wi-Fi is not ready at the start ($(wifi_state)): refused"; exit 1; }
POL0=$(sed -E 's/.*\[([a-z]+)\].*/\1/' "$POLICY" 2>/dev/null)
[ "$CONSOLE" = 1 ] && echo Y > "$CONP"
K "start: waits $WAITS; ASPM $aspmd; full $FULL; btorder $BTORDER; console $(cat "$CONP" 2>/dev/null); $(nets) networks; $(regs); $(lpo); kernel $(uname -v | cut -c1-24)"
if [ "$ASPM" != keep ]; then
	[ -e "$RULE" ] && mv "$RULE" "$SAVED" && moved=1
	udevadm control --reload
fi
n=0; bound=1; halts=0; recovered=0; last=ok; zero=0
for off in $WAITS; do
	n=$((n + 1))
	if [ "$bound" = 1 ]; then
		w=0; while ! wifi_ready && [ "$w" -lt 30 ]; do sleep 1; w=$((w + 1)); done
		echo "$HOST" > "$DRV/unbind" || { K "cycle $n: unbind failed"; exit 1; }
		[ "$FULL" = 1 ] && { echo "$BT" > "$BTDRV/unbind" || K "cycle $n: Bluetooth unbind failed"; }
	fi
	bound=1
	sleep "$off"
	before="$(regs); $(lpo)"
	m=$(kmark)
	case $ASPM in off | late) echo performance > "$POLICY" ;; esac
	if [ "$FULL" = 1 ] && [ "$BTORDER" = before ]; then
		# the hci device registers at once; its power-up and firmware patch
		# (about 1-2 s at 3 Mbaud) follow, hence 3 s more before the Wi-Fi
		bt_bind
		bt_wait || K "cycle $n: no Bluetooth device 10 s after its bind"
		sleep 3
	fi
	echo "$HOST" > "$DRV/bind" || { K "cycle $n: bind failed"; exit 1; }
	[ "$FULL" = 1 ] && [ "$BTORDER" = after1 ] && ( sleep 1; bt_bind ) &
	t=0; halted=0
	if [ "$ASPM" = late ]; then
		watch "$ASPM_DELAY"
		if [ "$halted" = 0 ]; then
			# what the udev rule does, late: L0s off, then the policy
			for f in /sys/bus/pci/drivers/brcmfmac/*/link/l0s_aspm; do echo 0 > "$f"; done 2>/dev/null
			echo powersupersave > "$POLICY"
			K "cycle $n: ASPM on, $t s after the bind"
			watch 12
		fi
	else
		watch 12
	fi
	if [ "$halted" = 1 ]; then
		sleep 3
		K "cycle $n: HALT after $off s off, $t s after the bind; before the bind: $before; now: $(regs); $(lpo)"
		since "$m" | grep -E 'link up|Firmware: |halted|Timeout|MMIO|past its depth|probe' | kmask | cut -c1-120 | head -6 |
			while read -r l; do K "  $l"; done
		elbi
		K "  ASPM policy: $(sed -E 's/.*\[([a-z]+)\].*/\1/' "$POLICY" 2>/dev/null)"
		since "$m" | grep -E 'CONSOLE: |all ones|D3:|resume:|sleep: ' | kmask | cut -c1-140 | tail -15 |
			while read -r l; do K "  $l"; done
		if [ "$CONTINUE" != 1 ]; then
			K "result: HALT at cycle $n"
			exit 1
		fi
		# CONTINUE=1: power the chip off again (the host's unbind cuts WLAN_EN),
		# in the background since a stuck driver can hold it; the next cycle binds
		( echo "$HOST" > "$DRV/unbind"; [ "$FULL" = 1 ] && echo "$BT" > "$BTDRV/unbind" ) & up=$!
		u=0; while kill -0 "$up" 2>/dev/null && [ "$u" -lt "$UNBIND_MAX" ]; do sleep 1; u=$((u + 1)); done
		if kill -0 "$up" 2>/dev/null; then
			K "result: HALT at cycle $n, then the unbind still stuck after $u s ($halts halts before, $recovered recovered)"
			exit 1
		fi
		halts=$((halts + 1)); bound=0; last=halt
		K "cycle $n: host unbound again $u s after the halt; the next cycle powers the chip on afresh"
		continue
	fi
	if [ "$FULL" = 1 ] && [ "$BTORDER" = late ]; then
		bt_bind
		bt_wait || K "cycle $n: no Bluetooth device 10 s after its bind"
	fi
	[ "$last" = halt ] && recovered=$((recovered + 1))
	last=ok
	x=$(nets)
	[ "$x" -gt 0 ] || zero=$((zero + 1))
	K "cycle $n: OK after $off s off, $x networks; before the bind: $before"
done
if [ "$CONTINUE" = 1 ]; then
	K "result: $n cycles, $halts halts, $recovered recovered by the next power cycle, $zero OK starts with no network after, last cycle $last"
	[ "$last" = ok ] || exit 1
else
	K "result: all $n cycles OK"
fi
