#!/usr/bin/env bash
# tests/sleep/run.sh — off-device verification suite for the 64-bit image's
# sleep (arm64/rootfs/overlay/: t715-sleep, t715-wifi-guard, their units) and
# its on-device scripts (ondevice/, run later on the tablet, not here).
#
# The suites, ported from the 32-bit image's image/tests/ with the 64-bit
# cases added:
#   test_t715_sleep.sh          t715-sleep on a fake root, its units, the build's
#                               enabling and checks; (m) the 64-bit cases
#   test_t715_wifi_guard.sh     t715-wifi-guard on a fake sysfs and kernel log;
#                               (t) to (t3) the 64-bit cases (the A57 boost)
#   test_sleep_soak_helpers.sh  ondevice/sleep-soak.sh's helpers; (g) the clock's
#                               judgment
#   test_arm64.sh               the 64-bit build, image checks, on-device scripts
#                               and docs
# They run side by side (the Wi-Fi guard's takes a few minutes); each one's
# output is printed in this order once all have ended.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUITES="test_t715_sleep.sh test_t715_wifi_guard.sh test_sleep_soak_helpers.sh test_arm64.sh"

FAILURES=0

fail() {
    printf 'TEST FAIL: %s\n' "$*" >&2
    FAILURES=$((FAILURES + 1))
}

pass() {
    printf 'TEST PASS: %s\n' "$*"
}

out="$(mktemp -d "${TMPDIR:-/tmp}/t715-arm64-sleep-run.XXXXXX")"
trap 'rm -rf "$out"' EXIT

for s in $SUITES; do
    ( bash "${SCRIPT_DIR}/${s}" > "${out}/${s}.log" 2>&1; echo $? > "${out}/${s}.rc" ) &
done
wait

for s in $SUITES; do
    rc="$(cat "${out}/${s}.rc" 2>/dev/null || echo 99)"
    sed 's/^/    /' "${out}/${s}.log"
    if [ "$rc" = 0 ] && [ "$(tail -n 1 "${out}/${s}.log")" = PASS ]; then
        pass "${s} ($(grep -c '^ok - ' "${out}/${s}.log") groups)"
    else
        fail "${s} exited ${rc}"
    fi
done

if [ "$FAILURES" -gt 0 ]; then
    printf 'TESTS FAILED (%d failure(s))\n' "$FAILURES" >&2
    exit 1
fi

printf 'ALL TESTS PASSED\n'
exit 0
