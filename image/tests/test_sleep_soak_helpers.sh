#!/usr/bin/env bash
# test_sleep_soak_helpers.sh — off-device test of the pure helpers of
# image/tests/ondevice/sleep-soak.sh, the on-device soak of the daily
# suspend.  The script is sourced with SOAK_LIB_ONLY=1, which defines its
# helpers and runs nothing (the soak itself needs the tablet), and the
# helpers are fed fixed samples: the median of odd and even counts, the hex
# words of a sample wake line, the "cp" word of the modem status JSON, and
# the kernel-log error counts since a timestamp mark, on a sample log with
# lines before and after the mark.  Nothing but the numbers and words the
# soak is allowed to log ever leaves the helpers, which the last group
# checks.  In the style of tests/test_t715_idle.sh (omarchy-mobile 5f7ba48,
# MIT).
#
# Usage: tests/test_sleep_soak_helpers.sh
# Prints "ok - ..." per group, "PASS" at the end; exit 1 on the first
# failure.  Needs bash 3.2 or later and /bin/sh; nothing outside a temporary
# directory.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SOAK="$here/tests/ondevice/sleep-soak.sh"
[ -f "$SOAK" ] || { echo "SETUP ERROR: no $SOAK" >&2; exit 2; }

t=$(mktemp -d "${TMPDIR:-/tmp}/t715-soak-test.XXXXXX")
cleanup() { rm -rf "$t"; }
trap cleanup EXIT

fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

# The helpers alone: SOAK_LIB_ONLY stops the script before the soak.
# shellcheck disable=SC1090  # the path is built above, from $here
SOAK_LIB_ONLY=1 . "$SOAK"

# --- (a) the median: odd counts, even counts, one value ---------------------------
[ "$(soak_median 7)" = 7 ] || fail "(a) the median of one value is the value (got $(soak_median 7))"
[ "$(soak_median 1 3 5)" = 3 ] || fail "(a) the median of 1 3 5 is 3 (got $(soak_median 1 3 5))"
[ "$(soak_median 9 1 5)" = 5 ] || fail "(a) the median of 9 1 5 is 5, unsorted input (got $(soak_median 9 1 5))"
[ "$(soak_median 4 1 3 2 5)" = 3 ] || fail "(a) the median of 4 1 3 2 5 is 3 (got $(soak_median 4 1 3 2 5))"
[ "$(soak_median 20 60 40 80 100)" = 60 ] \
    || fail "(a) the median of 20 60 40 80 100 is 60 (got $(soak_median 20 60 40 80 100))"
[ "$(soak_median 1 2)" = 1.5 ] || fail "(a) the median of 1 2 is 1.5 (got $(soak_median 1 2))"
[ "$(soak_median 10 2 30 4)" = 7 ] || fail "(a) the median of 10 2 30 4 is 7 (got $(soak_median 10 2 30 4))"
[ "$(soak_median 3 4)" = 3.5 ] || fail "(a) the median of 3 4 is 3.5 (got $(soak_median 3 4))"
[ "$(soak_median)" = 0 ] || fail "(a) the median of nothing is 0 (got $(soak_median))"
echo "ok - the median: one value, odd counts, even counts (whole and half)"

# --- (b) the wake line's hex words -------------------------------------------------
WAKE_NOEINT='[ 8120.410000] EXYNOS5433: woke up: WAKEUP_STAT 0x00100000, EINT_PEND .. .. .. ..'
WAKE_EINT='[ 9204.000000] EXYNOS5433: woke up: WAKEUP_STAT 0x00008000, EINT_PEND 00 00 04 00'
[ "$(soak_wake_words "$WAKE_NOEINT")" = '0x00100000' ] \
    || fail "(b) the words of a wake with no EINT pending (got $(soak_wake_words "$WAKE_NOEINT"))"
[ "$(soak_wake_stat "$WAKE_NOEINT")" = '0x00100000' ] \
    || fail "(b) WAKEUP_STAT of a wake line (got $(soak_wake_stat "$WAKE_NOEINT"))"
