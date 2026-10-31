#!/usr/bin/env bash
# gpufreq.sh — GPU frequency (panfrost devfreq) validation on the SM-T715,
# run as root ON THE TABLET over SSH, on a kernel whose board includes the
# gpufreq dtsi (docs/hardware/GPU.md §10) and an initramfs booted with
# t715.modblacklist=panfrost, so the GPU driver is loaded here, by hand,
# with the cap set before any GPU job runs. Decision record:
# docs/journal/ONDEVICE-2026-10-29.md ("GPU frequency:").
#
#   ssh root@172.16.42.1 'bash -s' -- precheck        < tests/ondevice/gpufreq.sh
#   ssh root@172.16.42.1 'bash -s' -- load 266000000  < tests/ondevice/gpufreq.sh
#   ssh root@172.16.42.1 'bash -s' -- step F MIN      < tests/ondevice/gpufreq.sh
#   ssh root@172.16.42.1 'bash -s' -- storm CAP MIN   < tests/ondevice/gpufreq.sh
#   ssh root@172.16.42.1 'bash -s' -- throttle CAP    < tests/ondevice/gpufreq.sh
#   ssh root@172.16.42.1 'bash -s' -- cap CAP         < tests/ondevice/gpufreq.sh
#
#   precheck   read-only: PMIC revision, BUCK6 ramp and boot voltage (S2MPS13
#              regmap, one register at a time), G3D ABB, ASV table and fused
#              groups (always-on SoC registers only).
#   load F     modprobe panfrost, cap max_freq at F at once, check the OPP
#              table, the regulator and the cooling device; then restart
#              the graphical session so Hyprland gets the GPU.
#   step F MIN pin the GPU at F for MIN minutes under the workload: glmark2
#              (--validate, then scored runs) and shell panel cycles. One
#              summary line: faults by type, voltage and clock read back,
#              hottest zone, GPU cooling state, glmark2 score/validation.
#   storm CAP MIN  the same workload while min/max flip between 266 MHz
#              and CAP every 50 ms (PLL relocks), then a validation run.
#   throttle CAP   governor free up to CAP under load; emulate apollo at
#              82 and 87 °C, check the GPU cooling state and frequency.
#   cap CAP    leave the governor free between 266 MHz and CAP.
#
# Never writes a register: the regmap file is only read line by line (a
# full read would clear the PMIC's interrupt registers), devmem only reads
# always-on blocks. Abort criteria (docs/hardware/GPU.md §10.8): a new
# fault type or a rate above the 266 MHz baseline, a reset/timeout message,
# voltage or clock not equal to the OPP, any zone >= 85 °C, a validation
# failure, a hang. On abort the GPU is pinned back to 266 MHz.
set -uo pipefail
export LC_ALL=C

D=/sys/class/devfreq/14ac0000.gpu
OUT=/tmp/gpufreq; mkdir -p "$OUT"
U=alarm; RUN=/run/user/$(id -u $U)
au() { runuser -u $U -- env XDG_RUNTIME_DIR=$RUN HYPRLAND_INSTANCE_SIGNATURE="$(ls -t $RUN/hypr 2>/dev/null | head -1)" \
        WAYLAND_DISPLAY=wayland-1 DBUS_SESSION_BUS_ADDRESS=unix:path=$RUN/bus OMARCHY_PATH=/usr/share/omarchy "$@"; }
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug

reg_file() { ls -d /sys/kernel/debug/regmap/*-0066 2>/dev/null | head -1; }
reg() { dd if="$(reg_file)/registers" bs=7 skip=$(($1)) count=1 2>/dev/null | tr -d '\n'; }
vreg() { dirname "$(grep -lx vdd_g3d /sys/class/regulator/*/name 2>/dev/null | head -1)"; }
clk() { awk '$1 ~ /^(fout_g3d_pll|aclk_g3d)$/ { print $1 "=" $5 }' /sys/kernel/debug/clk/clk_summary | tr '\n' ' '; }
# G3D ABB (PMU + 0x0790), read-only through /dev/mem: 0x8000008d is stock's
# reverse body bias for an idle GPU, which mainline leaves in place; stock
# runs the GPU at 0x80000088 (, docs/journal/ONDEVICE-2026-10-29.md).
abb() { python3 -c 'import mmap,os,struct
fd=os.open("/dev/mem",os.O_RDONLY|os.O_SYNC); m=mmap.mmap(fd,4096,mmap.MAP_SHARED,mmap.PROT_READ,offset=0x105C0000)
print("0x%08x" % struct.unpack("<I",m[0x790:0x794])[0])' 2>/dev/null || echo "?"; }
st() { echo "cur=$(cat $D/cur_freq) min=$(cat $D/min_freq) max=$(cat $D/max_freq) uV=$(cat "$(vreg)/microvolts") $(clk) abb=$(abb)"; }
pin() { echo "$1" > $D/max_freq; echo "$1" > $D/min_freq; sleep 1; }
free_range() { echo 266000000 > $D/min_freq; echo "$1" > $D/max_freq; }
hottest() { for z in /sys/class/thermal/thermal_zone*; do echo "$(cat $z/temp) $(cat $z/type)"; done | sort -n | tail -1; }
gpu_cdev() { for c in /sys/class/thermal/cooling_device*; do grep -qx 'devfreq-14ac0000.gpu' $c/type && echo $c; done | head -1; }
expected_uv() { case $1 in 160000000|266000000|350000000) echo 1037500 ;; 420000000) echo 1062500 ;;
    500000000) echo 1087500 ;; 550000000) echo 1112500 ;; 600000000) echo 1137500 ;; 700000000) echo 1200000 ;; *) echo 0 ;; esac; }

