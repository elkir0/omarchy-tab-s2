#!/bin/bash
# mkimage.sh — runs in the t715-omarchy-rootfs-helper container (Debian
# trixie, native arm64), started by tools/build-rootfs with the
# `docker export` of the final armv7h container on stdin. Unpacks the tree in
# the container (never on macOS: case-insensitive, loses ownership), applies
# the fixes that only make sense after the export, sizes the file system and
# writes the raw ext4 image with mkfs.ext4 -d.
#
# Environment:
#   IMG        output path in the container (the .tmp file is renamed on success)
#   SIZE_MIB   file system size in MiB, 0 = auto (content + 20 %, plus the
#              inode tables and the journal, rounded up to 64 MiB)
#   LABEL      ext4 label (ALARM, as the Phosh image; the initramfs mounts
#              the image by path and does not require one)
#   HOST_NAME  /etc/hostname
# Prints T715_<key>=<value> lines for tools/build-rootfs.
set -euo pipefail

: "${IMG:?}" "${SIZE_MIB:?}" "${LABEL:?}" "${HOST_NAME:?}"
T=/tree
JOURNAL_MIB=64

say() { printf 'mkimage: %s\n' "$*" >&2; }
die() { printf 'mkimage: ERROR: %s\n' "$*" >&2; exit 1; }

rm -rf "$T"
mkdir -p "$T"
say "unpacking the exported tree"
tar -x --numeric-owner --xattrs --xattrs-include='*' -C "$T"

# Docker leftovers. /.dockerenv makes systemd believe it runs in a container
# (console-getty would fight for tty1). /etc/hostname, /etc/hosts and
# /etc/resolv.conf were Docker bind mounts during the build: the export holds
# empty placeholders.
rm -f "$T/.dockerenv"
printf '%s\n' "$HOST_NAME" > "$T/etc/hostname"
cat > "$T/etc/hosts" <<EOF
# Static table lookup for hostnames.
# See hosts(5) for details.
127.0.0.1	localhost
::1		localhost
127.0.1.1	$HOST_NAME
EOF
# Omarchy enables systemd-resolved (config/enable-services.sh).
rm -f "$T/etc/resolv.conf"
ln -s ../run/systemd/resolve/stub-resolv.conf "$T/etc/resolv.conf"
chmod 0644 "$T/etc/hostname" "$T/etc/hosts"

[ ! -e "$T/.dockerenv" ] || die "/.dockerenv is still there"
[ -x "$T/sbin/init" ] || [ -L "$T/sbin/init" ] || die "no /sbin/init in the tree"
[ ! -e "$T/usr/lib/modules" ] || die "/usr/lib/modules in the tree"

used_mib="$(du -sx --block-size=1M "$T" | cut -f1)"
nfiles="$(find "$T" -xdev | wc -l)"
inodes=$(( nfiles * 6 / 5 + 4096 ))
inode_mib=$(( (inodes * 256 + 1048575) / 1048576 ))
overhead_mib=$(( inode_mib + JOURNAL_MIB + 64 ))
if [ "$SIZE_MIB" -eq 0 ]; then
    size_mib=$(( (used_mib * 12 / 10 + overhead_mib + 63) / 64 * 64 ))
    sizing="auto (content + 20 %, inode tables, journal)"
else
    size_mib="$SIZE_MIB"
    sizing="--size"
    [ $(( used_mib + overhead_mib )) -le "$size_mib" ] \
        || die "content (${used_mib} MiB + ${overhead_mib} MiB of metadata) does not fit in ${size_mib} MiB"
fi
say "content ${used_mib} MiB in ${nfiles} inodes; file system ${size_mib} MiB, ${inodes} inodes"

rm -f "$IMG.tmp"
truncate -s "${size_mib}M" "$IMG.tmp"
# -m 0: the image is mounted read-only, reserved blocks would be wasted.
mkfs.ext4 -q -F -L "$LABEL" -m 0 -b 4096 -N "$inodes" -J size="$JOURNAL_MIB" \
    -E lazy_itable_init=0,lazy_journal_init=0,root_owner=0:0 \
    -d "$T" "$IMG.tmp"
say "e2fsck -fn"
e2fsck -fn "$IMG.tmp" >&2
mv -f "$IMG.tmp" "$IMG"
rm -rf "$T"

d="$(dumpe2fs -h "$IMG" 2>/dev/null)"
field() { printf '%s\n' "$d" | sed -n "s/^$1: *//p" | head -n1; }
echo "T715_SIZING=$sizing"
echo "T715_SIZE_MIB=$size_mib"
echo "T715_CONTENT_MIB=$used_mib"
echo "T715_FILES=$nfiles"
echo "T715_LABEL=$(field 'Filesystem volume name')"
echo "T715_BLOCK_SIZE=$(field 'Block size')"
echo "T715_BLOCK_COUNT=$(field 'Block count')"
echo "T715_FREE_BLOCKS=$(field 'Free blocks')"
echo "T715_INODE_COUNT=$(field 'Inode count')"
echo "T715_FREE_INODES=$(field 'Free inodes')"
echo "T715_FEATURES=$(field 'Filesystem features')"
