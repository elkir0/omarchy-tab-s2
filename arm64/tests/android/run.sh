#!/usr/bin/env bash
# arm64/tests/android/run.sh — off-device suites of the Android (Waydroid)
# integration of the 64-bit image: rootfs/overlay-omarchy's t715-android,
# the /usr/local/bin/waydroid wrapper, launchd.py, t715-android-setup and
# the on-device smoke script (tested off-device). Ported from image/tests/
# of the owner's repository; test_t715_android_setup.sh adds the aarch64
# cases (mesa-fix skipped by `all`, one-line no-op on aarch64, 64-bit cfg).
#
# Usage: bash arm64/tests/android/run.sh
# Prints each suite's own output, then PASS/FAIL per suite; the last line is
# "ALL TESTS PASSED" or "TESTS FAILED". Exit 0 only when every suite passes.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SUITES=(
    test_t715_android.sh
    test_t715_android_launchd.sh
    test_t715_android_setup.sh
    test_android_smoke.sh
)

FAILURES=0
for suite in "${SUITES[@]}"; do
    echo "== $suite"
    if bash "$SCRIPT_DIR/$suite"; then
        printf 'PASS  %s\n' "$suite"
    else
        printf 'FAIL  %s\n' "$suite" >&2
        FAILURES=$((FAILURES + 1))
    fi
done

if [ "$FAILURES" -gt 0 ]; then
    printf 'TESTS FAILED (%d suite(s))\n' "$FAILURES" >&2
    exit 1
fi

printf 'ALL TESTS PASSED\n'
exit 0
