#!/bin/bash
# finalize.sh — the last step of each Dockerfile target: what ships carries no
# build-time state, and the build records become /usr/share/t715-arm64/
# MANIFEST.image (build.sh adds the file system figures and the smoke check).
# Adapted from omarchy-tab-s2/image/rootfs/finalize.sh.
#
# Environment: STAGE=base | STAGE (which image this tree becomes).
set -euo pipefail

STAGE="${STAGE:?STAGE=base or STAGE=omarchy}"
case "$STAGE" in
    base)    IMAGE_NAME=rootfs-aarch64-base.img ;;
    omarchy) IMAGE_NAME=rootfs-aarch64-omarchy45.img ;;
    *) printf 'finalize: ERROR: unknown STAGE %s\n' "$STAGE" >&2; exit 1 ;;
esac
B=/usr/share/t715-arm64/build
M=/usr/share/t715-arm64/MANIFEST.image
S=/usr/share/t715-arm64
. /t715/user.env

die() { printf 'finalize: ERROR: %s\n' "$*" >&2; exit 1; }

# --- mirrorlist: ALARM's own (setup-pacman.sh put named mirrors first for the build)
if [ -f /etc/pacman.d/mirrorlist.t715-orig ]; then
    mv -f /etc/pacman.d/mirrorlist.t715-orig /etc/pacman.d/mirrorlist
fi

# --- pacman.conf --------------------------------------------------------------
# ALARM's pristine file (saved by setup-pacman.sh: no DisableSandbox, CheckSpace
# and DownloadUser back), with commented notes on Omarchy's packages.
[ -f /etc/pacman.conf.t715-orig ] || die "no pristine pacman.conf"
awk -v stanza='# Omarchy (omarchy, omarchy-settings, omarchy-speedtest, omarchy-keyring, ...),
# Omarchy Mobile'"'"'s omamobile-settings, omamobile-remote and wlrctl, and the
# packages built for this tablet (omamobile-omarchy, omamobile-shell,
# omatel-agent, hyprgraphics) came from the local repository [t715-omarchy] of
# the image build, holding Omarchy'"'"'s and Omarchy Mobile'"'"'s own aarch64
# packages exactly as published (verified against their keys and pins). It is
# not shipped in this image. To use it again, copy that directory to /repo and
# uncomment (keep it before [core]: pacman takes a name from the first
# repository that has it):
#[t715-omarchy]
#SigLevel = Optional TrustedOnly
#Server = file:///repo

# Omarchy'"'"'s stable channel for aarch64: active at the END of this file
# (since 2026-11-25), so that a name Arch Linux ARM also carries stays Arch
# Linux ARM'"'"'s; listed here, before [core], it would win over them. This image
# runs Omarchy 4.5.0-3, the version Omarchy Mobile'"'"'s touch patches are
# checked against: IgnorePkg below keeps it there. (Omarchy Mobile'"'"'s own repository,
# https://pkgs.omamobile.org/stable/aarch64, is signed by keys pacman here
# does not hold: its packages are the phone'"'"'s, not this tablet'"'"'s.)
#[omarchy]
#SigLevel = Required DatabaseOptional
#Server = https://pkgs.omarchy.org/stable/aarch64' '
    !done && /^\[core\]$/ { print stanza; print ""; done = 1 }
    { print }
' /etc/pacman.conf.t715-orig > /etc/pacman.conf
# The omarchy stage starts from the base image, already finalized: its "pristine" file
# has the notes already. Keep one copy (the first), not two.
if [ "$(grep -c '^#\[t715-omarchy\]$' /etc/pacman.conf)" -gt 1 ]; then
    awk '/^# Omarchy \(omarchy, omarchy-settings/ { n++ } n == 2 && !end { if (/^\[core\]$/) { end = 1; print; } next } { print }' \
        /etc/pacman.conf > /etc/pacman.conf.dedup && cat /etc/pacman.conf.dedup > /etc/pacman.conf && rm -f /etc/pacman.conf.dedup
fi
if [ "$STAGE" = omarchy ]; then
    # Hyprland as tested with the dmabuf shim and the rebuilt hyprgraphics: an
    # upgrade waits for a new image. Its family goes with it, for the sonames.
    sed -i 's/^#IgnorePkg .*/# t715: Hyprland and its family stay as tested with the shim and the rebuilt\n# hyprgraphics; Omarchy stays at the pinned 4.5.0-3 (the touch patches are\n# checked against it); the touch layer and Omarchy Mobile'"'"'s packages are this\n# image'"'"'s own builds or verified copies, which no repository here carries\nIgnorePkg   = hypr* aquamarine xdg-desktop-portal-hyprland omarchy omarchy-settings omarchy-speedtest omarchy-keyring omamobile-omarchy omamobile-shell omamobile-settings omamobile-remote omamobile-voice wlrctl omatel-agent voxtype-bin/' /etc/pacman.conf