FAULTS='js fault|GPU Fault|Unhandled Page fault|gpu sched timeout|reset timed out|AS_ACTIVE bit stuck|error powering up gpu|power transition timeout|Could not lock PLL|Couldn.t set OPP|WARNING: CPU|soft lockup|rcu.*stall'
faults_since() { dmesg | tail -n "+$(( $1 + 1 ))" | grep -E "$FAULTS" |
    sed -E 's/^\[[ 0-9.]+\] //; s/(head|tail)=0x[0-9a-f]+/\1=X/g; s/js=[0-9]/js=N/' | sort | uniq -c | sort -rn; }

# The workload: the shell's 3 panels opened and closed until the deadline,
# plus, with GPUFREQ_GLMARK2=1, glmark2 fullscreen (a --validate pass, then
# scored runs). glmark2 is off by default: on 2026-10-29 its load hung the
# tablet at the daily 266 MHz clock, before any frequency change (Midgard
# job faults, like GStreamer's gltestsrc in docs/hardware/GPU.md §10.10).
workload() {
    local until=$1 tag=$2
    ( while [ "$(date +%s)" -lt "$until" ]; do
          for p in omamobile.launcher omamobile.quicksettings omamobile.switcher; do
              au omarchy-shell shell toggle $p {} >/dev/null 2>&1; sleep 2
              au omarchy-shell shell hide $p >/dev/null 2>&1; sleep 1
          done
      done ) &
    local panels=$!
    if [ "${GPUFREQ_GLMARK2:-0}" = 1 ]; then
        au glmark2-es2-wayland --fullscreen --validate > "$OUT/$tag-validate.txt" 2>&1
        while [ "$(date +%s)" -lt "$until" ]; do
            au glmark2-es2-wayland --fullscreen >> "$OUT/$tag-score.txt" 2>&1
        done
    fi
    wait $panels 2>/dev/null
}
validated() { local f="$OUT/$1-validate.txt"; [ -s "$f" ] || { echo "no-run"; return; }
    if grep -q 'Validation: Failure' "$f"; then echo "FAIL($(grep -c 'Validation: Failure' "$f"))"
    elif grep -q 'Validation: Success' "$f"; then echo "ok($(grep -c 'Validation: Success' "$f"))"
    else echo "unknown"; fi; }
score() { grep -h 'glmark2 Score' "$OUT/$1-score.txt" 2>/dev/null | awk '{ s += $3; n++ } END { if (n) printf "%d (%d runs)", s / n, n; else print "none" }'; }

summary() { # TAG F M0 T0
    local tag=$1 f=$2 m0=$3 t0=$4 uv ok=PASS
    uv=$(cat "$(vreg)/microvolts")
    local fl; fl=$(faults_since "$m0")
    echo "$fl" > "$OUT/$tag-faults.txt"
    local hot; hot=$(cat "$OUT/$tag-hot" 2>/dev/null || hottest)
    [ "$f" != 0 ] && [ "$uv" != "$(expected_uv "$f")" ] && ok="FAIL(voltage)"
    [ "${hot%% *}" -ge 85000 ] && ok="FAIL(temperature)"
    echo "$fl" | grep -qE 'timed out|stuck|powering up|transition timeout|lock PLL|set OPP|soft lockup|stall|WARNING' && ok="FAIL(gpu-error)"
    case "$(validated "$tag")" in FAIL*) ok="FAIL(validation)" ;; esac
    printf '%-14s %s  %s  hottest %s  cdev %s  valid %s  score %s  %s s\n' "$tag" "$ok" "$(st)" "$hot" \
        "$(cat "$(gpu_cdev)/cur_state" 2>/dev/null)" "$(validated "$tag")" "$(score "$tag")" "$(( $(date +%s) - t0 ))"
    echo "  faults: $(echo "$fl" | awk 'NF' | tr '\n' ';' | sed 's/  */ /g')"
}

