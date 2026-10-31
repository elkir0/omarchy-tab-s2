#!/bin/bash
# Daily image (no timer, no autotest) into RECOVERY, Omarchy selected again
# through rootfs.select, test files removed from /sdcard/linux, boot Linux.
set -u
D=$(dirname "$0")
R=$(cd "$(dirname "$0")/.." && pwd)
IMG=$R/out/test-recovery-daily/recovery.img
HEIMDALL=$R/src/heimdall/build/bin/heimdall
serial() { adb devices -l | awk '$2 == "device" && $1 !~ /:/ && /model:SM_T715/ {print $1}'; }
usb_android() {
    local s=
    for _ in $(seq 1 72); do s=$(serial); [ -n "$s" ] && break; sleep 5; done
    [ -n "$s" ] || { echo "android did not come up"; exit 1; }
    adb -s "$s" shell 'while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 2; done;
        for t in $(seq 1 30); do [ -f /sdcard/linux/rootfs.img ] && break; sleep 2; done; sleep 10'
}
leave_android() {
    local s=
    for t in 1 2 3; do
        for _ in $(seq 1 15); do s=$(serial); [ -n "$s" ] && break; sleep 2; done
        adb -s "$s" reboot "$1"; sleep 8
        [ -z "$(serial)" ] && { echo "left android for $1 (try $t) at $(date +%T)"; return 0; }
    done
    echo "adb reboot $1 ignored 3 times"; exit 1
}

if [ -z "$(serial)" ]; then
    "$D/tssh" 'systemctl reboot' 2>/dev/null; sleep 15
fi
usb_android; echo "android up at $(date +%T)"
adb -s "$(serial)" shell 'cd /sdcard/linux && rm -f t715-autotest.sh dmabuf-import-test vblank-wait tone1k.wav &&
    echo rootfs-omarchy.img > rootfs.select; sync; sleep 45; sync; echo "select: $(cat rootfs.select)"; ls'
leave_android download
for _ in $(seq 1 15); do "$HEIMDALL" detect >/dev/null 2>&1 && break; sleep 4; done
"$HEIMDALL" flash --RECOVERY "$IMG" 2>&1 | grep -E "RECOVERY|fail|rror" || exit 1
sleep 10
usb_android; echo "android up after flash at $(date +%T)"
leave_android recovery
T0=$(date +%s)
for _ in $(seq 1 80); do
    sleep 5
    "$D/tssh" true 2>/dev/null && { echo "ssh up after $(( $(date +%s) - T0 ))s"; break; }
done
"$D/tssh" 'uname -r; grep -E "rootfs.select|returnafter|autotest|knobs" /run/t715/initramfs.log | cut -c1-120; head -1 /etc/os-release; systemctl is-system-running'
