#!/usr/bin/env bash
# test_t715_bt_addr.sh — off-device test of t715-bt-addr
# (rootfs/overlay/usr/local/sbin/t715-bt-addr), the script that gives the
# SM-T715's Bluetooth controller an address derived from the eMMC CID.
#
# The script runs on this machine against a btmgmt stand-in that models
# what the kernel's mgmt API does with one controller.  The crux is the
# auto-off window: right after a controller's setup the kernel keeps it
# up for two seconds with HCI_AUTO_OFF set — mgmt reports it unpowered,
# a `power off` is a no-op, and a `public-addr` set inside that window
# is accepted all right, but the kernel's power-on shortcut then never
# writes the address and never announces the controller again
# (net/bluetooth/mgmt.c set_public_address, net/bluetooth/hci_core.c
# hci_power_on).  The model records that as `lost` plus a BUG line in
# its call log.  It also knows the controller appearing only after a few
# polls (hci_bcm registers it before its setup is over), an accepted
# change taking it out of mgmt's list until the address is written, and
# bluetoothd winning the race for the power state (a refused change).
# The scenarios check that the script powers the controller on before
# setting the address — never inside the window —, retries when
# bluetoothd wins, and gives up cleanly; that a copy of the script
# without the `power on` really does lose the controller to the bug; and
# that the address is derived as specified and never logged.
#
# Usage: tests/test_t715_bt_addr.sh
# Prints "ok - ..." per group, "PASS" at the end; exit 1 on the first
# failure (with what the stand-in logged). Needs bash, /bin/sh and
# sha256sum on PATH; works with macOS's bash 3.2. Nothing outside a
# temporary directory.
#
# In the style of test_t715_sdcard.sh.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BT="$here/rootfs/overlay/usr/local/sbin/t715-bt-addr"
[ -f "$BT" ] || { echo "SETUP ERROR: no $BT" >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 \
    || { echo "SETUP ERROR: no sha256sum" >&2; exit 2; }

t=$(mktemp -d "${TMPDIR:-/tmp}/t715-bt-test.XXXXXX")
cleanup() { rm -rf "$t"; }
trap cleanup EXIT
ST=$t

fail() {
    printf 'not ok - %s\n' "$1" >&2
    echo "--- btmgmt calls" >&2
    cat "$ST/calls" 2>/dev/null || true
    echo "--- model state" >&2
    local f
    for f in listed appear_after up autooff addr pending lost refuse bug_never_back; do
        printf '%s=%s\n' "$f" "$(cat "$ST/$f" 2>/dev/null || true)" >&2
    done
    echo "--- stdout" >&2
    cat "$ST/out" 2>/dev/null || true
    echo "--- stderr" >&2
    cat "$ST/err" 2>/dev/null || true
    exit 1
}

# --- stand-ins -----------------------------------------------------------------
# sleep returns at once (the script only ever waits for the controller);
# btmgmt answers from the model's state, in $T715_TEST_MGMT, one value
# per file.
mkdir -p "$t/bin"
cat > "$t/bin/sleep" <<'STUB'
#!/bin/sh
exit 0
STUB
cat > "$t/bin/btmgmt" <<'STUB'
#!/bin/sh
# A model of the kernel's mgmt API for one controller.  State in
# $T715_TEST_MGMT, one value per file: listed, appear_after, up, autooff,
# addr, pending, lost, refuse, bug_never_back.  Every call is appended to
# `calls`; a BUG line marks the race the script must avoid.  Like the
# real btmgmt it exits 0 even when a command fails.
M=${T715_TEST_MGMT:-}
[ -n "$M" ] && [ -d "$M" ] || exit 0
rd() { cat "$M/$1" 2>/dev/null || echo 0; }
wr() { printf '%s\n' "$2" > "$M/$1"; }
idx=0
while [ "${1:-}" = "--index" ]; do
    idx=$2
    shift 2
done
printf '%s\n' "$*" >> "$M/calls"
cmd=${1:-}
arg=${2:-}
invalid_index() {
    echo "Reading info for hci$idx failed with status 0x11 (Invalid Index)" >&2
    exit 0
}
# Not there yet: still waiting to appear, or lost to the bug.
if [ "$(rd appear_after)" -gt 0 ] || [ "$(rd lost)" = 1 ] || [ "$(rd listed)" != 1 ]; then
    if [ "$cmd" = info ] && [ "$(rd appear_after)" -gt 0 ]; then
        # The appear_after'th poll brings the controller up, inside the
        # auto-off window.
        n=$(($(rd appear_after) - 1))
        wr appear_after "$n"
        if [ "$n" -eq 0 ]; then
            wr listed 1
            wr up 1
            wr autooff 1
        fi
    fi
    invalid_index
fi
case $cmd in
info)
    p=$(rd pending)
    if [ "$p" -gt 0 ]; then
        # An accepted change: the controller re-opens, and mgmt does not
        # list it again until the address has been written.
        p=$((p - 1))
        wr pending "$p"
        if [ "$p" -eq 0 ]; then
            wr up 1
            wr autooff 0
        fi
        invalid_index
    fi
    printf 'hci%s:\tPrimary controller\n' "$idx"
    printf '\taddr %s version 7 manufacturer 15 class 0x000000\n' "$(rd addr)"
    ;;
