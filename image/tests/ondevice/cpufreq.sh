#!/usr/bin/env bash
# cpufreq.sh — CPU frequency checks on the SM-T715, run as root ON THE TABLET
# over SSH (docs/hardware/CPUFREQ.md section 9).
#
#   ssh root@172.16.42.1 'bash -s' -- precheck               < tests/ondevice/cpufreq.sh
#   ssh root@172.16.42.1 'bash -s' -- load                   < tests/ondevice/cpufreq.sh
#   ssh root@172.16.42.1 'bash -s' -- step 1200000 5         < tests/ondevice/cpufreq.sh
#   ssh root@172.16.42.1 'bash -s' -- storm 400000 1200000 5 < tests/ondevice/cpufreq.sh
#   ssh root@172.16.42.1 'bash -s' -- throttle               < tests/ondevice/cpufreq.sh
#   ssh root@172.16.42.1 'bash -s' -- idle schedutil 10      < tests/ondevice/cpufreq.sh
#
# precheck is P0 of the protocol. It reads only: /dev/mem is opened O_RDONLY
# and mapped PROT_READ, so it cannot write, and the regmap file is read line by
# line (a full read would clear the PMIC's interrupt registers). It runs from
# the rescue, never the persistent root: a first read of a block that is powered
# off can bus-fault into a panic. Each line is printed before its read, so the
# last line says what was being read. The two A57 cluster blocks come last, one
# word each, with the disks synced first.
#
# load, step, storm, throttle and idle are stage 1 (section 9, rows 1a-1d and
# 1f): the TEST kernel in RECOVERY, cpufreq_dt a module loaded here by hand.
#   load                    1a: panic sysctls and console level 7, marker in
#                             /dev/kmsg, modprobe, one PASS/FAIL line per item
#                             (policies, levels, governors, rails, cooling
#                             devices, zone maps, kernel messages), then the
#                             reference hashes and clip, made on the fixed
#                             A57. LOAD PASS / LOAD FAIL.
#   step KHZ MIN            1b: policy0 at KHZ (clock and rail checked against
#                             the OPP), one timed mem run on cpu0 into
#                             speed.txt, then the load and the monitor.
#   storm KHZ1 KHZ2 MIN     1c: the same while the level flips every 50 ms;
#                             ends with the total_trans delta (20 per second).
#   throttle                1d: emul_temp on the three CPU zones; per case the
#                             cooling state, scaling_max_freq and cur_freq,
#                             then release back to state 0 and 1200000.
#   idle KHZ|schedutil MIN  1f: no load, a status line every 10 s, then the
#                             mean current and power, the total_trans delta and
#                             time_in_state; policy0 back to userspace 1200000.
#   rest                    policy0 back to userspace at 1200000, status line.
#   status                  one status line.
# The load is one worker per A53, pinned with taskset, looping the workloads
# (mem = sha256 of the 256 MiB stream file, neon/int = the 64 MiB stream hashed
# through the NEON or the integer openssl code, video = the clip's md5) into
# /run/t715-cpufreq/results.log, one line per result:
# `<uptime> cpu<N> <workload> OK|BAD <value>`. The script comes over stdin:
# everything backgrounded reads /dev/null, or it eats the script. Only
# policy0's scaling_setspeed and scaling_governor, the three CPU zones'
# emul_temp, the panic sysctls, printk and /dev/kmsg are ever written — never
# policy4, never a regulator file, never /dev/mem or the regmap. On abort:
# ABORT line, last status line, load stopped, sync, systemctl reboot (back to
# the daily kernel); T715_NOREBOOT=1 skips the reboot and exits 3.
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

# ---- stage 1: policy0 (the A53s) only; policy4 is never written ----
P0=/sys/devices/system/cpu/cpufreq/policy0
P4=/sys/devices/system/cpu/cpufreq/policy4
FG=/sys/class/power_supply/sm5703-fuelgauge
CHG=/sys/class/power_supply/sm5703-charger
OUT=/run/t715-cpufreq
LEVELS="400000 500000 600000 800000 900000 1000000 1100000 1200000"
# the deterministic stream (AES-128-CTR of zeros, key and IV zero), hashed on
# another machine; the workloads must produce exactly these.
H256=87ce2d77e0b6dd1326c473b66de288b27003c21c03a110cdb31323491ab28f44
H64=f30fb789a9f52beedf72cacba5240bcd34e513150a201daab9f24dde4051556d
BADMSG='Internal error|(^|[^a-z])Oops[ :-]|undefined instruction|Unhandled fault|Bad mode|rcu.*stall|soft lockup|hung_task|WARNING: CPU|re-parenting mux timed-out|timeout in divider|Could not lock PLL|Failed to set regulator'

