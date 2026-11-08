#!/usr/bin/env bash
# test_omamobile_sdcard_tile.sh — off-device test of the SD card tile that
# 0012-tablet-sdcard-tile.patch adds to omamobile-shell's quick settings
# (pkg/omamobile-shell; the tile drives /usr/local/bin/t715-sdcard, in the
# root image's overlay).
#
# The patched tile-state.sh and tile-action.sh come out of the built package
# (bsdtar -xOf, the paths found with bsdtar -tf), or, when it is not built
# yet, from the upstream tarball in the t715-omarchy-pkg-src Docker volume
# with the patches applied. With a stub t715-sdcard first in PATH (and a
# timeout(1) stand-in on macOS, which has none) the probe is driven through:
# no command, slot=no, no card, a card that cannot be read, a readable card
# that is not mounted, and a mounted card; the action branch must exec
# t715-sdcard mount / eject. The QML must hold the sdcard object and
# TilesModel must list it after modem in the catalogue and the default
# layout. In the style of test_t715_animations.sh (omarchy-mobile 87b8395,
# MIT).
#
# Usage: tests/test_omamobile_sdcard_tile.sh
# Prints "ok - ..." per group, "PASS" at the end; exit 1 on the first
# failure. Needs bash, bsdtar and docker (only without a built package, for
# the tarball); works with macOS's bash 3.2. Nothing outside a temporary
# directory.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
pkg_dir="$here/pkg/omamobile-shell"
repo_dir="$here/out/repo/armv7h"
[ -f "$pkg_dir/0012-tablet-sdcard-tile.patch" ] \
    || { echo "SETUP ERROR: no $pkg_dir/0012-tablet-sdcard-tile.patch" >&2; exit 2; }

t=$(mktemp -d "${TMPDIR:-/tmp}/t715-sdcard-tile.XXXXXX")
cleanup() { rm -rf "$t"; }
trap cleanup EXIT

fail() {
    printf 'not ok - %s\n' "$1" >&2
    echo "--- t715-sdcard calls" >&2; cat "$t/calls" 2>/dev/null || true
    echo "--- t715-sdcard actions" >&2; cat "$t/actions" 2>/dev/null || true
    exit 1
}

# --- the patched scripts, from the built package or the patched source -----
# The newest omamobile-shell package the repository holds.
pkg=""
if [ -d "$repo_dir" ]; then
    while IFS= read -r cand; do
        # the newest built package that already carries the tile
        if bsdtar -xOf "$cand" 2>/dev/null \
             "$(bsdtar -tf "$cand" | grep -m1 'tile-action.sh$')" | grep -q 'sdcard'; then
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
cat > "$t/bin/t715-sdcard" <<STUB
#!/bin/sh
# state answers from a file the test fills and counts its calls; anything
# else is logged and answers ok.
case "\$1" in
  state) printf '%s\n' state >> "\$T715_TEST_CALLS"; cat "\$T715_TEST_STATE" ;;
  *)     printf '%s\n' "\$1" >> "\$T715_TEST_ACTIONS"; exit 0 ;;
esac
STUB
chmod +x "$t/bin/t715-sdcard"
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

# state: the probe's sdcard lines, with the stubs first in PATH.
state() {
    PATH="$t/bin:/usr/bin:/bin" HOME="$t" sh "$state_sh" | grep '^sdcard' || true
}

# --- (a) no t715-sdcard: no sdcard key at all --------------------------------
cat > "$t/state" <<'EOF'
slot=yes
card=yes
device=/dev/mmcblk1p1
fs=exfat
label=SDCARD
mounted=yes
mountpoint=/run/media/alarm/SDCARD
size=14.5G
free=14.4G
EOF
out=$(PATH="/usr/bin:/bin" HOME="$t" sh "$state_sh" | grep '^sdcard' || true)
[ -z "$out" ] || fail "(a) no command: no sdcard line (got: $out)"
: > "$t/calls"
echo "ok - no t715-sdcard: the probe prints no sdcard key, the tile stays dimmed"

# --- (b) slot=no: still nothing ----------------------------------------------
cat > "$t/state" <<'EOF'
slot=no
card=no
device=
fs=
label=
mounted=no
mountpoint=
size=
free=
EOF
out=$(state)
[ -z "$out" ] || fail "(b) slot=no: no sdcard line (got: $out)"
echo "ok - slot=no: no sdcard line either"

