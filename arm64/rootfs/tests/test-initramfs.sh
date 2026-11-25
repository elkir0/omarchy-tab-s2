#!/bin/bash
# test-initramfs.sh — what can be checked of the arm64 initramfs skeleton
# without a kernel: in Docker, with the busybox of the built initramfs.
#
#   1. its init parses under that busybox's sh;
#   2. its functions on files: read_knobs (the command line's values, what is
#      refused), check_ext4 (a superblock with and without the magic),
#      find_userdata (a fake /sys/block);
#   3. its flows against stub commands that log every mount, losetup, chroot,
#      switch_root: image mode; a persistent root that exists; its first boot
#      (the seed: what is copied, the marker, the rename); a seed without
#      room and a failing e2fsck (the fallback to image mode); a directory
#      without the marker (used only when it is an aarch64 system: a root
#      seeded by hand; never an armv7h root or a stray directory); a missing
#      image (which must wait, never hand over);
#      main itself, with the command line and /sys/block of the test;
#      t715.wdtfeed=1, the watchdog fed from the initramfs until the hand-over.
# Nothing is mounted for real: this checks which calls are made, in which
# order, with which options, not what the kernel answers to them.
#
# Usage: tests/test-initramfs.sh      (after initramfs/build-initramfs.sh)
set -euo pipefail

ROOTFS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$ROOTFS_DIR/lib/common.sh"
LOG_TAG=test-initramfs

[ -x "$OUT_DIR/initramfs/root/bin/busybox" ] || die "no $OUT_DIR/initramfs/root/bin/busybox: run initramfs/build-initramfs.sh"
docker_preflight
ensure_helper_image

docker run --rm -i --platform "$PLATFORM" -v "$OUT_DIR/initramfs:/initramfs:ro" \
    "$HELPER_IMAGE" bash -s <<'EOS'
set -u
bb=/initramfs/root/bin/busybox
init=/initramfs/root/init
fails=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }

"$bb" sh -n "$init" && pass "init parses under busybox sh" || fail "init does not parse under busybox sh"

# The functions of init, without its main call.
sed '/^main$/d' "$init" > /tmp/functions.sh
grep -q '^main() {' /tmp/functions.sh && pass "the functions load without running main" || fail "could not separate the functions"

knobs() { # CMDLINE-FILE
    "$bb" sh -c '. /tmp/functions.sh; kmsg=/dev/null; say() { :; }
        CMDLINE="$1"; read_knobs; echo "$ROOTIMG|$PERSIST|$ROOTWAIT|$SHELL"' _ "$1" 2>/dev/null | tail -n1
}

echo "== read_knobs =="
printf 'console=tty1 rootwait t715.rootimg=arm64/x.img t715.persist=arm64 t715.rootwait=7 t715.shell=1\n' >/tmp/cmdline.good
printf 't715.rootimg=/etc/passwd t715.persist=.hidden t715.rootwait=abc\n' >/tmp/cmdline.bad
got="$(knobs /tmp/cmdline.good)"
[ "$got" = 'arm64/x.img|arm64|7|1' ] && pass "t715.rootimg, t715.persist, t715.rootwait and t715.shell are read" || fail "knobs: '$got'"
got="$(knobs /tmp/cmdline.bad)"
[ "$got" = 'media/0/linux/rootfs-aarch64.img||20|0' ] && pass "an absolute path, a hidden name and a bad wait are refused (the defaults)" || fail "refused knobs: '$got'"
got="$(knobs /tmp/does-not-exist)"
[ "$got" = 'media/0/linux/rootfs-aarch64.img||20|0' ] && pass "without a command line: the defaults" || fail "defaults without a command line: '$got'"

