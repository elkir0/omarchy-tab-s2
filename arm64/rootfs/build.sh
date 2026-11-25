#!/usr/bin/env bash
# build.sh — the aarch64 root images of the Galaxy Tab S2 8.0 LTE (SM-T715,
# Exynos 5433) for the arm64 port, in Docker on the Mac (arm64 containers,
# native). The one command of this directory.
#
# Produces, in out/:
#   rootfs-aarch64-base.img      raw ext4 (label T715ARM64): Arch Linux ARM
#                                aarch64, systemd, sshd, NetworkManager, a
#                                getty, the user alarm: multi-user
#   rootfs-aarch64-omarchy45.img the same with Omarchy 4.5.0-3 (Hyprland, the
#                                Omarchy shell and Omarchy Mobile's touch
#                                layer), SDDM logging alarm in, when --target
#                                says so (it was rootfs-aarch64-omarchy.img,
#                                Omarchy 4.0.6, until 2026-11-24)
#   <image>.sha256               each image's checksum (shasum -a 256 -c format)
#   <image>.MANIFEST             what is inside: versions, packages, the
#                                build's records, the smoke check
#   package-audit.tsv            (tools/audit-packages) which of the owner's
#                                packages exist for aarch64
#   repo/aarch64/                the local repository [t715-omarchy]: Omarchy's
#                                pinned aarch64 packages, Omarchy Mobile's
#                                (omamobile-pins), and the packages built here
#                                (pkg/), with their manifests
#   initramfs/                   the initramfs skeleton (initramfs/build-initramfs.sh):
#                                root/ for CONFIG_INITRAMFS_SOURCE, the cpio.gz
#
# Usage:
#   build.sh [--target base|omarchy|all] [--ssh-pubkey FILE] [--user NAME]
#            [--password HASH] [--locale LANG] [--timezone TZ] [--size MiB]
#            [--max-size MiB] [--no-cache] [--keep-images] [--skip-packages] [-h]
#     --target WHICH     base, omarchy or all (default all; omarchy builds the
#                        base first and reuses its layers)
#     --ssh-pubkey FILE  OpenSSH public key for root and the user; without it
#                        nobody can log in over ssh (no password
#                        authentication, the user's is a placeholder)
#     --user NAME        the user's name, uid 1000 (default: alarm, ALARM's
#                        own user, as on the owner's armv7h tablet; another
#                        name renames it)
#     --password HASH    a crypt(3) hash for that user. Default: the
#                        documented PLACEHOLDER "changeme" (PLACEHOLDER_PASSWORD
#                        below; never ALARM's "alarm")
#     --locale LANG      LANG of the image (default en_US.UTF-8)
#     --timezone TZ      its time zone, a name under /usr/share/zoneinfo (default UTC)
#     --size MiB        file system size, 0 = content + 20 % (default 0)
#     --max-size MiB     a ceiling on the automatic size (default: 8192 for the
#                        base image, none for the Omarchy image)
#     --no-cache        rebuild every layer (fresh package sync)
#     --keep-images      keep the Docker images t715-arm64-port-rootfs/{base,omarchy}
#     --skip-packages    do not run tools/build-pkg (use out/repo/aarch64 as it is)
#
# What it does: lib/common.sh (the official tarball, the dev and helper
# images, the pacman cache volume), tools/fetch-omarchy, tools/fetch-omamobile
# and tools/build-pkg (the local repository [t715-omarchy]: Omarchy's and
# Omarchy Mobile's pinned aarch64 packages, verified, and the ones built for
# this tablet), a staged build context (cache/context),
# `docker build` per target, the smoke check in the image's own container,
# `docker export` into mkfs.ext4 -d (mkimage.sh, in the helper container:
# the tree is never extracted on macOS), checksums and manifests.
# Nothing here can reach the tablet: no device, no network but the package
# repositories.

set -euo pipefail

ROOTFS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$ROOTFS_DIR/lib/common.sh"

TARGET=all
SSH_PUBKEY=""
T715_USER=alarm
PASSWORD_HASH=""
T715_LANG=en_US.UTF-8
T715_TZ=UTC
SIZE_MIB=0
MAX_BASE=8192
MAX_OMARCHY=0
NO_CACHE=0
KEEP_IMAGES=0
SKIP_PACKAGES=0
# The placeholder password of the user (documented, to be changed: passwd, or
# omamobile-set-pin on the tablet).
PLACEHOLDER_PASSWORD="changeme"
BASE_IMG="rootfs-aarch64-base.img"
OMARCHY_IMG="rootfs-aarch64-omarchy45.img"
LABEL="T715ARM64"
HOST_NAME="gts28lte-arm64"

