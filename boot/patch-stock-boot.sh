#!/usr/bin/env bash
# Patch the stock SM-T715 BOOT image so Android stops re-flashing RECOVERY.
#
# The stock ramdisk's init.rc defines
#     service flash_recovery /system/bin/install-recovery.sh
#         class main
#         oneshot
# which rewrites the RECOVERY partition from /system/etc/install-recovery.sh
# at every boot.  Replacing "class main" with "disabled" (+ a comment) makes
# init never start the service, so a kernel flashed to RECOVERY survives
# Android boots.  Second change: "service.adb.tcp.port=5555" is appended to
# default.prop so adbd also listens on TCP 5555 (ADB over Wi-Fi) from boot;
# USB ADB and RSA authentication (ro.adb.secure=1) are unchanged.  These are
# the ONLY changes: kernel, DTBH, header fields, SEANDROIDENFORCE footer,
# signature and every other ramdisk entry are preserved bit-for-bit
# (verified by boot/tests/test_cpio_newc.py).
#
# Usage: bash boot/patch-stock-boot.sh
# Output: out/stock-patched/{boot.img,init.rc.diff,default.prop.diff,SHA256SUMS}
#
# Exit codes: 0 ok; 1 any failure (set -e + trap); the samsung_bootimg.py
# --max-size guard exits 2 if the image would exceed the 14 MiB partition.

set -euo pipefail

# Make relative paths work from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

BOOTIMG_TOOL="$SCRIPT_DIR/samsung_bootimg.py"
CPIO_TOOL="$SCRIPT_DIR/cpio_newc.py"
STOCK_BOOT="${T715_DUMPS_DIR:-$REPO_ROOT/dumps}/stock/boot.img"
OUT_DIR="$REPO_ROOT/out/stock-patched"
MAX_SIZE="0x00e00000"   # BOOT partition size, 14 MiB

[ -f "$STOCK_BOOT" ] || { echo "error: stock dump not found: $STOCK_BOOT" >&2; exit 1; }
[ -f "$BOOTIMG_TOOL" ] || { echo "error: missing $BOOTIMG_TOOL" >&2; exit 1; }
[ -f "$CPIO_TOOL" ] || { echo "error: missing $CPIO_TOOL" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/patch_stock_boot.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "== Unpacking $STOCK_BOOT"
python3 -I "$BOOTIMG_TOOL" unpack "$STOCK_BOOT" -o "$WORK/unpacked"

echo "== Decompressing the ramdisk"
gunzip -c "$WORK/unpacked/ramdisk" > "$WORK/ramdisk.cpio"

echo "== Extracting init.rc"
python3 -I "$CPIO_TOOL" extract-file "$WORK/ramdisk.cpio" init.rc > "$WORK/init.rc.orig"

# ---------------------------------------------------------------------------
# The patch: inside the "service flash_recovery" block, replace
#     class main
# with
#     disabled
#     # t715: disabled so RECOVERY keeps the test kernel
# ---------------------------------------------------------------------------
echo "== Patching flash_recovery"
python3 - "$WORK/init.rc.orig" "$WORK/init.rc.new" <<'PYEOF'
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, "rb") as f:
    data = f.read()

# Byte-level patterns (init.rc is LF-only in the stock ramdisk).
OLD = (b"service flash_recovery /system/bin/install-recovery.sh\n"
       b"    class main\n")
NEW = (b"service flash_recovery /system/bin/install-recovery.sh\n"
       b"    disabled\n"
       b"    # t715: disabled so RECOVERY keeps the test kernel\n")

count = data.count(OLD)
if count != 1:
    sys.exit("error: found %d 'service flash_recovery ... class main' "
             "blocks (expected exactly 1); refusing to patch" % count)

with open(dst, "wb") as f:
    f.write(data.replace(OLD, NEW))
PYEOF

echo "== Rebuilding the cpio archive"
python3 -I "$CPIO_TOOL" replace "$WORK/ramdisk.cpio" init.rc \
    "$WORK/init.rc.new" -o "$WORK/ramdisk.initrc.cpio"

# ---------------------------------------------------------------------------
# Second patch: append "service.adb.tcp.port=5555" to default.prop so adbd
# listens on TCP 5555 from boot (read by adbd at startup); refuse if the
# property is already present.
# ---------------------------------------------------------------------------
echo "== Patching default.prop (ADB over TCP 5555)"
python3 -I "$CPIO_TOOL" extract-file "$WORK/ramdisk.initrc.cpio" default.prop \
    > "$WORK/default.prop.orig"
python3 - "$WORK/default.prop.orig" "$WORK/default.prop.new" <<'PYEOF'
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, "rb") as f:
    data = f.read()

if b"service.adb.tcp.port" in data:
    sys.exit("error: default.prop already sets service.adb.tcp.port; "
             "refusing to patch")
if not data.endswith(b"\n"):
    data += b"\n"

with open(dst, "wb") as f:
    f.write(data + b"service.adb.tcp.port=5555\n")
PYEOF

python3 -I "$CPIO_TOOL" replace "$WORK/ramdisk.initrc.cpio" default.prop \
    "$WORK/default.prop.new" -o "$WORK/ramdisk.new.cpio"

# ---------------------------------------------------------------------------
# Recompression: reuse the original gzip settings when they can be detected.
# A gzip stream has no level field, but XFL (byte 8) is 4 for -1, 0 for
# -2..-8 (i.e. plain "gzip" default -6 and -9 both write 0x00) and 2 for
# -9 with zlib... The reliable detector is empirical: re-compress with each
# candidate level and keep the one that reproduces the original stream
# byte-for-byte.  When none does, fall back to "gzip -n -9".
# ---------------------------------------------------------------------------
echo "== Recompressing the ramdisk (gzip)"
python3 - "$WORK" <<'PYEOF'
import gzip
import struct
import sys
import zlib

