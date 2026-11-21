#!/usr/bin/env bash
# test_t715_android_setup.sh — off-device test of t715-android-setup
# (rootfs/overlay/usr/local/sbin/t715-android-setup).
#
# Runs the script on this machine against temporary fake sysfs, /dev,
# /var/lib/pacman/local, /var/tmp, home, vendor image, overlay and
# waydroid.cfg fixtures, with PATH stand-ins for pacman, waydroid, mount,
# umount, ufw, systemctl, getent, setfacl, chown and ln.  Tests the safe
# temporary-dbpath pacman installation (and temp cleanup on both success and
# failure), init's kernel binder check and --gapps option, mesa-fix's
# verified patching, idempotency, mismatch safety, stale overlay removal,
# foreign overlay preservation and guaranteed umount, configure's panfrost
# render-node discovery, configparser preservation (including mixed case
# keys), idempotency and optional density, ufw rule installation, service
# enablement, shared-storage ACLs and ~/Android symlink handling, all's
# stage order and stop-on-failure behaviour (without calling share), status
# output order (including mesa= without mounting), non-root refusal, and
# usage/exit codes.
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
    echo "--- mount" >&2; cat "$t/mount.log" 2>/dev/null || true
    echo "--- umount" >&2; cat "$t/umount.log" 2>/dev/null || true
    echo "--- ufw" >&2; cat "$t/ufw.log" 2>/dev/null || true
    echo "--- systemctl" >&2; cat "$t/systemctl.log" 2>/dev/null || true
    echo "--- getent" >&2; cat "$t/getent.log" 2>/dev/null || true
    echo "--- setfacl" >&2; cat "$t/setfacl.log" 2>/dev/null || true
    echo "--- chown" >&2; cat "$t/chown.log" 2>/dev/null || true
    echo "--- ln" >&2; cat "$t/ln.log" 2>/dev/null || true
    echo "--- timeout" >&2; cat "$t/timeout.log" 2>/dev/null || true
    echo "--- order" >&2; cat "$t/order.log" 2>/dev/null || true
    exit 1
}

# --- stand-ins ------------------------------------------------------------------
mkdir -p "$t/bin"

cat > "$t/bin/pacman" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$T715_TEST_PACMAN_LOG"
printf 'pacman %s\n' "${1:-}" >> "$T715_TEST_ORDER_LOG"
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
printf 'waydroid %s\n' "$*" >> "$T715_TEST_ORDER_LOG"
[ -f "$T715_TEST_WAYDROID_FAIL" ] && exit 1
if [ "${1:-}" = "shell" ]; then
    if [ -f "$T715_TEST_WAYDROID_SHELL_FAIL_MATCH" ]; then
        pat=$(cat "$T715_TEST_WAYDROID_SHELL_FAIL_MATCH")
        case "$*" in
            *"$pat"*)
                printf 'simulated shell error on %s\n' "$pat" >&2
                exit 1
                ;;
        esac
    fi
    if [ -f "$T715_TEST_WAYDROID_SHELL_RC" ]; then
        rc=$(cat "$T715_TEST_WAYDROID_SHELL_RC")
        exit "${rc:-1}"
    fi
    case "$*" in
        *"cmd package compile"*)
            if [ -f "$T715_TEST_WAYDROID_COMPILE_OUT" ]; then
                cat "$T715_TEST_WAYDROID_COMPILE_OUT"
            else
                printf 'Success\n'
            fi
            exit 0
            ;;
    esac
    if [ -f "$T715_TEST_WAYDROID_SHELL_OUT" ]; then
        cat "$T715_TEST_WAYDROID_SHELL_OUT"
    fi
    exit 0
fi
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
if [ "${1:-}" = "init" ] && [ -n "${T715_TEST_WAYDROID_CREATE_VENDOR:-}" ] && [ -n "${T715_TEST_WAYDROID_VENDOR_SRC:-}" ]; then
    mkdir -p "$T715_TEST_WAYDROID_CREATE_VENDOR/lib"
    cp "$T715_TEST_WAYDROID_VENDOR_SRC" "$T715_TEST_WAYDROID_CREATE_VENDOR/lib/libgallium_dri.so"
fi
exit 0
STUB

cat > "$t/bin/timeout" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$T715_TEST_TIMEOUT_LOG"
if [ -f "$T715_TEST_TIMEOUT_EXPIRE" ]; then
    exit 124
fi
shift
exec "$@"
STUB

cat > "$t/bin/mount" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$T715_TEST_MOUNT_LOG"
printf 'mount\n' >> "$T715_TEST_ORDER_LOG"
[ -f "$T715_TEST_MOUNT_FAIL" ] && exit 1
if [ "${1:-}" != "-o" ] || [ "${2:-}" != "ro,loop" ] || [ -z "${3:-}" ] || [ -z "${4:-}" ]; then
    printf 'stub mount: unexpected args: %s\n' "$*" >&2
    exit 1
fi
src=$3
dst=$4
if [ ! -d "$src" ] || [ ! -d "$dst" ]; then
    printf 'stub mount: bad src (%s) or dst (%s)\n' "$src" "$dst" >&2
    exit 1
fi
cp -R "$src/." "$dst/"
exit 0
STUB

