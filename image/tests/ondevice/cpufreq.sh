#!/usr/bin/env bash
# cpufreq.sh — CPU frequency checks on the SM-T715, run as root ON THE TABLET
# over SSH (docs/hardware/CPUFREQ.md section 9).
#
#   ssh root@172.16.42.1 'bash -s' -- precheck < tests/ondevice/cpufreq.sh
#
# precheck is P0 of the protocol. It reads only: /dev/mem is opened O_RDONLY
# and mapped PROT_READ, so it cannot write, and the regmap file is read line by
# line (a full read would clear the PMIC's interrupt registers). It runs from
# the rescue, never the persistent root: a first read of a block that is powered
# off can bus-fault into a panic. Each line is printed before its read, so the
# last line says what was being read. The two A57 cluster blocks come last, one
# word each, with the disks synced first.
set -u
cmd=${1:-}

rd32() { python3 -c 'import mmap,os,struct,sys
a=int(sys.argv[1],16); b=a&~0xfff
fd=os.open("/dev/mem",os.O_RDONLY|os.O_SYNC); m=mmap.mmap(fd,4096,mmap.MAP_SHARED,mmap.PROT_READ,offset=b)
print("0x%08x" % struct.unpack_from("<I",m,a-b)[0])' "$1"; }
show() { printf '%s %-12s %s = ' "$1" "$2" "$3"; rd32 "$3"; }
bit() { echo $(( ($1 >> $2) & 1 )); }
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
reg_file() { ls -d /sys/kernel/debug/regmap/*-0066 2>/dev/null | head -1; }
reg() { dd if="$(reg_file)/registers" bs=7 skip=$(($1)) count=1 2>/dev/null | tr -d '\n'; }
clk() { awk -v n="$1" '$1 == n { print $1 "=" $5 }' /sys/kernel/debug/clk/clk_summary; }

case "$cmd" in
precheck)
    grep -q bootmode=2 /proc/cmdline || { echo "refused: run this from the rescue (t715-reboot-to recovery)"; exit 2; }
    echo "kernel $(uname -r); hottest $(cat /sys/class/thermal/thermal_zone*/temp | sort -n | tail -1)"

    echo "--- P1 fuses (CHIPID2)"
    show P1 groups 0x10004000
    w=$(rd32 0x10004010); echo "P1 0x10004010 = $w bit20(fs_abb)=$(bit $w 20)"
    w=$(rd32 0x1000403C); echo "P1 0x1000403C = $w bit21(limit sample)=$(bit $w 21)"

    echo "--- P2 memory"
    w=$(rd32 0x105B1000)
    echo "P2 DREX_FREQ_CTRL0 0x105B1000 = $w bit20=$(bit $w 20) bit16=$(bit $w 16) bit12=$(bit $w 12) bits31:28=$(( (w >> 28) & 15 ))"
    show P2 mif+0x0204 0x105B0204
    show P2 mif+0x0604 0x105B0604
    clk clk2x_phy; clk fout_mem0_pll; clk fout_mem1_pll; clk aclk_cci

    echo "--- P3 ABB"
    show P3 A57-ABB 0x105C0780
    show P3 A53-ABB 0x105C0784

    echo "--- P4 clocks"
    clk mout_bus_pll_atlas_user; clk mout_bus_pll_apollo_user; clk div_aclk_atlas; clk div_aclk_apollo
    clk fout_atlas_pll; clk fout_apollo_pll

    echo "--- P5 PMIC, regmap $(reg_file)"
    echo "P5 line 0x1C $(reg 0x1C)   (B2OUT, expected 6a)"
    echo "P5 line 0x1E $(reg 0x1E)   (B3OUT, expected 7a)"
    echo "P5 line 0x0E $(reg 0x0E)   (CTRL2)"

    echo "--- last: the A57 cluster's blocks; cpus online $(cat /sys/devices/system/cpu/online)"
    sync
    show P5 cmu-atlas 0x11800608
    sync
    show P3 EMA 0x11810330
    w=$(rd32 0x11810330); echo "P3 EMA fields bits22:20=$(( (w >> 20) & 7 )) bits10:8=$(( (w >> 8) & 7 ))"
    echo "done"
    ;;
*)
    echo "usage: cpufreq.sh precheck"; exit 2 ;;
esac
