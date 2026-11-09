#!/usr/bin/env bash
# verify-rootfs.sh — offline checks of the Omarchy rootfs image
# (tools/build-rootfs) against the tablet owner's image contract
# (docs/image/ROOTFS.md), without booting it.
#
# Usage: tests/verify-rootfs.sh IMAGE PUBKEY
#        tests/verify-rootfs.sh IMAGE none     an image built with --public
#   IMAGE   out/rootfs-omarchy.img
#   PUBKEY  the public key given to tools/build-rootfs --ssh-pubkey
#
# Reads the image with debugfs/dumpe2fs in a throwaway Debian container
# (t715-omarchy-rootfs-helper, built if missing, native arm64), through a
# read-only bind mount: the image is never mounted, never written, and
# nothing is extracted on macOS. The USB debug link, Bluetooth and Wi-Fi
# files are compared with rootfs/overlay (the build's source; the Wi-Fi
# files' modes with git's), the Bluetooth patch RAM with its vendor dump in
# $T715_DUMPS_DIR/vendor_firmware and the Wi-Fi NVRAM with its dump in
# $T715_DUMPS_DIR/etc_wifi (default dumps/ at the repository's root;
# read-only, never copied here).
# Touch layer P2: package versions come from pkg/*/PKGBUILD, the markers set
# before omamobile-setup-user from rootfs/omarchy-user-setup.sh.
#
# Prints PASS/FAIL per check and a final "RESULT: PASS" or "RESULT: FAIL";
# exit 0 = PASS, 1 = a check failed, 2 = usage or setup error.
#
# NB: debugfs exits 0 even when a path does not exist: existence checks
# match its output ("Inode: ..."), never its exit status.

set -euo pipefail

usage() { sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -eq 2 ] || usage
IMG="$1"
KEY="$2"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DUMPS="${T715_DUMPS_DIR:-$REPO_DIR/../dumps}"
BT_FIRMWARE="$DUMPS/vendor_firmware/bcm4358A3_V0086.0144.hcd"
WIFI_NVRAM="$DUMPS/etc_wifi/nvram_net.txt"
# The Wi-Fi overlay files, with their modes as git records them.
WIFI_FILES="usr/local/sbin/t715-wifi-addr etc/udev/rules.d/90-t715-wifi-addr.rules etc/udev/rules.d/60-t715-wifi-aspm.rules etc/modprobe.d/t715-brcmfmac.conf etc/NetworkManager/conf.d/20-t715-wifi-mac.conf"
HELPER_IMAGE="t715-omarchy-rootfs-helper:latest"
CTR="t715-omarchy-rootfs-verify"

setup_error() { echo "SETUP ERROR: $*" >&2; exit 2; }
[ -f "$IMG" ] || setup_error "image not found: $IMG"
PUBLIC=0
if [ "$KEY" = none ]; then
    PUBLIC=1
    KEY=$(mktemp); BT_FIRMWARE=$KEY; WIFI_NVRAM=$KEY
fi
[ -r "$KEY" ] || setup_error "cannot read SSH public key: $KEY"
[ -f "$BT_FIRMWARE" ] || setup_error "no $BT_FIRMWARE (set T715_DUMPS_DIR)"
[ -f "$WIFI_NVRAM" ] || setup_error "no $WIFI_NVRAM (set T715_DUMPS_DIR)"
command -v docker >/dev/null || setup_error "docker not found"
docker info >/dev/null 2>&1 || setup_error "docker daemon not reachable"

if ! docker image inspect "$HELPER_IMAGE" >/dev/null 2>&1; then
    echo "building helper image $HELPER_IMAGE" >&2
    docker build --platform linux/arm64 -q -t "$HELPER_IMAGE" - >/dev/null <<'EOF' \
        || setup_error "cannot build $HELPER_IMAGE"
