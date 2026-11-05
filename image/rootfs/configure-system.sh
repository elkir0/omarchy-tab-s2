#!/bin/bash
# configure-system.sh — step 4 of rootfs/Dockerfile (root, armv7h, qemu).
# Turns the installed packages into the SM-T715 Omarchy image:
#   overlay (USB debug link, SSH, SDDM, udev, journald, logind's lid drop-in,
#   the touch layer's t715-keys, squeekboard unit, OSK environment and fcitx5
#   drop-in, Bluetooth's t715-bt-addr and bt-agent drop-in, Wi-Fi's
#   t715-wifi-addr), locale and time zone,
#   accounts (alarm = Omarchy's user, root locked), the SSH key,
#   AQ_DRM_DEVICES, Omarchy's system setup leaves (omarchy-system-setup.sh),
#   units, SDDM autologin into omarchy.desktop, Omarchy's user setup and the
#   per-user tablet settings (omarchy-user-setup.sh), the smoke check.
# /etc/hostname and /etc/resolv.conf are Docker bind mounts during the build:
# rootfs/mkimage.sh writes them into the exported tree.
set -euo pipefail

export SYSTEMD_OFFLINE=1
B=/usr/share/t715-omarchy/build
U=alarm
SESSION=omarchy.desktop

log() { printf 'configure: %s\n' "$*"; }
die() { printf 'configure: ERROR: %s\n' "$*" >&2; exit 1; }

mkdir -p "$B"

# --- overlay ----------------------------------------------------------------
# File by file, so existing directories keep their modes (/etc/sudoers.d is
# 0750); the five USB-link files are byte-for-byte copies of the Phosh
# image's (rootfs/overlay/, checked by tests/verify-rootfs.sh).
log "overlay"
(cd /t715/overlay && find . -type f -print) | sort | while IFS= read -r f; do
    f="${f#./}"
    install -D -m "$(stat -c %a "/t715/overlay/$f")" "/t715/overlay/$f" "/$f"
done
chmod 0440 /etc/sudoers.d/10-wheel
visudo -c >/dev/null || die "sudoers do not parse"

# --- locale, time zone ------------------------------------------------------
# The values tools/build-rootfs wrote into the overlay (--locale, --timezone).
. /usr/share/t715-omarchy/locale.env
log "locales en_US.UTF-8 fr_FR.UTF-8 $T715_LANG, LANG=$T715_LANG, $T715_TZ"
sed -i -e 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' \
       -e 's/^#fr_FR.UTF-8 UTF-8/fr_FR.UTF-8 UTF-8/' \
       -e "s/^#$T715_LANG UTF-8/$T715_LANG UTF-8/" /etc/locale.gen
# glibc 2.43's locale.gen ends its lines with two spaces: match them too.
grep -qE "^${T715_LANG//./\\.} UTF-8[[:space:]]*\$" /etc/locale.gen || die "no locale $T715_LANG in /etc/locale.gen"
locale-gen
echo "LANG=$T715_LANG" > /etc/locale.conf
[ -e "/usr/share/zoneinfo/$T715_TZ" ] || die "no zoneinfo for $T715_TZ"
ln -sfn "/usr/share/zoneinfo/$T715_TZ" /etc/localtime
printf '%s\n' "$T715_TZ" > /etc/timezone

# --- accounts ---------------------------------------------------------------
# alarm (uid 1000, from the ALARM tarball) is Omarchy's user and keeps ALARM's
# documented default password "alarm"; root is locked (SSH uses the key).
log "accounts"
[ "$(id -u "$U")" = 1000 ] || die "$U is not uid 1000"
usermod -p '!' root
usermod -aG wheel,video,audio,input,network,radio "$U"

# alarm's home from the new /etc/skel (Omarchy's, from omarchy-settings),
# as useradd -m would create it.
rm -rf "/home/$U"
cp -a /etc/skel "/home/$U"
chmod 0700 "/home/$U"
chown -R "$U:$U" "/home/$U"

