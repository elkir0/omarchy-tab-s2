#!/usr/bin/env bash
# test_t715_wifi_guard.sh — off-device test of t715-wifi-guard
# (rootfs/overlay/usr/local/sbin/t715-wifi-guard, its unit, its enabling
# in rootfs/configure-system.sh, its checks in tests/verify-rootfs.sh and
# its paragraph in docs/image/ROOTFS.md).
#
# Runs the script on this machine against a temporary fake sysfs: the
# exynos-pcie driver dir with the 15700000.pcie host and its bind/unbind
# files, the hci_uart_bcm driver dir with its serial0-0 device, the
# brcmfmac PCI device and a wlp1s0 with a phy80211 entry.  The bind and
# unbind files are plain files, so every write lands in the trace (the
# script's own T715_WG_TRACE), from which the tests read the order of the
# whole-chip power cycle; for the stuck case the host's unbind becomes a
# FIFO, which a write with no reader blocks on.  The fake dmesg prints a
# body per call, chosen by a try number from a sequence file (the last
# entry repeats): body.0 a good start, body.1..6 one of brcmfmac's failure
# signatures each, body.7 a single query timeout, which does not count,
# body.8 and body.9 good starts late in the boot, after failed ones,
# body.10 a good start whose log has no timestamps, body.11 the log hours
# later, turned over past every line an old judgment saw, and body.12 and
# body.13 one and two query timeouts after a judgment's mark.  A good
# body also brings the wlp1s0 interface, a failed one leaves the chip
# without it -- except 11, 12 and 13, which keep it (see (m)); a good
# body's log carries a MAC address, to prove the script never repeats
# one.  sleep is a stub that returns at once and records the seconds, so a
# judged start costs no time.
#
# In the style of tests/test_t715_power_profile.sh (omarchy-mobile 5f7ba48,
# MIT).
#
# Usage: tests/test_t715_wifi_guard.sh
# Prints "ok - ..." per group, "PASS" at the end; exit 1 on the first
# failure (with what the stubs collected).  Needs bash 3.2 or later;
# nothing outside a temporary directory.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WG="$here/rootfs/overlay/usr/local/sbin/t715-wifi-guard"
[ -f "$WG" ] || { echo "SETUP ERROR: no $WG" >&2; exit 2; }
UNIT="$here/rootfs/overlay/etc/systemd/system/t715-wifi-guard.service"
[ -f "$UNIT" ] || { echo "SETUP ERROR: no $UNIT" >&2; exit 2; }

t=$(mktemp -d "${TMPDIR:-/tmp}/t715-wifi-test.XXXXXX")
cleanup() { rm -rf "$t"; }
trap cleanup EXIT

fail() {
    printf 'not ok - %s\n' "$1" >&2
    echo "--- logger" >&2; cat "$t/log" 2>/dev/null || true
    echo "--- trace" >&2; cat "$t/trace" 2>/dev/null || true
    echo "--- stdout" >&2; cat "$t/out" 2>/dev/null || true
    echo "--- klog calls" >&2; cat "$t/klog.calls" 2>/dev/null || true
    exit 1
}

# --- stand-ins ------------------------------------------------------------------
mkdir -p "$t/bin"
# sleep: no real waiting -- the fake kernel log is not a moving target --
# and every second asked for recorded, so a wait can be checked.
cat > "$t/bin/sleep" <<'STUB'
#!/bin/sh
printf '%s\n' "$1" >> "$T715_TEST_SLEEPS"
exit 0
STUB
# logger: the script's decision lines land here, whatever they say, and
# in a copy kept over all the scenarios, for the privacy check (h).
cat > "$t/bin/logger" <<'STUB'
#!/bin/sh
# The script runs `logger -t t715-wifi-guard TEXT...`: drop the tag.
[ "${1:-}" = "-t" ] && shift 2
printf '%s\n' "$*" >> "$T715_TEST_LOG"
printf '%s\n' "$*" >> "$T715_TEST_LOG_ALL"
STUB
# dmesg: the fake kernel log.  Without -w it prints the log as it stands:
# line N of the sequence file names the body for call N (the calls counted
# in a file), the last line repeating once the sequence is used up.  With
# -w, the follow the script's run watches, it prints the new lines it was
# given and then ends: nothing more comes.  A good body (0, 7, whose
# single query timeout does not count, and 8 to 10) also brings the
# interface the driver would have created, and so do 11, 12 and 13, whose
# failures leave the netdev in place (the case the whole-log counts
# missed, see (m)); any other body leaves the chip without one.
cat > "$t/bin/dmesg" <<'STUB'
#!/bin/sh
if [ "${1:-}" = "-w" ] || [ "${1:-}" = "-W" ]; then
    cat "$T715_TEST_KFOLLOW" 2>/dev/null || true
    exit 0
