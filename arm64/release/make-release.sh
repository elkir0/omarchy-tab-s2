#!/usr/bin/env bash
# make-release.sh — the release of the 64-bit system for the Galaxy Tab S2 8.0 LTE (SM-T715): what
# a user downloads to go from a stock tablet to Omarchy in 64 bits, with no computer work but a
# copy and a flash (docs/INSTALL-ARM64.md).
#
# Usage:
#   arm64/release/make-release.sh --version V --image IMG --kernel-dir DIR --out DIR
#                                 [--dtb NAME] [--installer-kernel DIR] [--xz-level N] [--no-xz]
#                                 [--installer-knobs "t715.x=y ..."]
#   arm64/release/make-release.sh --version V --image-from DIR --out DIR [...]
#
#   --version V          the release's version (2.0.0): names the directory and the Odin package,
#                        and must be boot/golden/release
#   --image IMG          the root image from arm64/rootfs/build.sh (out/rootfs-aarch64-omarchy45.img);
#                        never changed: the release works on a copy
#   --kernel-dir DIR     the arm64 kernel's build (elkir0/bnuuyloader, t715/build-arm64.sh:
#                        kernel-out/): Image, modules.tar.xz and the device tree with the daily boot
#                        arguments (bootargs-daily.dts applied)
#   --dtb NAME           that device tree's file name in DIR (default gts28ltexx-daily.dtb)
#   --installer-kernel DIR  the 32-bit kernel the installer runs on (default out/mainline-v105, the
#                        1.0.5 release's: zImage, exynos5433-gts28ltexx.dtb)
#   --out DIR            where DIR/omarchy-tab-s2-V is made (refused if it exists)
#   --xz-level N         xz level for the image (default 6); --no-xz keeps only the raw image
#   --installer-knobs S  knobs added to the installer's (tests only: t715.telnet=1 t715.usbfn=ecm);
#                        a release with them says so in its MANIFEST
#   --image-from DIR     take omarchy-arm64.img, its .sha256 and its .xz from an earlier release
#                        directory as they are (the image a test installed on the tablet), and make
#                        only the installer and the sums again; --image and --kernel-dir are not used
#
# The release directory holds:
#   omarchy-arm64.img.xz         the root image, with the kernel's modules and the kernel's slot
#                                (usr/lib/t715-golden/kernel.slot, generation 0; the installer gives
#                                it its generation); unpacked, omarchy-arm64.img
#   omarchy-arm64.img.sha256     its sidecar: the installer refuses an image without it
#   boot.img, recovery.img       the installer (the 32-bit kernel and boot/initramfs/init built
#                                with --golden boot/golden): it is also the rescue afterwards
#   omarchy-tab-s2-V-AP.tar.md5  boot.img and recovery.img for Odin's AP slot (image/tools/pack-odin)
#   SHA256SUMS                   every file above, and the raw image
#   MANIFEST.txt                 what went in: versions, hashes, the image's own MANIFEST, the checks
#
# Checks on the image before anything is packed (each failure stops the script). The installer
# copies the image with busybox tar, which carries no extended attribute: the image's file
# capabilities are listed in usr/lib/t715-golden/file-capabilities and set again once at the first
# boot by t715-golden-caps.service, and any other attribute but the ACLs systemd-tmpfiles sets again
# is refused. Also: no SSH host key, an empty machine-id, no authorized_keys, no saved network, no
# top-level name with a blank, an aarch64 system, a clean e2fsck. Nothing private ever enters:
# inputs under dumps/ or sm-t715-private/ are refused.
#
# Runs in Docker on the Mac (a privileged helper container: the image is attached with losetup in a
# Docker volume, never on the macOS file system).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION="" IMAGE="" KDIR="" OUT="" DTB=gts28ltexx-daily.dtb IKERNEL="$ROOT/out/mainline-v105"
XZ_LEVEL=6 NO_XZ=0 IKNOBS="" IMAGE_FROM=""
HELPER=t715-golden-release:1
BASE_IMAGE="debian@sha256:8c4733a92aacd0bcff3779eadc35a4a5147f36cb20a5fcb56504cbc740212259"
VOL=t715-golden-release-work

