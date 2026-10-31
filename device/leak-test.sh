#!/bin/sh
# dma-buf leak through exynos-drm: count the buffers
# then 5 drawer open/close cycles and 5 quick-settings toggles.
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
m() {
    echo "$(cut -d' ' -f1 /proc/uptime) $1: decon=$(grep -c '13800000.decon' $B) gpu=$(grep -c '14ac0000.gpu' $B)" \
        "$(tail -1 $B | sed 's/Total //') shmem=$(awk '/^Shmem:/ {print int($2/1024)}' /proc/meminfo)M" \
        "unevict=$(awk '/^Unevictable:/ {print int($2/1024)}' /proc/meminfo)M avail=$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo)M"
}
m start
pkill -x foot; pkill -f /usr/lib/firefox/firefox; sleep 8
echo "firefox left: $(pgrep -fc /usr/lib/firefox)"
m "firefox+foot closed"
systemctl restart sddm
for _ in $(seq 1 60); do pgrep -x Hyprland >/dev/null && pgrep quickshell >/dev/null && break; sleep 2; done
sleep 25
m "session restarted"
WL=$(ls $RUN | grep -E '^wayland-[0-9]+$' | head -1)
echo "wayland socket: $WL"
cycle quicksettings
cycle switcher
cycle launcher
echo "shell restarts since session start: $(journalctl -b --since '-3min' --no-pager | grep -c 'relaunching')"