echo "== quiet =="
# "quiet" on the command line: log() goes to the kernel log only; warn() still prints.
quiet_out() { # CMDLINE-FILE
    "$bb" sh -c '. /tmp/functions.sh; kmsg=/dev/null; CMDLINE="$1"
        mkdir() { :; }; mount() { :; }; is_mounted() { return 0; }; printf() { [ "$1" = "\033[2J\033[H" ] || command printf "$@"; }
        mount_early; log "a progress line"; warn "a warning"' _ "$1" 2>/dev/null
}
printf 'console=tty0 quiet splash t715.persist=x\n' >/tmp/cmdline.quiet
got="$(quiet_out /tmp/cmdline.quiet)"
[ "$got" = 't715-initramfs: WARNING: a warning' ] && pass "quiet: progress lines off the screen, warnings on it" || fail "quiet: '$got'"
got="$(quiet_out /tmp/cmdline.good)"
[ "$got" = "$(command printf 't715-initramfs: a progress line\nt715-initramfs: WARNING: a warning')" ] && pass "without quiet: progress lines on the screen" || fail "not quiet: '$got'"

echo "== check_ext4 =="
dd if=/dev/zero of=/tmp/ext4dev bs=1 count=1124 2>/dev/null
printf '\123\357' | dd of=/tmp/ext4dev bs=1 seek=1080 conv=notrunc 2>/dev/null
out="$("$bb" sh -c '. /tmp/functions.sh; kmsg=/dev/null; UD_DEV="$1"; check_ext4' _ /tmp/ext4dev 2>&1)"
printf '%s\n' "$out" | grep -q "an ext4 file system (the superblock's magic)" && pass "an ext4 superblock is recognised by its magic" || fail "check_ext4 on an ext4 superblock: $out"
out="$("$bb" sh -c '. /tmp/functions.sh; kmsg=/dev/null; UD_DEV="$1"; check_ext4' _ /tmp/functions.sh 2>&1)"
printf '%s\n' "$out" | grep -q "does not carry ext4's magic" && pass "another file system is said so" || fail "check_ext4 on another file: $out"

echo "== find_userdata =="
rm -rf /tmp/sys; mkdir -p /tmp/sys/block/mmcblk0
mkpart() { mkdir -p "/tmp/sys/block/mmcblk0/$1"; printf 'MAJOR=179\nMINOR=1\nDEVNAME=%s\nPARTNAME=%s\n' "$1" "$2" >"/tmp/sys/block/mmcblk0/$1/uevent"; }
mkpart mmcblk0p9 RADIO; mkpart mmcblk0p22 USERDATA; mkpart mmcblk0p25 HIDDEN
found() { "$bb" sh -c '. /tmp/functions.sh; kmsg=/dev/null; say() { :; }
    TEST=1; SYS_BLOCK=/tmp/sys/block; ROOTWAIT="$1"; find_userdata; echo "dev=$UD_DEV"' _ "$1" 2>/dev/null | tail -n1; }
[ "$(found 3)" = 'dev=/dev/mmcblk0p22' ] && pass "the partition named USERDATA on the eMMC" || fail "find_userdata: $(found 3)"
rm -rf /tmp/sys/block/mmcblk0/mmcblk0p22
[ "$(found 1)" = 'dev=' ] && pass "no USERDATA: a failure after the wait (nothing else is taken)" || fail "find_userdata without USERDATA: $(found 1)"
mkpart mmcblk0p22 USERDATA

echo "== the flows, against stub commands =="
# Debian's busybox is a standalone shell: its applets come before anything in
# PATH, and shell functions come before its applets. The stubs are functions.
stubs='
mount() { echo "mount $*" >>"$CALLS"; for last; do :; done; printf "source %s x rw 0 0\n" "$last" >>"$STAB_MOUNTS"; }
umount() { echo "umount $*" >>"$CALLS"; for last; do :; done; grep -v " $last " "$STAB_MOUNTS" >"$STAB_MOUNTS.new"; mv -f "$STAB_MOUNTS.new" "$STAB_MOUNTS"; }
losetup() { echo "losetup $*" >>"$CALLS"; [ "$1" = -f ] && echo /dev/loop0; return 0; }
blockdev() { echo "blockdev $*" >>"$CALLS"; [ "$1" = --getsize64 ] && echo 1342177280; return 0; }
e2fsck() { echo "e2fsck $*" >>"$CALLS"; return "${E2FSCK_RC:-0}"; }
chroot() { shift; echo "chroot-cp $*" >>"$CALLS"; }
df() { for last; do :; done
    echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
    case "$last" in
        */lower) echo "/dev/loop0 2000000 500000 999999 50% /lower" ;;
        *) echo "/dev/mmc 2000000 100 ${UD_FREE:-2000000} 1% /userdata" ;;
    esac; }