fi
n=0
[ -f "$T715_TEST_CALLS" ] && n=$(cat "$T715_TEST_CALLS")
case $n in ''|*[!0-9]*) n=0 ;; esac
n=$((n + 1))
printf '%s\n' "$n" > "$T715_TEST_CALLS"
try=$(sed -n "${n}p" "$T715_TEST_SEQ" 2>/dev/null)
[ -n "$try" ] || try=$(tail -n 1 "$T715_TEST_SEQ" 2>/dev/null)
case $try in ''|*[!0-9]*) try=0 ;; esac
case $try in 0|7|8|9|10|11|12|13) mkdir -p "$T715_TEST_NET/wlp1s0/phy80211" 2>/dev/null ;;
             *) rm -rf "$T715_TEST_NET/wlp1s0" 2>/dev/null ;;
esac
cat "$T715_TEST_BODIES/body.$try" 2>/dev/null || exit 0
STUB
chmod +x "$t/bin/sleep" "$t/bin/logger" "$t/bin/dmesg"
export T715_TEST_LOG="$t/log" T715_TEST_SLEEPS="$t/sleeps" \
       T715_TEST_CALLS="$t/klog.calls" T715_TEST_SEQ="$t/klog.seq" \
       T715_TEST_BODIES="$t/klog" T715_TEST_KFOLLOW="$t/kfollow.lines" \
       T715_TEST_NET="$t/sys/class/net" T715_TEST_LOG_ALL="$t/log.all"
# Everything the script prints, over all the scenarios, for the privacy
# check (h): the log (the logger stub's copy), the traces, stdout and
# stderr.  mk_sysfs starts a scenario's own files, never these.
: > "$t/log.all"
: > "$t/trace.all"
: > "$t/out.all"
: > "$t/err.all"

