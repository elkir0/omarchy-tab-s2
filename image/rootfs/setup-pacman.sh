#!/bin/bash
# setup-pacman.sh — step 1 of rootfs/Dockerfile (runs in the armv7h image,
# under qemu on the Mac). Same pacman adaptations as the Phosh rootfs
# (legacy/phosh/Dockerfile), plus the local repository:
#   - keep a pristine /etc/pacman.conf (restored by finalize.sh);
#   - no alpm sandbox, no download user, no free-space check under qemu;
#   - [t715-omarchy] (out/repo/armv7h, bind-mounted at /repo) before [core],
#     SigLevel = Optional TrustAll (retagged packages are unsigned);
#   - ALARM keyring, plus Omarchy's signing key taken from the repository's
#     omarchy-keyring package, accepted only if it is the key pinned in
#     tools/omarchy-trusted.fpr (so pacman never fetches it from a keyserver);
#   - drop the kernel and linux-firmware (the rootfs ships neither), full
#     upgrade.
set -euo pipefail

CONF=/etc/pacman.conf
PINNED=/t715/omarchy-trusted.fpr

die() { printf 'setup-pacman: %s\n' "$*" >&2; exit 1; }

[ -f /repo/t715-omarchy.db ] || die "no /repo/t715-omarchy.db (local repository not mounted)"
[ -f "$PINNED" ] || die "no $PINNED"

cp -a "$CONF" /etc/pacman.conf.t715-orig

sed -i '/^\[options\]/a DisableSandbox' "$CONF"
sed -i -e 's/^CheckSpace/#CheckSpace/' -e 's/^DownloadUser/#DownloadUser/' "$CONF"

awk -v stanza='[t715-omarchy]
SigLevel = Optional TrustAll
Server = file:///repo' '
    !done && /^\[core\]$/ { print stanza; print ""; done = 1 }
    { print }
' "$CONF" > /tmp/pacman.conf.t715
cat /tmp/pacman.conf.t715 > "$CONF"
rm -f /tmp/pacman.conf.t715
repo_line="$(grep -n '^\[t715-omarchy\]$' "$CONF" | cut -d: -f1)"
core_line="$(grep -n '^\[core\]$' "$CONF" | head -n1 | cut -d: -f1)"
[ -n "$repo_line" ] && [ -n "$core_line" ] && [ "$repo_line" -lt "$core_line" ] \
    || die "could not declare [t715-omarchy] before [core]"

pacman-key --init
pacman-key --populate archlinuxarm

# Omarchy's signing key, from the repository's own keyring package.
keyring_pkg=""
for f in /repo/omarchy-keyring-*.pkg.tar.*; do
    case "$f" in *.sig) continue ;; esac
    [ -f "$f" ] && keyring_pkg="$f"
done
[ -n "$keyring_pkg" ] || die "no omarchy-keyring package in /repo"
kdir="$(mktemp -d)"
bsdtar -xf "$keyring_pkg" -C "$kdir" usr/share/pacman/keyrings
kr="$kdir/usr/share/pacman/keyrings"
upstream_fprs="$(sed -n 's/^\([0-9A-F]\{40\}\):.*$/\1/p' "$kr/omarchy-trusted" | sort -u)"
pinned_fprs="$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$PINNED" | grep -v '^$' | sort -u)"
[ -n "$upstream_fprs" ] || die "omarchy-keyring trusts no key"
for fpr in $upstream_fprs; do
    printf '%s\n' "$pinned_fprs" | grep -qx "$fpr" \
        || die "UNPINNED KEY $fpr in $(basename "$keyring_pkg") (see docs/image/REPACK.md)"
done
pacman-key --add "$kr/omarchy.gpg"
for fpr in $upstream_fprs; do
    pacman-key --lsign-key "$fpr"
done
rm -rf "$kdir"

pacman -Sy --noconfirm

# The kernel and the initramfs come from the Phosh session; the rootfs ships
# no kernel, no modules and no generic firmware.
kernel_pkgs="$(pacman -Qq | grep -E '^linux-(armv7|aarch64|firmware)' || true)"
if [ -n "$kernel_pkgs" ]; then
    # shellcheck disable=SC2086
    pacman -Rdd --noconfirm $kernel_pkgs
fi
rm -rf /usr/lib/modules

pacman -Syu --noconfirm
