#!/usr/bin/env bash
# test_t715_power_profile.sh — off-device test of t715-power-profile
# (rootfs/overlay/usr/local/sbin/t715-power-profile, its two units,
# docs/image/ROOTFS.md, docs/hardware/BATTERY.md "Battery saver").
#
# Runs the script on this machine against a temporary fake sysfs: two
# cpufreq policies with their clusters told apart by cpu_capacity (1024
# against 586, as the tablet reports them), online files for cpu1-7 (cpu0
# has none on this kernel), a DSI dpms file, a GPU devfreq device and the
# cpufreq boost file, each of which can be removed to prove the script
# copes without it.  The script runs under bash -x, and the trace gives
# the order of the big cluster's online writes, which must be t715-keys'
# (offline 7,6,5,4, online 4,5,6,7); the little cluster's online files
# prove by their content that the script never touches them.  Stand-ins
# in PATH: powerprofilesctl (whose answer or failure the test chooses)
# and logger, which collects the script's summary lines.  In the style of
# test_t715_keys.sh (omarchy-mobile 5f7ba48, MIT).
#
# Usage: tests/test_t715_power_profile.sh
# Prints "ok - ..." per group, "PASS" at the end; exit 1 on the first
# failure (with what the stubs collected).  Needs bash 3.2 or later;
# nothing outside a temporary directory.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PP="$here/rootfs/overlay/usr/local/sbin/t715-power-profile"
[ -f "$PP" ] || { echo "SETUP ERROR: no $PP" >&2; exit 2; }

t=$(mktemp -d "${TMPDIR:-/tmp}/t715-power-test.XXXXXX")
cleanup() { rm -rf "$t"; }
trap cleanup EXIT

fail() {
    printf 'not ok - %s\n' "$1" >&2
    echo "--- logger" >&2; cat "$t/log" 2>/dev/null || true
    echo "--- online writes" >&2; cat "$t/writes" 2>/dev/null || true
    exit 1
}

# --- stand-ins ------------------------------------------------------------------
mkdir -p "$t/bin"
cat > "$t/bin/logger" <<STUB
#!/bin/sh
# The script's summary lines land here, whatever they say.
printf '%s\n' "\$*" >> "\$T715_TEST_LOG"
STUB
cat > "$t/bin/powerprofilesctl" <<STUB
#!/bin/sh
# Answers the active profile, or fails: a flag file decides which, so a
# case can prove the state file is read instead.
[ -f "\$T715_TEST_PPD_FAIL" ] && exit 1
cat "\$T715_TEST_PPD_OUT"
STUB
chmod +x "$t/bin/logger" "$t/bin/powerprofilesctl"
export T715_TEST_LOG="$t/log" T715_TEST_PPD_OUT="$t/ppd-out" T715_TEST_PPD_FAIL="$t/ppd-fail"
printf 'balanced\n' > "$t/ppd-out"

