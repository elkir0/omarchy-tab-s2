#!/usr/bin/env bash
# test_t715_animations.sh — off-device test of t715-animations and the
# saver-flag read in rootfs/t715-looknfeel.lua (overlay/usr/local/bin/
# t715-animations, its two user units, docs/hardware/BATTERY.md 13).
#
# The script runs under /bin/sh on this machine with stand-ins first in
# PATH: hyprctl (appends its arguments, one call per line, to a file,
# and answers from files the test fills) and logger (collects the
# script's lines). Apply is driven with the saver flag absent and
# present, without a Hyprland session, and against a hyprctl that fails
# or answers something else than ok; status with the flag both ways and
# hyprctl answering or not. The Lua block runs under lua (luac -p first)
# with stub globals hl and o, the flag's path replaced by a temporary
# one, and must record enabled = true without the flag and false with
# it. The units and configure-system.sh are checked statically. In the
# style of test_t715_keys.sh (omarchy-mobile 5f7ba48, MIT).
#
# Usage: tests/test_t715_animations.sh
# Prints "ok - ..." per group, "skip - ..." where no Lua is installed,
# "PASS" at the end; exit 1 on the first failure (with what the stubs
# collected). Needs bash and /bin/sh; works with macOS's bash 3.2.
# Nothing outside a temporary directory.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ANIM="$here/rootfs/overlay/usr/local/bin/t715-animations"
LNF="$here/rootfs/t715-looknfeel.lua"
CONF="$here/rootfs/configure-system.sh"
PUNIT="$here/rootfs/overlay/etc/systemd/user/t715-animations.path"
SUNIT="$here/rootfs/overlay/etc/systemd/user/t715-animations.service"
[ -f "$ANIM" ] || { echo "SETUP ERROR: no $ANIM" >&2; exit 2; }
[ -f "$LNF" ] || { echo "SETUP ERROR: no $LNF" >&2; exit 2; }

t=$(mktemp -d "${TMPDIR:-/tmp}/t715-anim-test.XXXXXX")
cleanup() { rm -rf "$t"; }
trap cleanup EXIT

fail() {
    printf 'not ok - %s\n' "$1" >&2
    echo "--- hyprctl calls" >&2; cat "$t/calls" 2>/dev/null || true
    echo "--- logger" >&2; cat "$t/log" 2>/dev/null || true
    exit 1
}

# --- stand-ins -------------------------------------------------------------------
mkdir -p "$t/bin" "$t/run"
cat > "$t/bin/logger" <<STUB
#!/bin/sh
# The script's lines land here, whatever they say.
printf '%s\n' "\$*" >> "\$T715_TEST_LOG"
STUB
cat > "$t/bin/hyprctl" <<STUB
#!/bin/sh
# One line per call, then an answer the test fills; getoption has its own.
printf '%s\n' "hyprctl \$*" >> "\$T715_TEST_CALLS"
case "\$1" in
  getoption) [ -f "\$T715_TEST_GETOPT_OUT" ] && cat "\$T715_TEST_GETOPT_OUT" ;;
  *) [ -f "\$T715_TEST_EVAL_OUT" ] && cat "\$T715_TEST_EVAL_OUT" ;;
esac
exit "\$(cat "\$T715_TEST_RC" 2>/dev/null || echo 0)"
STUB
chmod +x "$t/bin/logger" "$t/bin/hyprctl"
export T715_TEST_LOG="$t/log" T715_TEST_CALLS="$t/calls" \
       T715_TEST_EVAL_OUT="$t/eval-out" T715_TEST_GETOPT_OUT="$t/getopt-out" \
       T715_TEST_RC="$t/rc"
SAVER="$t/run/saver"
printf 'ok\n' > "$t/eval-out"; printf '0\n' > "$t/rc"
: > "$t/calls"; : > "$t/log"
calls() { cat "$t/calls" 2>/dev/null || :; }
ncalls() { [ "$(calls | wc -l | tr -d ' ')" = "$1" ]; }
nlog()   { [ "$(grep -c "$1" "$t/log" 2>/dev/null || true)" -ge 1 ]; }

# anim [args...]: the script with the stubs first in PATH and a session's
# environment, the flag's path pointed at the temporary run dir.
anim() {
    env T715_ANIM_SAVER="$SAVER" PATH="$t/bin:/usr/bin:/bin" \
        HYPRLAND_INSTANCE_SIGNATURE="${ANIM_SIG-sig}" "$ANIM" "$@"
}
# anim_nosess [args...]: the same without HYPRLAND_INSTANCE_SIGNATURE.
anim_nosess() {
    env -u HYPRLAND_INSTANCE_SIGNATURE T715_ANIM_SAVER="$SAVER" \
        PATH="$t/bin:/usr/bin:/bin" "$ANIM" "$@"
}
# anim_emptysig: the signature set but empty.
anim_emptysig() {
    env HYPRLAND_INSTANCE_SIGNATURE= T715_ANIM_SAVER="$SAVER" \
        PATH="$t/bin:/usr/bin:/bin" "$ANIM"
}

