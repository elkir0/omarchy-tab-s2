#!/bin/bash
# finalize.sh — step 5 of rootfs/Dockerfile: what ships carries no
# build-time state, and the build records become
# /usr/share/t715-omarchy/MANIFEST.image (tools/build-rootfs adds the file
# system figures and the smoke check to make out/rootfs-omarchy.MANIFEST).
set -euo pipefail

B=/usr/share/t715-omarchy/build
M=/usr/share/t715-omarchy/MANIFEST.image

die() { printf 'finalize: ERROR: %s\n' "$*" >&2; exit 1; }

# --- pacman.conf --------------------------------------------------------------
# ALARM's pristine file (saved by setup-pacman.sh: no DisableSandbox, CheckSpace
# and DownloadUser back), with a commented note on the local repository.
[ -f /etc/pacman.conf.t715-orig ] || die "no pristine pacman.conf"
awk -v stanza='# Omarchy (omarchy, omarchy-settings retagged armv7h, and the arch=any
# packages omarchy-keyring, omarchy-themes-intros, fonts, yaru-icon-theme, ...)
# came from the local repository [t715-omarchy] built by tools/repack-omarchy
# in image/out/repo/armv7h (docs/image/REPACK.md). It is not shipped in
# this image. To use it again, copy that directory to /repo and uncomment
# (keep it before [core]):
#[t715-omarchy]
#SigLevel = Optional TrustAll
#Server = file:///repo' '
    !done && /^\[core\]$/ { print stanza; print ""; done = 1 }
    { print }
' /etc/pacman.conf.t715-orig > /etc/pacman.conf
# Hyprland as tested with the dmabuf shim, and hyprgraphics as patched here: an
# upgrade waits for a new image. Its family goes with it, for the sonames.
# Not Quickshell: it follows Qt's private API, so it has to move with Qt.
sed -i 's/^#IgnorePkg .*/# t715: Hyprland stays as tested with the shim (docs\/image\/ROOTFS.md, "Installing software")\nIgnorePkg   = hypr* aquamarine xdg-desktop-portal-hyprland/' /etc/pacman.conf
chmod 0644 /etc/pacman.conf
rm -f /etc/pacman.conf.t715-orig
# With no kernel package nothing needs mkinitcpio, and omarchy update would ask
# about the orphan each time.
pacman -D --asexplicit mkinitcpio >/dev/null
rm -f /var/lib/pacman/sync/t715-omarchy.db /var/lib/pacman/sync/t715-omarchy.files
! grep -qE '^[[:space:]]*\[t715-omarchy\]' /etc/pacman.conf || die "active [t715-omarchy] stanza left"
! grep -qE '^[[:space:]]*DisableSandbox' /etc/pacman.conf || die "DisableSandbox left in pacman.conf"
grep -qE '^IgnorePkg +=.*hypr\*' /etc/pacman.conf || die "no IgnorePkg for Hyprland in pacman.conf"

# --- no kernel, no modules ----------------------------------------------------
kernel="$(pacman -Qq | grep -E '^linux' | grep -vx 'linux-api-headers' || true)"
[ -z "$kernel" ] || die "kernel or firmware packages installed: $(echo $kernel)"
rm -rf /usr/lib/modules
find /boot -mindepth 1 -delete 2>/dev/null || true

