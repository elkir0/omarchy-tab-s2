#!/usr/bin/env bash
# Pack a mainline test kernel into a RECOVERY image for the SM-T715.
#
# The image keeps the header layout of the official TWRP recovery (same
# load addresses, page size, DTBH codes, SEANDROIDENFORCE footer), which
# sboot is known to boot from RECOVERY.  By default the ramdisk is a
# minimal cpio (/dev/console only): with no /init the kernel panics, and
# panic=5 reboots the board back to Android, where /proc/last_kmsg holds
# the log.  --initramfs packs a real one instead (e.g. the output of
# boot/build-initramfs.sh, which boots Arch from USERDATA).
#
# Usage: bash boot/pack-test-recovery.sh [--initramfs PATH] [--out DIR]
#                                           [--boot] [BUILD_DIR] [DTB_NAME]
#   BUILD_DIR       kernel build output (default out/mainline)
#   DTB_NAME        board dtb in BUILD_DIR (default exynos5433-gts28ltexx.dtb)
#   --initramfs P   gzip-compressed newc cpio to use as the ramdisk
#                   (e.g. out/initramfs/initramfs.cpio.gz);
#                   default: the empty cpio above
#   --out DIR       output directory (default out/test-recovery)
#   --boot          an image for BOOT instead (tablets without Android):
#                   the stock boot image's board name SYSMAGIC000KU, the
#                   14 MiB limit of mmcblk0p9, DIR/boot.img
#   --cmdline STR   the boot header's command line (default empty); sboot
#                   puts it before CONFIG_CMDLINE, so a word there loses
#                   to the same word in CONFIG_CMDLINE (e.g. loglevel=)
# Output: DIR/recovery.img or DIR/boot.img (+ SHA256SUMS)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/out/test-recovery"
INITRAMFS=""
BOOT=0
CMDLINE=
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --initramfs) [ $# -ge 2 ] || { echo "error: --initramfs needs a path" >&2; exit 2; }
                 INITRAMFS="$2"; shift 2 ;;
    --initramfs=*) INITRAMFS="${1#--initramfs=}"; shift ;;
    --out) [ $# -ge 2 ] || { echo "error: --out needs a directory" >&2; exit 2; }
           OUT="$2"; shift 2 ;;
    --out=*) OUT="${1#--out=}"; shift ;;
    --boot) BOOT=1; shift ;;
    --cmdline) [ $# -ge 2 ] || { echo "error: --cmdline needs a value" >&2; exit 2; }
               CMDLINE="$2"; shift 2 ;;
    --cmdline=*) CMDLINE="${1#--cmdline=}"; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    --) shift; POSITIONAL+=("$@"); break ;;
    -*) echo "error: unknown option: $1" >&2; exit 2 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
[ ${#POSITIONAL[@]} -le 2 ] || { echo "error: too many arguments" >&2; exit 2; }
BUILD="${POSITIONAL[0]:-$ROOT/out/mainline}"
DTB_NAME="${POSITIONAL[1]:-exynos5433-gts28ltexx.dtb}"
if [ -n "$INITRAMFS" ]; then
  [ -f "$INITRAMFS" ] || { echo "error: missing $INITRAMFS" >&2; exit 1; }
  gzip -t "$INITRAMFS" 2>/dev/null \
    || { echo "error: $INITRAMFS is not a valid gzip stream" >&2; exit 1; }
  [ "$(gzip -dc "$INITRAMFS" | head -c 6)" = "070701" ] \
    || { echo "error: $INITRAMFS does not hold a newc (070701) cpio" >&2; exit 1; }
  INITRAMFS="$(cd "$(dirname "$INITRAMFS")" && pwd)/$(basename "$INITRAMFS")"
fi
TOOL="$ROOT/boot/samsung_bootimg.py"
RECOVERY_SIZE=0x1000000   # mmcblk0p10, 16384 KiB (dumps/partitions.txt)
BOOT_SIZE=0xe00000        # mmcblk0p9, 14336 KiB (dumps/partitions.txt)
if [ "$BOOT" = 1 ]; then
  BOARD=SYSMAGIC000KU MAX_SIZE=$BOOT_SIZE IMG=boot.img       # as dumps/stock/boot.img
else
  BOARD=SYSMAGIC000RU MAX_SIZE=$RECOVERY_SIZE IMG=recovery.img  # as the official TWRP
fi
# Empty by default, like the stock boot image: our parameters come from
# CONFIG_CMDLINE (appended after sboot's ~850-byte line), and anything
# added here eats into the 1024-byte COMMAND_LINE_SIZE before them.

for f in "$BUILD/zImage" "$BUILD/$DTB_NAME"; do
  [ -f "$f" ] || { echo "error: missing $f" >&2; exit 1; }
done
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pack_test_recovery.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# sboot rewrites /chosen and /memory in place: leave room in the blob.
dtc -q -I dtb -O dtb -p 8192 -o "$WORK/board.dtb" "$BUILD/$DTB_NAME"
for p in model_info-chip model_info-platform model_info-subtype \
         model_info-hw_rev model_info-hw_rev_end; do
  fdtget "$WORK/board.dtb" / "$p" >/dev/null 2>&1 || {
    echo "error: $DTB_NAME lacks /$p (needed for the DTBH entry)" >&2; exit 1; }
done
python3 -I "$TOOL" dtbh-pack -o "$WORK/dt.img" --dtb "9:255=$WORK/board.dtb"

if [ -n "$INITRAMFS" ]; then
  cp "$INITRAMFS" "$WORK/ramdisk.gz"
  echo "ramdisk: $INITRAMFS ($(wc -c <"$WORK/ramdisk.gz" | tr -d ' ') bytes)"
else
python3 -I - "$WORK/ramdisk.cpio" <<'PY'
import sys

def entry(name, mode, rdevmajor=0, rdevminor=0, ino=1):
    name = name.encode() + b"\0"
    hdr = b"070701" + b"".join(b"%08x" % v for v in (
        ino, mode, 0, 0, 1, 0, 0, 0, 0, rdevmajor, rdevminor, len(name), 0))
    blob = hdr + name
    return blob + b"\0" * (-len(blob) % 4)

data = (entry("dev", 0o040755, ino=1)
        + entry("dev/console", 0o020600, 5, 1, ino=2)
        + entry("TRAILER!!!", 0, ino=0))
open(sys.argv[1], "wb").write(data + b"\0" * (-len(data) % 512))
PY
gzip -n -9 -c "$WORK/ramdisk.cpio" > "$WORK/ramdisk.gz"
fi

python3 -I "$TOOL" pack \
  --kernel "$BUILD/zImage" --ramdisk "$WORK/ramdisk.gz" --dt "$WORK/dt.img" \
  --board "$BOARD" --cmdline "$CMDLINE" \
  --base 0x10000000 --kernel-offset 0x00008000 --ramdisk-offset 0x01000000 \
  --second-offset 0x00f00000 --tags-offset 0x00000100 --pagesize 2048 \
  --seandroid --max-size "$MAX_SIZE" -o "$OUT/$IMG"

python3 -I "$TOOL" info "$OUT/$IMG" | grep -E "name|cmdline|_size|_addr"
SUMS=("${OUT#"$ROOT"/}/$IMG" "${BUILD#"$ROOT"/}/zImage" "${BUILD#"$ROOT"/}/$DTB_NAME")
[ -z "$INITRAMFS" ] || SUMS+=("${INITRAMFS#"$ROOT"/}")
( cd "$ROOT" && shasum -a 256 "${SUMS[@]}" ) > "$OUT/SHA256SUMS"
cat "$OUT/SHA256SUMS"