FROM debian:trixie
RUN apt-get update \
 && apt-get install -y --no-install-recommends e2fsprogs tar findutils coreutils \
 && rm -rf /var/lib/apt/lists/*
EOF
fi

IMG_ABS="$(cd "$(dirname "$IMG")" && pwd)/$(basename "$IMG")"
KEY_ABS="$(cd "$(dirname "$KEY")" && pwd)/$(basename "$KEY")"
docker rm -f "$CTR" >/dev/null 2>&1 || true

# The Wi-Fi overlay files' modes as git records them (MODES: path<TAB>mode).
mkdir -p "$REPO_DIR/cache"
MODES_DIR="$(mktemp -d "$REPO_DIR/cache/.verify-modes.XXXXXX")"
trap 'rm -rf "$MODES_DIR"' EXIT
for f in $WIFI_FILES; do
    m="$(git -C "$REPO_DIR" ls-files -s "rootfs/overlay/$f" | awk '{print $1}')"
    [ -n "$m" ] || setup_error "rootfs/overlay/$f is not tracked by git"
    printf '%s\t%s\n' "$f" "$m" >> "$MODES_DIR/MODES"
done
chmod -R a+rX "$MODES_DIR"

# The checks, run inside the helper container (passed as an argument, so
# that no command can read the rest of the script from stdin).
INNER=""
IFS= read -r -d '' INNER <<'SCRIPT' || true
set -u
IMG=/img/rootfs.img
W=$(mktemp -d)
PASS=0; FAIL=0

ok()  { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s%s\n' "$1" "${2:+ ($2)}"; FAIL=$((FAIL + 1)); }
# check DESC CMD...: PASS when CMD exits 0.
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

dfs()    { debugfs -R "$1" "$IMG" 2>/dev/null; }
exists() { dfs "stat \"$1\"" | grep -q '^Inode:'; }
absent() { ! exists "$1"; }
ftype()  { dfs "stat \"$1\"" | sed -n 's/^Inode: [0-9]*[[:space:]]*Type: \([a-z]*\).*/\1/p'; }
fmode()  { dfs "stat \"$1\"" | sed -n 's/.*Mode: *\(0[0-7]*\).*/\1/p' | head -n1; }
fuid()   { dfs "stat \"$1\"" | sed -n 's/^User: *\([0-9]*\) .*/\1/p' | head -n1; }
fgid()   { dfs "stat \"$1\"" | sed -n 's/.*Group: *\([0-9]*\).*/\1/p' | head -n1; }
# get PATH: the file's bytes in $W/f (empty when missing).
get()    { rm -f "$W/f"; dfs "dump \"$1\" $W/f" >/dev/null; [ -f "$W/f" ] || : > "$W/f"; }
cat_()   { get "$1"; cat "$W/f"; }
linkto() {
    local s
    s="$(dfs "stat \"$1\"")"
    printf '%s\n' "$s" | grep -q 'Type: symlink' || return 1
    if printf '%s\n' "$s" | grep -q '^Fast link dest:'; then
        printf '%s\n' "$s" | sed -n 's/^Fast link dest: "\(.*\)"$/\1/p'
    else
        get "$1"; cat "$W/f"
    fi
}
# resolve PATH: follow the last component's symlinks (debugfs follows the
# intermediate ones itself); prints the final path.
resolve() {
    local p="$1" t i=0
    while [ "$(ftype "$p")" = symlink ] && [ $i -lt 20 ]; do
        t="$(linkto "$p")" || return 1
        case "$t" in
            /*) p="$t" ;;
            *)  p="$(dirname "$p")/$t" ;;
        esac
        p="$(realpath -m -s "$p")"
        i=$((i + 1))
    done
    exists "$p" && printf '%s\n' "$p"
}
# local package names, from /var/lib/pacman/local/<name>-<ver>-<rel>.
dfs "ls -p /var/lib/pacman/local" | awk -F/ '$6 != "" && $6 != "." && $6 != ".." && $3 ~ /^04/ {print $6}' \
    | sed 's/-[^-]*-[^-]*$//' | sort -u > "$W/pkgs"
dfs "ls -p /var/lib/pacman/local" | awk -F/ '$6 != "" && $3 ~ /^04/ {print $6}' > "$W/pkgdirs"
has_pkg() { grep -qx "$1" "$W/pkgs"; }
pkg_ver() { grep -E "^$1-[^-]+-[^-]+$" "$W/pkgdirs" | sed "s/^$1-//" | head -n1; }

echo "== image format =="
check "raw image, not Android sparse (no 0xed26ff3a magic)" \
    sh -c '[ "$(od -An -tx1 -N4 /img/rootfs.img | tr -d " \n")" != "3aff26ed" ]'
check "ext4 superblock magic 0xEF53 at offset 1080" \
    sh -c '[ "$(od -An -tx1 -j1080 -N2 /img/rootfs.img | tr -d " \n")" = "53ef" ]'
SB="$(dumpe2fs -h "$IMG" 2>/dev/null)"
check "dumpe2fs reads the superblock, ext4 features (extent)" \
    sh -c 'printf "%s\n" "$1" | grep -q "^Filesystem features:.*extent"' _ "$SB"
bc="$(printf '%s\n' "$SB" | sed -n 's/^Block count: *//p')"
bs="$(printf '%s\n' "$SB" | sed -n 's/^Block size: *//p')"
check "file size equals block count x block size" \
    sh -c '[ "$(stat -c %s /img/rootfs.img)" = "$(( $1 * $2 ))" ]' _ "${bc:-0}" "${bs:-0}"
check "e2fsck -fn: clean" e2fsck -fn "$IMG"
label="$(printf '%s\n' "$SB" | sed -n 's/^Filesystem volume name: *//p')"
check "label ALARM (got: ${label:-none})" test "$label" = ALARM

echo "== boot =="
check "no /.dockerenv" absent /.dockerenv
init="$(resolve /sbin/init || true)"
check "/sbin/init -> systemd (${init:-unresolved})" \
    sh -c 'case "$1" in */lib/systemd/systemd) exit 0 ;; *) exit 1 ;; esac' _ "$init"
check "/sbin/init target is a regular file" test "$(ftype "${init:-/nonexistent}")" = regular
dt="$(resolve /etc/systemd/system/default.target || true)"
check "default target graphical.target (${dt:-unresolved})" \
    sh -c 'case "$1" in */graphical.target) exit 0 ;; *) exit 1 ;; esac' _ "$dt"
get /etc/machine-id
check "/etc/machine-id exists and is empty (transient id, no first-boot prompts)" \
    sh -c '[ -f "$1" ] && [ ! -s "$1" ]' _ "$W/f"
check "  (machine-id present in the image)" exists /etc/machine-id
check "no kernel package" sh -c '! grep -E "^linux" "$1" | grep -vxq linux-api-headers' _ "$W/pkgs"
check "no /usr/lib/modules" absent /usr/lib/modules
boot_entries="$(dfs "ls -p /boot" | awk -F/ '$6 != "" && $6 != "." && $6 != ".." {print $6}' | tr '\n' ' ')"
check "/boot is empty${boot_entries:+ (found: $boot_entries)}" test -z "$boot_entries"

echo "== USB debug link (byte-identical to rootfs/overlay) =="
for f in etc/systemd/system/usb-rndis.service usr/local/sbin/usb-rndis-setup \
         etc/usb-rndis/dnsmasq.conf etc/NetworkManager/conf.d/10-usb-rndis-unmanaged.conf \
         etc/ssh/sshd_config.d/10-t715.conf; do
    get "/$f"
    check "/$f identical to rootfs/overlay" cmp -s "$W/f" "/our-overlay/$f"
done
check "/usr/local/sbin/usb-rndis-setup mode 0755" test "$(fmode /usr/local/sbin/usb-rndis-setup)" = 0755
check "/etc/usb-rndis/function = ecm" test "$(cat_ /etc/usb-rndis/function)" = ecm
get /etc/usb-rndis/dnsmasq.conf; cp "$W/f" "$W/dnsmasq.conf"
check "dnsmasq.conf: port=0 (no DNS service)" grep -qx 'port=0' "$W/dnsmasq.conf"
check "dnsmasq.conf: empty dhcp-option=3 (no router)" grep -qx 'dhcp-option=3' "$W/dnsmasq.conf"
check "dnsmasq.conf: empty dhcp-option=6 (no DNS server)" grep -qx 'dhcp-option=6' "$W/dnsmasq.conf"
check "dnsmasq.conf: no other router/DNS option" \
    sh -c '! grep -Eq "^dhcp-option=(3|6|option:router|option:dns-server)[,=]" "$1"' _ "$W/dnsmasq.conf"
check "dnsmasq installed" has_pkg dnsmasq
check "openssh installed" has_pkg openssh
for u in usb-rndis.service sshd.service; do
    t="$(resolve "/etc/systemd/system/multi-user.target.wants/$u" || true)"
    check "$u enabled (multi-user.target.wants -> ${t:-missing})" test -n "$t"
done

echo "== SSH =="
if [ "$PUBLIC" = 1 ]; then
    check "public image: no SSH key" sh -c '! debugfs -R "stat /root/.ssh/authorized_keys" /img/rootfs.img 2>/dev/null | grep -q "^Inode:" && ! debugfs -R "stat /home/alarm/.ssh/authorized_keys" /img/rootfs.img 2>/dev/null | grep -q "^Inode:"'
else
get /root/.ssh/authorized_keys
check "/root/.ssh/authorized_keys == PUBKEY" cmp -s "$W/f" /img/key.pub
check "/root/.ssh mode 0700, owner 0:0" \
    test "$(fmode /root/.ssh) $(fuid /root/.ssh):$(fgid /root/.ssh)" = "0700 0:0"
check "/root/.ssh/authorized_keys mode 0600, owner 0:0" \
    test "$(fmode /root/.ssh/authorized_keys) $(fuid /root/.ssh/authorized_keys):$(fgid /root/.ssh/authorized_keys)" = "0600 0:0"
fi
get /etc/ssh/sshd_config.d/10-t715.conf; cp "$W/f" "$W/sshd.conf"
check "sshd: PermitRootLogin prohibit-password, PasswordAuthentication no" \
    sh -c 'grep -qx "PermitRootLogin prohibit-password" "$1" && grep -qx "PasswordAuthentication no" "$1"' _ "$W/sshd.conf"
get /etc/shadow; cp "$W/f" "$W/shadow"
check "root password locked" grep -q '^root:!' "$W/shadow"
check "alarm has a password (ALARM's default)" grep -q '^alarm:\$' "$W/shadow"

echo "== session: SDDM autologin into Omarchy =="
get /etc/sddm.conf.d/autologin.conf; cp "$W/f" "$W/autologin"
check "autologin.conf: [Autologin] User=alarm Session=omarchy.desktop Relogin=true" \
    sh -c 'awk "/^\[/{s=\$0} s==\"[Autologin]\"" "$1" > "$1.sec" &&
           grep -qx "User=alarm" "$1.sec" && grep -qx "Session=omarchy.desktop" "$1.sec" &&
           grep -qx "Relogin=true" "$1.sec"' _ "$W/autologin"
check "/var/lib/sddm/state.conf: Session=omarchy.desktop, User=alarm" \
    sh -c 'grep -qx "Session=omarchy.desktop" "$1" && grep -qx "User=alarm" "$1"' _ "$(get /var/lib/sddm/state.conf; cp "$W/f" "$W/state"; echo "$W/state")"
get /usr/local/share/wayland-sessions/omarchy.desktop; cp "$W/f" "$W/session"
check "omarchy.desktop present (Exec=uwsm start ... hyprland.desktop)" \
    grep -q '^Exec=uwsm start .*hyprland.desktop' "$W/session"
t="$(resolve /etc/systemd/system/display-manager.service || true)"
check "sddm.service enabled (display-manager.service -> ${t:-missing})" \
    sh -c 'case "$1" in */sddm.service) exit 0 ;; *) exit 1 ;; esac' _ "$t"
check "SDDM greeter: Omarchy's 10-wayland.conf" exists /etc/sddm.conf.d/10-wayland.conf

echo "== Hyprland dmabuf-check shim (docs/journal/ONDEVICE-2026-10-28.md) =="
SHIM=/usr/local/lib/t715-dmabuf-check-shim.so
check "$SHIM mode 0755, owner 0:0" test "$(fmode $SHIM) $(fuid $SHIM):$(fgid $SHIM)" = "0755 0:0"
get $SHIM; cp "$W/f" "$W/shim.so"
check "shim is a 32-bit ARM ELF (class 1, machine 0x28)" \
    sh -c '[ "$(od -An -tx1 -N5 "$1" | tr -d " \n")" = "7f454c4601" ] &&
           [ "$(od -An -tx1 -j18 -N2 "$1" | tr -d " \n")" = "2800" ]' _ "$W/shim.so"
check "shim defines drmPrimeFDToHandle, drmCloseBufferHandle and drmIoctl (DESTROY_DUMB fallback)" \
    sh -c 'grep -aq drmPrimeFDToHandle "$1" && grep -aq drmCloseBufferHandle "$1" && grep -aq drmIoctl "$1" &&
           grep -aq "closed with GEM_CLOSE instead" "$1"' _ "$W/shim.so"
check "/usr/local/bin/Hyprland wrapper mode 0755" test "$(fmode /usr/local/bin/Hyprland)" = 0755
check "wrapper preloads the shim into /usr/bin/Hyprland" \
    grep -qx "LD_PRELOAD=$SHIM exec /usr/bin/Hyprland \"\$@\"" <(cat_ /usr/local/bin/Hyprland)

echo "== display =="
check "/etc/environment: AQ_DRM_DEVICES=/dev/dri/card0" \
    grep -qx 'AQ_DRM_DEVICES=/dev/dri/card0' <(cat_ /etc/environment)
check "sddm.service.d: Environment=AQ_DRM_DEVICES=/dev/dri/card0" \
    grep -qx 'Environment=AQ_DRM_DEVICES=/dev/dri/card0' <(cat_ /etc/systemd/system/sddm.service.d/10-t715-aq-drm.conf)
check "~alarm/.config/uwsm/env: export AQ_DRM_DEVICES=/dev/dri/card0" \
    grep -qx 'export AQ_DRM_DEVICES=/dev/dri/card0' <(cat_ /home/alarm/.config/uwsm/env)
get /home/alarm/.config/hypr/monitors.lua; cp "$W/f" "$W/monitors.lua"
check "monitors.lua: local omarchy_monitor_scale = 2" grep -qx 'local omarchy_monitor_scale = 2' "$W/monitors.lua"
check "monitors.lua: no \"auto\" scale left" sh -c '! grep -q "omarchy_monitor_scale = \"auto\"" "$1"' _ "$W/monitors.lua"
check "~alarm/.config/hypr/hyprland.lua loads Omarchy's bootstrap" \
    grep -q 'default/hypr/bootstrap.lua' <(cat_ /home/alarm/.config/hypr/hyprland.lua)

echo "== user alarm =="
get /etc/passwd; cp "$W/f" "$W/passwd"
get /etc/group; cp "$W/f" "$W/group"
check "alarm is uid 1000, home /home/alarm" grep -q '^alarm:x:1000:1000:[^:]*:/home/alarm:' "$W/passwd"
for g in wheel video audio input network; do
    check "alarm in group $g" sh -c 'grep -E "^$1:" "$2" | cut -d: -f4 | tr , "\n" | grep -qx alarm' _ "$g" "$W/group"
done
check "/home/alarm owned by 1000:1000, mode 0700" \
    test "$(fmode /home/alarm) $(fuid /home/alarm):$(fgid /home/alarm)" = "0700 1000:1000"
mkdir -p "$W/home"
dfs "rdump /home/alarm $W/home" >/dev/null
# rdump keeps the owners of directories and files, not of symlinks:
# those are checked one by one with debugfs.
check "every file and directory under /home/alarm is owned by 1000:1000" \
    sh -c '[ -d "$1/alarm" ] && [ -z "$(find "$1/alarm" ! -type l \( ! -uid 1000 -o ! -gid 1000 \) -print -quit)" ]' _ "$W/home"
( cd "$W/home" && find alarm -type l ) | sed 's|^|stat "/home/|; s|$|"|' > "$W/links.cmd"
if [ -s "$W/links.cmd" ]; then
    check "every symlink under /home/alarm is owned by 1000 ($(wc -l < "$W/links.cmd") links)" \
        sh -c '! debugfs -f "$1" /img/rootfs.img 2>/dev/null | grep "^User:" | grep -vq "^User: *1000 *Group: *1000"' _ "$W/links.cmd"
fi
check "Omarchy user setup done (~/.local/state/omarchy/done/finalize-user)" \
    exists /home/alarm/.local/state/omarchy/done/finalize-user
check "Omarchy stay-awake state absent (the Stay awake tile starts off, so t715-idle's screen-off runs)" \
    absent /home/alarm/.local/state/omarchy/indicators/stay-awake
check "Omarchy toggle: suspend-off" exists /home/alarm/.local/state/omarchy/toggles/suspend-off
check "sudoers: 10-wheel NOPASSWD, mode 0440" \
    sh -c 'grep -q "^%wheel ALL=(ALL:ALL) NOPASSWD: ALL" "$1" && [ "$2" = 0440 ]' _ "$(get /etc/sudoers.d/10-wheel; cp "$W/f" "$W/sudo"; echo "$W/sudo")" "$(fmode /etc/sudoers.d/10-wheel)"

echo "== packages =="
for p in omarchy omarchy-settings hyprland quickshell uwsm sddm mesa squeekboard \
         gnome-calculator gnome-clocks geoclue wf-recorder pipewire-alsa; do
    check "$p installed ($(pkg_ver "$p"))" has_pkg "$p"
done
check "omarchy is the armv7h retag (4.0.6-1.1 or later .1)" sh -c 'case "$1" in *.1) exit 0 ;; *) exit 1 ;; esac' _ "$(pkg_ver omarchy)"
# pkg/hyprgraphics: the await() lost-wakeup fix that keeps Hyprland's text
# rendering from deadlocking (docs/image/PACKAGES.md, docs/journal/ONDEVICE-2026-10-28.md).
check "hyprgraphics is the patched rebuild ($(pkg_ver hyprgraphics), want a .1 pkgrel)" \
    sh -c 'case "$1" in *.1) exit 0 ;; *) exit 1 ;; esac' _ "$(pkg_ver hyprgraphics)"

echo "== services that must not run =="
wants="$(dfs "ls -p /etc/systemd/system" | awk -F/ '$6 ~ /\.wants$/ {print $6}')"
ufw_on=""
prov_on=""
for d in $wants; do
    l="$(dfs "ls -p /etc/systemd/system/$d" | awk -F/ '{print $6}')"
    printf '%s\n' "$l" | grep -qx ufw.service && ufw_on="$ufw_on $d"
    printf '%s\n' "$l" | grep -qx omarchy-provision-owner.service && prov_on="$prov_on $d"
done
check "ufw enabled (ufw.service in a .wants${ufw_on:+: found in$ufw_on})" test -n "$ufw_on"
check "/etc/ufw/ufw.conf: ENABLED=yes" grep -qx 'ENABLED=yes' <(cat_ /etc/ufw/ufw.conf)
get /etc/ufw/user.rules; cp "$W/f" "$W/ufw.rules"
check "ufw: only SSH and DHCP come in, on the USB cable, identical to rootfs/overlay" \
    sh -c 'test "$(grep -c "^-A ufw-user-input" "$1")" = 2 && grep -q "^-A ufw-user-input -i usb0 -p tcp --dport 22 -j ACCEPT" "$1" &&
           grep -q "^-A ufw-user-input -i usb0 -p udp --dport 67 -j ACCEPT" "$1" && cmp -s "$1" /our-overlay/etc/ufw/user.rules' _ "$W/ufw.rules"
exists /etc/NetworkManager/dispatcher.d/50-t715-hotspot-firewall
check "ufw: the Hotspot tile opens DHCP, DNS and forwarding while it is on" test "$(fmode /etc/NetworkManager/dispatcher.d/50-t715-hotspot-firewall)" = 0755
exists /etc/NetworkManager/conf.d/21-t715-wifi-no-pmf.conf
exists /etc/NetworkManager/conf.d/22-t715-wifi-powersave.conf
check "no Omarchy provisioning pending (/var/lib/omarchy/provisioning/pending)" \
    absent /var/lib/omarchy/provisioning/pending
check "omarchy-provision-owner.service not enabled${prov_on:+ (found in$prov_on)}" test -z "$prov_on"
po="$(linkto /etc/systemd/system/omarchy-provision-owner.service 2>/dev/null || true)"
check "omarchy-provision-owner.service absent or masked" \
    sh -c '[ "$1" = /dev/null ] || ! debugfs -R "stat /etc/systemd/system/omarchy-provision-owner.service" /img/rootfs.img 2>/dev/null | grep -q "^Inode:"' _ "$po"
for u in NetworkManager-wait-online.service systemd-networkd-wait-online.service; do
    check "$u masked (the network never holds up the boot)" \
        test "$(linkto "/etc/systemd/system/$u" 2>/dev/null)" = /dev/null
done
check "plocate's updatedb prunes /run/t715 (USERDATA)" grep -q '^PRUNEPATHS.*/run/t715' <(cat_ /etc/updatedb.conf)
for t in suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target sleep.target \
         plocate-updatedb.timer man-db.timer archlinux-keyring-wkd-sync.timer; do
    check "$t masked" test "$(linkto "/etc/systemd/system/$t" 2>/dev/null)" = /dev/null
done
check "ConditionNeedsUpdate stamps (/etc/.updated, /var/.updated)" \
    sh -c 'exists() { debugfs -R "stat \"$1\"" "$2" 2>/dev/null | grep -q "^Inode:"; }
           exists /etc/.updated "$1" && exists /var/.updated "$1"' _ "$IMG"

echo "== performance settings (docs/journal/ONDEVICE-2026-10-28.md) =="
check "zram-generator installed" has_pkg zram-generator
check "zram-generator.conf: zram0 at ram / 2, lz4" \
    sh -c 'grep -qx "zram-size = ram / 2" "$1" && grep -qx "compression-algorithm = lz4" "$1"' _ \
    "$(get /etc/systemd/zram-generator.conf; cp "$W/f" "$W/zram"; echo "$W/zram")"
check "sysctl: vm.swappiness = 180" grep -qx 'vm.swappiness = 180' <(cat_ /etc/sysctl.d/90-t715-vm.conf)
check "Firefox prefers GLES (gfx.egl.prefer-gles.enabled)" \
    grep -qx 'pref("gfx.egl.prefer-gles.enabled", true);' <(cat_ /usr/lib/firefox/browser/defaults/preferences/t715.js)
get /home/alarm/.config/hypr/looknfeel.lua; cp "$W/f" "$W/lnf"
check "looknfeel.lua: tablet block (opaque windows, no Xwayland, shorter animations)" \
    sh -c 'grep -q "^-- SM-T715 begin" "$1" && grep -q "^-- SM-T715 end" "$1" &&
           grep -q "opacity = \"1 1\"" "$1" && grep -q "xwayland = { enabled = false }" "$1"' _ "$W/lnf"
check "looknfeel.lua: the tablet block reads the saver flag" \
    sh -c 'grep -q "io.open(\"/run/t715-power/saver\", \"r\")" "$1" &&
           grep -q "animations = { enabled = t715_saver == nil }" "$1" &&
           ! grep -q "hl.config({ animations = { enabled = false } })" "$1"' _ "$W/lnf"
check "looknfeel.lua: the pointer shows with a mouse (cursor invisible = false, hide_on_touch, inactive_timeout 3)" \
    sh -c 'grep -qFx "hl.config({ cursor = { invisible = false, hide_on_touch = true, inactive_timeout = 3 } })" "$1" &&
           ! grep -q "invisible = true" "$1"' _ "$W/lnf"
ANIM=/usr/local/bin/t715-animations
check "$ANIM present with mode 0755" test "$(fmode $ANIM)" = 0755
for u in t715-animations.path t715-animations.service; do
    a="$(resolve /etc/systemd/user/graphical-session.target.wants/$u || true)"
    check "$u enabled for every user (graphical-session.target.wants -> ${a:-missing})" \
        test "$a" = /etc/systemd/user/$u
done
# The microSD card (docs/image/ROOTFS.md "microSD card"): the notifier as
# a user unit for every user, the tool 0755, and the udev rule that keeps
# /dev/disk/by-partlabel/* on the eMMC.
SDCARD=/usr/local/bin/t715-sdcard
check "$SDCARD present with mode 0755" test "$(fmode $SDCARD)" = 0755
a="$(resolve /etc/systemd/user/graphical-session.target.wants/t715-sdcard.service || true)"
check "t715-sdcard.service enabled for every user (graphical-session.target.wants -> ${a:-missing})" \
    test "$a" = /etc/systemd/user/t715-sdcard.service
check "the microSD partlabel rule installed (/etc/udev/rules.d/61-t715-removable-partlabel.rules)" \
    exists /etc/udev/rules.d/61-t715-removable-partlabel.rules
get /usr/share/t715-omarchy/wallpapers.tsv; cp "$W/f" "$W/wp"
check "theme backgrounds: all listed, none above a 2048 px short side" \
    sh -c '[ -s "$1" ] && awk -F"\t" '"'"'
        { d = ($3 ~ /^[0-9]+x[0-9]+$/) ? $3 : $2
          if (d !~ /^[0-9]+x[0-9]+$/) bad++
          split(d, a, "x"); s = (a[1] < a[2]) ? a[1] : a[2]; if (s > 2048) bad++ }
        END { exit bad > 0 }'"'"' "$1"' _ "$W/wp"

echo "== first-run notices (docs/image/ROOTFS.md) =="
FRW=/usr/share/omarchy/install/user/first-run/wifi.sh
get $FRW; cp "$W/f" "$W/frwifi"
check "$FRW is the tablet's (rootfs/overlay): no critical Wi-Fi notice, no update notice" \
    sh -c 'cmp -s "$1" /our-overlay/usr/share/omarchy/install/user/first-run/wifi.sh && ! grep -q -- "-u critical" "$1" && ! grep -q omarchy-update "$1"' _ "$W/frwifi"
get /usr/share/omamobile/shell/plugins/omamobile.quicksettings/WifiPanel.qml; cp "$W/f" "$W/wifipanel"
check "Wi-Fi panel: WPA2-PSK through nmcli without SAE (pkg/omamobile-shell 0002)" \
    grep -q nmcliWpa2ConnectArgv "$W/wifipanel"
check "  iw installed (the panel asks it about SAE)" exists /usr/bin/iw

echo "== touch layer P1: hardware keys (docs/image/ROOTFS.md) =="
K=/usr/local/bin/t715-keys
check "$K mode 0755, owner 0:0" test "$(fmode $K) $(fuid $K):$(fgid $K)" = "0755 0:0"
get $K; cp "$W/f" "$W/keys"
check "  identical to rootfs/overlay (a python3 script; python3 installed)" \
    sh -c 'cmp -s "$1" /our-overlay/usr/local/bin/t715-keys && head -n1 "$1" | grep -qx "#!/usr/bin/python3"' _ "$W/keys"
check "  python3 present" exists /usr/bin/python3
get /etc/udev/rules.d/60-t715-big-cores.rules
check "  60-t715-big-cores.rules identical to rootfs/overlay (cpu4-7 online writable for wheel)" \
    cmp -s "$W/f" /our-overlay/etc/udev/rules.d/60-t715-big-cores.rules
check "  long press at 0.6 s, the only hold time (HOLD = 0.6)" \
    sh -c 'grep -qx "HOLD = 0.6" "$1" && [ "$(grep -c "^HOLD = " "$1")" = 1 ]' _ "$W/keys"
get /etc/systemd/user/t715-keys.service; cp "$W/f" "$W/keys.unit"
check "t715-keys.service: ExecStart=$K, PartOf= and WantedBy=graphical-session.target" \
    sh -c 'grep -qx "ExecStart=/usr/local/bin/t715-keys" "$1" && grep -qx "PartOf=graphical-session.target" "$1" &&
           grep -qx "WantedBy=graphical-session.target" "$1"' _ "$W/keys.unit"
t="$(resolve /etc/systemd/user/graphical-session.target.wants/t715-keys.service || true)"
check "t715-keys.service enabled for every user (graphical-session.target.wants -> ${t:-missing})" \
    test "$t" = /etc/systemd/user/t715-keys.service
check "logind leaves the Power key to the session (HandlePowerKey=ignore)" \
    grep -qx 'HandlePowerKey=ignore' <(cat_ /etc/systemd/logind.conf.d/10-ignore-power-button.conf)
get /home/alarm/.config/hypr/hyprland.lua; cp "$W/f" "$W/hl"
check "hyprland.lua: the tablet block once, last, identical to rootfs/t715-tablet.lua" \
    sh -c '[ "$(grep -c "^-- SM-T715 tablet begin" "$1")" = 1 ] &&
           sed -n "/^-- SM-T715 tablet begin/,\$p" "$1" | cmp -s - /our-tablet.lua' _ "$W/hl"
check "  Omarchy's Power binding removed, Power and Home bound to nothing (t715-keys acts)" \
    sh -c 'grep -qx "hl.unbind(\"XF86PowerOff\")" "$1" &&
           grep -q "^o.bind(\"XF86PowerOff\", .*function() end, { locked = true })$" "$1" &&
           grep -q "^o.bind(\"XF86HomePage\", .*function() end, { locked = true })$" "$1"' _ "$W/hl"
check "  keys and the mouse never wake the screen (only t715-keys does)" \
    grep -q 'misc = { key_press_enables_dpms = false, mouse_move_enables_dpms = false }' "$W/hl"
get /home/alarm/.config/omarchy/extensions/omarchy-menu.jsonc; cp "$W/f" "$W/menu"
check "system menu: Lock only with a PIN, a PIN row, no Firmware, no Plymouth (alarm's menu extension file)" \
    sh -c 'grep -qx "  \"system.lock\": {\"when\": \"omarchy-toggle-enabled lock-on-start\"}," "$1" && grep -q "^  \"system.pin\": {" "$1" && grep -qx "  \"update.firmware\": {\"when\": \"false\"}," "$1" &&
           grep -qx "  \"update.config.plymouth\": {\"when\": \"false\"}," "$1"' _ "$W/menu"

echo "== touch layer P1: the cover (lid switch) =="
check "hyprland.lua: Omarchy's lid binds (lock, clamshell panel off) removed in the tablet block" \
    sh -c 'grep -qx "hl.unbind(\"switch:on:Lid Switch\")" "$1" && grep -qx "hl.unbind(\"switch:off:Lid Switch\")" "$1" &&
           ! sed -n "/^-- SM-T715 tablet begin/,\$p" "$1" | grep -q "^[^-]*switch:.*Lid Switch.*exec"' _ "$W/hl"
check "  t715-keys turns the screen off and on with the cover (SW_LID)" \
    sh -c 'grep -qx "SW_LID = 0" "$1" && grep -q "def cover(self, closed):" "$1" && grep -q "etype == EV_SW and code == SW_LID" "$1"' _ "$W/keys"
LID=/etc/systemd/logind.conf.d/90-t715-lid.conf
get $LID; cp "$W/f" "$W/lid.conf"
check "logind ignores the lid switch ($LID: HandleLidSwitch, -ExternalPower, -Docked = ignore), identical to rootfs/overlay" \
    sh -c 'for k in HandleLidSwitch HandleLidSwitchExternalPower HandleLidSwitchDocked; do grep -qx "$k=ignore" "$1" || exit 1; done &&
           cmp -s "$1" /our-overlay/etc/systemd/logind.conf.d/90-t715-lid.conf' _ "$W/lid.conf"
: > "$W/logind-dropins"
for d in /etc/systemd/logind.conf.d /usr/lib/systemd/logind.conf.d /usr/local/lib/systemd/logind.conf.d; do
    dfs "ls -p $d" | awk -F/ -v d="$d" '$6 ~ /\.conf$/ {print $6 "\t" d "/" $6}' >> "$W/logind-dropins"
done
last="$(sort "$W/logind-dropins" | tail -n1 | cut -f2)"
others=""
while IFS=$'\t' read -r _ path; do
    [ "$path" = "$LID" ] && continue
    cat_ "$path" | grep -Eq '^[[:space:]]*HandleLidSwitch' && others="$others $path"
done < "$W/logind-dropins"
check "  it sorts after every logind drop-in ($(cut -f1 "$W/logind-dropins" | sort | tr '\n' ' ')), and no other one sets a lid action${others:+:$others}" \
    sh -c '[ "$1" = "$2" ] && [ -z "$3" ]' _ "$last" "$LID" "$others"

echo "== touch layer P1: on-screen keyboard =="
SQ=/etc/systemd/user/t715-squeekboard.service
get $SQ; cp "$W/f" "$W/sq.unit"
check "t715-squeekboard.service: ExecStart=/usr/bin/squeekboard, Restart=on-failure, PartOf= and WantedBy=graphical-session.target, identical to rootfs/overlay" \
    sh -c 'grep -qx "ExecStart=/usr/bin/squeekboard" "$1" && grep -qx "Restart=on-failure" "$1" &&
           grep -qx "PartOf=graphical-session.target" "$1" && grep -qx "WantedBy=graphical-session.target" "$1" &&
           cmp -s "$1" /our-overlay/etc/systemd/user/t715-squeekboard.service' _ "$W/sq.unit"
check "  the keyboard's setting comes back at every login" \
    grep -qx 'ExecStartPre=/usr/bin/gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true' "$W/sq.unit"
check "  /usr/bin/squeekboard is squeekboard's binary (a regular file)" test "$(ftype /usr/bin/squeekboard)" = regular
t="$(resolve /etc/systemd/user/graphical-session.target.wants/t715-squeekboard.service || true)"
check "t715-squeekboard.service enabled for every user (graphical-session.target.wants -> ${t:-missing})" \
    test "$t" = $SQ
check "  no Hyprland launch of squeekboard left in alarm's config (uwsm-app lost it at boot), squeekboard's own unit not enabled" \
    sh -c '! grep -rqE "(launch|exec)_on_start\(.*squeekboard|uwsm-app.*squeekboard" "$1/alarm/.config/hypr" &&
           ! debugfs -R "stat /etc/systemd/user/graphical-session.target.wants/mobi.phosh.OSK.service" /img/rootfs.img 2>/dev/null | grep -q "^Inode:"' _ "$W/home"
check "  its layer without animation and above a lock (tablet block)" \
    sh -c 'grep -q "namespace = \"^osk\$\" }, no_anim = true" "$1" &&
           grep -q "namespace = \"^osk\$\" }, above_lock = 2" "$1"' _ "$W/hl"
get /etc/environment.d/20-t715-osk.conf; cp "$W/f" "$W/osk.env"
for kv in QT_IM_MODULE=wayland GTK_IM_MODULE=wayland INPUT_METHOD=none XMODIFIERS=@im=none SDL_IM_MODULE=none; do
    check "/etc/environment.d/20-t715-osk.conf: $kv" grep -qx "$kv" "$W/osk.env"
done
check "  Omarchy's 10-omarchy-fcitx.conf, which it overrides by sorting after it, is in /usr/lib/environment.d" \
    exists /usr/lib/environment.d/10-omarchy-fcitx.conf
check "fcitx5 held off by a condition (omarchy-fcitx5.service.d/10-t715-osk.conf)" \
    grep -qx 'ConditionPathExists=%h/.config/t715-omarchy/fcitx5' <(cat_ /etc/systemd/user/omarchy-fcitx5.service.d/10-t715-osk.conf)
check "  Omarchy's omarchy-fcitx5.service present, not masked (its first run enables it)" \
    sh -c 'debugfs -R "stat /usr/lib/systemd/user/omarchy-fcitx5.service" /img/rootfs.img 2>/dev/null | grep -q "^Inode:" &&
           [ "$1" != /dev/null ] && [ "$2" != /dev/null ]' _ \
    "$(linkto /etc/systemd/user/omarchy-fcitx5.service 2>/dev/null || true)" \
    "$(linkto /home/alarm/.config/systemd/user/omarchy-fcitx5.service 2>/dev/null || true)"
check "  the opt-in flag is absent for alarm (~/.config/t715-omarchy/fcitx5)" absent /home/alarm/.config/t715-omarchy/fcitx5
get /home/alarm/.config/dconf/user; cp "$W/f" "$W/dconf"
check "alarm's dconf database holds the OSK gsetting (screen-keyboard-enabled; its value: the smoke check)" \
    grep -aq 'screen-keyboard-enabled' "$W/dconf"
check "  and the keyboard's layout, locale.env's first (input-sources; its value: the smoke check)" \
    sh -c 'grep -aq "input-sources" "$1" && grep -aq "xkb" "$1"' _ "$W/dconf"
LAYOUT=/usr/share/t715-omarchy/squeekboard/keyboards/terminal
for l in us fr; do
    get $LAYOUT/$l.yaml; cp "$W/f" "$W/layout-$l"
    check "squeekboard terminal layout $l.yaml with Esc: GPL-3.0-or-later header, identical to rootfs/overlay" \
        sh -c 'head -n1 "$1" | grep -qx "# SPDX-License-Identifier: GPL-3.0-or-later" &&
               grep -q "Esc-small Tab-small" "$1" && cmp -s "$1" "/our-overlay/usr/share/t715-omarchy/squeekboard/keyboards/terminal/$2.yaml"' _ "$W/layout-$l" "$l"
    check "  linked as alarm's ~/.local/share/squeekboard/keyboards/terminal/$l.yaml" \
        test "$(linkto /home/alarm/.local/share/squeekboard/keyboards/terminal/$l.yaml 2>/dev/null)" = $LAYOUT/$l.yaml
done
check "  fr.yaml: AZERTY rows (squeekboard's terminal/fr)" grep -q '"a z e r t y u i o p"' "$W/layout-fr"
check "  their license notice next to them ($LAYOUT/NOTICE, both files)" \
    sh -c 'grep -q "GPL-3.0-or-later" "$1" && grep -q "us.yaml and fr.yaml" "$1"' _ "$(get $LAYOUT/NOTICE; cp "$W/f" "$W/notice"; echo "$W/notice")"
get /usr/share/t715-omarchy/MANIFEST.image; cp "$W/f" "$W/manifest"
check "build records: the touch layer's user steps all ok" \
    sh -c 'for s in "hyprland.lua: tablet block" "gsettings: screen-keyboard-enabled" "gsettings: input-sources" "squeekboard: terminal layouts" "menu: dead rows"; do
               grep -Eq "^  $s +ok( |\$)" "$1" || exit 1
           done' _ "$W/manifest"

echo "== touch layer P2: packages and Omarchy's patches (docs/image/ROOTFS.md) =="
for n in omamobile-omarchy omamobile-shell; do
    want="$(sed -n 's/^pkgver=//p' /our-pkg/$n/PKGBUILD)-$(sed -n 's/^pkgrel=//p' /our-pkg/$n/PKGBUILD)"
    check "$n installed, the pkg/$n build ($(pkg_ver "$n"); pkg/$n/PKGBUILD: $want)" test "$(pkg_ver "$n")" = "$want"
done
check "omamobile-apps, omamobile-owl-widgets, omamobile-update not installed" \
    sh -c '! grep -Eqx "omamobile-(apps|owl-widgets|update|keyring|firstboot)" "$1"' _ "$W/pkgs"
PS=/var/lib/omamobile/omarchy-patches
get $PS/status.json; cp "$W/f" "$W/pstatus"
get $PS/state.json; cp "$W/f" "$W/pstate"
dfs "ls -p /usr/share/omamobile/omarchy/patches" | awk -F/ '$6 ~ /\.patch$/ {print $6}' | sort > "$W/series"
# The JSON the applier writes (indent 2, sorted keys): a list's items one per line.
jlist() { awk -v k="\"$2\": [" 'index($0, k) { if (index($0, "]")) exit; f = 1; next } f && index($0, "]") { exit } f { gsub(/[ ",]/, ""); print }' "$1"; }
check "the series: upstream's 25 patches and ours, 0014 for the lock, 0028's narrow logo, without 0012, 0016 (phone-only)" \
    sh -c '[ "$(wc -l < "$1")" = 28 ] && grep -Eq "^0028-" "$1" && grep -qx t715-update-without-kernel-package.patch "$1" && grep -qx t715-pacman-keeps-alarm.patch "$1" && grep -qx t715-lock-blank-through-keys.patch "$1" && grep -Eq "^0014-" "$1" && ! grep -Eq "^(0012|0016)-" "$1"' _ "$W/series"
check "  bridge-4.0.4-menu-first-frame.patch kept (it targets 4.0.6)" grep -qx 'bridge-4.0.4-menu-first-frame.patch' "$W/series"
check "applier status: result ok, nothing failed" \
    sh -c 'grep -q "\"result\": \"ok\"" "$1" && grep -q "\"failed\": null" "$1"' _ "$W/pstatus"
check "applier status: every patch of the series applied, none found upstream" \
    sh -c '[ "$1" = "$(cat "$3")" ] && [ -z "$2" ]' _ "$(jlist "$W/pstatus" applied | sort)" "$(jlist "$W/pstatus" upstream)" "$W/series"
check "applier state: applied to the installed omarchy ($(pkg_ver omarchy))" \
    grep -q "\"omarchy\": \"omarchy $(pkg_ver omarchy)\"" "$W/pstate"
awk '/^    "usr\// { gsub(/[":{ ]/, ""); f = $0 } /"patched":/ { gsub(/[",]/, "", $2); print f "\t" $2 }' "$W/pstate" > "$W/pfiles"
bad=""
while IFS=$'\t' read -r rel sha; do
    get "/$rel"
    [ "$(sha256sum < "$W/f" | cut -d' ' -f1)" = "$sha" ] || bad="$bad $rel"
done < "$W/pfiles"
check "every patched file is the applier's ($(wc -l < "$W/pfiles") files, sha256 as recorded: verify)" \
    sh -c '[ -s "$1" ] && [ -z "$2" ]' _ "$W/pfiles" "$bad"
check "  0003: the lock's number pad is in Omarchy's shell" exists /usr/share/omarchy/shell/plugins/lock/Keypad.qml
check "  the bridge: the menu card waits for its first frame" grep -q 'property bool cardSettled: false' <(cat_ /usr/share/omarchy/shell/plugins/menu/Menu.qml)
ou="$(resolve /usr/bin/omarchy-update || true)"
check "  no 0012: omarchy-update is Omarchy's own (${ou:-unresolved})" sh -c '[ -n "$2" ] && ! grep -q omamobile-update "$1"' _ "$(get "${ou:-/nonexistent}"; cp "$W/f" "$W/ou"; echo "$W/ou")" "$ou"
check "  0020's touch wording switched on (/etc/environment.d/30-t715-touch.conf)" \
    grep -qx 'OMARCHY_NOTIFICATION_PHRASING=touch' <(cat_ /etc/environment.d/30-t715-touch.conf)
check "build records: install-mobile.sh applied and verified the series" \
    sh -c 'grep -Eq "^  patches: apply +ok" "$1" && grep -Eq "^  patches: verify +ok" "$1" && grep -Eq "^  patches: verify at finalize +ok" "$1"' _ "$W/manifest"

echo "== touch layer P2: the touch shell for alarm =="
SH=/usr/share/omamobile/shell
for p in omamobile.bar omamobile.quicksettings omamobile.launcher omamobile.switcher omamobile.home omamobile.keyboard omamobile.back omamobile.call; do
    check "plugin $p shipped and linked (~/.config/omarchy/plugins/$p -> $SH/plugins/$p)" \
        sh -c '[ "$1" = "$2" ]' _ "$(linkto "/home/alarm/.config/omarchy/plugins/$p" 2>/dev/null)" "$SH/plugins/$p"
done
for p in omamobile.fingerprint omamobile.update omamobile.access; do
    check "phone plugin $p neither shipped nor linked" sh -c '! debugfs -R "stat \"$1\"" /img/rootfs.img 2>/dev/null | grep -q "^Inode:" && ! debugfs -R "stat \"$2\"" /img/rootfs.img 2>/dev/null | grep -q "^Inode:"' _ "$SH/plugins/$p" "/home/alarm/.config/omarchy/plugins/$p"
done
get $SH/profile/shell.json; cp "$W/f" "$W/profile-shell"
get /home/alarm/.config/omarchy/shell.json; cp "$W/f" "$W/alarm-shell"
check "alarm's shell.json is the tablet profile (pkg/omamobile-shell/tablet-shell.json)" \
    sh -c 'cmp -s "$1" "$2" && cmp -s "$1" /our-pkg/omamobile-shell/tablet-shell.json' _ "$W/alarm-shell" "$W/profile-shell"
check "  bar omamobile.bar, the drawer at 6 columns, the call card, no other phone plugin" \
    sh -c 'grep -q "\"id\": \"omamobile.bar\"" "$1" && grep -q "\"columns\": 6" "$1" && grep -q "omamobile\.call" "$1" && ! grep -Eq "omamobile\.(fingerprint|update|access)" "$1"' _ "$W/alarm-shell"
check "  Omarchy's idle timers 0 (screensaver and lock off; t715-idle turns the screen off)" \
    sh -c 'sed -n "/\"idle\": {/,/}/p" "$1" | grep -q "\"screensaver\": 0" &&
           sed -n "/\"idle\": {/,/}/p" "$1" | grep -q "\"lock\": 0"' _ "$W/alarm-shell"
sed -n '/"disabledPlugins": \[/,/\]/p' "$W/alarm-shell" > "$W/disabled"
check "  Omarchy's 18 bar-widget-only plugins in disabledPlugins, not the menu, media or a service" \
    sh -c '[ "$(grep -c "^    \"omarchy\.[a-z-]*\",\{0,1\}$" "$1")" = 18 ] &&
           ! grep -Eq "\"omarchy\.(menu|media|background|lock|notifications|polkit|idle|battery|nightlight|clipboard|image-picker|osd)\"" "$1"' _ "$W/disabled"
get $SH/plugins/omamobile.home/TogglesWidget.qml; cp "$W/f" "$W/toggles"
get $SH/plugins/omamobile.bar/Bar.qml; cp "$W/f" "$W/bar"
check "  0004: the home toggles watch notifications.json (no dndState poll), the bar's modem and call watchers on" \
    sh -c 'grep -q "/.local/state/omarchy/notifications.json" "$1" && ! grep -q dndState "$1" &&
           grep -q "running: root.cellWatchEnabled" "$2" && grep -q "running: root.callWatchEnabled" "$2" &&
           grep -Eq "\"cellWatch\": *true" "$3" && grep -Eq "\"callWatch\": *true" "$3"' _ "$W/toggles" "$W/bar" "$W/alarm-shell"
get $SH/profile/home.json; cp "$W/f" "$W/profile-home"
get /home/alarm/.config/omamobile/home.json; cp "$W/f" "$W/alarm-home"
check "alarm's home.json is the tablet's (pkg/omamobile-shell/tablet-home.json): 6x8, Chromium, Firefox, Phone, Messages" \
    sh -c 'cmp -s "$1" "$2" && cmp -s "$1" /our-pkg/omamobile-shell/tablet-home.json && grep -q "\"columns\": 6" "$1" && grep -q "\"rows\": 8" "$1" &&
           grep -q "\"app\": \"firefox\"" "$1" && grep -q "\"app\": \"org.omamobile.Phone\"" "$1" &&
           grep -q "\"app\": \"org.omamobile.Messages\"" "$1" && grep -q "\"app\": \"chromium\"" "$1"' _ "$W/alarm-home" "$W/profile-home"
sed -n 's/^    "\(omamobile-[a-z0-9-]*\)|.*/\1/p' /our-user-setup.sh > "$W/premarks"
missing=""
while IFS= read -r m; do
    exists "/home/alarm/.local/state/omarchy/done/$m" || missing="$missing $m"
done < "$W/premarks"
check "omamobile-setup-user's skipped steps pre-marked ($(wc -l < "$W/premarks") markers from rootfs/omarchy-user-setup.sh${missing:+; missing:$missing})" \
    sh -c '[ "$(wc -l < "$1")" -ge 15 ] && [ -z "$2" ]' _ "$W/premarks" "$missing"
check "  its own steps ran: profile, home and back plugins, hidden dev tools (markers)" \
    sh -c 'for m in omamobile-shell-profile omamobile-home-plugin omamobile-back-plugin omamobile-keyboard-plugin omamobile-hide-dev-tools welcome-keybindings-not-applicable; do
               debugfs -R "stat \"/home/alarm/.local/state/omarchy/done/$m\"" /img/rootfs.img 2>/dev/null | grep -q "^Inode:" || exit 1
           done'
check "build records: omamobile-setup-user ok, shell.json, home.json and plugin links ok" \
    sh -c 'for s in "omamobile-setup-user" "omamobile: shell.json" "omamobile: home.json" "omamobile: plugin links"; do
               grep -Eq "^  $s +ok( |\$)" "$1" || exit 1
           done' _ "$W/manifest"
check "omamobile-setup-user.service masked for every user (setup ran at build time)" \
    test "$(linkto /etc/systemd/user/omamobile-setup-user.service 2>/dev/null)" = /dev/null
phone_bins=""
for b in omamobile-keys omamobile-sleepd omamobile-update omamobile-fp-enroll \
         omamobile-nfc-open omamobile-onboarding omamobile-osk-guard omamobile-portal-access omamobile-open-intent; do
    exists "/usr/bin/$b" && phone_bins="$phone_bins $b"
done
check "no phone-only helper (omamobile-keys, -sleepd, -update, NFC, fingerprint, osk-guard, portal)${phone_bins:+: found$phone_bins}" test -z "$phone_bins"
check "the PIN row's tool: omamobile-set-pin, and sudo's switch for it" \
    sh -c '[ -n "$1" ] && [ -n "$2" ]' _ "$(exists /usr/bin/omamobile-set-pin && echo y)" "$(exists /usr/local/sbin/t715-sudo-asks-password && echo y)"
tel_missing=""
for b in omamobile-call-watch omamobile-cell-watch omatel-agent omaphone omamessages shannon-loader shannonctl t715-sim-pin t715-mobile-settings mmcli; do
    exists "/usr/bin/$b" || tel_missing="$tel_missing $b"
done
check "telephony: the bar's watchers, omatel-agent, Phone, Messages, the modem tools and mmcli${tel_missing:+; missing:$tel_missing}" test -z "$tel_missing"
check "telephony: shannon-nv-provision and shannon-modem-prepare enabled at boot" \
    sh -c '[ -n "$1" ] && [ -n "$2" ]' _ "$(linkto /etc/systemd/system/multi-user.target.wants/shannon-nv-provision.service 2>/dev/null)" \
        "$(linkto /etc/systemd/system/multi-user.target.wants/shannon-modem-prepare.service 2>/dev/null)"
check "telephony: omatel-agent and t715-call-profile enabled for every user" \
    sh -c '[ -n "$1" ] && [ -n "$2" ]' _ "$(linkto /etc/systemd/user/default.target.wants/omatel-agent.service 2>/dev/null)" \
        "$(linkto /etc/systemd/user/default.target.wants/t715-call-profile.service 2>/dev/null)"
check "telephony: ModemManager masked, shannond's facade owns its bus name" \
    test "$(linkto /etc/systemd/system/ModemManager.service 2>/dev/null)" = /dev/null
mp_missing=""
for f in /usr/bin/t715-modem-power /usr/lib/systemd/system/t715-modem-power@.service \
         /usr/lib/systemd/system/t715-modem-standby.timer /usr/lib/systemd/system/t715-modem-standby.service \
         /usr/share/polkit-1/rules.d/50-t715-modem-power.rules; do
    exists "$f" || mp_missing="$mp_missing $f"
done
check "telephony: the modem's switch, t715-modem-power, its units and polkit rule${mp_missing:+; missing:$mp_missing}" test -z "$mp_missing"
mp_standby=$(exists /var/lib/t715-modem-power/standby && echo set || true)
check "  no standby setting in the image: the modem stays on with the screen off" test -z "$mp_standby"
get /usr/share/omamobile/shell/plugins/omamobile.quicksettings/TilesModel.js; cp "$W/f" "$W/tiles"
check "  the Modem tile in the quick settings catalogue (pkg/omamobile-shell 0011)" \
    grep -q '{ id: "modem", label: "Modem" }' "$W/tiles"
rot_missing=""
for f in /usr/local/bin/t715-rotate /etc/systemd/user/omamobile-autorotate.service /etc/udev/rules.d/61-t715-accelerometer.rules /usr/lib/systemd/system/iio-sensor-proxy.service; do
    exists "$f" || rot_missing="$rot_missing $f"
done
check "rotation: t715-rotate, its unit and iio-sensor-proxy${rot_missing:+; missing:$rot_missing}" test -z "$rot_missing"
check "rotation: not enabled --global, so the Rotation tile can turn it off" \
    sh -c '[ -z "$1" ]' _ "$(linkto /etc/systemd/user/graphical-session.target.wants/omamobile-autorotate.service 2>/dev/null)"
check "rotation: on for alarm from the first boot (omarchy-user-setup.sh)" \
    test "$(linkto /home/alarm/.config/systemd/user/graphical-session.target.wants/omamobile-autorotate.service 2>/dev/null)" = /etc/systemd/user/omamobile-autorotate.service
get /usr/bin/omarchy-update-restart; cp "$W/f" "$W/update-restart"
check "pacman: omarchy update knows there is no kernel package" grep -qx 'kernel_updated=false' "$W/update-restart"
get /usr/bin/omarchy-refresh-pacman; cp "$W/f" "$W/refresh-pacman"
check "pacman: omarchy-refresh-pacman refuses on Arch Linux ARM's pacman.conf" grep -qF "grep -q '^\[alarm\]' /etc/pacman.conf" "$W/refresh-pacman"
t="$(resolve /etc/systemd/user/timers.target.wants/t715-update-check.timer || true)"
check "t715-update-check.timer enabled for every user (timers.target.wants -> ${t:-missing})" test "$t" = /etc/systemd/user/t715-update-check.timer
check "  /usr/local/bin/t715-update-check is executable" sh -c 'dfs_mode=$(debugfs -R "stat /usr/local/bin/t715-update-check" "$1" 2>/dev/null); echo "$dfs_mode" | grep -q "Mode:  *0755"' _ "$IMG"
br_missing=""
for f in /usr/bin/chromium /usr/bin/t715-chromium-update /usr/lib/t715-chromium/prepare-root /usr/share/applications/chromium.desktop \
         /var/lib/t715-chromium/root/usr/lib/chromium/chromium /var/lib/t715-chromium/root/usr/share/icons/hicolor/256x256/apps/chromium.png \
         /usr/lib/firefox/firefox; do
    exists "$f" || br_missing="$br_missing $f"
done
check "browsers: Chromium (launcher, update tool, Debian's root) and Firefox${br_missing:+; missing:$br_missing}" test -z "$br_missing"
check "browsers: Chromium's daily update enabled" \
    sh -c '[ -n "$1" ]' _ "$(linkto /etc/systemd/system/timers.target.wants/t715-chromium-update.timer 2>/dev/null)"
get /home/alarm/.config/mimeapps.list; cp "$W/f" "$W/mimeapps"
check "browsers: Chromium is alarm's default for http, https and text/html" \
    sh -c 'grep -q "^x-scheme-handler/http=chromium.desktop" "$1" && grep -q "^x-scheme-handler/https=chromium.desktop" "$1" && grep -q "^text/html=chromium.desktop" "$1"' _ "$W/mimeapps"

echo "== camera: the software ISP stack (docs/hardware/CAMERA.md) =="
for p in t715-camera libcamera libcamera-ipa omacam; do
    check "$p installed ($(pkg_ver "$p"))" has_pkg "$p"
done
cam_missing=""
for f in /usr/bin/t715-photo /usr/bin/t715-camera /usr/share/applications/t715-camera-rear.desktop \
         /usr/share/applications/t715-camera-front.desktop /usr/lib/udev/rules.d/71-t715-dma-heap.rules \
         /etc/libcamera/configuration.yaml /etc/omacam/lenses.toml /usr/bin/omacam \
         /usr/share/applications/omacam.desktop /usr/share/icons/hicolor/scalable/apps/omacam.svg; do
    exists "$f" || cam_missing="$cam_missing $f"
done
check "both camera apps: commands, drawer entries, icon, dma-heap rule, libcamera and lens configuration${cam_missing:+; missing:$cam_missing}" test -z "$cam_missing"
check "libcamera ships its library (usr/lib/libcamera.so* in the package's files)" \
    sh -c 'grep -q "^usr/lib/libcamera\.so" "$1"' _ \
    "$(get "/var/lib/pacman/local/libcamera-$(pkg_ver libcamera)/files"; cp "$W/f" "$W/lc-lib-files"; echo "$W/lc-lib-files")"
check "/etc/libcamera/configuration.yaml is pkg/t715-camera's: the software ISP on the CPU (mode: cpu)" \
    sh -c 'cmp -s "$1" /our-pkg/t715-camera/libcamera-configuration.yaml && grep -qx "  software_isp:" "$1" && grep -qx "    mode: cpu" "$1"' _ \
    "$(get /etc/libcamera/configuration.yaml; cp "$W/f" "$W/lccfg"; echo "$W/lccfg")"
check "  the dma-heap udev rule in place, pkg's byte for byte: dma_heap system|reserved to group video, 0660" \
    sh -c 'cmp -s "$1" /our-pkg/t715-camera/71-t715-dma-heap.rules &&
           grep -q "^SUBSYSTEM==\"dma_heap\", KERNEL==\"system|reserved\", GROUP=\"video\", MODE=\"0660\"$" "$1"' _ \
    "$(get /usr/lib/udev/rules.d/71-t715-dma-heap.rules; cp "$W/f" "$W/dma.rules"; echo "$W/dma.rules")"
check "  omacam's lens table is pkg's, for this tablet (gts28ltexx, rear + front, 15 fps preview, 2-thread merge)" \
    sh -c 'cmp -s "$1" /our-pkg/t715-camera/omacam-lenses.toml && grep -qx "device = \"gts28ltexx\"" "$1" &&
           grep -qF "id = \"/base/i2c-cam-rear/camera-sensor@37\"" "$1" && grep -qF "id = \"/base/i2c-cam-front/camera-sensor@35\"" "$1" &&
           grep -qx "preview_fps = 15" "$1" && grep -qx "merge_threads = 2" "$1"' _ \
    "$(get /etc/omacam/lenses.toml; cp "$W/f" "$W/lenses"; echo "$W/lenses")"
check "libcamera holds the two cameras' tuning files (s5k4h5, s5k6b2, in its or libcamera-ipa's files)" \
    sh -c 'grep -hq "s5k4h5\.yaml" "$1" "$2" && grep -hq "s5k6b2\.yaml" "$1" "$2"' _ \
    "$W/lc-lib-files" \
    "$(get "/var/lib/pacman/local/libcamera-ipa-$(pkg_ver libcamera-ipa)/files"; cp "$W/f" "$W/lc-ipa-files"; echo "$W/lc-ipa-files")"
seqs="$(dfs "ls -p /usr/lib/firmware/t715" | awk -F/ '$6 ~ /\.seq$/ {print $6}' | tr '\n' ' ')"
check "no sensor .seq table in /usr/lib/firmware/t715 (Samsung's, made on the tablet)${seqs:+: found$seqs}" \
    sh -c '[ -z "$1" ]' _ "$seqs"
t="$(resolve /etc/systemd/system/multi-user.target.wants/t715-camera-tables.service || true)"
check "the tables' maker: t715-camera-tables.service enabled (-> ${t:-missing}), so the first boot makes them" \
    test "$t" = /usr/lib/systemd/system/t715-camera-tables.service
check "  /usr/bin/t715-camera-tables is pkg's, byte for byte, mode 0755" \
    sh -c '[ "$1" = 0755 ] && cmp -s "$2" /our-pkg/t715-camera/t715-camera-tables' _ \
    "$(fmode /usr/bin/t715-camera-tables)" \
    "$(get /usr/bin/t715-camera-tables; cp "$W/f" "$W/camtab"; echo "$W/camtab")"

echo "== Pi: the terminal coding agent (pkg/pi-coding-agent) =="
check "pi-coding-agent installed ($(pkg_ver pi-coding-agent))" has_pkg pi-coding-agent
check "/usr/bin/pi exists and is pkg's wrapper (mode 0755)" \
    sh -c '[ "$1" = 0755 ] && cmp -s "$2" /our-pkg/pi-coding-agent/pi' _ \
    "$(fmode /usr/bin/pi)" \
    "$(get /usr/bin/pi; cp "$W/f" "$W/pi"; echo "$W/pi")"
check "  it runs /opt/pi's cli.js, telemetry and update checks off (defaults the owner can override)" \
    sh -c 'grep -q ": \"\${PI_TELEMETRY:=0}\"" "$1" && grep -q ": \"\${PI_SKIP_VERSION_CHECK:=1}\"" "$1" &&
           grep -qx "exec /usr/bin/node /opt/pi/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js \"\$@\"" "$1"' _ "$W/pi"
check "  that cli.js is in the image" \
    exists /opt/pi/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js
mkdir -p "$W/pitree"
dfs "rdump /opt/pi $W/pitree" >/dev/null 2>&1 || true
check "  the drawer entry is pkg's pi.desktop (Exec=pi, a terminal app)" \
    sh -c 'cmp -s "$1" /our-pkg/pi-coding-agent/pi.desktop && grep -qx "Exec=pi" "$1" && grep -qx "Terminal=true" "$1"' _ \
    "$(get /usr/share/applications/pi.desktop; cp "$W/f" "$W/pi.desktop"; echo "$W/pi.desktop")"
check "  the licence where Arch looks for it (/usr/share/licenses/pi-coding-agent/LICENSE)" \
    exists /usr/share/licenses/pi-coding-agent/LICENSE
check "  no prebuilt .node helper under /opt/pi (none is 32-bit ARM; Pi reads the clipboard through wl-clipboard)" \
    sh -c '[ -d "$1/pi/node_modules" ] && [ -z "$(find "$1/pi" -name "*.node" -print -quit)" ]' _ "$W/pitree"
gps_missing=""
for f in /usr/bin/omamobile-gnss /usr/bin/t715-gps-capture /usr/lib/t715-gps/t715-gps-prepare /usr/lib/t715-gps/t715-gps-power \
         /usr/lib/systemd/system/t715-gpsd.service /usr/lib/systemd/system/t715-gps-nmea.socket /usr/lib/systemd/system/t715-gps-nmea@.service \
         /usr/lib/systemd/system/t715-gps-power.service /usr/share/polkit-1/rules.d/50-omamobile-gnss.rules; do
    exists "$f" || gps_missing="$gps_missing $f"
done
check "GPS: the package's commands, units and polkit rule${gps_missing:+; missing:$gps_missing}" test -z "$gps_missing"
check "GPS: no gpsd in the image, it comes from the tablet's own SYSTEM" absent /var/lib/t715-gps/root
check "GPS: Location is off in the image (the socket is not enabled)" absent /etc/systemd/system/sockets.target.wants/t715-gps-nmea.socket
get /usr/lib/systemd/system/t715-gpsd.service; cp "$W/f" "$W/gpsd.service"
check "GPS: gpsd has no network, no capability and no root" \
    sh -c 'grep -qx "PrivateNetwork=yes" "$1" && grep -qx "CapabilityBoundingSet=" "$1" && grep -qx "User=t715-gps" "$1"' _ "$W/gpsd.service"
get /usr/lib/systemd/system/t715-gps-power.service; cp "$W/f" "$W/gps-power.service"
check "GPS: the power line drops when gpsd goes" \
    sh -c 'grep -qx "BindsTo=t715-gps-power.service" "$1" && grep -qx "StopWhenUnneeded=yes" "$2" &&
           grep -qx "ExecStop=/usr/lib/t715-gps/t715-gps-power down" "$2"' _ "$W/gpsd.service" "$W/gps-power.service"
get /etc/geoclue/conf.d/90-t715-gps.conf; cp "$W/f" "$W/geoclue-gps"
get /usr/lib/systemd/system/geoclue.service.d/t715-gps.conf; cp "$W/f" "$W/geoclue-dropin"
check "GPS: GeoClue itself has no network (its GeoIP lookup survives [wifi] enable=false)" grep -qx 'PrivateNetwork=yes' "$W/geoclue-dropin"
check "GPS: GeoClue's only source is the receiver" \
    sh -c 'grep -q "^nmea-socket=/run/t715-gps/nmea.sock" "$1" &&
           [ "$(grep -c "^enable=false" "$1")" = 6 ] && [ "$(grep -c "^enable=true" "$1")" = 1 ]' _ "$W/geoclue-gps"

echo "== Claude Code: an installer, never Anthropic's code (docs/image/PACKAGES.md) =="
check "t715-claude-code installed ($(pkg_ver t715-claude-code))" has_pkg t715-claude-code
check "/usr/bin/t715-claude-install executable (mode 0755)" test "$(fmode /usr/bin/t715-claude-install)" = 0755
get /usr/share/licenses/t715-claude-code/LICENSE; cp "$W/f" "$W/cc-lic"
check "the licence is Yumi Lab's (MIT License)" \
    sh -c 'grep -q "MIT License" "$1" && grep -q "Yumi Lab" "$1"' _ "$W/cc-lic"
cc_missing=""
for f in /usr/share/t715-claude-code/installer/install.sh /usr/share/t715-claude-code/installer/MAX_VERSION \
         /usr/share/t715-claude-code/installer/lib/claude-release.sh /usr/share/t715-claude-code/installer/bin/claude-token-save; do
    exists "$f" || cc_missing="$cc_missing $f"
done
check "the installer tree is in (${cc_missing:+missing:$cc_missing})" test -z "$cc_missing"
check "nothing of Anthropic's: no /opt/claude-code" absent /opt/claude-code
check "nothing of Anthropic's: no /usr/local/bin/claude" absent /usr/local/bin/claude
# No token, anywhere: not even a file named like the token store. These trees
# are dumped once for the three greps below (read-only; rdump puts each
# directory inside its destination, which must exist).
mkdir -p "$W/cc"
for d in /etc /home /root /opt /usr/share/t715-claude-code; do
    dfs "rdump $d $W/cc" >/dev/null 2>&1 || true
done
oauth="$(find "$W/cc" -name .oauth_token -print -quit)"
check "no .oauth_token anywhere in /etc, /home, /root, /opt, /usr/share/t715-claude-code${oauth:+: found $oauth}" \
    test -z "$oauth"
tok="$(grep -rlIE 'sk-ant-[A-Za-z0-9]+-[A-Za-z0-9_-]{20,}' "$W/cc" 2>/dev/null | sed "s|^$W/cc||" | tr '\n' ' ')"
check "no OAuth token value (sk-ant-…) in /etc, /home, /root, /opt, /usr/share/t715-claude-code${tok:+: found in $tok}" \
    test -z "$tok"
envtok="$(grep -rlE 'CLAUDE_CODE_OAUTH_TOKEN' "$W/cc/etc" "$W/cc/home" "$W/cc/root" 2>/dev/null | sed "s|^$W/cc||" | tr '\n' ' ')"
check "no CLAUDE_CODE_OAUTH_TOKEN under /etc, /home, /root${envtok:+: found in $envtok}" test -z "$envtok"
# pkgrel=2's pieces: the guide the drawer opens, the drawer entry, and the
# manifest signature check with the release key it verifies against
# (pkg/t715-claude-code/PKGBUILD, docs/image/PACKAGES.md).
cc2_missing=""
for f in /usr/bin/t715-claude-guide /usr/share/applications/t715-claude-code.desktop \
         /usr/share/t715-claude-code/installer/lib/manifest-verify.sh \
         /usr/share/t715-claude-code/installer/anth-release-key.gpg; do
    exists "$f" || cc2_missing="$cc2_missing $f"
done
check "the guide, the drawer entry, the manifest check and the release key${cc2_missing:+; missing:$cc2_missing}" test -z "$cc2_missing"
check "/usr/bin/t715-claude-guide executable (mode 0755)" test "$(fmode /usr/bin/t715-claude-guide)" = 0755
check "t715-claude-install and t715-claude-guide are pkg's, byte for byte" \
    sh -c 'cmp -s "$1" /our-pkg/t715-claude-code/t715-claude-install && cmp -s "$2" /our-pkg/t715-claude-code/t715-claude-guide' _ \
    "$(get /usr/bin/t715-claude-install; cp "$W/f" "$W/cc-install"; echo "$W/cc-install")" \
    "$(get /usr/bin/t715-claude-guide; cp "$W/f" "$W/cc-guide"; echo "$W/cc-guide")"
get /usr/share/applications/t715-claude-code.desktop
check "t715-claude-code.desktop is pkg's (the drawer entry opens t715-claude-guide)" \
    cmp -s "$W/f" /our-pkg/t715-claude-code/t715-claude-code.desktop
check "manifest-verify.sh mode 0755, pkg's byte for byte (the check install.sh sources)" \
    sh -c '[ "$1" = 0755 ] && cmp -s "$2" /our-pkg/t715-claude-code/manifest-verify.sh' _ \
    "$(fmode /usr/share/t715-claude-code/installer/lib/manifest-verify.sh)" \
    "$(get /usr/share/t715-claude-code/installer/lib/manifest-verify.sh; cp "$W/f" "$W/mv.sh"; echo "$W/mv.sh")"
check "anth-release-key.gpg is pkg's, a dearmored OpenPGP key (0x99 0x02), not a detached signature" \
    sh -c 'cmp -s "$1" /our-pkg/t715-claude-code/anth-release-key.gpg && [ "$(od -An -tx1 -N2 "$1" | tr -d " \n")" = "9902" ]' _ \
    "$(get /usr/share/t715-claude-code/installer/anth-release-key.gpg; cp "$W/f" "$W/cc-key"; echo "$W/cc-key")"

echo "== no credential in the image (the owner signs in on the tablet) =="
# The dump above already holds /etc, /home, /root, /opt and the installer's
# tree: look for the credential stores in it, for root and every home.
cred="$(find "$W/cc/etc" "$W/cc/home" "$W/cc/root" \( -path '*/.pi/agent/auth.json' -o -path '*/.claude/.credentials.json' -o -path '*/.claude/.oauth_token' \) -print 2>/dev/null | sed "s|^$W/cc||" | tr '\n' ' ')"
check "no Pi or Claude credential store in /etc, /root or a home: .pi/agent/auth.json, .claude/.credentials.json, .claude/.oauth_token${cred:+: found$cred}" \
    sh -c '[ -d "$1/home" ] && [ -d "$1/root" ] && [ -z "$2" ]' _ "$W/cc" "$cred"
clset="$(find "$W/cc/etc" "$W/cc/home" "$W/cc/root" -path '*/.claude/settings.json' -exec grep -lE 'CLAUDE_CODE_OAUTH_TOKEN' {} + 2>/dev/null | sed "s|^$W/cc||" | tr '\n' ' ')"
check "no settings.json under .claude/ holds CLAUDE_CODE_OAUTH_TOKEN${clset:+: found$clset}" test -z "$clset"

check "telephony: no NV copy and no APN in the image" \
    sh -c '! debugfs -R "stat /var/lib/shannon/nv" /img/rootfs.img 2>/dev/null | grep -q "^Inode:" && ! debugfs -R "stat /etc/shannond.env" /img/rootfs.img 2>/dev/null | grep -q "^Inode:"'
units=""
for u in /usr/lib/systemd/user/omamobile-sleepd.service /usr/lib/systemd/user/omamobile-osk-guard.service \
         /usr/lib/systemd/user/omamobile-portal-access.service /usr/lib/systemd/system/omamobile-nfc-open.service \
         /usr/lib/systemd/user/omarchy-fcitx5.service.d/omamobile.conf /usr/lib/environment.d/20-omamobile-osk.conf \
         /etc/xdg/xdg-desktop-portal/hyprland-portals.conf /usr/share/omamobile/squeekboard /usr/share/omamobile/shell/hypr; do
    exists "$u" && units="$units $u"
done
check "no phone-only unit, no second OSK, fcitx5 or portal mechanism${units:+: found$units}" test -z "$units"
enabled=""
for d in /etc/systemd/system /etc/systemd/user /usr/lib/systemd/user /usr/lib/systemd/system; do
    for w in $(dfs "ls -p $d" | awk -F/ '$6 ~ /\.wants$/ {print $6}'); do
        dfs "ls -p $d/$w" | awk -F/ '{print $6}' | grep -E '^omamobile-' | grep -vx 'omamobile-setup-user.service' \
            | sed "s|^|$d/$w/|" >> "$W/omamobile-wants" || true
    done
done
check "no omamobile unit enabled but the masked setup-user ($(cat "$W/omamobile-wants" 2>/dev/null | tr '\n' ' '))" \
    sh -c '[ ! -s "$1" ]' _ "$W/omamobile-wants"
get /home/alarm/.config/hypr/looknfeel.lua; cp "$W/f" "$W/lnf2"
check "no phone.lua (maximize-all, omamobile-keys bindings) in alarm's Hyprland config" \
    sh -c '! grep -q "phone.lua" "$1" && ! grep -rq "omamobile-keys" "$2/alarm/.config/hypr"' _ "$W/lnf2" "$W/home"
check "no touch workspace swipe in alarm's Hyprland config, comments aside (it would fight the edge strips)" \
    sh -c '! grep -rhE "workspace_swipe_touch|workspace_swipe *=" "$1/alarm/.config/hypr" | grep -vqE "^[[:space:]]*--"' _ "$W/home"
check "  the keyboard's hide button above a lock, like the keyboard (tablet block)" \
    grep -q 'namespace = "^omamobile-osk-hide$" }, above_lock = 2' "$W/hl"
check "the call card stays above the lock (tablet block)" \
    grep -q 'namespace = "^omamobile-call(-top)?$" }, above_lock = 2' "$W/hl"
check "omamobile-set-pin, and no lock at login without its toggle" \
    sh -c 'test -n "$2" && grep -q "omarchy-toggle-enabled lock-on-start || exit 0" "$1"' _ "$W/hl" "$(exists /usr/bin/omamobile-set-pin && echo yes)"
check "t715-keys: Home goes to the touch shell's home page, held Home to its recents" \
    sh -c 'grep -q "\"omamobile.home\", \"goHome\"" "$1" && grep -q "\"toggle\", \"omamobile.switcher\"" "$1" && ! grep -q "toggle\", \"apps\"" "$1"' _ "$W/keys"
check "Omarchy's web apps in the drawer (HEY, YouTube), its Docker entry hidden" \
    sh -c '! grep -qx "NoDisplay=true" "$1/alarm/.local/share/applications/HEY.desktop" && ! grep -qx "NoDisplay=true" "$1/alarm/.local/share/applications/YouTube.desktop" &&
           grep -qx "NoDisplay=true" "$1/alarm/.local/share/applications/Docker.desktop"' _ "$W/home"

echo "== Bluetooth (docs/image/ROOTFS.md \"Bluetooth\") =="
for f in usr/local/sbin/t715-bt-addr etc/systemd/system/t715-bt-addr@.service etc/udev/rules.d/90-t715-bt-addr.rules; do
    get "/$f"
    check "/$f identical to rootfs/overlay" cmp -s "$W/f" "/our-overlay/$f"
done
check "/usr/local/sbin/t715-bt-addr mode 0755" test "$(fmode /usr/local/sbin/t715-bt-addr)" = 0755
BTFW=/usr/lib/firmware/brcm
fwsha="$(sha256sum < /bt-firmware.hcd | cut -d' ' -f1)"
for f in BCM4358A3.hcd bcm4358A3_V0086.0144.hcd; do
    if [ "$PUBLIC" = 1 ]; then check "public image: no $BTFW/$f" absent "$BTFW/$f"; continue; fi
    get "$BTFW/$f"
    check "$BTFW/$f: the vendor dump bcm4358A3_V0086.0144.hcd (sha256 ${fwsha:0:16}...), mode 0644" \
        sh -c '[ "$(sha256sum < "$1" | cut -d" " -f1)" = "$2" ] && [ "$3" = 0644 ]' _ "$W/f" "$fwsha" "$(fmode "$BTFW/$f")"
done
check "$BTFW/BCM.samsung,gts28ltexx.hcd -> BCM4358A3.hcd (btbcm's board-specific name)" \
    test "$(linkto "$BTFW/BCM.samsung,gts28ltexx.hcd" 2>/dev/null)" = BCM4358A3.hcd
fwls="$(dfs "ls -p /usr/lib/firmware" | awk -F/ '$6 != "" && $6 != "." && $6 != ".." {print $6}' | tr '\n' ' ')"
brls="$(dfs "ls -p $BTFW" | awk -F/ '$6 != "" && $6 != "." && $6 != ".." {print $6}' | sort | tr '\n' ' ')"
gtls="$(dfs "ls -p $BTFW/samsung-gts28" | awk -F/ '$6 != "" && $6 != "." && $6 != ".." {print $6}' | sort | tr '\n' ' ')"
if [ "$PUBLIC" = 1 ]; then
    check "public image: brcm/ holds no vendor file (${brls:-empty}; samsung-gts28/: ${gtls:-empty})" \
        sh -c '[ "$1" = "BCM.samsung,gts28ltexx.hcd brcmfmac4358-pcie.bin brcmfmac4358-pcie.txt samsung-gts28 " ] && [ -z "$2" ]' _ "$brls" "$gtls"
else
check "brcm/ holds the Bluetooth and Wi-Fi entries only (${brls:-empty}; samsung-gts28/: ${gtls:-empty}; /usr/lib/firmware: ${fwls:-empty}), no Samsung bcmdhd firmware" \
    sh -c '[ "$1" = "BCM.samsung,gts28ltexx.hcd BCM4358A3.hcd bcm4358A3_V0086.0144.hcd brcmfmac4358-pcie.bin brcmfmac4358-pcie.txt samsung-gts28 " ] &&
           [ "$3" = "nvram_net.txt " ] && ! printf "%s\n" "$2" | grep -qiE "brcmfmac|samsung-gts28|bcmdhd"' _ "$brls" "$fwls" "$gtls"
fi
for p in bluez bluez-utils; do
    check "$p installed ($(pkg_ver "$p"))" has_pkg "$p"
done
check "  btmgmt present (t715-bt-addr sets the address with it)" exists /usr/bin/btmgmt
t="$(resolve /etc/systemd/system/bluetooth.target.wants/bluetooth.service || true)"
check "bluetooth.service enabled (bluetooth.target.wants -> ${t:-missing})" \
    sh -c 'case "$1" in */bluetooth.service) exit 0 ;; *) exit 1 ;; esac' _ "$t"
BTA=/etc/systemd/user/bt-agent.service.d/10-t715-no-auto-accept.conf
get $BTA; cp "$W/f" "$W/bta.conf"
check "Omarchy's auto-accept agent never starts: $BTA, a condition that cannot hold, identical to rootfs/overlay" \
    sh -c 'grep -qx "ConditionPathExists=/dev/null/t715-no-auto-accept" "$1" &&
           cmp -s "$1" /our-overlay/etc/systemd/user/bt-agent.service.d/10-t715-no-auto-accept.conf' _ "$W/bta.conf"
check "  Omarchy's unit is the auto-accept one (bt-agent -c NoInputNoOutput), as the drop-in assumes" \
    grep -qx 'ExecStart=/usr/bin/bt-agent -c NoInputNoOutput' <(cat_ /usr/lib/systemd/user/bt-agent.service)
bta_dirs="$(dfs "ls -p /etc/systemd/user/bt-agent.service.d" | awk -F/ '$6 != "" && $6 != "." && $6 != ".." {print $6}' | tr '\n' ' ')"
check "  no other drop-in that could reset the condition (/etc/systemd/user/bt-agent.service.d: ${bta_dirs:-empty}; none in /usr/lib)" \
    sh -c '[ "$1" = "10-t715-no-auto-accept.conf " ] && ! debugfs -R "stat /usr/lib/systemd/user/bt-agent.service.d" /img/rootfs.img 2>/dev/null | grep -q "^Inode:"' _ "$bta_dirs"
check "  not masked (Omarchy's first run enables it with five other units in one command, which a mask fails)" \
    sh -c '[ "$1" != /dev/null ] && [ "$2" != /dev/null ]' _ \
    "$(linkto /etc/systemd/user/bt-agent.service 2>/dev/null || true)" "$(linkto /home/alarm/.config/systemd/user/bt-agent.service 2>/dev/null || true)"
check "  pairing goes through the touch shell's agent instead (omamobile-bt-agent, KeyboardDisplay)" \
    grep -q 'KeyboardDisplay' <(cat_ /usr/bin/omamobile-bt-agent)
check "pipewire-audio installed ($(pkg_ver pipewire-audio)): PipeWire's BlueZ plugin for Bluetooth audio" has_pkg pipewire-audio
check "pipewire-pulse installed ($(pkg_ver pipewire-pulse)): the PulseAudio server Firefox talks to" has_pkg pipewire-pulse
check "  pipewire-pulse.socket enabled for every user" \
    exists /etc/systemd/user/sockets.target.wants/pipewire-pulse.socket
UCM=/usr/share/alsa/ucm2/conf.d/wm1814
for f in wm1814.conf HiFi.conf; do
    get $UCM/$f; cp "$W/f" "$W/ucm-$f"
    check "$UCM/$f identical to rootfs/overlay (the wm1814 card's UCM profile, from the Phosh image, 159d3e9)" \
        cmp -s "$W/ucm-$f" "/our-overlay/usr/share/alsa/ucm2/conf.d/wm1814/$f"
done
get /usr/lib/firefox/browser/defaults/preferences/t715.js; cp "$W/f" "$W/ffprefs"
check "Firefox defaults: GLES for EGL, WebRender on the CPU (SWGL), no AV1, no first-run pages" \
    sh -c 'grep -q "gfx.egl.prefer-gles.enabled\", true" "$1" && grep -q "gfx.webrender.software\", true" "$1" &&
           grep -q "media.av1.enabled\", false" "$1" && grep -q "browser.aboutwelcome.enabled\", false" "$1"' _ "$W/ffprefs"
check "rtkit installed ($(pkg_ver rtkit)): realtime priority for PipeWire" has_pkg rtkit
check "hypridle installed ($(pkg_ver hypridle))" has_pkg hypridle
get /etc/systemd/user/t715-idle.service; cp "$W/f" "$W/idle.unit"
check "t715-idle.service identical to rootfs/overlay (hypridle -c /usr/share/t715-omarchy/hypridle.conf)" \
    cmp -s "$W/idle.unit" /our-overlay/etc/systemd/user/t715-idle.service
t="$(resolve /etc/systemd/user/graphical-session.target.wants/t715-idle.service || true)"
check "t715-idle.service enabled for every user (-> ${t:-missing})" \
    sh -c 'case "$1" in */t715-idle.service) exit 0 ;; *) exit 1 ;; esac' _ "$t"
get /usr/share/t715-omarchy/hypridle.conf; cp "$W/f" "$W/hypridle.conf"
check "hypridle.conf: 120 s, then SIGUSR1 to t715-keys unless stay-awake holds it (screen off, touch first)" \
    sh -c 'cmp -s "$1" /our-overlay/usr/share/t715-omarchy/hypridle.conf && grep -q "timeout = 120" "$1" && grep -q "SIGUSR1 t715-keys.service" "$1" && grep -q "test -e ~/.local/state/omarchy/indicators/stay-awake ||" "$1"' _ "$W/hypridle.conf"
check "  /usr/lib/spa-0.2/bluez5/libspa-bluez5.so present (wireplumber's Bluetooth monitor)" \
    test "$(ftype /usr/lib/spa-0.2/bluez5/libspa-bluez5.so)" = regular

echo "== Wi-Fi (docs/image/ROOTFS.md \"Wi-Fi\") =="
LFSHA=f04d8fdc0a0a301ccbbf543a2b470108c64ee341360f3450ed4fa9bbee04337c
get $BTFW/brcmfmac4358-pcie.bin
check "$BTFW/brcmfmac4358-pcie.bin: the linux-firmware build for the 4358 A3 ROM (sha256 ${LFSHA:0:16}...), mode 0644, owner 0:0" \
    sh -c '[ "$(sha256sum < "$1" | cut -d" " -f1)" = "$2" ] && [ "$3" = "0644 0:0" ]' _ "$W/f" "$LFSHA" \
    "$(fmode $BTFW/brcmfmac4358-pcie.bin) $(fuid $BTFW/brcmfmac4358-pcie.bin):$(fgid $BTFW/brcmfmac4358-pcie.bin)"
check "  linux-firmware-broadcom itself not installed (one file taken from it)" sh -c '! grep -qx "linux-firmware-broadcom" "$1"' _ "$W/pkgs"
BCMLIC=/usr/share/licenses/linux-firmware-broadcom/LICENCE.broadcom_bcm43xx
check "  its licence, $BCMLIC, mode 0644 (redistribution requires it)" \
    sh -c '[ "$1" = 0644 ] && [ -s "$2" ] && grep -qi broadcom "$2"' _ \
    "$(fmode $BCMLIC)" "$(get $BCMLIC; cp "$W/f" "$W/bcmlic"; echo "$W/bcmlic")"
nvsha="$(sha256sum < /wifi-nvram.txt | cut -d' ' -f1)"
NV=$BTFW/samsung-gts28/nvram_net.txt
if [ "$PUBLIC" = 1 ]; then
    check "public image: no $NV" absent "$NV"
else
get $NV
check "$NV: the dump's nvram_net.txt (sha256 ${nvsha:0:16}...), mode 0644, owner 0:0" \
    sh -c '[ "$(sha256sum < "$1" | cut -d" " -f1)" = "$2" ] && [ "$3" = "0644 0:0" ]' _ "$W/f" "$nvsha" \
    "$(fmode $NV) $(fuid $NV):$(fgid $NV)"
rm -f "$W/f"
fi
check "$BTFW/brcmfmac4358-pcie.txt -> samsung-gts28/nvram_net.txt (the NVRAM name brcmfmac asks for)" \
    test "$(linkto "$BTFW/brcmfmac4358-pcie.txt" 2>/dev/null)" = samsung-gts28/nvram_net.txt
while IFS=$'\t' read -r f mode; do
    get "/$f"
    check "/$f identical to rootfs/overlay" cmp -s "$W/f" "/our-overlay/$f"
    check "  mode $(fmode "/$f"), as git's $mode, owner 0:0" \
        sh -c '[ "$1" = "0${2#100} 0:0" ]' _ "$(fmode "/$f") $(fuid "/$f"):$(fgid "/$f")" "$mode"
done < /modes/MODES
check "  all of the Wi-Fi overlay files compared ($(wc -l < /modes/MODES): $WIFI_FILES)" \
    test "$(wc -l < /modes/MODES)" = "$(printf '%s\n' $WIFI_FILES | grep -c .)"
check "build records: install-wifi.sh installed the firmware and the NVRAM" \
    sh -c 'grep -Eq "^  firmware: brcm/brcmfmac4358-pcie.bin +ok" "$1" && grep -Eq "^  nvram: brcm/samsung-gts28/nvram_net.txt +ok" "$1"' _ "$W/manifest"
for p in networkmanager wpa_supplicant; do
    check "$p installed ($(pkg_ver "$p"))" has_pkg "$p"
done
t="$(resolve /etc/systemd/system/multi-user.target.wants/NetworkManager.service || true)"
check "NetworkManager.service enabled (multi-user.target.wants -> ${t:-missing})" \
    sh -c 'case "$1" in */NetworkManager.service) exit 0 ;; *) exit 1 ;; esac' _ "$t"
check "  its Wi-Fi backend: wpa_supplicant, started over D-Bus (binary, unit, fi.w1.wpa_supplicant1 activation file), not masked" \
    sh -c 'for f in /usr/bin/wpa_supplicant /usr/lib/systemd/system/wpa_supplicant.service /usr/share/dbus-1/system-services/fi.w1.wpa_supplicant1.service; do
               debugfs -R "stat $f" /img/rootfs.img 2>/dev/null | grep -q "^Inode:" || exit 1
           done && [ "$1" != /dev/null ]' _ "$(linkto /etc/systemd/system/wpa_supplicant.service 2>/dev/null || true)"
mkdir -p "$W/nm/etc" "$W/nm/usr"
dfs "rdump /etc/NetworkManager $W/nm/etc" >/dev/null
dfs "rdump /usr/lib/NetworkManager $W/nm/usr" >/dev/null
nm_files="$(find "$W/nm" -name '*.conf' | sed "s|^$W/nm/etc|/etc|; s|^$W/nm/usr|/usr/lib|" | sort | tr '\n' ' ')"
check "  no configuration file sets another wifi.backend ($nm_files)" \
    sh -c '! find "$1" -name "*.conf" -exec grep -hE "^[[:space:]]*wifi\.backend[[:space:]]*=" {} + | grep -vqE "=[[:space:]]*wpa_supplicant[[:space:]]*$"' _ "$W/nm"
others=""
for d in $wants; do
    for u in $(dfs "ls -p /etc/systemd/system/$d" | awk -F/ '{print $6}' \
               | grep -E '^(iwd|connman|systemd-networkd|dhcpcd|netctl)([@.-].*)?\.(service|socket)$'); do
        others="$others $d/$u"
    done
done
check "  nothing else manages the network: no iwd or connman; systemd-networkd, and ALARM's dhcpcd and netctl, not enabled${others:+ (found:$others)}" \
    sh -c '! grep -Eqx "iwd|connman" "$1" && [ -z "$2" ]' _ "$W/pkgs" "$others"
check "  the USB link left alone: only 10-usb-rndis-unmanaged.conf sets unmanaged-devices (usb0, rndis0)" \
    sh -c 'grep -qx "unmanaged-devices=interface-name:usb0;interface-name:rndis0" "$1/etc/NetworkManager/conf.d/10-usb-rndis-unmanaged.conf" &&
           [ "$(find "$1" -name "*.conf" -exec grep -lE "^[[:space:]]*unmanaged-devices" {} + | sed "s|^$1/||")" = "etc/NetworkManager/conf.d/10-usb-rndis-unmanaged.conf" ]' _ "$W/nm"

echo "== RTC: Linux never writes it (Android keeps its own reference) =="
check "no NTP daemon that can sync the RTC (chrony, ntp, ntpsec, openntpd) installed" \
    sh -c '! grep -Eqx "chrony|ntp|ntpsec|openntpd" "$1"' _ "$W/pkgs"
adj="$(cat_ /etc/adjtime | sed -n 3p)"
check "/etc/adjtime absent or UTC (a local-time RTC is rewritten by timedatectl set-timezone)" \
    sh -c '! debugfs -R "stat /etc/adjtime" /img/rootfs.img 2>/dev/null | grep -q "^Inode:" || [ "$1" = UTC ]' _ "$adj"
mkdir -p "$W/rtc"
for d in /usr/lib/systemd/system /usr/lib/systemd/user /usr/lib/systemd/system-sleep /usr/lib/systemd/system-shutdown \
         /etc/systemd /usr/share/libalpm/hooks /etc/pacman.d /usr/lib/udev/rules.d /etc/udev/rules.d \
         /usr/lib/tmpfiles.d /etc/NetworkManager /usr/lib/NetworkManager /usr/local /usr/share/omarchy/install \
         /usr/share/omarchy/default /usr/share/omarchy/migrations; do
    mkdir -p "$W/rtc$(dirname "$d")"
    dfs "rdump \"$d\" \"$W/rtc$(dirname "$d")\"" >/dev/null
done
# Omarchy's commands (its package's usr/bin), dumped in one debugfs run;
# binary files are skipped (grep -I).
get "/var/lib/pacman/local/omarchy-$(pkg_ver omarchy)/files"
mkdir -p "$W/rtc/omarchy-bin"
grep '^usr/bin/.' "$W/f" | while IFS= read -r b; do printf 'dump "/%s" "%s/rtc/omarchy-bin/%s"\n' "$b" "$W" "${b##*/}"; done > "$W/rtc.cmd"
debugfs -f "$W/rtc.cmd" "$IMG" >/dev/null 2>&1
nbin="$(ls "$W/rtc/omarchy-bin" | wc -l)"
rtc_hits="$(grep -rlIE '\bhwclock\b|systohc|set-local-rtc|timedatectl[[:space:]]+set-time([[:space:]]|$)|rtcsync' "$W/rtc" "$W/home" 2>/dev/null | sed "s|^$W/rtc||; s|^$W/home|/home|" | tr '\n' ' ')"
check "nothing writes the RTC: no hwclock, systohc, set-local-rtc, timedatectl set-time or rtcsync in units, hooks, udev rules, NetworkManager, /usr/local, alarm's home or Omarchy's scripts ($nbin commands)${rtc_hits:+: found in $rtc_hits}" \
    sh -c '[ "$1" -ge 100 ] && [ -z "$2" ]' _ "$nbin" "$rtc_hits"

echo "== pacman.conf =="
get /etc/pacman.conf; cp "$W/f" "$W/pacman.conf"
check "no active [t715-omarchy] stanza" sh -c '! grep -Eq "^[[:space:]]*\[t715-omarchy\]" "$1"' _ "$W/pacman.conf"
check "commented [t715-omarchy] note present" grep -q '^#\[t715-omarchy\]' "$W/pacman.conf"
check "Hyprland's family held back (IgnorePkg), Quickshell not" sh -c 'grep -Eq "^IgnorePkg +=.*hypr\*.*aquamarine" "$1" && ! grep -Eq "^IgnorePkg.*quickshell" "$1"' _ "$W/pacman.conf"
check "no DisableSandbox" sh -c '! grep -Eq "^[[:space:]]*DisableSandbox" "$1"' _ "$W/pacman.conf"
check "CheckSpace and DownloadUser restored (ALARM's pristine options)" \
    sh -c 'grep -qx "CheckSpace" "$1" && grep -Eq "^DownloadUser *= *alpm" "$1"' _ "$W/pacman.conf"
check "Architecture = armv7h" grep -Eq '^Architecture *= *armv7h' "$W/pacman.conf"
check "no t715-omarchy sync database left" absent /var/lib/pacman/sync/t715-omarchy.db

echo "== identity and tablet settings =="
check "/etc/hostname = gts28lte-omarchy" test "$(cat_ /etc/hostname | tr -d '\n')" = gts28lte-omarchy
# The language and time zone tools/build-rootfs was given (--locale, --timezone).
get /usr/share/t715-omarchy/locale.env; cp "$W/f" "$W/locale.env"
L_LANG=$(sed -n 's/^T715_LANG=//p' "$W/locale.env"); L_TZ=$(sed -n 's/^T715_TZ=//p' "$W/locale.env")
L_XKB=$(sed -n 's/^T715_XKB=//p' "$W/locale.env")
check "locale.env: LANG=${L_LANG:-?}, TZ=${L_TZ:-?}, keyboard ${L_XKB:-?}" \
    sh -c '[ -n "$1" ] && [ -n "$2" ] && case "$3" in us|fr) exit 0 ;; *) exit 1 ;; esac' _ "$L_LANG" "$L_TZ" "$L_XKB"
check "time zone $L_TZ (/etc/localtime)" \
    sh -c 'case "$1" in */zoneinfo/"$2") exit 0 ;; *) exit 1 ;; esac' _ "$(linkto /etc/localtime || true)" "$L_TZ"
check "/etc/locale.conf: LANG=$L_LANG" grep -qx "LANG=$L_LANG" <(cat_ /etc/locale.conf)
get /usr/lib/locale/locale-archive
check "locales generated: fr_FR.UTF-8 and en_US.UTF-8" sh -c 'grep -aq fr_FR.utf8 "$1" && grep -aq en_US.utf8 "$1"' _ "$W/f"
check "/etc/resolv.conf -> systemd-resolved stub" \
    sh -c 'case "$1" in *run/systemd/resolve/stub-resolv.conf) exit 0 ;; *) exit 1 ;; esac' _ "$(linkto /etc/resolv.conf || true)"
check "udev: eMMC partitions hidden from udisks" \
    grep -q 'UDISKS_IGNORE' <(cat_ /etc/udev/rules.d/90-t715-udisks-ignore-emmc.rules)
check "journald: persistent, 64M caps" grep -qx 'Storage=persistent' <(cat_ /etc/systemd/journald.conf.d/10-t715-journal.conf)
check "journald: no volatile drop-in left" absent /etc/systemd/journald.conf.d/10-t715-volatile.conf
check "t715-reboot-to present, mode 0755 (RECOVERY or Download mode without Android)" test "$(fmode /usr/local/sbin/t715-reboot-to)" = 0755
check "t715-reboot-to byte for byte" cmp -s <(cat_ /usr/local/sbin/t715-reboot-to) /our-overlay/usr/local/sbin/t715-reboot-to
echo "== Battery saver (docs/image/ROOTFS.md, docs/hardware/BATTERY.md) =="
PP=/usr/local/sbin/t715-power-profile
for f in usr/local/sbin/t715-power-profile etc/systemd/system/t715-power-profile.service etc/systemd/system/t715-power-profile.path \
         etc/systemd/system/t715-power-guard.service etc/systemd/system/t715-power-guard.timer; do
    get "/$f"
    check "/$f identical to rootfs/overlay" cmp -s "$W/f" "/our-overlay/$f"
done
check "$PP mode 0755" test "$(fmode $PP)" = 0755
t="$(resolve /etc/systemd/system/graphical.target.wants/t715-power-profile.service || true)"
check "t715-power-profile.service enabled (graphical.target.wants -> ${t:-missing}; PPD starts after multi-user.target)" \
    test "$t" = /etc/systemd/system/t715-power-profile.service
t="$(resolve /etc/systemd/system/multi-user.target.wants/t715-power-profile.path || true)"
check "t715-power-profile.path enabled (multi-user.target.wants -> ${t:-missing})" \
    test "$t" = /etc/systemd/system/t715-power-profile.path
get /etc/systemd/system/t715-power-profile.service; cp "$W/f" "$W/pp.service"
check "t715-power-profile.service: oneshot, runs apply, after and wanting PPD" \
    sh -c 'grep -qx "Type=oneshot" "$1" && grep -qx "ExecStart=/usr/local/sbin/t715-power-profile apply" "$1" &&
           grep -qx "After=power-profiles-daemon.service" "$1" && grep -qx "Wants=power-profiles-daemon.service" "$1"' _ "$W/pp.service"
get /etc/systemd/system/t715-power-profile.path; cp "$W/f" "$W/pp.path"
check "t715-power-profile.path: watches PPD's state.ini and runs the service" \
    sh -c 'grep -qx "PathChanged=/var/lib/power-profiles-daemon/state.ini" "$1" &&
           grep -qx "Unit=t715-power-profile.service" "$1"' _ "$W/pp.path"
t="$(resolve /etc/systemd/system/timers.target.wants/t715-power-guard.timer || true)"
check "t715-power-guard.timer enabled (timers.target.wants -> ${t:-missing})" \
    test "$t" = /etc/systemd/system/t715-power-guard.timer
get /etc/systemd/system/t715-power-guard.service; cp "$W/f" "$W/pg.service"
check "t715-power-guard.service: oneshot, runs guard, after t715-power-profile" \
    sh -c 'grep -qx "Type=oneshot" "$1" && grep -qx "ExecStart=/usr/local/sbin/t715-power-profile guard" "$1" &&
           grep -qx "After=t715-power-profile.service" "$1"' _ "$W/pg.service"
get $PP; cp "$W/f" "$W/pp"
check "t715-power-profile: the clusters by cpu_capacity, never a hardcoded cpu number" \
    sh -c 'grep -q "cpu_capacity" "$1" && ! grep -Eq "cpu[4-7]" "$1"' _ "$W/pp"
echo "== Wi-Fi guard =="
WG=/usr/local/sbin/t715-wifi-guard
for f in usr/local/sbin/t715-wifi-guard etc/systemd/system/t715-wifi-guard.service; do
    get "/$f"
    check "/$f identical to rootfs/overlay" cmp -s "$W/f" "/our-overlay/$f"
done
check "$WG mode 0755" test "$(fmode $WG)" = 0755
get $WG; cp "$W/f" "$W/wg"
t="$(resolve /etc/systemd/system/multi-user.target.wants/t715-wifi-guard.service || true)"
check "t715-wifi-guard.service enabled (multi-user.target.wants -> ${t:-missing})" \
    test "$t" = /etc/systemd/system/t715-wifi-guard.service
get /etc/systemd/system/t715-wifi-guard.service; cp "$W/f" "$W/wg.service"
check "t715-wifi-guard.service: simple, runs run, after NetworkManager and bluetooth, restarts whatever its exit" \
    sh -c 'grep -qx "Type=simple" "$1" && grep -qx "ExecStart=/usr/local/sbin/t715-wifi-guard run" "$1" &&
           grep -qx "After=NetworkManager.service bluetooth.service" "$1" &&
           grep -qx "Restart=always" "$1" && grep -qx "WantedBy=multi-user.target" "$1"' _ "$W/wg.service"
check "t715-wifi-guard: writes only the two drivers' bind and unbind files, never rfkill or NetworkManager's" \
    sh -c '! grep -v "^[[:space:]]*#" "$1" | grep -Eq "rfkill|nmcli|NetworkManager|ModemManager"' _ "$W/wg"
check "t715-shutdown-log.service enabled (shutdown steps kept in pstore)" test "$(linkto /etc/systemd/system/sysinit.target.wants/t715-shutdown-log.service)" = /etc/systemd/system/t715-shutdown-log.service
check "t715-stuck-procs: a system-shutdown hook, mode 0755, byte for byte" \
    sh -c '[ "$1" = 0755 ] && cmp -s "$2" "$3"' _ "$(fmode /usr/lib/systemd/system-shutdown/t715-stuck-procs)" \
        <(cat_ /usr/lib/systemd/system-shutdown/t715-stuck-procs) /our-overlay/usr/lib/systemd/system-shutdown/t715-stuck-procs
check "t715-pstore-shutdown.service enabled (stuck processes kept in /var/log/t715-shutdown)" \
    test "$(linkto /etc/systemd/system/multi-user.target.wants/t715-pstore-shutdown.service)" = /etc/systemd/system/t715-pstore-shutdown.service
check "plymouth: splash forced (sboot sets no 'splash'; needs kernel 00024, docs/DEPLOY.md 13.)" grep -q -- '--kernel-command-line="quiet splash"' <(cat_ /etc/systemd/system/plymouth-start.service.d/10-t715-splash.conf)
check "plymouth: theme omarchy" grep -qx 'Theme=omarchy' <(cat_ /etc/plymouth/plymouthd.conf)
check "systemd: ShowStatus=auto (no status lines before the splash)" grep -qx 'ShowStatus=auto' <(cat_ /etc/systemd/system.conf.d/10-t715-quiet.conf)
for u in plymouth-reboot plymouth-poweroff plymouth-halt plymouth-kexec; do
    check "plymouth: $u.service masked (shutdown race with Hyprland)" test "$(linkto /etc/systemd/system/$u.service)" = /dev/null
done
check "nothing in the image refers to USERDATA's mount point in fstab" \
    sh -c '! grep -q "/run/t715" "$1"' _ "$(get /etc/fstab; cp "$W/f" "$W/fstab"; echo "$W/fstab")"
check "smoke check installed (/usr/lib/t715-omarchy/smoke-check, 0755)" \
    test "$(fmode /usr/lib/t715-omarchy/smoke-check)" = 0755
check "build records in the image (/usr/share/t715-omarchy/MANIFEST.image)" \
    exists /usr/share/t715-omarchy/MANIFEST.image

printf '%s\n' "----------------------------------------"
if [ "$FAIL" -eq 0 ]; then
    printf 'RESULT: PASS (%d checks)\n' "$PASS"
    exit 0
fi
printf 'RESULT: FAIL (%d of %d checks failed)\n' "$FAIL" "$((PASS + FAIL))"
exit 1
SCRIPT

set +e
docker run --rm --name "$CTR" --platform linux/arm64 \
    -v "$IMG_ABS:/img/rootfs.img:ro" \
    -v "$KEY_ABS:/img/key.pub:ro" \
    -v "$REPO_DIR/rootfs/overlay:/our-overlay:ro" \
    -v "$REPO_DIR/rootfs/t715-tablet.lua:/our-tablet.lua:ro" \
    -v "$REPO_DIR/rootfs/omarchy-user-setup.sh:/our-user-setup.sh:ro" \
    -v "$REPO_DIR/pkg:/our-pkg:ro" \
    -v "$BT_FIRMWARE:/bt-firmware.hcd:ro" \
    -v "$WIFI_NVRAM:/wifi-nvram.txt:ro" \
    -v "$MODES_DIR:/modes:ro" \
    -e WIFI_FILES="$WIFI_FILES" \
    -e PUBLIC="$PUBLIC" \
    "$HELPER_IMAGE" bash -c "$INNER" </dev/null
rc=$?
set -e
case "$rc" in
    0|1) exit "$rc" ;;
    *)   echo "RESULT: FAIL (the checks could not run, exit $rc)"; exit 2 ;;
esac
