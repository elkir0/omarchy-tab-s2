# rootfs/Dockerfile — Omarchy (Hyprland + the Omarchy shell) root file system
# for the Samsung Galaxy Tab S2 8.0 LTE (SM-T715, gts28lte), Arch Linux ARM
# armv7h. Built by tools/build-rootfs, which then exports the tree into a raw
# ext4 image; see docs/image/ROOTFS.md.
#
# Modelled on the Phosh image's Dockerfile (legacy/phosh/,
# read-only for this repository). Everything runs under qemu user emulation
# (docker --platform linux/arm/v7): the package steps take tens of minutes.
#
# Inputs:
#   BASE                 t715-omarchy:base-armv7h, the plain ALARM armv7
#                        tarball import (lib/alarm.sh)
#   DEV                  t715-omarchy:dev-armv7h (base-devel), only to
#                        compile shim/ in a separate stage: the image ships
#                        no compiler
#   build context        this directory, staged by tools/build-rootfs with
#                        ssh/authorized_keys (--ssh-pubkey),
#                        omarchy-trusted.fpr (tools/),
#                        firmware/bt/bcm4358A3_V0086.0144.hcd and
#                        firmware/wifi/nvram_net.txt (the Phosh session's
#                        vendor dumps, read-only, never in git)
#   named context        t715repo = out/repo/armv7h, the local [t715-omarchy]
#                        repository (tools/repack-omarchy). It is bind-mounted
#                        at /repo only while pacman needs it: it never becomes
#                        part of the image.
# Every step bind-mounts only the files it uses, so editing a later step's
# script keeps the (slow) package layers cached. Downloaded packages go to a
# BuildKit cache mount, not into the image.

ARG BASE=t715-omarchy:base-armv7h
ARG DEV=t715-omarchy:dev-armv7h

# ---------------------------------------------------------------------------
# 0. Hyprland's dmabuf-check shim (shim/, docs/journal/ONDEVICE-2026-10-28.md),
#    compiled in the dev image.
# ---------------------------------------------------------------------------
FROM ${DEV} AS shim
RUN --mount=type=bind,source=shim,target=/t715/shim \
    mkdir -p /out && \
    gcc -O2 -Wall -Wextra -Werror -shared -fPIC \
        -o /out/t715-dmabuf-check-shim.so /t715/shim/t715-dmabuf-check-shim.c -ldl

# ---------------------------------------------------------------------------
# 0b. Chromium's Debian root (chromium-root.sh, pkg/t715-chromium), copied into
#     the image at step 3b. ALARM has no Chromium for armv7h.
# ---------------------------------------------------------------------------
FROM debian:trixie-slim AS chromium-root
RUN --mount=type=bind,source=chromium-root.sh,target=/t715/chromium-root.sh \
    sh /t715/chromium-root.sh

FROM ${BASE}

# ---------------------------------------------------------------------------
# 1. pacman under qemu, keyrings, [t715-omarchy] before [core], no kernel or
#    linux-firmware, full upgrade.
# ---------------------------------------------------------------------------
RUN --mount=type=bind,from=t715repo,target=/repo \
    --mount=type=cache,id=t715-omarchy-pacman-armv7h,target=/var/cache/pacman/pkg,sharing=locked \
    --mount=type=bind,source=setup-pacman.sh,target=/t715/setup-pacman.sh \
    --mount=type=bind,source=omarchy-trusted.fpr,target=/t715/omarchy-trusted.fpr \
    bash /t715/setup-pacman.sh

# ---------------------------------------------------------------------------
# 2. Omarchy itself: omarchy (4.0.6-1.1, retagged armv7h) pulls Hyprland,
#    Quickshell, uwsm, SDDM, PipeWire, ... and omarchy-settings (/etc/skel,
#    the session file, SDDM's Wayland greeter config).
# ---------------------------------------------------------------------------
RUN --mount=type=bind,from=t715repo,target=/repo \
    --mount=type=cache,id=t715-omarchy-pacman-armv7h,target=/var/cache/pacman/pkg,sharing=locked \
    OMARCHY_ALLOW_DIRECT_PACMAN=1 \
    pacman -Syu --needed --noconfirm omarchy omarchy-settings

# ---------------------------------------------------------------------------
# 3. Omarchy's base package list minus packages.omarchy-skip, plus
#    packages.extra.
# ---------------------------------------------------------------------------
RUN --mount=type=bind,from=t715repo,target=/repo \
    --mount=type=cache,id=t715-omarchy-pacman-armv7h,target=/var/cache/pacman/pkg,sharing=locked \
    --mount=type=bind,source=install-packages.sh,target=/t715/install-packages.sh \
    --mount=type=bind,source=packages.omarchy-skip,target=/t715/packages.omarchy-skip \
    --mount=type=bind,source=packages.extra,target=/t715/packages.extra \
    bash /t715/install-packages.sh

# ---------------------------------------------------------------------------
# 3b. The shim, preloaded into Hyprland only by the /usr/local/bin/Hyprland
#     wrapper (overlay): exynos-drm rejects panfrost's buffers in Hyprland's
#     linux-dmabuf check, which killed every GPU client.
# ---------------------------------------------------------------------------
COPY --from=shim --chmod=0755 /out/t715-dmabuf-check-shim.so /usr/local/lib/t715-dmabuf-check-shim.so

