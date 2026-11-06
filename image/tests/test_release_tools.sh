#!/usr/bin/env bash
# test_release_tools.sh — off-device test of the release tools
# (tools/pack-odin, tools/make-release): the Odin .tar.md5 packages and the
# checksummed release directory end users flash.
#
# Builds synthetic inputs in a temporary directory — fake boot.img and
# recovery.img with the ANDROID! magic, a small fake ext4 image (the magic
# at offset 1080, no mkfs needed) — then checks that:
#   - pack-odin refuses a wrong file name, a missing magic and an oversize
#     image, and refuses an image from a dumps/ directory;
#   - its package lists exactly the images with tar -tf, its trailer's md5
#     equals the md5 of the bytes before it, and the trailer names the tar;
#   - make-release produces every release file, its SHA256SUMS verifies
#     (shasum -a 256 -c / sha256sum -c, skipping the raw-image line), and
#     it refuses an existing output directory, a non-ext4 root image and an
#     input under a dumps/ directory.
#
# Usage: tests/test_release_tools.sh
# Prints "ok - ..." per group, "PASS" at the end; exit 1 on the first
# failure. Works on macOS (bsdtar, md5, shasum) and Linux (GNU tar, md5sum,
# sha256sum). Nothing outside a temporary directory.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PACK="$here/tools/pack-odin"
MAKE="$here/tools/make-release"
for f in "$PACK" "$MAKE"; do
    [ -x "$f" ] || { echo "SETUP ERROR: no $f" >&2; exit 2; }
done
for c in tar xz dd od find; do
    command -v "$c" >/dev/null || { echo "SETUP ERROR: no $c" >&2; exit 2; }
done

md5_of() {
    if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | awk '{print $1}'
    else md5 -q "$1"; fi
}
sha256_check() { # sha256_check SUMS: verify, ignoring the raw-image line
    if command -v sha256sum >/dev/null 2>&1; then
        grep -v '  rootfs-omarchy\.img$' "$1" | sha256sum -c -
    else
        grep -v '  rootfs-omarchy\.img$' "$1" | shasum -a 256 -c -
    fi
}
size_of() { wc -c < "$1" | tr -d ' '; }   # portable: stat -f/-c differ per OS

t=$(mktemp -d "${TMPDIR:-/tmp}/release-tools-test.XXXXXX")
trap 'rm -rf "$t"' EXIT
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

# --- synthetic inputs -------------------------------------------------------
# A boot image is an Android boot image (magic ANDROID! at offset 0); ours
# also carry the SEANDROIDENFORCE footer inside the file, which the tools
# must neither add nor remove: give the fakes a footer so the tools' copies
# keep it.
mkdir -p "$t/in"
fake_boot() { # fake_boot FILE KIB
    { printf 'ANDROID!'
      head -c $(( $2 * 1024 - 24 )) /dev/zero
      printf 'SEANDROIDENFORCE'; } > "$1"
}
fake_boot "$t/in/boot.img" 200
fake_boot "$t/in/recovery.img" 300
# A root image is raw ext4: the superblock magic 0xEF53 sits at offset 1080
# (1024 of the super block + 56 to s_magic), little-endian 53 ef.
fake_ext4() { # fake_ext4 FILE MIB
    head -c $(( $2 * 1048576 )) /dev/zero > "$1"
    printf '\x53\xef' | dd of="$1" bs=1 seek=1080 conv=notrunc status=none
}
fake_ext4 "$t/in/rootfs.img" 4

# --- pack-odin: the refusals -------------------------------------------------
# A wrong flash file name.
cp "$t/in/boot.img" "$t/in/other.img"
if "$PACK" --out "$t/wrong-name.tar.md5" "$t/in/other.img" >/dev/null 2>&1; then
    fail "pack-odin refuses a file not named boot.img or recovery.img"
fi
# A missing magic: a boot-sized image whose first 8 bytes are not ANDROID!.
mkdir -p "$t/in/bm"
{ printf 'KANDROID!'; head -c 204792 /dev/zero; printf 'SEANDROIDENFORCE'; } > "$t/in/bm/boot.img"
if "$PACK" --out "$t/wrong-magic.tar.md5" "$t/in/bm/boot.img" >/dev/null 2>&1; then
    fail "pack-odin refuses an image without the ANDROID! magic"
fi
# An oversize image: BOOT's limit is 14336 KiB.
mkdir -p "$t/in/oversize"
fake_boot "$t/in/oversize/boot.img" 14337
if "$PACK" --out "$t/oversize.tar.md5" "$t/in/oversize/boot.img" >/dev/null 2>&1; then
    fail "pack-odin refuses an image over the partition's size limit"