fi
if [ "$STAGE" = omarchy ] && ! grep -q '^\[omarchy\]$' /etc/pacman.conf; then
    # Omarchy's aarch64 channel, active, after Arch Linux ARM's repositories: what only
    # Omarchy ships (claude-code, yay, ...) comes from it, in Omarchy's package manager too;
    # IgnorePkg holds Omarchy, Hyprland and the touch layer at the tested versions.
    cat >> /etc/pacman.conf <<'OMARCHY'

# t715: Omarchy's aarch64 channel, after Arch Linux ARM's repositories (a name both
# carry stays Arch Linux ARM's: pacman takes a name from the first repository that has
# it). IgnorePkg above holds Omarchy, Hyprland and the touch layer at the tested versions.
[omarchy]
SigLevel = Required DatabaseOptional
Server = https://pkgs.omarchy.org/stable/aarch64
OMARCHY
fi
chmod 0644 /etc/pacman.conf
rm -f /etc/pacman.conf.t715-orig
rm -f /var/lib/pacman/sync/t715-omarchy.db /var/lib/pacman/sync/t715-omarchy.files
! grep -qE '^[[:space:]]*\[t715-omarchy\]' /etc/pacman.conf || die "active [t715-omarchy] stanza left"
! grep -qE '^[[:space:]]*DisableSandbox' /etc/pacman.conf || die "DisableSandbox left in pacman.conf"
# ALARM's file has CheckSpace (and DownloadUser, commented): the build's
# "under Docker" lines must be gone.
! grep -qE '^[[:space:]]*#(CheckSpace)' /etc/pacman.conf || die "CheckSpace is still commented out in pacman.conf"
if [ "$STAGE" = omarchy ]; then
    grep -qE '^IgnorePkg +=.*hypr\*' /etc/pacman.conf || die "no IgnorePkg for Hyprland in pacman.conf"
    grep -qE '^IgnorePkg +=.* voxtype-bin( |$)' /etc/pacman.conf || die "no IgnorePkg for voxtype-bin (ARMv8.0 build) in pacman.conf"
    [ "$(grep -c '^\[omarchy\]$' /etc/pacman.conf)" = 1 ] || die "not exactly one active [omarchy] in pacman.conf"
    [ "$(grep -c '^#\[t715-omarchy\]$' /etc/pacman.conf)" = 1 ] || die "the notes on Omarchy's packages are not there exactly once"
    awk '/^\[(core|extra|alarm|aur)\]$/ { last = NR } /^\[omarchy\]$/ { om = NR } END { exit !(om > last) }' /etc/pacman.conf \
        || die "[omarchy] is not after Arch Linux ARM's repositories"
fi

# --- what the build left as orphans stays ---------------------------------------
# `omarchy update` removes orphans (omarchy-update-orphan-pkgs). Whatever the
# build left installed as an unrequired dependency is wanted on the tablet:
# the owner's Lenovomarchy tablet lost its Wi-Fi firmware and diffutils at its
# first update that way (2026-11-18). Marked explicit.
orphans="$(pacman -Qdtq 2>/dev/null || true)"
if [ -n "$orphans" ]; then
    # shellcheck disable=SC2086
    pacman -D --asexplicit $orphans >/dev/null
fi
printf 'orphans marked explicit\t%s\t%s\n' "$(printf '%s\n' "$orphans" | grep -c . || true)" "$(echo $orphans)" > "$B/orphans.tsv"

# --- no kernel, no modules ----------------------------------------------------
kernel="$(pacman -Qq | grep -E '^linux' | grep -vx 'linux-api-headers' || true)"
[ -z "$kernel" ] || die "kernel or firmware packages installed: $(echo $kernel)"
rm -rf /usr/lib/modules
# /boot stays, empty: the kernel lives in the tablet's CACHE partition.
find /boot -mindepth 1 -delete 2>/dev/null || true