# --- (c) no card: off ----------------------------------------------------------
cat > "$t/state" <<'EOF'
slot=yes
card=no
device=
fs=
label=
mounted=no
mountpoint=
size=
free=
EOF
out=$(state)
[ "$out" = "sdcard_card=no
sdcard_fs=
sdcard=off" ] || fail "(c) no card (got: $out)"
echo "ok - no card: sdcard=off, sdcard_card=no"

# --- (d) a card, no file system: off, fs empty ---------------------------------
cat > "$t/state" <<'EOF'
slot=yes
card=yes
device=/dev/mmcblk1p1
fs=
label=
mounted=no
mountpoint=
size=14.5G
free=
EOF
out=$(state)
[ "$out" = "sdcard_card=yes
sdcard_fs=
sdcard=off" ] || fail "(d) not readable (got: $out)"
echo "ok - a card that cannot be read: sdcard=off, sdcard_fs empty"

# --- (e) a readable card, not mounted: off, fs set -----------------------------
cat > "$t/state" <<'EOF'
slot=yes
card=yes
device=/dev/mmcblk1p1
fs=exfat
label=SDCARD
mounted=no
mountpoint=
size=14.5G
free=
EOF
out=$(state)
[ "$out" = "sdcard_card=yes
sdcard_fs=exfat
sdcard=off" ] || fail "(e) not mounted (got: $out)"
echo "ok - readable, not mounted: sdcard=off, sdcard_fs=exfat"

# --- (f) mounted: on, with its free space --------------------------------------
cat > "$t/state" <<'EOF'
slot=yes
card=yes
device=/dev/mmcblk1p1
fs=exfat
label=SDCARD
mounted=yes
mountpoint=/run/media/alarm/SDCARD
size=14.5G
free=14.4G
EOF
out=$(state)
[ "$out" = "sdcard_card=yes
sdcard_fs=exfat
sdcard=on
sdcard_free=14.4G" ] || fail "(f) mounted (got: $out)"
: > "$t/calls"
out=$(state)
[ "$(wc -l < "$t/calls" | tr -d ' ')" = 1 ] \
    || fail "(f) one t715-sdcard state call per pass (got $(cat "$t/calls" | tr '\n' ' '))"
echo "ok - mounted: sdcard=on, sdcard_free=14.4G, one state call per pass"

# --- (g) the action branch: mount on, eject off --------------------------------
: > "$t/actions"
PATH="$t/bin:/usr/bin:/bin" HOME="$t" sh "$action_sh" sdcard on \
    || fail "(g) tile-action.sh sdcard on exits 0"
PATH="$t/bin:/usr/bin:/bin" HOME="$t" sh "$action_sh" sdcard off \
    || fail "(g) tile-action.sh sdcard off exits 0"
[ "$(cat "$t/actions")" = "mount
eject" ] || fail "(g) the branch runs mount then eject (got: $(cat "$t/actions" | tr '\n' ' '))"
echo "ok - the action branch: on mounts, off ejects"

# --- (h) the QML object and the model ------------------------------------------
grep -q '"sdcard": sdcard' "$qml" || fail "(h) QuickSettings.qml maps the sdcard backend"
grep -q 'id: sdcard' "$qml" || fail "(h) QuickSettings.qml has the sdcard object"
grep -q 'probedHas("sdcard")' "$qml" || fail "(h) the tile is available while probed"
grep -q 'sdcardProbeLater' "$qml" || fail "(h) the tile probes again after a tap"
grep -q '\["t715-sdcard", "open"\]' "$qml" || fail "(h) the long press opens the card"
grep -q 'exec t715-sdcard mount; else exec t715-sdcard eject' "$action_sh" \
    || fail "(h) the action branch execs t715-sdcard"
echo "ok - the QML: the sdcard object, its probe-later timer and its long press"

# --- (i) TilesModel: the catalogue and the default layout -----------------------
grep -q '{ id: "sdcard", label: "SD card" }' "$tiles_js" \
    || fail "(i) the catalogue has the SD card tile"
grep -q '"screenshot", "location", "modem", "sdcard"' "$tiles_js" \
    || fail "(i) the default layout ends with modem, sdcard"
cat_line=$(grep -n '{ id: "modem", label: "Modem" }' "$tiles_js" | head -n1 | cut -d: -f1)
sd_line=$(grep -n '{ id: "sdcard", label: "SD card" }' "$tiles_js" | head -n1 | cut -d: -f1)
[ -n "$cat_line" ] && [ -n "$sd_line" ] && [ "$sd_line" -gt "$cat_line" ] \
    || fail "(i) sdcard comes after modem in the catalogue"
echo "ok - TilesModel: sdcard in the catalogue after modem, closing the default layout"

echo "PASS"
