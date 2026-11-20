#!/usr/bin/env bash
# test_t715_android_setup.sh — off-device test of t715-android-setup
# (rootfs/overlay/usr/local/sbin/t715-android-setup).
#
# Runs the script on this machine against temporary fake sysfs, /dev,
# /var/lib/pacman/local, /var/tmp, home and waydroid.cfg fixtures, with PATH
# stand-ins for pacman, waydroid, ufw, systemctl, getent, setfacl, chown
# and ln.  Tests the safe temporary-dbpath pacman installation (and temp
# cleanup on both success and failure), init's kernel binder check and
# --gapps option, configure's panfrost render-node discovery, configparser
# preservation (including mixed case keys), idempotency and optional
# density, ufw rule installation, service enablement, shared-storage ACLs
# and ~/Android symlink handling, all's stop-on-failure behaviour (without
# calling share), status output order, non-root refusal, and usage/exit
# codes.
#
# Usage: image/tests/test_t715_android_setup.sh
# Prints "ok - ..." per group, "PASS" at the end; exit 1 on the first
# failure (with what the stubs collected).  Needs bash 3.2 or later and
# python3; nothing outside a temporary directory.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
AS="$here/rootfs/overlay/usr/local/sbin/t715-android-setup"
[ -f "$AS" ] || { echo "SETUP ERROR: no $AS" >&2; exit 2; }

t=$(mktemp -d "${TMPDIR:-/tmp}/t715-android-test.XXXXXX")
cleanup() { rm -rf "$t"; }
trap cleanup EXIT

fail() {
    printf 'not ok - %s\n' "$1" >&2
    echo "--- stdout" >&2; cat "$t/out" 2>/dev/null || true
    echo "--- stderr" >&2; cat "$t/err" 2>/dev/null || true
    echo "--- pacman" >&2; cat "$t/pacman.log" 2>/dev/null || true
    echo "--- waydroid" >&2; cat "$t/waydroid.log" 2>/dev/null || true
    echo "--- ufw" >&2; cat "$t/ufw.log" 2>/dev/null || true
    echo "--- systemctl" >&2; cat "$t/systemctl.log" 2>/dev/null || true
    echo "--- getent" >&2; cat "$t/getent.log" 2>/dev/null || true
    echo "--- setfacl" >&2; cat "$t/setfacl.log" 2>/dev/null || true
    echo "--- chown" >&2; cat "$t/chown.log" 2>/dev/null || true
    echo "--- ln" >&2; cat "$t/ln.log" 2>/dev/null || true
    exit 1
}

# --- stand-ins ------------------------------------------------------------------
mkdir -p "$t/bin"

cat > "$t/bin/pacman" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$T715_TEST_PACMAN_LOG"
case "${1:-}" in
    -Q)
        if [ "${2:-}" = "waydroid" ] && [ -f "$T715_TEST_PACMAN_INSTALLED" ]; then
            cat "$T715_TEST_PACMAN_INSTALLED"
            exit 0
        fi
        exit 1
        ;;
    -Sy)
        [ -f "$T715_TEST_PACMAN_FAIL_SY" ] && exit 1
        # Verify the local db was copied into the temporary --dbpath.
        dbpath=""
        prev=""
        for arg in "$@"; do
            if [ "$prev" = "--dbpath" ]; then
                dbpath=$arg
                break
            fi
            prev=$arg
        done
        if [ -z "$dbpath" ] || [ ! -f "$dbpath/local/sentinel" ]; then
            printf 'stub pacman: missing copied local db in %s\n' "$dbpath" >&2
            exit 1
        fi
        exit 0
        ;;
    -Sw)
        [ -f "$T715_TEST_PACMAN_FAIL_SW" ] && exit 1
        cachedir=""
        prev=""
        for arg in "$@"; do
            if [ "$prev" = "--cachedir" ]; then
                cachedir=$arg
                break
            fi
            prev=$arg
        done
        if [ -z "$cachedir" ] || [ ! -d "$cachedir" ]; then
            printf 'stub pacman: bad cachedir %s\n' "$cachedir" >&2
            exit 1
        fi
        printf 'fake-pkg\n' > "$cachedir/waydroid-1.6.3-1-any.pkg.tar.zst"
        printf 'fake-sig\n' > "$cachedir/waydroid-1.6.3-1-any.pkg.tar.zst.sig"
        exit 0
        ;;
    -U)
        [ -f "$T715_TEST_PACMAN_FAIL_U" ] && exit 1
        for arg in "$@"; do
            case "$arg" in
                -*) continue ;;
                *)
                    [ -f "$arg" ] || { printf 'stub pacman: missing pkg %s\n' "$arg" >&2; exit 1; }
                    ;;
            esac
        done
        if [ -f "$T715_TEST_PACMAN_MARK_ON_U" ]; then
            printf 'waydroid 1.6.3-1\n' > "$T715_TEST_PACMAN_INSTALLED"
        fi
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
STUB

