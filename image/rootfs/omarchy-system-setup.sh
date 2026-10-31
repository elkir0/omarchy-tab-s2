#!/bin/bash
# omarchy-system-setup.sh — Omarchy's install-time system setup, run at build
# time in the image tree (as root, called by configure-system.sh).
#
# Runs the leaves of install/{config,hardware,login,post-install}/all.sh in
# Omarchy's own order (omarchy-apply-system: config, then
# omarchy-apply-hardware, login, post-install) with Omarchy's own run_logged
# (install/helpers/logging.sh; output in /var/log/omarchy-install.log) and
# the environment the ISO gives them (OMARCHY_INSTALL_USER=alarm, first
# install). Differences, each recorded in the output table:
#   - the leaves in SKIP do not run (reason given);
#   - config/enable-services.sh runs from an adapted copy that leaves out the
#     "systemctl enable" lines of units this image does not install (the leaf
#     stops at the first missing unit otherwise);
#   - a failing leaf is recorded and the run goes on (the ISO's runner would
#     stop): failures are warnings, not build failures.
# A leaf that a future Omarchy adds and that SKIP does not name runs, as on
# a normal install.
#
# Usage: omarchy-system-setup.sh OUT.tsv      (leaf<TAB>status<TAB>detail)
set -uo pipefail

OUT="${1:?usage: omarchy-system-setup.sh OUT.tsv}"

export OMARCHY_PATH=/usr/share/omarchy
export OMARCHY_INSTALL="$OMARCHY_PATH/install"
export OMARCHY_INSTALL_USER=alarm
export OMARCHY_FIRST_INSTALL=1
export OMARCHY_UPGRADE=0
export OMARCHY_INSTALL_LOG_FILE=/var/log/omarchy-install.log
export PATH="$OMARCHY_PATH/bin:/usr/local/sbin:/usr/local/bin:/usr/bin"
export SYSTEMD_OFFLINE=1

ADAPT_DIR=/tmp/t715-omarchy-leaves

# The x86 quirk leaves detect their hardware from the PCI/DMI/ACPI/CPU data
# of the machine they run on, which at build time is the build container.
x86() { printf 'x86 laptop quirk (%s); no such hardware on the SM-T715' "$1"; }
LIMINE="limine boot entry drop-in; the tablet boots through Samsung's sboot, not limine"

declare -A SKIP=(
    [config/docker.sh]="docker is left out (packages.omarchy-skip); the leaf is an empty placeholder anyway"
    [config/snapper.sh]="btrfs snapshots (snapper, limine-snapper-sync): the root is a read-only ext4 image"
    [config/firewall.sh]="ufw's default deny would block SSH and DHCP on usb0, the only way into the tablet: configure-system.sh turns ufw on with the overlay's rules"
    [post-install/pacman.sh]="writes Omarchy's x86_64/aarch64 pacman.conf and mirrorlist over ALARM's armv7h ones"
    [hardware/pacman.sh]="adds the Apple T2 repository to pacman.conf; the image keeps ALARM's pacman.conf"
    [hardware/asus-rog.sh]="$(x86 "ASUS ROG, asusctl")"
    [hardware/framework16.sh]="$(x86 "Framework 16 keyboard")"
    [hardware/dell-xps-touchpad-haptics.sh]="$(x86 "Dell XPS haptic touchpad")"
    [hardware/surface.sh]="$(x86 "Microsoft Surface firmware")"
    [hardware/fix-synaptic-touchpad.sh]="$(x86 "PS/2 Synaptics touchpad, psmouse; the tablet's RMI4 touchscreen is I2C, built in")"
    [hardware/nvidia.sh]="$(x86 "NVIDIA PCI GPUs")"
    [hardware/vulkan.sh]="$(x86 "Vulkan for Intel/AMD/Apple PCI GPUs; Mesa has no Vulkan driver for Mali-T760")"
    [hardware/intel/video-acceleration.sh]="$(x86 "Intel GPU video acceleration")"
    [hardware/intel/lpmd.sh]="$(x86 "Intel low power mode daemon")"
    [hardware/intel/thermald.sh]="$(x86 "Intel thermald")"
    [hardware/intel/ipu7-camera.sh]="$(x86 "Intel IPU7 camera")"
    [hardware/intel/fred.sh]="$LIMINE (Intel Panther Lake FRED)"
    [hardware/intel/fix-wifi7-eht.sh]="$(x86 "Intel BE200/BE211 Wi-Fi 7")"
    [hardware/intel/sof-firmware.sh]="$(x86 "Intel Sound Open Firmware")"
    [hardware/dell-xps13-ptl-speaker-firmware.sh]="$(x86 "Dell XPS 13 speaker firmware")"
    [hardware/asus/fix-asus-ptl-display-backlight.sh]="$LIMINE (ASUS Panther Lake backlight)"
    [hardware/asus/fix-asus-ptl-b9406-display.sh]="$LIMINE (ASUS ExpertBook B9406 display)"
    [hardware/asus/fix-asus-ptl-b9406-touchpad.sh]="$(x86 "ASUS ExpertBook B9406 touchpad")"
    [hardware/asus/fix-z13-touchpad.sh]="$(x86 "ASUS ROG Flow Z13 touchpad")"
    [hardware/framework/qmk-hid.sh]="$(x86 "Framework 16 QMK keyboard")"
    [hardware/apple/fix-spi-keyboard.sh]="$(x86 "MacBook SPI keyboard")"
    [hardware/apple/fix-suspend-nvme.sh]="$(x86 "MacBook NVMe suspend")"
    [hardware/apple/fix-t2.sh]="$(x86 "Apple T2 Macs")"
    [hardware/apple/fix-brcmfmac-supplicant.sh]="$(x86 "Mac Broadcom Wi-Fi")"
    [hardware/lenovo/fix-yoga-pro7-bass-speakers.sh]="$(x86 "Lenovo Yoga Pro 7 speakers")"
    [hardware/fix-bcm43xx.sh]="$(x86 "Broadcom BCM4360/BCM4331 PCI Wi-Fi")"
    [hardware/fix-surface-keyboard.sh]="$(x86 "Microsoft Surface keyboard")"
    [hardware/fix-yt6801-ethernet-adapter.sh]="$(x86 "Motorcomm YT6801 PCI Ethernet")"
    [hardware/fix-tuxedo-backlight.sh]="$(x86 "TUXEDO/Slimbook keyboard backlight")"
    [hardware/speaker-tuning.sh]="speaker tunings for x86 laptop models (DMI match); audio is not validated on the tablet"
)

