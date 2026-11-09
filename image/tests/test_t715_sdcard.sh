#!/usr/bin/env bash
# test_t715_sdcard.sh — off-device test of t715-sdcard and its pieces
# (rootfs/overlay/usr/local/bin/t715-sdcard, its user unit, the udev rule,
# docs/image/ROOTFS.md "microSD card").
#
# The script runs on this machine against a fake sysfs (the slot's host
# under 15560000.mmc, the card's disk under its mmc host) with stand-ins
# first in PATH: lsblk, findmnt, udisksctl, udevadm, findmnt --poll,
# omarchy-notification-send, nautilus, gnome-disks and logger, each
# answering from tables the test fills. `state` is read for no slot, a
# slot without a card, an unformatted card, a vfat card mounted, an
# exfat card not mounted, a whole-disk file system and a label with
# spaces; `mount`, `eject` (clean and busy) and `open` (its three
# cases, by the stubbed command line) run the script; `watch` is fed a
# scripted sequence of udev lines through a pipe that stands in for its
# event stream (insert then mount, insert unmountable, removal while
# mounted, eject then removal, a card present at start), asserting the
# notifications sent and that nothing else runs. The user unit's keys
# and the udev rule's line are checked statically.
#
# Usage: tests/test_t715_sdcard.sh
# Prints "ok - ..." per group, "PASS" at the end; exit 1 on the first
# failure (with what the stubs collected). Needs bash and /bin/sh; works
# with macOS's bash 3.2. Nothing outside a temporary directory.
#
# In the style of test_t715_animations.sh (omarchy-mobile 5f7ba48, MIT).
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SD="$here/rootfs/overlay/usr/local/bin/t715-sdcard"
CONF="$here/rootfs/configure-system.sh"
UNIT="$here/rootfs/overlay/etc/systemd/user/t715-sdcard.service"
RULE="$here/rootfs/overlay/etc/udev/rules.d/61-t715-removable-partlabel.rules"
[ -f "$SD" ] || { echo "SETUP ERROR: no $SD" >&2; exit 2; }

t=$(mktemp -d "${TMPDIR:-/tmp}/t715-sd-test.XXXXXX")
# The watch cases' stand-in monitors (the fake udevadm monitor and
# findmnt --poll that `sd watch` starts) outlive it, blocked on their FIFO
# for good: stop whatever runs from this directory before removing it.
cleanup() { pkill -f -- "$t/" 2>/dev/null || true; rm -rf "$t"; }
trap cleanup EXIT

fail() {
    printf 'not ok - %s\n' "$1" >&2
    echo "--- notifications" >&2; cat "$t/notify" 2>/dev/null || true
    echo "--- log" >&2; cat "$t/log" 2>/dev/null || true
    echo "--- udisksctl" >&2; cat "$t/udisks" 2>/dev/null || true
    echo "--- apps" >&2; cat "$t/apps" 2>/dev/null || true
    exit 1
}

