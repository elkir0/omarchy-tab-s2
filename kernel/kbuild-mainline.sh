#!/usr/bin/env bash
# Build the 32-bit (ARMv7/LPAE) mainline Linux 6.12 kernel and board DTBs
# for the Samsung Galaxy Tab S2 8.0 LTE (SM-T715, Exynos5433) in Docker,
# then copy the artifacts into out/mainline/ (default) or
# out/mainline-<fragment>/ (--fragment NAME).
#
# The kernel tree (src/linux-6.12) is bind-mounted into the
# container at /src and built out-of-tree (O=/build) into a Docker named
# volume, so the kernel tree only receives the files git tracks (source
# edits stay uncommitted) and incremental rebuilds are fast.
#
# Usage:
#   kernel/kbuild-mainline.sh [--clean] [--arm64-only] [--fragment NAME] [-j N]
#
#   --clean       remove the build volume and rebuild from scratch
#   --arm64-only  run only the ARM64 non-regression phase
#   --fragment NAME  merge arch/arm/configs/NAME on top of the defconfig
#                 (e.g. gts28ltexx_m4.config) and build into its own
#                 Docker volume (t715-kbuild-out-<NAME minus .config>)
#                 and output dir (out/mainline-<NAME minus the
#                 board prefix and .config>, e.g. mainline-m2), so a
#                 fragment build can run concurrently with the default
#                 build.  Default build remains unchanged.
#   -j N          parallel jobs (default: nproc)
#
# Environment overrides (throw-away builds; do not disturb a concurrent
# default build on the t715-kbuild-out volume):
#   KBUILD_VOLUME   build volume name (default: t715-kbuild-out)
#   KBUILD_OUT_DIR  output directory (default: out/mainline)
#   T715_KERNEL_DIR the kernel tree (default: src/linux-6.12)
#   KBUILD_ARM64_VOLUME  ARM64 check volume (default: t715-kbuild-arm64-out)
#   KBUILD_SKIP_ARM64=1  skip the ARM64 non-regression phase
# KBUILD_VOLUME and KBUILD_OUT_DIR also win over the --fragment defaults, so
# two trees can build the same fragment at the same time.
#
# Boot partition budget (from the stock device): 14 MiB total shared by
# kernel + initramfs + DTB container.  The script fails if zImage
# exceeds 9 MiB, leaving ~5 MiB for the initramfs and the DTB.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# src/ may be a mount point or a link to the case-sensitive volume; Docker
# gets the resolved path.
SOURCE_DIR="${T715_KERNEL_DIR:-${REPO_ROOT}/src/linux-6.12}"
[[ -d "$SOURCE_DIR" ]] && SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd -P)"
IMAGE_TAG="t715-kbuild"
ARM64_VOLUME="${KBUILD_ARM64_VOLUME:-t715-kbuild-arm64-out}"
DEFCONFIG_NAME="gts28ltexx_defconfig"
ZIMAGE_MAX_BYTES=$((9 * 1024 * 1024))

# Host-portable CPU count: GNU/Linux nproc, macOS sysctl, POSIX getconf.
if command -v nproc >/dev/null 2>&1; then
    JOBS="$(nproc)"
elif command -v sysctl >/dev/null 2>&1; then
    JOBS="$(sysctl -n hw.ncpu)"
else
    JOBS="$(getconf _NPROCESSORS_ONLN)"
fi
CLEAN=0
ARM64_ONLY=0
FRAGMENT=""
FRAGMENT_NAME=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean) CLEAN=1; shift ;;
        --arm64-only) ARM64_ONLY=1; shift ;;
        --fragment)
            [[ $# -ge 2 ]] || { echo "error: --fragment needs a value" >&2; exit 2; }
            FRAGMENT="$2"; shift 2 ;;
        --fragment=*) FRAGMENT="${1#--fragment=}"; shift ;;
        -j)
            [[ $# -ge 2 ]] || { echo "error: -j needs a value" >&2; exit 2; }
            JOBS="$2"; shift 2 ;;
        -j*) JOBS="${1#-j}"; shift ;;
        -h|--help)
            sed -n '2,32p' "$0"; exit 0 ;;
        *)
            echo "error: unknown option: $1" >&2; sed -n '2,32p' "$0" >&2; exit 2 ;;
        esac
done

# --- build volume / output dir ----------------------------------------------
# A fragment build must never share the default build's volume or output
# directory: another worker may be running the default build in parallel.
VOLUME="${KBUILD_VOLUME:-t715-kbuild-out}"
OUT_DIR="${KBUILD_OUT_DIR:-${REPO_ROOT}/out/mainline}"
if [[ -n "$FRAGMENT" ]]; then
    FRAGMENT_NAME="$(basename "$FRAGMENT")"
    FRAGMENT_SUFFIX="${FRAGMENT_NAME%.config}"   # gts28ltexx_m4.config -> gts28ltexx_m4
    [[ -f "$SOURCE_DIR/arch/arm/configs/$FRAGMENT_NAME" ]] || {
        echo "error: fragment arch/arm/configs/$FRAGMENT_NAME not found" >&2
        exit 2
    }
    VOLUME="${KBUILD_VOLUME:-t715-kbuild-out-$FRAGMENT_SUFFIX}"
    # Output dir drops the board prefix so gts28ltexx_m4.config builds
    # into out/mainline-m4, not mainline-gts28ltexx_m4.
    BOARD_NAME="${DEFCONFIG_NAME%_defconfig}"        # gts28ltexx_defconfig -> gts28ltexx
    OUT_SUFFIX="${FRAGMENT_SUFFIX#"$BOARD_NAME"_}"   # gts28ltexx_m4 -> m4
    [[ -n "$OUT_SUFFIX" ]] || OUT_SUFFIX="$FRAGMENT_SUFFIX"
    OUT_DIR="${KBUILD_OUT_DIR:-${REPO_ROOT}/out/mainline-$OUT_SUFFIX}"
