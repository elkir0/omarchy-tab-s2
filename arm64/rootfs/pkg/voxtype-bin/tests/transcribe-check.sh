#!/usr/bin/env bash
# transcribe-check.sh — real end-to-end transcription test for the built
# voxtype-bin package.
#
# Usage: QEMU_CPU=cortex-a57 tests/transcribe-check.sh <extracted-package-root>
#
# Given the extracted package root as $1, this script:
#   1. downloads whisper.cpp's sample jfk.wav and the multilingual Whisper
#      `tiny` ggml model, refusing to run on any sha256 mismatch;
#   2. runs `voxtype transcribe jfk.wav` through the package's own voxtype
#      binary under `qemu-aarch64 -cpu "$QEMU_CPU" -L "$1"` (ARMv8.0-A: no
#      microphone, no daemon, no display needed — a temp HOME plus a config
#      file pointing at the downloaded model is enough);
#   3. fails unless the transcript contains "ask not what your country can
#      do" (case-insensitive).
set -euo pipefail

ROOT="${1:?usage: QEMU_CPU=cortex-a57 $0 <extracted-package-root>}"
QEMU_CPU="${QEMU_CPU:-cortex-a57}"

command -v qemu-aarch64 >/dev/null || { echo "FAIL: qemu-aarch64 not found"; exit 1; }
[ -d "$ROOT/usr" ] || { echo "FAIL: $ROOT is not an extracted package root"; exit 1; }

# Pinned downloads (sha256; any mismatch aborts the test).
JFK_URL="https://github.com/ggerganov/whisper.cpp/raw/master/samples/jfk.wav"
JFK_SHA256="59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin"
MODEL_SHA256="be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

download() { # download <url> <dest> <sha256>
    local url="$1" dest="$2" sha="$3"
    echo "downloading $url"
    curl -fL --retry 3 --connect-timeout 30 -o "$dest" "$url"
    echo "$sha  $dest" | sha256sum -c - >/dev/null \
        || { echo "FAIL: sha256 mismatch for $url"; exit 1; }
}

download "$JFK_URL" "$WORK/jfk.wav" "$JFK_SHA256"
download "$MODEL_URL" "$WORK/ggml-tiny.bin" "$MODEL_SHA256"

# The package's voxtype binary: /usr/bin/voxtype, following its symlink
# inside the package root (qemu needs a real file, and the symlink target is
# absolute, so re-anchor it under $ROOT).
VOXTYPE="$ROOT/usr/bin/voxtype"
if [ -L "$VOXTYPE" ]; then
    target="$(readlink "$VOXTYPE")"
    case "$target" in
        /*) VOXTYPE="$ROOT$target" ;;
        *)  VOXTYPE="$(dirname "$VOXTYPE")/$target" ;;
    esac
fi
[ -f "$VOXTYPE" ] || { echo "FAIL: no voxtype binary at $ROOT/usr/bin/voxtype"; exit 1; }
echo "voxtype binary: $VOXTYPE"

# Isolated HOME + config pointing the whisper engine at the pinned model.
mkdir -p "$WORK/home/.config/voxtype" "$WORK/run"
chmod 700 "$WORK/run"
cat >"$WORK/config.toml" <<EOF
[whisper]
model = "$WORK/ggml-tiny.bin"
language = "en"
threads = 4

[vad]
enabled = false
EOF

echo "transcribing jfk.wav under qemu-aarch64 -cpu $QEMU_CPU (this can take a while)"
set +e
timeout 1800 env HOME="$WORK/home" XDG_RUNTIME_DIR="$WORK/run" \
    qemu-aarch64 -cpu "$QEMU_CPU" -L "$ROOT" \
    "$VOXTYPE" --config "$WORK/config.toml" transcribe "$WORK/jfk.wav" \
    >"$WORK/stdout.txt" 2>"$WORK/stderr.txt"
rc=$?
set -e

cat "$WORK/stdout.txt"
[ "$rc" -eq 0 ] || {
    echo "FAIL: voxtype transcribe exited with $rc; stderr:"
    tail -30 "$WORK/stderr.txt"
    exit 1
}

if grep -qi 'ask not what your country can do' "$WORK/stdout.txt"; then
    echo "PASS: transcript contains \"ask not what your country can do\""
else
    echo "FAIL: transcript does not contain \"ask not what your country can do\""
    exit 1
fi