# --- stand-ins -----------------------------------------------------------------
mkdir -p "$t/bin"
cat > "$t/bin/logger" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "\$T715_TEST_LOG"
STUB
cat > "$t/bin/lsblk" <<STUB
#!/bin/sh
# The test's table answers (KEY|FSTYPE|LABEL|SIZE per device, ':' in values);
# -d -nrno COL DEV prints the row's column for /dev/DEV.
[ "\$1" = "-d" ] || exit 1
col=\$3
dev=\${4#/dev/}
awk -F'|' -v d="\$dev" -v c="\$col" '
    \$1 == d {
        if (c == "FSTYPE") print \$2; else if (c == "LABEL") print \$3; else print \$4
    }' "\$T715_TEST_LSBLK"
STUB
cat > "$t/bin/findmnt" <<STUB
#!/bin/sh
# -nrno COL -S DEV: the mount table's column for the device.
if [ "\$1" = "--poll" ]; then
    # The watch stand-in: a line arrives, the test writes it; EOF only when
    # the test closes the pipe, which it never does while watch runs.
    exec cat "\$T715_TEST_PIPE"
fi
[ "\$1" = "-nrno" ] || exit 1
col=\$2; dev=\${4#/dev/}
awk -F'|' -v d="\$dev" -v c="\$col" '
    \$1 == d {
        if (c == "TARGET") print \$2; else if (c == "AVAIL") print \$3
    }' "\$T715_TEST_MOUNTS"
STUB
cat > "$t/bin/udisksctl" <<STUB
#!/bin/sh
printf 'udisksctl %s\n' "\$*" >> "\$T715_TEST_UDISKS"
[ -n "\$T715_TEST_UDISKS_RC" ] && [ "\$1\$2" = "unmount-b" ] && exit "\$T715_TEST_UDISKS_RC"
# A mount adds the row udisks2 would leave in the mount table; an
# unmount drops it again.  The device is \$3 (udisksctl mount -b DEV).
if [ "\$1\$2" = "mount-b" ]; then
    printf '%s|/run/media/alarm/SDCARD|14.4G\n' "\${3#/dev/}" >> "\$T715_TEST_MOUNTS"
elif [ "\$1\$2" = "unmount-b" ]; then
    grep -v "^\${3#/dev/}|" "\$T715_TEST_MOUNTS" > "\$T715_TEST_MOUNTS.tmp" || true
    mv "\$T715_TEST_MOUNTS.tmp" "\$T715_TEST_MOUNTS"
fi
exit 0
STUB
cat > "$t/bin/udevadm" <<STUB
#!/bin/sh
printf 'udevadm %s\n' "\$*" >> "\$T715_TEST_UDEV"
cat "\$T715_TEST_PIPE"
STUB
cat > "$t/bin/omarchy-notification-send" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "\$T715_TEST_NOTIFY"
# -p: print the notification's id, as the real one does
case " \$* " in *" -p "*) echo 42 ;; esac
exit 0
STUB
# The notification server is on the bus (watch waits for it at start).
cat > "$t/bin/busctl" <<STUB
#!/bin/sh
exit 0
STUB
cat > "$t/bin/nautilus" <<STUB
#!/bin/sh
printf 'nautilus %s\n' "\$*" >> "\$T715_TEST_APPS"
exit 0
STUB
cat > "$t/bin/gnome-disks" <<STUB
#!/bin/sh
printf 'gnome-disks %s\n' "\$*" >> "\$T715_TEST_APPS"
exit 0
STUB
chmod +x "$t/bin/"*
export T715_TEST_LOG="$t/log" T715_TEST_LSBLK="$t/lsblk" T715_TEST_MOUNTS="$t/mounts" \
       T715_TEST_PIPE="$t/pipe" T715_TEST_UDISKS="$t/udisks" T715_TEST_UDISKS_RC="" \
       T715_TEST_UDEV="$t/udev" T715_TEST_NOTIFY="$t/notify" T715_TEST_APPS="$t/apps"
: > "$t/lsblk"; : > "$t/mounts"; : > "$t/log"; : > "$t/udisks"; : > "$t/notify"; : > "$t/apps"

# sd [args...]: the script on the fake sysfs, with the stubs first in PATH.
sd() {
    env T715_SDCARD_SYSFS="$t/sys" T715_SDCARD_STATE_DIR="$t/state" \
        PATH="$t/bin:/usr/bin:/bin" "$SD" "$@"
}
clear_files() {
    : > "$t/log"; : > "$t/udisks"; : > "$t/notify"; : > "$t/apps"
}
nlines() { [ "$(wc -l < "$1" | tr -d ' ')" = "$2" ]; }

# --- the fake sysfs ----------------------------------------------------------------
# mk_slot on|off: the host controller under soc@0/15560000.mmc (the slot
# exists only on a kernel that drives it); a new case starts from empty
# lsblk and mount tables too.
mk_slot() {
    rm -rf "$t/sys" "$t/state"
    mkdir -p "$t/state"
    : > "$t/lsblk"
    : > "$t/mounts"
    [ "$1" = off ] && { mkdir -p "$t/sys"; return 0; }
    mkdir -p "$t/sys/devices/platform/soc@0/15560000.mmc/mmc_host"
    mkdir -p "$t/sys/class/block"
}
# mk_card NUM: a card's disk mmcblk1 with a /sys/class/block link.
mk_card() {
    local host="$t/sys/devices/platform/soc@0/15560000.mmc/mmc_host/mmc1/mmc1:0001/block/$1"
    mkdir -p "$host" "$t/sys/class/block"
    ln -s "$host" "$t/sys/class/block/$1"
}
# mk_part DISK NUM: a partition with its /sys/class/block link.
mk_part() {
    local host="$t/sys/devices/platform/soc@0/15560000.mmc/mmc_host/mmc1/mmc1:0001/block/$1"
    local part="$1p$2"
    mkdir -p "$host/${part#"$1"/}"
    ln -s "$host/${part#"$1"/}" "$t/sys/class/block/$part"
}
# dev_row DEV FSTYPE LABEL SIZE: one lsblk answer. ':' in FSTYPE and LABEL
# becomes '|' for the awk tables.
dev_row() {
    printf '%s|%s|%s|%s\n' "$1" "${2//:/|}" "${3//:/|}" "$4" >> "$t/lsblk"
}
# mount_row DEV TARGET AVAIL: one mount answer.
mount_row() {
    printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$t/mounts"
}

# --- (a) state: no slot, slot without a card ------------------------------------
mk_slot off
out=$(sd state) || fail "(a) state without a slot exits 0"
[ "$out" = "slot=no
card=no
device=
fs=
label=
mounted=no
mountpoint=
size=
free=" ] || fail "(a) state without a slot (got:
$out)"
mk_slot on
out=$(sd state) || fail "(a) state with an empty slot exits 0"
printf '%s\n' "$out" | sed -n '1p' | grep -qx 'slot=yes' || fail "(a) slot=yes with the host"
[ "$(printf '%s\n' "$out" | sed -n '2p')" = "card=no" ] || fail "(a) card=no without a card"
echo "ok - state: no slot all no, a slot without a card"

# --- (b) state: an unformatted card ----------------------------------------------
mk_slot on
mk_card mmcblk1
mk_part mmcblk1 1
dev_row mmcblk1p1 "" "" "14.9G"
out=$(sd state) || fail "(b) state of an unformatted card exits 0"
[ "$(printf '%s\n' "$out" | sed -n '3,5p')" = "device=/dev/mmcblk1p1
fs=
label=" ] || fail "(b) the first partition named with an empty fs (got:
$(printf '%s\n' "$out" | sed -n '3,5p'))"
[ "$(printf '%s\n' "$out" | sed -n '8p')" = "size=14.9G" ] || fail "(b) the partition's size"
echo "ok - state: an unformatted card names its first partition, fs empty"

# --- (c) state: a mounted vfat card ------------------------------------------------
mk_slot on
mk_card mmcblk1
mk_part mmcblk1 1
dev_row mmcblk1p1 vfat SDCARD "14.5G"
mount_row mmcblk1p1 "/run/media/alarm/SDCARD" "14.4G"
out=$(sd state) || fail "(c) state of a mounted vfat card exits 0"
[ "$(printf '%s\n' "$out" | sed -n '3,9p')" = "device=/dev/mmcblk1p1
fs=vfat
label=SDCARD
mounted=yes
mountpoint=/run/media/alarm/SDCARD
size=14.5G
free=14.4G" ] || fail "(c) the mounted vfat card's state (got:
$(printf '%s\n' "$out" | sed -n '3,9p'))"
echo "ok - state: a mounted vfat card, every key answered"

# --- (d) state: an exfat card not mounted, a label with spaces ----------------------
mk_slot on
mk_card mmcblk1
mk_part mmcblk1 1
mk_part mmcblk1 2
dev_row mmcblk1p1 "" "" "1.0M"
dev_row mmcblk1p2 exfat "MY CARD" "29.7G"
out=$(sd state) || fail "(d) state of an exfat card exits 0"
[ "$(printf '%s\n' "$out" | sed -n '3,5p')" = "device=/dev/mmcblk1p2
fs=exfat
label=MY CARD" ] || fail "(d) the first partition with a file system wins (got:
$(printf '%s\n' "$out" | sed -n '3,5p'))"
[ "$(printf '%s\n' "$out" | sed -n '6p')" = "mounted=no" ] || fail "(d) not mounted"
[ "$(printf '%s\n' "$out" | sed -n '9p')" = "free=" ] || fail "(d) free empty when not mounted"
echo "ok - state: exfat not mounted, a label with spaces kept whole"

# --- (e) state: a whole-disk file system -------------------------------------------
mk_slot on
mk_card mmcblk1
dev_row mmcblk1 btrfs BACKUP "59.5G"
mount_row mmcblk1 "/run/media/alarm/BACKUP" "12.0G"
out=$(sd state) || fail "(e) state of a whole-disk card exits 0"
[ "$(printf '%s\n' "$out" | sed -n '2,3p')" = "card=yes
device=/dev/mmcblk1" ] || fail "(e) no partition table: the disk itself (got:
$(printf '%s\n' "$out" | sed -n '2,3p'))"
[ "$(printf '%s\n' "$out" | sed -n '4p')" = "fs=btrfs" ] || fail "(e) the disk's file system"
[ "$(printf '%s\n' "$out" | sed -n '9p')" = "free=12.0G" ] || fail "(e) the disk's free space"
echo "ok - state: a card without a partition table uses the whole disk"

# --- (f) mount -------------------------------------------------------------------------
mk_slot on
mk_card mmcblk1
mk_part mmcblk1 1
dev_row mmcblk1p1 exfat HOLIDAY "14.5G"
mount_row mmcblk1p1 "/run/media/alarm/HOLIDAY" "14.0G"
clear_files
sd mount >/dev/null 2>&1 || fail "(f) mount of a mounted card exits 0"
grep -qx "udisksctl mount -b /dev/mmcblk1p1" "$t/udisks" \
    && fail "(f) an already mounted card is not mounted again (got: $(cat "$t/udisks"))"
: > "$t/mounts"
sd mount >/dev/null 2>&1 || fail "(f) mount of an unmounted card exits 0"
grep -qx "udisksctl mount -b /dev/mmcblk1p1" "$t/udisks" || fail "(f) udisksctl mount runs"
mk_slot on
mk_card mmcblk1
mk_part mmcblk1 1
dev_row mmcblk1p1 "" "" "14.9G"
sd mount >/dev/null 2>&1 && fail "(f) mount of an unformatted card exits nonzero"
mk_slot off
sd mount >/dev/null 2>&1 && fail "(f) mount without a card exits nonzero"
echo "ok - mount: mounted card no-op, unmounted mounted, unformatted and empty refused"

# --- (g) eject: success ----------------------------------------------------------------
mk_slot on
mk_card mmcblk1
mk_part mmcblk1 1
mk_part mmcblk1 2
dev_row mmcblk1p1 vfat SDCARD "14.5G"
dev_row mmcblk1p2 "" "" "1.0M"
mount_row mmcblk1p1 "/run/media/alarm/SDCARD" "14.4G"
mount_row mmcblk1p2 "/run/media/alarm/2C34-1A4F" "0.9M"
clear_files
sd eject >/dev/null 2>&1 || fail "(g) eject exits 0"
grep -qx "udisksctl unmount -b /dev/mmcblk1p1" "$t/udisks" || fail "(g) the first partition unmounted"
grep -qx "udisksctl unmount -b /dev/mmcblk1p2" "$t/udisks" || fail "(g) the second partition unmounted"
grep -qx "udisksctl power-off -b /dev/mmcblk1" "$t/udisks" || fail "(g) the disk powered off"
case "$(cat "$t/notify")" in
*"SD card ejected"*"You can remove it now."*) ;;
*) fail "(g) the ejected notification (got: $(cat "$t/notify"))" ;;
esac
[ "$(grep -c 'udisksctl' "$t/udisks")" = 3 ] || fail "(g) exactly three udisksctl calls (got: $(cat "$t/udisks"))"
echo "ok - eject: every partition unmounted, power off, the notification"

# --- (h) eject: busy -------------------------------------------------------------------
export T715_TEST_UDISKS_RC=1
mk_slot on
mk_card mmcblk1
mk_part mmcblk1 1
dev_row mmcblk1p1 vfat SDCARD "14.5G"
mount_row mmcblk1p1 "/run/media/alarm/SDCARD" "14.4G"
clear_files
sd eject >/dev/null 2>&1 && fail "(h) eject with a busy partition exits nonzero"
grep -qx "udisksctl unmount -b /dev/mmcblk1p1" "$t/udisks" || fail "(h) the unmount was tried"
if grep -qx "udisksctl power-off -b /dev/mmcblk1" "$t/udisks"; then
    fail "(h) no power-off after a refused unmount"
fi
case "$(cat "$t/notify")" in
*"SD card not ejected"*"/dev/mmcblk1p1 could not be unmounted"*) ;;
*) fail "(h) the busy notification (got: $(cat "$t/notify"))" ;;
esac
export T715_TEST_UDISKS_RC=
echo "ok - eject: a busy partition stops it, power off never runs, the notification"

# --- (i) open: mounted ------------------------------------------------------------------
mk_slot on
mk_card mmcblk1
mk_part mmcblk1 1
dev_row mmcblk1p1 vfat SDCARD "14.5G"
mount_row mmcblk1p1 "/run/media/alarm/SDCARD" "14.4G"
clear_files
sd open >/dev/null 2>&1 || fail "(i) open of a mounted card exits 0"
[ "$(cat "$t/apps")" = "nautilus --new-window /run/media/alarm/SDCARD" ] \
    || fail "(i) Files on the mount point (got: $(cat "$t/apps"))"
nlines "$t/udisks" 0 || fail "(i) no udisksctl call"
echo "ok - open: a mounted card in Files, no mount"

# --- (j) open: not mounted but mountable --------------------------------------------------
: > "$t/mounts"
clear_files
sd open >/dev/null 2>&1 || fail "(j) open of a mountable card exits 0"
grep -qx "udisksctl mount -b /dev/mmcblk1p1" "$t/udisks" || fail "(j) the card mounted first"
grep -qx "nautilus --new-window /run/media/alarm/SDCARD" "$t/apps" \
    || fail "(j) Files after the mount (got: $(cat "$t/apps"))"
nlines "$t/apps" 1 || fail "(j) one app call (got: $(cat "$t/apps"))"
echo "ok - open: a mountable card is mounted by udisks, then opened in Files"

# --- (k) open: nothing mountable -----------------------------------------------------------
mk_slot on
mk_card mmcblk1
mk_part mmcblk1 1
mk_part mmcblk1 2
dev_row mmcblk1p1 "" "" "1.0M"
dev_row mmcblk1p2 swap "" "2.0G"
: > "$t/mounts"
clear_files
sd open >/dev/null 2>&1 || fail "(k) open of an unmountable card exits 0"
[ "$(cat "$t/apps")" = "gnome-disks --block-device /dev/mmcblk1" ] \
    || fail "(k) Disks on the card (got: $(cat "$t/apps"))"
nlines "$t/udisks" 0 || fail "(k) no udisksctl call (got: $(cat "$t/udisks"))"
mk_slot off
sd open >/dev/null 2>&1 && fail "(k) open without a card exits nonzero"
echo "ok - open: an unmountable card in Disks; no card refused"

# --- (l) usage --------------------------------------------------------------------------------
sd frobnicate >/dev/null 2>&1 && fail "(l) an unknown verb exits nonzero"
[ "$(sd frobnicate >/dev/null 2>&1; echo $?)" = 2 ] || fail "(l) an unknown verb exits 2"
sd >/dev/null 2>&1 && fail "(l) no argument exits nonzero"
[ "$(sd 2>/dev/null; echo $?)" = 2 ] || fail "(l) no argument exits 2"
case "$(sd 2>&1 >/dev/null)" in
usage:*) ;;
*) fail "(l) the usage goes to stderr" ;;
esac
sd --help >/dev/null 2>&1 || fail "(l) --help exits 0"
echo "ok - usage: no argument or an unknown verb exits 2, usage on stderr"

