#!/bin/bash
# Write a boot image to BOOT or RECOVERY from the running Linux, over SSH
# (tablets without Android: no Download mode, no heimdall needed).
# Usage: write-part.sh BOOT|RECOVERY IMAGE
# The image is copied to /tmp, its sha256 checked, its size checked against
# the partition, written with dd (fsync), and read back after dropping the
# page cache.  Writes nothing but /dev/disk/by-partlabel/BOOT or RECOVERY.
set -eu
D=$(dirname "$0")
[ $# -eq 2 ] || { sed -n '2,7p' "$0"; exit 2; }
PART=$1 IMG=$2
case $PART in BOOT | RECOVERY) ;; *) echo "only BOOT or RECOVERY"; exit 2 ;; esac
[ -f "$IMG" ] || { echo "no image $IMG"; exit 2; }
[ "$(head -c 8 "$IMG")" = "ANDROID!" ] || { echo "$IMG is not a boot image"; exit 2; }
SZ=$(wc -c <"$IMG" | tr -d ' ')
SUM=$(shasum -a 256 "$IMG" | cut -d' ' -f1)
scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "$IMG" root@172.16.42.1:/tmp/t715-part.img
"$D/tssh" "set -e
d=\$(readlink -f /dev/disk/by-partlabel/$PART)
[ \"\$(sha256sum /tmp/t715-part.img | cut -d' ' -f1)\" = $SUM ] || { echo 'copy corrupted'; exit 1; }
[ $SZ -le \$((\$(cat /sys/class/block/\${d#/dev/}/size) * 512)) ] || { echo 'image larger than $PART'; exit 1; }
dd if=/tmp/t715-part.img of=\"\$d\" bs=1M conv=fsync status=none
rm -f /tmp/t715-part.img
sync
echo 3 >/proc/sys/vm/drop_caches
[ \"\$(head -c $SZ \"\$d\" | sha256sum | cut -d' ' -f1)\" = $SUM ] || { echo '$PART read back differs'; exit 1; }
echo \"$PART (\$d): written and read back, sha256 ${SUM:0:12}\""
