#!/usr/bin/env bash
# build-initramfs.sh — the arm64 initramfs skeleton of the Galaxy Tab S2 8.0
# LTE (SM-T715): busybox sh as PID 1 (initramfs/init), which boots the aarch64
# root image of this build. Adapted from omarchy-tab-s2/boot/
# build-initramfs.sh (read-only), for arm64 and a much smaller init.
#
# Output, in out/initramfs/:
#   root/                       the initramfs as a directory, for the kernel's
#                               CONFIG_INITRAMFS_SOURCE (the kernel adds
#                               /dev/console itself: usr/default_cpio_list)
#   initramfs-aarch64.cpio.gz   the same as one archive (newc cpio, root:root,
#                               mtime 0, sorted, gzip -n -9): for an external
#                               initrd, or a later slot format
#   initramfs-aarch64.manifest.txt, SHA256SUMS
#
# Archive contents:
#   /init                   initramfs/init
#   /bin/busybox            static aarch64 busybox from Debian's busybox-static
#                           arm64 package (version + SHA-256 pinned below)
#   applet symlinks         every applet of "busybox --list-full" but linuxrc
#   /sbin/e2fsck            static e2fsck from Debian's e2fsck-static arm64
#                           package (pinned): the persistent root's check
#   /dev/console            char 5:1 (the kernel opens it for /init's stdio)
#   /etc/t715-initramfs.id  build identification, logged at boot
#   empty directories       newroot proc run userdata
#
# Usage: initramfs/build-initramfs.sh
# The .deb files (public Debian packages) are hash-checked downloads, kept in
# cache/initramfs/ and unpacked only in the container. Same inputs give the
# same archive. It checks nothing on a device: tests/test-initramfs.sh runs
# the init's own tests in Docker.

set -euo pipefail

ROOTFS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$ROOTFS_DIR/lib/common.sh"
LOG_TAG=initramfs

INIT_SRC="$ROOTFS_DIR/initramfs/init"
CPIO_PY="$ROOTFS_DIR/initramfs/cpio_newc.py"
OUT="$OUT_DIR/initramfs"
CACHE="$CACHE_DIR/initramfs"

# Debian trixie (stable), main, arm64: versions and SHA-256 from its package
# index (dists/trixie/main/binary-arm64/Packages), read on 2026-11-24. The
# snapshot address serves the same files should trixie move on.
DIST="trixie"
SNAPSHOT="20261101T000000Z"
BB_VERSION="1:1.37.0-6+b9"
BB_DEB="busybox-static_1.37.0-6+b9_arm64.deb"
BB_SHA256="c833be48abfa16bc19c4966ec93e289ff1ce5d2f1476cad3a57bd105378cd15c"
BB_PATH="pool/main/b/busybox/$BB_DEB"
FSCK_VERSION="1.47.2-3+b12"
FSCK_DEB="e2fsck-static_1.47.2-3+b12_arm64.deb"
FSCK_SHA256="a3c7aaac77ecd6f8521bdff1c4b9ac27cde3179801c38adf3c7ae317d09a6ef8"
FSCK_PATH="pool/main/e/e2fsprogs/$FSCK_DEB"

[ -f "$INIT_SRC" ] || die "missing $INIT_SRC"
[ -f "$CPIO_PY" ] || die "missing $CPIO_PY"
mkdir -p "$OUT" "$CACHE"
docker_preflight
ensure_helper_image

# --- the two .deb files, hash-pinned -------------------------------------------
fetch_deb() { # FILE SHA256 PATH
    local file="$1" sum="$2" path="$3" deb url
    deb="$CACHE/$file"
    if [ ! -f "$deb" ] || [ "$(sha256_of "$deb")" != "$sum" ]; then
        rm -f "$deb" "$deb.part"
        for url in "https://deb.debian.org/debian/$path" \
                   "https://snapshot.debian.org/archive/debian/$SNAPSHOT/$path"; do
            log "downloading $url"
            # %2B: '+' of the Debian version, in the file name.
            if curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors -o "$deb.part" "${url//+/%2B}"; then
                if [ "$(sha256_of "$deb.part")" = "$sum" ]; then
                    mv -f "$deb.part" "$deb"
                    break
                fi
                warn "$file from $url: not the pinned file"
            fi
            rm -f "$deb.part"
        done
    fi
    [ -f "$deb" ] || die "could not download $file"
    [ "$(sha256_of "$deb")" = "$sum" ] || die "$deb: SHA-256 mismatch"
}