# --- watch ----------------------------------------------------------------------
# The insert cases begin with the slot empty: watch records card=no at
# its start, then the card's sysfs tree is created and an event arrives,
# as udev would deliver it.  watch_wrap starts `sd watch` with the settle
# window short, both monitors reading from a FIFO the test fills; a
# holder sleep keeps the FIFO's write end open, so the stand-ins' cat
# never sees EOF and the stream lasts the whole case.
watch_wrap() {
    rm -f "$t/pipe"
    mkfifo "$t/pipe"
    env T715_SDCARD_SYSFS="$t/sys" T715_SDCARD_STATE_DIR="$t/state" \
        T715_SDCARD_SETTLE=1 PATH="$t/bin:/usr/bin:/bin" \
        "$SD" watch >"$t/watch-$1.out" 2>"$t/watch-$1.err" &
    WPID=$!
    sleep 30 >"$t/pipe" &
    HOLDER=$!
    sleep 0.4
}
watch_end() {
    kill "$WPID" "$HOLDER" 2>/dev/null || true
    wait "$WPID" 2>/dev/null || true
    wait "$HOLDER" 2>/dev/null || true
    rm -f "$t/pipe"
}
watch_send() {
    # A writer of its own, detached: when watch has exited already (an
    # error, or the case is over), a direct write to the FIFO would hang.
    ( printf '%s\n' "$1" >"$t/pipe" 2>/dev/null || true ) &
}
# card_in_tree: create the card's sysfs tree (an insertion).
card_in_tree() {
    mk_card mmcblk1
    mk_part mmcblk1 1
}
card_out_tree() {
    rm -rf "$t/sys/devices/platform/soc@0/15560000.mmc/mmc_host"
    rm -f "$t/sys/class/block/mmcblk1" "$t/sys/class/block/mmcblk1p1"
}