cat > "$t/bin/waydroid" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$T715_TEST_WAYDROID_LOG"
[ -f "$T715_TEST_WAYDROID_FAIL" ] && exit 1
if [ "${1:-}" = "init" ] && [ -n "${T715_TEST_WAYDROID_CREATE_CFG:-}" ]; then
    mkdir -p "$(dirname "$T715_TEST_WAYDROID_CREATE_CFG")"
    cat > "$T715_TEST_WAYDROID_CREATE_CFG" <<'CFG'
[waydroid]
arch = arm
drm_device = /dev/dri/renderD128

[properties]
ro.product.brand = Generic
CFG
fi
exit 0
STUB

cat > "$t/bin/ufw" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$T715_TEST_UFW_LOG"
if [ "${1:-}" = "status" ]; then
    cat "$T715_TEST_UFW_STATUS"
    exit 0
fi
if [ -f "$T715_TEST_UFW_SKIP" ]; then
    printf 'Skipping adding existing rule\n'
    exit 0
fi
printf 'Rule added\n'
exit 0
STUB

cat > "$t/bin/systemctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$T715_TEST_SYSTEMCTL_LOG"
case "${1:-}" in
    is-active)
        if [ -f "$T715_TEST_SYSTEMCTL_ACTIVE" ]; then
            printf 'active\n'
            exit 0
        fi
        printf 'inactive\n'
        exit 3
        ;;
    enable)
        [ -f "$T715_TEST_SYSTEMCTL_FAIL" ] && exit 1
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
STUB

REAL_LN=$(command -v ln)

cat > "$t/bin/getent" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$T715_TEST_GETENT_LOG"
if [ "${1:-}" = "passwd" ] && [ -n "${2:-}" ] && [ -f "$T715_TEST_PASSWD" ]; then
    while IFS= read -r line; do
        case "$line" in
            "$2":*)
                printf '%s\n' "$line"
                exit 0
                ;;
        esac
    done < "$T715_TEST_PASSWD"
fi
exit 2
STUB

cat > "$t/bin/setfacl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$T715_TEST_SETFACL_LOG"
if [ -f "$T715_TEST_SETFACL_FAIL" ]; then
    printf 'setfacl: simulated failure\n' >&2
    exit 1
fi
exit 0
STUB

cat > "$t/bin/chown" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$T715_TEST_CHOWN_LOG"
[ -f "$T715_TEST_CHOWN_FAIL" ] && exit 1
exit 0
STUB

cat > "$t/bin/ln" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$T715_TEST_LN_LOG"
exec "$T715_TEST_REAL_LN" "$@"
STUB

chmod +x "$t/bin/pacman" "$t/bin/waydroid" "$t/bin/ufw" "$t/bin/systemctl" \
         "$t/bin/getent" "$t/bin/setfacl" "$t/bin/chown" "$t/bin/ln"

export T715_TEST_PACMAN_LOG="$t/pacman.log"
export T715_TEST_PACMAN_INSTALLED="$t/pacman.installed"
export T715_TEST_PACMAN_FAIL_SY="$t/pacman.fail_sy"
export T715_TEST_PACMAN_FAIL_SW="$t/pacman.fail_sw"
export T715_TEST_PACMAN_FAIL_U="$t/pacman.fail_u"
export T715_TEST_PACMAN_MARK_ON_U="$t/pacman.mark_on_u"
export T715_TEST_WAYDROID_LOG="$t/waydroid.log"
export T715_TEST_WAYDROID_FAIL="$t/waydroid.fail"
export T715_TEST_UFW_LOG="$t/ufw.log"
export T715_TEST_UFW_STATUS="$t/ufw.status"
export T715_TEST_UFW_SKIP="$t/ufw.skip"
export T715_TEST_SYSTEMCTL_LOG="$t/systemctl.log"
export T715_TEST_SYSTEMCTL_ACTIVE="$t/systemctl.active"
export T715_TEST_SYSTEMCTL_FAIL="$t/systemctl.fail"
export T715_TEST_GETENT_LOG="$t/getent.log"
export T715_TEST_PASSWD="$t/passwd"
export T715_TEST_SETFACL_LOG="$t/setfacl.log"
export T715_TEST_SETFACL_FAIL="$t/setfacl.fail"
export T715_TEST_CHOWN_LOG="$t/chown.log"
export T715_TEST_CHOWN_FAIL="$t/chown.fail"
export T715_TEST_LN_LOG="$t/ln.log"
export T715_TEST_REAL_LN="$REAL_LN"

# --- fixture helpers ------------------------------------------------------------
S="$t/sys"
D="$t/dev"
TMP="$t/tmp"
CFG="$t/waydroid/waydroid.cfg"
PLOCAL="$t/pacman-local"
HOMES="$t/homes"