pids=""; flipper=""; EMUL_TOUCHED=""; MT=0; LOST=""; MSG=""; bad=0

uv_of() { case $1 in
    400000) echo 875000 ;; 500000) echo 912500 ;; 600000) echo 937500 ;; 800000) echo 1000000 ;;
    900000) echo 1025000 ;; 1000000) echo 1087500 ;; 1100000) echo 1125000 ;; 1200000) echo 1162500 ;; esac; }
is_level() { case $1 in 400000|500000|600000|800000|900000|1000000|1100000|1200000) return 0 ;; *) return 1 ;; esac; }
ok_min() { case $1 in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ] && [ "$1" -le 30 ]; }
norm_list() { tr ' ' '\n' | awk 'NF' | sort -n | tr '\n' ' '; }
rail() { dirname "$(grep -lx "$1" /sys/class/regulator/*/name 2>/dev/null | head -1)"; }
rail_uv() { cat "$(rail "$1")/microvolts" 2>/dev/null; }
zone_by_type() { local z; for z in /sys/class/thermal/thermal_zone*; do
    [ "$(cat "$z/type" 2>/dev/null)" = "$1" ] && { echo "$z"; return 0; }; done; return 1; }
cdev_by_type() { local c; for c in /sys/class/thermal/cooling_device*; do
    [ "$(cat "$c/type" 2>/dev/null)" = "$1" ] && { echo "$c"; return 0; }; done; return 1; }
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; bad=1; }
chk() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: $2, wanted $3"; fi; }

# workloads: the stream hashed three ways; OPENSSL_armcap pins the NEON (1) or
# integer (0) code path of both openssl processes.
ctr() { openssl enc -aes-128-ctr -K 00000000000000000000000000000000 -iv 00000000000000000000000000000000 -nosalt -in /dev/zero 2>/dev/null; }
hash_mem() { sha256sum "$OUT/data.bin" 2>/dev/null | awk '{ print $1 }'; }
hash_neon() { OPENSSL_armcap=1 ctr | head -c 67108864 | OPENSSL_armcap=1 openssl dgst -sha256 -r 2>/dev/null | awk '{ print $1 }'; }
hash_int() { OPENSSL_armcap=0 ctr | head -c 67108864 | OPENSSL_armcap=0 openssl dgst -sha256 -r 2>/dev/null | awk '{ print $1 }'; }
hash_video() { ffmpeg -v error -i "$OUT/clip.mp4" -f md5 - 2>/dev/null | tail -1; }
make_data() { ctr | head -c 268435456 > "$OUT/data.bin"; }
make_clip() { ffmpeg -y -f lavfi -i testsrc2=size=1280x720:rate=30 -t 10 -c:v libx264 -preset veryfast -pix_fmt yuv420p "$OUT/clip.mp4" >/dev/null 2>&1; }
wl_mem() { local v; v=$(hash_mem); [ "$v" = "$H256" ] && echo "OK $v" || echo "BAD $v"; }
wl_neon() { local v; v=$(hash_neon); [ "$v" = "$H64" ] && echo "OK $v" || echo "BAD $v"; }
wl_int() { local v; v=$(hash_int); [ "$v" = "$H64" ] && echo "OK $v" || echo "BAD $v"; }
wl_video() { local v r; v=$(hash_video); r=$(cat "$OUT/clip.md5" 2>/dev/null)
    [ -n "$v" ] && [ "$v" = "$r" ] && echo "OK $v" || echo "BAD $v"; }