die() { echo "make-release: $*" >&2; exit 1; }
say() { echo ">>> $*"; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --kernel-dir) KDIR="$2"; shift 2 ;;
    --dtb) DTB="$2"; shift 2 ;;
    --installer-kernel) IKERNEL="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --xz-level) XZ_LEVEL="$2"; shift 2 ;;
    --no-xz) NO_XZ=1; shift ;;
    --installer-knobs) IKNOBS="$2"; shift 2 ;;
    --image-from) IMAGE_FROM="$2"; shift 2 ;;
    -h|--help) sed -n '2,46p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?$ ]] || die "--version: a version like 2.0.0"
[[ "$(head -n 1 "$ROOT/boot/golden/release")" == "$VERSION" ]] || die "boot/golden/release says $(head -n 1 "$ROOT/boot/golden/release"), not $VERSION"
if [[ -n "$IMAGE_FROM" ]]; then
  for f in omarchy-arm64.img omarchy-arm64.img.sha256 MANIFEST.txt; do [[ -f "$IMAGE_FROM/$f" ]] || die "--image-from: no $f in $IMAGE_FROM"; done
  IMAGE_FROM="$(cd "$IMAGE_FROM" && pwd)"
  IMAGE="$IMAGE_FROM/omarchy-arm64.img"
  KDIR="$IMAGE_FROM"
else
  [[ -f "$IMAGE" ]] || die "--image: $IMAGE not found"
  for f in Image modules.tar.xz "$DTB"; do [[ -f "$KDIR/$f" ]] || die "--kernel-dir: no $f in $KDIR"; done
fi
for f in zImage exynos5433-gts28ltexx.dtb; do [[ -f "$IKERNEL/$f" ]] || die "--installer-kernel: no $f in $IKERNEL"; done
[[ "$XZ_LEVEL" =~ ^[0-9]$ ]] || die "--xz-level: 0 to 9"
[[ -n "$OUT" ]] || die "--out is required"
IMAGE="$(cd "$(dirname "$IMAGE")" && pwd)/$(basename "$IMAGE")"
KDIR="$(cd "$KDIR" && pwd)"
IKERNEL="$(cd "$IKERNEL" && pwd)"
for p in "$IMAGE" "$KDIR" "$IKERNEL"; do
  case "$p" in */dumps/* | */sm-t715-private/* | */sm-t715-private) die "$p: a private tree never enters a release" ;; esac
done
mkdir -p "$OUT"
REL="$(cd "$OUT" && pwd)/omarchy-tab-s2-$VERSION"
[[ ! -e "$REL" ]] || die "$REL exists"
mkdir "$REL"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ -n "$IMAGE_FROM" ]]; then
say "the image of $IMAGE_FROM, as it is"
for f in omarchy-arm64.img omarchy-arm64.img.sha256 omarchy-arm64.img.xz; do
  [[ -f "$IMAGE_FROM/$f" ]] && { cp -c "$IMAGE_FROM/$f" "$REL/$f" 2>/dev/null || cp "$IMAGE_FROM/$f" "$REL/$f"; }
done
IMG_SHA=$(cut -d' ' -f1 "$REL/omarchy-arm64.img.sha256")
[[ "$(sha "$REL/omarchy-arm64.img")" == "$IMG_SHA" ]] || die "the image does not match its sidecar"
if [[ $NO_XZ = 0 && ! -f "$REL/omarchy-arm64.img.xz" ]]; then
  say "the xz of that image"
  if ! docker image inspect "$HELPER" >/dev/null 2>&1; then die "no helper image $HELPER: run once without --image-from"; fi
  docker run --rm --platform linux/arm64 -v "$REL:/r" "$HELPER" sh -ec "xz -T0 -$XZ_LEVEL -k -c /r/omarchy-arm64.img >/r/omarchy-arm64.img.xz"