# (m) insert then udiskie's mount: the SD card notification, which
# replaces the card's previous one (here a removal warning, id 42)
mk_slot on
dev_row mmcblk1p1 vfat SDCARD "14.5G"
: > "$t/mounts"
clear_files
printf '42\n' > "$t/state/notify-id"
watch_wrap insert-mount
card_in_tree
mount_row mmcblk1p1 "/run/media/alarm/SDCARD" "14.4G"
watch_send "UDEV - the card's partitions are ready"
sleep 1.5
case "$(cat "$t/notify")" in
*"SD card"*"SDCARD (vfat, 14.5G): 14.4G free."*) ;;
*) fail "(m) the inserted-and-mounted notification (got: $(cat "$t/notify"))" ;;
esac
grep -q -- "-r 42" "$t/notify" || fail "(m) it replaces the card's previous notification (got: $(cat "$t/notify"))"
grep -q 'mounted SDCARD (vfat) at /run/media/alarm/SDCARD' "$t/log" \
    || fail "(m) one log line for the mount (log: $(cat "$t/log"))"
nlines "$t/notify" 1 || fail "(m) one notification only (got: $(cat "$t/notify"))"
nlines "$t/apps" 0 || fail "(m) nothing else ran (apps: $(cat "$t/apps"))"
nlines "$t/udisks" 0 || fail "(m) watch itself mounted nothing (got: $(cat "$t/udisks"))"
watch_end
echo "ok - watch: insert mounted within the window -> the SD card notification"