[ -z "$(soak_wake_eint "$WAKE_NOEINT")" ] \
    || fail "(b) EINT_PEND of a wake with none pending is empty (got $(soak_wake_eint "$WAKE_NOEINT"))"
[ "$(soak_wake_words "$WAKE_EINT")" = '0x00008000 00 00 04 00' ] \
    || fail "(b) the words of a wake with an EINT pending (got $(soak_wake_words "$WAKE_EINT"))"
[ "$(soak_wake_stat "$WAKE_EINT")" = '0x00008000' ] \
    || fail "(b) WAKEUP_STAT with an EINT pending (got $(soak_wake_stat "$WAKE_EINT"))"
[ "$(soak_wake_eint "$WAKE_EINT")" = '00 00 04 00' ] \
    || fail "(b) EINT_PEND's words (got $(soak_wake_eint "$WAKE_EINT"))"
[ "$(soak_wake_stat 'no wake line here')" = '' ] \
    || fail "(b) a line without WAKEUP_STAT gives nothing (got $(soak_wake_stat 'no wake line here'))"
echo "ok - the wake line: WAKEUP_STAT's word and EINT_PEND's words, hex only"

# --- (c) the CP's state out of the status JSON -------------------------------------
[ "$(soak_json_word '{"ready":true,"cp":"online","modem":"on"}' cp)" = online ] \
    || fail "(c) a quoted cp word (got $(soak_json_word '{"ready":true,"cp":"online","modem":"on"}' cp))"
[ "$(soak_json_word '{"cp":"booting"}' cp)" = booting ] \
    || fail "(c) a quoted cp word alone (got $(soak_json_word '{"cp":"booting"}' cp))"
[ "$(soak_json_word '{"cp":off}' cp)" = off ] \
    || fail "(c) a bare cp value (got $(soak_json_word '{"cp":off}' cp))"
[ -z "$(soak_json_word '{"modem":"on"}' cp)" ] \
    || fail "(c) a JSON without cp gives nothing (got $(soak_json_word '{"modem":"on"}' cp))"
[ -z "$(soak_json_word '' cp)" ] || fail "(c) an empty JSON gives nothing"
echo "ok - the JSON: the cp word, quoted or bare, and nothing without it"

# --- (d) the kernel log since a mark ------------------------------------------------
# The line at 99.000000 carries an error word before the mark: the soak's
# cycle must not count it, and a mark whose own line has left the ring
# buffer (90.000000) brings every line back in, that one included.
KLOG='[ 99.000000] brcmfmac: MMIO read failed (0xffffffff) at 0x18002030
[ 100.000000] brcmfmac4358 PCIe 0000:01:00.0: F/W 7.112.300.14
[ 100.500000] EXYNOS5433: SMC_CMD_SLEEP
[ 160.000000] EXYNOS5433: woke up: WAKEUP_STAT 0x00100000, EINT_PEND .. .. .. ..
[ 161.000000] brcmfmac4358 PCIe 0000:01:00.0: brcmf_pcie_probe: failed err=-110
[ 162.000000] brcmfmac: brcmf_fwmem: Firmware has halted
[ 163.000000] shannon 15690000.hsi: WARNING: unhandled exception
[ 163.500000] Call trace:
[ 164.000000] shannon_uart 15550000.serial: timed out
[ 165.000000] t715-sleep-soak: cycle 3: real, asleep 60 s'
[ "$(soak_klog_mark "$KLOG")" = 165.000000 ] \
    || fail "(d) the mark is the last line's timestamp (got $(soak_klog_mark "$KLOG"))"