sync() { :; }
sleep() { :; }
kill() { echo "kill $*" >>"$CALLS"; }
watchdog() { echo "watchdog $*" >>"$CALLS"; }
# What handoff does up to its exec, which no test can stand in for.
handoff() { handoff_ready || return 1; echo "SWITCH_ROOT $NEWROOT /sbin/init" >>"$CALLS"; exit 99; }
'

new_world() { # a fake USERDATA tree, the image's tree, empty call and mount logs
    rm -rf /tmp/world
    mkdir -p /tmp/world/userdata/media/0/linux /tmp/world/newroot/run/t715 /tmp/world/run
    : > /tmp/world/userdata/media/0/linux/rootfs-aarch64.img
    # The image's tree, as the seed reads it: top-level entries, lost+found, mnt, and its cp.
    for e in bin etc home usr var; do mkdir -p "/tmp/world/lower/$e"; : > "/tmp/world/lower/$e/file"; done
    mkdir -p /tmp/world/lower/usr/bin /tmp/world/lower/lost+found /tmp/world/lower/mnt
    : > /tmp/world/lower/usr/bin/cp
    chmod 0755 /tmp/world/lower/usr/bin/cp
    : > /tmp/calls
    printf 'source /run x rw 0 0\n' >/tmp/mounts
}
flow() { # SCRIPT [VAR=value ...]: the script in busybox sh, the functions and the stubs loaded
    local script="$1"; shift
    printf '%s\n' "$stubs" >/tmp/stubs.sh
    : > /tmp/calls   # each flow is judged on its own calls (the world may be kept)
    # MOUNTS and CMDLINE are set again below: the functions set their own.
    env -i PATH=/bin:/sbin:/usr/bin:/usr/sbin CALLS=/tmp/calls STAB_MOUNTS=/tmp/mounts \
        FLOW_CMDLINE="${FLOW_CMDLINE:-/tmp/cmdline.none}" "$@" "$bb" sh -c '
        . /tmp/functions.sh
        . /tmp/stubs.sh
        say() { :; }; log() { :; }
        err() { echo "ERR $*" >>"$CALLS"; }
        fallback() { echo FALLBACK >>"$CALLS"; }
        # The real one never returns; it releases the watchdog feeder first.
        wait_for_reset() { wdt_feed_stop; echo "WAIT_FOR_RESET" >>"$CALLS"; }
        mount_early() { :; }
        TEST=1; kmsg=/dev/null; CMDLINE="$FLOW_CMDLINE"; MOUNTS=/tmp/mounts
        DEVWATCHDOG="${FLOW_DEVWATCHDOG:-/nonexistent/watchdog}"
        SYS_BLOCK=/tmp/sys/block; UD_DEV=/dev/mmcblk0p22
        UD_MNT=/tmp/world/userdata; NEWROOT=/tmp/world/newroot
        RUNDIR=/tmp/world/run; LOWER=/tmp/world/lower; RW=/tmp/world/rw
        '"$script" >/tmp/flow.out 2>&1 || true
    cat /tmp/calls > /tmp/calls.read
}
expect() { # NAME PATTERN...: every pattern among the calls, in this order
    local name="$1" pattern line rest; shift
    rest="$(cat /tmp/calls.read)"
    for pattern; do
        line="$(printf '%s\n' "$rest" | grep -nF -- "$pattern" | head -n1 | cut -d: -f1)"
        if [ -z "$line" ]; then
            fail "$name: no \"$pattern\" among the calls"
            sed 's/^/        /' /tmp/calls.read | head -n 16
            return 1
        fi
        # What follows the line that matched: the next pattern must come later.
        rest="$(printf '%s\n' "$rest" | tail -n +"$((line + 1))")"
    done
    pass "$name"
}
expect_not() { # NAME PATTERN
    if grep -qF -- "$2" /tmp/calls.read; then fail "$1: \"$2\" was called"; else pass "$1"; fi
}