# --- the fake sysfs ----------------------------------------------------------------
S=$t/sys
PCIE=$S/bus/platform/drivers/exynos-pcie
BT=$S/bus/serial/drivers/hci_uart_bcm
mk_sysfs() {
    rm -rf "$S" "$t/run"
    mkdir -p "$PCIE/15700000.pcie" "$BT" "$S/bus/pci/drivers/brcmfmac/0000:01:00.0" \
             "$S/class/net/wlp1s0/phy80211" "$t/run"
    : > "$PCIE/bind"
    : > "$PCIE/unbind"
    : > "$BT/bind"
    : > "$BT/unbind"
    mkdir "$BT/serial0-0"
    # the kernel's say that its PCIe host power-cycles the Wi-Fi
    mkdir -p "$S/module/pci_exynos/parameters"
    printf 'Y\n' > "$S/module/pci_exynos/parameters/wifi_power_cycle"
    # The kernel log bodies: 0 a good start (with a MAC address, which the
    # script must never repeat), 1..6 one failure signature each, 7 a
    # single query timeout, which on its own does not fail a start, 8 a
    # good start late in the boot, after failed ones (the log a recovery's
    # good try judges, its last line at 2040.300000), 9 the same and one
    # more benign line, at 2150.000000, 10 body 0 without its timestamps
    # (a kernel log with none), 11 the log hours later, every line newer
    # than the 2040.300000 an old judgment stopped at and none stamped
    # with it (the ring buffer turned over) yet holding a probe failure
    # and keeping the interface -- the failure the whole-log counts
    # missed, see (m) -- 12 body 7's lines and one more query timeout
    # after its wm, 13 body 12 and a second timeout after it, a failure
    # signature that keeps the interface too (see (m2)).
    mkdir -p "$t/klog"
    { printf '%s\n' '[    2.800000] exynos-pcie 15700000.pcie: PCIe link up'
      printf '%s\n' '[    3.100000] brcmfmac4358 PCIe 0000:01:00.0: F/W 7.112.300.14'
      printf '%s\n' '[    3.350000] brcmfmac: using the NVRAM address 02:11:22:33:44:55' ; } > "$t/klog/body.0"
    { printf '%s\n' '[    4.100000] brcmfmac4358 PCIe 0000:01:00.0: brcmf_pcie_probe: failed err=-110'
      printf '%s\n' '[    4.120000] brcmfmac4358 PCIe 0000:01:00.0: no interface, the NVRAM address 02:11:22:33:44:55 unused' ; } > "$t/klog/body.1"
    printf '%s\n' '[    5.100000] brcmfmac: MMIO read failed (0xffffffff) at 0x18002030' > "$t/klog/body.2"
    printf '%s\n' '[    5.200000] brcmfmac: brcmf_fwmem: Firmware has halted' > "$t/klog/body.3"
    printf '%s\n' '[    5.300000] brcmfmac: brcmf_pcie_get_mbdata: mailbox status reads all ones' > "$t/klog/body.4"
    printf '%s\n' '[    5.400000] brcmfmac: brcmf_pcie_init_ringbuffers: ring 2 past its depth' > "$t/klog/body.5"
    { printf '%s\n' '[    6.100000] brcmfmac: brcmf_proto_bcdc_query_dcmd: Timeout on response for query command (88)'
      printf '%s\n' '[    6.400000] brcmfmac: brcmf_proto_bcdc_query_dcmd: Timeout on response for query command (88)' ; } > "$t/klog/body.6"
    { printf '%s\n' '[    3.100000] brcmfmac: brcmf_proto_bcdc_query_dcmd: Timeout on response for query command (88)'
      printf '%s\n' '[    3.500000] brcmfmac4358 PCIe 0000:01:00.0: F/W 7.112.300.14' ; } > "$t/klog/body.7"
    { printf '%s\n' '[    2.800000] exynos-pcie 15700000.pcie: PCIe link up'
      printf '%s\n' '[    3.100000] brcmfmac4358 PCIe 0000:01:00.0: F/W 7.112.300.14'
      printf '%s\n' '[ 2000.100000] brcmfmac4358 PCIe 0000:01:00.0: brcmf_pcie_probe: failed err=-110'
      printf '%s\n' '[ 2005.200000] brcmfmac: MMIO read failed (0xffffffff) at 0x18002030'
      printf '%s\n' '[ 2040.089000] brcmfmac: brcmf_fwmem: Firmware has halted'
      printf '%s\n' '[ 2040.200000] exynos-pcie 15700000.pcie: PCIe link up'
      printf '%s\n' '[ 2040.250000] brcmfmac4358 PCIe 0000:01:00.0: F/W 7.112.300.14'
      printf '%s\n' '[ 2040.300000] brcmfmac: using the NVRAM address 02:11:22:33:44:55' ; } > "$t/klog/body.8"
    { cat "$t/klog/body.8"
      printf '%s\n' '[ 2150.000000] brcmfmac4358 PCIe 0000:01:00.0: F/W 7.112.300.14' ; } > "$t/klog/body.9"
    { printf '%s\n' 'exynos-pcie 15700000.pcie: PCIe link up'
      printf '%s\n' 'brcmfmac4358 PCIe 0000:01:00.0: F/W 7.112.300.14'
      printf '%s\n' 'brcmfmac: using the NVRAM address 02:11:22:33:44:55' ; } > "$t/klog/body.10"
    { printf '%s\n' '[ 9000.100000] exynos-pcie 15700000.pcie: PCIe link up'
      printf '%s\n' '[ 9001.200000] brcmfmac4358 PCIe 0000:01:00.0: brcmf_pcie_probe: failed err=-110'
      printf '%s\n' '[ 9001.300000] brcmfmac4358 PCIe 0000:01:00.0: F/W 7.112.300.14' ; } > "$t/klog/body.11"
    { cat "$t/klog/body.7"
      printf '%s\n' '[   60.000000] brcmfmac: brcmf_proto_bcdc_query_dcmd: Timeout on response for query command (88)'
      printf '%s\n' '[   60.500000] brcmfmac4358 PCIe 0000:01:00.0: F/W 7.112.300.14' ; } > "$t/klog/body.12"
    { cat "$t/klog/body.12"
      printf '%s\n' '[   61.000000] brcmfmac: brcmf_proto_bcdc_query_dcmd: Timeout on response for query command (88)' ; } > "$t/klog/body.13"
    klog_seq 0
    : > "$t/kfollow.lines"
    : > "$t/log"
}
# klog_seq TRY...: what the fake kernel log answers, one body per call,
# the last repeating; also the try whose signature a check sees first.
klog_seq() {
    printf '%s\n' "$@" > "$t/klog.seq"
    : > "$t/klog.calls"
}
# stuck_unbind: the host's unbind as a FIFO -- a write with no reader
# blocks in the open, which is the kernel hanging in the unbind.
stuck_unbind() {
    rm -f "$PCIE/unbind"
    mkfifo "$PCIE/unbind"
}

# wg [args...]: the script on the fake sysfs, with the stubs first in PATH,
# the trace, stdout and stderr kept, and WG_RC its exit code; everything it
# ever printed also accumulates, for the MAC-address check at the end.
wg() {
    : > "$t/trace"
    : > "$t/out"
    : > "$t/err"
    : > "$t/sleeps"
    WG_RC=0
    env T715_WG_SYS="$S" T715_WG_LOCK="$t/run/guard.lock" \
        T715_WG_STATE="$t/run/guard.state" T715_WG_TRACE="$t/trace" \
        PATH="$t/bin:$PATH" \
        "$WG" "$@" > "$t/out" 2> "$t/err" || WG_RC=$?
    cat "$t/trace" >> "$t/trace.all"
    cat "$t/out" >> "$t/out.all"
    cat "$t/err" >> "$t/err.all"
    return 0
}
trace_lines() { wc -l < "$t/trace" | tr -d ' '; }
host_binds()  { grep -c '^bus/platform/drivers/exynos-pcie/bind ' "$t/trace" || true; }
CYCLE='bus/platform/drivers/exynos-pcie/unbind 15700000.pcie
bus/serial/drivers/hci_uart_bcm/unbind serial0-0
bus/platform/drivers/exynos-pcie/bind 15700000.pcie
bus/serial/drivers/hci_uart_bcm/bind serial0-0'
HOST_ONLY='bus/platform/drivers/exynos-pcie/unbind 15700000.pcie
bus/platform/drivers/exynos-pcie/bind 15700000.pcie'

