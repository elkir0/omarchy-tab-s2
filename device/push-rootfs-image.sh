#!/bin/bash
# Replace a root image in /sdcard/linux from Android over Wi-Fi ADB, then
# boot Linux (whatever RECOVERY holds).  The image is gzip -1 compressed on
# the Mac, pushed as NAME.new.gz, decompressed and md5-checked on Android,
# then renamed over NAME.  With --select, rootfs.select is set to NAME.
# Usage: push-rootfs-image.sh [--select] IMAGE NAME MD5
#   e.g. push-rootfs-image.sh --select out/rootfs-omarchy.img rootfs-omarchy.img <md5>
# Env: T715_ADB_WIFI (tablet ip:port, required),
#      T715_GZ_DIR (where the .gz is kept, default $TMPDIR).
# Never writes anything but /sdcard/linux (USERDATA).  The tablet's Wi-Fi
# ADB needs it on the same network; see docs for the 60 s post-boot wait.
set -u
D=$(dirname "$0")
SELECT=0
[ "${1:-}" = --select ] && { SELECT=1; shift; }
[ $# -eq 3 ] || { sed -n '2,11p' "$0"; exit 2; }
SRC=$1 NAME=$2 SUM=$3
case $NAME in .* | *[!A-Za-z0-9._-]*) echo "bad NAME"; exit 2 ;; *.img) ;; *) echo "NAME must end in .img"; exit 2 ;; esac
GZ=${T715_GZ_DIR:-${TMPDIR:-/tmp}}/$NAME-$SUM.gz
W=${T715_ADB_WIFI:?set T715_ADB_WIFI to the tablet ip:5555}
[ "$(md5 -q "$SRC" 2>/dev/null || md5sum "$SRC" | cut -d' ' -f1)" = "$SUM" ] || { echo "md5 of $SRC does not match"; exit 1; }
serial() { adb devices -l | awk '$2 == "device" && $1 !~ /:/ && /model:SM_T715/ {print $1}'; }
usb_android() {
    local s=
    for _ in $(seq 1 72); do s=$(serial); [ -n "$s" ] && break; sleep 5; done
    [ -n "$s" ] || { echo "android did not come up"; exit 1; }
    adb -s "$s" shell 'while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 2; done;
        for t in $(seq 1 30); do [ -f /sdcard/linux/rootfs.img ] && break; sleep 2; done; sleep 10'
}

if [ ! -s "$GZ" ]; then
    gzip -1 -c "$SRC" >"$GZ.part" && mv "$GZ.part" "$GZ" || { echo "gzip failed"; exit 1; }
fi
echo "compressed: $(stat -f %z "$GZ") bytes at $(date +%T)"

[ -n "$(serial)" ] || { "$D/tssh" 'systemctl reboot' 2>/dev/null; sleep 15; }
usb_android; echo "android up at $(date +%T)"
sleep 60   # post-boot load
adb -s "$(serial)" tcpip 5555 >/dev/null; sleep 6
adb connect "$W" | tail -1
adb -s "$W" shell 'df -h /sdcard | tail -1'

want=$(stat -f %z "$GZ")
adb -s "$W" shell "rm -f /sdcard/linux/$NAME.new.gz /sdcard/linux/$NAME.new"
for t in 1 2 3; do
    adb connect "$W" >/dev/null 2>&1
    adb -s "$W" push "$GZ" /sdcard/linux/$NAME.new.gz 2>&1 | tail -1
    got=$(adb -s "$W" shell stat -c %s /sdcard/linux/$NAME.new.gz 2>/dev/null | tr -d '\r')
    [ "$got" = "$want" ] && break
    echo "push incomplete ($got of $want), retrying"; sleep 10
done
[ "$got" = "$want" ] || { echo "push failed"; exit 1; }
got=$(adb -s "$W" shell "cd /sdcard/linux && gzip -d $NAME.new.gz && md5sum $NAME.new" | cut -d' ' -f1)
[ "$got" = "$SUM" ] || { echo "md5 mismatch: $got"; exit 1; }
SEL=; [ $SELECT = 1 ] && SEL="echo $NAME > rootfs.select;"
adb -s "$W" shell "cd /sdcard/linux && mv $NAME.new $NAME && $SEL
    sync; sleep 45; sync; echo \"select: \$(cat rootfs.select 2>/dev/null)\"; ls -la | grep -E 'img|select'"
adb disconnect "$W" >/dev/null 2>&1
echo "$NAME replaced (md5 ok) at $(date +%T)"
# Boot Linux again from RECOVERY
for _ in 1 2 3; do
    s=$(serial); [ -n "$s" ] || { sleep 5; continue; }
    adb -s "$s" reboot recovery; sleep 8; [ -z "$(serial)" ] && break
done
T0=$(date +%s)
for _ in $(seq 1 80); do
    sleep 5
    "$D/tssh" true 2>/dev/null && { echo "ssh up after $(( $(date +%s) - T0 ))s"; break; }
done
"$D/tssh" 'uname -r; head -1 /etc/os-release; grep -E "rootfs.select" /run/t715/initramfs.log | cut -c1-100; systemctl is-system-running; readlink /etc/localtime'
