#!/usr/bin/env bash
# Push the modem userspace to the tablet for a bring-up session (image mode:
# the root is a RAM overlay, so this runs after every boot).
#
#   device/modem-push.sh
#
# Copies modem/loader/build/shannon-loader-armv7, modem/shannond and
# modem/tools to /root/modem, makes the provisioned NV copy of the persistent
# root (read-only under /run/t715/userdata in image mode) appear at
# /var/lib/shannon, and sets the identity and firmware partitions read-only.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TSSH="$REPO_ROOT/device/tssh"

"$TSSH" 'for p in EFS m9kefs1 m9kefs2 m9kefs3 RADIO CDMA-RADIO PARAM; do blockdev --setro /dev/disk/by-partlabel/$p; done
mkdir -p /root/modem /var/lib/shannon
if [ -d /run/t715/userdata/omarchy/var/lib/shannon/nv ] && ! mountpoint -q /var/lib/shannon; then
    mount --bind -o ro /run/t715/userdata/omarchy/var/lib/shannon /var/lib/shannon
fi'
COPYFILE_DISABLE=1 tar --no-xattrs -C "$REPO_ROOT/modem" -cf - --exclude=__pycache__ --exclude='*.pyc' shannond tools loader/build/shannon-loader-armv7 audio |
    "$TSSH" 'tar -C /root/modem -xf - && ln -sf /root/modem/loader/build/shannon-loader-armv7 /root/modem/shannon-loader'
"$TSSH" 'cd /var/lib/shannon/nv && sha256sum -c manifest.sha256 && /root/modem/shannon-loader --version 2>/dev/null | head -1; ls /root/modem'