# (n) insert unmountable: the not-readable notification
mk_slot on
dev_row mmcblk1p1 "" "" "14.9G"
: > "$t/mounts"
clear_files
watch_wrap insert-blank
card_in_tree
watch_send "UDEV - a card without a file system"
sleep 1.5
case "$(cat "$t/notify")" in
*"SD card not readable"*"No file system this tablet can open. Tap to format it in Disks."*) ;;
*) fail "(n) the not-readable notification (got: $(cat "$t/notify"))" ;;
esac
grep -q 'no file system' "$t/log" || fail "(n) one log line (log: $(cat "$t/log"))"
nlines "$t/notify" 1 || fail "(n) one notification only"
nlines "$t/apps" 0 || fail "(n) nothing ran (apps: $(cat "$t/apps"))"
watch_end
echo "ok - watch: insert without a file system -> the not-readable notification"

# (o) removal while mounted: the critical warning.  watch starts with
# the card in and mounted, so its snapshot knows the card was in use.
mk_slot on
card_in_tree
dev_row mmcblk1p1 vfat SDCARD "14.5G"
mount_row mmcblk1p1 "/run/media/alarm/SDCARD" "14.4G"
clear_files
watch_wrap mounted
watch_send "mount change - the card's state settles"
sleep 0.6
: > "$t/notify"
card_out_tree
: > "$t/mounts"
watch_send "UDEV - the card is gone"
sleep 1.2
case "$(cat "$t/notify")" in
*"SD card removed"*"It was not ejected: files being written may be lost."*) ;;
*) fail "(o) the removal warning (got: $(cat "$t/notify"))" ;;
esac
grep -q -- "-u critical" "$t/notify" || fail "(o) the warning is critical"
grep -q 'card removed while mounted' "$t/log" || fail "(o) one log line (log: $(cat "$t/log"))"
watch_end
echo "ok - watch: removal while mounted -> the critical warning"