# --- the fake sysfs ----------------------------------------------------------------
# policy0: the little cluster, cpu0-3, eight levels on the tablet cut to
# four here; policy4: the big one, cpu4-7, a single level, as today's
# kernel has it.  cpu0 has no online file.
S=$t/sys
CF=$S/devices/system/cpu/cpufreq
mk_sysfs() {
    rm -rf "$S" "$t/run"
    mkdir -p "$CF/policy0" "$S/devices/system/cpu/cpu0" \
             "$S/devices/system/cpu/cpu4" "$S/class/drm/card0-DSI-1" "$t/run"
    printf '0 1 2 3\n'        > "$CF/policy0/related_cpus"
    printf '0 1 2 3\n'        > "$CF/policy0/affected_cpus"
    printf '400000 700000 1000000 1200000\n' > "$CF/policy0/scaling_available_frequencies"
    printf '1200000\n'        > "$CF/policy0/cpuinfo_max_freq"
    printf '1200000\n'        > "$CF/policy0/scaling_max_freq"
    printf '400000\n'         > "$CF/policy0/scaling_min_freq"
    printf 'schedutil\n'      > "$CF/policy0/scaling_governor"
    printf 'userspace performance schedutil\n' > "$CF/policy0/scaling_available_governors"
    printf '586\n'            > "$S/devices/system/cpu/cpu0/cpu_capacity"
    mkdir -p "$CF/policy4"
    printf '4 5 6 7\n'        > "$CF/policy4/related_cpus"
    printf '4 5 6 7\n'        > "$CF/policy4/affected_cpus"
    printf '1200000\n'        > "$CF/policy4/scaling_available_frequencies"
    printf '1200000\n'        > "$CF/policy4/cpuinfo_max_freq"
    printf '1200000\n'        > "$CF/policy4/scaling_max_freq"
    printf '1200000\n'        > "$CF/policy4/scaling_min_freq"
    printf 'schedutil\n'      > "$CF/policy4/scaling_governor"
    printf 'userspace performance schedutil\n' > "$CF/policy4/scaling_available_governors"
    printf '1024\n'           > "$S/devices/system/cpu/cpu4/cpu_capacity"
    # cpu1-7: online files; the script must write cpu4-7 only.
    for n in 1 2 3 4 5 6 7; do
        mkdir -p "$S/devices/system/cpu/cpu$n"
        printf '1\n' > "$S/devices/system/cpu/cpu$n/online"
    done
    printf 'On\n' > "$S/class/drm/card0-DSI-1/dpms"
    printf '[State]\nProfile=balanced\n' > "$t/state.ini"
    printf '1\n' > "$CF/boost"
    gpu_devfreq on
}
# gpu_devfreq on|off: the GPU's devfreq device, which today's kernel does
# not provide (the script must cope without it).
gpu_devfreq() {
    if [ "$1" = off ]; then
        rm -rf "$S/class/devfreq"
        return
    fi
    mkdir -p "$S/class/devfreq/14ac0000.gpu"
    printf '100000000 133333333 200000000 400000000\n' \
        > "$S/class/devfreq/14ac0000.gpu/available_frequencies"
    printf 'simple_ondemand userspace performance powersave\n' \
        > "$S/class/devfreq/14ac0000.gpu/available_governors"
    printf 'simple_ondemand\n' > "$S/class/devfreq/14ac0000.gpu/governor"
    printf '100000000\n'      > "$S/class/devfreq/14ac0000.gpu/min_freq"
    printf '400000000\n'      > "$S/class/devfreq/14ac0000.gpu/max_freq"
}

# pp [args...]: the script on the fake sysfs, with the stubs first in PATH
# and the trace kept, from which online_writes reads the order below.
pp() {
    : > "$t/trace"
    env T715_SYSFS="$S" T715_POWER_RUN="$t/run" \
        T715_PPD_STATE="$t/state.ini" T715_POWER_CONF="$t/conf" \
        PATH="$t/bin:$PATH" bash -x "$PP" "$@" 2> "$t/trace"
}
# online_writes: the big cores' online writes, in the order the script
# made them, as "7=0 6=0 5=0 4=0" (t715-keys' order).
online_writes() {
    sed -n 's/^.*write_val \([01]\) [^ ]*\/cpu\([4-7]\)\/online.*/\2=\1/p' "$t/trace" \
        | tr '\n' ' ' | sed 's/ $//'
}
little_max()  { cat "$CF/policy0/scaling_max_freq" 2>/dev/null || echo missing; }
little_gov()  { cat "$CF/policy0/scaling_governor" 2>/dev/null || echo missing; }
big_gov()     { cat "$CF/policy4/scaling_governor" 2>/dev/null || echo missing; }
boost()       { cat "$CF/boost" 2>/dev/null || echo absent; }
gpu()         { cat "$S/class/devfreq/14ac0000.gpu/$1" 2>/dev/null || echo absent; }
little_online() {
    for n in 1 2 3; do printf '%s' "$(cat "$S/devices/system/cpu/cpu$n/online")"; done
}