# --- (a) healthy Wi-Fi: check passes, run recovers nothing -------------------------
mk_sysfs
wg check
[ "$WG_RC" = 0 ] || fail "(a) check on a healthy Wi-Fi exits 0 (got $WG_RC)"
[ ! -s "$t/out" ] || fail "(a) check on a healthy Wi-Fi prints nothing (got $(cat "$t/out"))"
wg run
[ "$WG_RC" = 0 ] || fail "(a) run on a healthy Wi-Fi exits 0 (got $WG_RC)"
[ "$(trace_lines)" = 0 ] || fail "(a) run on a healthy Wi-Fi writes nothing (trace: $(cat "$t/trace"))"
grep -q 'boot check: the Wi-Fi is up' "$t/log" || fail "(a) run logs the boot check"
! grep -q 'recover' "$t/log" || fail "(a) run on a healthy Wi-Fi never recovers"
echo "ok - healthy Wi-Fi: check exits 0, run waits, checks and recovers nothing"

# --- (b) the signatures: each fails a start, one query timeout does not -------------
for b in 1 2 3 4 5 6; do
    klog_seq "$b"
    wg check
    [ "$WG_RC" = 1 ] || fail "(b) body $b: check exits 1 (got $WG_RC)"
    grep -q 'failure signature in the kernel log' "$t/out" \
        || fail "(b) body $b: the reason names the signature (got $(cat "$t/out"))"
    [ "$(wc -l < "$t/out" | tr -d ' ')" = 1 ] || fail "(b) body $b: one line only"
done
klog_seq 7
wg check
[ "$WG_RC" = 0 ] || fail "(b) one query timeout alone does not fail a start (got $WG_RC)"
echo "ok - signatures: each of the six fails a check, a single query timeout does not"

# --- (c) probe failure at boot, the next try good: one whole-chip cycle -------------
mk_sysfs
rm -rf "$S/class/net/wlp1s0"
klog_seq 1 1 1 0 0   # settle, boot check, the re-check under the lock, the try's before and judgment
wg run
[ "$WG_RC" = 0 ] || fail "(c) run exits 0 when the second start is good (got $WG_RC)"
[ "$(cat "$t/trace")" = "$CYCLE" ] \
    || fail "(c) one whole-chip cycle, host and Bluetooth, in order (trace: $(cat "$t/trace"))"
grep -q 'recovery try 1 of 6: the Wi-Fi came up' "$t/log" || fail "(c) the good try is logged"
grep -q 'recovered: the Wi-Fi is up' "$t/log" || fail "(c) the recovery is logged"
echo "ok - probe failure at boot: host unbind, Bluetooth unbind, host bind, Bluetooth bind, once; exit 0"

# --- (d) six failed tries: six cycles, exit 1 ---------------------------------------
mk_sysfs
rm -rf "$S/class/net/wlp1s0"
klog_seq 1
wg recover
[ "$WG_RC" = 1 ] || fail "(d) six failed tries exit 1 (got $WG_RC)"
[ "$(host_binds)" = 6 ] || fail "(d) six host binds (got $(host_binds))"
want=""; i=0; while [ $i -lt 6 ]; do want="$want$CYCLE
"; i=$((i + 1)); done
[ "$(cat "$t/trace")" = "${want%
}" ] || fail "(d) six whole-chip cycles in order (trace: $(cat "$t/trace"))"
grep -q 'recover: 6 tries, none brought the Wi-Fi up' "$t/log" || fail "(d) the giving-up line"
echo "ok - six failed tries: six whole-chip cycles, exit 1"

# --- (d2) a kernel that cannot power-cycle the Wi-Fi: no cycle, exit 3 --------------
mk_sysfs
rm -rf "$S/class/net/wlp1s0" "$S/module/pci_exynos/parameters/wifi_power_cycle"
klog_seq 1
wg recover
[ "$WG_RC" = 3 ] || fail "(d2) recover on a kernel without wifi_power_cycle exits 3 (got $WG_RC)"
[ "$(trace_lines)" = 0 ] || fail "(d2) no write at all (trace: $(cat "$t/trace"))"
grep -q 'cannot power-cycle the Wi-Fi' "$t/log" || fail "(d2) the refusal is logged"
mk_sysfs
rm -rf "$S/class/net/wlp1s0" "$S/module/pci_exynos/parameters/wifi_power_cycle"
klog_seq 1
wg run
[ "$WG_RC" = 0 ] || fail "(d2) run on such a kernel still exits 0 (got $WG_RC)"
[ "$(trace_lines)" = 0 ] || fail "(d2) run writes nothing (trace: $(cat "$t/trace"))"
echo "ok - a kernel without pci_exynos.wifi_power_cycle: recover exits 3, run recovers nothing"