: >/tmp/cmdline.none
P='ROOTIMG=media/0/linux/rootfs-aarch64.img;'
RO='mount -t ext4 -o ro,noload,nosuid,nodev,noexec /dev/mmcblk0p22 /tmp/world/userdata'
OVERLAY='mount -t overlay -o lowerdir=/tmp/world/lower,upperdir=/tmp/world/rw/upper,workdir=/tmp/world/rw/work overlayfs /tmp/world/newroot'

new_world; flow "$P mount_userdata_ro; boot_image; handoff"
expect "image mode: read-only without journal replay, the image read-only, the overlay, the hand-over" \
    'blockdev --setro /dev/mmcblk0p22' "$RO" \
    'losetup -r /dev/loop0 /tmp/world/userdata/media/0/linux/rootfs-aarch64.img' \
    'mount -t ext4 -o ro,noload /dev/loop0 /tmp/world/lower' "$OVERLAY" \
    'mount -n -o move /run /tmp/world/newroot/run' 'SWITCH_ROOT /tmp/world/newroot /sbin/init'
expect_not "image mode writes nothing to USERDATA" 'mount -t ext4 -o rw'

new_world; flow "$P mkdir -p /tmp/world/userdata/arm64; : > /tmp/world/userdata/arm64/.t715-persist
    PERSIST=arm64; persist_root; handoff"
expect "a persistent root that exists: checked, mounted read-write, bound as the root, the hand-over" \
    'e2fsck -p /dev/mmcblk0p22' 'mount -t ext4 -o rw,noatime,errors=remount-ro /dev/mmcblk0p22 /tmp/world/userdata' \
    'mount --bind /tmp/world/userdata/arm64 /tmp/world/newroot' 'SWITCH_ROOT /tmp/world/newroot /sbin/init'
expect_not "an existing persistent root needs no image" 'losetup'

new_world; flow "$P PERSIST=arm64; persist_root; handoff"
[ -f /tmp/world/userdata/arm64/.t715-persist ] && pass "the first boot of a persistent root: seeded, the marker written, renamed" \
    || fail "the seed left no USERDATA/arm64/.t715-persist"
expect "the seed: the image read-only, the new directory bound at its mnt, every entry but lost+found copied by the image's cp" \
    'e2fsck -p /dev/mmcblk0p22' 'mount -t ext4 -o rw,noatime,errors=remount-ro /dev/mmcblk0p22 /tmp/world/userdata' \
    'losetup -r /dev/loop0 /tmp/world/userdata/media/0/linux/rootfs-aarch64.img' \
    'mount -t ext4 -o ro,noload /dev/loop0 /tmp/world/lower' \
    'mount --bind /tmp/world/userdata/.arm64.t715-seed /tmp/world/lower/mnt' \
    'chroot-cp /usr/bin/cp -a /bin /mnt/' 'chroot-cp /usr/bin/cp -a /etc /mnt/' \
    'chroot-cp /usr/bin/cp -a /home /mnt/' 'chroot-cp /usr/bin/cp -a /usr /mnt/' \
    'chroot-cp /usr/bin/cp -a /var /mnt/' 'umount /tmp/world/lower/mnt' \
    'mount --bind /tmp/world/userdata/arm64 /tmp/world/newroot' 'SWITCH_ROOT /tmp/world/newroot /sbin/init'
expect_not "the seed skips lost+found" 'chroot-cp /usr/bin/cp -a /lost+found'
expect_not "the seed skips mnt itself" 'chroot-cp /usr/bin/cp -a /mnt /'