# --- SSH --------------------------------------------------------------------
log "SSH key for root and $U"
key=/t715/ssh/authorized_keys
! grep -q 'PRIVATE KEY' "$key" || die "the SSH key file is a private key"
install -d -m 0700 -o root -g root /root/.ssh
install -d -m 0700 -o "$U" -g "$U" "/home/$U/.ssh"
# A public image has no key: the initramfs installs media/0/linux/authorized_keys.
if [ -s "$key" ]; then
    install -m 0600 -o root -g root "$key" /root/.ssh/authorized_keys
    install -m 0600 -o "$U" -g "$U" "$key" "/home/$U/.ssh/authorized_keys"
fi

# --- display ----------------------------------------------------------------
# card0 = exynos-drm (panel), card1 = panfrost (render only): aquamarine must
# drive card0. Also in sddm.service.d/10-t715-aq-drm.conf (overlay) and in
# ~/.config/uwsm/env (omarchy-user-setup.sh).
log "AQ_DRM_DEVICES=/dev/dri/card0"
touch /etc/environment
sed -i '/^AQ_DRM_DEVICES=/d' /etc/environment
echo 'AQ_DRM_DEVICES=/dev/dri/card0' >> /etc/environment

# --- Omarchy's system setup -------------------------------------------------
log "Omarchy system setup leaves"
bash /t715/omarchy-system-setup.sh "$B/leaves-system.tsv"

# Groups Omarchy's setup records for the user (deferred-provisioning
# installs only; docker stays opt-in as in Omarchy).
if [ -s /var/lib/omarchy/provisioning/groups ]; then
    while IFS= read -r g; do
        [ -n "$g" ] && [ "$g" != docker ] && getent group "$g" >/dev/null \
            && usermod -aG "$g" "$U"
    done < /var/lib/omarchy/provisioning/groups
fi
id "$U" > "$B/alarm-id.txt"

# --- units ------------------------------------------------------------------
log "units"
systemctl enable usb-rndis.service sshd.service sddm.service t715-shutdown-log.service t715-pstore-shutdown.service
systemctl set-default graphical.target

# Touch layer P1 (docs/image/ROOTFS.md): the Power and Home keys and the cover,
# and the on-screen keyboard, for every user's graphical session
# (/etc/systemd/user/t715-{keys,squeekboard}.service from the overlay).
[ -x /usr/local/bin/t715-keys ] || die "no /usr/local/bin/t715-keys"
[ -x /usr/bin/squeekboard ] || die "no /usr/bin/squeekboard"
systemctl --global enable t715-keys.service t715-squeekboard.service t715-idle.service t715-update-check.timer

# Touch layer P2: omamobile-setup-user runs once, at build time, as alarm
# (omarchy-user-setup.sh). omamobile-shell also starts it at every login,
# before the compositor (graphical-session-pre.target), to pass package
# updates on to users. It stays masked to keep the session's start short:
# on a persistent root, a new package's steps are run by hand, as the user,
# with omamobile-setup-user.
systemctl --global mask omamobile-setup-user.service

# Omarchy's default theme asks for the Yaru-grey icons, which ALARM's
# yaru-icon-theme does not ship: GTK then falls back to hicolor and the Phone app
# loses its call, mute and tab icons.
[ -e /usr/share/icons/Yaru-grey ] || ln -s Yaru /usr/share/icons/Yaru-grey

# Modem (docs/hardware/MODEM.md): shannond's facade owns
# org.freedesktop.ModemManager1; modemmanager is here for mmcli only, and its
# daemon must never start (a D-Bus activation would take the name first).
systemctl mask ModemManager.service dbus-org.freedesktop.ModemManager1.service
# omatel-agent rings for calls and stores SMS: it runs for every desktop user.
systemctl --global enable omatel-agent.service

# Bluetooth (docs/image/ROOTFS.md "Bluetooth"): Omarchy's hardware/bluetooth.sh
# leaf enables bluetoothd; make sure of it. The controller's address comes
# from t715-bt-addr@hciN.service, pulled in by its udev rule (overlay).
systemctl enable bluetooth.service
[ -x /usr/local/sbin/t715-bt-addr ] || die "no /usr/local/sbin/t715-bt-addr"
command -v btmgmt >/dev/null || die "no btmgmt (bluez-utils), which t715-bt-addr needs"
# Omarchy's auto-accept pairing agent never starts: a condition drop-in
# (overlay, /etc/systemd/user/bt-agent.service.d), not a mask, which would
# make Omarchy's first-run `systemctl --user enable --now` fail.
[ -f /usr/lib/systemd/user/bt-agent.service ] \
    || die "no /usr/lib/systemd/user/bt-agent.service: check its drop-in still applies"