# --- (e) Bluetooth not bound: the cycle touches only the host ------------------------
mk_sysfs
rm -rf "$S/class/net/wlp1s0" "$BT/serial0-0"
klog_seq 0 0
wg recover 1
[ "$WG_RC" = 0 ] || fail "(e) recover without Bluetooth exits 0 (got $WG_RC)"
[ "$(cat "$t/trace")" = "$HOST_ONLY" ] \
    || fail "(e) only the host touched (trace: $(cat "$t/trace"))"
grep -q 'serial' "$t/trace" && fail "(e) no write to the Bluetooth driver"
echo "ok - Bluetooth not bound: the power cycle touches only the PCIe host"

# --- (f) a stuck host unbind: exit 2 past the limit ----------------------------------
mk_sysfs
rm -rf "$S/class/net/wlp1s0"
stuck_unbind
klog_seq 0
T715_WG_UNBIND_MAX=2 wg recover 1
[ "$WG_RC" = 2 ] || fail "(f) a stuck host unbind exits 2 (got $WG_RC)"
[ "$(trace_lines)" = 0 ] || fail "(f) nothing else written (trace: $(cat "$t/trace"))"
grep -q 'the host unbind did not return within 2 s: giving up' "$t/log" \
    || fail "(f) the giving-up line (log: $(cat "$t/log"))"
[ "$(grep -c '^1$' "$t/sleeps" || true)" -ge 2 ] \
    || fail "(f) the limit waited for (sleeps: $(tr '\n' ' ' < "$t/sleeps"))"
echo "ok - stuck host unbind: given 2 s, then exit 2 with a log line, nothing else written"

# --- (g) the rate limit in run: a fourth recovery never happens ----------------------
mk_sysfs
rm -rf "$S/class/net/wlp1s0"
klog_seq 1   # every start fails, forever
printf '%s\n' \
 '[ 1200.100000] brcmfmac4358 PCIe 0000:01:00.0: brcmf_pcie_probe: failed err=-110' \
 '[ 1300.200000] brcmfmac4358 PCIe 0000:01:00.0: brcmf_pcie_probe: failed err=-110' \
 '[ 1400.300000] brcmfmac4358 PCIe 0000:01:00.0: brcmf_pcie_probe: failed err=-110' \
 > "$t/kfollow.lines"
wg run
[ "$WG_RC" = 0 ] || fail "(g) run exits 0 all the same (got $WG_RC)"
# The boot check recovers once, the first two signatures twice more; the
# third hits the limit of 3 in 30 minutes and only logs.
[ "$(host_binds)" = 18 ] || fail "(g) three recoveries of six tries, 18 host binds (got $(host_binds))"
grep -q '3 recoveries in 30 minutes: not recovering any more until the next boot' "$t/log" \
    || fail "(g) the rate-limit line (log: $(cat "$t/log"))"
[ "$(grep -c 'watch: failure signature' "$t/log" || true)" = 3 ] \
    || fail "(g) every signature still watched (log: $(cat "$t/log"))"
echo "ok - rate limit: 3 recoveries, then one line and no more cycling, still watching"

# --- (g2) the lock held by another recovery that brings the Wi-Fi up ---------------
# The race of 2026-11-09: the watch check fails, but while this recovery
# waits for the lock another one (typed by hand) has already brought the
# Wi-Fi up.  Re-checked under the lock, the start is good: nothing is
# cycled, the skip is not counted as a recovery, and three later real
# failures still get their full rate limit -- had the skip counted, the
# third of them would meet the 3-in-30-minutes limit and never cycle.
# The fake kernel log plays the other recovery: its body turns good
# between the watch check and the re-check (a bind with no signature
# after it, the interface back, the device bound); where flock exists a
# real outside holder keeps the lock across that turn, so the service's
# re-check can only happen once the lock is given up.
mk_sysfs
printf '%s\n' \
 '[ 1500.100000] brcmfmac4358 PCIe 0000:01:00.0: brcmf_pcie_probe: failed err=-110' \
 '[ 1600.200000] brcmfmac4358 PCIe 0000:01:00.0: brcmf_pcie_probe: failed err=-110' \
 '[ 1700.300000] brcmfmac4358 PCIe 0000:01:00.0: brcmf_pcie_probe: failed err=-110' \
 '[ 1800.400000] brcmfmac4358 PCIe 0000:01:00.0: brcmf_pcie_probe: failed err=-110' \
 > "$t/kfollow.lines"
