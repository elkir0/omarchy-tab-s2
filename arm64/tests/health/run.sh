#!/usr/bin/env bash
# tests/run.sh — off-device verification suite for tools/t715-arm64-health

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HEALTH="${REPO_ROOT}/tools/t715-arm64-health"
GOOD="${SCRIPT_DIR}/fixtures/good"
BAD="${SCRIPT_DIR}/fixtures/bad"

# git keeps no empty directory: these five entries of each fixture are directories with nothing
# inside, and the tool reads their presence. They are put back before the first run.
for fixture in "$GOOD" "$BAD"; do
    mkdir -p "$fixture/sys/block/mmcblk1" "$fixture/sys/class/bluetooth/hci0" "$fixture/sys/fs/pstore"
    mkdir -p "$fixture/sys/bus/pci/drivers/brcmfmac/0000:01:00.0"
    mkdir -p "$fixture/sys/bus/platform/drivers/panfrost/14ac0000.gpu"
done

FAILURES=0

fail() {
    printf 'TEST FAIL: %s\n' "$*" >&2
    FAILURES=$((FAILURES + 1))
}

pass() {
    printf 'TEST PASS: %s\n' "$*"
}

run_health() {
    local root="$1"
    shift
    T715_ROOT="$root" T715_BIN="${root}/bin" bash "$HEALTH" "$@"
}

# 1. Good fixture (text mode)
good_out="$(run_health "$GOOD")"
good_rc=$?
if [ "$good_rc" -ne 0 ]; then
    fail "good fixture exited $good_rc (expected 0)"
    printf '%s\n' "$good_out" >&2
else
    pass "good fixture exited 0"
fi

if printf '%s\n' "$good_out" | grep -q '^FAIL '; then
    fail "good fixture produced FAIL line(s)"
    printf '%s\n' "$good_out" | grep '^FAIL ' >&2
else
    pass "good fixture produced no FAIL lines"
fi

if printf '%s\n' "$good_out" | grep -q '^SUMMARY pass=23 warn=0 fail=0$'; then
    pass "good fixture summary is pass=23 warn=0 fail=0"
else
    fail "good fixture unexpected summary: $(printf '%s\n' "$good_out" | tail -n 1)"
fi

if printf '%s\n' "$good_out" | grep -qiE 'serialno|GOODSECRET123|Kernel command line'; then
    fail "good fixture leaked serialno or Kernel command line"
else
    pass "good fixture did not leak serialno or Kernel command line"
fi

# The good fixture's atlas0 has a passive trip without a map (as stage 1 leaves atlas' 81 C one):
# allowed while another passive trip of the zone throttles, and named.
if printf '%s\n' "$good_out" | grep -q '^PASS thermal: .*atlas0-thermal passive trip(s) 2 without a map'; then
    pass "good fixture: an unbound passive trip next to a bound one is a PASS, and named"
else
    fail "good fixture: the unbound passive trip of atlas0 is not a named PASS"
    printf '%s\n' "$good_out" | grep ' thermal: ' >&2 || true
fi

# 2. Bad fixture (text mode)
bad_out="$(run_health "$BAD")"
bad_rc=$?
if [ "$bad_rc" -ne 1 ]; then
    fail "bad fixture exited $bad_rc (expected 1)"
else
    pass "bad fixture exited 1"
fi

for chk in cpus cpufreq thermal systemd kernel-log; do
    if printf '%s\n' "$bad_out" | grep -q "^FAIL ${chk}: "; then
        pass "bad fixture reported FAIL for ${chk}"
    else
        fail "bad fixture did not report FAIL for ${chk}"
        printf '%s\n' "$bad_out" | grep " ${chk}: " >&2 || true
    fi
done

if printf '%s\n' "$bad_out" | grep -Eq '^(WARN|FAIL) wifi: '; then
    pass "bad fixture reported WARN/FAIL for wifi"
else
    fail "bad fixture did not report WARN/FAIL for wifi"
fi

