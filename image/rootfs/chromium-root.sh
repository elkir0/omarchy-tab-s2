#!/bin/sh
# Stage chromium-root of rootfs/Dockerfile: Debian's Chromium and what it needs,
# in a root of its own. ALARM has no Chromium for armv7h.
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends chromium chromium-l10n \
    libegl1 libgles2 libgl1-mesa-dri mesa-libgallium libgbm1 libpulse0 dbus ca-certificates \
    fonts-dejavu-core fonts-noto-core fonts-noto-color-emoji
apt-get clean
rm -rf /var/lib/apt/lists/* /usr/share/doc/* /usr/share/man/* /usr/share/info/*