reset_env() {
    rm -rf "$S" "$D" "$TMP" "$t/waydroid" "$PLOCAL" "$HOMES" \
           "$t/pacman.installed" "$t/pacman.fail_sy" "$t/pacman.fail_sw" \
           "$t/pacman.fail_u" "$t/pacman.mark_on_u" "$t/waydroid.fail" \
           "$t/ufw.skip" "$t/systemctl.active" "$t/systemctl.fail" \
           "$t/passwd" "$t/setfacl.fail" "$t/chown.fail"
    mkdir -p "$S/class/drm" "$D" "$TMP" "$t/waydroid" "$PLOCAL" "$HOMES/alarm" "$HOMES/alice"
    printf 'ok\n' > "$PLOCAL/sentinel"
    printf 'Status: inactive\n' > "$t/ufw.status"
    cat > "$t/passwd" <<EOF
alarm:x:1000:1001:Alarm User:$HOMES/alarm:/bin/bash
alice:x:1042:1042:Alice:$HOMES/alice:/bin/bash
EOF
    clear_logs
}

clear_logs() {
    : > "$t/pacman.log"
    : > "$t/waydroid.log"
    : > "$t/ufw.log"
    : > "$t/systemctl.log"
    : > "$t/getent.log"
    : > "$t/setfacl.log"
    : > "$t/chown.log"
    : > "$t/ln.log"
    : > "$t/out"
    : > "$t/err"
}

mk_drm_nodes() {
    # renderD128 -> exynos-drm (display), renderD129 -> panfrost (GPU)
    rm -rf "$S/class/drm"
    mkdir -p "$S/class/drm/renderD128/device" "$S/class/drm/renderD129/device"
    ln -s ../../../../bus/platform/drivers/exynos-drm "$S/class/drm/renderD128/device/driver"
    ln -s ../../../../bus/platform/drivers/panfrost   "$S/class/drm/renderD129/device/driver"
}

write_cfg_fixture() {
    mkdir -p "$(dirname "$CFG")"
    cat > "$CFG" <<'EOF'
[waydroid]
arch = arm
images_path = /usr/share/waydroid-extra/images
system_ota = https://ota.waydro.id/system/lineage/waydroid_arm/VANILLA.json
drm_device = /dev/dri/renderD128
vendor_type = MAINLINE

[properties]
ro.product.brand = Generic
SomeMixedCaseKey = KeepMe%20Literal

[custom]
ExtraOption = untouched
EOF
}

run_as() {
    clear_logs
    RC=0
    env T715_ANDROID_CFG="$CFG" \
        T715_ANDROID_SYSFS="$S" \
        T715_ANDROID_DEV="$D" \
        T715_ANDROID_TMP="$TMP" \
        T715_ANDROID_PACMAN_LOCAL="$PLOCAL" \
        T715_ANDROID_ASSUME_ROOT=1 \
        PATH="$t/bin:$PATH" \
        "$AS" "$@" > "$t/out" 2> "$t/err" || RC=$?
    return 0
}

tmp_leftovers() {
    find "$TMP" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '
}

# --- (a) packages when already installed ----------------------------------------
reset_env
printf 'waydroid 1.6.3-1\n' > "$t/pacman.installed"
run_as packages
[ "$RC" = 0 ] || fail "(a) packages when installed exits 0 (got $RC)"
[ "$(wc -l < "$t/out" | tr -d ' ')" = 1 ] || fail "(a) prints one line"
[ "$(wc -l < "$t/pacman.log" | tr -d ' ')" = 1 ] \
    || fail "(a) only one pacman call when installed"
[ "$(cat "$t/pacman.log")" = "-Q waydroid" ] \
    || fail "(a) only pacman -Q waydroid called"
[ "$(tmp_leftovers)" = 0 ] || fail "(a) no temp dirs created"
echo "ok - packages when installed: exit 0, one line, no other pacman call"

# --- (b) packages when not installed --------------------------------------------
reset_env
run_as packages
[ "$RC" = 0 ] || fail "(b) packages when not installed exits 0 (got $RC)"
[ "$(wc -l < "$t/pacman.log" | tr -d ' ')" = 4 ] \
    || fail "(b) four pacman calls in order (got $(wc -l < "$t/pacman.log" | tr -d ' '))"
l1=$(sed -n '1p' "$t/pacman.log")
l2=$(sed -n '2p' "$t/pacman.log")
l3=$(sed -n '3p' "$t/pacman.log")
l4=$(sed -n '4p' "$t/pacman.log")
[ "$l1" = "-Q waydroid" ] || fail "(b) call 1 is -Q waydroid (got $l1)"
case "$l2" in
    "-Sy --dbpath $TMP/t715-android-db."*) ;;
    *) fail "(b) call 2 is -Sy with --dbpath inside TMP (got $l2)" ;;
esac
case "$l3" in
    "-Sw --noconfirm --dbpath $TMP/t715-android-db."*--cachedir\ "$TMP/t715-android-pkg."*" waydroid") ;;
    *) fail "(b) call 3 is -Sw with --dbpath and --cachedir inside TMP (got $l3)" ;;
esac
case "$l4" in
    "-U --noconfirm --needed $TMP/t715-android-pkg."*"/waydroid-1.6.3-1-any.pkg.tar.zst") ;;
    *) fail "(b) call 4 is -U with downloaded package file only (got $l4)" ;;
esac
! grep -q -- '-Syu' "$t/pacman.log" || fail "(b) never calls -Syu"
! grep -q '\.sig' "$t/pacman.log" || fail "(b) never passes .sig to -U"
[ "$(tmp_leftovers)" = 0 ] || fail "(b) temp dirs removed afterwards"
echo "ok - packages when not installed: four calls in order, temporary --dbpath, temp dirs cleaned"