power)
    if [ "$arg" = on ]; then
        wr up 1
        wr autooff 0
    elif [ "$arg" = off ] && [ "$(rd up)" = 1 ] && [ "$(rd autooff)" = 0 ]; then
        # Inside the window (up=1 autooff=1) the kernel sees the
        # controller as off already: nothing to do.
        wr up 0
    fi
    ;;
public-addr)
    r=$(rd refuse)
    if [ "$r" -gt 0 ]; then
        # bluetoothd won the race and powered the controller on just
        # before the change.
        wr refuse $((r - 1))
        wr up 1
        wr autooff 0
        echo "Set public address failed with status 0x0c (Rejected)" >&2
    elif [ "$(rd up)" = 1 ] && [ "$(rd autooff)" = 0 ]; then
        echo "Set public address failed with status 0x0c (Rejected)" >&2
    elif [ "$(rd up)" = 1 ] && [ "$(rd autooff)" = 1 ]; then
        # The race: accepted inside the auto-off window, and the kernel's
        # power-on shortcut never re-announces the controller.
        wr lost 1
        printf 'BUG: address changed inside the auto-off window\n' >> "$M/calls"
    else
        # Powered off for real: the change is accepted.
        wr addr "$arg"
        if [ "$(rd bug_never_back)" = 1 ]; then
            wr lost 1
        else
            wr pending 2
        fi
    fi
    ;;
esac
exit 0
STUB
chmod +x "$t/bin/"*

# --- helpers ---------------------------------------------------------------------
# Two obviously fake CIDs, and the addresses the script should derive
# from them (the same recipe: sha256 of "t715-bt-addr:<cid>", first 12
# hex digits, the first octet with the locally-administered bit set).
CID1=0123456789abcdef0123456789abcd00
CID2=fedcba9876543210fedcba9876543210
printf '%s\n' "$CID1" > "$t/cid"
printf '%s\n' "$CID2" > "$t/cid2"
derived_addr() {
    local h b0 c a
    h=$(printf 't715-bt-addr:%s' "$1" | sha256sum | cut -c1-12)
    b0=$(( (0x$(printf '%s' "$h" | cut -c1-2) & 0xfc) | 0x02 ))
    a=$(printf '%02X' "$b0")
    for c in 3 5 7 9 11; do
        a=$a:$(printf '%s' "$h" | cut -c"$c-$((c + 1))" | tr a-f A-F)
    done
    printf '%s\n' "$a"
}
ADDR1=$(derived_addr "$CID1")
ADDR2=$(derived_addr "$CID2")

# mg_init DIR [ADDR]: a fresh controller — listed, powered off, the
# chip's default address — every knob at zero.
mg_init() {
    rm -rf "$1"
    mkdir -p "$1"
    printf '1\n' > "$1/listed"
    printf '0\n' > "$1/appear_after"
    printf '0\n' > "$1/up"
    printf '0\n' > "$1/autooff"
    printf '%s\n' "${2:-43:58:A3:00:00:01}" > "$1/addr"
    printf '0\n' > "$1/pending"
    printf '0\n' > "$1/lost"
    printf '0\n' > "$1/refuse"
    printf '0\n' > "$1/bug_never_back"
    : > "$1/calls"
}
# knob DIR NAME VALUE: turn a scenario knob.
knob() { printf '%s\n' "$3" > "$1/$2"; }
mg() { cat "$1/$2" 2>/dev/null || true; }
# bt SCRIPT DIR CIDFILE: the script as its unit runs it (sh, hci0, the
# stand-ins first in PATH), stdout and stderr captured in the state dir;
# the exit status lands in RC.
bt() {
    local rc=0
    ST=$2
    env PATH="$t/bin:$PATH" T715_BT_ADDR_CID="$3" T715_TEST_MGMT="$2" \
        sh "$1" hci0 >"$2/out" 2>"$2/err" || rc=$?
    RC=$rc
}
ncalls() { grep -c -- "$1" "$2" || true; }
logged() { [ "$(cat "$1/out")" = "$2" ]; }
# nothing_leaked DIR LABEL: neither CID nor a derived address was put on
# the script's stdout or stderr.
nothing_leaked() {
    local s
    for s in "$CID1" "$CID2" "$ADDR1" "$ADDR2"; do
        if grep -qF -- "$s" "$1/out" 2>/dev/null || grep -qF -- "$s" "$1/err" 2>/dev/null; then
            fail "$2 the CID or a derived address was logged"
        fi
    done
}

