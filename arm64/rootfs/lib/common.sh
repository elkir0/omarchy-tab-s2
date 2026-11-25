# common.sh — shared helpers of the aarch64 root image build for the Galaxy
# Tab S2 8.0 LTE (SM-T715). Sourced by build.sh, tools/* and tests/*.
#
# Adapted from omarchy-tab-s2/image/lib/alarm.sh (read-only), for one
# architecture and with names of our own: every Docker image, container and
# volume this build creates starts with t715-arm64-port-rootfs-, so nothing
# here can touch the owner's (t715-omarchy:*, t715-kbuild*, ...).
#
# Images (all local, never pushed):
#   t715-arm64-port-rootfs/alarm      docker import of the official ALARM aarch64 tarball
#   t715-arm64-port-rootfs/dev        alarm + keyring + full upgrade + base-devel/git (compiles, makepkg)
#   t715-arm64-port-rootfs/build      dev + the build tools of the image build
#   t715-arm64-port-rootfs/helper     Debian stable + e2fsprogs, python3, file, binutils
#                                        (docker export -> ext4; the initramfs build)
#   t715-arm64-port-rootfs/base       the base image tree   (Dockerfile target "rootfs-base")
#   t715-arm64-port-rootfs/omarchy    the Omarchy image tree (Dockerfile target "rootfs-omarchy")

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOTFS_DIR="$(cd "$COMMON_DIR/.." && pwd)"
CACHE_DIR="$ROOTFS_DIR/cache"
OUT_DIR="$ROOTFS_DIR/out"
REPO_DIR="$OUT_DIR/repo/aarch64"        # the local pacman repository [t715-omarchy]
LOG_DIR="$CACHE_DIR/logs"

PREFIX="t715-arm64-port-rootfs"
PLATFORM="linux/arm64"
ARCH="aarch64"

ALARM_TARBALL="ArchLinuxARM-aarch64-latest.tar.gz"
ALARM_URL="http://os.archlinuxarm.org/os/$ALARM_TARBALL"
ALARM_TARBALL_PATH="$CACHE_DIR/$ALARM_TARBALL"
ALARM_PIN="$COMMON_DIR/alarm-tarball.sha256"   # "<sha256>  <file name>", written by tools/pin-tarball
ALARM_IMAGE="$PREFIX/alarm"
DEV_IMAGE="$PREFIX/dev"
BUILD_IMAGE="$PREFIX/build"
HELPER_IMAGE="$PREFIX/helper"
BASE_IMAGE="$PREFIX/base"
OMARCHY_IMAGE="$PREFIX/omarchy"

# Plain directories of ours (bind-mounted into the containers), not Docker
# volumes: the build leaves nothing in Docker but images and build cache.
PKCACHE_DIR="$CACHE_DIR/pkcache"      # pacman's package cache
SYNCDB_DIR="$CACHE_DIR/syncdb"        # pacman's synchronized databases (tools/audit-packages)
SRCDEST_DIR="$CACHE_DIR/srcdest"      # makepkg's source cache (tools/build-pkg)

# The owner's tree, read-only: the scripts and PKGBUILDs this build adapts
# are copied from it by tools/import-from-owner (never read at build time).
OWNER_REPO="${T715_OWNER_REPO:-}"
[ -n "$OWNER_REPO" ] || OWNER_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/"../../.. && pwd)" || true

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "${LOG_TAG:-rootfs}" "$*"; }
warn() { printf '\033[1;33m[%s:warn]\033[0m %s\n' "${LOG_TAG:-rootfs}" "$*" >&2; }
die()  { printf '\033[1;31m[%s:error]\033[0m %s\n' "${LOG_TAG:-rootfs}" "$*" >&2; exit 1; }

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
md5_of()    { md5 -q "$1"; }

# docker_preflight: the daemon answers and builds arm64 natively.
docker_preflight() {
    command -v docker >/dev/null || die "docker not found"
    docker info >/dev/null 2>&1 || die "docker daemon not reachable"
    local os arch
    os="$(docker info --format '{{.OSType}}' 2>/dev/null)"
    arch="$(docker info --format '{{.Architecture}}' 2>/dev/null)"
    [ "$os" = linux ] || die "docker does not run Linux containers (OSType=$os)"
    case "$arch" in aarch64|arm64) ;; *) warn "docker's architecture is $arch: arm64 containers run emulated (slow)" ;; esac
}

