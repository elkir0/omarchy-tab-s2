#!/bin/sh
# t715-autotest.sh, round "iommu": DECON System MMU kernel (docs/hardware/IOMMU.md
# section 10.2/10.3).  Restarts the board (back to Android) when done.
D=$(dirname "$0")
sec() { echo "== $*"; }
# Measure soon after Phosh is up: the session blanks the panel (DISP off)
# after 5 min idle.
for _ in $(seq 1 60); do
    [ "$(systemctl is-active phosh 2>/dev/null)" = active ] && break
    sleep 2
done
sleep 20
echo "AUTOTEST BEGIN iommu $(uname -r) state=$(systemctl is-system-running) up=$(cut -d' ' -f1 /proc/uptime)"
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug

sec 'sysmmu and attach messages'
dmesg | grep -iE "sysmmu|iommu|DMA mapping|contiguously|PAGE FAULT|MMU Fault" | grep -vE "saving state|restoring state" | tail -20
echo "save/restore lines: $(dmesg | grep -cE 'saving state|restoring state')"
ls /sys/class/iommu/ 2>&1 | tr '\n' ' '; echo
for g in /sys/kernel/iommu_groups/*; do
    [ -d "$g" ] && echo "group ${g##*/} type $(cat "$g/type" 2>/dev/null) devices $(ls "$g/devices" | tr '\n' ' ')"
done

for b in dmabuf-import-test vblank-wait; do cp "$D/$b" /tmp/$b && chmod 0755 /tmp/$b; done
for n in /sys/class/drm/renderD* /sys/class/drm/card[0-9]; do
    drv=$(basename "$(readlink -f "$n/device/driver")")
    case "${n##*/}:$drv" in
    renderD*:panfrost) ln -sfn "/dev/dri/${n##*/}" /tmp/t715-gpu ;;
    card*:exynos-drm) ln -sfn "/dev/dri/${n##*/}" /tmp/t715-kms ;;
    esac
done

sec 'display'
systemctl is-active phosh | sed 's/^/phosh /'
irq() { grep -E "decon|dsi" /proc/interrupts | awk '{s=0; for(i=2;i<=9;i++) s+=$i; print $NF, s}'; }
/tmp/vblank-wait >/tmp/vw.out 2>&1 &
VW=$!
sleep 2
t1=$(cut -d' ' -f1 /proc/uptime); irq >/tmp/i1
sleep 6
t2=$(cut -d' ' -f1 /proc/uptime); irq >/tmp/i2
wait $VW; cat /tmp/vw.out
paste /tmp/i1 /tmp/i2 | awk -v t1="$t1" -v t2="$t2" '{printf "irq %s %.2f/s\n", $1, ($4-$2)/(t2-t1)}'
echo "vblank timeouts: $(dmesg | grep -cE 'vblank wait timed out|flip_done timed out')"

sec 'non-contiguous import'
/tmp/dmabuf-import-test; echo "exit $?"
for i in 1 2 3 4 5; do /tmp/dmabuf-import-test >/dev/null; printf "%s " $?; done; echo "(5 more imports)"
echo "contiguously lines: $(dmesg | grep -c 'mapped contiguously')"
dmesg | grep -iE "PAGE FAULT|MMU Fault|iommu.*fail" | tail -5

sec summary
systemctl is-active phosh NetworkManager bluetooth | tr '\n' ' '; echo
echo "failed units: $(systemctl --failed --no-legend --plain | wc -l)"
echo "kernel warnings: $(dmesg | grep -cE 'WARNING:|BUG:|Oops')"
echo "AUTOTEST END"
sleep 3
systemctl reboot
