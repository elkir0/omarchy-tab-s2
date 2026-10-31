#!/bin/sh
# t715-autotest.sh: run by t715-autotest.service (initramfs knob
# t715.autotest=1) from /sdcard/linux/.  Prints test results to the journal
# (forwarded to the kernel log, read back from Android in /proc/last_kmsg),
# then restarts the board, which boots Android.  Prints no serial numbers,
# CIDs or addresses.
D=/tmp
sec() { echo "== $*"; }

# Wait for the boot to finish (this unit is Type=simple, so it does not
# hold the boot), then let the session settle.
for _ in $(seq 1 60); do
    [ "$(systemctl is-active phosh 2>/dev/null)" = active ] && break
    sleep 2
done
sleep 1
echo "AUTOTEST BEGIN final $(uname -r) state=$(systemctl is-system-running) up=$(cut -d' ' -f1 /proc/uptime)"

sec timers
grep -m1 -E "^ *\.resolution" /proc/timer_list
zcat /proc/config.gz 2>/dev/null | grep -E "^CONFIG_(HZ|PREEMPT|NO_HZ_IDLE|HIGH_RES_TIMERS|SCHED_MC)=" | tr '\n' ' '; echo
echo "cpu capacity: $(cat /sys/devices/system/cpu/cpu0/cpu_capacity) $(cat /sys/devices/system/cpu/cpu4/cpu_capacity)"

sec display
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
for b in dmabuf-import-test vblank-wait; do cp "$D/$b" /tmp/$b && chmod 0755 /tmp/$b; done
for n in /sys/class/drm/renderD* /sys/class/drm/card[0-9]; do
    drv=$(basename "$(readlink -f "$n/device/driver")")
    case "${n##*/}:$drv" in
    renderD*:panfrost) ln -sfn "/dev/dri/${n##*/}" /tmp/t715-gpu ;;
    card*:exynos-drm) ln -sfn "/dev/dri/${n##*/}" /tmp/t715-kms ;;
    esac
done
awk 'NR>2 && $1 ~ /^(fout_disp_pll|sclk_decon_vclk|sclk_decon_eclk|sclk_dsim0)$/ {printf "clk %s rate=%s\n", $1, $5}' /sys/kernel/debug/clk/clk_summary
irqsum() { grep -E "drm_decon" /proc/interrupts | awk '{s=0; for(i=2;i<=9;i++) s+=$i; t+=s} END {print t}'; }
/tmp/vblank-wait >/tmp/vw.out 2>&1 &
VW=$!
sleep 2
t1=$(cut -d' ' -f1 /proc/uptime); i1=$(irqsum)
sleep 6
t2=$(cut -d' ' -f1 /proc/uptime); i2=$(irqsum)
wait $VW
echo "frame rate: $(tr -d '\n' </tmp/vw.out) decon $(awk -v a="$i1" -v b="$i2" -v t1="$t1" -v t2="$t2" 'BEGIN {printf "%.2f", (b-a)/(t2-t1)}')/s"
echo "vblank timeouts: $(dmesg | grep -cE 'vblank wait timed out|flip_done timed out')"
sec iommu
dmesg | grep -E "exynos-sysmmu|Adding to iommu group|DMA mapping operations" | sed 's/^\[[ 0-9.]*\] //'
/tmp/dmabuf-import-test | tail -1
echo "contiguously lines: $(dmesg | grep -c 'mapped contiguously') faults: $(dmesg | grep -ciE 'PAGE FAULT|MMU Fault')"

sec services
systemctl is-active phosh NetworkManager bluetooth | tr '\n' ' '; echo
systemctl --failed --no-legend --plain | head -5
W=$(ls /sys/class/net | grep -E "^wl" | head -1)
echo "wifi $W $(nmcli -t -f DEVICE,STATE device 2>/dev/null | grep "^$W:" | cut -d: -f2)"
ip link set "$W" up 2>/dev/null; sleep 3; echo "wifi networks: $(iw dev "$W" scan 2>/dev/null | grep -c '^BSS ')"
echo "bt $(bluetoothctl show 2>/dev/null | grep -m1 Powered | tr -d '\t')"
echo "usb0: $(cat /sys/class/net/usb0/operstate 2>/dev/null) carrier=$(cat /sys/class/net/usb0/carrier 2>/dev/null)"

sec audio
dmesg | grep -iE "arizona|wm1814|wm8998|i2s|fll" | grep -iE "err|fail|revision|timed|underclock|dropped" | tail -6
cat /proc/asound/cards
echo "ucm verbs: $(alsaucm -c hw:0 list _verbs 2>&1 | tr '\n' ' ')"
echo "ucm devices: $(alsaucm -c hw:0 set _verb HiFi list _devices 2>&1 | tr '\n' ' ')"
systemctl --user -M alarm@ stop pipewire.socket pipewire-pulse.socket wireplumber pipewire pipewire-pulse >/dev/null 2>&1
sleep 1
alsaucm -c hw:0 set _verb HiFi set _enadev Speaker set _enadev Mic 2>&1 | tail -2
amixer -c wm1814 cset name='Speaker Digital Volume' 96 >/dev/null 2>&1
for c in 'SPKOUTL Input 1' 'SPK Switch' 'Speaker Digital Switch' 'IN1L Mux' 'AIF1TX1 Input 1' 'Main Mic Switch'; do
    echo "ctl $c = $(amixer -c wm1814 cget name="$c" 2>&1 | grep -m1 ': values=' | sed 's/.*values=//')"