# --- (c) packages cleanup when -Sw fails ----------------------------------------
reset_env
: > "$t/pacman.fail_sw"
run_as packages
[ "$RC" = 1 ] || fail "(c) packages exits 1 when -Sw fails (got $RC)"
[ -s "$t/err" ] || fail "(c) error message on stderr when -Sw fails"
! grep -q -- '^-U ' "$t/pacman.log" || fail "(c) -U not called after -Sw fails"
[ "$(tmp_leftovers)" = 0 ] || fail "(c) temp dirs removed even when -Sw fails"
echo "ok - packages failure: exit 1 on -Sw error, -U skipped, temp dirs cleaned"

# --- (d) init -------------------------------------------------------------------
reset_env
run_as init
[ "$RC" = 3 ] || fail "(d) init without binder exits 3 (got $RC)"
grep -qi 'kernel' "$t/err" || fail "(d) stderr names the kernel"
[ ! -s "$t/waydroid.log" ] || fail "(d) waydroid not called without binder"

: > "$D/binder"
write_cfg_fixture
run_as init
[ "$RC" = 0 ] || fail "(d) init with cfg present exits 0 (got $RC)"
[ ! -s "$t/waydroid.log" ] || fail "(d) waydroid not called when cfg already exists"

rm -f "$CFG"
run_as init
[ "$RC" = 0 ] || fail "(d) fresh init exits 0 (got $RC)"
[ "$(cat "$t/waydroid.log")" = "init" ] || fail "(d) waydroid init called"

run_as init --gapps
[ "$RC" = 0 ] || fail "(d) fresh init --gapps exits 0 (got $RC)"
[ "$(cat "$t/waydroid.log")" = "init -s GAPPS" ] || fail "(d) waydroid init -s GAPPS called"
echo "ok - init: exit 3 without binder, skipped with cfg, fresh and --gapps"

# --- (e) configure --------------------------------------------------------------
reset_env
mk_drm_nodes
run_as configure
[ "$RC" = 1 ] || fail "(e) configure without cfg exits 1 (got $RC)"
[ -s "$t/err" ] || fail "(e) stderr explains missing cfg"
[ ! -s "$t/waydroid.log" ] || fail "(e) waydroid not called without cfg"

write_cfg_fixture
run_as configure
[ "$RC" = 0 ] || fail "(e) configure exits 0 (got $RC)"
[ "$(cat "$t/waydroid.log")" = "upgrade --offline" ] \
    || fail "(e) waydroid upgrade --offline called once"
[ "$(wc -l < "$t/out" | tr -d ' ')" = 3 ] \
    || fail "(e) prints one line per key changed (got $(wc -l < "$t/out" | tr -d ' '))"

python3 - "$CFG" <<'PY' || fail "(e) configparser assertions failed"
import configparser, sys

cfg = configparser.ConfigParser(interpolation=None)
cfg.optionxform = str
cfg.read(sys.argv[1], encoding="utf-8")

assert cfg.get("waydroid", "drm_device") == "/dev/dri/renderD129", cfg.get("waydroid", "drm_device")
assert cfg.get("waydroid", "arch") == "arm"
assert cfg.get("waydroid", "images_path") == "/usr/share/waydroid-extra/images"
assert cfg.get("waydroid", "system_ota") == "https://ota.waydro.id/system/lineage/waydroid_arm/VANILLA.json"
assert cfg.get("waydroid", "vendor_type") == "MAINLINE"
assert cfg.get("properties", "ro.opengles.version") == "196609"
assert cfg.get("properties", "persist.waydroid.multi_windows") == "false"
assert cfg.get("properties", "ro.product.brand") == "Generic"
assert "SomeMixedCaseKey" in cfg["properties"], list(cfg["properties"].keys())
assert cfg.get("properties", "SomeMixedCaseKey") == "KeepMe%20Literal"
assert not cfg.has_option("properties", "ro.sf.lcd_density")
assert cfg.get("custom", "ExtraOption") == "untouched"
PY

# Second run: idempotent, nothing to change, no upgrade call
run_as configure
[ "$RC" = 0 ] || fail "(e) second configure exits 0 (got $RC)"
[ "$(cat "$t/out")" = "nothing to change" ] || fail "(e) second run says nothing to change"
[ ! -s "$t/waydroid.log" ] || fail "(e) second run does not call waydroid upgrade"

# Density set only with T715_ANDROID_DENSITY
clear_logs
RC=0
env T715_ANDROID_CFG="$CFG" \
    T715_ANDROID_SYSFS="$S" \
    T715_ANDROID_DEV="$D" \
    T715_ANDROID_TMP="$TMP" \
    T715_ANDROID_PACMAN_LOCAL="$PLOCAL" \
    T715_ANDROID_ASSUME_ROOT=1 \
    T715_ANDROID_DENSITY=240 \
    PATH="$t/bin:$PATH" \
    "$AS" configure > "$t/out" 2> "$t/err" || RC=$?
