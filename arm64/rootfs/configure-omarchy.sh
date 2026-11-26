#!/bin/bash
# configure-omarchy.sh — step 12 of the Dockerfile, the Omarchy image: what
# the base image's configure-base.sh did for a system that boots, done again
# for the desktop: the touch layer's overlay, SDDM autologin, Omarchy's
# system setup leaves, units, the firewall, Omarchy's user setup and the
# per-user tablet settings.
#
# Adapted from omarchy-tab-s2/image/rootfs/configure-system.sh
# (read-only): its second half, after "display". Left out of it, and why:
#   t715-power-profile, t715-power-guard, 60-t715-big-cores.rules   they scale
#     CPU and GPU frequencies or take cores offline: the kernel's business
#     under the owner's rules (CPUFREQ.md), and the arm64 kernel has none of
#     it yet; power-profiles-daemon is not installed either;
#   t715-sleep, t715-sleep-prepare, t715-sleep-restore   suspend to RAM has no
#     arm64 kernel support yet, and the watchdog runs: sleep targets stay masked;
#   t715-wifi-guard, 60-t715-wifi-aspm.rules, modprobe.d/t715-brcmfmac.conf
#     written for the arm32 kernel's brcmfmac and regulators: to be ported
#     with Wi-Fi itself;
#   omatel-agent.service stays (omamobile-shell depends on the agent).
set -euo pipefail

export SYSTEMD_OFFLINE=1
B=/usr/share/t715-arm64/build
S=/usr/share/t715-omarchy
. /t715/user.env
U="$T715_USER"
SESSION=omarchy.desktop

log() { printf 'configure-omarchy: %s\n' "$*"; }
die() { printf 'configure-omarchy: ERROR: %s\n' "$*" >&2; exit 1; }
record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$B/omarchy.tsv"; }

mkdir -p "$B"
: > "$B/omarchy.tsv"
[ "$(id -u "$U")" = 1000 ] || die "$U is not uid 1000 (configure-base.sh did not run)"
pacman -Q omarchy >/dev/null 2>&1 || die "omarchy is not installed"

# --- overlay-omarchy --------------------------------------------------------
log "overlay-omarchy"
(cd /t715/overlay-omarchy && find . -type f -print) | sort | while IFS= read -r f; do
    f="${f#./}"
    install -D -m "$(stat -c %a "/t715/overlay-omarchy/$f")" "/t715/overlay-omarchy/$f" "/$f"
done
record "overlay-omarchy" ok "$(find /t715/overlay-omarchy -type f | wc -l) files"

# The image's language, time zone and first keyboard layout (the on-screen
# keyboard's), for omarchy-user-setup.sh.
install -d -m 0755 "$S"
printf 'T715_LANG=%s\nT715_TZ=%s\nT715_XKB=us\n' "$T715_LANG" "$T715_TZ" > "$S/locale.env"
chmod 0644 "$S/locale.env"

# --- display ----------------------------------------------------------------
# Aquamarine must drive exynos-drm (the panel), not panfrost (render only). By
# path, not by number: on the 32-bit kernel exynos-drm is card0, on arm64 the
# probe order makes panfrost card0 and exynos-drm card1 (card0 there: Hyprland
# "CBackend::create() failed!", tablet 2026-11-25). Also in
# sddm.service.d/10-t715-aq-drm.conf (overlay-omarchy) and in
# ~/.config/uwsm/env (omarchy-user-setup.sh).
touch /etc/environment
sed -i '/^AQ_DRM_DEVICES=/d' /etc/environment
echo 'AQ_DRM_DEVICES=/dev/dri/by-path/platform-exynos-drm-card' >> /etc/environment
record "AQ_DRM_DEVICES" ok "/dev/dri/by-path/platform-exynos-drm-card"

# --- Omarchy's system setup -------------------------------------------------
log "Omarchy system setup leaves"
bash /t715/omarchy-system-setup.sh "$B/omarchy-system.tsv"

# Groups Omarchy's setup records for the user.
if [ -s /var/lib/omarchy/provisioning/groups ]; then
    while IFS= read -r g; do
        [ -n "$g" ] && getent group "$g" >/dev/null 2>&1 && usermod -aG "$g" "$U"
    done < /var/lib/omarchy/provisioning/groups
fi
record "user's groups" ok "$(id -nG "$U")"

# --- units ------------------------------------------------------------------
log "units"
systemctl enable usb-rndis.service sshd.service sddm.service \
    t715-shutdown-log.service t715-pstore-shutdown.service t715-vendor-firmware.service
