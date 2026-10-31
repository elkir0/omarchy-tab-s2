#!/bin/bash
# install-wifi.sh — step 3f of rootfs/Dockerfile: the BCM4358's Wi-Fi
# firmware and NVRAM for brcmfmac (docs/image/ROOTFS.md "Wi-Fi").
#   - brcm/brcmfmac4358-pcie.bin: the one file of ALARM's signed
#     linux-firmware-broadcom package that brcmfmac loads on this chip (the
#     linux-firmware build for the 4358 A3 ROM). pacman downloads the package
#     into its cache mount and checks its signature; the package itself is not
#     installed (the image ships no firmware package). Pinned by sha256: the
#     build stops on any other file.
#   - brcm/samsung-gts28/nvram_net.txt: the tablet's NVRAM (its MAC address
#     and radio calibration), staged read-only by tools/build-rootfs from the
#     Phosh session's dumps (never in git, never printed), with the name
#     brcmfmac asks for, brcmfmac4358-pcie.txt, linked to it.
# Records, for finalize.sh and the MANIFEST:
#   /usr/share/t715-omarchy/build/wifi.tsv   step, status, detail
set -euo pipefail

FW_PKG=linux-firmware-broadcom
FW_NAME=brcmfmac4358-pcie.bin
FW_SHA256=f04d8fdc0a0a301ccbbf543a2b470108c64ee341360f3450ed4fa9bbee04337c
NVRAM=/t715/wifi/nvram_net.txt
BRCM=/usr/lib/firmware/brcm
CACHE=/var/cache/pacman/pkg
B=/usr/share/t715-omarchy/build

die() { printf 'install-wifi: %s\n' "$*" >&2; exit 1; }

mkdir -p "$B"
[ -s "$NVRAM" ] || die "no $NVRAM (staged by tools/build-rootfs)"

# --- firmware, from the signed package ------------------------------------------
# -w: download only (the signature is checked); -dd: without its
# linux-firmware-whence dependency, which only holds the licence texts.
file="$(pacman -Sdd --print --print-format '%f' "$FW_PKG")" || die "$FW_PKG is not in the sync databases"
ver="$(pacman -Sdd --print --print-format '%v' "$FW_PKG")"
repo="$(pacman -Sdd --print --print-format '%r' "$FW_PKG")"
pacman -Swdd --noconfirm "$FW_PKG"
[ -f "$CACHE/$file" ] || die "pacman did not download $file"
install -d -m 0755 "$BRCM"
bsdtar -xOf "$CACHE/$file" "usr/lib/firmware/brcm/$FW_NAME" > "$BRCM/$FW_NAME.t715" \
    || die "no usr/lib/firmware/brcm/$FW_NAME in $file"
sha="$(sha256sum "$BRCM/$FW_NAME.t715" | cut -d' ' -f1)"
if [ "$sha" != "$FW_SHA256" ]; then
    rm -f "$BRCM/$FW_NAME.t715"
    die "$FW_NAME from $file: sha256 $sha, expected $FW_SHA256"
fi
mv -f "$BRCM/$FW_NAME.t715" "$BRCM/$FW_NAME"
chmod 0644 "$BRCM/$FW_NAME"
printf 'firmware: brcm/%s\tok\tfrom %s/%s %s (signed; the package is not installed), sha256 %s\n' \
    "$FW_NAME" "$repo" "$FW_PKG" "$ver" "$sha" > "$B/wifi.tsv"

# --- NVRAM ------------------------------------------------------------------------
install -D -m 0644 "$NVRAM" "$BRCM/samsung-gts28/nvram_net.txt"
ln -sfn samsung-gts28/nvram_net.txt "$BRCM/brcmfmac4358-pcie.txt"
printf 'nvram: brcm/samsung-gts28/nvram_net.txt\tok\tthe Phosh session'"'"'s dump (its sha256: the MANIFEST header); brcm/brcmfmac4358-pcie.txt -> samsung-gts28/nvram_net.txt\n' >> "$B/wifi.tsv"

echo "install-wifi: $FW_NAME ($FW_PKG $ver, sha256 ok) and the NVRAM installed"
