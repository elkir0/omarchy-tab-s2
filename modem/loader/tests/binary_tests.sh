#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Black-box checks of the real binary (real Linux ops) on synthetic files,
# under the nv_guard.so interposer exported by run_tests.sh.
#   binary_tests.sh BUILD_DIR FIXTURE_DIR
# shannon-loader-testpin differs from shannon-loader only by its BOOT SHA-256
# pin (the synthetic BOOT's); the production binary must refuse that BOOT.
set -eu

B=$1
FIX=$2
T="$B/shannon-loader-testpin"
P="$B/shannon-loader"
G="$B/nv_guard.so"
fails=0
OUT="${TMPDIR:-/tmp}/sl_bin.$$.out"
RUNDIR="/run/shannon-test-$$"

COMMON="--boot-dev=/dev/null --ipc-dev=/dev/null --rfs-dev=/dev/null \
--image=$FIX/bin/radio.img --lli-control=$FIX/bin/lli_control \
--cp-status=$FIX/bin/cp_status --allow-hw-param=$FIX/bin/allow_hw \
--battery-capacity=$FIX/bin/capacity --battery-temp=$FIX/bin/temp \
--battery-current=$FIX/bin/current_now --state-file=$RUNDIR/cp-state"

nv() { echo "--nv=$FIX/small/$1/nv_data.bin --nv-manifest=$FIX/small/$1/manifest.sha256"; }

# the arguments that differ from $COMMON, for the report
label() {
	for a in "$@"; do
		case " $COMMON " in *" $a "*) continue ;; esac
		printf '%s ' "$a"
	done | sed "s#$FIX#\$FIX#g"
}

run() {	# expected-rc must-contain binary args...
	want=$1; grep_for=$2; bin=$3; shift 3
	rc=0
	# shellcheck disable=SC2086
	LD_PRELOAD="$G" "$bin" "$@" >"$OUT" 2>&1 || rc=$?
	set -- "$(basename "$bin")" "$@"
	if [ "$rc" -eq "$want" ] && { [ -z "$grep_for" ] || grep -q -- "$grep_for" "$OUT"; }; then
		printf 'ok   rc=%s %s\n' "$rc" "$(label "$@")"
	else
		printf 'FAIL rc=%s (want %s, grep "%s") %s\n' "$rc" "$want" "$grep_for" "$(label "$@")"
		sed 's/^/     | /' "$OUT" | tail -15
		fails=$((fails + 1))
	fi
}

# shellcheck disable=SC2046,SC2086
{
run 0 "dry run: preflight passed" "$T" $COMMON $(nv ok) --dry-run
run 0 "matches MD5(nv) (unsalted)" "$T" $COMMON $(nv ok) --dry-run
run 0 "RIL salt" "$T" $COMMON $(nv salted) --dry-run --nv-md5=require
run 3 "is missing" "$T" $COMMON $(nv missing) --dry-run
run 3 "no padding" "$T" $COMMON $(nv short) --dry-run
run 3 "no padding" "$T" $COMMON $(nv long) --dry-run
run 3 "every byte is 0xFF" "$T" $COMMON $(nv ff) --dry-run
run 0 "WARNING" "$T" $COMMON $(nv ff) --dry-run --allow-blank-nv
run 3 "SHA-256 mismatch" "$T" $COMMON $(nv shabad) --dry-run
run 3 "symbolic link" "$T" $COMMON $(nv symlink) --dry-run
run 3 "manifest" "$T" $COMMON $(nv nomanifest) --dry-run
run 3 "mounted read-write" "$T" $COMMON --nv-mode=direct --nv=$FIX/small/ok/nv_data.bin --dry-run
run 4 "not the pinned stock BOOT" "$T" $COMMON $(nv ok) --dry-run --image=$FIX/bin/radio_badboot.img
run 4 "not the pinned stock BOOT" "$P" $COMMON $(nv ok) --dry-run
run 2 "absolute path" "$T" $COMMON --nv=relative/nv_data.bin --dry-run
run 2 "" "$T" --bogus-option
run 2 "" "$T" --attempts=4
run 5 "missing or not a character device" "$T" $COMMON $(nv ok) --dry-run --boot-dev=/nonexistent
run 5 "allow_hw" "$T" $COMMON $(nv ok) --dry-run --allow-hw-param=$FIX/bin/cp_status
run 8 "refusing CP power-on" "$T" $COMMON $(nv ok) --dry-run --battery-capacity=$FIX/bin/capacity_low
# ioctls on /dev/null fail with ENOTTY: one attempt, MODEM_OFF, exit 6
run 6 "boot failed after 1 attempts" "$T" $COMMON $(nv ok) --stop-after=power
run 2 "must be under /run/" "$T" $COMMON $(nv ok) --stop-after=power --state-file=$FIX/small/ok/cp-state
run 0 "dd39fae36c2ccfbc28c3562c405962c827b2cf5d66f9e63d3fb90223dd0f94f4" "$P" --version
run 0 "TEST BUILD" "$T" --version
}

# the power rung published the CP state (atomic replace under /run/)
if [ "$(cat "$RUNDIR/cp-state" 2>/dev/null)" = "session=1 state=offline" ] &&
   [ ! -e "$RUNDIR/cp-state.tmp" ]; then
	echo "ok   $RUNDIR/cp-state = \"session=1 state=offline\" (no temporary left)"
else
	echo "FAIL state file: $(cat "$RUNDIR/cp-state" 2>&1)"; fails=$((fails + 1))
fi
rm -rf "$RUNDIR"

# the loader never wrote a file in the fixture tree
if find "$FIX" -newer "$FIX/bin/allow_hw" -type f | grep -q .; then
	echo "FAIL files modified under the fixture tree:"; find "$FIX" -newer "$FIX/bin/allow_hw" -type f
	fails=$((fails + 1))
else
	echo "ok   no file modified or added under the fixture tree"
fi
rm -f "$OUT"
[ "$fails" -eq 0 ]