systemctl set-default graphical.target >/dev/null

# Touch layer P1: the Power and Home keys and the cover, and the on-screen
# keyboard, for every user's graphical session (/etc/systemd/user/t715-{keys,
# squeekboard}.service from overlay-omarchy).
[ -x /usr/local/bin/t715-keys ] || die "no /usr/local/bin/t715-keys"
[ -x /usr/local/bin/t715-animations ] || die "no /usr/local/bin/t715-animations"
[ -x /usr/bin/squeekboard ] || die "no /usr/bin/squeekboard"
[ -x /usr/local/bin/t715-sdcard ] || die "no /usr/local/bin/t715-sdcard"
[ -x /usr/local/bin/t715-rotate ] || die "no /usr/local/bin/t715-rotate"
systemctl --global enable t715-keys.service t715-squeekboard.service t715-idle.service \
    t715-update-check.timer t715-animations.path t715-animations.service t715-sdcard.service
record "units" ok "sshd, sddm, usb-rndis; for every session: t715-keys, t715-squeekboard, t715-idle, t715-sdcard, t715-animations, t715-update-check.timer; graphical.target"

# Android (Waydroid) session: does nothing on a system without Waydroid because of its ConditionPathExists= checks.
[ -x /usr/local/bin/t715-android ] || die "no /usr/local/bin/t715-android"
[ -x /usr/local/sbin/t715-android-setup ] || die "no /usr/local/sbin/t715-android-setup"
[ -x /usr/local/bin/waydroid ] || die "no /usr/local/bin/waydroid"
[ -f /usr/local/lib/t715-android/launchd.py ] || die "no /usr/local/lib/t715-android/launchd.py"
systemctl --global enable t715-android.service
systemctl --global enable t715-android-launchd.service
# Keep waydroid-container.service disabled until the user runs `sudo t715-android-setup all`.
systemctl disable waydroid-container.service || true

# Omarchy 4.5's migration hold list, for an in-place Omarchy upgrade later
# (t715-omarchy-migrations-hold, overlay-omarchy): a fresh image marks every
# shipped migration done for the user (omarchy-user-setup.sh).
install -D -m 0644 /t715/omarchy-migrations.hold "$S/omarchy-migrations.hold"
[ -x /usr/local/bin/t715-omarchy-migrations-hold ] || die "no /usr/local/bin/t715-omarchy-migrations-hold"
record "migration hold list" ok "$S/omarchy-migrations.hold: $(grep -c '^[0-9]*\.sh' "$S/omarchy-migrations.hold") migrations, for t715-omarchy-migrations-hold"

# omamobile-setup-user ran at build time (omarchy-user-setup.sh). It would run
# again at every login before the compositor: masked to keep the session's
# start short; on a persistent root a new package's steps are run by hand, as
# the user, with omamobile-setup-user.
systemctl --global mask omamobile-setup-user.service

# Omarchy's default theme asks for the Yaru-grey icons, which ALARM's
# yaru-icon-theme does not ship: GTK then falls back to hicolor.
[ -e /usr/share/icons/Yaru-grey ] || ln -s Yaru /usr/share/icons/Yaru-grey

# Bluetooth: Omarchy's hardware/bluetooth.sh leaf enables bluetoothd; make
# sure of it. The controller's address comes from t715-bt-addr@hciN.service,
# pulled in by its udev rule (overlay-omarchy).
if pacman -Q bluez >/dev/null 2>&1; then
    systemctl enable bluetooth.service
    [ -x /usr/local/sbin/t715-bt-addr ] || die "no /usr/local/sbin/t715-bt-addr"
    command -v btmgmt >/dev/null || die "no btmgmt (bluez-utils), which t715-bt-addr needs"
    [ -f /usr/lib/systemd/user/bt-agent.service ] \
        || die "no /usr/lib/systemd/user/bt-agent.service: check its drop-in still applies"
    record "Bluetooth" ok "bluetoothd enabled; t715-bt-addr@hciN by its udev rule; Omarchy's auto-accept pairing agent skipped"
else
    record "Bluetooth" "not installed" "no bluez"
fi

# The modem (t715-modem, since 2026-11-25 on arm64): shannond exports its own
# ModemManager facade, so the real ModemManager must never run (it would probe
# the CP's nodes); as on the 32-bit image.  The package enables its chain
# (shannon-nv-provision, shannon-modem-prepare); the overlay's drop-in starts it
# only after this boot's KBOOT: up.  The user joins radio for shannonctl.
if [ -e /usr/lib/systemd/system/ModemManager.service ]; then
    systemctl mask ModemManager.service dbus-org.freedesktop.ModemManager1.service 2>/dev/null || true