# boot good; watch fail, re-check good (the other recovery's start); then
# three real failures, each failing the re-check as well and coming good
# on the try's judgment.
klog_seq 0 1 0  1 1 1 0  1 1 1 0  1 1 1 0
holder=""
if command -v flock >/dev/null 2>&1; then
    (
        flock -x 9
        printf 'held\n' > "$t/run/holder"
        /bin/sleep 1
    ) 9>"$t/run/guard.lock" &
    holder=$!
    i=0
    while [ ! -f "$t/run/holder" ] && [ "$i" -lt 50 ]; do
        /bin/sleep 0.1
        i=$((i + 1))
    done
    [ -f "$t/run/holder" ] || fail "(g2) the outside holder never got the lock"
fi
wg run
if [ -n "$holder" ]; then wait "$holder" || true; fi
[ "$WG_RC" = 0 ] || fail "(g2) run exits 0 (got $WG_RC)"
[ "$(grep -c 'recover: the Wi-Fi came up meanwhile (another recovery held the lock): nothing to do' "$t/log" || true)" = 1 ] \
    || fail "(g2) the came-up-meanwhile line, once (log: $(cat "$t/log"))"
[ "$(host_binds)" = 3 ] \
    || fail "(g2) the skipped recovery cycles nothing, the three real ones one cycle each (got $(host_binds) host binds)"
want=""; i=0; while [ $i -lt 3 ]; do want="$want$CYCLE
"; i=$((i + 1)); done
[ "$(cat "$t/trace")" = "${want%
}" ] || fail "(g2) three whole-chip cycles only, in order (trace: $(cat "$t/trace"))"
! grep -q 'not recovering any more' "$t/log" \
    || fail "(g2) the skip leaves the rate limit whole (log: $(cat "$t/log"))"
[ "$(grep -c 'recovered: the Wi-Fi is up' "$t/log" || true)" = 3 ] \
    || fail "(g2) the three later failures all recovered (log: $(cat "$t/log"))"
echo "ok - lock held by another recovery: re-checked under the lock, nothing cycled, not counted, later failures still recovered"

# --- (k) the backlog after a recovery is skipped -------------------------------------
# The noise of 2026-11-09: while a recovery runs, its failed tries' own
# failure lines pile up in the follow pipe, and once the Wi-Fi was up the
# watch gave each of them a 10 s wait and a check that passed.  Every good
# judgment now saves, with its counts, the kernel timestamp of the last
# line it saw (wm=), and the watch skips the lines logged at or before it,
# with one log line per wm: no wait, no check, no count.
# The fake log's calls: the boot check (body 0, good); L1's watch check
# and the re-check under the lock (1, both fail); try 1, before its bind
# and its judgment (1, then 2: an MMIO read after the bind, failed); try 2,
# before and judgment (8, good: the state's wm is 2040.300000); every
# later check (9, good: wm=2150.000000).
SKIP_LINE='watch: skipping failure signatures logged before the last good check (already judged)'
mk_sysfs
klog_seq 0 1 1 1 2 8 8 9
# L1 is watched and recovered; L2..L4 were judged by try 2 (L3 in the same
# second as the wm, its micros with a leading zero; L4 equal to the wm);
# L5, one microsecond after the wm, is watched; L6 was judged by L5's
# check (a new wm, so a second skip line); L7, without a timestamp, is
# watched.  L5's check passes only because the fake log does not show L5's
# own line -- a shortcut of the fixture: what this proves is that L5 is
# watched, not skipped.
printf '%s\n' \
 '[ 2000.100000] brcmfmac4358 PCIe 0000:01:00.0: brcmf_pcie_probe: failed err=-110' \
 '[ 2005.200000] brcmfmac: MMIO read failed (0xffffffff) at 0x18002030' \
 '[ 2040.089000] brcmfmac: brcmf_fwmem: Firmware has halted' \
 '[ 2040.300000] brcmfmac: brcmf_pcie_get_mbdata: mailbox status reads all ones' \
 '[ 2040.300001] brcmfmac: brcmf_fwmem: Firmware has halted' \
 '[ 2120.600000] brcmfmac: MMIO read failed (0xffffffff) at 0x18002030' \
 'brcmfmac: MMIO read failed (0xffffffff) at 0x18002030' \
 > "$t/kfollow.lines"
wg run
[ "$WG_RC" = 0 ] || fail "(k) run exits 0 (got $WG_RC)"
want='watch: failure signature (probe_failed) in the kernel log
watch: failure signature (fw_halted) in the kernel log
watch: failure signature (mmio_read) in the kernel log'
[ "$(grep 'watch: failure signature' "$t/log" || true)" = "$want" ] \
    || fail "(k) L1, L5 and L7 watched, in order, and nothing else (log: $(cat "$t/log"))"