record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$OUT"; }

unit_installed() {
    [ -e "/usr/lib/systemd/system/$1" ] || [ -e "/etc/systemd/system/$1" ]
}

# adapt_enable_services: writes the adapted copy; sets ADAPT_PATH, ADAPT_NOTE.
ADAPT_PATH=""
ADAPT_NOTE=""
adapt_enable_services() {
    local src="$OMARCHY_INSTALL/config/enable-services.sh"
    local dst="$ADAPT_DIR/config/enable-services.sh"
    local re='^[[:space:]]*systemctl[[:space:]]+enable[[:space:]]+([^[:space:]]+)[[:space:]]*$'
    local line dropped=""
    mkdir -p "${dst%/*}"
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ $line =~ $re ]] && ! unit_installed "${BASH_REMATCH[1]}"; then
            dropped="$dropped ${BASH_REMATCH[1]}"
            printf '# omarchy-tab-s2: %s is not installed in this image\n# %s\n' \
                "${BASH_REMATCH[1]}" "$line"
            continue
        fi
        printf '%s\n' "$line"
    done < "$src" > "$dst"
    if [ -n "$dropped" ]; then
        ADAPT_NOTE="adapted: not enabling${dropped} (not installed)"
    else
        ADAPT_NOTE="every unit it enables is installed"
    fi
    ADAPT_PATH="$dst"
}

# shellcheck disable=SC1091
source "$OMARCHY_INSTALL/helpers/logging.sh"
start_install_log
: > "$OUT"

re_leaf='^run_logged[[:space:]]+"[$]OMARCHY_INSTALL/([^"]+)"[[:space:]]*$'
ok=0; failed=0; skipped=0
for part in config hardware login post-install; do
    all="$OMARCHY_INSTALL/$part/all.sh"
    if [ ! -f "$all" ]; then
        record "$part/all.sh" missing "Omarchy ships no $part/all.sh"
        continue
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        if [[ ! $line =~ $re_leaf ]]; then
            record "$part/all.sh" "not run" "line not understood by this runner: $line"
            continue
        fi
        rel="${BASH_REMATCH[1]}"
        leaf="$OMARCHY_INSTALL/$rel"
        if [ -n "${SKIP[$rel]+x}" ]; then
            record "$rel" skipped "${SKIP[$rel]}"
            skipped=$((skipped + 1))
            continue
        fi
        if [ ! -f "$leaf" ]; then
            record "$rel" failed "listed in $part/all.sh but missing"
            failed=$((failed + 1))
            continue
        fi
        detail=""
        if [ "$rel" = config/enable-services.sh ]; then
            adapt_enable_services
            leaf="$ADAPT_PATH"
            detail="$ADAPT_NOTE"
        fi
        if run_logged "$leaf"; then
            record "$rel" ok "$detail"
            ok=$((ok + 1))
        else
            rc=$?
            record "$rel" "failed (exit $rc)" "${detail:+$detail; }see /var/log/omarchy-install.log"
            failed=$((failed + 1))
        fi
    done < "$all"
done

stop_install_log
rm -rf "$ADAPT_DIR"
printf 'omarchy-system-setup: %d ok, %d failed, %d skipped\n' "$ok" "$failed" "$skipped"
exit 0
