#!/usr/bin/env bash
# test_t715_idle.sh — off-device test of t715-idle's hypridle.conf
# (rootfs/overlay/usr/share/t715-omarchy/hypridle.conf, t715-idle.service,
# docs/image/ROOTFS.md "Touch layer P1").
#
# Static checks of the config first: one listener at 120 s, the general
# block's two inhibit lines honoured, and an on-timeout command with no "#"
# or "$", which hyprlang would read as a comment or a variable. Then the
# extracted on-timeout command runs under /bin/sh -c, as hypridle runs it,
# with HOME in a temporary directory whose path contains a space (the "~"
# in the command must expand there) and a stub systemctl first in PATH that
# logs its arguments: without the stay-awake file it signals t715-keys,
# with it the timeout does nothing, and removing it arms the timer again.
# In the style of test_t715_keys.sh (omarchy-mobile 5f7ba48, MIT).
#
# Usage: tests/test_t715_idle.sh
# Prints "ok - ..." per group, "PASS" at the end; exit 1 on the first
# failure. Needs bash and /bin/sh; works with macOS's bash 3.2. Nothing
# outside a temporary directory.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CONF="$here/rootfs/overlay/usr/share/t715-omarchy/hypridle.conf"
[ -f "$CONF" ] || { echo "SETUP ERROR: no $CONF" >&2; exit 2; }

t=$(mktemp -d "${TMPDIR:-/tmp}/t715-idle-test.XXXXXX")
cleanup() { rm -rf "$t"; }
trap cleanup EXIT

fail() {
    printf 'not ok - %s\n' "$1" >&2
    echo "--- systemctl calls" >&2; cat "$t/bin/calls" 2>/dev/null || true
    exit 1
}

# --- static checks -------------------------------------------------------------
# The config is small and read with awk and grep, the tools verify-rootfs.sh
# uses on extracted files.
listeners=$(awk '/^listener[[:space:]]*\{/{n++} END{print n + 0}' "$CONF")
[ "$listeners" = 1 ] || fail "exactly one listener block (found $listeners)"
timeout=$(sed -n 's/^[[:space:]]*timeout[[:space:]]*=[[:space:]]*//p' "$CONF")
[ "$timeout" = 120 ] || fail "the listener's timeout is 120 (found ${timeout:-none})"
grep -qx '[[:space:]]*ignore_dbus_inhibit = false' "$CONF" || fail "general: ignore_dbus_inhibit = false"
grep -qx '[[:space:]]*ignore_systemd_inhibit = false' "$CONF" || fail "general: ignore_systemd_inhibit = false"
cmd=$(sed -n 's/^[[:space:]]*on-timeout[[:space:]]*=[[:space:]]*//p' "$CONF")
[ -n "$cmd" ] || fail "the listener has an on-timeout command"
case "$cmd" in
    *"#"*) fail "on-timeout holds a #, which hyprlang would read as a comment" ;;
    *'$'*) fail "on-timeout holds a \$, which hyprlang would read as a variable" ;;
esac
echo "ok - one listener at 120 s, both inhibitors honoured, on-timeout with no # or \$"

# --- the stand-in and the environment --------------------------------------------
# hypridle runs on-timeout through /bin/sh -c, which on the tablet is bash.
# HOME's path holds a space: the command's "~" must expand, not split.
mkdir -p "$t/bin" "$t/home dir"
cat > "$t/bin/systemctl" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$t/bin/calls"
exit 0
STUB
chmod +x "$t/bin/systemctl"
: > "$t/bin/calls"

run_timeout() { env -i HOME="$t/home dir" PATH="$t/bin:/usr/bin:/bin" /bin/sh -c "$cmd"; }
calls() { cat "$t/bin/calls" 2>/dev/null || :; }

# --- (a) no stay-awake file: the screen-off runs ---------------------------------
run_timeout || fail "on-timeout with no stay-awake file exits 0"
[ "$(calls | wc -l | tr -d ' ')" = 1 ] || fail "the screen-off ran once (got $(calls | wc -l | tr -d ' '))"
[ "$(calls)" = "--user kill --kill-whom=main --signal=SIGUSR1 t715-keys.service" ] \
    || fail "the stub got the SIGUSR1 line (got: $(calls))"

# --- (b) the stay-awake file exists: the timeout does nothing ---------------------
mkdir -p "$t/home dir/.local/state/omarchy/indicators"
: > "$t/home dir/.local/state/omarchy/indicators/stay-awake"
: > "$t/bin/calls"
run_timeout || fail "on-timeout with the stay-awake file exits 0"
[ "$(calls | wc -l | tr -d ' ')" = 0 ] || fail "the stay-awake file held the timeout (got: $(calls))"
echo "ok - on-timeout signals t715-keys without the stay-awake file, nothing with it"

# --- (c) the file goes again: the timer is armed ---------------------------------
rm -f "$t/home dir/.local/state/omarchy/indicators/stay-awake"
: > "$t/bin/calls"
run_timeout || fail "on-timeout after removing the file exits 0"
[ "$(calls)" = "--user kill --kill-whom=main --signal=SIGUSR1 t715-keys.service" ] \
    || fail "the stub ran again once the file was gone (got: $(calls))"
echo "ok - removing the stay-awake file arms the screen-off again"

echo "PASS"