# --- (a) power-saver: caps, offline in order, the flag ------------------------------
mk_sysfs
rm -f "$t/log" "$t/conf"
pp apply power-saver || fail "(a) power-saver exits 0"
[ "$(little_max)" = 1000000 ] || fail "(a) the little cluster capped at 1000000 (got $(little_max))"
[ "$(online_writes)" = "7=0 6=0 5=0 4=0" ] \
    || fail "(a) the big cores offline in the order 7,6,5,4 (got $(online_writes))"
[ "$(cat "$S/devices/system/cpu/cpu4/online")" = 0 ] || fail "(a) cpu4's online file says 0"
[ -f "$t/run/saver" ] || fail "(a) the saver flag is there"
[ "$(boost)" = 0 ] || fail "(a) boost off (got $(boost))"
[ "$(gpu max_freq)" = 200000000 ] || fail "(a) the GPU capped at 200000000 (got $(gpu max_freq))"
[ "$(little_online)" = 111 ] || fail "(a) the little cluster's online files untouched (got $(little_online))"
grep -q 'power-saver: little max 1000000' "$t/log" || fail "(a) one summary line through logger"
echo "ok - power-saver: little at 1000000, big offline 7,6,5,4, flag, GPU 200 MHz, boost 0"

# --- (b) balanced with the panel lit: everything back --------------------------------
echo On > "$S/class/drm/card0-DSI-1/dpms"
: > "$t/log"
pp apply balanced || fail "(b) balanced exits 0"
[ "$(little_max)" = 1200000 ] || fail "(b) the little cluster back at cpuinfo_max_freq (got $(little_max))"
[ "$(little_gov)" = schedutil ] || fail "(b) the little governor schedutil (got $(little_gov))"
[ "$(big_gov)" = schedutil ] || fail "(b) the big governor schedutil (got $(big_gov))"
[ "$(online_writes)" = "4=1 5=1 6=1 7=1" ] \
    || fail "(b) the big cores online in the order 4,5,6,7 (got $(online_writes))"
[ ! -e "$t/run/saver" ] || fail "(b) the flag is gone"
[ "$(boost)" = 1 ] || fail "(b) boost on (got $(boost))"
[ "$(gpu max_freq)" = 400000000 ] || fail "(b) the GPU back at 400000000 (got $(gpu max_freq))"
[ "$(gpu governor)" = simple_ondemand ] || fail "(b) the GPU governor simple_ondemand (got $(gpu governor))"
grep -q 'balanced: little max 1200000' "$t/log" || fail "(b) one summary line through logger"
echo "ok - balanced, panel lit: schedutil and the top frequencies everywhere, big online 4,5,6,7, flag gone"

# --- (c) balanced with the panel dark: the big cores stay offline ----------------------
echo Off > "$S/class/drm/card0-DSI-1/dpms"
: > "$t/log"
pp apply power-saver || fail "(c) power-saver exits 0"
[ "$(online_writes)" = "7=0 6=0 5=0 4=0" ] || fail "(c) setup: offline again (got $(online_writes))"
: > "$t/log"
pp apply balanced || fail "(c) balanced, panel dark, exits 0"
[ "$(little_max)" = 1200000 ] || fail "(c) the little cluster is freed all the same (got $(little_max))"
[ "$(online_writes)" = "" ] || fail "(c) the big cores stay offline (got $(online_writes))"
[ "$(cat "$S/devices/system/cpu/cpu4/online")" = 0 ] || fail "(c) cpu4's online file still says 0"
[ ! -e "$t/run/saver" ] || fail "(c) the flag is gone all the same"
grep -q 'the panel is dark' "$t/log" || fail "(c) the summary says the panel is dark"
echo "ok - balanced, panel dark: caps and flag as ever, the big cores left to t715-keys"
echo On > "$S/class/drm/card0-DSI-1/dpms"

