#!/bin/bash
# Run t715-autotest.sh on the tablet through the t715.autotest knob.
# Usage: autotest-run.sh [RECOVERY_IMG]   (no image: RECOVERY unchanged)
# Needs the tablet on Android (waits for it).  Prints the AUTOTEST lines of
# the Linux boot, read back from /proc/last_kmsg.
set -u
D=$(dirname "$0")
IMG=${1:-}
R=$(cd "$(dirname "$0")/.." && pwd)
HEIMDALL=$R/src/heimdall/build/bin/heimdall
OUT=${T715_PRIVATE:-$HOME/t715-private}/boottests
serial() { adb devices -l | awk '$2 == "device" && $1 !~ /:/ && /model:SM_T715/ {print $1}'; }
wait_android() {
    local s=
    for _ in $(seq 1 ${1:-360}); do s=$(serial); [ -n "$s" ] && break; sleep 5; done
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

wait_android; echo "android ready at $(date +%T)"
S=$(serial)
# SCRIPT: the test script (pushed as t715-autotest.sh); EXTRA: more files.
adb -s "$S" push "${SCRIPT:-$D/t715-autotest.sh}" /sdcard/linux/t715-autotest.sh >/dev/null || { echo "push failed"; exit 1; }
for f in $D/tone1k.wav ${EXTRA:-}; do
    adb -s "$S" push "$f" /sdcard/linux/ >/dev/null || { echo "push $f failed"; exit 1; }
done
adb -s "$S" shell 'cd /sdcard/linux && rm -f rootfs.select && md5sum t715-autotest.sh | cut -c1-12; sync; sleep 45; sync'
if [ -n "$IMG" ]; then
    leave_android download
    for _ in $(seq 1 15); do "$HEIMDALL" detect >/dev/null 2>&1 && break; sleep 4; done
    "$HEIMDALL" flash --RECOVERY "$IMG" 2>&1 | grep -E "RECOVERY|fail|rror" || exit 1
    sleep 10
    wait_android
fi
leave_android recovery
# The script restarts the board when done; returnafter is the safety net.
sleep 60
wait_android 420
echo "back on android at $(date +%T)"
F=$OUT/last_kmsg_autotest_$(date +%H%M).txt
adb -s "$(serial)" shell cat /proc/last_kmsg >"$F"
echo "log: $F ($(wc -l <"$F") lines)"
grep -E "t715-autotest|t715-initramfs: (t715\.|knobs|modules)" "$F" | sed -E 's/^\[[ 0-9.]+\] //; s/t715-autotest\[[0-9]+\]: //' |
    sed -E 's/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/XX:XX/g'
