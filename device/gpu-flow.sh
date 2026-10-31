#!/bin/bash
# GPU devfreq test on Phosh (t715.rootimg knob, rootfs.select untouched),
# then the daily image back into RECOVERY and a boot into Omarchy.
# Needs the tablet on Android and out/mainline-gpufreq built.
set -u
D=$(dirname "$0")
R=$(cd "$(dirname "$0")/.." && pwd)
HEIMDALL=$R/src/heimdall/build/bin/heimdall
OUT=${T715_PRIVATE:-$HOME/t715-private}/boottests
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
flash() {
    leave_android download
    for _ in $(seq 1 15); do "$HEIMDALL" detect >/dev/null 2>&1 && break; sleep 4; done
    "$HEIMDALL" flash --RECOVERY "$1" 2>&1 | grep -E "RECOVERY|fail|rror" || exit 1
    sleep 10
    usb_android; echo "android up after flash at $(date +%T)"
}
wait_ssh() {
    local t0=$(date +%s)
    for _ in $(seq 1 80); do
        sleep 5
        "$D/tssh" true 2>/dev/null && { echo "ssh up after $(( $(date +%s) - t0 ))s"; return 0; }
    done
    echo "no ssh"; return 1
}

cd "$R" || exit 1
bash boot/build-initramfs.sh --out out/initramfs-gpu \
    --knobs "t715.usbfn=ecm t715.failwait=300 t715.returnafter=2700 t715.rootimg=media/0/linux/rootfs.img" \
    --modules out/mainline-gpufreq/modules.tar.xz 2>&1 | grep -E "cpio.gz:|rror"
bash boot/pack-test-recovery.sh --initramfs out/initramfs-gpu/initramfs.cpio.gz \
    --out out/test-recovery-gpu out/mainline-gpufreq exynos5433-gts28ltexx-gpufreqtest.dtb 2>&1 | grep -E "recovery.img|rror"
[ -s out/test-recovery-gpu/recovery.img ] || { echo "no gpu image"; exit 1; }

usb_android; echo "android up at $(date +%T)"
flash out/test-recovery-gpu/recovery.img
leave_android recovery
wait_ssh || exit 1
"$D/tssh" 'uname -r; head -1 /etc/os-release; grep -E "knobs|rootfs.select|root image" /run/t715/initramfs.log | cut -c1-140'
"$D/tssh" 'cat >/tmp/gpu.sh' <"$D/gpu-ssh.sh"
F=$OUT/gputest_$(date +%H%M).txt
ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@172.16.42.1 'sh /tmp/gpu.sh' 2>&1 | sed -E 's/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/XX:XX/g' | tee "$F"
grep -q "GPUTEST END" "$F" || { echo "GPU test did not finish; the returnafter timer brings the tablet back to Android"; exit 1; }
"$D/tssh" 'dmesg' >"$OUT/gputest_dmesg_$(date +%H%M).txt" 2>/dev/null
echo "log: $F"

"$D/tssh" 'systemctl reboot' 2>/dev/null; sleep 15
usb_android; echo "android up at $(date +%T)"
flash out/test-recovery-daily/recovery.img
leave_android recovery
wait_ssh || exit 1
"$D/tssh" 'uname -r; head -1 /etc/os-release; grep -E "knobs|rootfs.select" /run/t715/initramfs.log | cut -c1-140; systemctl is-system-running; ls -la /usr/lib/firmware/brcm/brcmfmac4358-pcie.bin 2>&1 | cut -c1-80'
