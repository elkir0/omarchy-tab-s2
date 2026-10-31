#!/bin/sh
# t715-autotest.sh, round "gpu": panfrost devfreq (docs/hardware/GPU.md section 10).
# Steps the GPU through its OPPs one at a time under a shader load,
# checking clock, voltage, faults and temperatures; stops at the first
# problem and parks the GPU at 266 MHz.  Restarts the board when done.
sec() { echo "== $*"; }
for _ in $(seq 1 60); do
    [ "$(systemctl is-active phosh 2>/dev/null)" = active ] && break
    sleep 2
done
sleep 20
echo "GPUTEST BEGIN $(uname -r) state=$(systemctl is-system-running) up=$(cut -d' ' -f1 /proc/uptime)"
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug

command -v gst-launch-1.0 >/dev/null && gst-inspect-1.0 gltestsrc >/dev/null 2>&1 && echo "load tool: gltestsrc ok" || echo "load tool: gltestsrc MISSING"
DF=$(ls -d /sys/class/devfreq/*gpu* 2>/dev/null | head -1)
REG=
for r in /sys/class/regulator/*; do [ "$(cat "$r/name" 2>/dev/null)" = vdd_g3d ] && REG=$r; done
faults() { dmesg | grep -ciE "panfrost.*(timeout|fault|reset|error)|gpu sched.*timeout"; }
temps() { cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | tr '\n' ' '; }
maxtemp() { cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1; }
gclk() { awk 'NR>2 && $1 == "aclk_g3d" {print $5}' /sys/kernel/debug/clk/clk_summary; }
state() { echo "cur=$(cat "$DF/cur_freq") clk=$(gclk) vdd_g3d=$(cat "$REG/microvolts") temps=$(temps)"; }
load() {
    # Mandelbrot shader at the panel size, rendered off-screen by panfrost.
    t1=$(cut -d' ' -f1 /proc/uptime)
    GST_GL_PLATFORM=egl GST_GL_WINDOW=surfaceless timeout 90 gst-launch-1.0 -q \
        gltestsrc pattern=mandelbrot num-buffers=${1:-120} \
        ! 'video/x-raw(memory:GLMemory),width=1536,height=2048' ! fakesink sync=false >/tmp/gst.out 2>&1
    rc=$?
    t2=$(cut -d' ' -f1 /proc/uptime)
    echo "load rc=$rc frames=${1:-120} $(awk -v a="$t1" -v b="$t2" -v n="${1:-120}" 'BEGIN {printf "%.1f s, %.1f fps", b-a, n/(b-a)}')"
    [ "$rc" = 0 ] || tail -3 /tmp/gst.out
    return $rc
}

sec devfreq
echo "node $DF"
[ -n "$DF" ] || { echo "no GPU devfreq node"; dmesg | grep -iE "panfrost|devfreq|opp" | tail -8; echo "GPUTEST END"; exit 0; }
echo "governor $(cat "$DF/governor") min $(cat "$DF/min_freq") max $(cat "$DF/max_freq")"
echo "available $(cat "$DF/available_frequencies")"
dmesg | grep -iE "panfrost|devfreq|opp|g3d" | tail -6
ls -d /sys/class/thermal/cooling_device* 2>/dev/null | while read -r c; do echo "cooling ${c##*/} $(cat "$c/type") max_state=$(cat "$c/max_state")"; done
echo "start: $(state) faults=$(faults)"

sec 'baseline load at the boot clock'
echo 266000000 >"$DF/min_freq"; echo 266000000 >"$DF/max_freq"; sleep 1
echo "$(state)"
load 120 || echo "LOAD FAILED at baseline"

sec stepping
F0=$(faults)
ok=
for f in 350000000 420000000 500000000 550000000 600000000 700000000; do
    echo "$f" >"$DF/max_freq"; echo "$f" >"$DF/min_freq"; sleep 1
    echo "step $f: $(state)"
    if ! load 120; then echo "ABORT: load failed at $f"; break; fi
    F1=$(faults)
    if [ "$F1" != "$F0" ]; then echo "ABORT: new GPU fault lines at $f"; dmesg | grep -iE "panfrost|gpu sched" | tail -5; break; fi
    t=$(maxtemp)
    if [ "${t:-0}" -gt 85000 ]; then echo "ABORT: $t mC at $f"; break; fi
    ok=$f
    echo "step $f ok: $(state)"
done
echo "highest level passed: ${ok:-none}"

sec 'governor run'
echo 160000000 >"$DF/min_freq"; echo 600000000 >"$DF/max_freq"; sleep 1
load 240 &
LP=$!
sleep 4; echo "under load: $(state)"
wait $LP
sleep 3; echo "idle: $(state)"
cat "$DF/trans_stat" 2>/dev/null | head -14

sec summary
echo 160000000 >"$DF/min_freq"; echo 600000000 >"$DF/max_freq"
echo "faults total $(faults)"
systemctl is-active phosh | sed 's/^/phosh /'
echo "kernel warnings: $(dmesg | grep -cE 'WARNING:|BUG:|Oops')"
echo "GPUTEST END"