[ "$(grep -cxF "$SKIP_LINE" "$t/log" || true)" = 2 ] \
    || fail "(k) one skip line per wm, two in all (log: $(cat "$t/log"))"
[ "$(grep -c '^10$' "$t/sleeps" || true)" = 3 ] \
    || fail "(k) three debounce waits, for L1, L5 and L7 only (sleeps: $(tr '\n' ' ' < "$t/sleeps"))"
[ "$(host_binds)" = 2 ] || fail "(k) two host binds, try 1's and try 2's (got $(host_binds))"
[ "$(cat "$t/trace")" = "$CYCLE
$CYCLE" ] || fail "(k) two whole-chip cycles, in order (trace: $(cat "$t/trace"))"
grep -qF 'recovery try 1 of 6: failed: failure signature after the bind (mmio_read)' "$t/log" \
    || fail "(k) try 1 fails on the MMIO read after its bind (log: $(cat "$t/log"))"
grep -qF 'recovery try 2 of 6: the Wi-Fi came up' "$t/log" \
    || fail "(k) try 2 brings the Wi-Fi up (log: $(cat "$t/log"))"
[ "$(grep -c 'recovered: the Wi-Fi is up' "$t/log" || true)" = 1 ] \
    || fail "(k) one recovery, logged once (log: $(cat "$t/log"))"
[ "$(grep -c 'watch check: the Wi-Fi is up' "$t/log" || true)" = 2 ] \
    || fail "(k) L5's and L7's checks pass (log: $(cat "$t/log"))"
grep -qxF 'wm=2150.000000' "$t/run/guard.state" \
    || fail "(k) the state holds the last good check's wm (state: $(cat "$t/run/guard.state" 2>/dev/null || true))"
! grep -Eq '[0-9]+\.[0-9]{6}' "$t/log" \
    || fail "(k) no kernel timestamp in any log line (log: $(cat "$t/log"))"
echo "ok - backlog after a recovery: what the last good check judged is skipped, one line per check; the rest still watched"

# --- (k2) no timestamps, nothing skipped ----------------------------------------------
# A kernel log without timestamps gives the judgments no wm, so the state
# has none: then no line is skipped, timestamped or not, and each one gets
# its wait and its check, as before.
mk_sysfs
klog_seq 10
printf '%s\n' \
 '[ 2200.100000] brcmfmac: MMIO read failed (0xffffffff) at 0x18002030' \
 '[ 2200.200000] brcmfmac: brcmf_fwmem: Firmware has halted' \
 > "$t/kfollow.lines"
wg run
[ "$WG_RC" = 0 ] || fail "(k2) run exits 0 (got $WG_RC)"
[ "$(grep -c 'watch: failure signature' "$t/log" || true)" = 2 ] \
    || fail "(k2) both lines watched (log: $(cat "$t/log"))"
! grep -qF "$SKIP_LINE" "$t/log" || fail "(k2) nothing skipped (log: $(cat "$t/log"))"
[ "$(grep -c '^10$' "$t/sleeps" || true)" = 2 ] \
    || fail "(k2) two debounce waits (sleeps: $(tr '\n' ' ' < "$t/sleeps"))"
[ "$(host_binds)" = 0 ] || fail "(k2) no recovery, no host bind (got $(host_binds))"
[ -f "$t/run/guard.state" ] || fail "(k2) the good checks saved a state"
! grep -q '^wm=' "$t/run/guard.state" \
    || fail "(k2) a log without timestamps saves no wm (state: $(cat "$t/run/guard.state"))"
echo "ok - a log without timestamps: no wm in the state, nothing skipped, every line watched"

# --- (m) a turned-over ring buffer no longer hides a failure --------------------------
# The flaw of 2026-11-10: the kernel log is a ring buffer, about 1500
# lines on the tablet, and it turns over within hours.  A judgment saved
# its counts over the whole log; hours later the lines of those very
# failures are gone, and a new failure brings a count back to what the
# state holds, not above it -- missed, and a failure that leaves the
# netdev then passes for "up".  Body 11 is that log: every line newer than
# the 2040.300000 of the state's wm, none stamped with it (the wm line
# itself has turned over), a probe failure in it, the interface kept.  The
# state is what body 8's good judgment would have saved.  With whole-log
# counts, probe_failed=1 is not above the state's 1 and the interface is
# there, so the old check said "up"; the judgment now reads the lines
# after the wm -- every line still in the buffer.
mk_sysfs
printf '%s\n' 'probe_failed=1' 'mmio_read=1' 'fw_halted=1' 'mailbox_ones=0' \
    'ring_depth=0' 'query_timeout=0' 'wm=2040.300000' > "$t/run/guard.state"
klog_seq 11
wg check
[ "$WG_RC" = 1 ] || fail "(m) a failure past the state's counts exits 1 (got $WG_RC)"
[ "$(wc -l < "$t/out" | tr -d ' ')" = 1 ] \
    || fail "(m) one line on stdout (got $(cat "$t/out"))"
grep -q '(probe_failed)' "$t/out" \
    || fail "(m) the reason names the probe failure (got $(cat "$t/out"))"
echo "ok - turned-over ring buffer: a failure past the state's wm is judged, counts or no counts"

# --- (m2) the query rule counts the timeouts since the mark ---------------------------
# The older flaw: the query timeout counts only from its second
# occurrence in what a judgment reads, and what it read was the whole
# log.  A log that already held one timeout, and a start whose own good
# bring-up showed one, counted two: a start that came up was failed and
# the chip cycled again for nothing.  The rule now counts the timeouts in
# the lines since the mark.  The state is body 7's good judgment (six
# counts at 0, wm=3.500000); body 12 holds one timeout after that mark,
# body 13 two.  check only reads, so the state stays as written between
# the two.
mk_sysfs
printf '%s\n' 'probe_failed=0' 'mmio_read=0' 'fw_halted=0' 'mailbox_ones=0' \
    'ring_depth=0' 'query_timeout=0' 'wm=3.500000' > "$t/run/guard.state"
klog_seq 12
wg check
[ "$WG_RC" = 0 ] \
    || fail "(m2) one timeout since the mark does not fail a check (got $WG_RC, out: $(cat "$t/out"))"
klog_seq 13
wg check
[ "$WG_RC" = 1 ] \
    || fail "(m2) two timeouts since the mark fail the check (got $WG_RC)"
grep -q '(query_timeout)' "$t/out" \
    || fail "(m2) the reason names the query timeout (got $(cat "$t/out"))"
echo "ok - query timeouts: one since the mark is nothing, two since the mark fail the check"

# --- (m3) a try's good start with one query timeout is good ---------------------------
# The same flaw from the recovery side: the log before the bind already
# held one timeout (body 7), and the start's own good bring-up added one
# (body 12) -- two in the whole log, so the old judgment failed a start
# that came up.  The try now judges the lines after the wm of its
# pre-bind snapshot: body 12's one timeout is the start's own alone, the
# try is good, one cycle, and the saved state carries the whole-log
# digest with its wm.
mk_sysfs
rm -rf "$S/class/net/wlp1s0"
klog_seq 7 12
wg recover 1
[ "$WG_RC" = 0 ] \
    || fail "(m3) a good start whose log holds a prior timeout exits 0 (got $WG_RC)"
grep -q 'recovery try 1 of 1: the Wi-Fi came up' "$t/log" \
    || fail "(m3) the good try is logged (log: $(cat "$t/log"))"
[ "$(host_binds)" = 1 ] || fail "(m3) exactly one host bind (got $(host_binds))"
grep -q '^wm=60\.500000$' "$t/run/guard.state" \
    || fail "(m3) the state holds the start's wm (state: $(cat "$t/run/guard.state" 2>/dev/null || true))"
echo "ok - a try's good start with one query timeout of its own: good, one cycle, the wm saved"

# --- (h) no address, no SSID, no kernel line in anything the script says -------------
# The fake log's bodies carry a MAC address; nothing the script printed in
# any scenario (log lines, the trace, check's reason, stderr) may match one.
if grep -Eq '([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}' \
        "$t/log.all" "$t/trace.all" "$t/out.all" "$t/err.all"; then
    grep -En '([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}' "$t/log.all" "$t/trace.all" "$t/out.all" "$t/err.all" >&2 || true
    fail "(h) something the script said matches a MAC address"
fi
echo "ok - privacy: no MAC address in any log line, trace write or reason"

# --- (i) the unit, the enabling and the checks ---------------------------------------
grep -qx 'Type=simple' "$UNIT" || fail "(i) the unit is Type=simple"
grep -qx 'ExecStart=/usr/local/sbin/t715-wifi-guard run' "$UNIT" || fail "(i) the unit runs run"
grep -Eqx 'After=.*NetworkManager\.service.*bluetooth\.service.*' "$UNIT" \
    || fail "(i) the unit comes after NetworkManager and bluetooth"
grep -qx 'Restart=always' "$UNIT" || fail "(i) the unit restarts whatever its exit"
grep -qx 'WantedBy=multi-user.target' "$UNIT" || fail "(i) the unit is wanted by multi-user.target"
grep -q 'systemctl enable.*t715-wifi-guard.service' "$here/rootfs/configure-system.sh" \
    || fail "(i) configure-system.sh enables the unit"
grep -q 't715-wifi-guard' "$here/tests/verify-rootfs.sh" \
    || fail "(i) verify-rootfs.sh checks the guard"
grep -q 't715-wifi-guard' "$here/../docs/image/ROOTFS.md" \
    || fail "(i) docs/image/ROOTFS.md tells the story"
echo "ok - the unit, configure-system.sh, verify-rootfs.sh and ROOTFS.md all carry it"

echo "PASS"