new_world; flow "$P PERSIST=arm64; persist_root || { fallback; mount_userdata_ro; boot_image; handoff; }" UD_FREE=100000
expect "a seed without room: said so, and image mode takes over" \
    'ERR USERDATA has 97 MiB free, the seed needs 1000 MiB' 'FALLBACK' "$RO" "$OVERLAY" 'SWITCH_ROOT /tmp/world/newroot /sbin/init'
expect_not "without room nothing is copied" 'chroot-cp'

new_world; flow "$P PERSIST=arm64; persist_root || fallback" E2FSCK_RC=4
expect "a failing e2fsck: said so, no read-write mount" 'e2fsck -p /dev/mmcblk0p22' 'ERR e2fsck left errors on USERDATA (exit 4)' 'FALLBACK'
expect_not "a failing e2fsck: USERDATA is not mounted read-write" 'mount -t ext4 -o rw'

new_world; flow "$P mkdir -p /tmp/world/userdata/arm64; PERSIST=arm64; persist_root || fallback"   # no marker, no system: never touched
expect "a directory without the marker that is no system is never used" 'ERR USERDATA/arm64 exists without its marker and is no aarch64 system' 'FALLBACK'
expect_not "no bind of a directory without the marker" 'mount --bind /tmp/world/userdata/arm64'

# elf CLASS MACHINE FILE: a 64-byte ELF header (class byte 4, machine byte 18).
elf() { mkdir -p "${3%/*}"; dd if=/dev/zero of="$3" bs=64 count=1 2>/dev/null
    printf '\177ELF' | dd of="$3" conv=notrunc 2>/dev/null
    printf "$1\001\001" | dd of="$3" bs=1 seek=4 conv=notrunc 2>/dev/null
    printf "$2" | dd of="$3" bs=1 seek=18 conv=notrunc 2>/dev/null; }
new_world; elf '\002' '\267' /tmp/world/userdata/omarchy-arm64/usr/lib/systemd/systemd
flow "$P PERSIST=omarchy-arm64; persist_root; handoff"
expect "a root seeded by hand (no marker, an aarch64 systemd): checked, mounted read-write, bound as the root, the hand-over" \
    'e2fsck -p /dev/mmcblk0p22' 'mount -t ext4 -o rw,noatime,errors=remount-ro /dev/mmcblk0p22 /tmp/world/userdata' \
    'mount --bind /tmp/world/userdata/omarchy-arm64 /tmp/world/newroot' 'SWITCH_ROOT /tmp/world/newroot /sbin/init'
expect_not "a root seeded by hand is not seeded again" 'losetup'
[ ! -e /tmp/world/userdata/omarchy-arm64/.t715-persist ] && pass "a root seeded by hand gets no marker (nothing is written into it)" \
    || fail "the init wrote a marker into a root seeded by hand"

new_world; elf '\001' '\050' /tmp/world/userdata/omarchy/usr/lib/systemd/systemd   # the armv7h system's root
flow "$P PERSIST=omarchy; persist_root || fallback"
expect "an armv7h root without the marker (a 32-bit ARM systemd) is never used" 'ERR USERDATA/omarchy exists without its marker and is no aarch64 system' 'FALLBACK'
expect_not "no bind of the armv7h root" 'mount --bind /tmp/world/userdata/omarchy'

new_world; elf '\002' '\076' /tmp/world/userdata/arm64/usr/lib/systemd/systemd   # x86-64
flow "$P PERSIST=arm64; persist_root || fallback"
expect "a 64-bit root of another machine (x86-64) is never used" 'ERR USERDATA/arm64 exists without its marker and is no aarch64 system' 'FALLBACK'

printf 'console=tty1 t715.persist=omarchy-arm64 t715.kbootmark=0 t715.return=20\n' >/tmp/cmdline.lead
new_world; elf '\002' '\267' /tmp/world/userdata/omarchy-arm64/usr/lib/systemd/systemd
flow "main" FLOW_CMDLINE=/tmp/cmdline.lead
expect "main, the owner's root USERDATA/omarchy-arm64 seeded by hand: no seed, bound as the root, the hand-over" \
    'e2fsck -p /dev/mmcblk0p22' 'mount --bind /tmp/world/userdata/omarchy-arm64 /tmp/world/newroot' 'SWITCH_ROOT /tmp/world/newroot /sbin/init'