worker() { # N: pinned to cpuN by start_load, loops the workloads into results.log
    local n=$1 wl r
    while [ ! -e "$OUT/stop" ]; do
        for wl in mem neon int video; do
            [ -e "$OUT/stop" ] && break
            [ "$wl" = video ] && ! command -v ffmpeg >/dev/null 2>&1 && continue
            r=$(wl_$wl)
            echo "$(cut -d. -f1 /proc/uptime) cpu$n $wl $r" >> "$OUT/results.log"
        done
    done
}
on_cpu() { # CPU CMD...: CMD and its children on one CPU, in a subshell, stdin
    # clear of the script (the caller's own affinity is untouched)
    local c=$1; shift
    ( taskset -pc "$c" "$BASHPID" >/dev/null 2>&1; "$@" ) </dev/null
}
start_load() {
    mkdir -p "$OUT"; rm -f "$OUT/stop"; : > "$OUT/results.log"; pids=""
    local n
    for n in 0 1 2 3; do
        ( taskset -pc "$n" "$BASHPID" >/dev/null 2>&1; worker "$n" ) </dev/null >/dev/null 2>&1 &
        pids="$pids $!"
    done
}
alive_p() { # a reaped-but-unwaited worker reads Z here: kill -0 would lie
    local s; s=$(sed -n 's/.*) \(.\).*/\1/p' "/proc/$1/stat" 2>/dev/null)
    [ -n "$s" ] && [ "$s" != Z ]
}
descendants() { # PID: everything below PID, worker -> $() subshell -> pipeline
    local c pp
    for c in /proc/[0-9]*; do
        pp=$(sed -n 's/.*) [A-Za-z] \([0-9]*\) .*/\1/p' "$c/stat" 2>/dev/null)
        [ "$pp" = "$1" ] && { echo "${c#/proc/}"; descendants "${c#/proc/}"; }
    done
}
stop_load() { # the stop file ends a worker between workloads, then force
    [ -n "${pids:-}" ] || return 0
    local p i alive=""
    touch "$OUT/stop" 2>/dev/null
    for i in $(seq 1 75); do
        alive=""
        for p in $pids; do alive_p "$p" && alive="$alive $p"; done
        [ -z "$alive" ] && break
        sleep 0.2
    done
    if [ -n "$alive" ]; then # a stuck worker: its children do not die with it
        kill -9 $(for p in $alive; do descendants "$p"; echo "$p"; done) 2>/dev/null
    fi
    pids=""
}

# the only writer of emul_temp: 115000 powers the board off, so nothing at or
# above 105000, and no zone but the three CPU ones, is ever accepted.
set_emul() { # ZONETYPE TEMP
    local z
    case $1 in atlas0-thermal|atlas1-thermal|apollo-thermal) ;; *)
        echo "refused: $1 is not one of the three CPU zones"; return 1 ;; esac
    case $2 in ''|*[!0-9]*) echo "refused: temp '$2' is not a number"; return 1 ;; esac
    [ "$2" -ge 105000 ] && { echo "refused: $2 >= 105000 (115000 powers the board off)"; return 1; }
    z=$(zone_by_type "$1") || { echo "refused: no zone $1"; return 1; }
    echo "$2" > "$z/emul_temp" || return 1
    case " $EMUL_TOUCHED " in *" $1 "*) ;; *) EMUL_TOUCHED="$EMUL_TOUCHED $1" ;; esac
}
emul_release() { local t; for t in $EMUL_TOUCHED; do set_emul "$t" 0; done; }
cleanup() { # every exit path; subshells (workers, $( )) must not run it
    [ "${BASHPID:-0}" = "$$" ] || return 0
    [ -n "${flipper:-}" ] && kill "$flipper" 2>/dev/null
    stop_load
    emul_release
}
trap cleanup EXIT
trap 'exit 130' INT TERM

counts() { awk '{ if ($4 == "OK") ok++; else if ($4 == "BAD") bad++ } END { printf "ok=%d bad=%d", ok + 0, bad + 0 }' "$OUT/results.log" 2>/dev/null || printf 'ok=0 bad=0'; }
wl_counts() { local w n out=""; for w in mem neon int video; do
    n=$(awk -v w="$w" '$3 == w && $4 == "OK" { c++ } END { print c + 0 }' "$OUT/results.log" 2>/dev/null || echo 0)
    out="$out$w=$n "; done; echo "$out"; }