fi
# A duplicate.
if "$PACK" --out "$t/dup.tar.md5" "$t/in/boot.img" "$t/in/boot.img" >/dev/null 2>&1; then
    fail "pack-odin refuses the same flash name twice"
fi
# Private data.
mkdir -p "$t/dumps"
cp "$t/in/boot.img" "$t/dumps/boot.img"
if "$PACK" --out "$t/private.tar.md5" "$t/dumps/boot.img" >/dev/null 2>&1; then
    fail "pack-odin refuses an image under a dumps/ directory"
fi
echo "ok - pack-odin refuses wrong names, bad magic, oversize, duplicates and dumps/"

# --- pack-odin: the package ---------------------------------------------------
out="$t/omarchy-tab-s2-0.9.4-AP.tar.md5"
"$PACK" --out "$out" "$t/in/boot.img" "$t/in/recovery.img" > "$t/pack.out" 2>&1 \
    || fail "pack-odin builds the AP package"
grep -q "^$out (" "$t/pack.out" || fail "pack-odin prints the result's path and size"
[ "$(tar -tf "$out")" = "boot.img
recovery.img" ] || fail "the package lists exactly boot.img and recovery.img"
# The trailer: the md5 of the tar bytes, then two spaces and the tar's name.
# It follows the tar's NUL padding, so read the last non-empty line.
fs="$(size_of "$out")"
trailer="$(tail -c 256 "$out" | tr '\000' '\n' | tail -n 1)"
thash="$(printf '%s\n' "$trailer" | awk '{print $1}')"
tname="$(printf '%s\n' "$trailer" | awk '{print $NF}')"
tl=$(( ${#thash} + 2 + ${#tname} + 1 ))
tarlen=$(( fs - tl ))
head -c "$tarlen" "$out" > "$t/tar-part"
[ "$(md5_of "$t/tar-part")" = "$thash" ] || fail "the trailer's md5 equals the md5 of the tar bytes"
[ "$tname" = "omarchy-tab-s2-0.9.4-AP.tar" ] || fail "the trailer names the tar file"
# The members come out with the fixed metadata (owner 0:0, mode 0644).
mode="$(tar -tvf "$out" | head -n1 | awk '{print $1}')"
owner="$(tar -tvf "$out" | head -n1 | awk '{print $2}')"
[ "$mode" = "-rw-r--r--" ] || fail "the packaged images have mode 0644 (got $mode)"
[ "$owner" = "0/0" ] || [ "$owner" = "root/root" ] || [ "$owner" = "0" ] \
    || fail "the packaged images belong to 0:0 (got $owner)"
# The images themselves are untouched: byte for byte.
mkdir -p "$t/x" && tar -xf "$out" -C "$t/x"
cmp "$t/x/boot.img" "$t/in/boot.img" || fail "the packaged boot.img is the input, byte for byte"
echo "ok - pack-odin: ustar listing, md5 trailer, fixed metadata, bytes untouched"

# --- make-release --------------------------------------------------------------
outroot="$t/relroot"
"$MAKE" --version 0.9.4 --boot "$t/in/boot.img" --recovery "$t/in/recovery.img" \
        --rootfs "$t/in/rootfs.img" --out "$outroot" --xz-level 1 > "$t/make.out" 2>&1 \
    || { cat "$t/make.out" >&2; fail "make-release builds the release directory"; }
REL="$outroot/omarchy-tab-s2-0.9.4"
for f in boot.img recovery.img rootfs-omarchy.img.xz \
         omarchy-tab-s2-0.9.4-AP.tar.md5 omarchy-tab-s2-0.9.4-boot.tar.md5 \
         SHA256SUMS RELEASE.md; do
    [ -f "$REL/$f" ] || fail "make-release produces $f"
done
[ "$(tar -tf "$REL/omarchy-tab-s2-0.9.4-boot.tar.md5")" = "boot.img" ] \
    || fail "the boot-only Odin package holds only boot.img"
xz -t "$REL/rootfs-omarchy.img.xz" 2>/dev/null || fail "rootfs-omarchy.img.xz is a valid xz stream"
cmp "$REL/boot.img" "$t/in/boot.img" || fail "the release's boot.img is the input"
echo "ok - make-release: every file, the boot-only package, a valid xz, images copied"

# SHA256SUMS: every file of the release verifies, the raw-image line is
# listed under its uncompressed name and the comment says so.
grep -q '^# SHA256SUMS also lists the root image' "$REL/SHA256SUMS" \
    || fail "SHA256SUMS carries the comment about the raw-image line"
grep -q '  rootfs-omarchy\.img$' "$REL/SHA256SUMS" \
    || fail "SHA256SUMS lists the raw image as rootfs-omarchy.img"
! grep -q '  RELEASE\.md$' "$REL/SHA256SUMS" \
    || fail "SHA256SUMS leaves RELEASE.md out (it is edited after the sums)"
( cd "$REL" && sha256_check SHA256SUMS >/dev/null 2>&1 ) \
    || fail "sha256 -c passes on SHA256SUMS for the files present"
# And the raw line matches the root image we fed in.
rawsha="$(grep '  rootfs-omarchy\.img$' "$REL/SHA256SUMS" | awk '{print $1}')"
if command -v sha256sum >/dev/null 2>&1; then insha="$(sha256sum "$t/in/rootfs.img" | awk '{print $1}')"
else insha="$(shasum -a 256 "$t/in/rootfs.img" | awk '{print $1}')"; fi
[ "$rawsha" = "$insha" ] || fail "the raw-image line is the sha256 of the input root image"
# RELEASE.md: the version, the date, every artifact.
grep -q "release 0.9.4" "$REL/RELEASE.md" || fail "RELEASE.md names the version"
grep -qE "^Version 0\.9\.4, [0-9]{4}-[0-9]{2}-[0-9]{2} \(UTC\)" "$REL/RELEASE.md" \
    || fail "RELEASE.md names the version and the UTC date (date only)"
for f in boot.img recovery.img rootfs-omarchy.img.xz omarchy-tab-s2-0.9.4-AP.tar.md5; do
    grep -q "$f" "$REL/RELEASE.md" || fail "RELEASE.md lists $f"
done
grep -q "TODO" "$REL/RELEASE.md" || fail "RELEASE.md has placeholders for the changes and steps"
# No host path anywhere in the generated text files.
if grep -qE "(^|[^A-Za-z0-9])$t" "$REL/SHA256SUMS" "$REL/RELEASE.md" 2>/dev/null; then
    fail "no absolute host path in the generated files"
fi
echo "ok - make-release: SHA256SUMS verifies, RELEASE.md complete, no host paths"

# --- make-release: the refusals -------------------------------------------------
if "$MAKE" --version 0.9.4 --boot "$t/in/boot.img" --recovery "$t/in/recovery.img" \
          --rootfs "$t/in/rootfs.img" --out "$outroot" >/dev/null 2>&1; then
    fail "make-release refuses an existing output directory"
fi
# Not an ext4 image: zeros with some other bytes at 1080, so the magic
# check cannot pass by chance.
head -c $((4 * 1048576)) /dev/zero > "$t/in/notext4.img"
printf '\x00\x00' | dd of="$t/in/notext4.img" bs=1 seek=1080 conv=notrunc status=none
if "$MAKE" --version 0.9.5 --boot "$t/in/boot.img" --recovery "$t/in/recovery.img" \
          --rootfs "$t/in/notext4.img" --out "$t/relroot2" >/dev/null 2>&1; then
    fail "make-release refuses a root image with no ext4 superblock"
fi
[ ! -e "$t/relroot2/omarchy-tab-s2-0.9.5" ] || fail "a refused release leaves no directory behind"
if "$MAKE" --version 0.9.6 --boot "$t/dumps/boot.img" --recovery "$t/in/recovery.img" \
          --rootfs "$t/in/rootfs.img" --out "$t/relroot3" >/dev/null 2>&1; then
    fail "make-release refuses an input under a dumps/ directory"
fi
[ ! -e "$t/relroot3/omarchy-tab-s2-0.9.6" ] || fail "a refused release leaves no directory behind"
echo "ok - make-release refuses an existing directory, a non-ext4 root, dumps/"

# --- make-release --no-xz --------------------------------------------------------
"$MAKE" --version 0.9.7 --boot "$t/in/boot.img" --recovery "$t/in/recovery.img" \
        --rootfs "$t/in/rootfs.img" --out "$t/relroot4" --no-xz >/dev/null 2>&1 \
    || fail "make-release --no-xz builds the release directory"
[ -f "$t/relroot4/omarchy-tab-s2-0.9.7/rootfs-omarchy.img" ] \
    || fail "--no-xz copies the raw image as rootfs-omarchy.img"
cmp "$t/relroot4/omarchy-tab-s2-0.9.7/rootfs-omarchy.img" "$t/in/rootfs.img" \
    || fail "--no-xz copies the raw image byte for byte"
( cd "$t/relroot4/omarchy-tab-s2-0.9.7" \
    && { if command -v sha256sum >/dev/null 2>&1; then sha256sum -c SHA256SUMS
         else shasum -a 256 -c SHA256SUMS; fi } >/dev/null 2>&1 ) \
    || fail "--no-xz: SHA256SUMS verifies with no raw-image line to skip"
echo "ok - make-release --no-xz: the raw image, checksums whole"

echo "PASS"
