#!/bin/bash
# Flash a RECOVERY image on the SM-T715 and boot Linux from it.
# Usage: flash-boot.sh RECOVERY_IMG   (writes RECOVERY only)
set -u
IMG=$1
R=$(cd "$(dirname "$0")/.." && pwd)
HEIMDALL=$R/src/heimdall/build/bin/heimdall
TSSH=$(dirname "$0")/tssh
[ -f "$IMG" ] || [ "$IMG" = /dev/null ] || { echo "no image $IMG"; exit 2; }

serial() { adb devices -l | awk '$2 == "device" && $1 !~ /:/ && /model:SM_T715/ {print $1}'; }
wait_android() {
    local s=
    for _ in $(seq 1 72); do s=$(serial); [ -n "$s" ] && break; sleep 5; done
    [ -n "$s" ] || { echo "android did not come up"; exit 1; }
    adb -s "$s" shell 'while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 2; done;
        for t in $(seq 1 30); do [ -f /sdcard/linux/rootfs.img ] && break; sleep 2; done; sleep 10'
    echo "android ready"
}
leave_android() { # $1 = reboot target
    local s=
    for t in 1 2 3; do
        # adb drops for a few seconds while Android reconfigures USB
        for _ in $(seq 1 15); do s=$(serial); [ -n "$s" ] && break; sleep 2; done
        adb -s "$s" reboot "$1"; sleep 8
        [ -z "$(serial)" ] && { echo "left android for $1 (try $t)"; return 0; }
    done
    echo "adb reboot $1 ignored 3 times"; exit 1
}

if "$TSSH" true 2>/dev/null; then "$TSSH" 'systemctl reboot' 2>/dev/null; sleep 10; fi
wait_android
if [ "$IMG" = /dev/null ]; then  # reboot only, RECOVERY unchanged
    leave_android recovery
    T0=$(date +%s)
    for _ in $(seq 1 60); do
        sleep 5
        "$TSSH" true 2>/dev/null && { echo "linux ssh up after $(( $(date +%s) - T0 ))s"; exit 0; }
    done
    echo "no ssh after 300s"; exit 1
fi
leave_android download
for _ in $(seq 1 15); do "$HEIMDALL" detect >/dev/null 2>&1 && break; sleep 4; done
"$HEIMDALL" flash --RECOVERY "$IMG" 2>&1 | grep -E "RECOVERY|fail|rror" || exit 1
sleep 10
wait_android
leave_android recovery
T0=$(date +%s)
for _ in $(seq 1 60); do
    sleep 5
    "$TSSH" true 2>/dev/null && { echo "linux ssh up after $(( $(date +%s) - T0 ))s"; exit 0; }
done
echo "no ssh after 300s"; exit 1
