#!/bin/bash
# setup-pacman.sh — step 1 of the Dockerfile (runs in the arm64 image tree).
# Adapted from omarchy-tab-s2/image/rootfs/setup-pacman.sh for an
# aarch64 base that Omarchy publishes for: here nothing is retagged, so the
# local repository keeps Omarchy's signatures (Optional TrustedOnly instead
# of the owner's Optional TrustAll).
#   - keep a pristine /etc/pacman.conf (restored by finalize.sh);
#   - no alpm sandbox, no download user, no free-space check under Docker;
#   - [t715-omarchy] (out/repo/aarch64, bind-mounted at /repo) before [core]
#     when /repo holds a repository (the Omarchy image; the base image builds
#     without it);
#   - ALARM keyring, plus Omarchy's signing key taken from the repository's
#     omarchy-keyring package, accepted only if it is the key pinned in
#     omarchy-trusted.fpr (pacman never fetches it from a keyserver);
#   - drop the kernel and linux-firmware (the image ships neither), full
#     upgrade.
set -euo pipefail

CONF=/etc/pacman.conf
PINNED=/t715/omarchy-trusted.fpr

die() { printf 'setup-pacman: %s\n' "$*" >&2; exit 1; }

[ -f "$PINNED" ] || die "no $PINNED"

cp -a "$CONF" /etc/pacman.conf.t715-orig

# Build time only: ALARM's geographic redirector (mirror.archlinuxarm.org) can
# send to a mirror that lags its own database (2026-11-24: va.us listed
# mesa-1:26.3.1-3 and answered 404 for it). Named mirrors first; finalize.sh
# puts ALARM's own mirrorlist back.
cp -a /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.t715-orig
{ printf 'Server = http://%s.mirror.archlinuxarm.org/$arch/$repo\n' de fl.us
  cat /etc/pacman.d/mirrorlist.t715-orig; } > /etc/pacman.d/mirrorlist

sed -i '/^\[options\]/a DisableSandbox' "$CONF"
sed -i -e 's/^CheckSpace/#CheckSpace/' -e 's/^DownloadUser/#DownloadUser/' "$CONF"

if [ -f /repo/t715-omarchy.db ]; then
    awk -v stanza='[t715-omarchy]
SigLevel = Optional TrustedOnly
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
fi

pacman-key --init
pacman-key --populate archlinuxarm

# Omarchy's signing key, from the repository's own keyring package: the only
# repository that carries it is our own copy, so this needs /repo.
keyring_pkg=""
for f in /repo/omarchy-keyring-*.pkg.tar.zst; do
    case "$f" in *.sig) continue ;; esac
    [ -f "$f" ] && keyring_pkg="$f"
done
if [ -f /repo/t715-omarchy.db ]; then
    [ -n "$keyring_pkg" ] || die "no omarchy-keyring package in /repo"
    kdir="$(mktemp -d)"
    bsdtar -xf "$keyring_pkg" -C "$kdir" usr/share/pacman/keyrings
    kr="$kdir/usr/share/pacman/keyrings"
    upstream_fprs="$(sed -n 's/^\([0-9A-F]\{40\}\):.*$/\1/p' "$kr/omarchy-trusted" | sort -u)"
    pinned_fprs="$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$PINNED" | grep -v '^$' | sort -u)"
    [ -n "$upstream_fprs" ] || die "omarchy-keyring trusts no key"
    for fpr in $upstream_fprs; do
        printf '%s\n' "$pinned_fprs" | grep -qx "$fpr" \
            || die "UNPINNED KEY $fpr in $(basename "$keyring_pkg") (omarchy-trusted.fpr)"
    done
    pacman-key --add "$kr/omarchy.gpg"
    for fpr in $upstream_fprs; do
        pacman-key --lsign-key "$fpr"
    done
    rm -rf "$kdir"
fi

pacman -Sy --noconfirm

# The kernel comes from the tablet's own build (its loader starts it); the
# image ships no kernel, no modules and no generic firmware.
kernel_pkgs="$(pacman -Qq | grep -E '^linux-(aarch64|armv7|firmware)' || true)"
if [ -n "$kernel_pkgs" ]; then
    # shellcheck disable=SC2086
    pacman -Rdd --noconfirm $kernel_pkgs
fi
rm -rf /usr/lib/modules

pacman -Syu --noconfirm