# --- (a) flag absent, a session: animations on ------------------------------------
rm -f "$SAVER"
anim || fail "(a) apply without the flag exits 0"
ncalls 1 || fail "(a) exactly one hyprctl call (got $(calls | wc -l | tr -d ' '))"
[ "$(calls)" = "hyprctl eval hl.config({ animations = { enabled = true } })" ] \
    || fail "(a) the eval turns the animations on (got: $(calls))"
nlog "animations on" || fail "(a) one log line says animations on"
echo "ok - flag absent: one eval, animations on (balanced)"

# --- (b) flag present: animations off ----------------------------------------------
: > "$SAVER"; : > "$t/calls"; : > "$t/log"
anim || fail "(b) apply with the flag exits 0"
ncalls 1 || fail "(b) exactly one hyprctl call (got $(calls | wc -l | tr -d ' '))"
[ "$(calls)" = "hyprctl eval hl.config({ animations = { enabled = false } })" ] \
    || fail "(b) the eval turns the animations off (got: $(calls))"
nlog "animations off" || fail "(b) one log line says animations off"
echo "ok - flag present: one eval, animations off (Battery saver)"

# --- (c) no session: nothing changes, one log line ----------------------------------
: > "$t/calls"; : > "$t/log"
anim_nosess || fail "(c) apply without a signature exits 0"
ncalls 0 || fail "(c) no hyprctl call (got: $(calls))"
nlog "no Hyprland session" || fail "(c) one log line says no Hyprland session"
: > "$t/calls"; : > "$t/log"
anim_emptysig || fail "(c) apply with an empty signature exits 0"
ncalls 0 || fail "(c) an empty signature makes no hyprctl call (got: $(calls))"
nlog "no Hyprland session" || fail "(c) the empty signature logs too"
echo "ok - no session, or an empty signature: no hyprctl call, one log line"

# --- (d) hyprctl exits 1: the failure is logged --------------------------------------
printf "Couldn't connect to the socket\n" > "$t/eval-out"; printf '1\n' > "$t/rc"
: > "$t/calls"; : > "$t/log"
anim >/dev/null 2>&1 && fail "(d) a failing hyprctl exits 1"
nlog "hyprctl eval failed: Couldn't connect to the socket" \
    || fail "(d) the log holds hyprctl's first line (log: $(cat "$t/log"))"
printf 'ok\n' > "$t/eval-out"; printf '0\n' > "$t/rc"

# --- (e) hyprctl exits 0 but not ok: still a failure ----------------------------------
printf 'unknown request\n' > "$t/eval-out"
: > "$t/calls"; : > "$t/log"
anim >/dev/null 2>&1 && fail "(e) an answer other than ok exits 1"
nlog "hyprctl eval failed: unknown request" \
    || fail "(e) the log holds hyprctl's answer (log: $(cat "$t/log"))"
printf 'ok\n' > "$t/eval-out"
echo "ok - a failing or unanswered hyprctl: exit 1, the first line logged"

# --- (f) no argument: apply -----------------------------------------------------------
rm -f "$SAVER"; : > "$t/calls"; : > "$t/log"
anim >/dev/null 2>&1 || fail "(f) no argument exits 0"
ncalls 1 || fail "(f) no argument makes one hyprctl call (got: $(calls))"
[ "$(calls)" = "hyprctl eval hl.config({ animations = { enabled = true } })" ] \
    || fail "(f) no argument behaves as apply (got: $(calls))"
echo "ok - no argument behaves as apply"

# --- (g) status --------------------------------------------------------------------------
printf 'bool: true\nset: true\n' > "$t/getopt-out"
out=$(anim status) || fail "(g) status exits 0"
[ "$out" = "saver flag: absent ($SAVER)
hyprland animations:enabled: true" ] || fail "(g) status without the flag (got: $out)"
: > "$SAVER"
out=$(anim status) || fail "(g) status with the flag exits 0"
case "$out" in
    "saver flag: present ($SAVER)"$'\n'hyprland*true*) ;;
    *) fail "(g) status with the flag (got: $out)" ;;
esac
out=$(anim_nosess status) || fail "(g) status without a session exits 0"
case "$out" in
    *$'\n'"hyprland animations:enabled: unknown (no Hyprland session)") ;;
    *) fail "(g) status without a session (got: $out)" ;;