fi

# --- docker image -----------------------------------------------------------
if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    echo ">>> Docker image $IMAGE_TAG not found; building it"
    docker build --platform linux/arm64 \
        -f "$REPO_ROOT/kernel/docker/kbuild.Dockerfile" \
        -t "$IMAGE_TAG" "$REPO_ROOT/kernel/docker"
fi

# --- arm32 build ------------------------------------------------------------
# shellcheck disable=SC2016
run_make() {
    docker run --rm \
        --platform linux/arm64 \
        -v "$SOURCE_DIR:/src" \
        -v "$VOLUME:/build" \
        -w /src \
        "$IMAGE_TAG" \
        make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- O=/build "$@"
}

arm32_build() {
    if [[ $CLEAN -eq 1 ]]; then
        echo ">>> --clean: removing build volume $VOLUME"
        docker volume rm -f "$VOLUME" >/dev/null
    fi
    docker volume create "$VOLUME" >/dev/null
    mkdir -p "$OUT_DIR"

    echo ">>> [arm32] Configuring ($DEFCONFIG_NAME${FRAGMENT_NAME:+ + $FRAGMENT_NAME})"
    run_make "$DEFCONFIG_NAME"
    if [[ -n "$FRAGMENT_NAME" ]]; then
        # make merges the fragment on top of the defconfig config
        run_make "$FRAGMENT_NAME"
    fi
    run_make -j"$JOBS" olddefconfig

    echo ">>> [arm32] Building zImage + gts28ltexx DTBs + modules (-j$JOBS)"
    run_make -j"$JOBS" zImage dtbs modules
    # The volume persists between builds: drop module trees left by earlier
    # kernel releases, or modules.tar.xz carries several lib/modules/<release>.
    docker run --rm --platform linux/arm64 -v "$VOLUME:/build" \
        "$IMAGE_TAG" bash -ec "rm -rf /build/mod-install"
    run_make -j"$JOBS" INSTALL_MOD_PATH=/build/mod-install modules_install

    echo ">>> [arm32] Packaging modules.tar.xz"
    docker run --rm --platform linux/arm64 -v "$VOLUME:/build" \
        "$IMAGE_TAG" \
        bash -ec "tar -C /build/mod-install -cJf /build/modules.tar.xz ."

    echo ">>> [arm32] Copying artifacts to $OUT_DIR"
    docker run --rm --platform linux/arm64 \
        -v "$VOLUME:/build" -v "$OUT_DIR:/out" \
        "$IMAGE_TAG" \
        bash -ec "cp -f /build/arch/arm/boot/zImage \
                        /build/arch/arm/boot/dts/samsung/exynos5433-gts28ltexx*.dtb \
                        /build/.config \
                        /build/System.map \
                        /build/modules.tar.xz /out/"

    # --- size check (runs on the host; macOS/BSD stat has -f) ---------------
    zimage_bytes=$(stat -f %z "$OUT_DIR/zImage")
    dtb_bytes=0
    for dtb in "$OUT_DIR"/exynos5433-gts28ltexx*.dtb; do
        dtb_bytes=$((dtb_bytes + $(stat -f %z "$dtb")))
    done
    total=$((zimage_bytes + dtb_bytes))
    budget=$((14 * 1048576))
    echo ">>> [arm32] zImage: $zimage_bytes bytes, DTBs: $dtb_bytes bytes total"
    echo ">>> [arm32] kernel+DTBs use $((total / 1024)) KiB of the $((budget / 1024)) KiB boot budget; $(((budget - total) / 1024)) KiB left for initramfs"
    if (( zimage_bytes > ZIMAGE_MAX_BYTES )); then
        echo "ERROR: zImage is $zimage_bytes bytes > 9 MiB budget ($ZIMAGE_MAX_BYTES)" >&2
        exit 1
    fi
}

# --- arm64 non-regression (requirement: no regression for ARM64 builds) -----
arm64_check() {
    echo ">>> [arm64] Non-regression: defconfig + exynos clk/pinctrl + tm2 DTB"
    docker volume create "$ARM64_VOLUME" >/dev/null
    # The .dtb goal must be relative to arch/arm64/boot/dts: the stock
    # top-level "%.dtb" rule re-dispatches the goal as $(dtstree)/$@, so a
    # full-path goal would come out as arch/arm64/boot/dts/arch/... and
    # fail with "No rule to make target".
    # shellcheck disable=SC2016
    if ! docker run --rm --platform linux/arm64 \
        -v "$SOURCE_DIR:/src" -v "$ARM64_VOLUME:/build-arm64" -w /src \
        "$IMAGE_TAG" \
        bash -ec '
            set -e
            make ARCH=arm64 O=/build-arm64 defconfig
            make -j'"$JOBS"' ARCH=arm64 O=/build-arm64 \
                drivers/clk/samsung/ drivers/pinctrl/samsung/ \
                exynos/exynos5433-tm2.dtb
            test -f /build-arm64/arch/arm64/boot/dts/exynos/exynos5433-tm2.dtb
        '; then
        docker volume rm -f "$ARM64_VOLUME" >/dev/null 2>&1 || true
        echo "ERROR: ARM64 non-regression build failed" >&2
        exit 1
    fi
    docker volume rm -f "$ARM64_VOLUME" >/dev/null
    echo ">>> [arm64] Non-regression OK"
}

if [[ $ARM64_ONLY -eq 1 ]]; then
    arm64_check
    exit 0
fi

arm32_build
[[ "${KBUILD_SKIP_ARM64:-0}" == 1 ]] || arm64_check

exit 0