# --- (d) no GPU, no boost: the CPU part still applies ---------------------------------
gpu_devfreq off
rm -f "$CF/boost"
: > "$t/log"
pp apply power-saver || fail "(d) power-saver without GPU or boost exits 0"
[ "$(little_max)" = 1000000 ] || fail "(d) the little cluster capped (got $(little_max))"
[ "$(online_writes)" = "7=0 6=0 5=0 4=0" ] || fail "(d) the big cores offline (got $(online_writes))"
[ -f "$t/run/saver" ] || fail "(d) the flag is there"
: > "$t/log"
pp apply balanced || fail "(d) balanced without GPU or boost exits 0"
[ "$(little_max)" = 1200000 ] || fail "(d) the little cluster freed (got $(little_max))"
[ "$(online_writes)" = "4=1 5=1 6=1 7=1" ] || fail "(d) the big cores online (got $(online_writes))"
grep -q 'gpu -' "$t/log" || fail "(d) the summary marks the GPU absent"
echo "ok - no GPU and no boost: exit 0, the CPU part applied"

# --- (e) the configuration file: keep the big cluster, another little cap --------------
mk_sysfs
printf 'SAVER_BIG=keep\nSAVER_LITTLE_MAX_KHZ=800000\n' > "$t/conf"
: > "$t/log"
pp apply power-saver || fail "(e) power-saver with the config exits 0"
[ "$(online_writes)" = "" ] || fail "(e) SAVER_BIG=keep leaves the big cores alone (got $(online_writes))"
[ "$(cat "$S/devices/system/cpu/cpu4/online")" = 1 ] || fail "(e) cpu4's online file still says 1"
# 800000 allows 700000, the highest level not over it.
[ "$(little_max)" = 700000 ] || fail "(e) SAVER_LITTLE_MAX_KHZ=800000 caps at 700000 (got $(little_max))"
[ -f "$t/run/saver" ] || fail "(e) the flag is there with keep"
echo "ok - config: SAVER_BIG=keep writes no online file, SAVER_LITTLE_MAX_KHZ=800000 caps at 700000"

# --- (f) a cap below every frequency: the lowest --------------------------------------
printf 'SAVER_LITTLE_MAX_KHZ=1\n' > "$t/conf"
pp apply power-saver || fail "(f) power-saver with a cap of 1 exits 0"
[ "$(little_max)" = 400000 ] || fail "(f) a cap under every level gives the lowest (got $(little_max))"
echo "ok - clamping: a cap below every available frequency gives the lowest"

# (g) needs a pristine tree: the caps of (e) and (f) still hold.

# --- (g) no profile given: powerprofilesctl, then the state file -----------------------
mk_sysfs
rm -f "$t/log" "$t/conf"
printf 'power-saver\n' > "$t/ppd-out"
pp apply || fail "(g) apply without a profile exits 0"
[ "$(little_max)" = 1000000 ] || fail "(g) the stub's power-saver applied (got $(little_max))"
[ -f "$t/run/saver" ] || fail "(g) the flag is there"
printf 'balanced\n' > "$t/ppd-out"
pp apply || fail "(g) apply with the stub on balanced exits 0"
[ "$(little_max)" = 1200000 ] || fail "(g) the stub's balanced applied (got $(little_max))"
# The stub fails: the state file answers.
touch "$t/ppd-fail"
printf '[State]\nProfile=power-saver\n' > "$t/state.ini"
pp apply || fail "(g) apply with the stub down exits 0"
[ "$(little_max)" = 1000000 ] || fail "(g) the state file's power-saver applied (got $(little_max))"
[ -f "$t/run/saver" ] || fail "(g) the flag is there from the state file"
# Neither answers: balanced, and nothing stops.
rm -f "$t/state.ini"
: > "$t/log"
pp apply || fail "(g) apply with nothing to read exits 0"
[ "$(little_max)" = 1200000 ] || fail "(g) balanced without any source (got $(little_max))"
[ ! -e "$t/run/saver" ] || fail "(g) no flag without any source"
rm -f "$t/ppd-fail"
echo "ok - no profile: powerprofilesctl first, the state file next, balanced when neither answers"

