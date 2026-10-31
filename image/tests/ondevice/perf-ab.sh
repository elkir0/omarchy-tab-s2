#!/usr/bin/env bash
# perf-ab.sh: measurements for the Omarchy performance A/B tests on the SM-T715.
# Runs as root ON THE TABLET, fed over SSH like tests/ondevice/omarchy-probe.sh:
#   ssh root@172.16.42.1 'bash -s' -- facts      < tests/ondevice/perf-ab.sh
#   ssh root@172.16.42.1 'bash -s' -- load 30    < tests/ondevice/perf-ab.sh   # while someone uses the screen
#   ssh root@172.16.42.1 'bash -s' -- cost quickshell 'omarchy-shell shell toggle omarchy.menu "{\"menu\":\"root\"}"' < tests/ondevice/perf-ab.sh
# Read-only apart from debugfs mount and panfrost's profiling switch (both reset at reboot).
set -uo pipefail
export LC_ALL=C
U=alarm; RUN=/run/user/$(id -u $U)
as_user() { runuser -u $U -- env XDG_RUNTIME_DIR=$RUN WAYLAND_DISPLAY=$(ls $RUN | grep -m1 -E '^wayland-[0-9]+$') \
    HYPRLAND_INSTANCE_SIGNATURE=$(ls -t $RUN/hypr | head -1) OMARCHY_PATH=/usr/share/omarchy PATH=/usr/share/omarchy/bin:/usr/bin "$@"; }
GPU=/sys/bus/platform/devices/14ac0000.gpu

facts() {
    mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
    echo "== clocks (Hz) actually programmed by sboot: CPU clusters, GPU, memory/bus"
    grep -iE 'apollo|atlas|g3d|mif|mem[01]_pll|bus_pll|aclk_bus' /sys/kernel/debug/clk/clk_summary | awk '{print $1, $(NF-4)}' | head -30
    echo "== timer resolution (10000000 ns = HZ=100 without HIGH_RES_TIMERS)"
    awk '/resolution/ {print; exit}' /proc/timer_list
    echo "== cpufreq / devfreq"; ls /sys/devices/system/cpu/cpu0/cpufreq 2>&1 | head -2; ls /sys/class/devfreq
    echo "== swap, overlay RAM"; swapon --show; grep -E 'MemAvailable|Shmem:|SwapFree' /proc/meminfo; df -m /run/t715/rw 2>/dev/null
    echo "== Qt render loop of the shell"; tr '\0' '\n' < /proc/$(pgrep -xo quickshell)/environ | grep -E '^QSG_|^QT_QUICK' || echo "(default: threaded)"
    echo "== Hyprland opacity of the active window"; for pr in opacity alpha; do as_user hyprctl getprop activewindow $pr 2>&1 | head -1; done
    echo "== caches (lost each boot unless baked)"; du -sh /home/$U/.cache/mesa_shader_cache* /home/$U/.cache/omarchy/image-selector 2>/dev/null
}

# The fdinfo files of every panfrost DRM file descriptor. Scanning every fdinfo
# of every process each second cost the tablet seconds of CPU once Firefox ran
#: list them once (gpu_scan), then read only those (gpu_ns).
GPU_FILES=()
gpu_scan() {
    local fd
    GPU_FILES=()
    for fd in /proc/[0-9]*/fd/*; do
        case "$(readlink "$fd" 2>/dev/null)" in /dev/dri/*) ;; *) continue ;; esac
        grep -qs 'drm-driver:.panfrost' "${fd/\/fd\//\/fdinfo\/}" && GPU_FILES+=("${fd/\/fd\//\/fdinfo\/}")
    done
}
# Sum of panfrost fragment + vertex/tiler time over those clients, deduplicated by client id.
gpu_ns() {
    [ ${#GPU_FILES[@]} -gt 0 ] || { echo 0; return; }
    awk 'FNR == 1 && id != "" {print id, s; id = ""; s = 0}
         /drm-client-id/ {id = $2} /drm-engine-(fragment|vertex-tiler)/ {s += $2}
         END {if (id != "") print id, s}' "${GPU_FILES[@]}" 2>/dev/null \
        | sort -u -k1,1 | awk '{s += $2} END {print s + 0}'
}
# FPS proxy as in ONDEVICE-2026-10-28.md: wakeups of Hyprland's busiest non-main
# thread (the DRM commit thread); DECON IRQs tick at 60 Hz even when idle.
# Prints "tid:switches" per non-main thread; frames() takes the max delta.
thr() { local h; h=$(pgrep -xo Hyprland); for t in /proc/$h/task/*; do [ "${t##*/}" = "$h" ] && continue
    echo "${t##*/}:$(awk '/^voluntary_ctxt_switches/ {print $2}' $t/status)"; done; }
frames() { join -t: <(sort <<<"$1") <(sort <<<"$2") | awk -F: '{d=$3-$2; if (d>m) m=d} END {print m+0}'; }
ticks() { local s=0 p; for p in $(pgrep -x "$1"); do s=$((s + $(awk '{print $14+$15}' /proc/$p/stat))); done; echo $s; }

# Rates are per real second (each sample measures its own interval), so a slow
# sample does not inflate them. The GPU client list is refreshed every 10 s.
load() {
    echo 1 > $GPU/profiling
    local n=${1:-30} g0 g1 f0 f1 h0 h1 q0 q1 t0 t1 ms
    echo "t  frames/s  gpu_frag+vt%  hypr%  qs%  memavail_MiB"
    gpu_scan
    g0=$(gpu_ns); f0=$(thr); h0=$(ticks Hyprland); q0=$(ticks quickshell); t0=$(date +%s%N)
    for ((i = 1; i <= n; i++)); do
        sleep 1
        g1=$(gpu_ns); f1=$(thr); h1=$(ticks Hyprland); q1=$(ticks quickshell); t1=$(date +%s%N)
        ms=$(( (t1 - t0) / 1000000 )); [ "$ms" -gt 0 ] || ms=1
        printf '%-3s %-9s %-10s %-6s %-4s %s\n' $i \
            $(( $(frames "$f0" "$f1") * 1000 / ms )) $(( (g1 - g0) / 10000 / ms )) \
            $(( (h1 - h0) * 1000 / ms )) $(( (q1 - q0) * 1000 / ms )) \
            $(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
        g0=$g1; f0=$f1; h0=$h1; q0=$q1; t0=$t1
        # New GPU clients (an app just opened): rescan, new baseline.
        if [ $((i % 10)) -eq 0 ]; then gpu_scan; g0=$(gpu_ns); fi
    done
}

# CPU seconds a process spends on one action, and wall time of the action itself.
cost() {
    local p=$1; shift; local t0 t1 a b
    t0=$(ticks "$p"); a=$(date +%s%N)
    as_user bash -c "$*" >/dev/null 2>&1
    sleep 3; t1=$(ticks "$p"); b=$(date +%s%N)
    echo "$p: $(( (t1 - t0) * 10 )) ms CPU over $(( (b - a) / 1000000 - 3000 )) ms + 3 s settle"
}

cmd=${1:-facts}; shift || true
case $cmd in facts|load|cost) $cmd "$@" ;; *) echo "usage: facts | load [N] | cost <proc> <command>" >&2; exit 2 ;; esac
