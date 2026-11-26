# syntax=docker/dockerfile:1
# Dockerfile — the aarch64 root images of the Galaxy Tab S2 8.0 LTE (SM-T715,
# Exynos 5433): the base image (target rootfs-base) and the Omarchy image
# (target rootfs-omarchy, built on the base). Arch Linux ARM aarch64, native
# arm64 containers on the Mac. Built by build.sh, which then exports each
# tree into a raw ext4 image (mkimage.sh); see arm64/docs/ROOTFS.md.
#
# Adapted from omarchy-tab-s2/image/rootfs/Dockerfile (the armv7h
# image). Everything that differs is marked "aarch64:".
#
# Inputs:
#   BASE                 t715-arm64-port-rootfs/alarm, the official ALARM aarch64
#                        tarball's import (lib/common.sh)
#   DEV                  t715-arm64-port-rootfs/dev (base-devel), only to
#                        compile in a separate stage: the image ships no compiler
#   build context        staged by build.sh in cache/context/: the step
#                        scripts, overlay/, overlay-omarchy/, packages.*,
#                        watchdog/ and shim/ (sources), user.env (the user,
#                        alarm by default), ssh/authorized_keys (--ssh-pubkey),
#                        omarchy-migrations.hold,
#                        firmware/ (vendor files staged by the owner, if any),
#                        repo-manifests/
#   named context        t715repo = out/repo/aarch64, the local [t715-omarchy]
#                        repository. It is bind-mounted at /repo only while
#                        pacman needs it: it never becomes part of the image.
#   cache mount          t715-arm64-port-rootfs-pkcache at /var/cache/pacman/pkg:
#                        the downloaded packages, shared by every build (BuildKit's
#                        cache: tools/docker-clean removes it).
# Every step bind-mounts only the files it uses, so editing a later step's
# script keeps the (slow) package layers cached.

ARG BASE=t715-arm64-port-rootfs/alarm
ARG DEV=t715-arm64-port-rootfs/dev

# ---------------------------------------------------------------------------
# 0. What needs a compiler, in the dev image: the watchdog keeper (static)
#    and Hyprland's dmabuf-check shim (the Omarchy image preloads it).
# ---------------------------------------------------------------------------
FROM ${DEV} AS compiled
RUN --mount=type=bind,source=watchdog/t715-watchdog-keeper.c,target=/src/t715-watchdog-keeper.c \
    mkdir -p /out \
 && gcc -O2 -Wall -Wextra -Werror -static -s \
        -o /out/t715-watchdog-keeper /src/t715-watchdog-keeper.c
RUN --mount=type=bind,source=shim/t715-dmabuf-check-shim.c,target=/src/t715-dmabuf-check-shim.c \
    gcc -O2 -Wall -Wextra -Werror -shared -fPIC \
        -o /out/t715-dmabuf-check-shim.so /src/t715-dmabuf-check-shim.c -ldl

# ===========================================================================
# The base image: boots to multi-user (rootfs-aarch64-base.img)
# ===========================================================================
FROM ${BASE} AS rootfs-base

# ---------------------------------------------------------------------------
# 1. pacman, keyrings, no kernel or linux-firmware, full upgrade. The local
#    repository is mounted (it may be absent: the base image needs none).
# ---------------------------------------------------------------------------
RUN --mount=type=bind,from=t715repo,target=/repo \
    --mount=type=cache,id=t715-arm64-port-rootfs-pkcache,target=/var/cache/pacman/pkg,sharing=locked \
    --mount=type=bind,source=setup-pacman.sh,target=/t715/setup-pacman.sh \
    --mount=type=bind,source=omarchy-trusted.fpr,target=/t715/omarchy-trusted.fpr \
    bash /t715/setup-pacman.sh

# ---------------------------------------------------------------------------
# 2. The base packages (packages.base). Every pacman step mounts the local
#    repository again: it is in pacman.conf from step 1 and pacman -Sy syncs it.
# ---------------------------------------------------------------------------
RUN --mount=type=bind,from=t715repo,target=/repo \
    --mount=type=cache,id=t715-arm64-port-rootfs-pkcache,target=/var/cache/pacman/pkg,sharing=locked \
    --mount=type=bind,source=install-base.sh,target=/t715/install-base.sh \
    --mount=type=bind,source=packages.base,target=/t715/packages.base \
    SYSTEMD_OFFLINE=1 bash /t715/install-base.sh

