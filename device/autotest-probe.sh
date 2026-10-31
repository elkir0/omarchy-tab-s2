#!/bin/sh
# t715-autotest.sh, round "probe": read-only measurements for the display
# flicker, the DECON SysMMU pre-flight and the GPU baseline.  Restarts the
# board (back to Android) when done.
D=$(dirname "$0")
sec() { echo "== $*"; }
for _ in $(seq 1 90); do
    case $(systemctl is-system-running 2>/dev/null) in running | degraded) break ;; esac
    sleep 2
done
sleep 15
echo "AUTOTEST BEGIN probe2 $(uname -r) up=$(cut -d' ' -f1 /proc/uptime)"
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug

for b in dmabuf-import-test vblank-wait; do cp "$D/$b" /tmp/$b && chmod 0755 /tmp/$b; done
for n in /sys/class/drm/renderD* /sys/class/drm/card[0-9]; do
    drv=$(basename "$(readlink -f "$n/device/driver")")
    echo "drm node ${n##*/} driver $drv"
    case "${n##*/}:$drv" in
    renderD*:panfrost) ln -sfn "/dev/dri/${n##*/}" /tmp/t715-gpu ;;
    card*:exynos-drm) ln -sfn "/dev/dri/${n##*/}" /tmp/t715-kms ;;
    esac
done

sec dmabuf import baseline
/tmp/dmabuf-import-test; echo "exit $?"
echo "contiguously lines: $(dmesg | grep -c 'mapped contiguously')"

sec display clocks
awk 'NR>2 && $1 !~ /tv|hdmi|dsim1|phyclk|usbhost|spdif|trace|smies/ && $1 ~ /decon_eclk|decon_vclk|dsim0|aclk_disp|pclk_disp|bus_pll|mfc_pll|disp_pll|mif_pll|rgb_vclk/ {printf "clk %s en=%s rate=%s\n", $1, $2, $5}' \
    /sys/kernel/debug/clk/clk_summary | head -80

sec frame rate
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

sec 'DISP power domain, IOMMU pre-flight'
dmesg | grep -i 'power domain' | tail -5
cat /sys/kernel/debug/pm_genpd/DISP/idle_states 2>&1 | head -4
grep -A8 -E "^DISP" /sys/kernel/debug/pm_genpd/pm_genpd_summary 2>&1 | head -10

sec GPU baseline
dmesg | grep -iE "panfrost.*(clock|mali|features|AS_PRESENT)" | tail -4
for r in /sys/class/regulator/*; do
    [ "$(cat "$r/name" 2>/dev/null)" = vdd_g3d ] && echo "vdd_g3d $(cat "$r/microvolts" 2>/dev/null) uV"
done
awk 'NR>2 && $1 ~ /g3d/ {printf "clk %s en=%s rate=%s\n", $1, $2, $5}' /sys/kernel/debug/clk/clk_summary | head -12
for t in glmark2-es2-wayland glmark2-es2-drm glmark2-es2 kmscube eglgears_wayland es2gears_wayland es2gears weston-simple-egl vkcube gst-launch-1.0 mpv ffmpeg; do
    command -v $t >/dev/null 2>&1 && echo "tool $t"
done
cat /sys/class/thermal/thermal_zone*/type 2>/dev/null | tr '\n' ' '; echo
cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | tr '\n' ' '; echo

echo "AUTOTEST END"
sleep 3
systemctl reboot
