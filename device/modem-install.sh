#!/usr/bin/env bash
# Install the SS333 modem stack into the tablet's running root and enable it,
# so that it starts by itself at every boot of a kernel with the modem series
# (kernel/patches/t715-modem). Meant for the persistent root
# (USERDATA/omarchy); in image mode everything is lost at the next boot.
#
#   device/modem-install.sh [--apn APN] [--user NAME] [--no-enable]
#
# Installs: /usr/bin/shannon-loader and shannonctl; /usr/lib/shannond (daemon, CLI,
# audio hook, shannon-modem-prepare); the three units in /etc/systemd/system;
# the ModemManager D-Bus policy; the udev rules (identity and firmware
# partitions read-only, modem nodes root only); the modprobe blacklist; the
# "Voice Call" UCM files; the radio group. Enables shannon-modem-prepare.service,
# which waits for the battery gate and then starts shannon-loader.service and
# shannond.service (on a kernel without the modem series its condition skips
# the chain). With --apn, writes /etc/shannond.env (the LTE attach APN) and adds
# the NetworkManager connection "t715-mobile" (autoconnect off). With --user,
# adds that desktop user to the radio group (shannonctl over
# /run/shannond/control) and enables the user unit t715-call-profile.service
# (the "Voice Call" PipeWire profile during calls). The verified NV copy must
# already be in /var/lib/shannon/nv (manifest checked). Starts nothing: reboot,
# or start shannon-loader.service by hand.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TSSH="$REPO_ROOT/device/tssh"
APN="" ENABLE=1 DESKUSER=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --apn) APN="$2"; shift 2 ;;
        --user) DESKUSER="$2"; shift 2 ;;
        --no-enable) ENABLE=0; shift ;;
        *) echo "usage: modem-install.sh [--apn APN] [--user NAME] [--no-enable]" >&2; exit 2 ;;
    esac
done

COPYFILE_DISABLE=1 tar --no-xattrs -C "$REPO_ROOT" -cf - --exclude=__pycache__ --exclude='*.pyc' \
    modem/loader/build/shannon-loader-armv7 modem/shannond/shannond modem/shannond/bin \
    modem/shannond/dbus modem/audio/voice-hook.sh modem/audio/t715-call-profile \
    modem/audio/t715-call-profile.service modem/systemd modem/udev modem/modprobe \
    image/rootfs/overlay/usr/share/alsa/ucm2/conf.d/wm1814/VoiceCall.conf \
    image/rootfs/overlay/usr/share/alsa/ucm2/conf.d/wm1814/wm1814.conf |
    "$TSSH" 'rm -rf /run/modem-install && mkdir -p /run/modem-install && tar -C /run/modem-install -xf -'

"$TSSH" "APN='$APN' ENABLE=$ENABLE DESKUSER='$DESKUSER' bash -s" <<'EOF'
set -euo pipefail
S=/run/modem-install
( cd /var/lib/shannon/nv && sha256sum -c --quiet manifest.sha256 ) || { echo "NV copy missing or altered in /var/lib/shannon/nv"; exit 1; }
install -m 0755 $S/modem/loader/build/shannon-loader-armv7 /usr/bin/shannon-loader
rm -rf /usr/lib/shannond/shannond /usr/lib/shannond/bin
mkdir -p /usr/lib/shannond
cp -r $S/modem/shannond/shannond $S/modem/shannond/bin /usr/lib/shannond/
install -m 0755 $S/modem/audio/voice-hook.sh /usr/lib/shannond/voice-hook.sh
install -m 0755 $S/modem/audio/t715-call-profile /usr/lib/shannond/t715-call-profile
install -m 0644 $S/modem/audio/t715-call-profile.service /usr/lib/systemd/user/t715-call-profile.service
ln -sf /usr/lib/shannond/bin/shannonctl /usr/local/bin/shannonctl
install -m 0755 $S/modem/systemd/shannon-modem-prepare /usr/lib/shannond/shannon-modem-prepare
install -m 0644 $S/modem/systemd/*.service /etc/systemd/system/
install -m 0644 $S/modem/shannond/dbus/org.freedesktop.ModemManager1.conf /usr/share/dbus-1/system.d/t715-modem-mm.conf
install -m 0644 $S/modem/udev/*.rules /etc/udev/rules.d/
install -m 0644 $S/modem/modprobe/t715-modem.conf /etc/modprobe.d/t715-modem.conf
install -m 0644 $S/image/rootfs/overlay/usr/share/alsa/ucm2/conf.d/wm1814/*.conf /usr/share/alsa/ucm2/conf.d/wm1814/
getent group radio >/dev/null || groupadd -r radio
if [ -n "$DESKUSER" ]; then
    usermod -aG radio "$DESKUSER"
    # "Voice Call" PipeWire profile during calls (WirePlumber < 0.5.15 does not pick it)
    uid=$(id -u "$DESKUSER")
    runuser -u "$DESKUSER" -- env XDG_RUNTIME_DIR=/run/user/$uid systemctl --user daemon-reload 2>/dev/null || true
    runuser -u "$DESKUSER" -- env XDG_RUNTIME_DIR=/run/user/$uid systemctl --user enable --now t715-call-profile.service 2>&1 | grep -v '^Created symlink' || true
fi
systemctl daemon-reload
busctl call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus ReloadConfig
if [ "$ENABLE" = 1 ]; then
    # earlier installs enabled the services themselves, or a timer
    systemctl disable shannon-loader.service shannond.service shannon-modem.timer 2>/dev/null || true
    rm -f /etc/systemd/system/shannon-modem.timer
    systemctl daemon-reload
    systemctl enable shannon-modem-prepare.service 2>&1 | grep -v '^Created symlink' || true
fi
if [ -n "$APN" ]; then
    # the LTE attach APN, sent before every radio on (docs/hardware/MODEM.md §6.7)
    printf 'SHANNOND_OPTS="--lte-apn %s"\n' "$APN" > /etc/shannond.env
fi
if [ -n "$APN" ] && ! nmcli -t -f NAME connection show | grep -qx t715-mobile; then
    nmcli connection add type gsm ifname '*' con-name t715-mobile gsm.apn "$APN" \
        connection.autoconnect no ipv6.method ignore >/dev/null
fi
echo "installed; shannon-modem-prepare.service $(systemctl is-enabled shannon-modem-prepare.service)"
rm -rf $S
EOF
