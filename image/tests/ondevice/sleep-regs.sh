#!/bin/sh
# sleep-regs.sh — read only: what the first real sleep needs to know, run as root
# on the tablet (daily kernel or sleep test kernel):
#   - the power-down state (CON_PDN, PUD_PDN) of the PMIC and power-control
#     pins, through the pin controllers' own debugfs (the driver reads the
#     banks as its sleep save does);
#   - the S2MPS13's warm-reset input switch and the enable mode of the rails
#     stock runs under PWREN, through its regmap (volatile: hardware reads).
# Never reads the finger controller (14cb0000, the secure world's) nor aud
# (114b0000, its bus clock is held only by the sleep test kernel), nor the
# PMIC's interrupt registers (read to clear).
set -u
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
echo "kernel $(uname -v | cut -c1-40)"

pdn() { case $1 in 0x0) echo out0 ;; 0x1) echo out1 ;; 0x2) echo input ;; 0x3) echo prev ;; *) echo "?$1" ;; esac; }
pud() { case $1 in 0x0) echo none ;; 0x1) echo down ;; 0x3) echo up ;; *) echo "?$1" ;; esac; }
want() { case $1 in
	gpf5-4) echo "WRSTBI   stock out1/none" ;; gpf0-1) echo "G3D_EN   stock out0/none" ;;
	gpr3-0) echo "DVS_EN   stock prev/none" ;; gpr3-1) echo "CP_ON    stock prev/none" ;;
	gpr3-5) echo "PERST    stock prev/none" ;; gpj2-0) echo "WLAN_EN  stock prev/none" ;;
	gpd4-0) echo "BT_EN    stock prev/up" ;;   gpc0-5) echo "CP_RESET stock prev/none" ;;
	esac; }

echo "pin      now(CON DAT) sleep(CON_PDN/PUD_PDN)   role, stock sleep state"
for c in 10580000 11090000 15690000 14ca0000 14cc0000; do
	d=$(ls -d /sys/kernel/debug/pinctrl/${c}.pinctrl* 2>/dev/null | head -1)
	[ -n "$d" ] || { echo "pinctrl $c: absent"; continue; }
	grep -E '\((gpf5-4|gpf0-1|gpr3-0|gpr3-1|gpr3-5|gpj2-0|gpd4-0|gpc0-5)\)' "$d/pins" |
	while read -r line; do
		p=$(echo "$line" | sed -E 's/^pin [0-9]+ \(([^)]+)\).*/\1/')
		con=$(echo "$line" | sed -nE 's/.* CON\((0x[0-9a-f]+)\).*/\1/p')
		dat=$(echo "$line" | sed -nE 's/.* DAT\((0x[0-9a-f]+)\).*/\1/p')
		cp=$(echo "$line" | sed -nE 's/.* CON_PDN\((0x[0-9a-f]+)\).*/\1/p')
		pp=$(echo "$line" | sed -nE 's/.* PUD_PDN\((0x[0-9a-f]+)\).*/\1/p')
		printf '%-8s %-5s %-4s   %-6s/%-5s                %s\n' "$p" "$con" "$dat" "$(pdn "$cp")" "$(pud "$pp")" "$(want "$p")"
	done
done

r=$(ls -d /sys/kernel/debug/regmap/*-0066 2>/dev/null | head -1)
[ -n "$r" ] || { echo "no S2MPS13 regmap"; exit 0; }
reg() { dd if="$r/registers" bs=7 skip=$(($1)) count=1 2>/dev/null | sed -nE 's/^[0-9a-f]+: ([0-9a-f]+)$/\1/p'; }
v=$(reg 0x18)
echo "S2MPS13 WRSTBI (0x18) = 0x$v: buck reset on WRSTBI low $( [ $((0x${v:-0} & 0x20)) -ne 0 ] && echo enabled || echo disabled)"
# CTRL bits 7:6: 11 always on, 01 on while PWREN is high (off in sleep), 00 off
for e in "0x19 BUCK1 vdd_mif" "0x1b BUCK2 vdd_atl" "0x1d BUCK3 vdd_apl" "0x1f BUCK4 vdd_int" \
	 "0x21 BUCK5 vdd_disp_cam0" "0x23 BUCK6 vdd_g3d" "0x37 LDO2" "0x40 LDO11"; do
	set -- $e
	v=$(reg "$1")
	case $(( (0x${v:-0} >> 6) & 3 )) in 3) m="always on" ;; 1) m="PWREN (off in sleep)" ;; 0) m="off" ;; *) m="mode 2" ;; esac
	printf '%-6s %-14s 0x%s  %s\n' "$2" "${3:-}" "$v" "$m"
done
