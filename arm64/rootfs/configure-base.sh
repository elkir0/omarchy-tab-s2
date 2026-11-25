#!/bin/bash
# configure-base.sh — the base image's configuration (root, in the build
# container). Adapted from omarchy-tab-s2/image/rootfs/configure-
# system.sh, for an image that has to boot on a kernel still being brought up:
#   overlay/ (the USB debug link, SSH, sudo, journald, logind, the udev rules,
#   the watchdog keeper and the boot mark, the vendor-files unit),
#   locale and time zone,
#   accounts: ALARM's default user (alarm, uid 1000) is the user, as on the
#   owner's armv7h tablet (since 2026-11-24; build.sh --user NAME renames it),
#   with the placeholder password instead of ALARM's "alarm", root is locked,
#   an SSH key when the build was given one, /etc/fstab, the units.
# /etc/hostname and /etc/resolv.conf are Docker bind mounts during the build:
# mkimage.sh writes them into the exported tree.
set -euo pipefail

export SYSTEMD_OFFLINE=1
B=/usr/share/t715-arm64/build
# T715_USER, T715_LANG, T715_TZ and either T715_PASSWORD_HASH or T715_PASSWORD
# (a placeholder then: hashed here with a fixed salt).
. /t715/user.env
U="$T715_USER"

log() { printf 'configure-base: %s\n' "$*"; }
die() { printf 'configure-base: ERROR: %s\n' "$*" >&2; exit 1; }
record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$B/base.tsv"; }

mkdir -p "$B"
: > "$B/base.tsv"

# --- overlay ----------------------------------------------------------------
# File by file, so existing directories keep their modes (/etc/sudoers.d is
# 0750).
log "overlay"
(cd /t715/overlay && find . -type f -print) | sort | while IFS= read -r f; do
    f="${f#./}"
    install -D -m "$(stat -c %a "/t715/overlay/$f")" "/t715/overlay/$f" "/$f"
done
chmod 0440 /etc/sudoers.d/10-wheel
visudo -c >/dev/null || die "sudoers do not parse"
record "overlay" ok "$(find /t715/overlay -type f | wc -l) files"

# --- locale, time zone ------------------------------------------------------
log "LANG=$T715_LANG, $T715_TZ"
sed -i -e "s/^#$T715_LANG UTF-8/$T715_LANG UTF-8/" -e "s/^#${T715_LANG//./\\.} UTF-8 /$T715_LANG UTF-8 /" /etc/locale.gen
grep -qE "^${T715_LANG//./\\.} UTF-8[[:space:]]*$" /etc/locale.gen || die "no locale $T715_LANG in /etc/locale.gen"
locale-gen
echo "LANG=$T715_LANG" > /etc/locale.conf
[ -e "/usr/share/zoneinfo/$T715_TZ" ] || die "no zoneinfo for $T715_TZ"
ln -sfn "/usr/share/zoneinfo/$T715_TZ" /etc/localtime
printf '%s\n' "$T715_TZ" > /etc/timezone
record "locale, time zone" ok "$T715_LANG, $T715_TZ"

# --- accounts ---------------------------------------------------------------
# The tarball's default user alarm (uid 1000, password "alarm") is the user
# (T715_USER=alarm, the default since 2026-11-24: the owner's armv7h tablet
# and its SDDM autologin name alarm), or is renamed T715_USER. Its password
# is the build's (the documented placeholder unless --password gave a hash):
# ALARM's documented "alarm" is never left as shipped.
log "accounts: $U (uid 1000), root locked"
[ -n "$U" ] || die "no T715_USER in user.env"
case "$U" in
    root) die "T715_USER=root: the user must not be root" ;;
    *[!a-z0-9_-]*|''|[0-9-]*) die "T715_USER=$U is not a valid user name" ;;
esac
id alarm >/dev/null 2>&1 || die "ALARM's default user alarm is not in the tarball"
[ "$(id -u alarm)" = 1000 ] || die "alarm is not uid 1000"
if [ "$U" != alarm ]; then
    id "$U" >/dev/null 2>&1 && die "$U exists next to alarm"
    getent group alarm | grep -q ":1000:" && groupmod -n "$U" alarm
    usermod -l "$U" -d "/home/$U" -m alarm