[ "$RC" = 0 ] || fail "(e) configure with density exits 0 (got $RC)"
[ "$(wc -l < "$t/out" | tr -d ' ')" = 1 ] || fail "(e) density adds one changed line"
[ "$(cat "$t/waydroid.log")" = "upgrade --offline" ] \
    || fail "(e) density change triggers upgrade --offline"
python3 - "$CFG" <<'PY' || fail "(e) density value check failed"
import configparser, sys
cfg = configparser.ConfigParser(interpolation=None)
cfg.optionxform = str
cfg.read(sys.argv[1], encoding="utf-8")
assert cfg.get("properties", "ro.sf.lcd_density") == "240"
assert "SomeMixedCaseKey" in cfg["properties"]
PY

# No panfrost render node -> exit 1 and cfg untouched
rm -rf "$S/class/drm/renderD129"
cp "$CFG" "$t/cfg.before"
run_as configure
[ "$RC" = 1 ] || fail "(e) configure without panfrost exits 1 (got $RC)"
[ -s "$t/err" ] || fail "(e) stderr reports missing panfrost"
cmp -s "$t/cfg.before" "$CFG" || fail "(e) cfg untouched when panfrost is absent"
[ ! -s "$t/waydroid.log" ] || fail "(e) waydroid not called when panfrost is absent"
echo "ok - configure: panfrost renderD129, preserves keys/case, idempotent, density opt-in, safe on missing panfrost"

# --- (f) firewall ---------------------------------------------------------------
reset_env
printf 'Status: inactive\n' > "$t/ufw.status"
run_as firewall
[ "$RC" = 0 ] || fail "(f) firewall with ufw inactive exits 0 (got $RC)"
[ "$(cat "$t/ufw.log")" = "status" ] || fail "(f) no rule added when ufw inactive"

# ufw absent from PATH
clear_logs
mkdir -p "$t/bin-noufw"
ln -sf "$t/bin/pacman" "$t/bin-noufw/pacman"
ln -sf "$t/bin/waydroid" "$t/bin-noufw/waydroid"
ln -sf "$t/bin/systemctl" "$t/bin-noufw/systemctl"
RC=0
env T715_ANDROID_CFG="$CFG" \
    T715_ANDROID_SYSFS="$S" \
    T715_ANDROID_DEV="$D" \
    T715_ANDROID_TMP="$TMP" \
    T715_ANDROID_PACMAN_LOCAL="$PLOCAL" \
    T715_ANDROID_ASSUME_ROOT=1 \
    PATH="$t/bin-noufw:/usr/bin:/bin" \
    "$AS" firewall > "$t/out" 2> "$t/err" || RC=$?
[ "$RC" = 0 ] || fail "(f) firewall with ufw absent exits 0 (got $RC)"

# ufw active -> four rules
printf 'Status: active\n\nTo Action From\n' > "$t/ufw.status"
run_as firewall
[ "$RC" = 0 ] || fail "(f) firewall with ufw active exits 0 (got $RC)"
want_ufw='status
allow in on waydroid0 to any port 53
allow in on waydroid0 to any port 67 proto udp
route allow in on waydroid0
route allow out on waydroid0'
[ "$(cat "$t/ufw.log")" = "$want_ufw" ] \
    || fail "(f) four ufw rules added when active"

# ufw active with Skipping output -> still exit 0
: > "$t/ufw.skip"
run_as firewall
[ "$RC" = 0 ] || fail "(f) firewall tolerates Skipping output (got $RC)"
echo "ok - firewall: no-op when ufw inactive/absent, four waydroid0 rules when active"

# --- (g) enable -----------------------------------------------------------------
reset_env
run_as enable
[ "$RC" = 0 ] || fail "(g) enable exits 0 (got $RC)"
[ "$(cat "$t/systemctl.log")" = "enable --now waydroid-container.service" ] \
    || fail "(g) systemctl enable --now waydroid-container.service called"

: > "$t/systemctl.fail"
run_as enable
[ "$RC" = 1 ] || fail "(g) enable exits 1 when systemctl fails (got $RC)"
echo "ok - enable: systemctl enable --now waydroid-container.service"

# --- (h) all --------------------------------------------------------------------
# Stop at failing step (init exits 3 because binder is missing)
reset_env
mk_drm_nodes
printf 'waydroid 1.6.3-1\n' > "$t/pacman.installed"
printf 'Status: active\n' > "$t/ufw.status"
run_as all
[ "$RC" = 3 ] || fail "(h) all stops with init exit code 3 (got $RC)"
[ "$(cat "$t/pacman.log")" = "-Q waydroid" ] || fail "(h) packages ran before init"
[ ! -s "$t/waydroid.log" ] || fail "(h) waydroid not called after binder check failed"
[ ! -s "$t/ufw.log" ] || fail "(h) firewall not called after init failed"
[ ! -s "$t/systemctl.log" ] || fail "(h) enable not called after init failed"