# (p) eject then removal: silence
mk_slot on
card_in_tree
dev_row mmcblk1p1 exfat HOLIDAY "14.5G"
mount_row mmcblk1p1 "/run/media/alarm/HOLIDAY" "14.0G"
clear_files
watch_wrap eject
watch_send "any event to sync the initial state"
sleep 0.6
: > "$t/notify"
# eject: the marker, then the unmounts, then the card leaves
: > "$t/state/ejected"
: > "$t/mounts"
watch_send "mount change"
sleep 0.6
card_out_tree
watch_send "UDEV - the card is gone"
sleep 1.2
nlines "$t/notify" 0 || fail "(p) nothing said after an eject (got: $(cat "$t/notify"))"
grep -q 'card removed (it was ejected)' "$t/log" || fail "(p) one log line for the eject's removal (log: $(cat "$t/log"))"
watch_end
echo "ok - watch: removal after an eject -> nothing on screen, one log line"

# (q) a card present at start: mounted by watch itself
mk_slot on
card_in_tree
dev_row mmcblk1p1 vfat SDCARD "14.5G"
: > "$t/mounts"
clear_files
watch_wrap start
sleep 1.2
case "$(cat "$t/notify")" in
*"SD card"*"SDCARD (vfat, 14.5G): 14.4G free."*) ;;
*) fail "(q) the start notification (got: $(cat "$t/notify"))" ;;
esac
grep -qx "udisksctl mount -b /dev/mmcblk1p1" "$t/udisks" || fail "(q) watch mounted the card itself"
nlines "$t/udisks" 1 || fail "(q) exactly one udisksctl call (got: $(cat "$t/udisks"))"
grep -q 'udiskie mounts add events only' "$t/log" || fail "(q) one log line for the start mount (log: $(cat "$t/log"))"
nlines "$t/apps" 0 || fail "(q) nothing opened on its own (apps: $(cat "$t/apps"))"
watch_end
echo "ok - watch: a card in at start is mounted by watch, with the notification"