fi
usermod -c "Tablet user" "$U"
[ "$(id -u "$U")" = 1000 ] || die "$U is not uid 1000"
if [ -n "${T715_PASSWORD_HASH:-}" ]; then
    hash="$T715_PASSWORD_HASH"
    placeholder=no
else
    # A fixed salt: the same placeholder hash in every image.
    hash="$(openssl passwd -6 -salt t715placeholder "$T715_PASSWORD")"
    placeholder=yes
fi
printf '%s\n' "$hash" | grep -qE '^\$[0-9y]+\$' || die "the password hash does not look like a crypt hash"
usermod -p "$hash" "$U"
usermod -p '!' root
getent group video >/dev/null && usermod -aG video "$U"
getent group audio >/dev/null && usermod -aG audio "$U"
getent group input >/dev/null && usermod -aG input "$U"
getent group network >/dev/null && usermod -aG network "$U"
usermod -aG wheel "$U"

# The home from /etc/skel, as useradd -m would have made it.
rm -rf "/home/$U"
cp -a /etc/skel "/home/$U"
chmod 0700 "/home/$U"
chown -R "$U:$U" "/home/$U"
record "user" ok "$U, uid 1000, groups $(id -nG "$U"), password: $([ "$placeholder" = yes ] && echo 'PLACEHOLDER (see the documentation)' || echo 'given at the build')"
record "root" ok "locked (no password); ssh by key only"

# --- SSH --------------------------------------------------------------------
key=/t715/ssh/authorized_keys
! grep -q 'PRIVATE KEY' "$key" 2>/dev/null || die "the SSH key file is a private key"
install -d -m 0700 -o root -g root /root/.ssh
install -d -m 0700 -o "$U" -g "$U" "/home/$U/.ssh"
if [ -s "$key" ]; then
    grep -qE '^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com) ' "$key" \
        || die "$key does not look like an OpenSSH public key file"
    install -m 0600 -o root -g root "$key" /root/.ssh/authorized_keys
    install -m 0600 -o "$U" -g "$U" "$key" "/home/$U/.ssh/authorized_keys"
    record "SSH key for root and $U" ok "$(grep -c . "$key") line(s)"
else
    record "SSH key" none "no key at the build: nobody can log in over ssh until one is given (--ssh-pubkey)"
fi

# --- file system table ------------------------------------------------------
# The kernel, or its initramfs, mounts the root; nothing else is mounted.
cat > /etc/fstab <<'EOF'
# Static file system table of the SM-T715 arm64 image. The kernel's own
# initramfs (or the kernel itself, root=) mounts the root before systemd
# starts, and this tablet has no other file system to mount: nothing is
# listed, so that nothing can hold sysinit.target waiting for a device.
# (<file system> <dir> <type> <options> <dump> <pass>)
EOF
chmod 0644 /etc/fstab
record "/etc/fstab" ok "no entry"

# --- units ------------------------------------------------------------------
log "units"
systemctl enable sshd.service NetworkManager.service usb-rndis.service \
    t715-kboot-mark.service t715-watchdog-keeper.service \
    t715-shutdown-log.service t715-pstore-shutdown.service t715-vendor-firmware.service \
    run-t715-userdata.mount
systemctl set-default multi-user.target >/dev/null
# No suspend on a kernel still being brought up: with the watchdog running,
# a suspended tablet that never wakes is reset (as a hung one is), and
# logind's idle and lid actions are not this image's business yet.
systemctl mask suspend.target sleep.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
# The bring-up knobs (arm64/docs/ROOTFS.md): t715.kbootmark=0
# skips the mark (its condition); t715.return=MIN enables t715-return.timer
# from its generator at each boot. Nothing to enable for them here: the timer
# must not run without the knob.
[ -x /etc/systemd/system-generators/t715-return-generator ] || die "no t715-return-generator"
[ -x /usr/local/sbin/t715-return ] || die "no /usr/local/sbin/t715-return"
record "units" ok "sshd, NetworkManager, usb-rndis, t715-kboot-mark (after sshd and usb-rndis; not with t715.kbootmark=0), t715-watchdog-keeper, t715-shutdown-log, t715-pstore-shutdown, t715-vendor-firmware; t715-return.timer by its generator with t715.return=MIN only; sleep targets masked"
record "getty" ok "systemd's own getty@tty1 (static) and serial-getty on the console"

mkdir -p /var/log/journal
log "done"
