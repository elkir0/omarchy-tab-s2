#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# shannon-loader test runner (called by `make test`).
#   run_tests.sh BUILD_DIR FIXTURE_DIR
# The fixture tree lives outside the repository (default /tmp) and is made
# read-only before any loader code runs; everything that executes loader code
# runs under the nv_guard.so LD_PRELOAD tripwire (except the ASan build,
# which must be first in the library list).
set -eu

B=$1
FIX=$2
HERE=$(cd "$(dirname "$0")" && pwd)
fails=0

step() { printf '\n=== %s\n' "$*"; }
ok() { printf 'ok   %s\n' "$*"; }
ko() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }

step "fixtures in $FIX (synthetic, PRNG patterns)"
if [ -d "$FIX" ]; then chmod -R u+w "$FIX"; rm -rf "$FIX"; fi
"$B/mkfixtures" "$FIX"

step "hash cross-check against coreutils"
"$B/test_hashes" >/dev/null && ok "test_hashes vectors" || ko "test_hashes vectors"
for d in "$FIX/real" "$FIX/small/ok" "$FIX/small/salted"; do
	if (cd "$d" && sha256sum -c --quiet manifest.sha256); then
		ok "sha256sum -c $(basename "$d")/manifest.sha256"
	else
		ko "sha256sum -c $d"
	fi
done
a=$(md5sum < "$FIX/small/ok/nv_data.bin" | cut -c1-32)
b=$(cut -c1-32 "$FIX/small/ok/nv_data.bin.md5")
[ "$a" = "$b" ] && ok "MD5(nv) == md5sum" || ko "MD5(nv) $a != $b"
a=$( (cat "$FIX/small/salted/nv_data.bin"; printf 'Samsung_Android_RIL') | md5sum | cut -c1-32)
b=$(cut -c1-32 "$FIX/small/salted/nv_data.bin.md5")
[ "$a" = "$b" ] && ok "MD5(nv || salt) == md5sum" || ko "salted MD5 $a != $b"

chmod -R a-w "$FIX"

export NV_GUARD_PATHS="$FIX:/efs:/var/lib/shannon"
export NV_GUARD_SYSFS="/sys/bus/platform/devices/10f24000.mipi-lli/lli_control:/dev/mipi-lli/lli_control:/sys/devices/10f24000.mipi-lli/lli_control:/sys/devices/platform/10f24000.mipi-lli/lli_control:/sys/bus/platform/drivers/mif_sipc5/mif_pdata/cp_status/value:$FIX/bin/lli_control:$FIX/bin/cp_status"
export NV_GUARD_LOG="${TMPDIR:-/tmp}/nv_guard.$$.log"
rm -f "$NV_GUARD_LOG"
G="$B/nv_guard.so"

step "nv_guard positive controls (each must exit 86)"
expect_guard() {
	rc=0
	LD_PRELOAD="$G" "$B/guard_selftest" "$@" 2>/dev/null || rc=$?
	if [ "$rc" -eq 86 ]; then ok "guard stops: $*"; else ko "guard missed: $* (rc $rc)"; fi
}
expect_guard rw "$FIX/small/ok/nv_data.bin"
expect_guard wronly "$FIX/real/nv_data.bin"
expect_guard creat "$FIX/small/missing/nv_data.bin"
expect_guard openat "$FIX/small/ok/new"
expect_guard fopen "$FIX/small/ok/nv_data.bin.md5"
expect_guard trunc "$FIX/small/ok/nv_data.bin"
expect_guard rename "$FIX/small/ok/nv_data.bin" "$FIX/small/ok/x"
expect_guard unlink "$FIX/small/ok/manifest.sha256"
expect_guard mkdir "$FIX/small/newdir"
expect_guard creat /efs/nv_data.bin
expect_guard wronly "$FIX/bin/lli_control"
expect_guard ioctl /dev/null
rc=0; LD_PRELOAD="$G" "$B/guard_selftest" ro "$FIX/small/ok/nv_data.bin" || rc=$?
[ "$rc" -eq 0 ] && ok "guard allows read-only open" || ko "read-only open refused ($rc)"
rm -f "$NV_GUARD_LOG"

step "level-1 tests (mock + virtual clock) under nv_guard"
rc=0; LD_PRELOAD="$G" "$B/test_loader" "$FIX" || rc=$?
[ "$rc" -eq 0 ] && ok "test_loader" || ko "test_loader (rc $rc)"

step "level-1 tests, ASan + UBSan build"
# LeakSanitizer does not run under qemu-user (armv7 container on arm64 hosts)
case $(uname -m) in arm*) leaks=0 ;; *) leaks=1 ;; esac
rc=0; ASAN_OPTIONS=detect_leaks=$leaks "$B/test_loader_asan" "$FIX" >/dev/null || rc=$?
[ "$rc" -eq 0 ] && ok "test_loader_asan" || ko "test_loader_asan (rc $rc)"

step "binary tests (real binary, real Linux ops) under nv_guard"
rc=0; sh "$HERE/binary_tests.sh" "$B" "$FIX" || rc=$?
[ "$rc" -eq 0 ] && ok "binary tests" || ko "binary tests"

step "safety checks (sources and objects)"
rc=0; sh "$HERE/safety_check.sh" "$B" || rc=$?
[ "$rc" -eq 0 ] && ok "safety checks" || ko "safety checks"

if [ -s "$NV_GUARD_LOG" ]; then
	ko "nv_guard recorded violations:"
	cat "$NV_GUARD_LOG"
else
	ok "nv_guard: no violation recorded"
fi
rm -f "$NV_GUARD_LOG"
chmod -R u+w "$FIX" && rm -rf "$FIX"

echo
if [ "$fails" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "$fails FAILURE(S)"; fi
[ "$fails" -eq 0 ]