# Wi-Fi (docs/image/ROOTFS.md "Wi-Fi"): NetworkManager (enabled by Omarchy's
# enable-services.sh) drives brcmfmac through wpa_supplicant, which it starts
# over D-Bus; t715-wifi-addr is run by its udev rule (overlay).
[ -x /usr/local/sbin/t715-wifi-addr ] || die "no /usr/local/sbin/t715-wifi-addr"
command -v wpa_supplicant >/dev/null || die "no wpa_supplicant (NetworkManager's Wi-Fi backend)"

# ufw on, nothing in but SSH and DHCP on the USB cable: the rules are the
# overlay's /etc/ufw/user*.rules, written by ufw itself on the tablet.
# config/firewall.sh is skipped: it opens LocalSend and Docker, and it would
# leave usb0, the way in, closed.
[ -s /etc/ufw/user.rules ] && [ -s /etc/ufw/user6.rules ] || die "no ufw rules in the overlay"
sed -i 's/^ENABLED=.*/ENABLED=yes/' /etc/ufw/ufw.conf
systemctl enable ufw.service

# Omarchy's first-boot provisioning (user creation on tty1) must never run:
# the user exists already and it would hold tty1 before SDDM.
rm -f /var/lib/omarchy/provisioning/pending
ln -sfn /dev/null /etc/systemd/system/omarchy-provision-owner.service

# No suspend or hibernation: resume is untested on this kernel, and a hang
# that ends in a watchdog reset boot-loops the tablet into RECOVERY
# (docs/journal/COORDINATION.md).
systemctl mask sleep.target suspend.target hibernate.target \
    hybrid-sleep.target suspend-then-hibernate.target

# No Plymouth screen at shutdown: one hand-over of the display less while
# Hyprland exits.  A DRM commit that never completes after such hand-overs
# (exynos-drm "flip_done timed out") left black screens on 2026-10-29
# (docs/DEPLOY.md 13.); masking these did not stop it, but without a splash
# they only showed text.
systemctl mask plymouth-reboot.service plymouth-poweroff.service \
    plymouth-halt.service plymouth-kexec.service

# The image is read-only and every boot starts from it: periodic index and
# keyring jobs only cost CPU on the tablet and their results are lost at
# reboot (updatedb and mandb ran at build time).
systemctl mask plocate-updatedb.timer man-db.timer archlinux-keyring-wkd-sync.timer

# USERDATA stays mounted read-only at /run/t715/userdata: keep plocate's
# updatedb (Omarchy's post-install/localdb.sh, plocate-updatedb.timer) out of
# Android's files.
if [ -f /etc/updatedb.conf ] && ! grep -q '/run/t715' /etc/updatedb.conf; then
    sed -i 's|^PRUNEPATHS *= *"|&/run/t715 |' /etc/updatedb.conf
fi

# --- SDDM autologin ---------------------------------------------------------
# /etc/sddm.conf.d/autologin.conf comes from the overlay.
log "SDDM autologin: $U into $SESSION"
[ -f "/usr/local/share/wayland-sessions/$SESSION" ] \
    || [ -f "/usr/share/wayland-sessions/$SESSION" ] \
    || die "no $SESSION session file"
install -d -m 0750 -o sddm -g sddm /var/lib/sddm
printf '[Last]\nSession=%s\nUser=%s\n' "$SESSION" "$U" > /var/lib/sddm/state.conf
chown -R sddm:sddm /var/lib/sddm

# --- Omarchy's user setup and the tablet's per-user settings ----------------
log "Omarchy user setup as $U"
bash /t715/omarchy-user-setup.sh "$B/leaves-user.tsv"

# --- smoke check ------------------------------------------------------------
install -D -m 0755 /t715/smoke-check.sh /usr/lib/t715-omarchy/smoke-check

log "done"