# Happy path: all --gapps runs all five stages in order
reset_env
mk_drm_nodes
: > "$D/binder"
: > "$t/pacman.mark_on_u"
printf 'Status: active\n' > "$t/ufw.status"
clear_logs
RC=0
env T715_ANDROID_CFG="$CFG" \
    T715_ANDROID_SYSFS="$S" \
    T715_ANDROID_DEV="$D" \
    T715_ANDROID_TMP="$TMP" \
    T715_ANDROID_PACMAN_LOCAL="$PLOCAL" \
    T715_ANDROID_ASSUME_ROOT=1 \
    T715_TEST_WAYDROID_CREATE_CFG="$CFG" \
    PATH="$t/bin:$PATH" \
    "$AS" all --gapps > "$t/out" 2> "$t/err" || RC=$?
[ "$RC" = 0 ] || fail "(h) all --gapps happy path exits 0 (got $RC)"
[ "$(wc -l < "$t/pacman.log" | tr -d ' ')" = 4 ] || fail "(h) all ran packages"
want_wd='init -s GAPPS
upgrade --offline'
[ "$(cat "$t/waydroid.log")" = "$want_wd" ] || fail "(h) all ran init -s GAPPS then upgrade --offline"
[ "$(cat "$t/ufw.log")" = "$want_ufw" ] || fail "(h) all ran firewall"
[ "$(cat "$t/systemctl.log")" = "enable --now waydroid-container.service" ] \
    || fail "(h) all ran enable"
[ ! -s "$t/setfacl.log" ] && [ ! -s "$t/getent.log" ] \
    || fail "(h) all must not call share"
echo "ok - all: stops at first failing step with its exit code; happy path runs all five stages (not share)"

# --- (h2) share -----------------------------------------------------------------
# Unknown user -> exit 1, no setfacl call
reset_env
run_as share nobodyhere
[ "$RC" = 1 ] || fail "(h2) share unknown user exits 1 (got $RC)"
[ -s "$t/err" ] || fail "(h2) share unknown user prints error on stderr"
[ ! -s "$t/setfacl.log" ] || fail "(h2) share unknown user does not call setfacl"

# Media dir missing -> exit 1, message mentions not booted, no setfacl call, nothing created
reset_env
run_as share
[ "$RC" = 1 ] || fail "(h2) share without media/0 exits 1 (got $RC)"
grep -qi 'booted' "$t/err" || fail "(h2) share without media/0 mentions Android has not booted"
[ ! -s "$t/setfacl.log" ] || fail "(h2) share without media/0 does not call setfacl"
[ ! -e "$HOMES/alarm/Android" ] && [ ! -L "$HOMES/alarm/Android" ] \
    || fail "(h2) share without media/0 creates nothing"

# Media dir present but none of the six directories exist -> exit 1, no setfacl call
ALARM_DATA="$HOMES/alarm/.local/share/waydroid/data"
ALARM_MEDIA="$ALARM_DATA/media"
ALARM_MEDIA0="$ALARM_MEDIA/0"
mkdir -p "$ALARM_MEDIA0"
run_as share
[ "$RC" = 1 ] || fail "(h2) share with zero target dirs exits 1 (got $RC)"
[ -s "$t/err" ] || fail "(h2) share with zero target dirs prints error"
[ ! -s "$t/setfacl.log" ] || fail "(h2) share with zero target dirs does not call setfacl"

# Normal run with four of the six directories present (Movies and Music missing)
mkdir -p "$ALARM_MEDIA0/Download" "$ALARM_MEDIA0/Pictures" \
         "$ALARM_MEDIA0/Documents" "$ALARM_MEDIA0/DCIM"
run_as share
[ "$RC" = 0 ] || fail "(h2) normal share exits 0 (got $RC)"
[ ! -s "$t/err" ] || fail "(h2) normal share writes nothing to stderr"
want_setfacl="-m u:1000:x $ALARM_DATA $ALARM_MEDIA
-m u:1000:rx $ALARM_MEDIA0
-R -m u:1000:rwX $ALARM_MEDIA0/Download $ALARM_MEDIA0/Pictures $ALARM_MEDIA0/Documents $ALARM_MEDIA0/DCIM
-R -d -m u:1000:rwX,g:1023:rwX,m::rwx $ALARM_MEDIA0/Download $ALARM_MEDIA0/Pictures $ALARM_MEDIA0/Documents $ALARM_MEDIA0/DCIM"
[ "$(cat "$t/setfacl.log")" = "$want_setfacl" ] \
    || fail "(h2) exact setfacl commands mismatch (got: $(cat "$t/setfacl.log"))"
! grep -q 'u:alarm:' "$t/setfacl.log" || fail "(h2) setfacl uses numeric uid, not username"
[ "$(wc -l < "$t/out" | tr -d ' ')" = 7 ] \
    || fail "(h2) prints one line per directory (6) plus one for link (got $(wc -l < "$t/out" | tr -d ' '))"
grep -q "Movies" "$t/out" || fail "(h2) reports missing Movies on stdout"
grep -q "Music" "$t/out" || fail "(h2) reports missing Music on stdout"
[ -L "$HOMES/alarm/Android" ] || fail "(h2) ~/Android symlink created"
[ "$(readlink "$HOMES/alarm/Android")" = "$ALARM_MEDIA0" ] \
    || fail "(h2) ~/Android points to media/0"
