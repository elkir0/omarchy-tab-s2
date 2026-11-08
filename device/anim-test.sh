#!/bin/sh
# Drawer leak with Hyprland animations on.
B=/sys/kernel/debug/dma_buf/bufinfo
RUN=/run/user/1000
WL=$(ls $RUN | grep -E '^wayland-[0-9]+$' | head -1)
au() {
    SIG=$(ls -t $RUN/hypr | head -1)
    runuser -u alarm -- env XDG_RUNTIME_DIR=$RUN HYPRLAND_INSTANCE_SIGNATURE=$SIG WAYLAND_DISPLAY=$WL \
        DBUS_SESSION_BUS_ADDRESS=unix:path=$RUN/bus OMARCHY_PATH=/usr/share/omarchy "$@"
}
m() {
    echo "$(cut -d' ' -f1 /proc/uptime) $1: decon=$(grep -c '13800000.decon' $B)" \
        "drawer-size bufs=$(grep -cE '^0*12140544' $B) $(tail -1 $B | sed 's/Total //')" \
        "shmem=$(awk '/^Shmem:/ {print int($2/1024)}' /proc/meminfo)M"
}
echo "animations before: $(au hyprctl getoption animations:enabled 2>&1 | head -1)"
m start
au hyprctl eval "hl.config({ animations = { enabled = true } })" 2>&1 | head -2
echo "animations now: $(au hyprctl getoption animations:enabled 2>&1 | head -1)"
for i in 1 2 3 4 5; do
    au omarchy-shell shell toggle omamobile.launcher {} >/dev/null 2>&1; sleep 3
    au omarchy-shell shell hide omamobile.launcher >/dev/null 2>&1; sleep 3
done
sleep 5
m "after 5 launcher cycles, animations on"
# The image's animations follow the Battery saver (/run/t715-power/saver):
# restore that, not a fixed off.
if [ -e /run/t715-power/saver ]; then RESTORE=false; else RESTORE=true; fi
au hyprctl eval "hl.config({ animations = { enabled = $RESTORE } })" 2>&1 | head -2
echo "animations back as the saver says: $(au hyprctl getoption animations:enabled 2>&1 | head -1)"
echo "shell restarts: $(journalctl -b --since '-1min' --no-pager | grep -c relaunching)"