fetch_deb "$BB_DEB" "$BB_SHA256" "$BB_PATH"
fetch_deb "$FSCK_DEB" "$FSCK_SHA256" "$FSCK_PATH"

# --- assemble in the container -------------------------------------------------
INIT_SHA="$(sha256_of "$INIT_SRC")"
BUILD_ID="init sha256:${INIT_SHA:0:12}, busybox-static $BB_VERSION arm64, e2fsck-static $FSCK_VERSION arm64"

rm -rf "$OUT/root" "$OUT"/*.tmp
mkdir -p "$OUT"
docker run --rm -i --platform "$PLATFORM" \
    -v "$CACHE/$BB_DEB:/in/busybox.deb:ro" -v "$CACHE/$FSCK_DEB:/in/e2fsck.deb:ro" \
    -v "$INIT_SRC:/in/init:ro" -v "$CPIO_PY:/in/cpio_newc.py:ro" \
    -v "$OUT:/out" -e BUILD_ID="$BUILD_ID" \
    "$HELPER_IMAGE" bash -euo pipefail -s <<'EOS' || die "the initramfs assembly failed"
cd /tmp
dpkg-deb -x /in/busybox.deb deb
dpkg-deb -x /in/e2fsck.deb fsckdeb
# find, not ls: under pipefail an ls of a path that does not exist fails.
bb="$(find deb -name busybox -type f | head -n1)"
fsck="$(find fsckdeb -name 'e2fsck.static' -type f | head -n1)"
[ -n "$bb" ] && [ -n "$fsck" ] || { echo "error: no busybox or e2fsck.static in the packages" >&2; exit 1; }
for b in "$bb" "$fsck"; do
    desc="$(file -b "$b")"
    machine="$(readelf -h "$b" | sed -n 's/^ *Machine: *//p')"
    case "$desc" in
        "ELF 64-bit LSB executable, ARM aarch64"*"statically linked"*) ;;
        *) echo "error: ${b##*/} is not a static AArch64 executable: $desc" >&2; exit 1 ;;
    esac
    [ "$machine" = AArch64 ] || { echo "error: ${b##*/}: machine $machine" >&2; exit 1; }
    if readelf -l "$b" | grep -q 'Requesting program interpreter'; then
        echo "error: ${b##*/} has a program interpreter (dynamic)" >&2; exit 1
    fi
    echo ">>> ${b##*/}: $desc"
done
"$fsck" -V 2>&1 | sed 's/^/>>> /'
"$bb" --list-full >applets
[ -s applets ] || { echo "error: busybox --list-full printed nothing" >&2; exit 1; }
# The init must parse under this busybox's sh, and its applets must be there.
"$bb" sh -n /in/init || { echo "error: /init has a syntax error" >&2; exit 1; }
# Every applet the init calls must be in this busybox (wherever it lives:
# bin, sbin, usr/bin or usr/sbin).
for a in sh mount umount losetup blockdev chroot dd sed tail sleep cat find df mv \
         sync grep cttyhack setsid mkdir uname; do
    grep -qE "(^|/)$a\$" applets || { echo "error: busybox lacks the applet $a" >&2; exit 1; }
done
printf '%s\n' "$BUILD_ID" >build-id

python3 -I - "$bb" "$fsck" applets build-id /out/initramfs-aarch64.cpio /out/root <<"PY"
import os
import sys

sys.path.insert(0, "/in")
import cpio_newc as c

bb, fsck, applets, build_id, out, rootdir = sys.argv[1:7]

