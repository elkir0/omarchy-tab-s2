# alarm.sh — shared helpers for the Arch Linux ARM Docker images of the
# Omarchy image. Adapted from legacy/phosh/pkg/alarm-common.sh (copied on
# 2026-10-28). Source it, then call `alarm_setup <aarch64|armv7h>`.
#
# Images (all local, never pushed), all under the t715-omarchy name so that
# nothing here ever rebuilds or retags an image of the Phosh builder:
#   t715-omarchy:base-<arch>   tarball import
#   t715-omarchy:dev-<arch>    base + keyring + full upgrade + base-devel/git
#
# Tarballs come from os.archlinuxarm.org and are MD5-checked. They are looked
# up first in image/cache/ (git-ignored), then, read-only, in the legacy Phosh
# builder's cache (legacy/phosh/cache), else downloaded to image/cache/.

ALARM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALARM_REPO_DIR="$(cd "$ALARM_LIB_DIR/.." && pwd)"
ALARM_CACHE_DIR="$ALARM_REPO_DIR/cache"

alarm_log()  { printf '\033[1;34m[alarm]\033[0m %s\n' "$*" >&2; }
alarm_die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 2; }

# alarm_setup ARCH: sets ALARM_ARCH, ALARM_PLATFORM, ALARM_TARBALL,
# ALARM_BASE_IMAGE, ALARM_DEV_IMAGE.
alarm_setup() {
    ALARM_ARCH="$1"
    case "$ALARM_ARCH" in
        aarch64)
            ALARM_PLATFORM=linux/arm64
            ALARM_TARBALL=ArchLinuxARM-aarch64-latest.tar.gz
            ;;
        armv7h)
            ALARM_PLATFORM=linux/arm/v7
            ALARM_TARBALL=ArchLinuxARM-armv7-latest.tar.gz
            ;;
        *) alarm_die "unsupported arch: $ALARM_ARCH (aarch64|armv7h)" ;;
    esac
    ALARM_BASE_IMAGE="t715-omarchy:base-$ALARM_ARCH"
    ALARM_DEV_IMAGE="t715-omarchy:dev-$ALARM_ARCH"
    command -v docker >/dev/null || alarm_die "docker not found"
    docker info >/dev/null 2>&1 || alarm_die "docker daemon not reachable"
}

# alarm_fetch_tarball: sets ALARM_TARBALL_PATH to a verified tarball.
alarm_fetch_tarball() {
    local url="http://os.archlinuxarm.org/os/$ALARM_TARBALL"
    local f="$ALARM_CACHE_DIR/$ALARM_TARBALL"
    local shared="$ALARM_REPO_DIR/../legacy/phosh/cache/$ALARM_TARBALL"
    mkdir -p "$ALARM_CACHE_DIR"
    if { [ ! -f "$f" ] || [ ! -f "$f.md5" ]; } && [ -f "$shared" ] && [ -f "$shared.md5" ]; then
        f="$shared"
        alarm_log "using the legacy Phosh builder's tarball (read-only): $f"
    elif [ ! -f "$f" ] || [ ! -f "$f.md5" ]; then
        alarm_log "downloading $ALARM_TARBALL"
        curl -fL --retry 8 --retry-delay 5 --retry-all-errors -C - -o "$f" "$url"
        curl -fL --retry 5 -o "$f.md5" "$url.md5"
    fi
    local expected actual
    expected="$(awk '{print $1}' "$f.md5")"
    if command -v md5sum >/dev/null 2>&1; then
        actual="$(md5sum "$f" | awk '{print $1}')"
    else
        actual="$(md5 -q "$f")"
    fi
    [ "$actual" = "$expected" ] || alarm_die "md5 mismatch for $f: expected $expected, got $actual"
    ALARM_TARBALL_PATH="$f"
}

alarm_ensure_base_image() {
    if docker image inspect "$ALARM_BASE_IMAGE" >/dev/null 2>&1; then
        return 0
    fi
    alarm_fetch_tarball
    alarm_log "importing $ALARM_TARBALL as $ALARM_BASE_IMAGE"
    docker import --platform "$ALARM_PLATFORM" \
        "$ALARM_TARBALL_PATH" "$ALARM_BASE_IMAGE" >/dev/null
}

# alarm_ensure_dev_image [--rebuild]
alarm_ensure_dev_image() {
    if [ "${1:-}" != "--rebuild" ] \
       && docker image inspect "$ALARM_DEV_IMAGE" >/dev/null 2>&1; then
        return 0
    fi
    alarm_ensure_base_image
    alarm_log "building $ALARM_DEV_IMAGE (full upgrade + base-devel; slow under qemu for armv7h)"
    docker build --platform "$ALARM_PLATFORM" \
        --build-arg BASE="$ALARM_BASE_IMAGE" \
        -f "$ALARM_LIB_DIR/alarm-dev.Dockerfile" \
        -t "$ALARM_DEV_IMAGE" "$ALARM_LIB_DIR" >&2
}

# pkgbuild_version DIR: prints "<pkgver>-<pkgrel>" read from DIR/PKGBUILD
# without executing it.
pkgbuild_version() {
    local pb="$1/PKGBUILD" ver rel
    ver="$(sed -n 's/^pkgver=//p' "$pb" | head -n1)"
    rel="$(sed -n 's/^pkgrel=//p' "$pb" | head -n1)"
    [ -n "$ver" ] && [ -n "$rel" ] || alarm_die "cannot read pkgver/pkgrel from $pb"
    printf '%s-%s\n' "$ver" "$rel"
}

# local_pkg_path NAME ARCH: prints the cached package file for the version in
# pkg/NAME/PKGBUILD, or nothing when it has not been built yet.
local_pkg_path() {
    local name="$1" arch="$2" ver f
    ver="$(pkgbuild_version "$ALARM_REPO_DIR/pkg/$name")"
    for f in "$ALARM_CACHE_DIR/pkg/$arch/$name-$ver-$arch".pkg.tar.*; do
        case "$f" in *.sig) continue ;; esac
        [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
    done
    return 0
}