fi
sed -n '/^== The root image/,/^== The installer/p' "$IMAGE_FROM/MANIFEST.txt" | sed '$d' >"$WORK/image-part.txt"
sed -n '/^== The image.s build/,$p' "$IMAGE_FROM/MANIFEST.txt" >"$WORK/build-part.txt"
else
# --- the kernel's slot (generation 0): elkir0/bnuuyloader t715/loader/scripts/build_slot.py's format
say "the kernel's slot"
python3 -I - "$KDIR/Image" "$KDIR/$DTB" "$WORK/kernel.slot" <<'PY'
import struct, sys
image, dtb = open(sys.argv[1], "rb").read(), open(sys.argv[2], "rb").read()
def fnv(data):
    h = 0xCBF29CE484222325
    for b in data:
        h = ((h ^ b) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h & 0xFFFFFFFF, h >> 32
if struct.unpack_from("<I", image, 0x38)[0] != 0x644D5241 or struct.unpack_from("<Q", image, 8)[0] != 0:
    raise SystemExit("the kernel image has no arm64 header, or a text offset other than 0")
if dtb[:4] != b"\xd0\x0d\xfe\xed":
    raise SystemExit("the device tree has no magic")
image += bytes(-len(image) % 512)
dtb += bytes(-len(dtb) % 512)
if 0x1000 + len(image) + len(dtb) > 131072 * 512:
    raise SystemExit("the kernel and its tree do not fit a slot of 64 MiB")
# "T7K1", version 1, generation 0, flags 0, the image's size and address, the tree's, their hashes
header = struct.pack("<12I", 0x314B3754, 1, 0, 0, len(image), 0x42000000, len(dtb), 0x5F000000, *fnv(image), *fnv(dtb))
header += struct.pack("<II", *fnv(header))
open(sys.argv[3], "wb").write(header + bytes(0x1000 - len(header)) + image + dtb)
PY
KREL=$(tar -tJf "$KDIR/modules.tar.xz" | sed -n 's#^\(\./\)\{0,1\}lib/modules/\([^/]*\)/modules.dep$#\2#p' | head -n 1)
[[ -n "$KREL" ]] || die "no lib/modules/RELEASE/modules.dep in modules.tar.xz"
cat >"$WORK/RELEASE" <<EOF
Omarchy for the Galaxy Tab S2 (SM-T715), 64 bits: release $VERSION
kernel $KREL
Image sha256 $(sha "$KDIR/Image")
device tree $DTB sha256 $(sha "$KDIR/$DTB")
kernel.slot sha256 $(sha "$WORK/kernel.slot") (generation 0)
EOF

# --- the helper image
if ! docker image inspect "$HELPER" >/dev/null 2>&1; then
  say "building the helper image $HELPER"
  docker build --platform linux/arm64 -t "$HELPER" - <<EOF
FROM $BASE_IMAGE
RUN apt-get update && apt-get install -y --no-install-recommends e2fsprogs attr libcap2-bin xz-utils python3 && rm -rf /var/lib/apt/lists/*
EOF
fi

# --- the image: copied into a volume, modules and slot added, checked
say "copying the image into the work volume"
docker volume rm -f "$VOL" >/dev/null 2>&1 || true
docker volume create "$VOL" >/dev/null
docker run --rm --platform linux/arm64 -v "$VOL:/v" -v "$IMAGE:/in/image.img:ro" "$HELPER" \
  sh -ec 'cp /in/image.img /v/omarchy-arm64.img'
say "adding the modules and the slot, checking"
docker run --rm --privileged --platform linux/arm64 -v "$VOL:/v" -v "$KDIR/modules.tar.xz:/in/modules.tar.xz:ro" \
  -v "$WORK:/in/work:ro" "$HELPER" bash -euo pipefail -c '
img=/v/omarchy-arm64.img
e2fsck -fy "$img" >/v/e2fsck-before.log 2>&1 || [ $? -le 1 ] || { cat /v/e2fsck-before.log; exit 1; }
# room for the modules and the slot: 256 MiB more when less than that is free
bs=$(dumpe2fs -h "$img" 2>/dev/null | sed -n "s/^Block size: *//p")
free=$(dumpe2fs -h "$img" 2>/dev/null | sed -n "s/^Free blocks: *//p")
if [ $((free * bs)) -lt $((256 * 1048576)) ]; then
  size=$(stat -c %s "$img")
  truncate -s $((size + 256 * 1048576)) "$img"
  resize2fs "$img" >/dev/null 2>&1
  echo "the image grew by 256 MiB"
fi
loop=$(losetup -f --show "$img")
trap "umount /mnt/r 2>/dev/null; losetup -d $loop 2>/dev/null" EXIT
mkdir -p /mnt/r
mount -t ext4 "$loop" /mnt/r
fail=0
check() { echo "check: $1"; }
bad() { echo "CHECK FAILED: $1"; fail=1; }
# the modules (under usr/lib: lib is a link there in Arch)
mkdir -p /tmp/m && tar -C /tmp/m -xJf /in/modules.tar.xz
rel=$(ls /tmp/m/lib/modules)
rm -f /tmp/m/lib/modules/$rel/build /tmp/m/lib/modules/$rel/source
rm -rf /mnt/r/usr/lib/modules/$rel
install -d -m 0755 /mnt/r/usr/lib/modules
cp -a /tmp/m/lib/modules/$rel /mnt/r/usr/lib/modules/
chown -R 0:0 /mnt/r/usr/lib/modules/$rel
[ -f /mnt/r/usr/lib/modules/$rel/modules.dep ] && check "modules of $rel installed ($(find /mnt/r/usr/lib/modules/$rel -name "*.ko*" | wc -l) modules)" || bad "no modules.dep"
# the slot and the release note
install -d -m 0755 /mnt/r/usr/lib/t715-golden
install -m 0644 /in/work/kernel.slot /in/work/RELEASE /mnt/r/usr/lib/t715-golden/
check "usr/lib/t715-golden/kernel.slot and RELEASE"
# File capabilities: the installer copies with busybox tar, which does not carry them. They are
# listed in the image and set again once, at the first boot, by t715-golden-caps.service.
getcap -r /mnt/r 2>/dev/null | sed "s#^/mnt/r##" | sort >/mnt/r/usr/lib/t715-golden/file-capabilities
cat >/mnt/r/usr/lib/t715-golden/restore-capabilities <<"SH"
#!/bin/sh
# Golden: the installer copies the image with busybox tar, which does not carry file capabilities.
# Set again those the image had (usr/lib/t715-golden/file-capabilities: the output of getcap -r).
# A kernel built without CONFIG_EXT4_FS_SECURITY keeps none on ext4 ("Operation not supported"):
# then newuidmap and newgidmap get the setuid bit instead (the mode shadow installs them with by
# default), the others stay without, and this runs again at the next boot, for a kernel that can.
list=/usr/lib/t715-golden/file-capabilities
stamp=/var/lib/t715/file-capabilities.done
[ -f "$stamp" ] && cmp -s "$list" "$stamp" && exit 0
rc=0
unsupported=0
while read -r path caps; do
    [ -e "$path" ] || continue
    if out=$(setcap "$caps" "$path" 2>&1); then
        continue
    fi
    case $out in
    *"not supported"*)
        unsupported=1
        case $path in
        /usr/bin/newuidmap | /usr/bin/newgidmap)
            chmod 4755 "$path" && echo "$path: setuid root instead of $caps (no file capability on this kernel)" ;;
        *) echo "$path: left without $caps (no file capability on this kernel)" ;;
        esac
        ;;
    *)
        echo "$out" >&2
        rc=1
        ;;
    esac