# --- (a) the controller appears inside the auto-off window -----------------------
mg_init "$t/win"
knob "$t/win" appear_after 2
bt "$BT" "$t/win" "$t/cid"
[ "$RC" = 0 ] || fail "(a) exit 0 when the window is survived"
logged "$t/win" "t715-bt-addr: hci0: generated address set" \
    || fail "(a) the generated-address line (got: $(cat "$t/win/out"))"
[ "$(mg "$t/win" lost)" = 0 ] || fail "(a) the controller was not lost"
if grep -q 'BUG:' "$t/win/calls"; then
    fail "(a) the address was not changed inside the window"
fi
# First line number of each call, empty when there is none; grep finds
# nothing inside the $( ), which set -e does not see.
first_line() { grep -n -- "$1" "$2/calls" | sed -n '1p' | cut -d: -f1; }
# The model logs the command words alone on each line, so anchor them.
pon=$(first_line '^power on$' "$t/win" || true)
ppa=$(first_line '^public-addr' "$t/win" || true)
if [ -z "$pon" ] || [ -z "$ppa" ] || [ "$pon" -ge "$ppa" ]; then
    fail "(a) power on comes before the first public-addr"
fi
[ "$(mg "$t/win" addr)" = "$ADDR1" ] \
    || fail "(a) the controller ends with the generated address"
nothing_leaked "$t/win" "(a)"
echo "ok - window at first sight: power on first, the address set, the controller kept"

# --- (b) the same without the fix: the model loses the controller ------------------
[ "$(grep -c -- ' power on ' "$BT" || true)" = 1 ] \
    || fail "(b) the script has exactly one power on line to delete"
sed '/ power on /d' "$BT" > "$t/bt-no-power-on"
if grep -q -- ' power on ' "$t/bt-no-power-on"; then
    fail "(b) the copy still powers the controller on"
fi
mg_init "$t/old"
knob "$t/old" appear_after 2
bt "$t/bt-no-power-on" "$t/old" "$t/cid"
[ "$RC" = 1 ] || fail "(b) the unfixed script fails (exit $RC)"
[ "$(mg "$t/old" lost)" = 1 ] \
    || fail "(b) the model loses the controller to the bug"
grep -q 'BUG: address changed inside the auto-off window' "$t/old/calls" \
    || fail "(b) the BUG line is recorded"
echo "ok - without the power on the model records the controller as lost"

# --- (c) bluetoothd wins once ------------------------------------------------------
mg_init "$t/refuse1"
knob "$t/refuse1" up 1
knob "$t/refuse1" autooff 1
knob "$t/refuse1" refuse 1
bt "$BT" "$t/refuse1" "$t/cid"
[ "$RC" = 0 ] || fail "(c) exit 0 after bluetoothd wins once"
logged "$t/refuse1" "t715-bt-addr: hci0: generated address set" \
    || fail "(c) the generated-address line (got: $(cat "$t/refuse1/out"))"
[ "$(ncalls '^public-addr' "$t/refuse1/calls")" = 2 ] \
    || fail "(c) exactly two public-addr calls"
nothing_leaked "$t/refuse1" "(c)"
echo "ok - bluetoothd wins once: the second attempt sets the address"

# --- (d) bluetoothd always wins ----------------------------------------------------
mg_init "$t/refuseall"
knob "$t/refuseall" up 1
knob "$t/refuseall" autooff 1
knob "$t/refuseall" refuse 99
bt "$BT" "$t/refuseall" "$t/cid"
[ "$RC" = 1 ] || fail "(d) exit 1 when bluetoothd always wins"
logged "$t/refuseall" "t715-bt-addr: hci0: setting the generated address failed" \
    || fail "(d) the failure line (got: $(cat "$t/refuseall/out"))"
