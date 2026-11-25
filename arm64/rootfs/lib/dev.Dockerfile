# dev.Dockerfile — the aarch64 Arch Linux ARM development container of this
# build: the official tarball's import, the ALARM keyring, a full upgrade and
# base-devel (makepkg, gcc, ...). Adapted from
# omarchy-tab-s2/image/lib/alarm-dev.Dockerfile (read-only).
#
# BASE is t715-arm64-port-rootfs/alarm (lib/common.sh, ensure_dev_image).
# Same pacman adaptations as the owner's: no alpm sandbox / download user /
# free-space check under Docker. Package signatures stay enforced.

ARG BASE=t715-arm64-port-rootfs/alarm
FROM ${BASE}

RUN <<'EOS'
set -eu
sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
sed -i -e 's/^CheckSpace/#CheckSpace/' -e 's/^DownloadUser/#DownloadUser/' \
       /etc/pacman.conf

pacman-key --init
pacman-key --populate archlinuxarm
pacman -Sy --noconfirm

# No kernel or generic firmware in a container: dropping them avoids
# mkinitcpio runs during the upgrade.
kernel_pkgs="$(pacman -Qq | grep -E '^linux-(aarch64|armv7|firmware)' || true)"
if [ -n "$kernel_pkgs" ]; then
    # shellcheck disable=SC2086
    pacman -Rdd --noconfirm $kernel_pkgs
fi

pacman -Syu --noconfirm --needed base-devel git
pacman -Scc --noconfirm >/dev/null 2>&1 || true
EOS