fi
if pacman -Q t715-modem >/dev/null 2>&1; then
    getent group radio >/dev/null 2>&1 || die "t715-modem is installed but there is no radio group"
    usermod -aG radio "$U"
    systemctl enable shannon-nv-provision.service shannon-modem-prepare.service
    record "modem" ok "t715-modem $(pacman -Q t715-modem | cut -d' ' -f2); chain enabled after the boot mark; $U in radio"
else
    record "modem" "not installed" "no t715-modem"
fi
# omatel-agent (rings for calls, keeps SMS): omamobile-shell's dependency; it
# runs for every desktop user, with nothing to talk to until there is a modem.
[ -f /usr/lib/systemd/user/omatel-agent.service ] && systemctl --global enable omatel-agent.service

# ufw on, nothing in but SSH and DHCP on the USB cable: the rules are
# overlay-omarchy's /etc/ufw/user*.rules. Omarchy's config/firewall.sh is
# skipped by omarchy-system-setup.sh: it would close usb0, the way in.
[ -s /etc/ufw/user.rules ] && [ -s /etc/ufw/user6.rules ] || die "no ufw rules in overlay-omarchy"
sed -i 's/^ENABLED=.*/ENABLED=yes/' /etc/ufw/ufw.conf
systemctl enable ufw.service
record "firewall" ok "ufw: SSH (22) and DHCP (67) on usb0 only"

# Omarchy's first-boot provisioning (user creation on tty1) must never run:
# the user exists already and it would hold tty1 before SDDM.
rm -f /var/lib/omarchy/provisioning/pending
ln -sfn /dev/null /etc/systemd/system/omarchy-provision-owner.service

# No Plymouth screen at shutdown: one hand-over of the display less while the
# session ends (the owner's image: black screens after such hand-overs on
# 2026-10-29).
systemctl mask plymouth-reboot.service plymouth-poweroff.service \
    plymouth-halt.service plymouth-kexec.service

# Periodic index and keyring jobs: their results are lost at each reboot of a
# RAM-overlay image (updatedb and mandb ran at build time).
systemctl mask plocate-updatedb.timer man-db.timer archlinux-keyring-wkd-sync.timer

# --- SDDM autologin ---------------------------------------------------------
log "SDDM autologin: $U into $SESSION"
[ -f "/usr/local/share/wayland-sessions/$SESSION" ] \
    || [ -f "/usr/share/wayland-sessions/$SESSION" ] \
    || die "no $SESSION session file"
install -d -m 0750 /etc/sddm.conf.d
cat > /etc/sddm.conf.d/autologin.conf <<EOS
# SM-T715 arm64 image: log the user straight into Omarchy's session
# ($SESSION, from omarchy-settings). Relogin: the tablet has no keyboard for
# SDDM's greeter, so SDDM logs in again if the session ends.
[Autologin]
User=$U
Session=$SESSION
Relogin=true
EOS
chmod 0644 /etc/sddm.conf.d/autologin.conf
install -d -m 0750 -o sddm -g sddm /var/lib/sddm
printf '[Last]\nSession=%s\nUser=%s\n' "$SESSION" "$U" > /var/lib/sddm/state.conf
chown -R sddm:sddm /var/lib/sddm

# --- the user's home, from Omarchy's /etc/skel ------------------------------
# The base image made it from ALARM's /etc/skel. omarchy-settings has since
# put Omarchy's own files there (.config/hypr/*.lua, ...): the home is made
# again from it, as useradd -m would, before Omarchy's user setup fills it.
log "home of $U from Omarchy's /etc/skel"
key=/t715/ssh/authorized_keys
rm -rf "/home/$U"
cp -a /etc/skel "/home/$U"
chmod 0700 "/home/$U"
chown -R "$U:$U" "/home/$U"
if [ -s "$key" ]; then
    install -d -m 0700 -o "$U" -g "$U" "/home/$U/.ssh"
    install -m 0600 -o "$U" -g "$U" "$key" "/home/$U/.ssh/authorized_keys"
fi
record "home" ok "from Omarchy's /etc/skel$( [ -s "$key" ] && echo ', with the SSH key')"

# --- Omarchy's user setup and the tablet's per-user settings ----------------
log "Omarchy user setup as $U"
bash /t715/omarchy-user-setup.sh "$B/omarchy-user.tsv"

log "done"
