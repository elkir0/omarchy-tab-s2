# Arch Linux ARM development image (aarch64 or armv7h) of the Omarchy track,
# copied from legacy/phosh/pkg/alarm-dev.Dockerfile. Used to
# repack and build packages (tools/) and to run the headless tests (tests/).
#
# BASE is a `docker import` of the official ALARM tarball for the target
# architecture (see lib/alarm.sh). Same pacman adaptations as the Phosh
# rootfs Dockerfile: no alpm sandbox / download user / free-space check under
# Docker (and qemu for armv7h). Package signatures stay enforced.

ARG BASE
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