# --- space: documentation and unused translations (as the owner's image) -------
rm -rf /usr/share/doc/* /usr/share/gtk-doc/*
lang_prefix="${T715_LANG%%_*}"
find /usr/share/locale -mindepth 1 -maxdepth 1 -type d \
     ! -name 'en*' ! -name "$lang_prefix*" -exec rm -rf {} + 2>/dev/null || true

# --- per-machine and temporary state ------------------------------------------
# An empty machine-id: systemd makes a transient one at each boot without
# first-boot semantics (no systemd-firstboot prompts, no preset-all).
: > /etc/machine-id
rm -f /var/lib/systemd/random-seed
# Pacman's hooks armed ConditionNeedsUpdate: without these stamps the tablet
# would rerun ldconfig and friends at every boot.
/usr/lib/systemd/systemd-update-done
[ -f /etc/.updated ] && [ -f /var/.updated ] || die "systemd-update-done wrote no stamps"
rm -rf /var/cache/pacman/pkg/* /tmp/* /var/tmp/* /root/.cache /root/.bash_history /root/.gnupg/random_seed 2>/dev/null || true
rm -rf /run/user /run/systemd 2>/dev/null || true
# No SSH host key, no log of the build: the first start of sshd makes its keys.
rm -f /etc/ssh/ssh_host_* 2>/dev/null || true
find /var/log -mindepth 1 -delete 2>/dev/null || true
mkdir -p /var/log/journal

# --- what ships with the image ---------------------------------------------------
install -D -m 0755 /t715/smoke-check.sh /usr/lib/t715-arm64/smoke-check
[ ! -f /t715/smoke-check-omarchy ] || install -D -m 0644 /t715/smoke-check-omarchy /usr/lib/t715-arm64/smoke-check-omarchy
install -D -m 0644 /t715/README.md /usr/share/doc/t715-arm64/README.md
# The user's name, for the smoke check and whoever looks.
printf 'T715_USER=%s\nT715_LANG=%s\nT715_TZ=%s\n' "$T715_USER" "$T715_LANG" "$T715_TZ" > "$S/user.env"
chmod 0644 "$S/user.env"
printf 'image: %s (%s)\nbuilt: %s\narch: aarch64\n' "$IMAGE_NAME" "$STAGE" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" > "$S/IMAGE"

# --- MANIFEST.image -------------------------------------------------------------
pkgver() { pacman -Q "$1" 2>/dev/null | cut -d' ' -f2 || true; }
tsv_count() { [ -f "$1" ] && awk -F'\t' -v s="$2" '$2 == s' "$1" | wc -l | tr -d ' ' || echo 0; }
table() { [ -f "$1" ] && column -t -s $'\t' "$1" | sed 's/^/  /'; }

{
    echo "== Image tree ($STAGE, rootfs/finalize.sh, $(date -u '+%Y-%m-%d %H:%M:%S UTC')) =="
    echo "image:           $IMAGE_NAME"
    echo "base:            Arch Linux ARM aarch64 tarball ($(sed -n '/^[0-9a-f]\{64\}/p' /t715/tarball-pin | awk '{print "sha256 " $1 ", " $2}'))"
    echo "user:            $(id "$T715_USER")"
    echo "LANG=$T715_LANG, $T715_TZ"
    echo
    echo "== Versions =="
    for p in systemd pacman openssh networkmanager wpa_supplicant sudo; do
        printf '  %-28s %s\n' "$p" "$(pkgver "$p")"
    done
    for p in omarchy omarchy-settings hyprland quickshell mesa sddm uwsm aquamarine hyprgraphics \
             xdg-desktop-portal-hyprland pipewire pipewire-audio wireplumber squeekboard \
             omamobile-shell omamobile-omarchy omatel-agent omamobile-settings omamobile-remote wlrctl \
             omarchy-speedtest bluez firefox chromium systemd; do
        pacman -Q "$p" >/dev/null 2>&1 || continue
        printf '  %-28s %s\n' "$p" "$(pkgver "$p")"
    done
    echo
    echo "== Packages =="
    echo "installed:       $(pacman -Q | wc -l)"
    echo "explicit:        $(pacman -Qe | wc -l)"
    echo
    echo "== Omarchy's packages as imported, and the packages rebuilt for this image =="
    for m in /t715/repo-manifests/*.tsv; do
        [ -f "$m" ] || continue
        echo "-- $(basename "$m") --"
        table "$m"
    done
    echo
    echo "== The image's own configuration (configure-base.sh) =="
    table "$B/base.tsv"
    echo
    echo "== Wi-Fi firmware and the vendor files' placeholders (install-wifi.sh) =="
    table "$B/wifi.tsv"
    for t in omarchy-base omarchy extras omarchy mobile omarchy-system omarchy-user orphans; do
        [ -f "$B/$t.tsv" ] || continue
        echo
        case "$t" in
            omarchy-base) echo "== Omarchy's base list (install/omarchy-base.packages) ==" ;;
            extras)       echo "== Extra packages (packages.extra) ==" ;;
            omarchy)      echo "== Omarchy itself ==" ;;
            mobile)       echo "== Touch layer (packages.mobile) ==" ;;
            omarchy-system) echo "== Omarchy's system setup leaves ==" ;;
            omarchy-user)   echo "== Omarchy's user setup and the tablet settings ==" ;;
            orphans)        echo "== Build orphans marked explicit (omarchy update removes orphans) ==" ;;
        esac
        table "$B/$t.tsv"
    done
} > "$M"
chmod 0644 "$M"
cat "$M"
