#!/bin/bash
# install-wifi.sh — the BCM4358's firmware, and a place for its two vendor
# files. Adapted from omarchy-tab-s2/image/rootfs/install-wifi.sh,
# which takes the vendor files from the tablet's dumps: this build never does.
#   - brcm/brcmfmac4358-pcie.bin: the one file of ALARM's signed
#     linux-firmware-broadcom package that brcmfmac loads on this chip.  pacman
#     downloads the package and checks its signature; the package itself is
#     not installed (the image ships no firmware package).  Pinned by sha256
#     (the owner's pin): the build stops on any other file.  Its licence,
#     LICENCE.broadcom_bcm43xx, which redistribution requires, comes from the
#     same package, at the same path as the package's.
#   - PLACEHOLDERS, never taken from the tablet's dumps (they hold its Wi-Fi
#     and Bluetooth addresses and Samsung firmware):
#       brcm/samsung-gts28/nvram_net.txt      the Wi-Fi NVRAM
#       brcm/BCM4358A3.hcd                    the Bluetooth patch RAM
#     The image only creates the links brcmfmac and hci_bcm ask for
#     (brcmfmac4358-pcie.txt, BCM.samsung,gts28ltexx.hcd).  The two files are
#     filled in either at the first boot, from the tablet's own SYSTEM
#     partition (t715-vendor-firmware.service), or by the owner at build time:
#     stage them in cache/vendor/ (nvram_net.txt, bcm4358A3_V0086.0144.hcd)
#     and they are installed, unread: only their sizes are recorded.
# Records, for finalize.sh and the MANIFEST:
#   /usr/share/t715-arm64/build/wifi.tsv   step, status, detail
set -euo pipefail

FW_PKG=linux-firmware-broadcom
FW_NAME=brcmfmac4358-pcie.bin
FW_SHA256=f04d8fdc0a0a301ccbbf543a2b470108c64ee341360f3450ed4fa9bbee04337c
STAGED=/t715/firmware
BRCM=/usr/lib/firmware/brcm
CACHE=/var/cache/pacman/pkg
B=/usr/share/t715-arm64/build

die() { printf 'install-wifi: %s\n' "$*" >&2; exit 1; }

mkdir -p "$B"
: > "$B/wifi.tsv"

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

# --- its licence, from the same package ---------------------------------------------
LIC="usr/share/licenses/$FW_PKG/LICENCE.broadcom_bcm43xx"
install -d -m 0755 "/${LIC%/*}"
bsdtar -xOf "$CACHE/$file" "$LIC" > "/$LIC" || die "no $LIC in $file"
[ -s "/$LIC" ] || die "$LIC is empty in $file"
chmod 0644 "/$LIC"
printf 'licence: /%s\tok\tfrom %s %s\n' "$LIC" "$FW_PKG" "$ver" >> "$B/wifi.tsv"
rm -f "$CACHE/$file"   # 20 MiB that serve no more

# --- the two vendor files: links now, files by placeholder ---------------------------
missing=""
install -d -m 0755 "$BRCM/samsung-gts28"
ln -sfn samsung-gts28/nvram_net.txt "$BRCM/brcmfmac4358-pcie.txt"
ln -sfn BCM4358A3.hcd "$BRCM/BCM.samsung,gts28ltexx.hcd"

if [ -s "$STAGED/nvram_net.txt" ]; then
    install -m 0644 "$STAGED/nvram_net.txt" "$BRCM/samsung-gts28/nvram_net.txt"
    printf 'nvram: brcm/samsung-gts28/nvram_net.txt\tstaged by the owner\t%s bytes; brcm/brcmfmac4358-pcie.txt -> samsung-gts28/nvram_net.txt\n' \
        "$(wc -c < "$BRCM/samsung-gts28/nvram_net.txt")" >> "$B/wifi.tsv"
else
    missing="$missing brcm/samsung-gts28/nvram_net.txt"
    printf 'nvram: brcm/samsung-gts28/nvram_net.txt\tMISSING\tplaceholder: copied at first boot from SYSTEM by t715-vendor-firmware.service\n' >> "$B/wifi.tsv"
fi
if [ -s "$STAGED/bcm4358A3_V0086.0144.hcd" ]; then
    install -m 0644 "$STAGED/bcm4358A3_V0086.0144.hcd" "$BRCM/BCM4358A3.hcd"
    printf 'patchram: brcm/BCM4358A3.hcd\tstaged by the owner\t%s bytes; brcm/BCM.samsung,gts28ltexx.hcd -> BCM4358A3.hcd\n' \
        "$(wc -c < "$BRCM/BCM4358A3.hcd")" >> "$B/wifi.tsv"
else
    missing="$missing brcm/BCM4358A3.hcd"
    printf 'patchram: brcm/BCM4358A3.hcd\tMISSING\tplaceholder: copied at first boot from SYSTEM by t715-vendor-firmware.service\n' >> "$B/wifi.tsv"
fi
if [ -n "$missing" ]; then
    # Read on the tablet: what the owner has to provide, and where.
    {
        echo "# PLACEHOLDER: this image lacks the tablet's vendor files (never taken from its dumps):"
        # shellcheck disable=SC2086
        for f in $missing; do echo "#   /usr/lib/firmware/$f"; done
        echo "# Either t715-vendor-firmware.service copies them at the first boot from the tablet's"
        echo "# SYSTEM partition, or they are staged in cache/vendor/ before tools/build (see docs)."
    } > /usr/share/t715-arm64/VENDOR-FILES-MISSING
fi
echo "install-wifi: $FW_NAME ($FW_PKG $ver, sha256 ok); vendor files missing:${missing:- none}"
