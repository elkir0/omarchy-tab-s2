#!/usr/bin/env bash
# uibench.sh — cost of opening the touch shell's panels, run as root ON THE
# TABLET over SSH:  ssh root@172.16.42.1 'bash -s' -- LABEL < tests/ondevice/uibench.sh
# uibench.sh LABEL: 5 open/close cycles of the drawer, quick settings and
# recents; per open: panel frames in the 1.2 s after the IPC call, and the
# CPU (ms) and GPU (ms, fragment + vertex) spent by quickshell and Hyprland.
export LC_ALL=C
LABEL=${1:-run}
RUN=/run/user/1000
au() { runuser -u alarm -- env LANG=fr_FR.UTF-8 XDG_RUNTIME_DIR=$RUN HYPRLAND_INSTANCE_SIGNATURE=$(ls -t $RUN/hypr | head -1) WAYLAND_DISPLAY=wayland-1 DBUS_SESSION_BUS_ADDRESS=unix:path=$RUN/bus OMARCHY_PATH=/usr/share/omarchy "$@"; }
decon() { awk '/drm_decon/ { for (i = 2; i <= NF && $i ~ /^[0-9]+$/; i++) s += $i } END { print s + 0 }' /proc/interrupts; }
cpu_ms() { awk -v hz="$(getconf CLK_TCK)" '{ print int(($14 + $15) * 1000 / hz) }' "/proc/$1/stat" 2>/dev/null || echo 0; }
# GPU ns of one process's own panfrost clients (max per client id: fds are shared).
gpu_ns() { for f in /proc/$1/fdinfo/*; do grep -qs 'drm-driver:.panfrost' "$f" || continue; awk '/drm-client-id/ {id=$2} /drm-engine-/ {s+=$2} END {print id, s}' "$f"; done | sort -k1,1 -k2,2n | awk '{m[$1]=$2} END {for (k in m) t+=m[k]; print t+0}'; }
q=$(pgrep -n -u alarm -x quickshell); h=$(pgrep -xo Hyprland)
for p in omamobile.launcher omamobile.quicksettings omamobile.switcher; do
  fr=0; qc=0; hc=0; qg=0; hg=0
  for i in 1 2 3 4 5; do
    d0=$(decon); a0=$(cpu_ms $q); b0=$(cpu_ms $h); g0=$(gpu_ns $q); k0=$(gpu_ns $h)
    au omarchy-shell shell toggle $p {} >/dev/null 2>&1; sleep 1.2
    d1=$(decon); a1=$(cpu_ms $q); b1=$(cpu_ms $h); g1=$(gpu_ns $q); k1=$(gpu_ns $h)
    fr=$((fr + d1 - d0)); qc=$((qc + a1 - a0)); hc=$((hc + b1 - b0)); qg=$((qg + (g1 - g0) / 1000000)); hg=$((hg + (k1 - k0) / 1000000))
    au omarchy-shell shell hide $p >/dev/null 2>&1; sleep 1.5
  done
  printf '%-10s %-26s open: %5.1f frames  qs cpu %5d ms  hypr cpu %4d ms  qs gpu %5d ms  hypr gpu %4d ms (means of 5)\n' \
    "$LABEL" "$p" "$(awk -v f=$fr "BEGIN { print f / 5 }")" $((qc / 5)) $((hc / 5)) $((qg / 5)) $((hg / 5))
done