done <"$list"
if [ "$rc" = 0 ] && [ "$unsupported" = 0 ]; then
    mkdir -p /var/lib/t715 && cp "$list" "$stamp"
fi
exit "$rc"
SH
chmod 0755 /mnt/r/usr/lib/t715-golden/restore-capabilities
cat >/mnt/r/usr/lib/systemd/system/t715-golden-caps.service <<"UNIT"
# Galaxy Tab S2, Golden release: the file capabilities the copy of the installer could not carry, set
# again once (/usr/lib/t715-golden/restore-capabilities).
[Unit]
Description=Galaxy Tab S2: set the file capabilities of the installed image again
ConditionPathExists=/usr/lib/t715-golden/file-capabilities
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/lib/t715-golden/restore-capabilities

[Install]
WantedBy=multi-user.target
UNIT
mkdir -p /mnt/r/etc/systemd/system/multi-user.target.wants
ln -sf /usr/lib/systemd/system/t715-golden-caps.service /mnt/r/etc/systemd/system/multi-user.target.wants/t715-golden-caps.service
check "$(wc -l </mnt/r/usr/lib/t715-golden/file-capabilities) file capabilities listed, set again at the first boot (t715-golden-caps.service)"
# Any other extended attribute would be lost by the copy: only ACLs that systemd-tmpfiles sets again
python3 - /mnt/r <<"PY" >/tmp/xattrs.txt
import os, sys
root = sys.argv[1]
tmpfiles = ("/var/log/journal", "/var/lib/systemd", "/var/lib/tpm2-tss")
for top, dirs, files in os.walk(root):
    for name in dirs + files:
        p = os.path.join(top, name)
        try:
            attrs = os.listxattr(p, follow_symlinks=False)
        except OSError:
            continue
        rel = p[len(root):]
        for a in attrs:
            if a == "security.capability":
                continue
            if a.startswith("system.posix_acl_") and rel.startswith(tmpfiles):
                continue
            print(rel, a)