# ---------------------------------------------------------------------------
# 3c. Theme backgrounds scaled to a 2048 px short side (vips): the shell
#     decodes them at full size, up to 7680x4320.
# ---------------------------------------------------------------------------
RUN --mount=type=bind,source=t715-wallpapers.sh,target=/t715/t715-wallpapers.sh \
    bash /t715/t715-wallpapers.sh

# ---------------------------------------------------------------------------
# 3d. Touch layer P2 (docs/image/ROOTFS.md): omamobile-omarchy and omamobile-shell
#     (packages.mobile, from pkg/ through [t715-omarchy]); the first one's
#     pacman hook applies its Omarchy patch series, install-mobile.sh checks
#     it. Its own step, so that the slow package layers above stay cached.
# ---------------------------------------------------------------------------
RUN --mount=type=bind,from=t715repo,target=/repo \
    --mount=type=cache,id=t715-omarchy-pacman-armv7h,target=/var/cache/pacman/pkg,sharing=locked \
    --mount=type=bind,source=install-mobile.sh,target=/t715/install-mobile.sh \
    --mount=type=bind,source=packages.mobile,target=/t715/packages.mobile \
    bash /t715/install-mobile.sh

# ---------------------------------------------------------------------------
# 3e. Bluetooth patch RAM for the BCM4358 (docs/image/ROOTFS.md "Bluetooth"),
#     staged by tools/build-rootfs from the Phosh session's vendor dump
#     (never in git). Installed as the Phosh image installs it: btbcm finds
#     no chip name for this LMP subversion and asks for
#     brcm/BCM.<board compatible>.hcd.
# ---------------------------------------------------------------------------
RUN --mount=type=bind,source=firmware/bt,target=/t715/firmware/bt \
    install -d /usr/lib/firmware/brcm && \
    { [ ! -f /t715/firmware/bt/bcm4358A3_V0086.0144.hcd ] || install -m0644 /t715/firmware/bt/bcm4358A3_V0086.0144.hcd /usr/lib/firmware/brcm/BCM4358A3.hcd; } && \
    { [ ! -f /t715/firmware/bt/bcm4358A3_V0086.0144.hcd ] || install -m0644 /t715/firmware/bt/bcm4358A3_V0086.0144.hcd /usr/lib/firmware/brcm/bcm4358A3_V0086.0144.hcd; } && \
    ln -sfn BCM4358A3.hcd '/usr/lib/firmware/brcm/BCM.samsung,gts28ltexx.hcd'

# ---------------------------------------------------------------------------
# 3f. Wi-Fi firmware and NVRAM for brcmfmac (docs/image/ROOTFS.md "Wi-Fi"):
#     brcmfmac4358-pcie.bin taken from ALARM's signed linux-firmware-broadcom
#     package (pinned by sha256, the package not installed), and the NVRAM
#     staged by tools/build-rootfs from the Phosh session's dumps.
# ---------------------------------------------------------------------------
RUN --mount=type=cache,id=t715-omarchy-pacman-armv7h,target=/var/cache/pacman/pkg,sharing=locked \
    --mount=type=bind,source=firmware/wifi,target=/t715/wifi \
    --mount=type=bind,source=install-wifi.sh,target=/t715/install-wifi.sh \
    bash /t715/install-wifi.sh

# ---------------------------------------------------------------------------
# 3b. Chromium's root. Not in a package: apt keeps it up to date on the tablet.
# ---------------------------------------------------------------------------
COPY --from=chromium-root / /var/lib/t715-chromium/root/
RUN /usr/lib/t715-chromium/prepare-root

# ---------------------------------------------------------------------------
# 4. Tablet and Omarchy configuration: overlay (USB debug link, SSH, SDDM,
#    the touch layer's t715-keys, squeekboard and OSK files, Bluetooth's
#    t715-bt-addr, Wi-Fi's t715-wifi-addr),
#    locale/time zone, accounts, SSH key, Omarchy's system setup leaves,
#    units, SDDM autologin, Omarchy's user setup as alarm, scale 2, the
#    tablet Lua blocks, touch layer P2's omamobile-setup-user.
# ---------------------------------------------------------------------------
RUN --mount=type=bind,source=overlay,target=/t715/overlay \
    --mount=type=bind,source=ssh,target=/t715/ssh \
    --mount=type=bind,source=configure-system.sh,target=/t715/configure-system.sh \
    --mount=type=bind,source=omarchy-system-setup.sh,target=/t715/omarchy-system-setup.sh \
    --mount=type=bind,source=omarchy-user-setup.sh,target=/t715/omarchy-user-setup.sh \
    --mount=type=bind,source=t715-looknfeel.lua,target=/t715/t715-looknfeel.lua \
    --mount=type=bind,source=t715-tablet.lua,target=/t715/t715-tablet.lua \
    --mount=type=bind,source=smoke-check.sh,target=/t715/smoke-check.sh \
    bash /t715/configure-system.sh

# ---------------------------------------------------------------------------
# 5. Pristine pacman.conf, no build-time state, build records.
# ---------------------------------------------------------------------------
RUN --mount=type=bind,source=finalize.sh,target=/t715/finalize.sh \
    bash /t715/finalize.sh