# ---------------------------------------------------------------------------
# 3. The watchdog keeper, compiled above.
# ---------------------------------------------------------------------------
COPY --from=compiled --chmod=0755 /out/t715-watchdog-keeper /usr/local/sbin/t715-watchdog-keeper

# ---------------------------------------------------------------------------
# 4. The Wi-Fi firmware from ALARM's signed package, and the links for the
#    two vendor files (placeholders: never taken from the tablet's dumps).
# ---------------------------------------------------------------------------
RUN --mount=type=bind,from=t715repo,target=/repo \
    --mount=type=cache,id=t715-arm64-port-rootfs-pkcache,target=/var/cache/pacman/pkg,sharing=locked \
    --mount=type=bind,source=install-wifi.sh,target=/t715/install-wifi.sh \
    --mount=type=bind,source=firmware,target=/t715/firmware \
    bash /t715/install-wifi.sh

# ---------------------------------------------------------------------------
# 5. Configuration: overlay/, locale and time zone, accounts (the placeholder
#    user), SSH key, fstab, units.
# ---------------------------------------------------------------------------
RUN --mount=type=bind,source=overlay,target=/t715/overlay \
    --mount=type=bind,source=ssh,target=/t715/ssh \
    --mount=type=bind,source=user.env,target=/t715/user.env \
    --mount=type=bind,source=configure-base.sh,target=/t715/configure-base.sh \
    bash /t715/configure-base.sh

# ---------------------------------------------------------------------------
# 6. Pristine pacman.conf, no build-time state, build records.
# ---------------------------------------------------------------------------
RUN --mount=type=bind,source=finalize.sh,target=/t715/finalize.sh \
    --mount=type=bind,source=smoke-check.sh,target=/t715/smoke-check.sh \
    --mount=type=bind,source=smoke-check-omarchy,target=/t715/smoke-check-omarchy \
    --mount=type=bind,source=user.env,target=/t715/user.env \
    --mount=type=bind,source=tarball-pin,target=/t715/tarball-pin \
    --mount=type=bind,source=repo-manifests,target=/t715/repo-manifests \
    --mount=type=bind,source=README.md,target=/t715/README.md \
    STAGE=base bash /t715/finalize.sh

# ===========================================================================
# The Omarchy image: Hyprland and the Omarchy shell (rootfs-aarch64-omarchy45.img)
# ===========================================================================
FROM rootfs-base AS rootfs-omarchy

# ---------------------------------------------------------------------------
# 7. Omarchy itself: omarchy 4.5.0-3 (Omarchy's own aarch64 package, as
#    published) pulls Hyprland, Quickshell, uwsm, SDDM, PipeWire,
#    omarchy-speedtest, ... and omarchy-settings (/etc/skel, the session file,
#    SDDM's Wayland greeter config; it provides omarchy-security-functions,
#    which omarchy 4.5 depends on), from the local repository.
# ---------------------------------------------------------------------------
RUN --mount=type=bind,from=t715repo,target=/repo \
    --mount=type=cache,id=t715-arm64-port-rootfs-pkcache,target=/var/cache/pacman/pkg,sharing=locked \
    --mount=type=bind,source=repo-on.sh,target=/t715/repo-on.sh \
    OMARCHY_ALLOW_DIRECT_PACMAN=1 bash -c 'bash /t715/repo-on.sh && pacman -Syu --needed --noconfirm omarchy omarchy-settings'

# ---------------------------------------------------------------------------
# 8. Omarchy's base package list minus packages.omarchy-skip, plus
#    packages.extra.
# ---------------------------------------------------------------------------
RUN --mount=type=bind,from=t715repo,target=/repo \
    --mount=type=cache,id=t715-arm64-port-rootfs-pkcache,target=/var/cache/pacman/pkg,sharing=locked \
    --mount=type=bind,source=repo-on.sh,target=/t715/repo-on.sh \
    --mount=type=bind,source=install-packages.sh,target=/t715/install-packages.sh \
    --mount=type=bind,source=packages.omarchy-skip,target=/t715/packages.omarchy-skip \
    --mount=type=bind,source=packages.extra,target=/t715/packages.extra \
    bash -c 'bash /t715/repo-on.sh && bash /t715/install-packages.sh'