def install(name, mode, data=None, target=None, rdev=(0, 0)):
    path = os.path.join(rootdir, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if target is not None:
        if not os.path.lexists(path):
            os.symlink(target, path)
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as out_file:
        out_file.write(data)
    os.chmod(path, mode & 0o7777)

items = {}  # name -> (mode, data, rdevmajor, rdevminor)
for d in ("bin", "dev", "etc", "newroot", "proc", "run", "sbin", "userdata"):
    items[d] = (0o040755, b"", 0, 0)
    os.makedirs(os.path.join(rootdir, d), exist_ok=True)
items["dev/console"] = (0o020600, b"", 5, 1)       # the kernel adds this one to a directory source itself
items["init"] = (0o100755, open("/in/init", "rb").read(), 0, 0)
items["bin/busybox"] = (0o100755, open(bb, "rb").read(), 0, 0)
items["sbin/e2fsck"] = (0o100755, open(fsck, "rb").read(), 0, 0)
items["etc/t715-initramfs.id"] = (0o100644, open(build_id, "rb").read(), 0, 0)
links = {}
for line in open(applets):
    path = line.strip()
    if not path or path in ("linuxrc", "sbin/init") or path in items:
        continue
    if path.split("/")[0] not in ("bin", "sbin", "usr"):
        raise SystemExit("unexpected applet path %r" % path)
    items[path] = (0o120777, b"/bin/busybox", 0, 0)
    links[path] = "/bin/busybox"

# The directory for CONFIG_INITRAMFS_SOURCE: files and links, no device node.
for name, (mode, data, rmaj, rmin) in sorted(items.items()):
    if (mode & 0o170000) == 0o040000:
        continue
    if (mode & 0o170000) == 0o120000:
        install(name, mode, target=data.decode())
    elif (mode & 0o170000) == 0o020000:
        continue
    else:
        install(name, mode, data=data)

entries = []
for ino, name in enumerate(sorted(items), start=1):
    mode, data, rmaj, rmin = items[name]
    entries.append(c.Entry(name, data=data, mode=mode, ino=ino,
                           nlink=2 if mode & 0o170000 == 0o040000 else 1,
                           mtime=0, rdevmajor=rmaj, rdevminor=rmin))
blob = c.write_archive(entries)
blob += b"\0" * (-len(blob) % 512)
open(out, "wb").write(blob)
with open(out + ".manifest.txt", "w") as manifest:
    for name in sorted(items):
        manifest.write("%s\n" % name)
# The directory holds the archive's files and links, and nothing else (the
# kernel adds /dev/console to a directory source itself).
in_root = set()
for top, dirs, files in os.walk(rootdir):
    for name in dirs + files:
        path = os.path.join(top, name)
        if not os.path.isdir(path) or os.path.islink(path):
            in_root.add("/" + os.path.relpath(path, rootdir))
in_archive = set("/" + name for name, (mode, _, _, _) in items.items()
                 if (mode & 0o170000) != 0o040000 and name != "dev/console")
if in_root != in_archive:
    raise SystemExit("error: root/ and the archive hold different trees: %s" % sorted(in_root ^ in_archive)[:6])
print(">>> cpio: %d entries, %d bytes; root/ holds the same %d files and links" % (len(entries), len(blob), len(in_root)))
PY
chmod 0755 /out/root/init /out/root/bin/busybox /out/root/sbin/e2fsck
gzip -n -9 -c /out/initramfs-aarch64.cpio > /out/initramfs-aarch64.cpio.gz
rm -f /out/initramfs-aarch64.cpio
(cd /out && sha256sum initramfs-aarch64.cpio.gz > SHA256SUMS)
echo ">>> $(cat /out/SHA256SUMS)"
EOS

SIZE="$(wc -c < "$OUT/initramfs-aarch64.cpio.gz" | tr -d ' ')"
log "$BUILD_ID"
log "$OUT/initramfs-aarch64.cpio.gz: $SIZE bytes ($((SIZE / 1024)) KiB); CONFIG_INITRAMFS_SOURCE directory: $OUT/root/"
cat "$OUT/SHA256SUMS"