usage() { sed -n '/^# Usage:/,/^#$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --target)        TARGET="${2:?--target needs base, omarchy or all}"; shift 2 ;;
        --ssh-pubkey)    SSH_PUBKEY="${2:?--ssh-pubkey needs a file}"; shift 2 ;;
        --user)          T715_USER="${2:?--user needs a name}"; shift 2 ;;
        --password)      PASSWORD_HASH="${2:?--password needs a crypt hash}"; shift 2 ;;
        --locale)        T715_LANG="${2:?--locale needs a value}"; shift 2 ;;
        --timezone)      T715_TZ="${2:?--timezone needs a value}"; shift 2 ;;
        --size)          SIZE_MIB="${2:?--size needs a value in MiB}"; shift 2 ;;
        --max-size)      MAX_OMARCHY="${2:?}"; MAX_BASE="${2:?}"; shift 2 ;;
        --no-cache)      NO_CACHE=1; shift ;;
        --keep-images)   KEEP_IMAGES=1; shift ;;
        --skip-packages) SKIP_PACKAGES=1; shift ;;
        -h|--help)       usage 0 ;;
        *)               die "unknown option: $1 (see --help)" ;;
    esac
done
case "$TARGET" in base|omarchy|all) ;; *) die "--target: base, omarchy or all (not $TARGET)" ;; esac
[[ "$T715_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "--user $T715_USER: a lower-case user name"
[ "$T715_USER" != root ] || die "--user root: the user must not be root"
[[ "$T715_LANG" =~ ^[a-z]{2,3}_[A-Z]{2}\.UTF-8$ ]] || die "--locale $T715_LANG: expected a name like en_US.UTF-8"
[[ "$T715_TZ" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] || die "--timezone $T715_TZ: expected a zoneinfo name like UTC or Europe/Paris"
[[ "$SIZE_MIB$MAX_BASE$MAX_OMARCHY" =~ ^[0-9]+$ ]] || die "--size and --max-size must be integers (MiB)"
if [ -n "$SSH_PUBKEY" ]; then
    [ -r "$SSH_PUBKEY" ] || die "cannot read SSH public key: $SSH_PUBKEY"
    ! grep -q 'PRIVATE KEY' "$SSH_PUBKEY" || die "$SSH_PUBKEY is a private key: pass the .pub file"
    [ "$(grep -c . "$SSH_PUBKEY")" -ge 1 ] || die "$SSH_PUBKEY is empty"
fi
if [ -n "$PASSWORD_HASH" ]; then
    [[ "$PASSWORD_HASH" == *'$'* ]] || die "--password: a crypt(3) hash contains a '\$'"
fi

mkdir -p "$OUT_DIR" "$CACHE_DIR" "$LOG_DIR"
BUILD_START="$(date +%s)"
log "1/7 preflight"
docker_preflight
free_gb="$(df -g "$HOME" | awk 'NR == 2 {print $4}')"
[ "$free_gb" -ge 25 ] || warn "only ${free_gb} GB free: the Omarchy image build needs about 20 GB"
ensure_dev_image
ensure_helper_image
ensure_pkcache_dir

# ---------------------------------------------------------------------------
log "2/7 the local repository [t715-omarchy]"
mkdir -p "$REPO_DIR"
if [ "$TARGET" != base ] || [ -f "$REPO_DIR/MANIFEST-omarchy.tsv" ]; then
    bash "$ROOTFS_DIR/tools/fetch-omarchy"
fi
if [ "$TARGET" != base ]; then
    bash "$ROOTFS_DIR/tools/fetch-omamobile"
fi
if [ "$TARGET" != base ] && [ "$SKIP_PACKAGES" = 0 ]; then
    # Dependencies first: omamobile-shell depends on omatel-agent (the
    # alphabetical order of pkg/ builds it too early); any other package
    # of pkg/ follows in alphabetical order.
    order="omatel-agent"
    for d in "$ROOTFS_DIR"/pkg/*/; do
        n="$(basename "$d")"
        case " $order " in *" $n "*) ;; *) order="$order $n" ;; esac
    done
    for n in $order; do
        [ -f "$ROOTFS_DIR/pkg/$n/PKGBUILD" ] || continue
        # t715-modem's source is this repository's modem/, archived from a commit (git-ignored):
        # a fresh clone has none yet. An archive already there is kept (tools/stage-t715-modem
        # by hand takes another commit).
        if [ "$n" = t715-modem ] && [ ! -f "$ROOTFS_DIR/pkg/t715-modem/t715-modem-src.tar.gz" ]; then
            bash "$ROOTFS_DIR/tools/stage-t715-modem"
        fi
        bash "$ROOTFS_DIR/tools/build-pkg" "$n"
    done
fi

# ---------------------------------------------------------------------------
log "3/7 build context (cache/context)"
CTX="$CACHE_DIR/context"
rm -rf "$CTX"
mkdir -p "$CTX/firmware" "$CTX/ssh" "$CTX/repo-manifests" "$CTX/watchdog" "$CTX/shim"
cp -f "$ROOTFS_DIR/Dockerfile" "$ROOTFS_DIR"/*.sh "$ROOTFS_DIR"/packages.* "$ROOTFS_DIR"/t715-*.lua \
      "$ROOTFS_DIR/omarchy-trusted.fpr" "$ROOTFS_DIR/omarchy-migrations.hold" "$CTX/"
cp -R "$ROOTFS_DIR/overlay" "$ROOTFS_DIR/overlay-omarchy" "$CTX/"
cp -f "$ROOTFS_DIR/watchdog/t715-watchdog-keeper.c" "$CTX/watchdog/"
cp -f "$ROOTFS_DIR/shim/t715-dmabuf-check-shim.c" "$CTX/shim/"
cp -f "$COMMON_DIR/alarm-tarball.sha256" "$CTX/tarball-pin"
cp -f "$ROOTFS_DIR/on-device-README.md" "$CTX/README.md"
# The two vendor files, if the owner staged them (never read here: copied, and
# only their sizes reach the records).
for f in nvram_net.txt bcm4358A3_V0086.0144.hcd; do
    [ ! -s "$CACHE_DIR/vendor/$f" ] || cp -f "$CACHE_DIR/vendor/$f" "$CTX/firmware/$f"
done
: > "$CTX/ssh/authorized_keys"
if [ -n "$SSH_PUBKEY" ]; then
    cp -f "$SSH_PUBKEY" "$CTX/ssh/authorized_keys"
fi
chmod 0644 "$CTX/ssh/authorized_keys"
for m in "$REPO_DIR"/MANIFEST-*.tsv; do
    [ -f "$m" ] && cp -f "$m" "$CTX/repo-manifests/" || true
done
# The Omarchy image's part of the smoke check (nothing yet: an empty file).
if [ -f "$ROOTFS_DIR/smoke-check-omarchy" ]; then
    cp -f "$ROOTFS_DIR/smoke-check-omarchy" "$CTX/"
else
    : > "$CTX/smoke-check-omarchy"
fi
{
    printf 'T715_USER=%s\nT715_LANG=%s\nT715_TZ=%s\n' "$T715_USER" "$T715_LANG" "$T715_TZ"
    if [ -n "$PASSWORD_HASH" ]; then printf 'T715_PASSWORD_HASH=%s\n' "$PASSWORD_HASH"
    else printf 'T715_PASSWORD=%s\n' "$PLACEHOLDER_PASSWORD"; fi
} > "$CTX/user.env"
vendor="$(ls "$CTX/firmware" | tr '\n' ' ')"
log "context: user $T715_USER, LANG=$T715_LANG, $T715_TZ, ssh key: $([ -n "$SSH_PUBKEY" ] && echo given || echo none), vendor files staged: ${vendor:-none}"

# ---------------------------------------------------------------------------
build_target() { # TARGET-NAME IMAGE-TAG STAGE IMG MAX_MIB
    local target="$1" tag="$2" stage="$3" img="$4" max="$5"
    local flags=(--platform "$PLATFORM" --progress=plain --build-context "t715repo=$REPO_DIR"
                 --build-arg "BASE=$ALARM_IMAGE" --build-arg "DEV=$DEV_IMAGE"
                 --target "$target" -t "$tag")
    [ "$NO_CACHE" -eq 0 ] || flags+=(--no-cache)
    local tries=0
    log "[$stage] docker build --target $target (log: $LOG_DIR/build-$stage.log)"
    while :; do
        if docker build "${flags[@]}" "$CTX" 2>&1 | tee "$LOG_DIR/build-$stage.log" >/dev/null; then
            return 0
        fi
        tries=$((tries + 1))
        # ALARM's mirror can be out of sync (a package its database lists is
        # not there yet, "404"): a few minutes later it is. Cached layers make
        # the retry cheap. Any other failure stops the build.
        if [ "$tries" -le 5 ] && grep -qE 'failed to retrieve file|error retrieving|returned error: 40[34]|Unexpected EOF|Operation too slow|Failed to connect' "$LOG_DIR/build-$stage.log"; then
            log "[$stage] a package mirror did not serve a file: retry $tries in $((tries * 30)) s"
            sleep "$((tries * 30))"
            continue
        fi
        die "docker build of $target failed (see $LOG_DIR/build-$stage.log)"
    done
}

# ---------------------------------------------------------------------------
smoke_target() { # IMAGE-TAG STAGE OUTFILE -> exits on failure
    local tag="$1" stage="$2" out="$3" rc
    log "[$stage] smoke check in the image's own container"
    set +e
    docker run --rm --platform "$PLATFORM" "$tag" /usr/lib/t715-arm64/smoke-check > "$out" 2>&1
    rc=$?
    set -e
    grep -E '^(FAIL|WARN)' "$out" || true
    [ "$rc" -eq 0 ] || { cat "$out"; die "the smoke check of the $stage image failed (exit $rc): see $out"; }
    log "[$stage] smoke check: PASS ($(grep -c '^PASS' "$out") checks, $(grep -c '^WARN' "$out") warnings)"
}

# ---------------------------------------------------------------------------
export_target() { # IMAGE-TAG STAGE IMG MAX_MIB SMOKE-FILE
    local tag="$1" stage="$2" img="$3" max="$4" smoke="$5"
    local ctr="$PREFIX-export-$stage" mk="$PREFIX-mkimage-$stage" stats="$CACHE_DIR/mkimage-$stage.out"
    owned_docker "$ctr" "$mk"
    docker rm -f "$ctr" "$mk" >/dev/null 2>&1 || true
    log "[$stage] exporting the tree into out/$img (size: $([ "$SIZE_MIB" -eq 0 ] && echo auto || echo "$SIZE_MIB MiB"))"
    docker create --name "$ctr" --platform "$PLATFORM" "$tag" /bin/true >/dev/null
    docker cp "$ctr:/usr/share/t715-arm64/MANIFEST.image" "$CACHE_DIR/MANIFEST.image-$stage" >/dev/null
    if ! docker export "$ctr" | docker run --rm -i --name "$mk" --platform "$PLATFORM" \
            -e IMG="/out/$img" -e SIZE_MIB="$SIZE_MIB" -e MAX_MIB="$max" -e LABEL="$LABEL" \
            -e HOST_NAME="$HOST_NAME" -e STAGE="$stage" \
            -v "$OUT_DIR:/out" -v "$ROOTFS_DIR/mkimage.sh:/mkimage.sh:ro" \
            "$HELPER_IMAGE" bash /mkimage.sh > "$stats"; then
        rm -f "$OUT_DIR/$img.tmp"
        die "ext4 image creation failed for $img"
    fi
    docker rm -f "$ctr" >/dev/null
    stat_of() { sed -n "s/^T715_$1=//p" "$stats" | head -n1; }
    BS="$(stat_of BLOCK_SIZE)"; BC="$(stat_of BLOCK_COUNT)"; FB="$(stat_of FREE_BLOCKS)"
    IC="$(stat_of INODE_COUNT)"; FI="$(stat_of FREE_INODES)"

    log "[$stage] checksum and manifest of $img"
    (cd "$OUT_DIR" && rm -f "$img.sha256" && shasum -a 256 "$img" > "$img.sha256.tmp" && mv -f "$img.sha256.tmp" "$img.sha256")
    local sha bytes du_bytes
    sha="$(cut -d' ' -f1 "$OUT_DIR/$img.sha256")"
    bytes="$(stat -f %z "$OUT_DIR/$img")"
    du_bytes="$(du -k "$OUT_DIR/$img" | cut -f1)"
    {
        echo "# $(basename "$img" .img).MANIFEST — aarch64 image for the Galaxy Tab S2 8.0 LTE (SM-T715)"
        echo "# written by build.sh on $(date -u '+%Y-%m-%d %H:%M:%S UTC'); NOT TESTED ON THE TABLET (built in Docker on the Mac)"
        echo
        echo "== Image =="
        echo "file:            $img"
        echo "format:          raw ext4 (not Android sparse), label $(stat_of LABEL), block size $BS"
        echo "features:        $(stat_of FEATURES)"
        echo "size:            $(( BC * BS / 1048576 )) MiB ($bytes bytes; $(( du_bytes / 1024 )) MiB on the Mac's disk: a sparse file)"
        echo "used:            $(( (BC - FB) * BS / 1048576 )) MiB (content $(stat_of CONTENT_MIB) MiB + file system metadata and journal)"
        echo "free:            $(( FB * BS / 1048576 )) MiB, $FI of $IC inodes free"
        echo "sha256:          $sha"
        echo "hostname:        $HOST_NAME"
        echo "user:            $T715_USER (uid 1000), password: $( [ -n "$PASSWORD_HASH" ] && echo 'the hash given at the build' || echo "PLACEHOLDER \"$PLACEHOLDER_PASSWORD\" (change it: passwd $T715_USER)")"
        echo "ssh:             $([ -n "$SSH_PUBKEY" ] && echo "the key given at the build, for root and $T715_USER" || echo 'NO KEY: nobody can log in over ssh until one is given (--ssh-pubkey), or one is added to the image')"
        echo "base:            Arch Linux ARM aarch64 tarball, sha256 $(awk '/^[0-9a-f]/ {print $1}' "$COMMON_DIR/alarm-tarball.sha256")"
        echo "locale:          LANG=$T715_LANG, $T715_TZ"
        cat "$CACHE_DIR/MANIFEST.image-$stage"
        echo
        echo "== Smoke check (in the image's own container on the Mac: no hardware, no watchdog, no compositor) =="
        cat "$smoke"
    } > "$OUT_DIR/$(basename "$img" .img).MANIFEST"
    chmod 0644 "$OUT_DIR/$img.sha256"
    [ "$KEEP_IMAGES" -eq 1 ] || docker image rm "$tag" >/dev/null 2>&1 || true
    log "done: out/$img"
}

# ---------------------------------------------------------------------------
# The package audit: what the owner's lists have for aarch64.
if [ ! -s "$OUT_DIR/package-audit.tsv" ] || [ "${T715_AUDIT:-0}" = 1 ]; then
    bash "$ROOTFS_DIR/tools/audit-packages" | sed 's/^/[audit] /'
fi

log "the images (build, smoke check, export, checksum)"
[ "$TARGET" = omarchy ] || build_target rootfs-base "$BASE_IMAGE" base "$BASE_IMG" "$MAX_BASE"
[ "$TARGET" = base ] || build_target rootfs-omarchy "$OMARCHY_IMAGE" omarchy "$OMARCHY_IMG" "$MAX_OMARCHY"
# The base image's smoke check, export, checksum and manifest.
if [ "$TARGET" != omarchy ]; then
    smoke_target "$BASE_IMAGE" base "$CACHE_DIR/smoke-base.txt"
    export_target "$BASE_IMAGE" base "$BASE_IMG" "$MAX_BASE" "$CACHE_DIR/smoke-base.txt"
fi
# The Omarchy image.
if [ "$TARGET" != base ]; then
    smoke_target "$OMARCHY_IMAGE" omarchy "$CACHE_DIR/smoke-omarchy.txt"
    export_target "$OMARCHY_IMAGE" omarchy "$OMARCHY_IMG" "$MAX_OMARCHY" "$CACHE_DIR/smoke-omarchy.txt"
fi

# The initramfs skeleton that boots these images (the tests of its init in Docker).
bash "$ROOTFS_DIR/initramfs/build-initramfs.sh"
bash "$ROOTFS_DIR/tests/test-initramfs.sh" | tail -n 1 | sed 's/^/[initramfs] /'

printf '%s\n' "-------------------------------------------------------------"
for img in "$BASE_IMG" "$OMARCHY_IMG"; do
    [ -f "$OUT_DIR/$img" ] || continue
    printf 'image     : %s\n' "$OUT_DIR/$img"
    printf 'size      : %s MiB, %s MiB on the Mac disk (sparse)\n' \
        "$(sed -n 's/^size:  *//p' "$OUT_DIR/$(basename "$img" .img).MANIFEST" | awk '{print $1}')" \
        "$(( $(du -k "$OUT_DIR/$img" | cut -f1) / 1024 ))"
    printf 'sha256    : %s\n' "$(cut -d' ' -f1 "$OUT_DIR/$img.sha256")"
done
printf 'initramfs : %s (%s)\n' "$OUT_DIR/initramfs/initramfs-aarch64.cpio.gz" "$(cut -c1-64 "$OUT_DIR/initramfs/SHA256SUMS" 2>/dev/null || true)"
printf 'audit     : %s\n' "$OUT_DIR/package-audit.tsv"
printf 'wall time  : %d min %02d s\n' "$(( ($(date +%s) - BUILD_START) / 60 ))" "$(( ($(date +%s) - BUILD_START) % 60 ))"
printf '%s\n' "-------------------------------------------------------------"