if printf '%s\n' "$bad_out" | grep -q '^WARN kboot-mark: .*t715\.kbootmark=0'; then
    pass "bad fixture reported t715.kbootmark=0 reason on kboot-mark"
else
    fail "bad fixture did not report t715.kbootmark=0 on kboot-mark"
fi

if printf '%s\n' "$bad_out" | grep -qE 'serialno|XYZ'; then
    fail "bad fixture leaked serialno or XYZ in text output"
else
    pass "bad fixture never printed serialno or XYZ in text output"
fi

# 3. --json output (good and bad fixtures)
good_json="$(run_health "$GOOD" --json)"
good_json_rc=$?
if [ "$good_json_rc" -ne 0 ]; then
    fail "good fixture --json exited $good_json_rc (expected 0)"
else
    pass "good fixture --json exited 0"
fi

bad_json="$(run_health "$BAD" --json)"
bad_json_rc=$?
if [ "$bad_json_rc" -ne 1 ]; then
    fail "bad fixture --json exited $bad_json_rc (expected 1)"
else
    pass "bad fixture --json exited 1"
fi

if printf '%s\n' "$bad_json" | grep -qE 'serialno|XYZ'; then
    fail "bad fixture leaked serialno or XYZ in --json output"
else
    pass "bad fixture never printed serialno or XYZ in --json output"
fi

if command -v python3 >/dev/null 2>&1; then
    if printf '%s\n' "$good_json" | python3 -m json.tool >/dev/null 2>&1; then
        pass "good fixture --json is valid JSON"
    else
        fail "good fixture --json is invalid JSON"
    fi
    if printf '%s\n' "$bad_json" | python3 -m json.tool >/dev/null 2>&1; then
        pass "bad fixture --json is valid JSON"
    else
        fail "bad fixture --json is invalid JSON"
    fi
else
    printf 'SKIP: python3 not found; skipping JSON syntax validation\n'
fi

# 4. --only cpus,battery
only_out="$(run_health "$GOOD" --only cpus,battery)"
only_rc=$?
only_lines="$(printf '%s\n' "$only_out" | wc -l | awk '{print $1}')"
only_check_names="$(printf '%s\n' "$only_out" | awk '/^(PASS|WARN|FAIL) / { sub(/:$/, "", $2); print $2 }' | tr '\n' ',' | sed 's/,$//')"

if [ "$only_rc" -ne 0 ]; then
    fail "--only cpus,battery exited $only_rc (expected 0)"
elif [ "$only_lines" -ne 3 ]; then
    fail "--only cpus,battery printed ${only_lines} lines (expected 3)"
    printf '%s\n' "$only_out" >&2
elif [ "$only_check_names" != "cpus,battery" ]; then
    fail "--only cpus,battery ran '${only_check_names}' (expected 'cpus,battery')"
elif ! printf '%s\n' "$only_out" | grep -q '^SUMMARY pass=2 warn=0 fail=0$'; then
    fail "--only cpus,battery unexpected summary: $(printf '%s\n' "$only_out" | tail -n 1)"
else
    pass "--only cpus,battery printed exactly cpus, battery, and SUMMARY"
fi

# 5. Missing external tool handled with WARN (no crash)
missing_out="$(T715_ROOT="$GOOD" T715_BIN="${GOOD}/bin" T715_CMD_DMESG="nonexistent-dmesg-bin" bash "$HEALTH" --only kernel-log)"
missing_rc=$?
if [ "$missing_rc" -ne 0 ]; then
    fail "missing dmesg exited $missing_rc (expected 0 with WARN)"
elif ! printf '%s\n' "$missing_out" | grep -q '^WARN kernel-log: .*missing'; then
    fail "missing dmesg did not emit WARN missing: ${missing_out}"
else
    pass "missing tool emits WARN instead of crashing"
fi

if [ "$FAILURES" -gt 0 ]; then
    printf 'TESTS FAILED (%d failure(s))\n' "$FAILURES" >&2
    exit 1
fi

printf 'ALL TESTS PASSED\n'
exit 0