status_line() {
    local z zones="" c0; c0=$(cdev_by_type cpufreq-cpu0)
    for z in /sys/class/thermal/thermal_zone*; do
        zones="$zones$(cat "$z/type" 2>/dev/null)=$(cat "$z/temp" 2>/dev/null) "
    done
    printf 'up=%s p0=%s kfc=%s p4=%s eagle=%s %scdev0=%s tbat=%s cap=%s I=%smA chg=%s %s\n' \
        "$(cut -d. -f1 /proc/uptime)" \
        "$(cat "$P0/scaling_cur_freq" 2>/dev/null)" "$(rail_uv vdd_kfc)" \
        "$(cat "$P4/scaling_cur_freq" 2>/dev/null)" "$(rail_uv vdd_eagle)" \
        "$zones" \
        "$(cat "$c0/cur_state" 2>/dev/null)" \
        "$(cat "$FG/temp" 2>/dev/null)" "$(cat "$FG/capacity" 2>/dev/null)" \
        "$(( $(cat "$FG/current_now" 2>/dev/null || echo 0) / 1000 ))" \
        "$(cat "$CHG/online" 2>/dev/null)" "$(counts)"
}
ts_of() { awk -F'[][]' '{ printf "%.6f\n", $2 + 0 }'; } # dmesg line -> kernel seconds, to the us
mark() { # MT, the kernel time of a marker line, bounds the messages scanned
    # next. Not a line count, nor a fixed line: the ring is already full at
    # boot and the session's services write to it (one every 5 s), so each
    # message pushes an old one out and a fixed line leaves it in minutes
    local mk="t715-cpufreq: $cmd $(date +%s.%N)"
    echo "$mk" > /dev/kmsg 2>/dev/null || true
    MT=$(dmesg | grep -F -- "$mk" | tail -1 | ts_of); MT=${MT:-0}
}
ring_check() { # LOST and MSG from the lines after MT, then MT moves to the last
    # line read, so the next check starts where this one stopped
    local ring first
    ring=$(dmesg)
    first=$(printf '%s\n' "$ring" | head -1 | ts_of)
    LOST=$(awk -v a="$first" -v b="$MT" 'BEGIN { if (a + 0 > b + 0) print "yes" }')
    MSG=$(printf '%s\n' "$ring" | awk -F'[][]' -v t="$MT" '$2 + 0 > t + 0' | grep -iE "$BADMSG" | tail -1)
    MT=$(printf '%s\n' "$ring" | tail -1 | ts_of)
}
pin_self() { AFF0=$(taskset -pc $$ 2>/dev/null | head -1 | sed 's/.*: //'); taskset -pc "$1" $$ >/dev/null 2>&1; }
unpin_self() { taskset -pc "${AFF0:-0-7}" $$ >/dev/null 2>&1; }
abort() { # REASON: stop everything and go back to the daily kernel
    echo "ABORT $1"
    status_line
    [ -n "$flipper" ] && { kill "$flipper" 2>/dev/null; flipper=""; }
    stop_load
    sync
    if [ "${T715_NOREBOOT:-}" = 1 ]; then echo "T715_NOREBOOT=1: not rebooting, exit 3"; exit 3; fi
    systemctl reboot; sleep 30; exit 3
}
watch() { # "KHZ..." (empty: any clock) [nocdev]: the abort checks of section 9
    local k ok cur uv z t p msg cs gt cap
    [ -s "$OUT/results.log" ] && awk '$4 == "BAD" { bad = 1 } END { exit !bad }' "$OUT/results.log" && abort "BAD result in results.log"
    ring_check
    [ -n "$LOST" ] && abort "dmesg: the ring no longer reaches back to the last check"
    [ -n "$MSG" ] && abort "kernel message: $MSG"
    if [ -n "$1" ]; then
        ok=0
        for p in 1 2 3; do # again after 0.3 s: a read can land mid-transition
            cur=$(cat "$P0/scaling_cur_freq" 2>/dev/null); uv=$(rail_uv vdd_kfc)
            for k in $1; do [ "$cur" = "$k" ] && [ "$uv" = "$(uv_of "$k")" ] && ok=1; done
            [ "$ok" = 1 ] && break; sleep 0.3
        done
        [ "$ok" = 1 ] || abort "clock $cur / rail $uv, wanted $1 at its vdd_kfc"
    fi
    for z in /sys/class/thermal/thermal_zone*; do
        t=$(cat "$z/temp" 2>/dev/null); [ -n "$t" ] && [ "$t" -ge 85000 ] && abort "$(cat "$z/type" 2>/dev/null) at $t"
    done
    if [ "${2:-}" != nocdev ]; then
        cs=$(cat "$(cdev_by_type cpufreq-cpu0)/cur_state" 2>/dev/null || echo 0)
        [ "$cs" -gt 0 ] && abort "cooling state $cs: a trip is active"
    fi
    gt=$(cat "$FG/temp" 2>/dev/null || echo 0); [ "$gt" -ge 540 ] && abort "gauge temp $gt"
    cap=$(cat "$FG/capacity" 2>/dev/null || echo 100); [ "$cap" -lt 50 ] && abort "battery $cap %"
    for p in ${pids:-}; do alive_p "$p" || abort "worker $p died"; done
    [ -n "$flipper" ] && ! alive_p "$flipper" && abort "flipper died"
}
monitor() { # MIN KHZ...: a status line and the abort checks every 5 s
    local deadline=$(( $(date +%s) + $1 * 60 )); shift
    local accept="$*"
    while [ "$(date +%s)" -lt "$deadline" ]; do
        # A flipping clock is read held on one level: clock and rail are two
        # reads, and a transition between them pairs one level's clock with
        # the other's rail (storm of 11-03: 400000 with 1162500, the safe
        # order of a transition, and 1200000 with 875000 in a status line).
        [ -n "$flipper" ] && { : > "$OUT/hold"; sleep 0.2; }
        status_line
        watch "$accept" cdev
        rm -f "$OUT/hold"
        sleep 5
    done
}
check_zone() { # TYPE T1 T2: exactly two cdev links to cpufreq-cpu0, passive, at T1/T2
    local zn l ty tp temps n badty want got
    zn=$(zone_by_type "$1")
    [ -n "$zn" ] || { fail "$1: zone missing"; return 0; }
    n=0; badty=0; temps=""
    for l in $(ls "$zn" | grep -E '^cdev[0-9]+$'); do
        ty=$(cat "$zn/$l/type" 2>/dev/null)
        [ "$ty" = cpufreq-cpu0 ] || continue
        n=$((n + 1)); tp=$(cat "$zn/${l}_trip_point" 2>/dev/null)
        temps="$temps $(cat "$zn/trip_point_${tp}_temp" 2>/dev/null)"
        [ "$(cat "$zn/trip_point_${tp}_type" 2>/dev/null)" = passive ] || badty=1
    done
    want=$(printf '%s %s' "$2" "$3" | norm_list); got=$(printf '%s' "$temps" | norm_list)
    if [ "$n" = 2 ] && [ "$badty" = 0 ] && [ "$got" = "$want" ]; then pass "$1: two passive trips $2/$3 on cpufreq-cpu0"
    else fail "$1: n=$n passive=$(( 1 - badty )) temps=[$got] want=[$want]"; fi
}
guard() { # [load|any]: the test kernel only, and the module state must be right;
    # any (rest, status) also works below 50 %, to put things back
    grep -q bootmode=2 /proc/cmdline || { echo "refused: not the test kernel in recovery (bootmode=2)"; exit 2; }
    if [ -d /sys/module/sec_modem_v1 ] || ls /lib/modules/"$(uname -r)"/kernel/drivers/misc/modem_v1/* >/dev/null 2>&1; then
        echo "refused: a modem driver is present"; exit 2
    fi
    local t
    for t in openssl taskset python3; do command -v "$t" >/dev/null 2>&1 || { echo "refused: $t missing"; exit 2; }; done
    [ "$(rd32 0x10004000 2>/dev/null)" = "0x01110111" ] || { echo "refused: fuse 0x10004000 is not 0x01110111, not this chip's table"; exit 2; }
    mkdir -p "$OUT"
    local cap; cap=$(cat "$FG/capacity" 2>/dev/null) || { echo "refused: no fuel gauge"; exit 2; }
    [ "${1:-}" = any ] || [ "$cap" -ge 50 ] || { echo "refused: battery at $cap %"; exit 2; }
    if [ "${1:-}" = load ]; then
        lsmod | grep -q '^cpufreq_dt ' && { echo "refused: cpufreq_dt already loaded"; exit 2; }
    else
        lsmod | grep -q '^cpufreq_dt ' || { echo "refused: cpufreq_dt not loaded (run load first)"; exit 2; }
        [ -d "$P0" ] || { echo "refused: no policy0"; exit 2; }
    fi
}

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
load)
    guard load
    mkdir -p "$OUT"; rm -f "$OUT/stop"; : > "$OUT/results.log"; : > "$OUT/speed.txt"
    sysctl -w kernel.panic_on_rcu_stall=1 kernel.softlockup_panic=1 kernel.hung_task_panic=1
    echo 7 > /proc/sys/kernel/printk
    mark
    kfc0=$(rail_uv vdd_kfc); eagle0=$(rail_uv vdd_eagle)
    echo "rails before: vdd_kfc $kfc0 vdd_eagle $eagle0"
    modprobe cpufreq_dt || { echo "LOAD FAIL: modprobe cpufreq_dt"; exit 1; }
    for _ in $(seq 1 20); do [ -d "$P0" ] && break; sleep 0.5; done

    echo "--- 1a policies and levels"
    if [ -d "$P0" ] && [ -d "$P4" ]; then pass "policies policy0 policy4"; else fail "policies policy0/policy4"; fi
    chk "policy0 related_cpus" "$(cat $P0/related_cpus 2>/dev/null)" "0 1 2 3"
    chk "policy4 related_cpus" "$(cat $P4/related_cpus 2>/dev/null)" "4 5 6 7"
    chk "cpuinfo_max_freq both 1200000" "$(cat $P0/cpuinfo_max_freq 2>/dev/null)/$(cat $P4/cpuinfo_max_freq 2>/dev/null)" "1200000/1200000"
    chk "policy0 frequencies" "$(cat $P0/scaling_available_frequencies 2>/dev/null | norm_list)" "$(printf '%s' "$LEVELS" | norm_list)"
    chk "policy4 frequencies" "$(cat $P4/scaling_available_frequencies 2>/dev/null | norm_list)" "$(echo 1200000 | norm_list)"
    chk "governors userspace" "$(cat $P0/scaling_governor 2>/dev/null)/$(cat $P4/scaling_governor 2>/dev/null)" "userspace/userspace"
    chk "cur_freq 1200000 both" "$(cat $P0/scaling_cur_freq 2>/dev/null)/$(cat $P0/cpuinfo_cur_freq 2>/dev/null)/$(cat $P4/scaling_cur_freq 2>/dev/null)/$(cat $P4/cpuinfo_cur_freq 2>/dev/null)" "1200000/1200000/1200000/1200000"

    echo "--- 1a rails and cooling"
    kfc1=$(rail_uv vdd_kfc); eagle1=$(rail_uv vdd_eagle)
    if [ "$kfc1" = "$kfc0" ] && [ "$kfc1" = 1162500 ] && [ "$eagle1" = "$eagle0" ] && [ "$eagle1" = 1062500 ]; then
        pass "rails unchanged $kfc1/$eagle1"
    else fail "rails $kfc0->$kfc1 $eagle0->$eagle1 (wanted 1162500/1062500)"; fi
    c0=$(cdev_by_type cpufreq-cpu0); c4=$(cdev_by_type cpufreq-cpu4)
    if [ -n "$c0" ] && [ "$(cat "$c0/max_state" 2>/dev/null)" = 7 ]; then pass "cdev cpufreq-cpu0 max_state 7"
    else fail "cdev cpufreq-cpu0 max_state $(cat "$c0/max_state" 2>/dev/null)"; fi
    if [ -n "$c4" ] && [ "$(cat "$c4/max_state" 2>/dev/null)" = 0 ]; then pass "cdev cpufreq-cpu4 max_state 0"
    else fail "cdev cpufreq-cpu4 max_state $(cat "$c4/max_state" 2>/dev/null)"; fi
    check_zone atlas0-thermal 95000 100000
    check_zone atlas1-thermal 95000 100000
    check_zone apollo-thermal 81000 86000
    c4hit=""
    for zn in /sys/class/thermal/thermal_zone*; do
        for l in $(ls "$zn" 2>/dev/null | grep -E '^cdev[0-9]+$'); do
            [ "$(cat "$zn/$l/type" 2>/dev/null)" = cpufreq-cpu4 ] && c4hit="$c4hit $(cat "$zn/type" 2>/dev/null)"
        done
    done
    [ -z "$c4hit" ] && pass "no zone bound to cpufreq-cpu4" || fail "cpufreq-cpu4 bound to:$c4hit"
    ring_check
    [ -n "$LOST" ] && fail "dmesg: the ring no longer reaches back to the marker"
    [ -n "$MSG" ] && fail "kernel message: $MSG" || pass "no bad kernel message"

    echo "--- 1a references, on the fixed A57"
    on_cpu 4 make_data
    h=$(on_cpu 4 hash_mem); chk "data.bin sha256 (256 MiB)" "$h" "$H256"
    h=$(on_cpu 4 hash_neon); chk "neon reference (64 MiB)" "$h" "$H64"
    h=$(on_cpu 4 hash_int); chk "int reference (64 MiB)" "$h" "$H64"
    if command -v ffmpeg >/dev/null 2>&1; then
        if on_cpu 4 make_clip && [ -s "$OUT/clip.mp4" ]; then
            on_cpu 4 ffmpeg -v error -i "$OUT/clip.mp4" -f md5 - > "$OUT/clip.md5" 2>/dev/null
            h=$(on_cpu 4 hash_video); chk "clip md5 round-trip" "$h" "$(cat "$OUT/clip.md5" 2>/dev/null)"
        else fail "clip encode"; fi
    else
        echo "WARN no ffmpeg: video workload skipped"
    fi
    echo "policy0 total_trans $(cat "$P0/stats/total_trans" 2>/dev/null)"
    [ "$bad" = 0 ] && { echo "LOAD PASS"; exit 0; } || { echo "LOAD FAIL"; exit 1; }
    ;;
step)
    guard
    KHZ=${2:-}; MIN=${3:-}
    is_level "$KHZ" || { echo "refused: KHZ must be one of $LEVELS"; exit 2; }
    ok_min "$MIN" || { echo "refused: MIN must be 1-30"; exit 2; }
    mark
    echo "$KHZ" > "$P0/scaling_setspeed"
    sleep 0.5
    cur=$(cat "$P0/scaling_cur_freq"); cif=$(cat "$P0/cpuinfo_cur_freq"); uv=$(rail_uv vdd_kfc)
    { [ "$cur" = "$KHZ" ] && [ "$cif" = "$KHZ" ] && [ "$uv" = "$(uv_of "$KHZ")" ]; } || \
        abort "clock $cur/$cif rail $uv at $KHZ (wanted $(uv_of "$KHZ"))"
    t0=$(date +%s%N); h=$(on_cpu 0 hash_mem); t1=$(date +%s%N)
    [ "$h" = "$H256" ] || abort "mem hash $h during the timed run"
    ns=$(( t1 - t0 )); mbs=$(( 268435456000 / ns ))
    echo "mem at $KHZ: $mbs MB/s ($(( ns / 1000000 )) ms)"
    echo "$KHZ $mbs" >> "$OUT/speed.txt"
    base=$(awk '$1 == 1200000 { print $2; exit }' "$OUT/speed.txt" 2>/dev/null)
    if [ -n "$base" ]; then
        awk -v a="$mbs" -v b="$base" -v k="$KHZ" 'BEGIN { printf "report: speed ratio %.3f against clock ratio %.3f (vs 1200000)\n", a / b, k / 1200000 }'
    fi
    start_load
    pin_self 4
    monitor "$MIN" "$KHZ"
    unpin_self
    stop_load
    watch "" nocdev  # the last results can land after the final poll; a trip
    echo "STEP PASS $KHZ $(wl_counts)"   # lingering past the load is not one
    ;;
storm)
    guard
    K1=${2:-}; K2=${3:-}; MIN=${4:-}
    is_level "$K1" && is_level "$K2" || { echo "refused: KHZ1 and KHZ2 must be in $LEVELS"; exit 2; }
    [ "$K1" != "$K2" ] || { echo "refused: KHZ1 and KHZ2 are the same"; exit 2; }
    ok_min "$MIN" || { echo "refused: MIN must be 1-30"; exit 2; }
    mark
    start_load
    tt0=$(cat "$P0/stats/total_trans" 2>/dev/null)
    rm -f "$OUT/hold"
    ( taskset -pc 4 "$BASHPID" >/dev/null 2>&1
      while [ ! -e "$OUT/stop" ]; do
          for k in "$K1" "$K2"; do # monitor() holds it on a level for its reads
              while [ -e "$OUT/hold" ] && [ ! -e "$OUT/stop" ]; do sleep 0.02; done
              echo "$k" > "$P0/scaling_setspeed"; sleep 0.05
          done
      done ) </dev/null >/dev/null 2>&1 &
    flipper=$!
    pin_self 4
    monitor "$MIN" "$K1" "$K2"
    unpin_self
    kill "$flipper" 2>/dev/null; flipper=""; rm -f "$OUT/hold"
    echo 1200000 > "$P0/scaling_setspeed"
    stop_load
    watch "" nocdev
    tt1=$(cat "$P0/stats/total_trans" 2>/dev/null)
    echo "total_trans delta $(( tt1 - tt0 )) expected $(( MIN * 60 * 20 )) (20 per second)"
    echo "STORM PASS $(wl_counts)"
    ;;
throttle)
    guard
    mark
    echo 1200000 > "$P0/scaling_setspeed"
    c0=$(cdev_by_type cpufreq-cpu0)
    [ -n "$c0" ] || { echo "refused: no cpufreq-cpu0 cooling device"; exit 2; }
    trc=0
    for spec in "apollo-thermal 82000 1 2 -ge" "apollo-thermal 87000 2 7 -le" \
                "atlas0-thermal 96000 1 2 -ge" "atlas0-thermal 101000 2 7 -le" \
                "atlas1-thermal 96000 1 2 -ge" "atlas1-thermal 101000 2 7 -le"; do
        set -- $spec
        zt=$1; et=$2; lo=$3; hi=$4; op=$5
        set_emul "$zt" "$et" || { fail "$zt $et: emul_temp refused"; trc=1; continue; }
        sleep 3
        st=$(cat "$c0/cur_state" 2>/dev/null); mf=$(cat "$P0/scaling_max_freq" 2>/dev/null); cf=$(cat "$P0/scaling_cur_freq" 2>/dev/null)
        ok=1
        case $st in ''|*[!0-9]*) ok=0 ;; *) [ "$st" -ge "$lo" ] && [ "$st" -le "$hi" ] || ok=0 ;; esac
        case $mf in ''|*[!0-9]*) ok=0 ;; *) if [ "$op" = -ge ]; then [ "$mf" -ge 1000000 ] || ok=0
            else [ "$mf" -le 1000000 ] || ok=0; fi ;; esac
        if [ "$ok" = 1 ]; then echo "PASS $zt $et: state $st, max_freq $mf, cur_freq $cf"
        else echo "FAIL $zt $et: state $st (want $lo-$hi), max_freq $mf (want $op 1000000), cur_freq $cf"; trc=1; fi
        set_emul "$zt" 0
        rok=0
        for i in $(seq 1 20); do
            sleep 0.5
            [ "$(cat "$c0/cur_state" 2>/dev/null)" = 0 ] || continue
            if [ "$(cat "$P0/scaling_cur_freq" 2>/dev/null)" = 1200000 ]; then rok=1; break; fi
        done
        if [ "$rok" = 1 ]; then echo "PASS $zt released: state 0, cur_freq 1200000"
        else echo "FAIL $zt release: state $(cat "$c0/cur_state" 2>/dev/null), cur_freq $(cat "$P0/scaling_cur_freq" 2>/dev/null)"; trc=1; fi
    done
    echo 1200000 > "$P0/scaling_setspeed"
    exit "$trc"
    ;;
idle)
    guard
    mode=${2:-}; MIN=${3:-}
    if [ "$mode" != schedutil ]; then is_level "$mode" || { echo "refused: KHZ must be in $LEVELS, or schedutil"; exit 2; }; fi
    ok_min "$MIN" || { echo "refused: MIN must be 1-30"; exit 2; }
    mark
    tt0=$(cat "$P0/stats/total_trans" 2>/dev/null)
    if [ "$mode" = schedutil ]; then
        echo schedutil > "$P0/scaling_governor" 2>/dev/null
        [ "$(cat "$P0/scaling_governor")" = schedutil ] || { echo "refused: schedutil governor not available"; exit 2; }
        accept=""
    else
        echo "$mode" > "$P0/scaling_setspeed"
        accept="$mode"
    fi
    n=0; si=0; sp=0
    deadline=$(( $(date +%s) + MIN * 60 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        status_line
        i=$(cat "$FG/current_now" 2>/dev/null || echo 0)
        v=$(cat "$FG/voltage_now" 2>/dev/null || echo 0)
        si=$(( si + i )); sp=$(( sp + i * v )); n=$(( n + 1 ))
        watch "$accept" nocdev
        sleep 10
    done
    watch "$accept" nocdev
    awk -v si="$si" -v sp="$sp" -v n="$n" 'BEGIN { if (n > 0) printf "mean current %.1f mA, mean power %.1f mW over %d samples\n", si / n / 1000, sp / n / 1000000000, n }'
    echo "total_trans delta $(( $(cat "$P0/stats/total_trans" 2>/dev/null || echo 0) - tt0 ))"
    echo "--- policy0/stats/time_in_state"
    cat "$P0/stats/time_in_state" 2>/dev/null
    echo userspace > "$P0/scaling_governor"
    echo 1200000 > "$P0/scaling_setspeed"
    ;;
rest)
    guard any
    echo userspace > "$P0/scaling_governor" 2>/dev/null
    echo 1200000 > "$P0/scaling_setspeed"
    status_line
    ;;
status)
    guard any
    status_line
    ;;
*)
    echo "usage: cpufreq.sh precheck | load | step KHZ MIN | storm KHZ1 KHZ2 MIN |"
    echo "                throttle | idle KHZ|schedutil MIN | rest | status"
    echo "       KHZ is one of $LEVELS; on abort the tablet reboots back to the"
    echo "       daily kernel, unless T715_NOREBOOT=1 (then no reboot, exit 3)"
    exit 2 ;;
esac