expect_not "main, a root seeded by hand: no image attached" 'losetup'

new_world; flow "$P rm -f /tmp/world/userdata/media/0/linux/rootfs-aarch64.img; main"
expect "a missing image (main): said so, and init waits for the reset: no hand-over" \
    "$RO" 'ERR no image media/0/linux/rootfs-aarch64.img on USERDATA' 'WAIT_FOR_RESET'
expect_not "a missing image: no hand-over" 'SWITCH_ROOT'

new_world; flow "main"
expect "main, image mode: from the kernel command line to the hand-over" \
    'blockdev --setro /dev/mmcblk0p22' "$RO" "$OVERLAY" 'SWITCH_ROOT /tmp/world/newroot /sbin/init'
expect_not "main, image mode: nothing is mounted read-write" 'mount -t ext4 -o rw'

printf 't715.persist=arm64\n' >/tmp/cmdline.other
new_world; flow "main" FLOW_CMDLINE=/tmp/cmdline.other
expect "main with a persistent root on the command line, its first boot: e2fsck, the seed, the hand-over" \
    'e2fsck -p /dev/mmcblk0p22' 'losetup -r /dev/loop0 /tmp/world/userdata/media/0/linux/rootfs-aarch64.img' \
    'chroot-cp /usr/bin/cp -a /bin /mnt/' \
    'mount --bind /tmp/world/userdata/arm64 /tmp/world/newroot' 'SWITCH_ROOT /tmp/world/newroot /sbin/init'
flow "main" FLOW_CMDLINE=/tmp/cmdline.other   # the same world: the root exists now
expect "main, the next boot of that root: no seed any more" \
    'e2fsck -p /dev/mmcblk0p22' 'mount --bind /tmp/world/userdata/arm64 /tmp/world/newroot' 'SWITCH_ROOT /tmp/world/newroot /sbin/init'
expect_not "the next boot: no image attached" 'losetup'

# t715.wdtfeed=1: fed from the first knob to the hand-over, then released.
printf 't715.wdtfeed=1\n' >/tmp/cmdline.feed
new_world; flow "main" FLOW_CMDLINE=/tmp/cmdline.feed
expect "without a watchdog device, t715.wdtfeed=1 feeds nothing" 'blockdev --setro /dev/mmcblk0p22' 'SWITCH_ROOT /tmp/world/newroot /sbin/init'
expect_not "without a watchdog device the applet is not started" 'watchdog -F'
new_world; flow "main" FLOW_CMDLINE=/tmp/cmdline.feed FLOW_DEVWATCHDOG=/dev/null
expect "t715.wdtfeed=1: fed from the start, released just before the hand-over" \
    'watchdog -F -T 5 /dev/null' 'mount -t ext4 -o ro,noload,nosuid,nodev,noexec /dev/mmcblk0p22 /tmp/world/userdata' \
    "$OVERLAY" 'kill ' 'mount -n -o move /run /tmp/world/newroot/run' 'SWITCH_ROOT /tmp/world/newroot /sbin/init'
new_world; flow "$P rm -f /tmp/world/userdata/media/0/linux/rootfs-aarch64.img; main" FLOW_CMDLINE=/tmp/cmdline.feed FLOW_DEVWATCHDOG=/dev/null
expect "t715.wdtfeed=1 and a failure: the feeder is stopped before the wait for the reset" \
    'watchdog -F -T 5 /dev/null' 'ERR no image media/0/linux/rootfs-aarch64.img on USERDATA' 'kill ' 'WAIT_FOR_RESET'
expect_not "a failure with the feeder on: no hand-over" 'SWITCH_ROOT'

echo "-----"
[ "$fails" -eq 0 ] && { echo "TEST: PASS"; exit 0; }
echo "TEST: FAIL ($fails)"
exit 1
EOS