done
TONE=/tmp/tone1k.wav
arecord -D hw:wm1814,0 -c 2 -r 48000 -f S16_LE -d 2 /tmp/rec.wav 2>/tmp/arec.err &
sleep 0.4
timeout 5 aplay -D hw:wm1814,0 "$TONE" 2>&1 | tail -2
wait
tail -2 /tmp/arec.err
echo "rec bytes $(stat -c %s /tmp/rec.wav 2>/dev/null)"
# Left channel, 16-bit LE, 44-byte header: RMS of the tone window
# (0.6-1.3 s) and of the tail (1.6-2.0 s), and a Goertzel at 500/1000/1500 Hz.
od -An -v -t d2 -w4 -j 44 /tmp/rec.wav 2>/dev/null | awk '
function g(f,   k,a,b,t,i,n) { k=2*cos(2*3.14159265*f/48000); a=0; b=0; n=0
    for (i=28800; i<62400; i++) { t=x[i]+k*a-b; b=a; a=t; n++ }
    return sqrt(a*a+b*b-k*a*b)/n }
{ x[NR-1]=$1 }
END { s1=0; n1=0; s2=0; n2=0
    for (i=28800; i<62400; i++) { s1+=x[i]*x[i]; n1++ }
    for (i=76800; i<NR; i++) { s2+=x[i]*x[i]; n2++ }
    printf "loopback frames=%d rms_tone=%.0f rms_tail=%.0f g500=%.1f g1000=%.1f g1500=%.1f\n",
        NR, sqrt(s1/(n1?n1:1)), sqrt(s2/(n2?n2:1)), g(500), g(1000), g(1500) }'
dmesg | grep -iE "arizona|wm8998|i2s|pl330" | grep -iE "err|fail|timed|underclock|dropped" | tail -4
systemctl --user -M alarm@ start pipewire.socket pipewire-pulse.socket pipewire pipewire-pulse wireplumber >/dev/null 2>&1

sec battery
modprobe sm5703_fuel_gauge; sleep 2
dmesg | grep -i sm5703 | tail -3
grep -E "STATUS|CAPACITY|VOLTAGE|CURRENT|TEMP|PRESENT" /sys/class/power_supply/sm5703-fuelgauge/uevent 2>&1 | tr '\n' ' '; echo
sleep 5; echo "upower: $(upower -e 2>/dev/null | tr '\n' ' ')"
upower -i "$(upower -e 2>/dev/null | grep -m1 battery)" 2>/dev/null | grep -E "percentage|state|energy-rate" | tr -s ' ' | tr '\n' ';'; echo

sec sensors
modprobe st_lsm6dsx_i2c; modprobe yamaha_yas530; sleep 3
dmesg | grep -iE "lsm6|yas5|st_lsm" | tail -6
for d in /sys/bus/iio/devices/iio:device*; do
    [ -e "$d/name" ] || continue
    printf "iio %s %s" "${d##*/}" "$(cat "$d/name")"
    [ -e "$d/in_accel_x_raw" ] && printf " accel=%s,%s,%s scale=%s" "$(cat "$d/in_accel_x_raw")" "$(cat "$d/in_accel_y_raw")" "$(cat "$d/in_accel_z_raw")" "$(cat "$d/in_accel_scale" 2>/dev/null)"
    [ -e "$d/in_anglvel_x_raw" ] && printf " gyro=%s,%s,%s" "$(cat "$d/in_anglvel_x_raw")" "$(cat "$d/in_anglvel_y_raw")" "$(cat "$d/in_anglvel_z_raw")"
    [ -e "$d/in_magn_x_raw" ] && printf " magn=%s,%s,%s" "$(cat "$d/in_magn_x_raw")" "$(cat "$d/in_magn_y_raw")" "$(cat "$d/in_magn_z_raw")"
    echo
done
systemctl restart iio-sensor-proxy 2>/dev/null; sleep 3
timeout 5 monitor-sensor 2>&1 | grep -iE "accelerometer|orientation|compass" | head -4

sec hall
grep -A4 "hall-sensor" /proc/bus/input/devices | grep -E "Name|Handlers" | tr '\n' ' '; echo
echo "LidClosed $(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager LidClosed 2>&1)"

sec summary
echo "failed units: $(systemctl --failed --no-legend --plain | wc -l)"
echo "kernel warnings: $(dmesg | grep -cE 'WARNING:|BUG:|Oops')"
echo "AUTOTEST END"
sleep 5
echo "(no reboot: interactive run)"
