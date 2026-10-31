#!/bin/sh
# dma-buf leak through exynos-drm: count the buffers
# attached to DECON around each action.  Runs as root over SSH.
# Variant for a kernel without the DECON SysMMU: no decon attachments
# there, so watch Shmem/Unevictable and Hyprland's panfrost memory.
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
B=/sys/kernel/debug/dma_buf/bufinfo
RUN=/run/user/1000
au() {
    SIG=$(ls -t $RUN/hypr | head -1)
    runuser -u alarm -- env XDG_RUNTIME_DIR=$RUN HYPRLAND_INSTANCE_SIGNATURE=$SIG WAYLAND_DISPLAY=$WL \
        DBUS_SESSION_BUS_ADDRESS=unix:path=$RUN/bus OMARCHY_PATH=/usr/share/omarchy "$@"
}
# cycle NAME: open and close one omarchy-shell panel 5 times
cycle() {
    for i in 1 2 3 4 5; do
        au omarchy-shell shell toggle omamobile.$1 {} >/dev/null 2>&1; sleep 3
        au omarchy-shell shell hide omamobile.$1 >/dev/null 2>&1; sleep 3
    done
    sleep 5
    m "after 5 $1 cycles"
}
# Hyprland's panfrost resident memory, summed over its render-node fds
hr() {
    p=$(pgrep -x Hyprland); t=0
    for f in /proc/$p/fdinfo/*; do
        v=$(awk '/^drm-resident-memory:/ {print $2}' $f 2>/dev/null); [ -n "$v" ] && t=$((t + v))
    done
    echo $t
}
m() {
    echo "$(cut -d' ' -f1 /proc/uptime) $1: decon=$(grep -c '13800000.decon' $B) gpu=$(grep -c '14ac0000.gpu' $B)" \
        "$(tail -1 $B | sed 's/Total //') shmem=$(awk '/^Shmem:/ {print int($2/1024)}' /proc/meminfo)M" \
        "unevict=$(awk '/^Unevictable:/ {print int($2/1024)}' /proc/meminfo)M avail=$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo)M" \
        "hypr_panfrost_resident=$(hr)K"
}
for _ in $(seq 1 60); do pgrep -x Hyprland >/dev/null && pgrep quickshell >/dev/null && break; sleep 2; done
sleep 25
m start
WL=$(ls $RUN | grep -E '^wayland-[0-9]+$' | head -1)
echo "wayland socket: $WL"
cycle quicksettings
cycle switcher
cycle launcher
echo "shell restarts since session start: $(journalctl -b --since '-3min' --no-pager | grep -c 'relaunching')"
