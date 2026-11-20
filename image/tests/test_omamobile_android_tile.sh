#!/usr/bin/env bash
# test_omamobile_android_tile.sh — off-device test of the Android tile that
# 0013-tablet-android-tile.patch adds to omamobile-shell's quick settings
# (pkg/omamobile-shell; the tile drives /usr/local/bin/t715-android, in the
# root image's overlay).
#
# The patched tile-state.sh and tile-action.sh come out of the built package
# (bsdtar -xOf, the paths found with bsdtar -tf), or, when it is not built
# yet, from the upstream tarball in the t715-omarchy-pkg-src Docker volume
# with the patches applied. With a stub t715-android first in PATH (and a
# timeout(1) stand-in on macOS, which has none) the probe is driven through:
# no command, installed=no, installed and stopped, running, and frozen; the
# action branch must exec t715-android start / stop. The QML must hold the
# android object and TilesModel must list it right after sdcard in the
# catalogue and the default layout. In the style of test_t715_animations.sh
# (omarchy-mobile 87b8395, MIT).
#
# Usage: tests/test_omamobile_android_tile.sh
# Prints "ok - ..." per group, "PASS" at the end; exit 1 on the first
# failure. Needs bash, bsdtar and docker (only without a built package, for
# the tarball); works with macOS's bash 3.2. Nothing outside a temporary
# directory.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
pkg_dir="$here/pkg/omamobile-shell"
repo_dir="$here/out/repo/armv7h"
[ -f "$pkg_dir/0013-tablet-android-tile.patch" ] \
    || { echo "SETUP ERROR: no $pkg_dir/0013-tablet-android-tile.patch" >&2; exit 2; }

t=$(mktemp -d "${TMPDIR:-/tmp}/t715-android-tile.XXXXXX")
cleanup() { rm -rf "$t"; }
trap cleanup EXIT

fail() {
    printf 'not ok - %s\n' "$1" >&2
    echo "--- t715-android calls" >&2; cat "$t/calls" 2>/dev/null || true
    echo "--- t715-android actions" >&2; cat "$t/actions" 2>/dev/null || true
    exit 1
}

# --- the patched scripts, from the built package or the patched source -----
# The newest omamobile-shell package the repository holds.
pkg=""
if [ -d "$repo_dir" ]; then
    while IFS= read -r cand; do
        # the newest built package that already carries the tile
        if bsdtar -xOf "$cand" 2>/dev/null \
             "$(bsdtar -tf "$cand" | grep -m1 'tile-action.sh$')" | grep -q 't715-android'; then
            pkg=$cand
            break
        fi
    done < <(for f in "$repo_dir"/omamobile-shell-*-any.pkg.tar.zst; do [ -e "$f" ] && printf '%s\n' "$f"; done | sort -Vr)
fi
if [ -n "$pkg" ]; then
    echo "scripts from the built package: $pkg"
else
    echo "no built omamobile-shell package with the tile: patching the source"
fi
mkdir -p "$t/src/plugins/omamobile.quicksettings" "$t/src/bin"
if [ -n "$pkg" ]; then
    member_prefix=$(bsdtar -tf "$pkg" | grep -m1 'tile-state.sh$' | sed 's|tile-state.sh$||')
    [ -n "$member_prefix" ] || fail "cannot find tile-state.sh in $pkg"
    bsdtar -xOf "$pkg" "${member_prefix}tile-state.sh" > "$t/src/plugins/omamobile.quicksettings/tile-state.sh"
    bsdtar -xOf "$pkg" "${member_prefix}tile-action.sh" > "$t/src/plugins/omamobile.quicksettings/tile-action.sh"
    bsdtar -xOf "$pkg" "${member_prefix}QuickSettings.qml" > "$t/src/plugins/omamobile.quicksettings/QuickSettings.qml"
    bsdtar -xOf "$pkg" "${member_prefix}TilesModel.js" > "$t/src/plugins/omamobile.quicksettings/TilesModel.js"
else
    # The upstream tarball lives in the t715-omarchy-pkg-src volume (the
    # build's own source cache); extract it through docker, then apply the
    # whole patch series, as prepare() does.
    commit=87b839567ad77911e948a4549f84198549191a36
    docker run --rm -v t715-omarchy-pkg-src:/srcdest:ro -v "$t/src:/out" alpine \
        sh -c "cd /out && tar -xzf /srcdest/omarchy-mobile-${commit:0:7}.tar.gz \
               omarchy-mobile-$commit/packages/omamobile-shell/plugins \
               omarchy-mobile-$commit/packages/omamobile-shell/bin \
               omarchy-mobile-$commit/packages/omamobile-shell/test" \
        || fail "cannot extract the omarchy-mobile tarball (is the volume there?)"
    pkgroot="$t/src/omarchy-mobile-$commit/packages/omamobile-shell"
    rm -rf "$t/src/plugins" "$t/src/bin"
    mv "$pkgroot/plugins" "$pkgroot/bin" "$pkgroot/test" "$t/src/"
    rm -rf "$t/src/omarchy-mobile-$commit"
    cd "$t/src"
    for p in "$pkg_dir"/0*.patch; do
        patch -Np1 -i "$p" >/dev/null || fail "patch $(basename "$p") does not apply"
    done
    cd "$here"
fi
state_sh="$t/src/plugins/omamobile.quicksettings/tile-state.sh"
action_sh="$t/src/plugins/omamobile.quicksettings/tile-action.sh"
qml="$t/src/plugins/omamobile.quicksettings/QuickSettings.qml"
tiles_js="$t/src/plugins/omamobile.quicksettings/TilesModel.js"

