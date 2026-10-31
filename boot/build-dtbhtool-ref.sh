#!/usr/bin/env bash
# Build the LineageOS dtbhtool C reference binaries (mkbootimg, mkdtbimg,
# unpackbootimg, unpackdtbhimg) from the read-only sources in
# src/hardware_samsung-18.1/dtbhtool inside debian:trixie (arm64) and
# drop them into out/tools/.
#
# Usage: bash boot/build-dtbhtool-ref.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$REPO_ROOT/src/hardware_samsung-18.1/dtbhtool"
OUT_DIR="$REPO_ROOT/out/tools"
IMAGE_NAME="dtbhtool-ref"
DOCKERFILE="$REPO_ROOT/boot/docker/dtbhtool-ref.Dockerfile"

if ! command -v docker >/dev/null 2>&1; then
    echo "error: docker is required to build the C reference tools" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

# The build context is boot/docker (it carries the samsung_dtbh.h shim);
# the C sources themselves are mounted read-only at run time so nothing under
# src/ can be modified.
docker build --platform linux/arm64 \
    -f "$DOCKERFILE" \
    -t "$IMAGE_NAME" \
    "$REPO_ROOT/boot/docker"

docker run --rm --platform linux/arm64 \
    -v "$SRC_DIR:/src:ro" \
    -v "$OUT_DIR:/out" \
    "$IMAGE_NAME"

echo
echo "Reference tools in $OUT_DIR:"
ls -l "$OUT_DIR"