# --- the user unit, statically ---------------------------------------------------------
[ -f "$UNIT" ] || fail "no $UNIT"
grep -qx 'ExecStart=/usr/local/bin/t715-sdcard watch' "$UNIT" \
    || fail "the unit runs t715-sdcard watch"
grep -qx 'PartOf=graphical-session.target' "$UNIT" || fail "PartOf= missing"
grep -qx 'After=graphical-session.target' "$UNIT" || fail "After= missing"
grep -qx 'Restart=on-failure' "$UNIT" || fail "Restart=on-failure missing"
grep -qx 'RestartSec=5' "$UNIT" || fail "RestartSec=5 missing"
grep -qx 'WantedBy=graphical-session.target' "$UNIT" || fail "WantedBy= missing"
head -n1 "$UNIT" | grep -q '^#' || fail "the unit carries a header comment"
grep -Fqx '[ -x /usr/local/bin/t715-sdcard ] || die "no /usr/local/bin/t715-sdcard"' "$CONF" \
    || fail "configure-system.sh checks for t715-sdcard"
grep -qx 'systemctl --global enable t715-keys.service t715-squeekboard.service t715-idle.service t715-update-check.timer t715-animations.path t715-animations.service t715-sdcard.service' "$CONF" \
    || fail "configure-system.sh enables t715-sdcard.service on its global enable line"
echo "ok - the user unit's keys, configure-system.sh's check and global enable"

# --- the udev rule -----------------------------------------------------------------------
[ -f "$RULE" ] || fail "no $RULE"
# shellcheck disable=SC2016  # udev's $env{...} must stay a literal dollar
grep -Fqx 'SUBSYSTEM=="block", KERNEL=="mmcblk[1-9]p[0-9]*", SYMLINK-="disk/by-partlabel/$env{ID_PART_ENTRY_NAME}"' "$RULE" \
    || fail "the rule removes the card partitions' by-partlabel links"
grep -q 'SYMLINK+=' "$RULE" && fail "the rule adds no link"
grep -qi 'eFuses\|RADIO' "$RULE" || fail "the header names the readers it protects"
echo "ok - the udev rule: one SYMLINK-= line for the card's partitions"

echo "PASS"