SINCE=$(soak_klog_since "$KLOG" 100.000000)
case $SINCE in
*'[ 99.000000]'*) fail "(d) the lines before the mark are not in (a line of 99.000000 is)" ;;
*'[ 100.000000]'*) fail "(d) the mark's own line is not in (the line 100.000000 is)" ;;
*'[ 161.000000]'*) ;;
*) fail "(d) the lines after the mark are in (none of 161.000000 is)" ;;
esac
DIG=$(soak_bad_digest "$SINCE")
[ "$DIG" = 'bug=0 warn=1 oops=0 trace=1 timeout=1 probe=1 halt=1 mmio=0' ] \
    || fail "(d) the error counts since the mark (got $DIG)"
[ "$(soak_digest_total "$DIG")" = 5 ] || fail "(d) the digest's total is 5 (got $(soak_digest_total "$DIG"))"
# the mark's line left the ring buffer: every line still in counts
GONE=$(soak_klog_since "$KLOG" 90.000000)
case $GONE in
*'[ 100.000000]'*) ;;
*) fail "(d) a mark whose line has turned over keeps every line" ;;
esac
[ "$(soak_digest_total "$(soak_bad_digest "$GONE")")" = 6 ] \
    || fail "(d) the turned-over log counts its earlier line too (got $(soak_digest_total "$(soak_bad_digest "$GONE")"))"
# the mark at the very end: nothing after it
[ -z "$(soak_klog_since "$KLOG" 165.000000)" ] \
    || fail "(d) a mark at the last line leaves nothing (got $(soak_klog_since "$KLOG" 165.000000))"
[ "$(soak_digest_total "$(soak_bad_digest "$(soak_klog_since "$KLOG" 165.000000)")")" = 0 ] \
    || fail "(d) no lines since the mark, no errors"
echo "ok - the kernel log: counted since the mark, and since a mark the ring buffer dropped"

# --- (e) what the kernel log says happened -----------------------------------------
[ "$(soak_sleep_kind "$SINCE")" = real ] \
    || fail "(e) a log with the SMC_CMD_SLEEP line is a real sleep (got $(soak_sleep_kind "$SINCE"))"
DRY=$(printf '%s\n' \
    '[ 200.000000] EXYNOS5433: dry run, no SMC_CMD_SLEEP' \
    '[ 200.100000] EXYNOS5433: woke up: WAKEUP_STAT 0x00100000, EINT_PEND .. .. .. ..')
[ "$(soak_sleep_kind "$DRY")" = 'dry run' ] \
    || fail "(e) the dry run line, which holds SMC_CMD_SLEEP too (got $(soak_sleep_kind "$DRY"))"
[ "$(soak_sleep_kind 'nothing happened')" = 'no suspend' ] \
    || fail "(e) a log without a sleep line (got $(soak_sleep_kind 'nothing happened'))"
echo "ok - the sleep kind: real, dry run (checked before real), no suspend"

# --- (f) only counts, fixed words and hex words leave the helpers -------------------
# Everything the helpers print, checked against a raw kernel line, an
# address, a timestamp and anything but digits, dots and the words the soak
# logs.  soak_klog_since returns the lines themselves, by design: the soak
# counts them and never logs them, and it is not run here.
ALL=$(printf '%s\n' \
    "$(soak_median 1 2 3 4)" \
    "$(soak_wake_words "$WAKE_EINT")" \
    "$(soak_json_word '{"cp":"online"}' cp)" \
    "$(soak_bad_digest "$SINCE")" \
    "$(soak_digest_total "$DIG")" \
    "$(soak_sleep_kind "$SINCE")")
case $ALL in
*EXYNOS5433*|*brcmf*|*shannon*|*Call\ trace*|*WARNING*)
    fail "(f) a raw kernel word left a helper (got: $ALL)" ;;
*[0-9].[0-9][0-9][0-9][0-9][0-9][0-9]*)
    fail "(f) a kernel timestamp left a helper (got: $ALL)" ;;
esac
if printf '%s\n' "$ALL" | grep -Eq '([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}'; then
    fail "(f) an address left a helper (got: $ALL)"
fi
echo "ok - privacy: the helpers print counts, fixed words and hex words only"

echo "PASS"