# --- space: documentation and unused translations (as the Phosh image) -------
rm -rf /usr/share/doc/* /usr/share/gtk-doc/*
find /usr/share/locale -mindepth 1 -maxdepth 1 -type d \
     ! -name 'en*' ! -name 'fr*' -exec rm -rf {} + 2>/dev/null || true

# --- per-machine and temporary state ------------------------------------------
# An empty machine-id: systemd makes a transient one at each boot without
# first-boot semantics (no systemd-firstboot prompts, no preset-all), which
# suits a RAM overlay.
: > /etc/machine-id
rm -f /var/lib/systemd/random-seed
# Pacman's hooks armed ConditionNeedsUpdate: without these stamps the tablet
# would rerun ldconfig and friends at every boot (~2 s on the sysinit path).
/usr/lib/systemd/systemd-update-done
[ -f /etc/.updated ] && [ -f /var/.updated ] || die "systemd-update-done wrote no stamps"
rm -rf /var/cache/pacman/pkg/* /tmp/* /var/tmp/* /root/.cache /root/.bash_history
rm -rf /run/user

# --- touch layer P2: the patch series is still in place --------------------------
# Step 4 ran Omarchy's setup after install-mobile.sh applied it: nothing may
# have changed a patched file since.
if [ -x /usr/bin/omamobile-omarchy-patches ]; then
    out="$(/usr/bin/omamobile-omarchy-patches verify 2>&1)" \
        || die "omamobile-omarchy-patches verify: $out"
    printf 'patches: verify at finalize\tok\t%s\n' "$out" >> "$B/mobile.tsv"
fi

# --- MANIFEST.image -------------------------------------------------------------
pkgver() { pacman -Q "$1" 2>/dev/null | cut -d' ' -f2 || true; }
tsv_count() { awk -F'\t' -v s="$2" '$2 == s' "$1" | wc -l; }
table() { column -t -s $'\t' "$1" | sed 's/^/  /'; }

base_tsv="$B/omarchy-base.tsv"
{
    echo "== Image tree (rootfs/finalize.sh, $(date -u '+%Y-%m-%d %H:%M:%S UTC')) =="
    echo "base:            t715-omarchy:base-armv7h (Arch Linux ARM armv7h tarball)"
    echo "hostname:        gts28lte-omarchy; $(sed -n 's/^T715_//p' /usr/share/t715-omarchy/locale.env | tr '\n' ' ')"
    echo "user:            $(cat "$B/alarm-id.txt" 2>/dev/null || id alarm)"
    echo
    echo "== Versions =="
    for p in omarchy omarchy-settings hyprland quickshell mesa sddm uwsm qt6-base \
             aquamarine xdg-desktop-portal-hyprland pipewire pipewire-audio wireplumber \
             squeekboard omamobile-shell omamobile-omarchy hyprgraphics bluez \
             networkmanager wpa_supplicant firefox systemd; do
        printf '  %-28s %s\n' "$p" "$(pkgver "$p")"
    done
    printf '  %-28s %s\n' "chromium (Debian)" \
        "$(awk '/^Package: chromium$/ {f=1} f && /^Version:/ {print $2; exit}' /var/lib/t715-chromium/root/var/lib/dpkg/status)"
    echo
    echo "== Packages =="
    echo "installed:       $(pacman -Q | wc -l)"
    echo "explicit:        $(pacman -Qe | wc -l)"
    echo
    echo "== Omarchy base list (/usr/share/omarchy/install/omarchy-base.packages) =="
    echo "entries:         $(wc -l < "$base_tsv")"
    echo "installed:       $(tsv_count "$base_tsv" installed)"
    echo "skipped by list: $(tsv_count "$base_tsv" skipped) (rootfs/packages.omarchy-skip)"
    echo "unavailable:     $(tsv_count "$base_tsv" unavailable) (not installable on armv7h)"
    echo "failed:          $(tsv_count "$base_tsv" failed)"
    echo
    echo "-- installed --"
    awk -F'\t' '$2 == "installed" {print $1}' "$base_tsv" | tr '\n' ' ' | fold -s -w 78 | sed 's/^/  /'
    echo
    echo "-- skipped by packages.omarchy-skip --"
    awk -F'\t' '$2 == "skipped" {print $1 "\t" $3}' "$base_tsv" > /tmp/t.tsv; table /tmp/t.tsv
    echo "-- unavailable on armv7h --"
    awk -F'\t' '$2 == "unavailable" {print $1 "\t" $3}' "$base_tsv" > /tmp/t.tsv; table /tmp/t.tsv
    if [ "$(tsv_count "$base_tsv" failed)" -gt 0 ]; then
        echo "-- failed --"
        awk -F'\t' '$2 == "failed" {print $1 "\t" $3}' "$base_tsv" > /tmp/t.tsv; table /tmp/t.tsv
    fi
    echo
    echo "== Extra packages (rootfs/packages.extra) =="
    table "$B/extras.tsv"
    echo
    echo "== Omarchy system setup leaves (install/{config,hardware,login,post-install}) =="
    echo "ok: $(tsv_count "$B/leaves-system.tsv" ok), skipped: $(tsv_count "$B/leaves-system.tsv" skipped), failed: $(grep -c $'\tfailed' "$B/leaves-system.tsv" || true)"
    table "$B/leaves-system.tsv"
    echo
    echo "== Omarchy user setup as alarm (omarchy-provision-user, install/user) and tablet settings =="
    table "$B/leaves-user.tsv"
    echo
    echo "== Touch layer P2 packages and Omarchy patches (rootfs/install-mobile.sh, packages.mobile) =="
    table "$B/mobile.tsv"
    echo
    echo "== Wi-Fi firmware and NVRAM (rootfs/install-wifi.sh) =="
    table "$B/wifi.tsv"
} > "$M"
rm -f /tmp/t.tsv
chmod 0644 "$M"
cat "$M"