[ "$(ncalls '^public-addr' "$t/refuseall/calls")" = 10 ] \
    || fail "(d) exactly ten public-addr calls"
nothing_leaked "$t/refuseall" "(d)"
echo "ok - bluetoothd always wins: ten attempts, then a clean failure"

# --- (e) the address is already the generated one ----------------------------------
mg_init "$t/already" "$ADDR1"
knob "$t/already" up 1
bt "$BT" "$t/already" "$t/cid"
[ "$RC" = 0 ] || fail "(e) exit 0 when the address is already set"
logged "$t/already" "t715-bt-addr: hci0 already has its generated address" \
    || fail "(e) the already-set line (got: $(cat "$t/already/out"))"
[ "$(cat "$t/already/calls")" = "info" ] \
    || fail "(e) one info call, no power or public-addr at all (got: $(cat "$t/already/calls"))"
nothing_leaked "$t/already" "(e)"
echo "ok - already set: read once, nothing touched"

# --- (f) no eMMC CID ---------------------------------------------------------------
mg_init "$t/nocid"
bt "$BT" "$t/nocid" "$t/no-such-cid"
[ "$RC" = 0 ] || fail "(f) exit 0 without a CID"
logged "$t/nocid" "t715-bt-addr: no eMMC CID, hci0 keeps its address" \
    || fail "(f) the no-CID line (got: $(cat "$t/nocid/out"))"
if [ -s "$t/nocid/calls" ]; then
    fail "(f) btmgmt is never called without a CID"
fi
nothing_leaked "$t/nocid" "(f)"
echo "ok - no eMMC CID: the address kept, btmgmt never called"

# --- (g) the controller never shows up ---------------------------------------------
mg_init "$t/never"
knob "$t/never" appear_after 1000
bt "$BT" "$t/never" "$t/cid"
[ "$RC" = 0 ] || fail "(g) exit 0 when the controller never shows up"
logged "$t/never" "t715-bt-addr: hci0 did not show up in mgmt within 60 s" \
    || fail "(g) the give-up line (got: $(cat "$t/never/out"))"
[ "$(ncalls '^info$' "$t/never/calls")" = 60 ] \
    || fail "(g) exactly sixty info calls"
nothing_leaked "$t/never" "(g)"
echo "ok - never listed: sixty polls, then give up without failing"

# --- (h) an accepted change that never comes back ----------------------------------
mg_init "$t/noback"
knob "$t/noback" appear_after 2
knob "$t/noback" bug_never_back 1
bt "$BT" "$t/noback" "$t/cid"
[ "$RC" = 1 ] || fail "(h) exit 1 when the change never comes back"
logged "$t/noback" "t715-bt-addr: hci0: setting the generated address failed" \
    || fail "(h) the failure line (got: $(cat "$t/noback/out"))"
[ "$(mg "$t/noback" lost)" = 1 ] \
    || fail "(h) the model shows the change never came back"
if grep -q 'BUG:' "$t/noback/calls"; then
    fail "(h) no window race in this failure"
fi
nothing_leaked "$t/noback" "(h)"
echo "ok - accepted but never back: a clean failure, not the window race"

# --- (i) the address itself: derived, formatted, never logged ----------------------
mg_init "$t/der1"
bt "$BT" "$t/der1" "$t/cid"
[ "$RC" = 0 ] || fail "(i) exit 0 for the first CID"
[ "$(mg "$t/der1" addr)" = "$ADDR1" ] \
    || fail "(i) the address derives from the first CID as specified"
mg_init "$t/der2"
bt "$BT" "$t/der2" "$t/cid2"
[ "$RC" = 0 ] || fail "(i) exit 0 for the second CID"
[ "$(mg "$t/der2" addr)" = "$ADDR2" ] \
    || fail "(i) the address derives from the second CID as specified"
[ "$ADDR1" != "$ADDR2" ] || fail "(i) two CIDs give two addresses"
for a in "$ADDR1" "$ADDR2"; do
    printf '%s\n' "$a" | grep -qE '^[0-9A-F]{2}(:[0-9A-F]{2}){5}$' \
        || fail "(i) the address is six upper-case hex octets"
    o=$((0x${a%%:*}))
    [ $((o & 0x02)) -ne 0 ] || fail "(i) the locally-administered bit is set"
    [ $((o & 0x01)) -eq 0 ] || fail "(i) the address is a unicast one"
done
nothing_leaked "$t/der1" "(i)"
nothing_leaked "$t/der2" "(i)"
echo "ok - the address: derived per CID, locally administered unicast, never logged"

echo "PASS"