PY
[ ! -s /tmp/xattrs.txt ] && check "no other extended attribute than capabilities and the ACLs systemd-tmpfiles sets" || bad "extended attributes the copy would lose: $(head -n 5 /tmp/xattrs.txt)"
keys=$(ls /mnt/r/etc/ssh/ssh_host_* 2>/dev/null | head -n 3 || true)
[ -z "$keys" ] && check "no SSH host key" || bad "SSH host keys in the image: $keys"
mid=$(cat /mnt/r/etc/machine-id 2>/dev/null || true)
case "$mid" in "" | uninitialized) check "machine-id empty" ;; *) bad "a machine-id is set" ;; esac
for k in /mnt/r/root/.ssh/authorized_keys /mnt/r/home/*/.ssh/authorized_keys; do
  [ -e "$k" ] && bad "an authorized_keys: ${k#/mnt/r}" || true
done
check "no authorized_keys"
blank=$(ls -A /mnt/r | grep -E "[[:space:]]" || true)
[ -z "$blank" ] && check "no top-level name with a blank" || bad "top-level names with blanks"
sys=$(od -An -tu1 -j 18 -N 1 /mnt/r/usr/lib/systemd/systemd | tr -d " ")
[ "$sys" = 183 ] && check "an aarch64 system" || bad "usr/lib/systemd/systemd is not AArch64"
for f in /mnt/r/etc/NetworkManager/system-connections/*; do
  [ -e "$f" ] && bad "a saved network: ${f##*/}" || true
done
check "no saved network"
df -k /mnt/r | awk "NR == 2 { printf \"used %d MiB of %d MiB\\n\", \$3 / 1024, \$2 / 1024 }" >/v/df.txt
umount /mnt/r
losetup -d "$loop"
trap - EXIT
e2fsck -fn "$img" >/v/e2fsck-after.log 2>&1 && check "e2fsck clean" || { bad "e2fsck"; tail -n 5 /v/e2fsck-after.log; }
cat /v/df.txt
exit $fail
' | tee "$WORK/checks.txt"
grep -q 'CHECK FAILED' "$WORK/checks.txt" && die "the image failed a check"