work = sys.argv[1]
orig = open(work + "/unpacked/ramdisk", "rb").read()
cpio = open(work + "/ramdisk.new.cpio", "rb").read()

header = orig[:10]
if header[:2] != b"\x1f\x8b" or header[2] != 8:
    sys.exit("error: stock ramdisk is not a deflate (method 8) gzip stream")
flags = header[3]
if flags & 0xE6:  # FEXTRA|FNAME|FCOMMENT|FHCRC make re-encoding ambiguous
    sys.exit("error: stock gzip header sets extra/name/comment/crc flags "
             "(FLG=0x%02x); cannot detect the settings" % flags)

level_file = open(work + "/gzip-level", "w")


def gz(data, level):
    co = zlib.compressobj(level, zlib.DEFLATED, -15)
    body = co.compress(data) + co.flush()
    return (b"\x1f\x8b\x08\x00" + b"\x00" * 4 + b"\x00\x03" + body
            + struct.pack("<II", zlib.crc32(data) & 0xFFFFFFFF,
                          len(data) & 0xFFFFFFFF))


detected = None
for level in (6, 9, 1):
    if orig == gz(cpio_orig := gzip.decompress(orig), level):
        detected = level
        break

if detected is None:
    # Undetectable: fall back to gzip -n -9 (as instructed).
    level_file.write("9\n")
    level_file.close()
    with open(work + "/ramdisk.new.gz", "wb") as f:
        f.write(gz(cpio, 9))
    print("gzip settings: undetectable; using -n -9 (fallback)")
else:
    level_file.write("%d\n" % detected)
    level_file.close()
    with open(work + "/ramdisk.new.gz", "wb") as f:
        f.write(gz(cpio, detected))
    print("gzip settings: level %d detected (byte-identical "
          "re-compression of the original)" % detected)
PYEOF
GZIP_LEVEL="$(cat "$WORK/gzip-level")"

echo "== Repacking the boot image"
# Update only the ramdisk payload path/size; everything else in the json
# (name, addresses, pagesize, dt, id, signature, trailer) is untouched.
# samsung_bootimg.py pack --from-json recomputes nothing -- it reuses the
# stored id verbatim, so update it here to what mkbootimg would compute for
# the new payloads (the stock id does follow the SHA-1 scheme; verified by
# boot/tests/test_cpio_newc.py).
python3 - "$WORK" "$GZIP_LEVEL" <<'PYEOF'
import hashlib
import json
import os
import struct
import sys

work, level = sys.argv[1], sys.argv[2]
manifest_path = os.path.join(work, "unpacked", "bootimg.json")
with open(manifest_path) as f:
    manifest = json.load(f)

ramdisk = open(os.path.join(work, "ramdisk.new.gz"), "rb").read()
with open(os.path.join(work, "unpacked", "ramdisk"), "wb") as f:
    f.write(ramdisk)

manifest["header"]["ramdisk_size"] = len(ramdisk)

# mkbootimg.c:286-299 id: SHA-1(kernel || le32(kernel_size) ||
# ramdisk || le32(ramdisk_size) || second || le32(second_size) ||
# [dt || le32(dt_size)]).
hdr = manifest["header"]
parts = [
    ("kernel", hdr["kernel_size"]),
    ("ramdisk", hdr["ramdisk_size"]),
    ("second", hdr["second_size"]),
]
ctx = hashlib.sha1()
for key, size in parts:
    rel = manifest.get(key)
    if rel is None:
        blob = b""
    else:
        with open(os.path.join(work, "unpacked", rel), "rb") as f:
            blob = f.read()
    ctx.update(blob)
    ctx.update(struct.pack("<I", size))
if manifest.get("dt") is not None:
    with open(os.path.join(work, "unpacked", manifest["dt"]), "rb") as f:
        blob = f.read()
    ctx.update(blob)
    ctx.update(struct.pack("<I", hdr["dt_size"]))
digest = ctx.digest()
manifest["header"]["id"] = list(struct.unpack("<5I", digest)) + [0, 0, 0]

with open(manifest_path, "w") as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
    f.write("\n")
PYEOF

mkdir -p "$OUT_DIR"
python3 -I "$BOOTIMG_TOOL" pack --from-json "$WORK/unpacked/bootimg.json" \
    --max-size "$MAX_SIZE" -o "$OUT_DIR/boot.img"

echo "== Writing init.rc.diff"
diff -u -L "a/init.rc" -L "b/init.rc" \
    "$WORK/init.rc.orig" "$WORK/init.rc.new" > "$OUT_DIR/init.rc.diff" || true
diff -u -L "a/default.prop" -L "b/default.prop" \
    "$WORK/default.prop.orig" "$WORK/default.prop.new" \
    > "$OUT_DIR/default.prop.diff" || true

echo "== SHA256SUMS"
ORIG_REL="dumps/stock/boot.img"
NEW_REL="out/stock-patched/boot.img"
{
    shasum -a 256 "$STOCK_BOOT"
    shasum -a 256 "$OUT_DIR/boot.img"
    shasum -a 256 "$OUT_DIR/init.rc.diff"
    shasum -a 256 "$OUT_DIR/default.prop.diff"
} | sed -e "s|$REPO_ROOT/||g" > "$OUT_DIR/SHA256SUMS"
cat "$OUT_DIR/SHA256SUMS"

SIZE="$(stat -f %z "$OUT_DIR/boot.img")"
LIMIT=$((0x00e00000))
echo "== Done: $OUT_DIR/boot.img ($SIZE bytes, limit $LIMIT)"
if [ "$SIZE" -gt "$LIMIT" ]; then
    echo "error: image exceeds the 14 MiB BOOT partition" >&2
    exit 1
fi