cat > "$t/bin/umount" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$T715_TEST_UMOUNT_LOG"
printf 'umount\n' >> "$T715_TEST_ORDER_LOG"
if [ -n "${1:-}" ] && [ -d "$1" ]; then
    rm -rf "$1"/*
fi
exit 0
STUB

cat > "$t/bin/ufw" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$T715_TEST_UFW_LOG"
printf 'ufw %s\n' "${1:-}" >> "$T715_TEST_ORDER_LOG"
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
printf 'systemctl %s\n' "${1:-}" >> "$T715_TEST_ORDER_LOG"
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

chmod +x "$t/bin/pacman" "$t/bin/waydroid" "$t/bin/timeout" "$t/bin/mount" "$t/bin/umount" \
         "$t/bin/ufw" "$t/bin/systemctl" "$t/bin/getent" "$t/bin/setfacl" \
         "$t/bin/chown" "$t/bin/ln"

export T715_TEST_PACMAN_LOG="$t/pacman.log"
export T715_TEST_PACMAN_INSTALLED="$t/pacman.installed"
export T715_TEST_PACMAN_FAIL_SY="$t/pacman.fail_sy"
export T715_TEST_PACMAN_FAIL_SW="$t/pacman.fail_sw"
export T715_TEST_PACMAN_FAIL_U="$t/pacman.fail_u"
export T715_TEST_PACMAN_MARK_ON_U="$t/pacman.mark_on_u"
export T715_TEST_WAYDROID_LOG="$t/waydroid.log"
export T715_TEST_WAYDROID_FAIL="$t/waydroid.fail"
export T715_TEST_WAYDROID_SHELL_OUT="$t/waydroid.shell_out"
export T715_TEST_WAYDROID_COMPILE_OUT="$t/waydroid.compile_out"
export T715_TEST_WAYDROID_SHELL_RC="$t/waydroid.shell_rc"
export T715_TEST_WAYDROID_SHELL_FAIL_MATCH="$t/waydroid.shell_fail_match"
export T715_TEST_TIMEOUT_LOG="$t/timeout.log"
export T715_TEST_TIMEOUT_EXPIRE="$t/timeout.expire"
export T715_TEST_MOUNT_LOG="$t/mount.log"
export T715_TEST_MOUNT_FAIL="$t/mount.fail"
export T715_TEST_UMOUNT_LOG="$t/umount.log"
export T715_TEST_ORDER_LOG="$t/order.log"
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

# --- Mesa fixture binaries ------------------------------------------------------
TEST_MESA_OFFSET="0x20"
python3 - "$t" <<'PY'
import os, sys

base = sys.argv[1]
prefix = bytes(range(0x20))
suffix = bytes(range(0x24, 0x80))
with open(os.path.join(base, "mesa.bad"), "wb") as fh:
    fh.write(prefix + bytes.fromhex("01f0eaff") + suffix)
with open(os.path.join(base, "mesa.fixed"), "wb") as fh:
    fh.write(prefix + bytes.fromhex("aff30080") + suffix)
with open(os.path.join(base, "mesa.wrong_bytes"), "wb") as fh:
    fh.write(prefix + bytes.fromhex("deadbeef") + suffix)
with open(os.path.join(base, "mesa.other"), "wb") as fh:
    fh.write(b"Mesa-26.1.0-fixed-upstream" + bytes(range(102)))
PY
TEST_BAD_SHA=$(sha256sum "$t/mesa.bad" | awk '{print $1}')
TEST_FIXED_SHA=$(sha256sum "$t/mesa.fixed" | awk '{print $1}')
TEST_WRONG_BYTES_SHA=$(sha256sum "$t/mesa.wrong_bytes" | awk '{print $1}')
TEST_OTHER_SHA=$(sha256sum "$t/mesa.other" | awk '{print $1}')
TEST_OTHER_SHORT=${TEST_OTHER_SHA:0:12}

# --- fixture helpers ------------------------------------------------------------
S="$t/sys"
D="$t/dev"
TMP="$t/tmp"
CFG="$t/waydroid/waydroid.cfg"
VENDOR_IMG="$t/waydroid/images/vendor.img"
OVERLAY="$t/waydroid/overlay"
PLOCAL="$t/pacman-local"
HOMES="$t/homes"
ETC="$t/etc"

reset_env() {
    rm -rf "$S" "$D" "$TMP" "$t/waydroid" "$PLOCAL" "$HOMES" "$ETC" \
           "$t/pacman.installed" "$t/pacman.fail_sy" "$t/pacman.fail_sw" \
           "$t/pacman.fail_u" "$t/pacman.mark_on_u" "$t/waydroid.fail" \
           "$t/waydroid.shell_out" "$t/waydroid.compile_out" "$t/waydroid.shell_rc" \
           "$t/waydroid.shell_fail_match" "$t/timeout.expire" \
           "$t/mount.fail" "$t/ufw.skip" "$t/systemctl.active" \
           "$t/systemctl.fail" "$t/passwd" "$t/setfacl.fail" "$t/chown.fail"
    mkdir -p "$S/class/drm" "$D" "$TMP" "$t/waydroid" "$PLOCAL" "$HOMES/alarm" "$HOMES/alice" "$ETC"
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
    : > "$t/timeout.log"
    : > "$t/mount.log"
    : > "$t/umount.log"
    : > "$t/order.log"
    : > "$t/ufw.log"
    : > "$t/systemctl.log"
    : > "$t/getent.log"
    : > "$t/setfacl.log"
    : > "$t/chown.log"
    : > "$t/ln.log"
    : > "$t/out"
    : > "$t/err"
}

write_vendor_fixture() {
    rm -rf "$VENDOR_IMG"
    mkdir -p "$VENDOR_IMG/lib"
    cp "$1" "$VENDOR_IMG/lib/libgallium_dri.so"
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
        T715_ANDROID_VENDOR_IMG="$VENDOR_IMG" \
        T715_ANDROID_OVERLAY="$OVERLAY" \
        T715_ANDROID_MESA_BAD_SHA="$TEST_BAD_SHA" \
        T715_ANDROID_MESA_FIXED_SHA="$TEST_FIXED_SHA" \
        T715_ANDROID_MESA_OFFSET="$TEST_MESA_OFFSET" \
        T715_ANDROID_SYSFS="$S" \
        T715_ANDROID_DEV="$D" \
        T715_ANDROID_TMP="$TMP" \
        T715_ANDROID_ETC="$ETC" \
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

# --- (d2) mesa-fix --------------------------------------------------------------
OVERLAY_LIB="$OVERLAY/vendor/lib/libgallium_dri.so"

# No vendor image -> exit 1, message mentions init, no mount/umount
reset_env
run_as mesa-fix
[ "$RC" = 1 ] || fail "(d2) mesa-fix without vendor.img exits 1 (got $RC)"
grep -qi 'init' "$t/err" || fail "(d2) stderr tells user to run init first"
[ ! -s "$t/mount.log" ] && [ ! -s "$t/umount.log" ] \
    || fail "(d2) mount/umount not called when vendor.img missing"
[ "$(tmp_leftovers)" = 0 ] || fail "(d2) no temp leftovers when vendor.img missing"

# Known bad build -> applied, mode 0644, sha256 matches fixed, umount called
write_vendor_fixture "$t/mesa.bad"
run_as mesa-fix
[ "$RC" = 0 ] || fail "(d2) mesa-fix applied exits 0 (got $RC)"
[ "$(cat "$t/out")" = "mesa-fix: applied" ] \
    || fail "(d2) stdout is 'mesa-fix: applied' (got: $(cat "$t/out"))"
[ ! -s "$t/err" ] || fail "(d2) applied writes nothing to stderr"
[ -f "$OVERLAY_LIB" ] || fail "(d2) overlay library installed"
cmp -s "$t/mesa.fixed" "$OVERLAY_LIB" || fail "(d2) overlay library bytes match patched build"
python3 - "$OVERLAY_LIB" <<'PY' || fail "(d2) overlay library mode is not 0644"
import os, sys
mode = os.stat(sys.argv[1]).st_mode & 0o777
assert mode == 0o644, oct(mode)
PY
[ "$(wc -l < "$t/mount.log" | tr -d ' ')" = 1 ] || fail "(d2) mount called once"
[ "$(wc -l < "$t/umount.log" | tr -d ' ')" = 1 ] || fail "(d2) umount called once"
[ "$(tmp_leftovers)" = 0 ] || fail "(d2) temp dirs cleaned after apply"

# Second run -> nothing to do, overlay untouched, umount called
run_as mesa-fix
[ "$RC" = 0 ] || fail "(d2) second mesa-fix exits 0 (got $RC)"
grep -qi 'nothing to do' "$t/out" || fail "(d2) second run says nothing to do (got: $(cat "$t/out"))"
[ ! -s "$t/err" ] || fail "(d2) second run writes nothing to stderr"
cmp -s "$t/mesa.fixed" "$OVERLAY_LIB" || fail "(d2) overlay library unchanged on second run"
[ "$(wc -l < "$t/umount.log" | tr -d ' ')" = 1 ] || fail "(d2) umount called on second run"
[ "$(tmp_leftovers)" = 0 ] || fail "(d2) temp dirs cleaned on second run"

# Old bytes not as expected -> exit 1, existing overlay untouched, umount called
reset_env
write_vendor_fixture "$t/mesa.wrong_bytes"
mkdir -p "$(dirname "$OVERLAY_LIB")"
printf 'keep-existing-overlay\n' > "$OVERLAY_LIB"
clear_logs
RC=0
env T715_ANDROID_CFG="$CFG" \
    T715_ANDROID_VENDOR_IMG="$VENDOR_IMG" \
    T715_ANDROID_OVERLAY="$OVERLAY" \
    T715_ANDROID_MESA_BAD_SHA="$TEST_WRONG_BYTES_SHA" \
    T715_ANDROID_MESA_FIXED_SHA="$TEST_FIXED_SHA" \
    T715_ANDROID_MESA_OFFSET="$TEST_MESA_OFFSET" \
    T715_ANDROID_SYSFS="$S" \
    T715_ANDROID_DEV="$D" \
    T715_ANDROID_TMP="$TMP" \
    T715_ANDROID_PACMAN_LOCAL="$PLOCAL" \
    T715_ANDROID_ASSUME_ROOT=1 \
    PATH="$t/bin:$PATH" \
    "$AS" mesa-fix > "$t/out" 2> "$t/err" || RC=$?
[ "$RC" = 1 ] || fail "(d2) wrong old bytes exits 1 (got $RC)"
[ -s "$t/err" ] || fail "(d2) wrong old bytes reports error on stderr"
[ "$(cat "$OVERLAY_LIB")" = "keep-existing-overlay" ] \
    || fail "(d2) overlay untouched on wrong old bytes"
[ "$(wc -l < "$t/umount.log" | tr -d ' ')" = 1 ] || fail "(d2) umount called on wrong old bytes"
[ "$(tmp_leftovers)" = 0 ] || fail "(d2) temp dirs cleaned on wrong old bytes"

# Result sha mismatch -> exit 1, overlay untouched, umount called
reset_env
write_vendor_fixture "$t/mesa.bad"
mkdir -p "$(dirname "$OVERLAY_LIB")"
printf 'keep-before-sha-fail\n' > "$OVERLAY_LIB"
clear_logs
RC=0
env T715_ANDROID_CFG="$CFG" \
    T715_ANDROID_VENDOR_IMG="$VENDOR_IMG" \
    T715_ANDROID_OVERLAY="$OVERLAY" \
    T715_ANDROID_MESA_BAD_SHA="$TEST_BAD_SHA" \
    T715_ANDROID_MESA_FIXED_SHA="0000000000000000000000000000000000000000000000000000000000000000" \
    T715_ANDROID_MESA_OFFSET="$TEST_MESA_OFFSET" \
    T715_ANDROID_SYSFS="$S" \
    T715_ANDROID_DEV="$D" \
    T715_ANDROID_TMP="$TMP" \
    T715_ANDROID_PACMAN_LOCAL="$PLOCAL" \
    T715_ANDROID_ASSUME_ROOT=1 \
    PATH="$t/bin:$PATH" \
    "$AS" mesa-fix > "$t/out" 2> "$t/err" || RC=$?
[ "$RC" = 1 ] || fail "(d2) result sha mismatch exits 1 (got $RC)"
grep -qi 'mismatch' "$t/err" || fail "(d2) result sha mismatch reports mismatch on stderr"
[ "$(cat "$OVERLAY_LIB")" = "keep-before-sha-fail" ] \
    || fail "(d2) overlay untouched on result sha mismatch"
[ "$(wc -l < "$t/umount.log" | tr -d ' ')" = 1 ] || fail "(d2) umount called on result sha mismatch"
[ "$(tmp_leftovers)" = 0 ] || fail "(d2) temp dirs cleaned on result sha mismatch"

# Missing lib/libgallium_dri.so inside vendor.img -> exit 1, umount still called
reset_env
mkdir -p "$VENDOR_IMG"
run_as mesa-fix
[ "$RC" = 1 ] || fail "(d2) missing libgallium_dri.so exits 1 (got $RC)"
[ -s "$t/err" ] || fail "(d2) missing libgallium_dri.so prints error"
[ "$(wc -l < "$t/umount.log" | tr -d ' ')" = 1 ] || fail "(d2) umount called when lib missing"
[ "$(tmp_leftovers)" = 0 ] || fail "(d2) temp dirs cleaned when lib missing"

# Unknown vendor build with our patched file in overlay -> removed, exit 0
reset_env
write_vendor_fixture "$t/mesa.other"
mkdir -p "$(dirname "$OVERLAY_LIB")"
cp "$t/mesa.fixed" "$OVERLAY_LIB"
run_as mesa-fix
[ "$RC" = 0 ] || fail "(d2) unknown build with our patched overlay exits 0 (got $RC)"
[ ! -e "$OVERLAY_LIB" ] || fail "(d2) stale patched overlay removed on unknown build"
grep -qi 'removed' "$t/out" || fail "(d2) stdout reports removal of stale patched overlay"
grep -qx "mesa-fix: unknown Mesa build $TEST_OTHER_SHORT, nothing applied" "$t/out" \
    || fail "(d2) stdout prints unknown Mesa build line (got: $(cat "$t/out"))"
[ ! -s "$t/err" ] || fail "(d2) removing our stale overlay writes nothing to stderr"
[ "$(wc -l < "$t/umount.log" | tr -d ' ')" = 1 ] || fail "(d2) umount called on unknown build"
[ "$(tmp_leftovers)" = 0 ] || fail "(d2) temp dirs cleaned on unknown build"

# Unknown vendor build with foreign file in overlay -> kept, warning on stderr, exit 0
reset_env
write_vendor_fixture "$t/mesa.other"
mkdir -p "$(dirname "$OVERLAY_LIB")"
printf 'foreign-mesa-lib\n' > "$OVERLAY_LIB"
run_as mesa-fix
[ "$RC" = 0 ] || fail "(d2) unknown build with foreign overlay exits 0 (got $RC)"
[ -f "$OVERLAY_LIB" ] && [ "$(cat "$OVERLAY_LIB")" = "foreign-mesa-lib" ] \
    || fail "(d2) foreign overlay file kept untouched"
grep -qi 'warning' "$t/err" || fail "(d2) warning printed on stderr for foreign overlay"
[ "$(cat "$t/out")" = "mesa-fix: unknown Mesa build $TEST_OTHER_SHORT, nothing applied" ] \
    || fail "(d2) stdout prints unknown Mesa build line (got: $(cat "$t/out"))"
[ "$(wc -l < "$t/umount.log" | tr -d ' ')" = 1 ] || fail "(d2) umount called with foreign overlay"
[ "$(tmp_leftovers)" = 0 ] || fail "(d2) temp dirs cleaned with foreign overlay"

echo "ok - mesa-fix: applied, idempotent, byte/sha mismatch safe, unknown build cleanup/warning, missing image, umount always called"

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
[ "$(wc -l < "$t/out" | tr -d ' ')" = 7 ] \
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
assert cfg.get("properties", "ro.lmk.use_minfree_levels") == "false"
assert cfg.get("properties", "persist.waydroid.width") == "744"
assert cfg.get("properties", "persist.waydroid.height") == "1000"
assert cfg.get("properties", "ro.config.low_ram") == "true"
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

# T715_ANDROID_LOW_RAM=0 leaves ro.config.low_ram alone (absent or existing)
write_cfg_fixture
clear_logs
RC=0
env T715_ANDROID_CFG="$CFG" \
    T715_ANDROID_SYSFS="$S" \
    T715_ANDROID_DEV="$D" \
    T715_ANDROID_TMP="$TMP" \
    T715_ANDROID_PACMAN_LOCAL="$PLOCAL" \
    T715_ANDROID_ASSUME_ROOT=1 \
    T715_ANDROID_LOW_RAM=0 \
    PATH="$t/bin:$PATH" \
    "$AS" configure > "$t/out" 2> "$t/err" || RC=$?
[ "$RC" = 0 ] || fail "(e) configure with LOW_RAM=0 exits 0 (got $RC)"
[ "$(wc -l < "$t/out" | tr -d ' ')" = 6 ] \
    || fail "(e) LOW_RAM=0 changes 6 keys (got $(wc -l < "$t/out" | tr -d ' '))"
python3 - "$CFG" <<'PY' || fail "(e) LOW_RAM=0 should leave ro.config.low_ram absent"
import configparser, sys
cfg = configparser.ConfigParser(interpolation=None)
cfg.optionxform = str
cfg.read(sys.argv[1], encoding="utf-8")
assert not cfg.has_option("properties", "ro.config.low_ram")
PY

python3 - "$CFG" <<'PY'
import configparser, sys
cfg = configparser.ConfigParser(interpolation=None)
cfg.optionxform = str
cfg.read(sys.argv[1], encoding="utf-8")
cfg.set("properties", "ro.config.low_ram", "false")
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    cfg.write(fh)
PY
clear_logs
RC=0
env T715_ANDROID_CFG="$CFG" \
    T715_ANDROID_SYSFS="$S" \
    T715_ANDROID_DEV="$D" \
    T715_ANDROID_TMP="$TMP" \
    T715_ANDROID_PACMAN_LOCAL="$PLOCAL" \
    T715_ANDROID_ASSUME_ROOT=1 \
    T715_ANDROID_LOW_RAM=0 \
    PATH="$t/bin:$PATH" \
    "$AS" configure > "$t/out" 2> "$t/err" || RC=$?
[ "$RC" = 0 ] || fail "(e) configure with LOW_RAM=0 and existing false exits 0 (got $RC)"
[ "$(cat "$t/out")" = "nothing to change" ] || fail "(e) LOW_RAM=0 leaves existing value alone"
python3 - "$CFG" <<'PY' || fail "(e) LOW_RAM=0 altered existing ro.config.low_ram"
import configparser, sys
cfg = configparser.ConfigParser(interpolation=None)
cfg.optionxform = str
cfg.read(sys.argv[1], encoding="utf-8")
assert cfg.get("properties", "ro.config.low_ram") == "false"
PY

# Restore low_ram=true before density test
run_as configure
[ "$RC" = 0 ] || fail "(e) configure restoring low_ram exits 0 (got $RC)"
[ "$(wc -l < "$t/out" | tr -d ' ')" = 1 ] || fail "(e) restoring low_ram changes 1 key"

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
[ ! -s "$t/mount.log" ] || fail "(h) mesa-fix not called after init failed"
[ ! -s "$t/ufw.log" ] || fail "(h) firewall not called after init failed"
[ ! -s "$t/systemctl.log" ] || fail "(h) enable not called after init failed"

# Stop at failing mesa-fix (vendor.img absent after init)
reset_env
mk_drm_nodes
: > "$D/binder"
printf 'waydroid 1.6.3-1\n' > "$t/pacman.installed"
printf 'Status: active\n' > "$t/ufw.status"
clear_logs
RC=0
env T715_ANDROID_CFG="$CFG" \
    T715_ANDROID_VENDOR_IMG="$VENDOR_IMG" \
    T715_ANDROID_OVERLAY="$OVERLAY" \
    T715_ANDROID_MESA_BAD_SHA="$TEST_BAD_SHA" \
    T715_ANDROID_MESA_FIXED_SHA="$TEST_FIXED_SHA" \
    T715_ANDROID_MESA_OFFSET="$TEST_MESA_OFFSET" \
    T715_ANDROID_SYSFS="$S" \
    T715_ANDROID_DEV="$D" \
    T715_ANDROID_TMP="$TMP" \
    T715_ANDROID_PACMAN_LOCAL="$PLOCAL" \
    T715_ANDROID_ASSUME_ROOT=1 \
    T715_TEST_WAYDROID_CREATE_CFG="$CFG" \
    PATH="$t/bin:$PATH" \
    "$AS" all > "$t/out" 2> "$t/err" || RC=$?
[ "$RC" = 1 ] || fail "(h) all stops with exit 1 when mesa-fix fails (got $RC)"
[ "$(cat "$t/waydroid.log")" = "init" ] || fail "(h) configure not called after mesa-fix failed"
[ ! -s "$t/ufw.log" ] || fail "(h) firewall not called after mesa-fix failed"
[ ! -s "$t/systemctl.log" ] || fail "(h) enable not called after mesa-fix failed"

# Happy path: all --gapps runs all six stages in order
reset_env
mk_drm_nodes
: > "$D/binder"
: > "$t/pacman.mark_on_u"
printf 'Status: active\n' > "$t/ufw.status"
clear_logs
RC=0
env T715_ANDROID_CFG="$CFG" \
    T715_ANDROID_VENDOR_IMG="$VENDOR_IMG" \
    T715_ANDROID_OVERLAY="$OVERLAY" \
    T715_ANDROID_MESA_BAD_SHA="$TEST_BAD_SHA" \
    T715_ANDROID_MESA_FIXED_SHA="$TEST_FIXED_SHA" \
    T715_ANDROID_MESA_OFFSET="$TEST_MESA_OFFSET" \
    T715_ANDROID_SYSFS="$S" \
    T715_ANDROID_DEV="$D" \
    T715_ANDROID_TMP="$TMP" \
    T715_ANDROID_PACMAN_LOCAL="$PLOCAL" \
    T715_ANDROID_ASSUME_ROOT=1 \
    T715_TEST_WAYDROID_CREATE_CFG="$CFG" \
    T715_TEST_WAYDROID_CREATE_VENDOR="$VENDOR_IMG" \
    T715_TEST_WAYDROID_VENDOR_SRC="$t/mesa.bad" \
    PATH="$t/bin:$PATH" \
    "$AS" all --gapps > "$t/out" 2> "$t/err" || RC=$?
[ "$RC" = 0 ] || fail "(h) all --gapps happy path exits 0 (got $RC)"
[ "$(wc -l < "$t/pacman.log" | tr -d ' ')" = 4 ] || fail "(h) all ran packages"
want_wd='init -s GAPPS
upgrade --offline'
[ "$(cat "$t/waydroid.log")" = "$want_wd" ] || fail "(h) all ran init -s GAPPS then upgrade --offline"
cmp -s "$t/mesa.fixed" "$OVERLAY_LIB" || fail "(h) all applied mesa-fix"
[ "$(cat "$t/ufw.log")" = "$want_ufw" ] || fail "(h) all ran firewall"
[ "$(cat "$t/systemctl.log")" = "enable --now waydroid-container.service" ] \
    || fail "(h) all ran enable"
want_order='pacman -Q
pacman -Sy
pacman -Sw
pacman -U
waydroid init -s GAPPS
mount
umount
waydroid upgrade --offline
ufw status
ufw allow
ufw allow
ufw route
ufw route
systemctl enable'
[ "$(cat "$t/order.log")" = "$want_order" ] \
    || fail "(h) all stage order mismatch (got: $(cat "$t/order.log"))"
[ ! -s "$t/setfacl.log" ] && [ ! -s "$t/getent.log" ] \
    || fail "(h) all must not call share"
echo "ok - all: stops at first failing step with its exit code; happy path runs all six stages in order (not share)"

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

# --- (h3) google-id -------------------------------------------------------------
# Container inactive -> exit 1, message on stderr, neither timeout nor waydroid called
reset_env
run_as google-id
[ "$RC" = 1 ] || fail "(h3) google-id with inactive container exits 1 (got $RC)"
[ ! -s "$t/out" ] || fail "(h3) google-id with inactive container writes nothing to stdout"
grep -qi 'waydroid-container.service' "$t/err" \
    || fail "(h3) google-id inactive container error names waydroid-container.service"
[ ! -s "$t/timeout.log" ] && [ ! -s "$t/waydroid.log" ] \
    || fail "(h3) google-id with inactive container does not call timeout or waydroid"

# Numeric answer (synthetic dummy ID) -> exit 0, ID alone on stdout, 2 lines on stderr
reset_env
: > "$t/systemctl.active"
printf '1234567890123456789\n' > "$t/waydroid.shell_out"
run_as google-id
[ "$RC" = 0 ] || fail "(h3) google-id numeric answer exits 0 (got $RC)"
[ "$(cat "$t/out")" = "1234567890123456789" ] \
    || fail "(h3) google-id prints ID alone on stdout (got: $(cat "$t/out"))"
[ "$(wc -l < "$t/out" | tr -d ' ')" = 1 ] || fail "(h3) google-id stdout is exactly 1 line"
[ "$(wc -l < "$t/err" | tr -d ' ')" = 2 ] \
    || fail "(h3) google-id stderr is exactly 2 lines (got $(wc -l < "$t/err" | tr -d ' '))"
grep -Fq 'https://www.google.com/android/uncertified' "$t/err" \
    || fail "(h3) google-id stderr includes uncertified registration URL"
grep -Fq 't715-android stop' "$t/err" && grep -Fq 'start' "$t/err" \
    || fail "(h3) google-id stderr tells user to stop then start Android"
! grep -Fq '1234567890123456789' "$t/err" \
    || fail "(h3) google-id does not repeat the ID on stderr"
grep -Fq '30 waydroid shell -- sh -c ' "$t/timeout.log" \
    || fail "(h3) google-id runs waydroid shell bounded with timeout 30"
grep -Fq 'gservices.db' "$t/waydroid.log" && grep -Fq 'android_id' "$t/waydroid.log" \
    || fail "(h3) google-id queries gservices.db for android_id"
[ "$(tmp_leftovers)" = 0 ] || fail "(h3) google-id stores no temporary files"

# Numeric answer with trailing CR -> still accepted cleanly
printf '9876543210987654321\r\n' > "$t/waydroid.shell_out"
run_as google-id
[ "$RC" = 0 ] || fail "(h3) google-id numeric answer with CR exits 0 (got $RC)"
[ "$(cat "$t/out")" = "9876543210987654321" ] \
    || fail "(h3) google-id strips trailing CR cleanly"

# Empty answer -> exit 1, nothing on stdout, message says not created yet
: > "$t/waydroid.shell_out"
run_as google-id
[ "$RC" = 1 ] || fail "(h3) google-id empty answer exits 1 (got $RC)"
[ ! -s "$t/out" ] || fail "(h3) google-id empty answer writes nothing to stdout"
grep -qi 'not created' "$t/err" || fail "(h3) google-id empty answer explains ID not created yet"

# Garbage (non-numeric) answer -> exit 1, nothing on stdout
printf 'not-a-valid-id\n' > "$t/waydroid.shell_out"
run_as google-id
[ "$RC" = 1 ] || fail "(h3) google-id garbage answer exits 1 (got $RC)"
[ ! -s "$t/out" ] || fail "(h3) google-id garbage answer writes nothing to stdout"
grep -qi 'not created' "$t/err" || fail "(h3) google-id garbage answer explains ID not created yet"

# Multi-line numeric garbage -> exit 1
printf '12345\n67890\n' > "$t/waydroid.shell_out"
run_as google-id
[ "$RC" = 1 ] || fail "(h3) google-id multi-line output exits 1 (got $RC)"
[ ! -s "$t/out" ] || fail "(h3) google-id multi-line output writes nothing to stdout"

# waydroid shell non-zero exit (e.g., gservices.db missing) -> exit 1
printf '1\n' > "$t/waydroid.shell_rc"
run_as google-id
[ "$RC" = 1 ] || fail "(h3) google-id shell failure exits 1 (got $RC)"
[ ! -s "$t/out" ] || fail "(h3) google-id shell failure writes nothing to stdout"
grep -qi 'not created' "$t/err" || fail "(h3) google-id shell failure explains ID not created yet"
rm -f "$t/waydroid.shell_rc"

# Timeout (exit 124) -> exit 1, nothing on stdout, message mentions timed out
: > "$t/timeout.expire"
run_as google-id
[ "$RC" = 1 ] || fail "(h3) google-id timeout exits 1 (got $RC)"
[ ! -s "$t/out" ] || fail "(h3) google-id timeout writes nothing to stdout"
grep -qi 'timed out' "$t/err" || fail "(h3) google-id timeout reports timeout on stderr"
rm -f "$t/timeout.expire"
echo "ok - google-id: inactive container, numeric (+CR), empty, garbage, shell error, and timeout"

# --- (h4) trim ------------------------------------------------------------------
# Container inactive -> exit 1, message names waydroid-container.service, no shell call
reset_env
run_as trim
[ "$RC" = 1 ] || fail "(h4) trim with inactive container exits 1 (got $RC)"
[ ! -s "$t/out" ] || fail "(h4) trim with inactive container writes nothing to stdout"
grep -qi 'waydroid-container.service' "$t/err" \
    || fail "(h4) trim inactive container error names waydroid-container.service"
[ ! -s "$t/timeout.log" ] && [ ! -s "$t/waydroid.log" ] \
    || fail "(h4) trim with inactive container does not call timeout or waydroid"

# None of the trim packages installed (e.g. VANILLA image) -> nothing to trim, exit 0
reset_env
: > "$t/systemctl.active"
cat > "$t/waydroid.shell_out" <<'PKGS'
package:com.android.settings
package:org.lineageos.jelly
package:com.android.documentsui
PKGS
run_as trim
[ "$RC" = 0 ] || fail "(h4) trim when none installed exits 0 (got $RC)"
[ "$(cat "$t/out")" = "trim: nothing to trim" ] \
    || fail "(h4) trim prints 'trim: nothing to trim' (got: $(cat "$t/out"))"
[ ! -s "$t/err" ] || fail "(h4) trim nothing to trim writes nothing to stderr"
[ "$(cat "$t/waydroid.log")" = "shell -- pm list packages" ] \
    || fail "(h4) trim queries pm list packages once and stops when none match (got: $(cat "$t/waydroid.log"))"

# Subset installed (3 of 5, with CRLF) -> skips absent silently, disables 3, sets activity_manager_constants
reset_env
: > "$t/systemctl.active"
printf 'package:com.android.settings\r\npackage:com.google.android.googlequicksearchbox\r\npackage:com.google.android.dialer\r\npackage:com.google.android.as\r\n' \
    > "$t/waydroid.shell_out"
run_as trim
[ "$RC" = 0 ] || fail "(h4) trim subset exits 0 (got $RC)"
[ ! -s "$t/err" ] || fail "(h4) trim subset writes nothing to stderr"
want_trim_out='trim: disabled com.google.android.googlequicksearchbox
trim: disabled com.google.android.dialer
trim: disabled com.google.android.as'
[ "$(cat "$t/out")" = "$want_trim_out" ] \
    || fail "(h4) trim subset prints one line per package acted on (got: $(cat "$t/out"))"
want_trim_wd='shell -- pm list packages
shell -- pm disable-user --user 0 com.google.android.googlequicksearchbox
shell -- pm disable-user --user 0 com.google.android.dialer
shell -- pm disable-user --user 0 com.google.android.as
shell -- settings put global activity_manager_constants max_cached_processes=6'
[ "$(cat "$t/waydroid.log")" = "$want_trim_wd" ] \
    || fail "(h4) trim subset waydroid calls mismatch (got: $(cat "$t/waydroid.log"))"
[ "$(wc -l < "$t/timeout.log" | tr -d ' ')" = 5 ] \
    || fail "(h4) all 5 trim waydroid shell calls wrapped in timeout 30"
! grep -qv '^30 waydroid shell -- ' "$t/timeout.log" \
    || fail "(h4) every trim call uses timeout 30 waydroid shell --"

# All 5 default packages installed -> acts on all 5 + settings put
reset_env
: > "$t/systemctl.active"
cat > "$t/waydroid.shell_out" <<'PKGS'
package:com.google.android.googlequicksearchbox
package:com.google.android.apps.messaging
package:com.google.android.ims
package:com.google.android.dialer
package:com.google.android.as
PKGS
run_as trim
[ "$RC" = 0 ] || fail "(h4) trim all 5 exits 0 (got $RC)"
[ "$(wc -l < "$t/out" | tr -d ' ')" = 5 ] || fail "(h4) trim all 5 prints 5 lines"
grep -qx 'shell -- pm disable-user --user 0 com.google.android.apps.messaging' "$t/waydroid.log" \
    || fail "(h4) trim disables messaging"
grep -qx 'shell -- pm disable-user --user 0 com.google.android.ims' "$t/waydroid.log" \
    || fail "(h4) trim disables ims"
grep -qx 'shell -- settings put global activity_manager_constants max_cached_processes=6' "$t/waydroid.log" \
    || fail "(h4) trim sets max_cached_processes=6"

# --undo on subset installed -> pm enable for each installed, settings delete activity_manager_constants
reset_env
: > "$t/systemctl.active"
cat > "$t/waydroid.shell_out" <<'PKGS'
package:com.google.android.googlequicksearchbox
package:com.google.android.ims
package:com.android.settings
PKGS
run_as trim --undo
[ "$RC" = 0 ] || fail "(h4) trim --undo exits 0 (got $RC)"
[ ! -s "$t/err" ] || fail "(h4) trim --undo writes nothing to stderr"
want_undo_out='trim: enabled com.google.android.googlequicksearchbox
trim: enabled com.google.android.ims'
[ "$(cat "$t/out")" = "$want_undo_out" ] \
    || fail "(h4) trim --undo prints one line per package acted on (got: $(cat "$t/out"))"
want_undo_wd='shell -- pm list packages
shell -- pm enable com.google.android.googlequicksearchbox
shell -- pm enable com.google.android.ims
shell -- settings delete global activity_manager_constants'
[ "$(cat "$t/waydroid.log")" = "$want_undo_wd" ] \
    || fail "(h4) trim --undo waydroid calls mismatch (got: $(cat "$t/waydroid.log"))"

# --undo when none installed -> nothing to trim, exit 0
printf 'package:com.android.settings\n' > "$t/waydroid.shell_out"
run_as trim --undo
[ "$RC" = 0 ] || fail "(h4) trim --undo when none installed exits 0 (got $RC)"
[ "$(cat "$t/out")" = "trim: nothing to trim" ] \
    || fail "(h4) trim --undo prints nothing to trim when none installed"
[ "$(cat "$t/waydroid.log")" = "shell -- pm list packages" ] \
    || fail "(h4) trim --undo makes no pm/settings call when none installed"

# Override file $ETC/trim (comments, inline comments, blank lines, whitespace)
reset_env
: > "$t/systemctl.active"
cat > "$ETC/trim" <<'OVR'
# Custom trim list
  com.example.heavy   # inline comment

com.example.absent
com.example.second
com.example.heavy
OVR
cat > "$t/waydroid.shell_out" <<'PKGS'
package:com.google.android.googlequicksearchbox
package:com.example.heavy
package:com.example.second
PKGS
run_as trim
[ "$RC" = 0 ] || fail "(h4) trim with override exits 0 (got $RC)"
want_ovr_out='trim: disabled com.example.heavy
trim: disabled com.example.second'
[ "$(cat "$t/out")" = "$want_ovr_out" ] \
    || fail "(h4) trim override acts only on installed override pkgs (got: $(cat "$t/out"))"
! grep -q 'googlequicksearchbox' "$t/waydroid.log" \
    || fail "(h4) override file replaces default list"
grep -qx 'shell -- settings put global activity_manager_constants max_cached_processes=6' "$t/waydroid.log" \
    || fail "(h4) trim override still applies settings put"

# waydroid shell failure on pm list packages -> exit 1
printf '1\n' > "$t/waydroid.shell_rc"
run_as trim
[ "$RC" = 1 ] || fail "(h4) trim pm list failure exits 1 (got $RC)"
[ -s "$t/err" ] || fail "(h4) trim pm list failure reports error on stderr"
rm -f "$t/waydroid.shell_rc"

# waydroid shell failure on pm disable-user -> exit 1, stops before settings
printf 'pm disable-user' > "$t/waydroid.shell_fail_match"
run_as trim
[ "$RC" = 1 ] || fail "(h4) trim pm disable failure exits 1 (got $RC)"
[ -s "$t/err" ] || fail "(h4) trim pm disable failure reports error on stderr"
! grep -q 'settings put' "$t/waydroid.log" || fail "(h4) settings not called after pm disable fails"

# waydroid shell failure on settings put -> exit 1
printf 'settings put' > "$t/waydroid.shell_fail_match"
run_as trim
[ "$RC" = 1 ] || fail "(h4) trim settings put failure exits 1 (got $RC)"
[ -s "$t/err" ] || fail "(h4) trim settings put failure reports error on stderr"
rm -f "$t/waydroid.shell_fail_match"

# Timeout (exit 124) -> exit 1, message mentions timed out
: > "$t/timeout.expire"
run_as trim
[ "$RC" = 1 ] || fail "(h4) trim timeout exits 1 (got $RC)"
grep -qi 'timed out' "$t/err" || fail "(h4) trim timeout reports timeout on stderr"
rm -f "$t/timeout.expire"
echo "ok - trim: inactive container, none/subset/all installed, settings, --undo, override file, shell error, and timeout"

# --- (h5) optimize --------------------------------------------------------------
# Container inactive -> exit 1, message names waydroid-container.service, no shell call
reset_env
run_as optimize
[ "$RC" = 1 ] || fail "(h5) optimize with inactive container exits 1 (got $RC)"
[ ! -s "$t/out" ] || fail "(h5) optimize with inactive container writes nothing to stdout"
grep -qi 'waydroid-container.service' "$t/err" \
    || fail "(h5) optimize inactive container error names waydroid-container.service"
[ ! -s "$t/timeout.log" ] && [ ! -s "$t/waydroid.log" ] \
    || fail "(h5) optimize with inactive container does not call timeout or waydroid"

# Without arguments: realistic dumpsys package dexopt excerpt
reset_env
: > "$t/systemctl.active"
cat > "$t/waydroid.shell_out" <<'DEXOPT'
Dexopt state:
  [com.android.settings]
    path: /system/priv-app/Settings/Settings.apk
      arm: [status=verify] [reason=prebuilt]
  [com.android.documentsui]
    path: /system/priv-app/DocumentsUI/DocumentsUI.apk
      arm: [status=speed] [reason=cmdline]
  [org.lineageos.jelly]
    path: /system/product/app/Jelly/Jelly.apk
      arm: [status=speed-profile] [reason=bg-dexopt]
  [com.example.full]
    path: /data/app/~~aaa==/com.example.full-bbb==/base.apk
      arm: [status=everything] [reason=cmdline]
  [com.example.split]
    path: /data/app/~~ccc==/com.example.split-ddd==/base.apk
      arm: [status=speed-profile] [reason=install]
    path: /data/app/~~ccc==/com.example.split-ddd==/split_config.arm.apk
      arm: [status=verify] [reason=install]
  [com.example.quicken]
    path: /data/app/~~eee==/com.example.quicken-fff==/base.apk
      arm: [status=quicken] [reason=first-boot]
  [com.example.overlay]
    path: /vendor/overlay/ThemeOverlay.apk
Compiler stats:
  [com.android.documentsui]
     DocumentsUI.apk - 120
  [com.example.statsonly]
     StatsOnly.apk - 50
DEXOPT
run_as optimize
[ "$RC" = 0 ] || fail "(h5) optimize auto exits 0 (got $RC)"
[ ! -s "$t/err" ] || fail "(h5) optimize auto writes nothing to stderr"
want_opt_wd='shell -- dumpsys package dexopt
shell -- cmd package compile -m speed -f com.android.settings
shell -- cmd package compile -m speed -f com.example.split
shell -- cmd package compile -m speed -f com.example.quicken'
[ "$(cat "$t/waydroid.log")" = "$want_opt_wd" ] \
    || fail "(h5) optimize auto waydroid calls mismatch (got: $(cat "$t/waydroid.log"))"
grep -qx '30 waydroid shell -- dumpsys package dexopt' "$t/timeout.log" \
    || fail "(h5) dumpsys wrapped in timeout 30"
grep -qx '900 waydroid shell -- cmd package compile -m speed -f com.android.settings' "$t/timeout.log" \
    || fail "(h5) compile settings wrapped in timeout 900"
grep -qx '900 waydroid shell -- cmd package compile -m speed -f com.example.split' "$t/timeout.log" \
    || fail "(h5) compile split wrapped in timeout 900"
grep -qx '900 waydroid shell -- cmd package compile -m speed -f com.example.quicken' "$t/timeout.log" \
    || fail "(h5) compile quicken wrapped in timeout 900"
[ "$(sed -n '1p' "$t/out")" = "optimize: compiling 3 packages" ] \
    || fail "(h5) prints count before starting (got: $(sed -n '1p' "$t/out"))"
grep -Eq '^optimize: com\.android\.settings Success \([0-9]+ s\)$' "$t/out" \
    || fail "(h5) prints Success line for settings (got: $(cat "$t/out"))"
grep -Eq '^optimize: com\.example\.split Success \([0-9]+ s\)$' "$t/out" \
    || fail "(h5) prints Success line for split"
grep -Eq '^optimize: com\.example\.quicken Success \([0-9]+ s\)$' "$t/out" \
    || fail "(h5) prints Success line for quicken"

# All packages already compiled -> 0 packages, exit 0, no compile call
cat > "$t/waydroid.shell_out" <<'DEXOPT'
Dexopt state:
  [com.android.settings]
    path: /system/priv-app/Settings/Settings.apk
      arm: [status=speed] [reason=cmdline]
  [org.lineageos.jelly]
    path: /system/product/app/Jelly/Jelly.apk
      arm: [status=speed-profile] [reason=bg-dexopt]
DEXOPT
run_as optimize
[ "$RC" = 0 ] || fail "(h5) optimize when all compiled exits 0 (got $RC)"
[ "$(cat "$t/out")" = "optimize: 0 packages to compile" ] \
    || fail "(h5) prints 0 packages to compile (got: $(cat "$t/out"))"
[ "$(cat "$t/waydroid.log")" = "shell -- dumpsys package dexopt" ] \
    || fail "(h5) no compile call when all compiled"

# Explicit package arguments -> does not call dumpsys, compiles only given packages
run_as optimize com.android.deskclock com.android.documentsui
[ "$RC" = 0 ] || fail "(h5) optimize explicit pkgs exits 0 (got $RC)"
[ ! -s "$t/err" ] || fail "(h5) optimize explicit pkgs writes nothing to stderr"
want_opt_exp='shell -- cmd package compile -m speed -f com.android.deskclock
shell -- cmd package compile -m speed -f com.android.documentsui'
[ "$(cat "$t/waydroid.log")" = "$want_opt_exp" ] \
    || fail "(h5) optimize explicit pkgs calls mismatch (got: $(cat "$t/waydroid.log"))"
[ "$(sed -n '1p' "$t/out")" = "optimize: compiling 2 packages" ] \
    || fail "(h5) explicit pkgs prints count before starting"

# Partial failure: one package fails, remaining package still compiled, exit 1
printf 'com.example.bad' > "$t/waydroid.shell_fail_match"
run_as optimize com.example.bad com.example.good
[ "$RC" = 1 ] || fail "(h5) optimize partial failure exits 1 (got $RC)"
grep -q 'com.example.bad' "$t/err" || fail "(h5) failure reported on stderr"
grep -Eq '^optimize: com\.example\.good Success \([0-9]+ s\)$' "$t/out" \
    || fail "(h5) remaining package still compiled after earlier failure"
rm -f "$t/waydroid.shell_fail_match"

# Android `Failure` output with exit 0 -> treated as failure, exit 1
printf 'Failure\n' > "$t/waydroid.compile_out"
run_as optimize com.example.missing
[ "$RC" = 1 ] || fail "(h5) optimize Failure output exits 1 (got $RC)"
grep -q 'com.example.missing' "$t/err" || fail "(h5) Failure output reported on stderr"
rm -f "$t/waydroid.compile_out"

# Compile timeout (exit 124) -> exit 1, reports timed out
: > "$t/timeout.expire"
run_as optimize com.example.slow
[ "$RC" = 1 ] || fail "(h5) optimize compile timeout exits 1 (got $RC)"
grep -qi 'timed out' "$t/err" || fail "(h5) compile timeout reported on stderr"
rm -f "$t/timeout.expire"

# dumpsys failure -> exit 1, no compile calls
printf '1\n' > "$t/waydroid.shell_rc"
run_as optimize
[ "$RC" = 1 ] || fail "(h5) optimize dumpsys failure exits 1 (got $RC)"
[ -s "$t/err" ] || fail "(h5) optimize dumpsys failure writes stderr"
! grep -q 'cmd package compile' "$t/waydroid.log" || fail "(h5) no compile on dumpsys failure"
rm -f "$t/waydroid.shell_rc"
echo "ok - optimize: inactive container, dexopt parsing (multi-status/good/overlay/stats), explicit pkgs, partial failure, timeout"

# --- (i) status -----------------------------------------------------------------
reset_env
run_as status
[ "$RC" = 0 ] || fail "(i) status (uninitialised) exits 0 (got $RC)"
want_status_empty='kernel=no
package=none
initialised=no
gpu=
gles=
container=inactive
mesa=none'
[ "$(cat "$t/out")" = "$want_status_empty" ] \
    || fail "(i) uninitialised status lines and order mismatch"
[ ! -s "$t/mount.log" ] && [ ! -s "$t/umount.log" ] \
    || fail "(i) status (uninitialised) must not mount anything"

: > "$D/binder"
printf 'waydroid 1.6.3-1\n' > "$t/pacman.installed"
mk_drm_nodes
write_cfg_fixture
run_as configure
[ "$RC" = 0 ] || fail "(i) setup configure failed"
: > "$t/systemctl.active"
run_as status
[ "$RC" = 0 ] || fail "(i) status (configured, vendor) exits 0 (got $RC)"
want_status_vendor='kernel=yes
package=1.6.3-1
initialised=yes
gpu=/dev/dri/renderD129
gles=196609
container=active
mesa=vendor'
[ "$(cat "$t/out")" = "$want_status_vendor" ] \
    || fail "(i) configured status (mesa=vendor) lines and order mismatch"
[ ! -s "$t/mount.log" ] && [ ! -s "$t/umount.log" ] \
    || fail "(i) status (vendor) must not mount anything"

mkdir -p "$(dirname "$OVERLAY_LIB")"
cp "$t/mesa.fixed" "$OVERLAY_LIB"
run_as status
[ "$RC" = 0 ] || fail "(i) status (configured, fixed) exits 0 (got $RC)"
want_status_fixed='kernel=yes
package=1.6.3-1
initialised=yes
gpu=/dev/dri/renderD129
gles=196609
container=active
mesa=fixed'
[ "$(cat "$t/out")" = "$want_status_fixed" ] \
    || fail "(i) configured status (mesa=fixed) lines and order mismatch"
[ ! -s "$t/mount.log" ] && [ ! -s "$t/umount.log" ] \
    || fail "(i) status (fixed) must not mount anything"

printf 'some-other-overlay\n' > "$OVERLAY_LIB"
run_as status
[ "$RC" = 0 ] || fail "(i) status (configured, unknown) exits 0 (got $RC)"
want_status_unknown='kernel=yes
package=1.6.3-1
initialised=yes
gpu=/dev/dri/renderD129
gles=196609
container=active
mesa=unknown'
[ "$(cat "$t/out")" = "$want_status_unknown" ] \
    || fail "(i) configured status (mesa=unknown) lines and order mismatch"
[ ! -s "$t/mount.log" ] && [ ! -s "$t/umount.log" ] \
    || fail "(i) status (unknown) must not mount anything"
echo "ok - status: exact seven key=value lines in order, all four mesa states, never mounts"

# --- (j) non-root refusal -------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    reset_env
    for sub in packages init mesa-fix configure firewall enable share google-id trim optimize all; do
        clear_logs
        RC=0
        env T715_ANDROID_CFG="$CFG" \
            T715_ANDROID_VENDOR_IMG="$VENDOR_IMG" \
            T715_ANDROID_OVERLAY="$OVERLAY" \
            T715_ANDROID_SYSFS="$S" \
            T715_ANDROID_DEV="$D" \
            T715_ANDROID_TMP="$TMP" \
            T715_ANDROID_ETC="$ETC" \
            T715_ANDROID_PACMAN_LOCAL="$PLOCAL" \
            PATH="$t/bin:$PATH" \
            "$AS" "$sub" > "$t/out" 2> "$t/err" || RC=$?
        [ "$RC" = 1 ] || fail "(j) non-root $sub exits 1 (got $RC)"
        grep -qi 'root' "$t/err" || fail "(j) non-root $sub error mentions root"
        [ ! -s "$t/pacman.log" ] && [ ! -s "$t/waydroid.log" ] \
            && [ ! -s "$t/timeout.log" ] \
            && [ ! -s "$t/mount.log" ] && [ ! -s "$t/umount.log" ] \
            && [ ! -s "$t/ufw.log" ] && [ ! -s "$t/systemctl.log" ] \
            && [ ! -s "$t/getent.log" ] && [ ! -s "$t/setfacl.log" ] \
            && [ ! -s "$t/chown.log" ] && [ ! -s "$t/ln.log" ] \
            || fail "(j) non-root $sub called an external command"
    done
    # status and --help still work without root
    clear_logs
    RC=0
    env T715_ANDROID_CFG="$CFG" \
        T715_ANDROID_VENDOR_IMG="$VENDOR_IMG" \
        T715_ANDROID_OVERLAY="$OVERLAY" \
        T715_ANDROID_SYSFS="$S" \
        T715_ANDROID_DEV="$D" \
        T715_ANDROID_TMP="$TMP" \
        T715_ANDROID_ETC="$ETC" \
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
grep -q 't715-android-setup mesa-fix' "$t/out" || fail "(k) --help usage lists mesa-fix"
grep -q 't715-android-setup share' "$t/out" || fail "(k) --help usage lists share"
grep -q 't715-android-setup google-id' "$t/out" || fail "(k) --help usage lists google-id"
grep -q 't715-android-setup trim' "$t/out" || fail "(k) --help usage lists trim"
grep -q 't715-android-setup optimize' "$t/out" || fail "(k) --help usage lists optimize"
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

run_as mesa-fix extra
[ "$RC" = 2 ] || fail "(k) mesa-fix extra exits 2 (got $RC)"

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

run_as google-id extra
[ "$RC" = 2 ] || fail "(k) google-id extra exits 2 (got $RC)"

run_as trim --bogus
[ "$RC" = 2 ] || fail "(k) trim --bogus exits 2 (got $RC)"

run_as trim --undo extra
[ "$RC" = 2 ] || fail "(k) trim --undo extra exits 2 (got $RC)"

run_as optimize --bogus
[ "$RC" = 2 ] || fail "(k) optimize --bogus exits 2 (got $RC)"
echo "ok - usage and exit codes: --help on stdout (0), bad usage on stderr (2)"

echo "PASS"