esac
: > "$t/getopt-out"; printf '1\n' > "$t/rc"
out=$(anim status) || fail "(g) status with hyprctl failing exits 0"
case "$out" in
    *"unknown (hyprctl failed)") ;;
    *) fail "(g) status with hyprctl failing (got: $out)" ;;
esac
printf 'bool: true\nset: true\n' > "$t/getopt-out"; printf '0\n' > "$t/rc"
echo "ok - status: the flag with its path, the value or why it is unknown"

# --- (h) an unknown argument --------------------------------------------------------------
: > "$t/calls"; : > "$t/log"
anim frobnicate >/dev/null 2>&1 && fail "(h) an unknown argument exits nonzero"
[ "$(anim frobnicate >/dev/null 2>&1; echo $?)" = 2 ] \
    || fail "(h) an unknown argument exits 2"
case "$(anim frobnicate 2>&1 >/dev/null)" in
    usage:*) ;;
    *) fail "(h) the usage line goes to stderr" ;;
esac
ncalls 0 || fail "(h) an unknown argument makes no hyprctl call (got: $(calls))"
echo "ok - an unknown argument: exit 2, usage on stderr, no hyprctl call"

# --- (i) the Lua block ----------------------------------------------------------------------
# The stub globals: hl.config records animations.enabled when the table has
# animations, hl.animation and o.window do nothing. It prints the last
# recorded value, or "none".
cat > "$t/hl-stub.lua" <<'LUA'
local recorded = nil
hl = {
  config = function(tbl)
    if type(tbl) == "table" and tbl.animations ~= nil then
      recorded = tbl.animations.enabled
    end
  end,
  animation = function() end,
}
o = { window = function() end }
local f = assert(arg and arg[1] or error("usage: lua hl-stub.lua FILE"))
assert(loadfile(f))()
print(recorded == nil and "none" or tostring(recorded))
LUA
LUAC=$(command -v luac || command -v luac5.4 || true)
LUA=$(command -v lua || command -v lua5.4 || true)
if [ -n "$LUAC" ] && [ -n "$LUA" ]; then
    "$LUAC" -p "$LNF" || fail "(i) looknfeel.lua parses"
    ! grep -q 'hl.config({ animations = { enabled = false } })' "$LNF" \
        || fail "(i) the unconditional animations = false line is gone"
    for state in absent present; do
        sed "s|/run/t715-power/saver|$t/lua-saver|g" "$LNF" > "$t/lnf.lua"
        rm -f "$t/lua-saver"; [ "$state" = present ] && : > "$t/lua-saver"
        out=$("$LUA" "$t/hl-stub.lua" "$t/lnf.lua") \
            || fail "(i) the block runs under lua with the flag $state"
        [ "$out" = true ] || [ "$out" = false ] || fail "(i) lua answered $out"
        if [ "$state" = absent ]; then
            [ "$out" = true ] || fail "(i) no flag: animations on (got $out)"
        else
            [ "$out" = false ] || fail "(i) the flag there: animations off (got $out)"
        fi
    done
    echo "ok - the Lua block: parses, on without the flag, off with it"
else
    echo "skip - no lua/luac installed: the Lua block not run"
fi

# --- (j) the units and configure-system.sh, statically --------------------------------------
[ -f "$PUNIT" ] || fail "(j) no $PUNIT"
[ -f "$SUNIT" ] || fail "(j) no $SUNIT"
grep -qx 'PathChanged=/run/t715-power/saver' "$PUNIT" \
    || fail "(j) the path unit watches /run/t715-power/saver"
grep -qx 'Unit=t715-animations.service' "$PUNIT" \
    || fail "(j) the path unit starts t715-animations.service"
for u in "$PUNIT" "$SUNIT"; do
    grep -qx 'PartOf=graphical-session.target' "$u" || fail "(j) PartOf= missing in $u"
    grep -qx 'WantedBy=graphical-session.target' "$u" || fail "(j) WantedBy= missing in $u"
done
grep -qx 'Type=oneshot' "$SUNIT" || fail "(j) the service is oneshot"
grep -qx 'ExecStart=/usr/local/bin/t715-animations apply' "$SUNIT" \
    || fail "(j) the service runs t715-animations apply"
grep -qx 'systemctl --global enable t715-keys.service t715-squeekboard.service t715-idle.service t715-update-check.timer t715-animations.path t715-animations.service t715-sdcard.service' "$CONF" \
    || fail "(j) configure-system.sh enables both units on its global enable line"
grep -Fqx '[ -x /usr/local/bin/t715-animations ] || die "no /usr/local/bin/t715-animations"' "$CONF" \
    || fail "(j) configure-system.sh checks for t715-animations"
echo "ok - the path unit watches the flag, the service applies, both enabled globally"

echo "PASS"