# owned_docker NAME...: refuse anything that is not ours.
owned_docker() {
    local n
    for n in "$@"; do
        case "$n" in "$PREFIX"|"$PREFIX":*|"$PREFIX"/*|"$PREFIX"-*) ;; *) die "refusing to touch a Docker object that is not ours: $n" ;; esac
    done
}

# ensure_tarball: the official ALARM aarch64 tarball in cache/, checked.
#   ALARM's own check first (the .md5 published next to the tarball), then,
#   when lib/alarm-tarball.sha256 exists, the SHA-256 pinned there: a tarball
#   that ALARM replaced fails loudly instead of silently changing the base.
ensure_tarball() {
    local expected actual pinned
    mkdir -p "$CACHE_DIR"
    if [ ! -s "$ALARM_TARBALL_PATH" ] || [ ! -s "$ALARM_TARBALL_PATH.md5" ]; then
        log "downloading $ALARM_URL"
        rm -f "$ALARM_TARBALL_PATH.part"
        curl -fsSL --retry 8 --retry-delay 5 --retry-all-errors -o "$ALARM_TARBALL_PATH.part" "$ALARM_URL" \
            || die "download of $ALARM_URL failed"
        curl -fsSL --retry 5 --retry-all-errors -o "$ALARM_TARBALL_PATH.md5.part" "$ALARM_URL.md5" \
            || die "download of $ALARM_URL.md5 failed"
        mv -f "$ALARM_TARBALL_PATH.md5.part" "$ALARM_TARBALL_PATH.md5"
        mv -f "$ALARM_TARBALL_PATH.part" "$ALARM_TARBALL_PATH"
    fi
    expected="$(awk '{print $1}' "$ALARM_TARBALL_PATH.md5")"
    actual="$(md5_of "$ALARM_TARBALL_PATH")"
    [ "$actual" = "$expected" ] || die "md5 mismatch for $ALARM_TARBALL_PATH: expected $expected, got $actual"
    if [ -f "$ALARM_PIN" ]; then
        # The pin is in shasum -c format (comment lines allowed).
        (cd "$CACHE_DIR" && shasum -a 256 -c --status "$ALARM_PIN") \
            || die "sha256 mismatch for $ALARM_TARBALL against $ALARM_PIN (ALARM replaced its tarball: review, then tools/pin-tarball)"
    else
        warn "no $ALARM_PIN: the tarball is checked against ALARM's md5 only (tools/pin-tarball pins its sha256)"
    fi
}

ensure_alarm_image() {
    docker image inspect "$ALARM_IMAGE" >/dev/null 2>&1 && return 0
    ensure_tarball
    log "importing $ALARM_TARBALL as $ALARM_IMAGE"
    docker import --platform "$PLATFORM" "$ALARM_TARBALL_PATH" "$ALARM_IMAGE" >/dev/null
}

# ensure_dev_image: alarm + pacman-key + full upgrade + base-devel git (lib/dev.Dockerfile).
ensure_dev_image() {
    docker image inspect "$DEV_IMAGE" >/dev/null 2>&1 && return 0
    ensure_alarm_image
    log "building $DEV_IMAGE (full upgrade + base-devel)"
    docker build --platform "$PLATFORM" --build-arg "BASE=$ALARM_IMAGE" \
        -f "$COMMON_DIR/dev.Dockerfile" -t "$DEV_IMAGE" "$COMMON_DIR" >&2 \
        || die "build of $DEV_IMAGE failed"
}

# ensure_helper_image: Debian trixie + e2fsprogs, native arm64 (mkimage.sh runs there).
ensure_helper_image() {
    docker image inspect "$HELPER_IMAGE" >/dev/null 2>&1 && return 0
    log "building $HELPER_IMAGE (debian:stable-slim + e2fsprogs, python3, file, binutils)"
    docker build --platform "$PLATFORM" -q -t "$HELPER_IMAGE" - >/dev/null <<'EOF' || die "build of $HELPER_IMAGE failed"
FROM debian:stable-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends e2fsprogs tar findutils coreutils \
    python3 file binutils xz-utils \
 && rm -rf /var/lib/apt/lists/*
EOF
}

ensure_pkcache_dir() { mkdir -p "$PKCACHE_DIR"; }

# run_dev [docker run args...]: a shell in $DEV_IMAGE with the pacman cache
# volume mounted, for interactive exploration and for the tools.
run_dev() {
    ensure_dev_image
    ensure_pkcache_dir
    docker run --rm -i --platform "$PLATFORM" \
        -v "$PKCACHE_DIR:/var/cache/pacman/pkg" "$@" "$DEV_IMAGE"
}