track_hot() { # TAG UNTIL: keep the hottest reading
    ( local best=0 line; while [ "$(date +%s)" -lt "$2" ]; do line=$(hottest); [ "${line%% *}" -gt "$best" ] && best=${line%% *} && echo "$line" > "$OUT/$1-hot"; sleep 1; done ) &
}

cmd=${1:-}; shift || true
case "$cmd" in
precheck)
    R=$(reg_file); echo "regmap: ${R:-missing}"
    echo "P1 REG_ID    $(reg 0x00)   (must not be 00)"
    echo "P2 BUCK_RAMP1 $(reg 0x30)  (BUCK6 = bits 1:0, stock 1 = 12 mV/us)"
    echo "P3 B6OUT     $(reg 0x24)   (0x56 = 937.5 mV at boot); vdd_g3d $(cat "$(vreg)/microvolts" 2>/dev/null) uV; $(clk)"
    echo "P4 G3D ABB   $(abb)  (stock runs the GPU at 0x80000088; 0x8000008d = its idle reverse bias)"
    lsmod | grep -q '^panfrost ' && echo "WARNING: panfrost already loaded" || echo "panfrost not loaded (as expected)"
    ;;
load)
    cap=${1:-266000000}
    m0=$(dmesg | wc -l)
    modprobe panfrost || { echo "modprobe failed"; exit 1; }
    for _ in $(seq 1 20); do [ -d $D ] && break; sleep 0.5; done
    [ -d $D ] || { echo "no devfreq device"; dmesg | tail -n +$((m0 + 1)) | grep -iE 'panfrost|opp|devfreq'; exit 1; }
    pin "$cap"
    dmesg | tail -n "+$((m0 + 1))" | grep -iE 'panfrost|opp|devfreq|regulator' | head -20
    echo "governor $(cat $D/governor); available $(cat $D/available_frequencies)"
    echo "$(st)"
    c=$(gpu_cdev); echo "cooling ${c:-none}: state $(cat $c/cur_state 2>/dev/null)/$(cat $c/max_state 2>/dev/null)"
    for z in /sys/class/thermal/thermal_zone*; do grep -q apollo $z/type && ls $z | grep -E '^cdev[0-9]+$' | while read -r l; do
        echo "  $(cat $z/type) $l -> $(cat $z/$l/type) trip $(cat $z/${l}_trip_point)"; done; done
    systemctl restart sddm; sleep 25
    echo "session: Hyprland $(pgrep -xo Hyprland) quickshell $(pgrep -n -u $U -x quickshell)"
    ;;
step)
    f=$1; min=${2:-10}
    pin "$f"; m0=$(dmesg | wc -l); t0=$(date +%s); until=$(( t0 + min * 60 ))
    rm -f "$OUT/step-$f"-*; track_hot "step-$f" "$until"
    workload "$until" "step-$f"
    pin "$f"; summary "step-$f" "$f" "$m0" "$t0"
    ;;
storm)
    cap=$1; min=${2:-10}
    m0=$(dmesg | wc -l); t0=$(date +%s); until=$(( t0 + min * 60 ))
    echo 0 > $D/min_freq; echo "$cap" > $D/max_freq
    ( while [ "$(date +%s)" -lt "$until" ]; do
          echo "$cap" > $D/max_freq; echo "$cap" > $D/min_freq; sleep 0.05
          echo 266000000 > $D/min_freq; echo 266000000 > $D/max_freq; sleep 0.05
      done ) &
    flipper=$!
    rm -f "$OUT/storm"-*; track_hot storm "$until"
    workload "$until" storm
    wait $flipper 2>/dev/null
    echo "transitions: $(grep -E 'Total transition' $D/trans_stat)"
    pin 266000000; summary storm 266000000 "$m0" "$t0"
    ;;
throttle)
    cap=$1; z=$(for z in /sys/class/thermal/thermal_zone*; do grep -q apollo $z/type && echo $z; done | head -1)
    c=$(gpu_cdev); free_range "$cap"
    until=$(( $(date +%s) + 60 )); ( au glmark2-es2-wayland --fullscreen --run-forever >/dev/null 2>&1 & echo $! > $OUT/gl.pid; sleep 60; kill "$(cat $OUT/gl.pid)" ) &
    sleep 5; echo "loaded: $(st) state $(cat $c/cur_state)"
    echo 82000 > $z/emul_temp; sleep 2; echo "apollo 82 C: state $(cat $c/cur_state) $(st)"
    echo 87000 > $z/emul_temp; sleep 2; echo "apollo 87 C: state $(cat $c/cur_state) $(st)"
    echo 0 > $z/emul_temp; sleep 8; echo "released:    state $(cat $c/cur_state) $(st)"
    wait
    ;;
cap)
    free_range "$1"; echo "$(st)"
    ;;
*) echo "usage: precheck | load F | step F MIN | storm CAP MIN | throttle CAP | cap CAP" >&2; exit 2 ;;
esac