# --- stand-ins ----------------------------------------------------------------
mkdir -p "$t/bin"
cat > "$t/bin/t715-android" <<STUB
#!/bin/sh
# state answers from a file the test fills and counts its calls; anything
# else is logged and answers ok.
case "\$1" in
  state) printf '%s\n' state >> "\$T715_TEST_CALLS"; cat "\$T715_TEST_STATE" ;;
  *)     printf '%s\n' "\$1" >> "\$T715_TEST_ACTIONS"; exit 0 ;;
esac
STUB
chmod +x "$t/bin/t715-android"
# macOS has no timeout(1); the probe bounds each command with it.
if ! command -v timeout >/dev/null 2>&1; then
    cat > "$t/bin/timeout" <<STUB
#!/bin/sh
# drop the duration, run the rest
dur="\$1"; shift
exec "\$@"
STUB
    chmod +x "$t/bin/timeout"
fi
export T715_TEST_STATE="$t/state" T715_TEST_CALLS="$t/calls" T715_TEST_ACTIONS="$t/actions"
: > "$t/calls"; : > "$t/actions"

# state: the probe's android lines, with the stubs first in PATH.
state() {
    PATH="$t/bin:/usr/bin:/bin" HOME="$t" sh "$state_sh" | grep '^android' || true
}

# --- (a) no t715-android: no android key at all ------------------------------
cat > "$t/state" <<'EOF'
installed=yes
session=running
container=running
apps=2
EOF
out=$(PATH="/usr/bin:/bin" HOME="$t" sh "$state_sh" | grep '^android' || true)
[ -z "$out" ] || fail "(a) no command: no android line (got: $out)"
: > "$t/calls"
echo "ok - no t715-android: the probe prints no android key, the tile stays dimmed"

# --- (b) installed=no: still nothing -----------------------------------------
cat > "$t/state" <<'EOF'
installed=no
session=stopped
container=stopped
apps=
EOF
out=$(state)
[ -z "$out" ] || fail "(b) installed=no: no android line (got: $out)"
echo "ok - installed=no: no android line either"

# --- (c) installed and stopped: off ------------------------------------------
cat > "$t/state" <<'EOF'
installed=yes
session=stopped
container=stopped
apps=
EOF
out=$(state)
[ "$out" = "android=off
android_container=stopped" ] || fail "(c) stopped (got: $out)"
echo "ok - installed and stopped: android=off, android_container=stopped"

# --- (d) running: on, with container=running, one state call per pass --------
cat > "$t/state" <<'EOF'
installed=yes
session=running
container=running
apps=2
EOF
out=$(state)
[ "$out" = "android=on
android_container=running" ] || fail "(d) running (got: $out)"
: > "$t/calls"
out=$(state)
[ "$(wc -l < "$t/calls" | tr -d ' ')" = 1 ] \
    || fail "(d) one t715-android state call per pass (got $(cat "$t/calls" | tr '\n' ' '))"
echo "ok - running: android=on, android_container=running, one state call per pass"

# --- (e) frozen: on, with container=frozen -----------------------------------
cat > "$t/state" <<'EOF'
installed=yes
session=running
container=frozen
apps=0
EOF
out=$(state)
[ "$out" = "android=on
android_container=frozen" ] || fail "(e) frozen (got: $out)"
echo "ok - frozen: android=on, android_container=frozen"

# --- (f) the action branch: start on, stop off -------------------------------
: > "$t/actions"
PATH="$t/bin:/usr/bin:/bin" HOME="$t" sh "$action_sh" android on \
    || fail "(f) tile-action.sh android on exits 0"
PATH="$t/bin:/usr/bin:/bin" HOME="$t" sh "$action_sh" android off \
    || fail "(f) tile-action.sh android off exits 0"
[ "$(cat "$t/actions")" = "start
stop" ] || fail "(f) the branch runs start then stop (got: $(cat "$t/actions" | tr '\n' ' '))"
echo "ok - the action branch: on starts, off stops"

# --- (g) the QML object and the action branch --------------------------------
grep -q '"android": android' "$qml" || fail "(g) QuickSettings.qml maps the android backend"
grep -q 'id: android' "$qml" || fail "(g) QuickSettings.qml has the android object"
grep -q 'probedHas("android")' "$qml" || fail "(g) the tile is available while probed"
grep -q 'androidProbeLater' "$qml" || fail "(g) the tile probes again after a tap"
grep -q '\["t715-android", "settings"\]' "$qml" || fail "(g) the long press opens Android settings"
grep -q 'exec t715-android start; else exec t715-android stop' "$action_sh" \
    || fail "(g) the action branch execs t715-android"
echo "ok - the QML: the android object, its probe-later timer and its long press"

# --- (h) TilesModel: the catalogue and the default layout --------------------
grep -q '{ id: "android", label: "Android" }' "$tiles_js" \
    || fail "(h) the catalogue has the Android tile"
grep -q '"screenshot", "location", "modem", "sdcard", "android"' "$tiles_js" \
    || fail "(h) the default layout ends with sdcard, android"
sd_line=$(grep -n '{ id: "sdcard", label: "SD card" }' "$tiles_js" | head -n1 | cut -d: -f1)
and_line=$(grep -n '{ id: "android", label: "Android" }' "$tiles_js" | head -n1 | cut -d: -f1)
[ -n "$sd_line" ] && [ -n "$and_line" ] && [ "$and_line" -eq $((sd_line + 1)) ] \
    || fail "(h) android comes right after sdcard in the catalogue"
echo "ok - TilesModel: android in the catalogue right after sdcard, closing the default layout"

echo "PASS"