# ---------------------------------------------------------------------------
# 9. The dmabuf-check shim, preloaded into Hyprland only by the
#    /usr/local/bin/Hyprland wrapper (overlay-omarchy): exynos-drm rejects
#    panfrost's buffers in Hyprland's linux-dmabuf check.
# ---------------------------------------------------------------------------
COPY --from=compiled --chmod=0755 /out/t715-dmabuf-check-shim.so /usr/local/lib/t715-dmabuf-check-shim.so

# ---------------------------------------------------------------------------
# 10. Theme backgrounds scaled to a 2048 px short side (vips): the shell
#     decodes them at full size, up to 7680x4320.
# ---------------------------------------------------------------------------
RUN --mount=type=bind,source=t715-wallpapers.sh,target=/t715/t715-wallpapers.sh \
    bash /t715/t715-wallpapers.sh

# ---------------------------------------------------------------------------
# 11. The touch layer (packages.mobile: pkg/'s packages and Omarchy Mobile's,
#     through [t715-omarchy]).
# ---------------------------------------------------------------------------
RUN --mount=type=bind,from=t715repo,target=/repo \
    --mount=type=cache,id=t715-arm64-port-rootfs-pkcache,target=/var/cache/pacman/pkg,sharing=locked \
    --mount=type=bind,source=repo-on.sh,target=/t715/repo-on.sh \
    --mount=type=bind,source=install-mobile.sh,target=/t715/install-mobile.sh \
    --mount=type=bind,source=packages.mobile,target=/t715/packages.mobile \
    bash -c 'bash /t715/repo-on.sh && bash /t715/install-mobile.sh'

# ---------------------------------------------------------------------------
# 12. Tablet and Omarchy configuration: overlay-omarchy/, the patches to
#     omarchy-settings (patches-omarchy-settings/), the accounts'
#     groups, AQ_DRM_DEVICES, Omarchy's system setup leaves, units, SDDM
#     autologin, Omarchy's user setup and the per-user tablet settings, the
#     migration hold list. ssh/ again: the user's home is made anew from
#     Omarchy's /etc/skel here, and gets the key again.
# ---------------------------------------------------------------------------
RUN --mount=type=bind,source=overlay-omarchy,target=/t715/overlay-omarchy \
    --mount=type=bind,source=patches-omarchy-settings,target=/t715/patches-omarchy-settings \
    --mount=type=bind,source=user.env,target=/t715/user.env \
    --mount=type=bind,source=ssh,target=/t715/ssh \
    --mount=type=bind,source=omarchy-migrations.hold,target=/t715/omarchy-migrations.hold \
    --mount=type=bind,source=configure-omarchy.sh,target=/t715/configure-omarchy.sh \
    --mount=type=bind,source=omarchy-system-setup.sh,target=/t715/omarchy-system-setup.sh \
    --mount=type=bind,source=omarchy-user-setup.sh,target=/t715/omarchy-user-setup.sh \
    --mount=type=bind,source=t715-looknfeel.lua,target=/t715/t715-looknfeel.lua \
    --mount=type=bind,source=t715-tablet.lua,target=/t715/t715-tablet.lua \
    bash /t715/configure-omarchy.sh

# ---------------------------------------------------------------------------
# 13. Pristine pacman.conf, no build-time state, build records.
# ---------------------------------------------------------------------------
RUN --mount=type=bind,source=finalize.sh,target=/t715/finalize.sh \
    --mount=type=bind,source=smoke-check.sh,target=/t715/smoke-check.sh \
    --mount=type=bind,source=smoke-check-omarchy,target=/t715/smoke-check-omarchy \
    --mount=type=bind,source=user.env,target=/t715/user.env \
    --mount=type=bind,source=tarball-pin,target=/t715/tarball-pin \
    --mount=type=bind,source=repo-manifests,target=/t715/repo-manifests \
    --mount=type=bind,source=README.md,target=/t715/README.md \
    STAGE=omarchy bash /t715/finalize.sh