[ "$(cat "$t/chown.log")" = "-h 1000:1001 $HOMES/alarm/Android" ] \
    || fail "(h2) chown -h UID:GID called on ~/Android (got: $(cat "$t/chown.log"))"
[ "$(cat "$t/ln.log")" = "-s $ALARM_MEDIA0 $HOMES/alarm/Android" ] \
    || fail "(h2) ln -s called with media/0 and ~/Android"

# Second run: idempotent, link left alone (no ln or chown call), exit 0
run_as share
[ "$RC" = 0 ] || fail "(h2) second share exits 0 (got $RC)"
[ ! -s "$t/err" ] || fail "(h2) second share writes nothing to stderr"
[ "$(cat "$t/setfacl.log")" = "$want_setfacl" ] \
    || fail "(h2) second share applies identical setfacl commands"
[ ! -s "$t/ln.log" ] || fail "(h2) second share leaves existing symlink alone (no ln)"
[ ! -s "$t/chown.log" ] || fail "(h2) second share leaves existing symlink alone (no chown)"
[ -L "$HOMES/alarm/Android" ] && [ "$(readlink "$HOMES/alarm/Android")" = "$ALARM_MEDIA0" ] \
    || fail "(h2) ~/Android symlink still intact after second run"
[ "$(wc -l < "$t/out" | tr -d ' ')" = 7 ] \
    || fail "(h2) second share prints 7 lines on stdout"

# Regular file at ~/Android -> warning on stderr, exit 0, file untouched
rm -f "$HOMES/alarm/Android"
printf 'keep-me\n' > "$HOMES/alarm/Android"
run_as share
[ "$RC" = 0 ] || fail "(h2) share with regular file at ~/Android exits 0 (got $RC)"
[ -s "$t/err" ] || fail "(h2) share with regular file at ~/Android prints warning on stderr"
[ -f "$HOMES/alarm/Android" ] && [ ! -L "$HOMES/alarm/Android" ] \
    || fail "(h2) regular file at ~/Android not replaced"
[ "$(cat "$HOMES/alarm/Android")" = "keep-me" ] \
    || fail "(h2) regular file contents untouched"
[ ! -s "$t/ln.log" ] && [ ! -s "$t/chown.log" ] \
    || fail "(h2) neither ln nor chown called when ~/Android is a regular file"

# Explicit USER / T715_ANDROID_USER override uses that user's uid/gid/home
ALICE_MEDIA0="$HOMES/alice/.local/share/waydroid/data/media/0"
mkdir -p "$ALICE_MEDIA0/Download"
clear_logs
RC=0
env T715_ANDROID_CFG="$CFG" \
    T715_ANDROID_SYSFS="$S" \
    T715_ANDROID_DEV="$D" \
    T715_ANDROID_TMP="$TMP" \
    T715_ANDROID_PACMAN_LOCAL="$PLOCAL" \
    T715_ANDROID_ASSUME_ROOT=1 \
    T715_ANDROID_USER=alice \
    PATH="$t/bin:$PATH" \
    "$AS" share > "$t/out" 2> "$t/err" || RC=$?
[ "$RC" = 0 ] || fail "(h2) share with T715_ANDROID_USER=alice exits 0 (got $RC)"
grep -q -- '-m u:1042:rx ' "$t/setfacl.log" || fail "(h2) share uses alice numeric uid 1042"
[ "$(readlink "$HOMES/alice/Android")" = "$ALICE_MEDIA0" ] \
    || fail "(h2) alice ~/Android symlink points to alice media/0"
[ "$(cat "$t/chown.log")" = "-h 1042:1042 $HOMES/alice/Android" ] \
    || fail "(h2) chown called with alice uid:gid"

# setfacl failing -> exit 1
: > "$t/setfacl.fail"
run_as share alice
[ "$RC" = 1 ] || fail "(h2) share exits 1 when setfacl fails (got $RC)"
[ -s "$t/err" ] || fail "(h2) share prints error when setfacl fails"
rm -f "$t/setfacl.fail"

# setfacl missing from PATH -> exit 1
mkdir -p "$t/bin-nosetfacl"
ln -sf "$t/bin/getent" "$t/bin-nosetfacl/getent"
clear_logs
RC=0
env T715_ANDROID_CFG="$CFG" \
    T715_ANDROID_SYSFS="$S" \
    T715_ANDROID_DEV="$D" \
    T715_ANDROID_TMP="$TMP" \
    T715_ANDROID_PACMAN_LOCAL="$PLOCAL" \
    T715_ANDROID_ASSUME_ROOT=1 \
    PATH="$t/bin-nosetfacl" \
    "$AS" share alice > "$t/out" 2> "$t/err" || RC=$?
[ "$RC" = 1 ] || fail "(h2) share exits 1 when setfacl is missing (got $RC)"
grep -qi 'setfacl' "$t/err" || fail "(h2) missing setfacl error mentions setfacl"
echo "ok - share: unknown user, missing media/0, 4-of-6 dirs exact setfacl + link, idempotent, conflict warning, setfacl failure/missing"