say "the raw image's checksum, and the xz"
docker run --rm --platform linux/arm64 -v "$VOL:/v" "$HELPER" sh -ec "
cd /v && sha256sum omarchy-arm64.img >omarchy-arm64.img.sha256
if [ $NO_XZ = 0 ]; then xz -T0 -$XZ_LEVEL -k -c omarchy-arm64.img >omarchy-arm64.img.xz; fi"
docker run --rm --platform linux/arm64 -v "$VOL:/v" -v "$REL:/out" "$HELPER" sh -ec "
cp /v/omarchy-arm64.img.sha256 /out/
if [ -f /v/omarchy-arm64.img.xz ]; then cp /v/omarchy-arm64.img.xz /out/; fi
cp /v/omarchy-arm64.img /out/omarchy-arm64.img"
IMG_SHA=$(cut -d' ' -f1 "$REL/omarchy-arm64.img.sha256")
[[ "$(sha "$REL/omarchy-arm64.img")" == "$IMG_SHA" ]] || die "the raw image does not match its sidecar after the copy"
{
  echo "== The root image (omarchy-arm64.img)"
  echo "sha256 $IMG_SHA"
  sed -n 's/^check: /  - /p; /^used /p' "$WORK/checks.txt"
  echo
  echo "== Its kernel (usr/lib/t715-golden/RELEASE)"
  sed 's/^/  /' "$WORK/RELEASE"
  echo
} >"$WORK/image-part.txt"
{
  echo "== The image's build (arm64/rootfs/out/*.MANIFEST)"
  m="${IMAGE%.img}.MANIFEST"; [[ -f "$m" ]] || m="$(dirname "$IMAGE")/rootfs-aarch64-omarchy45.MANIFEST"
  # dates only, never a time of day, in what is published
  if [[ -f "$m" ]]; then sed -E 's/^/  /; s/[T ][0-9]{2}:[0-9]{2}(:[0-9]{2}([.][0-9]+)?)?(Z| UTC|[+-][0-9]{2}:?[0-9]{2})?//g' "$m"; else echo "  (no MANIFEST next to the image)"; fi
} >"$WORK/build-part.txt"
docker volume rm -f "$VOL" >/dev/null 2>&1 || true
fi

# --- the installer: boot/initramfs with boot/golden, on the 32-bit kernel, BOOT and RECOVERY
say "the installer"
KNOBS="t715.failwait=30 t715.quiet=1${IKNOBS:+ $IKNOBS}"
bash "$ROOT/boot/build-initramfs.sh" --out "$WORK/initramfs" --knobs "$KNOBS" --golden "$ROOT/boot/golden" >"$WORK/initramfs.log"
bash "$ROOT/boot/pack-test-recovery.sh" --initramfs "$WORK/initramfs/initramfs.cpio.gz" --out "$WORK/recovery" "$IKERNEL" >"$WORK/pack-recovery.log"
bash "$ROOT/boot/pack-test-recovery.sh" --initramfs "$WORK/initramfs/initramfs.cpio.gz" --boot --out "$WORK/boot" "$IKERNEL" >"$WORK/pack-boot.log"
cp "$WORK/boot/boot.img" "$WORK/recovery/recovery.img" "$REL/"
bash "$ROOT/image/tools/pack-odin" --out "$REL/omarchy-tab-s2-$VERSION-AP.tar.md5" "$REL/boot.img" "$REL/recovery.img"

# --- sums and manifest
( cd "$REL" && shasum -a 256 $(ls | grep -v -E '^(SHA256SUMS|MANIFEST.txt)$') >SHA256SUMS )
{
  echo "Omarchy for the Galaxy Tab S2 (SM-T715), 64 bits: release $VERSION"
  echo
  cat "$WORK/image-part.txt"
  echo "== The installer (boot.img, recovery.img)"
  echo "  32-bit kernel: $(basename "$IKERNEL"), zImage sha256 $(sha "$IKERNEL/zImage")"
  grep -h '^>>> init sha256' "$WORK/initramfs.log" | sed 's/^>>> /  initramfs: /'
  echo "  loader: boot/golden (bootloader $(cat "$ROOT/boot/golden/bootloader"), PARAM's first $(cat "$ROOT/boot/golden/extent") bytes),"
  echo "  one pair per stock PARAM the installer knows (stock.sha256 and loader.sha256, line by line):"
  paste -d '\n' <(grep -v '^[[:space:]]*$' "$ROOT/boot/golden/stock.sha256" | sed 's/^/    stock  /') \
    <(grep -v '^[[:space:]]*$' "$ROOT/boot/golden/loader.sha256" | sed 's/^/    loader /')
  [[ -z "$IKNOBS" ]] || echo "  TEST KNOBS ADDED: $IKNOBS (not a release to publish)"
  echo
  cat "$WORK/build-part.txt"
} >"$REL/MANIFEST.txt"
say "done: $REL"
ls -la "$REL"