# --- (h) min_freq above the new GPU max: min comes down first -------------------------
mk_sysfs
rm -f "$t/conf"
printf '400000000\n' > "$S/class/devfreq/14ac0000.gpu/min_freq"
: > "$t/log"
pp apply power-saver || fail "(h) power-saver with a high GPU min exits 0"
[ "$(gpu min_freq)" = 200000000 ] || fail "(h) the GPU min lowered to the new max (got $(gpu min_freq))"
[ "$(gpu max_freq)" = 200000000 ] || fail "(h) the GPU max set (got $(gpu max_freq))"
pp apply balanced || fail "(h) balanced after it exits 0"
[ "$(gpu max_freq)" = 400000000 ] || fail "(h) the GPU max back (got $(gpu max_freq))"
echo "ok - GPU: min_freq above the new max is lowered first"

# --- (i) usage --------------------------------------------------------------------------
pp status >/dev/null 2>&1 || fail "(i) status exits 0"
pp apply extra balanced >/dev/null 2>&1 && fail "(i) too many arguments is refused"
[ "$(pp apply extra 2>/dev/null; echo $?)" = 2 ] || fail "(i) an unknown profile exits 2"
[ "$(pp frobnicate 2>/dev/null; echo $?)" = 2 ] || fail "(i) an unknown verb exits 2"
[ "$(pp 2>/dev/null; echo $?)" = 2 ] || fail "(i) no verb exits 2"
[ "$(pp apply >/dev/null 2>&1; echo $?)" = 0 ] || fail "(i) apply with no profile exits 0"
echo "ok - usage: status and apply accepted, anything else exits 2"

# --- (j) the tablet's layout: cpufreq links, the big cluster already offline -----------
# As on the device (2026-11-07): an offline cpu keeps its cpufreq link but
# has no cpu_capacity, and its inactive policy answers EBUSY, read here as
# missing files.  The clusters must still be told apart, through the links.
mk_sysfs
rm -f "$t/conf"
for n in 0 1 2 3; do ln -s ../cpufreq/policy0 "$S/devices/system/cpu/cpu$n/cpufreq"; done
for n in 4 5 6 7; do
    ln -s ../cpufreq/policy4 "$S/devices/system/cpu/cpu$n/cpufreq"
    printf '0\n' > "$S/devices/system/cpu/cpu$n/online"
done
rm -f "$S/devices/system/cpu/cpu4/cpu_capacity" "$CF/policy4/related_cpus" \
      "$CF/policy4/affected_cpus" "$CF/policy4/scaling_governor" "$CF/policy4/cpuinfo_max_freq"
: > "$t/log"
pp apply power-saver || fail "(j) power-saver exits 0"
[ "$(little_max)" = 1000000 ] || fail "(j) the little cluster capped (got $(little_max))"
[ -f "$t/run/saver" ] || fail "(j) the saver flag is there"
grep -q 'power-saver: little max 1000000, big offline' "$t/log" \
    || fail "(j) the big cluster found through the links while offline (log: $(cat "$t/log"))"
echo On > "$S/class/drm/card0-DSI-1/dpms"
: > "$t/log"
pp apply balanced || fail "(j) balanced exits 0"
[ "$(online_writes)" = "4=1 5=1 6=1 7=1" ] \
    || fail "(j) the offline big cores come back, 4,5,6,7 (got $(online_writes))"
[ "$(little_max)" = 1200000 ] || fail "(j) the little cluster back at its top (got $(little_max))"
[ ! -e "$t/run/saver" ] || fail "(j) the flag is gone"
[ ! -e "$CF/policy4/scaling_governor" ] || fail "(j) nothing written to the inactive policy"
grep -q 'balanced: little max 1200000, big online' "$t/log" || fail "(j) the summary says the big cores came back"
echo "ok - offline big cluster: found through the cpufreq links, brought back by balanced"

echo "PASS"