# --- (i) status -----------------------------------------------------------------
reset_env
run_as status
[ "$RC" = 0 ] || fail "(i) status (uninitialised) exits 0 (got $RC)"
want_status_empty='kernel=no
package=none
initialised=no
gpu=
gles=
container=inactive'
[ "$(cat "$t/out")" = "$want_status_empty" ] \
    || fail "(i) uninitialised status lines and order mismatch"

: > "$D/binder"
printf 'waydroid 1.6.3-1\n' > "$t/pacman.installed"
mk_drm_nodes
write_cfg_fixture
run_as configure
[ "$RC" = 0 ] || fail "(i) setup configure failed"
: > "$t/systemctl.active"
run_as status
[ "$RC" = 0 ] || fail "(i) status (configured) exits 0 (got $RC)"
want_status_full='kernel=yes
package=1.6.3-1
initialised=yes
gpu=/dev/dri/renderD129
gles=196609
container=active'
[ "$(cat "$t/out")" = "$want_status_full" ] \
    || fail "(i) configured status lines and order mismatch"
echo "ok - status: exact six key=value lines in order, both empty and configured"

# --- (j) non-root refusal -------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    reset_env
    for sub in packages init configure firewall enable share all; do
        clear_logs
        RC=0
        env T715_ANDROID_CFG="$CFG" \
            T715_ANDROID_SYSFS="$S" \
            T715_ANDROID_DEV="$D" \
            T715_ANDROID_TMP="$TMP" \
            T715_ANDROID_PACMAN_LOCAL="$PLOCAL" \
            PATH="$t/bin:$PATH" \
            "$AS" "$sub" > "$t/out" 2> "$t/err" || RC=$?
        [ "$RC" = 1 ] || fail "(j) non-root $sub exits 1 (got $RC)"
        grep -qi 'root' "$t/err" || fail "(j) non-root $sub error mentions root"
        [ ! -s "$t/pacman.log" ] && [ ! -s "$t/waydroid.log" ] \
            && [ ! -s "$t/ufw.log" ] && [ ! -s "$t/systemctl.log" ] \
            && [ ! -s "$t/getent.log" ] && [ ! -s "$t/setfacl.log" ] \
            && [ ! -s "$t/chown.log" ] && [ ! -s "$t/ln.log" ] \
            || fail "(j) non-root $sub called an external command"
    done
    # status and --help still work without root
    clear_logs
    RC=0
    env T715_ANDROID_CFG="$CFG" \
        T715_ANDROID_SYSFS="$S" \
        T715_ANDROID_DEV="$D" \
        T715_ANDROID_TMP="$TMP" \
        T715_ANDROID_PACMAN_LOCAL="$PLOCAL" \
        PATH="$t/bin:$PATH" \
        "$AS" status > "$t/out" 2> "$t/err" || RC=$?
    [ "$RC" = 0 ] || fail "(j) non-root status exits 0 (got $RC)"
    echo "ok - non-root refusal: mutating subcommands exit 1 without hook; status allowed"
else
    echo "ok - non-root refusal: skipped (test running as root)"
fi

# --- (k) usage and exit codes ---------------------------------------------------
reset_env
run_as --help
[ "$RC" = 0 ] || fail "(k) --help exits 0 (got $RC)"
grep -q '^usage: t715-android-setup ' "$t/out" || fail "(k) --help prints usage on stdout"
grep -q 't715-android-setup share' "$t/out" || fail "(k) --help usage lists share"
[ ! -s "$t/err" ] || fail "(k) --help writes nothing to stderr"

run_as
[ "$RC" = 2 ] || fail "(k) no argument exits 2 (got $RC)"
grep -q '^usage: t715-android-setup ' "$t/err" || fail "(k) no argument prints usage on stderr"
[ ! -s "$t/out" ] || fail "(k) no argument writes nothing to stdout"

run_as frobnicate
[ "$RC" = 2 ] || fail "(k) unknown subcommand exits 2 (got $RC)"
grep -q '^usage: t715-android-setup ' "$t/err" || fail "(k) unknown subcommand prints usage on stderr"

run_as init --bogus
[ "$RC" = 2 ] || fail "(k) init --bogus exits 2 (got $RC)"

run_as all --bogus
[ "$RC" = 2 ] || fail "(k) all --bogus exits 2 (got $RC)"

run_as packages extra
[ "$RC" = 2 ] || fail "(k) packages extra exits 2 (got $RC)"

run_as status extra
[ "$RC" = 2 ] || fail "(k) status extra exits 2 (got $RC)"

run_as --help extra
[ "$RC" = 2 ] || fail "(k) --help extra exits 2 (got $RC)"

run_as share a b
[ "$RC" = 2 ] || fail "(k) share extra arg exits 2 (got $RC)"

run_as share --bogus
[ "$RC" = 2 ] || fail "(k) share --bogus exits 2 (got $RC)"
echo "ok - usage and exit codes: --help on stdout (0), bad usage on stderr (2)"

echo "PASS"
