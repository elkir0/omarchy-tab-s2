#!/usr/bin/env bash
# Host-side tests for the SM-T715 initramfs (boot/initramfs/init,
# boot/build-initramfs.sh).  Never touches the tablet.
#
#  1. Reproducibility: two builds into temp dirs must be byte-identical.
#  2. shellcheck: the init (-s sh) and the bash scripts.
#  3. Boot test in Docker: linux/arm/v7 (the tablet's userspace ISA, run by
#     qemu), --privileged (loop devices, mounts; this test only),
#     --network none.  The freshly built cpio is unpacked onto a tmpfs and
#     its /init runs as PID 1 of new PID + mount namespaces, chrooted there
#     like the kernel's rootfs, with T715_INITRAMFS_TEST=host-test (log to
#     stderr, knobs from $T715_TEST_CMDLINE, veth pair instead of the USB
#     gadget, exit 99 instead of reboot).  A synthetic GPT disk on a loop
#     device (partitions EFS, SYSTEM, USERDATA) carries an ext4 USERDATA
#     with media/0/linux/rootfs.img: a tiny ext4 "rootfs" whose /sbin/init
#     checks, after the real switch_root, what the initramfs handed over.
#     Scenarios: shell (t715.shell=1 t715.telnet=1, DHCP lease + telnet
#     from the "host" end of the veth, then continue), direct boot, missing
#     image, invalid t715.rootimg, no USERDATA.  USERDATA's checksum must
#     not change in any of them.  Then the persistent root (rootfs.select
#     line 2 persist=omarchy): first boot (e2fsck, seed over an interrupted
#     one, read-write bind root, on-screen progress lines), second boot (no
#     seed, state kept), rescue (t715.persist=0: image mode), a directory
#     without the marker (refused, image mode), a good rootfs-alt.img.sha256
#     sidecar (checked, seed runs), a bad one (refused: no seed directory,
#     USERDATA untouched), the same again as written on Windows (CR LF, a
#     UTF-8 byte order mark, an upper-case hash: accepted; a wrong CR LF
#     hash: refused) and with two lines (refused as malformed), a too-small
#     USERDATA (fallback to image mode with the "Not enough free space"
#     line).  Also the end-user defaults:
#     no telnet on the default boot (port closed, log says so), and
#     t715.failreboot=0 turning a failure into exit 97 with the on-screen
#     failure line.  USERDATA must stay fsck-clean.  The eMMC-only
#     partition lookup: list_partnames, extracted from the unpacked /init,
#     ignores a microSD card that carries a clone of a tablet's eMMC
#     (15560000.mmc, mmcblk1p*, USERDATA and SYSTEM among its names) while
#     keeping the eMMC's and the test loop disk's names, and a boot with a
#     second disk also named USERDATA is still refused.
#
#     The loader's rescue (t715.paramrescue: a tablet whose only system is
#     started by a loader in PARAM).  The disk has an 8 MiB PARAM that starts
#     with the loader the rescue knows, and a second initramfs is built with
#     --paramrescue (reproducible too; the option refuses to build without the
#     stock PARAM's sha256).  PARAM holding anything else, /init writes the
#     known loader there and exits 98 instead of restarting.  The knob off,
#     the stock image, the known loader, the files missing, an image that is
#     not the one its sha256 announces, a disk that cannot be written and a
#     disk with no partition named PARAM: nothing is written, and the boot
#     goes on to the failure path (exit 99).  PARAM flagged read-only (a flag
#     of the system of every day): cleared, and the loader written.  Then a
#     rescue whose loader is only the first half of PARAM
#     (--paramrescue-extent 4194304): data S-Boot wrote after the loader
#     changes nothing (the loader, the stock image: nothing done, the data
#     kept), a change inside the loader's part is written over and what
#     follows is kept, a loader of the list of those left alone
#     (--paramrescue-also) is left alone, a malformed length is refused.
#
#     The installer of the 64-bit system (t715.golden=1, a build with --golden
#     DIR): a second synthetic disk (PARAM 8 MiB, SYSTEM with the Wi-Fi NVRAM
#     and the Bluetooth patch RAM, CACHE 200 MiB as Android leaves it: one
#     file system spanning the partition, USERDATA with omarchy-arm64.img
#     and its .sha256 sidecar in media/0/linux; the image is an ext4 root
#     tree carrying usr/lib/t715-golden/kernel.slot, a generation-0 slot).
#     Scenarios: the fresh install, the resume (the root is there already:
#     the copy is skipped), the loader's hand-back (exit 99 after
#     t715.failwait), the rescue (PARAM holds neither image: the loader is
#     forged again from the root's saved stock PARAM), a PARAM whose archive
#     is the stock one with non-zero bytes left after its end (installed all
#     the same, the loader's zeros over them; the same tolerance in the
#     rescue's forge), a PARAM whose archive is not the stock one (the
#     on-screen report of what differs against stock.members, then the
#     refusal), the refusals (unknown
#     PARAM, wrong bootloader, no or wrong sidecar, not an aarch64 image, a
#     foreign root: exit 97, PARAM/CACHE/USERDATA byte-identical), the slots
#     already in CACHE (the free one gets one generation above the other,
#     the file system and the other slot stay byte-identical), the reinstall
#     asked by linux/reinstall over an installed root with the loader in
#     PARAM (the happy path: the old root kept as omarchy-arm64.previous,
#     the request file gone, the saved stock PARAM carried over to the new
#     root, PARAM left alone, the free slot one generation above the other;
#     refused while omarchy-arm64.previous exists, with no image, a bad sum
#     or not enough free space: exit 97, nothing written; a copy that fails
#     puts the kept root back and restarts; an interrupted one, the old root
#     at omarchy-arm64.previous and no request file, goes on as a plain
#     install and carries the saved stock PARAM over), and the forge
#     and fnv1a64 of the init against Python (boot/golden/check-param.py's
#     forge).  All the golden fixtures are synthetic, generated on the host
#     with python3.
#
# Usage: bash boot/tests/test_initramfs.sh
# (internal: --in-container CPIO_GZ, run inside the test container)
set -euo pipefail

BASE_IMAGE="debian@sha256:8c4733a92aacd0bcff3779eadc35a4a5147f36cb20a5fcb56504cbc740212259"
TOOLS_IMAGE="t715-initramfs-tools:1"   # built by boot/build-initramfs.sh
TEST_IMAGE="t715-initramfs-test:2"

# ===========================================================================
# inside the container (Debian armhf, root, privileged)
# ===========================================================================

W=/work
NPASS=0
NFAIL=0
BOOT_PID=""
LOOPS=()

ok() { echo "  PASS  $*"; NPASS=$((NPASS + 1)); }
ko() { echo "  FAIL  $*"; NFAIL=$((NFAIL + 1)); }
check() {  # DESCRIPTION COMMAND...
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else ko "$d"; fi
}
log_has() { grep -qF -- "$2" "$W/$1.log"; }

# A loop device node from the VM's devtmpfs (the container's /dev is static).
node() { echo "$W/dev/${1#/dev/}"; }

detach_inner_loops() {
  local dev
  # The init attached media/0/linux/rootfs.img or omarchy-arm64.img from its
  # own namespace (losetup shows the backing file with or without its path,
  # depending on whether that namespace is still alive).
  for dev in $(losetup -a 2>/dev/null | awk -F: '/(media\/0\/linux\/)?(rootfs|omarchy-arm64)[^\/]*\.img/ {print $1}'); do
    losetup -d "$(node "$dev")" 2>/dev/null || true
  done
}

container_cleanup() {
  if [[ -n "$BOOT_PID" ]]; then kill "$BOOT_PID" 2>/dev/null || true; fi
  ip link del usb0 2>/dev/null || true
  detach_inner_loops
  local l
  for l in "${LOOPS[@]}"; do losetup -d "$(node "$l")" 2>/dev/null || true; done
}

wait_for() {  # LOGNAME TEXT SECONDS
  local i
  for ((i = 0; i < $3; i++)); do
    log_has "$1" "$2" && return 0
    sleep 1
  done
  return 1
}

# prepare_boot NAME [KNOBS_FILE_CONTENT]: unpack the cpio on a fresh tmpfs
# and create the veth pair standing in for the gadget's usb0 (the init
# deletes usb0 at hand-over, as removing the gadget function would).
prepare_boot() {
  local r="$W/root-$1"
  ip link del usb0 2>/dev/null || true
  ip link add usb0 type veth peer name t715host0
  ip link set dev t715host0 up
  mkdir -p "$r"
  mount -t tmpfs -o mode=0755 "initrd-$1" "$r"
  (cd "$r" && gzip -dc "$CPIO" | cpio -idm --quiet --no-absolute-filenames)
  if [[ -n "${2:-}" ]]; then printf '%s\n' "$2" >"$r/etc/t715-knobs"; fi
  # Stand-in for the module tree of build-initramfs.sh --modules, named
  # after the running kernel as /init looks it up with uname -r.
  mkdir -p "$r/lib/modules/$(uname -r)/kernel"
  printf '# t715 test tree\n' >"$r/lib/modules/$(uname -r)/modules.dep"
}
# run_init NAME CMDLINE: run the unpacked /init as PID 1 of new PID + mount
# namespaces, chrooted (output in $W/NAME.log, its exit status returned).
run_init() {
  env -i HOME=/ TERM=linux T715_INITRAMFS_TEST=host-test T715_TEST_CMDLINE="$2" \
    /usr/bin/unshare --pid --mount --propagation private --kill-child \
    /usr/sbin/chroot "$W/root-$1" /init >"$W/$1.log" 2>&1
}
show_log() { sed 's/^/        | /' "$W/$1.log"; }

write_fake_init() {
  cat >"$1" <<'EOF'
#!/bin/sh
# Stand-in for systemd (boot/tests/test_initramfs.sh): runs as PID 1
# after the initramfs' switch_root and checks what it handed over.
PATH=/usr/bin
export PATH
n=0
check() {
    if eval "$2" >/dev/null 2>&1; then
        echo "T715TEST ok: $1"
    else
        echo "T715TEST FAIL: $1"
        n=$((n + 1))
    fi
}
field() { # MOUNTPOINT FIELD(1=source 3=fstype 4=options)
    while read -r s m t o _; do
        if [ "$m" = "$1" ]; then
            case $2 in 1) echo "$s" ;; 3) echo "$t" ;; 4) echo "$o" ;; esac
        fi
    done </proc/mounts
}
has_opt() { case ",$(field "$1" 4)," in *,"$2",*) return 0 ;; esac; return 1; }
LOOP=$(field /run/t715/lower 1)
UD=$(field /run/t715/userdata 1)
check "running as PID 1" '[ "$$" = 1 ]'
if [ "$(field / 3)" = overlay ]; then
echo "T715TEST mode=image loop=$LOOP userdata=$UD"
check "/ is the t715 overlay, read-write" '[ "$(field / 1)" = t715-root ] && [ "$(field / 3)" = overlay ] && has_opt / rw'
check "image mounted ro at /run/t715/lower" '[ "$(field /run/t715/lower 3)" = ext4 ] && has_opt /run/t715/lower ro'
check "upper layer on tmpfs /run/t715/rw" '[ "$(field /run/t715/rw 3)" = tmpfs ]'
check "USERDATA mounted ro at /run/t715/userdata" '[ "$(field /run/t715/userdata 3)" = ext4 ] && has_opt /run/t715/userdata ro'
check "USERDATA without journal replay" 'has_opt /run/t715/userdata norecovery || has_opt /run/t715/userdata noload'
check "USERDATA nosuid,nodev,noexec" 'has_opt /run/t715/userdata nosuid && has_opt /run/t715/userdata nodev && has_opt /run/t715/userdata noexec'
check "USERDATA block device read-only (BLKROSET)" '[ "$(blockdev --getro "$UD")" = 1 ]'
check "loop device read-only" '[ "$(cat /sys/block/${LOOP#/dev/}/ro)" = 1 ]'
check "write to USERDATA refused" '! touch /run/t715/userdata/t715-write-test'
check "rw remount of USERDATA refused" '! mount -o remount,rw /run/t715/userdata'
check "USERDATA still read-only after that" 'has_opt /run/t715/userdata ro'
check "image content visible" '[ "$(cat /etc/lower-marker)" = "fake rootfs" ]'
check "module tree installed in the root" '[ "$(cat "/lib/modules/$(uname -r)/modules.dep")" = "# t715 test tree" ]'
check "module tree in the tmpfs layer, not the image" '[ ! -e /run/t715/lower/lib/modules ]'
check "root writable" 'echo t715 >/etc/overlay-test && [ "$(cat /etc/overlay-test)" = t715 ]'
check "writes land in the tmpfs, not the image" '[ -e /run/t715/rw/upper/etc/overlay-test ] && [ ! -e /run/t715/lower/etc/overlay-test ]'
else
read -r _ _ P _ </.t715-persist
P=${P%,}
echo "T715TEST mode=persist root=$P userdata=$UD"
check "/ is a read-write ext4 persistent root" '[ "$(field / 3)" = ext4 ] && has_opt / rw && [ -f /.t715-persist ]'
check "root keeps exec, suid and devices" '! has_opt / noexec && ! has_opt / nosuid && ! has_opt / nodev'
check "USERDATA mounted rw at /run/t715/userdata" '[ "$(field /run/t715/userdata 3)" = ext4 ] && has_opt /run/t715/userdata rw'
check "USERDATA errors=remount-ro" 'has_opt /run/t715/userdata errors=remount-ro'
check "USERDATA view nosuid,nodev,noexec" 'has_opt /run/t715/userdata nosuid && has_opt /run/t715/userdata nodev && has_opt /run/t715/userdata noexec'
check "USERDATA block device writable" '[ "$(blockdev --getro "$UD")" = 0 ]'
check "the root is USERDATA/$P" 'echo "$$" >/t715-probe && [ "$(cat "/run/t715/userdata/$P/t715-probe")" = 1 ]'
check "no image attached" '! grep -q " /run/t715/lower " /proc/mounts'
check "seeded image content" '[ "$(cat /etc/lower-marker)" = "fake rootfs" ]'
check "/mnt created empty" '[ -d /mnt ] && [ -z "$(ls -A /mnt)" ]'
check "lost+found not copied" '[ ! -e /lost+found ]'
check "module tree installed with its stamp" '[ "$(cat "/lib/modules/$(uname -r)/modules.dep")" = "# t715 test tree" ] && [ -s "/lib/modules/$(uname -r)/.t715-initramfs" ]'
check "e2fsck log kept in /run" '[ -f /run/t715/e2fsck.log ]'
b=$(cat /var/t715-boots 2>/dev/null)
b=$((${b:-0} + 1))
echo "$b" >/var/t715-boots
echo "T715TEST boots=$b"
fi
check "USERDATA files readable" '[ "$(cat /run/t715/userdata/media/0/Download/notes.txt)" = "synthetic owner file" ]'
check "/dev /proc /sys /run moved into the new root" '[ "$(field /dev 3)" = devtmpfs ] && [ "$(field /proc 3)" = proc ] && [ "$(field /sys 3)" = sysfs ] && [ "$(field /run 3)" = tmpfs ]'
check "/dev/pts mounted" '[ "$(field /dev/pts 3)" = devpts ]'
check "t715.modblacklist written to /run/modprobe.d" 'grep -qx "blacklist pci_exynos" /run/modprobe.d/t715-knob-blacklist.conf && grep -qx "blacklist brcmfmac" /run/modprobe.d/t715-knob-blacklist.conf'
check "t715.autotest unit runs the script from USERDATA" 'grep -qx "ExecStart=/bin/sh /run/t715/userdata/media/0/linux/t715-autotest.sh" /run/systemd/system/t715-autotest.service && grep -qx "Type=simple" /run/systemd/system/t715-autotest.service'
check "t715.autotest unit enabled" '[ "$(readlink /run/systemd/system/multi-user.target.wants/t715-autotest.service)" = ../t715-autotest.service ]'
check "t715.autotest forwards the journal to the kernel log" 'grep -qx "ForwardToKMsg=yes" /run/systemd/journald.conf.d/90-t715-kmsg.conf'
check "no knob file in the root's /etc" '[ ! -e /etc/modprobe.d/t715-knob-blacklist.conf ] && [ ! -e /etc/systemd/system/t715-autotest.service ]'
check "initramfs log kept in /run" 'grep -q "exec switch_root" /run/t715/initramfs.log'
check "debug interface gone" '! ip link show usb0'
check "no telnetd/udhcpd left" '! grep -qsxE "telnetd|udhcpd" /proc/[0-9]*/comm'
# Every process but PID 1 (zombies aside) must be gone; no fork here.
others=0
for p in /proc/[0-9]*; do
    [ "${p#/proc/}" = 1 ] && continue
    read -r _ _ st _ <"$p/stat" 2>/dev/null || continue
    [ "$st" = Z ] || others=$((others + 1))
done
check "only PID 1 survived the hand-over" '[ "$others" = 0 ]'
if [ "$n" -eq 0 ]; then
    echo "T715TEST RESULT: PASS"
else
    echo "T715TEST RESULT: FAIL ($n)"
fi
exit "$n"
EOF
  chmod 0755 "$1"
}

make_fixtures() {
  mkdir -p "$W/x"
  (cd "$W/x" && gzip -dc "$CPIO" | cpio -idm --quiet --no-absolute-filenames)
  BB="$W/x/bin/busybox"

  # Fake Arch-like rootfs: /sbin -> usr/bin, /lib -> usr/lib,
  # /usr/bin/init -> ../lib/systemd/systemd
  local f="$W/fakeroot" a
  mkdir -p "$f/usr/bin" "$f/usr/lib/systemd" "$f/etc" "$f/dev" "$f/proc" "$f/sys" "$f/run" "$f/tmp" "$f/mnt" "$f/var"
  ln -s usr/bin "$f/bin"
  ln -s usr/bin "$f/sbin"
  ln -s usr/lib "$f/lib"
  cp "$BB" "$f/usr/bin/busybox"
  for a in sh cat grep blockdev touch mount ip uname cp ls readlink; do ln -s busybox "$f/usr/bin/$a"; done
  ln -s ../lib/systemd/systemd "$f/usr/bin/init"
  write_fake_init "$f/usr/lib/systemd/systemd"
  echo "fake rootfs" >"$f/etc/lower-marker"
  mkfs.ext4 -q -F -L ALARM -d "$f" "$W/rootfs.img" 24M

  # Synthetic USERDATA with "owner" files around the image.
  local u="$W/userdata"
  mkdir -p "$u/media/0/linux" "$u/media/0/DCIM" "$u/media/0/Download"
  cp "$W/rootfs.img" "$u/media/0/linux/rootfs.img"
  # Second image picked by rootfs.select (same content, other name).
  cp "$W/rootfs.img" "$u/media/0/linux/rootfs-alt.img"
  printf "rootfs-alt.img\r\n" >"$u/media/0/linux/rootfs.select"
  head -c 262144 /dev/urandom >"$u/media/0/DCIM/IMG_0001.jpg"
  echo "synthetic owner file" >"$u/media/0/Download/notes.txt"
  mkfs.ext4 -q -F -d "$u" "$W/userdata.img" 64M

  # GPT disk: USERDATA is the 3rd partition (found by name, not number).
  # PARAM is the 4th, 8 MiB as on the tablet, holding the loader the rescue
  # knows (/t/param-known.img).
  truncate -s 80M "$W/disk.img"
  sfdisk -q "$W/disk.img" <<'EOF'
label: gpt
start=2048, size=2048, name=EFS
start=4096, size=8192, name=SYSTEM
start=12288, size=131072, name=USERDATA
start=143360, size=16384, name=PARAM
EOF
  dd if="$W/userdata.img" of="$W/disk.img" bs=512 seek=12288 conv=notrunc status=none
  dd if=/t/param-known.img of="$W/disk.img" bs=512 seek=143360 conv=notrunc status=none
}

disk_sums() {
  sync
  echo "disk=$(sha256sum <"$W/disk.img" | cut -d' ' -f1)"
  echo "userdata=$(dd if="$W/disk.img" bs=512 skip=12288 count=131072 status=none | sha256sum | cut -d' ' -f1)"
}

attach_disk() {  # [IMAGE] [PART_WITH_USERDATA]: the disk image to attach (the fixtures' by default)
  local n part=${2:-3}
  n=$(losetup -f)
  losetup -P "$(node "$n")" "${1:-$W/disk.img}"
  LOOPS+=("$n")
  OUTER=$n
  local i
  for ((i = 0; i < 20; i++)); do
    grep -qx "PARTNAME=USERDATA" "/sys/class/block/${n#/dev/}p$part/uevent" 2>/dev/null && return 0
    sleep 0.5
  done
  return 1
}

detach_disk() {
  losetup -d "$(node "$OUTER")"
  LOOPS=()
}

# --- scenarios ---------------------------------------------------------------

scenario_shell() {
  echo "--- scenario: t715.shell=1 t715.telnet=1 (debug link, DHCP, telnet, then continue)"
  prepare_boot shell
  run_init shell "t715.shell=1 t715.telnet=1 t715.rootwait=30 t715.failwait=120 t715.modblacklist=pci_exynos,brcmfmac t715.autotest=1" &
  BOOT_PID=$!
  if ! wait_for shell "staying in the initramfs" 240; then
    ko "initramfs reached the shell-mode wait"; show_log shell
    kill "$BOOT_PID" 2>/dev/null || true; wait "$BOOT_PID" 2>/dev/null || true; BOOT_PID=""
    return
  fi
  ok "initramfs reached the shell-mode wait"

  check "usb0 carries 172.16.42.1/24" sh -c 'ip -4 addr show dev usb0 | grep -q "inet 172.16.42.1/24 "'
  local listen
  listen=$("$BB" netstat -ltn 2>/dev/null | awk '$4 ~ /:23$/ {print $4}' | tr '\n' ' ') || true
  if [[ "$listen" == "172.16.42.1:23 " ]]; then ok "telnetd listens on 172.16.42.1:23 only"
  else ko "telnetd listens on 172.16.42.1:23 only (got: '$listen')"; fi

  cat >"$W/dhcp.sh" <<'EOF'
#!/bin/sh
[ "$1" = bound ] && echo "LEASE $ip $subnet"
exit 0
EOF
  chmod 0755 "$W/dhcp.sh"
  local lease
  lease=$(timeout 60 "$BB" udhcpc -i t715host0 -f -q -n -t 5 -T 3 -s "$W/dhcp.sh" 2>/dev/null \
    | awk '/^LEASE/ {print $2, $3}') || true
  case "$lease" in
    "172.16.42."[2-9]" 255.255.255.0" | "172.16.42.10 255.255.255.0") ok "DHCP lease in 172.16.42.2-10 ($lease)" ;;
    *) ko "DHCP lease in 172.16.42.2-10 (got: '$lease')" ;;
  esac

  # The typed commands echo back verbatim; only their results contain
  # 42TELNET / RO2DENIED / UD1MOUNTED.
  # shellcheck disable=SC2016  # expanded by the remote shell
  { printf '%s\n' 'echo $((6*7))TELNET' \
      'touch /userdata/t715-probe 2>/dev/null || echo RO$((1+1))DENIED' \
      'grep -c " /userdata ext4 ro," /proc/mounts | sed s/^/UD/ | sed s/$/MOUNTED/' 'exit'
    sleep 8; } | timeout 30 "$BB" nc 172.16.42.1 23 >"$W/telnet.out" 2>&1 || true
  check "telnet debug shell answers" grep -q 42TELNET "$W/telnet.out"
  check "USERDATA read-only from the debug shell" grep -q RO2DENIED "$W/telnet.out"
  check "USERDATA mounted ro on /userdata" grep -q UD1MOUNTED "$W/telnet.out"

  # A debug-shell leftover immune to the hang-up: the hand-over must kill it.
  cat >"$W/root-shell/tmp/plant.sh" <<'EOF'
trap '' HUP
echo $$ >/tmp/t715-leftover.pid
exec sleep 600
EOF
  { printf '%s\n' 'sh /tmp/plant.sh &' 'exit'; sleep 4; } \
    | timeout 15 "$BB" nc 172.16.42.1 23 >/dev/null 2>&1 || true
  # shellcheck disable=SC2016  # expanded by the remote shell
  { printf '%s\n' 'kill -0 "$(cat /tmp/t715-leftover.pid)" && echo ALIVE$((2+3))' 'exit'; sleep 4; } \
    | timeout 15 "$BB" nc 172.16.42.1 23 >"$W/telnet2.out" 2>&1 || true
  check "leftover process planted from the debug shell, survives its hang-up" grep -q ALIVE5 "$W/telnet2.out"

  touch "$W/root-shell/tmp/t715-continue"
  local rc=0
  wait "$BOOT_PID" || rc=$?
  BOOT_PID=""
  check "switch_root reached the image's /sbin/init (exit $rc)" test "$rc" -eq 0
  check "image /sbin/init checks pass" log_has shell "T715TEST RESULT: PASS"
  check "teardown logged" log_has shell "debug link down"
  check "usb0 removed after hand-over" sh -c '! ip link show usb0'
  check "telnet port closed after hand-over" sh -c "! $BB netstat -ltn | grep -q ':23 '"
  grep -E "T715TEST (ok|FAIL)" "$W/shell.log" | sed 's/^/        /'
  [[ $rc -eq 0 ]] || show_log shell
  detach_inner_loops
}

scenario_direct() {
  echo "--- scenario: default boot (no shell, no telnet)"
  prepare_boot direct
  local rc=0
  run_init direct "t715.rootwait=30 t715.modblacklist=pci_exynos,brcmfmac t715.autotest=1 t715.quiet=1" &
  BOOT_PID=$!
  # Probe while the initramfs is up: an unattended boot reaches the
  # hand-over within seconds of "debug link up", which deletes usb0, so
  # the probes run at once, not after a sleep.
  if ! wait_for direct "debug link up" 240; then
    ko "debug link came up"; show_log direct
    kill "$BOOT_PID" 2>/dev/null || true; wait "$BOOT_PID" 2>/dev/null || true; BOOT_PID=""
    return
  fi
  ok "debug link up"
  check "usb0 carries 172.16.42.1/24" sh -c 'ip -4 addr show dev usb0 | grep -q "inet 172.16.42.1/24 "'
  # nc exits 1 at once when nothing listens on 23 (connection refused).
  if timeout 5 "$BB" nc 172.16.42.1 23 </dev/null >/dev/null 2>&1; then
    ko "telnet port closed by default (something answered)"
  else
    ok "telnet port closed by default (nothing answers on 172.16.42.1:23)"
  fi
  wait "$BOOT_PID" || rc=$?
  BOOT_PID=""
  check "switch_root reached the image's /sbin/init (exit $rc)" test "$rc" -eq 0
  check "image /sbin/init checks pass" log_has direct "T715TEST RESULT: PASS"
  check "USERDATA found by GPT name" log_has direct "USERDATA is /dev/${OUTER#/dev/}p3"
  check "BLKROSET logged" log_has direct "set read-only (BLKROSET)"
  check "rootfs.select followed" log_has direct "rootfs.select: booting rootfs-alt.img"
  check "selected image attached" log_has direct "root image media/0/linux/rootfs-alt.img:"
  check "t715.quiet=1 read" log_has direct "t715.quiet: console loglevel 3, VT cleared"
  check "knobs defaults logged" log_has direct "telnet=0 failreboot=1"
  check "telnet shell off by default, log says so" log_has direct "telnet shell off (t715.telnet=1 turns it on)"
  check "no shell on the debug link by default" log_has direct "no shell (t715.telnet=0)"
  check "DHCP server still up by default" log_has direct "DHCP 172.16.42.2-172.16.42.10, no shell"
  [[ $rc -eq 0 ]] || show_log direct
  detach_inner_loops
  ip link del usb0 2>/dev/null || true
}

scenario_missing() {
  echo "--- scenario: missing image, knobs file + cmdline override"
  prepare_boot missing "t715.failwait=2 t715.rootwait=99"
  local rc=0
  run_init missing "t715.rootimg=media/0/linux/nope.img t715.rootwait=30" || rc=$?
  check "rebooted after failwait (exit 99, got $rc)" test "$rc" -eq 99
  check "knobs: file + cmdline merged" log_has missing "rootimg=media/0/linux/nope.img shell=0 failwait=2s rootwait=30s"
  check "t715.rootimg= wins over rootfs.select" sh -c "! grep -q 'rootfs.select: booting' '$W/missing.log'"
  check "reason logged" log_has missing "ERROR: root image 'media/0/linux/nope.img' not found in USERDATA"
  check "missing component logged" log_has missing "first missing path component: media/0/linux/nope.img"
  check "failure said on screen" log_has missing "t715-say: Omarchy could not start: the Linux image file is missing."
  check "rebooting-in-N said on screen" log_has missing "t715-say: rebooting in 2 seconds"
  check "debug shell offered" log_has missing "boot stopped: debug shell on telnet 172.16.42.1 for 2s"
  check "reboot logged" log_has missing "rebooting (reboot -f)"
  check "owner's files not listed" sh -c "! grep -qE 'DCIM|Download|notes.txt' '$W/missing.log'"
  [[ $rc -eq 99 ]] || show_log missing
  ip link del usb0 2>/dev/null || true
}

scenario_failwait_screen() {
  echo "--- scenario: t715.failreboot=0 (failure waits on screen, exit 97)"
  prepare_boot fwait
  local rc=0
  run_init fwait "t715.rootimg=media/0/linux/nope.img t715.rootwait=30 t715.failreboot=0" || rc=$?
  check "exit 97 with t715.failreboot=0 (got $rc)" test "$rc" -eq 97
  check "failure reason said on screen" log_has fwait "t715-say: Omarchy could not start: the Linux image file is missing. Hold Power and Volume down to restart."
  check "waiting line said on screen" log_has fwait "t715-say: waiting: hold Power and Volume down to restart"
  check "no reboot timer" sh -c "! grep -q 'boot stopped: debug shell on telnet' '$W/fwait.log'"
  [[ $rc -eq 97 ]] || show_log fwait
  ip link del usb0 2>/dev/null || true
}

scenario_badpath() {
  echo "--- scenario: invalid t715.rootimg"
  prepare_boot badpath
  local rc=0
  run_init badpath "t715.rootimg=media/../../etc/passwd t715.failwait=1 t715.modblacklist=../x" || rc=$?
  check "rebooted (exit 99, got $rc)" test "$rc" -eq 99
  check "path refused" log_has badpath "ERROR: invalid t715.rootimg"
  check "invalid t715.modblacklist ignored" log_has badpath "ignoring invalid 't715.modblacklist=../x'"
  check "USERDATA never mounted" sh -c "! grep -q 'mounted ro,noload' '$W/badpath.log'"
  [[ $rc -eq 99 ]] || show_log badpath
  ip link del usb0 2>/dev/null || true
}

# with_userdata CMD...: run CMD with USERDATA (the attached disk's p3)
# mounted on $W/ud.
# The read-only boots left BLKROSET on that device: cleared first.
param_dev() { echo "$(node "$OUTER")p4"; }
param_is() { cmp -s "$1" "$(param_dev)"; }   # PARAM holds exactly this image
set_param() {
  local d i
  d=$(param_dev)
  # devtmpfs makes the node a moment after the partition appears: wait for it.
  # Never write where the node is not there yet: dd would make a plain file of
  # that name in devtmpfs, which every later run would then find in place of
  # the partition (seen 2026-11-25, and /init rightly refused it).
  for ((i = 0; i < 20; i++)); do
    [ -b "$d" ] && break
    sleep 0.5
  done
  [ -b "$d" ] || { echo "  FAIL  PARAM is not a block device here ($d)"; NFAIL=$((NFAIL + 1)); return 1; }
  dd if="$1" of="$d" bs=1M conv=fsync status=none
}
set_param_other() {  # PARAM holds neither image: the stock one, one byte changed
  cp /t/param-stock.img "$W/param-other.img"
  printf '\x5a' | dd of="$W/param-other.img" bs=1 seek=4096 conv=notrunc status=none
  set_param "$W/param-other.img"
}
RESCUE_CPIO=/t/initramfs-rescue.cpio.gz   # a scenario may take another rescue's initramfs
prepare_rescue_boot() {  # NAME [KNOBS]: as prepare_boot, with the rescue's initramfs
  local cpio=$CPIO
  CPIO=$RESCUE_CPIO
  prepare_boot "$@"
  CPIO=$cpio
}
# Every scenario: the root image is missing, so a boot that goes on past the
# rescue ends in the failure path after 2 s (exit 99).
PR_FAIL="t715.rootimg=media/0/linux/nope.img t715.rootwait=30 t715.failwait=2"

scenario_param_off() {
  echo "--- scenario: t715.paramrescue=0: PARAM is never touched"
  set_param_other
  prepare_rescue_boot proof "t715.paramrescue=0"
  local rc=0
  run_init proof "$PR_FAIL" || rc=$?
  check "the boot went on to the failure path (exit 99, got $rc)" test "$rc" -eq 99
  check "nothing done" sh -c "! grep -q 't715.paramrescue: ' '$W/proof.log'"
  check "PARAM still holds the other content" param_is "$W/param-other.img"
  [[ $rc -eq 99 ]] || show_log proof
  ip link del usb0 2>/dev/null || true
}

scenario_param_stock() {
  echo "--- scenario: PARAM holds the stock image: left alone"
  set_param /t/param-stock.img
  prepare_rescue_boot prstock
  local rc=0
  run_init prstock "$PR_FAIL" || rc=$?
  check "the boot went on to the failure path (exit 99, got $rc)" test "$rc" -eq 99
  check "the knob is on by default with --paramrescue" grep -qx t715.paramrescue=1 "$W/root-prstock/etc/t715-knobs"
  check "logged: the stock image, nothing done" log_has prstock "bytes of PARAM (/dev/loop0p4) hold the stock image, no loader: nothing to do"
  check "PARAM still holds the stock image" param_is /t/param-stock.img
  [[ $rc -eq 99 ]] || show_log prstock
  ip link del usb0 2>/dev/null || true
}

scenario_param_known() {
  echo "--- scenario: PARAM holds the loader known to work: left alone"
  set_param /t/param-known.img
  prepare_rescue_boot prknown
  local rc=0
  run_init prknown "$PR_FAIL" || rc=$?
  check "the boot went on to the failure path (exit 99, got $rc)" test "$rc" -eq 99
  check "logged: the known loader, nothing done" log_has prknown "bytes of PARAM (/dev/loop0p4) hold the loader known to work, nothing to do"
  check "PARAM still holds the known loader" param_is /t/param-known.img
  [[ $rc -eq 99 ]] || show_log prknown
  ip link del usb0 2>/dev/null || true
}

scenario_param_unknown() {
  echo "--- scenario: PARAM holds neither: the known loader is written back, then the restart (exit 98)"
  set_param_other
  prepare_rescue_boot prunknown
  local rc=0
  run_init prunknown "$PR_FAIL" || rc=$?
  check "exit 98: the restart after the write (got $rc)" test "$rc" -eq 98
  check "said on screen: writing it back" log_has prunknown "t715-say: Rescue: PARAM does not hold the loader known to work. Writing it back."
  check "said on screen: back in PARAM, restarting" log_has prunknown "t715-say: Rescue: the loader known to work is back in PARAM. Restarting."
  check "logged: PARAM holds neither, writing the loader" log_has prunknown "bytes of PARAM (/dev/loop0p4) read back"
  check "logged: neither image, writing the loader" log_has prunknown "neither the loader known to work nor the stock image, writing the loader"
  check "logged: where PARAM differs" log_has prunknown "differ from the loader, the first at byte"
  check "logged: reads back, restarting" log_has prunknown "t715.paramrescue: PARAM reads back as the loader known to work: restarting"
  check "the failure path was not reached" sh -c "! grep -q 'boot stopped' '$W/prunknown.log'"
  check "PARAM now holds the loader known to work" param_is /t/param-known.img
  [[ $rc -eq 98 ]] || show_log prunknown
  ip link del usb0 2>/dev/null || true
}

scenario_param_nofiles() {
  echo "--- scenario: the rescue's files are missing (the plain initramfs, the knob on the command line)"
  set_param_other
  prepare_boot prnofiles
  local rc=0
  run_init prnofiles "$PR_FAIL t715.paramrescue=1" || rc=$?
  check "the boot went on to the failure path (exit 99, got $rc)" test "$rc" -eq 99
  check "logged: a file lacks, nothing done" log_has prnofiles "t715.paramrescue: /lib/t715-paramrescue lacks a file, nothing done"
  check "PARAM still holds the other content" param_is "$W/param-other.img"
  [[ $rc -eq 99 ]] || show_log prnofiles
  ip link del usb0 2>/dev/null || true
}

scenario_param_wrongimage() {
  echo "--- scenario: the image is not the one loader.sha256 announces"
  set_param_other
  prepare_rescue_boot prwrong
  printf '%064d\n' 0 >"$W/root-prwrong/lib/t715-paramrescue/loader.sha256"
  local rc=0
  run_init prwrong "$PR_FAIL" || rc=$?
  check "the boot went on to the failure path (exit 99, got $rc)" test "$rc" -eq 99
  check "logged: not the announced image, nothing done" log_has prwrong "t715.paramrescue: param.img.gz is not the image loader.sha256 announces, nothing done"
  check "PARAM still holds the other content" param_is "$W/param-other.img"
  [[ $rc -eq 99 ]] || show_log prwrong
  ip link del usb0 2>/dev/null || true
}

scenario_param_ro() {
  echo "--- scenario: PARAM cannot be written (the whole disk read-only): the boot goes on to the failure path"
  set_param_other
  prepare_rescue_boot prro
  blockdev --setro "$(node "$OUTER")"
  local rc=0
  run_init prro "$PR_FAIL" || rc=$?
  blockdev --setrw "$(node "$OUTER")"
  check "exit 99: the failure path after the failed write (got $rc)" test "$rc" -eq 99
  check "said on screen: could not be restored" log_has prro "t715-say: Rescue: PARAM could not be restored. Hold Power and Volume down to restart."
  check "logged: the write failed" log_has prro "ERROR: t715.paramrescue: the write to"
  check "PARAM still holds the other content" param_is "$W/param-other.img"
  [[ $rc -eq 99 ]] || show_log prro
  ip link del usb0 2>/dev/null || true
}

# PARAM flagged read-only as the system of every day leaves it: the flag is cleared.
scenario_param_roflag() {
  echo "--- scenario: PARAM flagged read-only: made writable, the known loader is written back (exit 98)"
  set_param_other
  prepare_rescue_boot prflag
  blockdev --setro "$(param_dev)"
  local rc=0
  run_init prflag "$PR_FAIL" || rc=$?
  blockdev --setrw "$(param_dev)"
  check "exit 98: the restart after the write (got $rc)" test "$rc" -eq 98
  check "logged: made writable" log_has prflag "t715.paramrescue: PARAM was read-only, made writable"
  check "PARAM now holds the loader known to work" param_is /t/param-known.img
  [[ $rc -eq 98 ]] || show_log prflag
  ip link del usb0 2>/dev/null || true
}

# --- the loader is only the first EXTENT bytes of PARAM (build-initramfs.sh
# --- --paramrescue-extent): what follows is S-Boot's own data.
EXTENT=4194304
set_param_tail() {  # bytes S-Boot wrote after the loader
  printf 'S-Boot data' | dd of="$(param_dev)" bs=1 seek=5000000 conv=notrunc status=none
}
param_head_is() {  # the loader's part of PARAM is this image's
  cmp -s <(head -c "$EXTENT" "$1") <(head -c "$EXTENT" "$(param_dev)")
}
param_tail_kept() { [ "$(dd if="$(param_dev)" bs=1 skip=5000000 count=11 status=none)" = "S-Boot data" ]; }

scenario_param_extent_loader() {
  echo "--- scenario: extent: the loader, then data S-Boot wrote: nothing done, the data kept"
  set_param /t/param-known.img
  set_param_tail
  RESCUE_CPIO=/t/initramfs-rescue-extent.cpio.gz prepare_rescue_boot extloader
  local rc=0
  run_init extloader "$PR_FAIL" || rc=$?
  check "the boot went on to the failure path (exit 99, got $rc)" test "$rc" -eq 99
  check "logged: the first bytes hold the loader, nothing done" \
    log_has extloader "the first $EXTENT bytes of PARAM (/dev/loop0p4) hold the loader known to work, nothing to do"
  check "S-Boot's data kept" param_tail_kept
  [[ $rc -eq 99 ]] || show_log extloader
  ip link del usb0 2>/dev/null || true
}

scenario_param_extent_stock() {
  echo "--- scenario: extent: the stock image, then data S-Boot wrote: nothing done"
  set_param /t/param-stock.img
  set_param_tail
  RESCUE_CPIO=/t/initramfs-rescue-extent.cpio.gz prepare_rescue_boot extstock
  local rc=0
  run_init extstock "$PR_FAIL" || rc=$?
  check "the boot went on to the failure path (exit 99, got $rc)" test "$rc" -eq 99
  check "logged: the first bytes hold the stock image, nothing done" \
    log_has extstock "the first $EXTENT bytes of PARAM (/dev/loop0p4) hold the stock image, no loader: nothing to do"
  check "S-Boot's data kept" param_tail_kept
  [[ $rc -eq 99 ]] || show_log extstock
  ip link del usb0 2>/dev/null || true
}

scenario_param_extent_unknown() {
  echo "--- scenario: extent: a change inside the loader's part: written over, what follows kept (exit 98)"
  cp /t/param-known.img "$W/param-changed.img"          # the loader with one byte changed
  printf '\x5a' | dd of="$W/param-changed.img" bs=1 seek=4096 conv=notrunc status=none
  set_param "$W/param-changed.img"
  set_param_tail
  RESCUE_CPIO=/t/initramfs-rescue-extent.cpio.gz prepare_rescue_boot extunknown
  local rc=0
  run_init extunknown "$PR_FAIL" || rc=$?
  check "exit 98: the restart after the write (got $rc)" test "$rc" -eq 98
  check "logged: the first bytes hold neither, writing the loader" \
    log_has extunknown "the first $EXTENT bytes of PARAM (/dev/loop0p4) read back"
  check "logged: neither image, writing the loader" \
    log_has extunknown "neither the loader known to work nor the stock image, writing the loader"
  check "logged: the difference is at the byte that was changed" log_has extunknown "the first at byte 4097"
  check "logged: what follows the loader is not compared" log_has extunknown "(what follows the loader is not compared)"
  check "the loader's part now holds the known loader" param_head_is /t/param-known.img
  check "S-Boot's data kept" param_tail_kept
  [[ $rc -eq 98 ]] || show_log extunknown
  ip link del usb0 2>/dev/null || true
}

scenario_param_also() {
  echo "--- scenario: extent: a loader of the list of those left alone: nothing done"
  set_param /t/param-third.img
  set_param_tail
  RESCUE_CPIO=/t/initramfs-rescue-extent.cpio.gz prepare_rescue_boot pralso
  local rc=0
  run_init pralso "$PR_FAIL" || rc=$?
  check "the boot went on to the failure path (exit 99, got $rc)" test "$rc" -eq 99
  check "logged: another loader known to work, nothing done" \
    log_has pralso "the first $EXTENT bytes of PARAM (/dev/loop0p4) hold another loader known to work, nothing to do"
  check "the loader left as it was" param_head_is /t/param-third.img
  check "S-Boot's data kept" param_tail_kept
  [[ $rc -eq 99 ]] || show_log pralso
  ip link del usb0 2>/dev/null || true
}

scenario_param_extent_bad() {
  echo "--- scenario: extent: the loader's length is not a number: nothing done"
  set_param_other
  RESCUE_CPIO=/t/initramfs-rescue-extent.cpio.gz prepare_rescue_boot extbad
  printf 'abc\n' >"$W/root-extbad/lib/t715-paramrescue/extent"
  local rc=0
  run_init extbad "$PR_FAIL" || rc=$?
  check "the boot went on to the failure path (exit 99, got $rc)" test "$rc" -eq 99
  check "logged: the length is not a number, nothing done" \
    log_has extbad "t715.paramrescue: the loader's length is not a number ('abc'), nothing done"
  check "PARAM still holds the other content" param_is "$W/param-other.img"
  [[ $rc -eq 99 ]] || show_log extbad
  ip link del usb0 2>/dev/null || true
}

# Another disk, with no partition named PARAM at all.
scenario_param_nopart() {
  echo "--- scenario: no partition named PARAM: nothing done"
  truncate -s 80M "$W/disk-noparam.img"
  sfdisk -q "$W/disk-noparam.img" <<'PARTS'
label: gpt
start=2048, size=2048, name=EFS
start=4096, size=8192, name=SYSTEM
start=12288, size=131072, name=USERDATA
PARTS
  dd if="$W/userdata.img" of="$W/disk-noparam.img" bs=512 seek=12288 conv=notrunc status=none
  attach_disk "$W/disk-noparam.img" || { ko "the disk without PARAM could not be attached"; return 1; }
  prepare_rescue_boot prnopart
  local rc=0
  run_init prnopart "$PR_FAIL" || rc=$?
  check "the boot went on to the failure path (exit 99, got $rc)" test "$rc" -eq 99
  check "logged: no single partition named PARAM, nothing done" log_has prnopart "t715.paramrescue: no single partition named PARAM (none), nothing done"
  [[ $rc -eq 99 ]] || show_log prnopart
  ip link del usb0 2>/dev/null || true
  detach_disk
}

# ===========================================================================
# the installer of the 64-bit system (t715.golden): its fixtures, helpers
# and scenarios.  Everything here is synthetic; the golden directory and the
# PARAM images were generated on the host by python3 (boot/golden/check-param.py's
# forge gives loader.sha256 and param-loader.img), and are mounted read-only
# at $GF.
# ===========================================================================
GF=/t/golden-fixtures
GOLDEN_CPIO=/t/initramfs-golden.cpio.gz
GEXTENT=7340032                    # the fixtures' extent (the loader's part of PARAM)
GSLOT_SECTORS=140                  # the fixtures' kernel.slot: 71680 bytes = 140 sectors
GOLD_CMD="androidboot.bootloader=T715XXU2CRH1 t715.golden=1 t715.rootwait=30 t715.failwait=2"

prepare_golden_boot() {  # NAME [KNOBS]: as prepare_boot, with the golden initramfs
  local cpio=$CPIO
  CPIO=$GOLDEN_CPIO
  prepare_boot "$@"
  CPIO=$cpio
}

# The golden disk's partitions, by number: PARAM SYSTEM CACHE USERDATA.
g_param_dev()  { echo "$(node "$OUTER")p1"; }
g_system_dev() { echo "$(node "$OUTER")p2"; }
g_cache_dev()  { echo "$(node "$OUTER")p3"; }
g_ud_dev()     { echo "$(node "$OUTER")p4"; }

# gpart_sum START COUNT: one partition's content checksum, in sectors.
gpart_sum() { dd if="$W/disk-golden.img" bs=512 skip="$1" count="$2" status=none | sha256sum | cut -d' ' -f1; }
gdisk_sums() {
  sync
  echo "param=$(gpart_sum 2048 16384)"
  echo "system=$(gpart_sum 18432 16384)"
  echo "cache=$(gpart_sum 34816 409600)"
  echo "userdata=$(gpart_sum 444416 131072)"
}

gwait_node() {  # DEV: wait for the devtmpfs node (never write where it is not there yet)
  local d=$1 i
  for ((i = 0; i < 20; i++)); do
    [ -b "$d" ] && return 0
    sleep 0.5
  done
  return 1
}
gset_param() {  # IMG: PARAM holds this 8 MiB image
  local d
  d=$(g_param_dev)
  gwait_node "$d" || { ko "PARAM is not a block device here ($d)"; return 1; }
  blockdev --setrw "$d" 2>/dev/null || true
  dd if="$1" of="$d" bs=1M conv=notrunc,fsync status=none
}
# greset_all [USERDATA_IMG]: the golden disk's factory state (stock PARAM,
# Android's CACHE, USERDATA holding the given image, by default the factory
# one: the image and its sidecar in media/0/linux, no root).  The variant
# images are built offline, so no read-write mount is needed to set up.
greset_all() {
  local d
  for d in p1 p2 p3 p4; do blockdev --setrw "$(node "$OUTER")$d" 2>/dev/null || true; done
  gset_param "$GF/param-stock.img" || return 1
  dd if="$W/golden-system.img" of="$(g_system_dev)" bs=1M conv=notrunc status=none
  dd if="$W/golden-cache.img" of="$(g_cache_dev)" bs=1M conv=notrunc status=none
  dd if="${1:-$W/golden-userdata-factory.img}" of="$(g_ud_dev)" bs=1M conv=notrunc status=none
}
# gwith_userdata CMD...: run CMD with the golden disk's USERDATA on $W/gud.
gwith_userdata() {
  mkdir -p "$W/gud"
  blockdev --setrw "$(g_ud_dev)" || return 1
  mount "$(g_ud_dev)" "$W/gud" || return 1
  local rc=0
  "$@" || rc=$?
  umount "$W/gud"
  return "$rc"
}
# gplant_root KIND [SAVED_PARAM]: hand-plant an installed root on USERDATA, as
# scenario 1's seed leaves it (the marker, the kernel's slot); with KIND=golden,
# also the .t715-golden marker and the saved stock PARAM (the rescue's),
# SAVED_PARAM by default $GF/param-stock.img.
gplant_root() {
  # shellcheck disable=SC2016  # expanded by the sh -c script
  gwith_userdata sh -c '
    set -e
    mkdir -p "$1/omarchy-arm64/usr/lib/t715-golden" "$1/omarchy-arm64/var/lib/t715"
    printf "persistent root omarchy-arm64, installed from omarchy-arm64.img\ninstaller 9.9.9-test, kernel t715-test\n" >"$1/omarchy-arm64/.t715-persist"
    cp "$2/kernel.slot" "$1/omarchy-arm64/usr/lib/t715-golden/kernel.slot"
    if [ "$3" = golden ]; then
      echo "Omarchy for the Galaxy Tab S2, 64 bits: installer 9.9.9-test" >"$1/omarchy-arm64/.t715-golden"
      cp "${4:-$2/param-stock.img}" "$1/omarchy-arm64/var/lib/t715/PARAM-stock.img"
      chmod 0600 "$1/omarchy-arm64/var/lib/t715/PARAM-stock.img"
    fi
  ' sh "$W/gud" "$GF" "$1" "${2:-}"
}
# gslot_gen DEV SECTOR: the generation of the slot header there, read by the
# init's own slot_gen (busybox sh, the same bytes the boots run), empty when
# that header is not one of ours.
gslot_gen() { "$W/root-gfns/bin/busybox" sh "$W/gslot.sh" "$1" "$2"; }
# gcache_blocks: "BLOCKS LOG_BLOCK_SIZE" of CACHE's file system superblock.
gcache_blocks() {
  dd if="$(g_cache_dev)" of="$W/cache-sb" bs=1024 skip=1 count=1 status=none
  echo "$(od -An -tu4 -j 4 -N 4 "$W/cache-sb" | tr -d ' ') $(od -An -tu4 -j 24 -N 4 "$W/cache-sb" | tr -d ' ')"
}
# gparam_loader_sum: the sha256 the fixtures' loader.sha256 names on line 1
# (the loader forged from param-stock.img).
gparam_loader_sum() { gparam_line loader.sha256 1; }
# gparam_stock_sum: the sha256 the fixtures' stock.sha256 names on line 1
# (param-stock.img).
gparam_stock_sum() { gparam_line stock.sha256 1; }
# gparam_line FILE N: the sha256 on line N of one of the fixtures' two sha256
# files (one line per stock PARAM, paired by line number: the loader of line
# N is forged from the stock PARAM of line N).
gparam_line() { sed -n "${2}p" "$GF/golden/$1" | cut -d' ' -f1; }
# gparam_head_is IMG: PARAM's first GEXTENT bytes are IMG's.
gparam_head_is() { [ "$(head -c "$GEXTENT" "$(g_param_dev)" | sha256sum | cut -d' ' -f1)" = "$(head -c "$GEXTENT" "$1" | sha256sum | cut -d' ' -f1)" ]; }
# garchive_end: where the stock archive ends (the fixtures' stock.end).
garchive_end() { cat "$GF/stock.end"; }
# gtail_len: the length of the non-zero run after the stock archive's end in
# param-golden-tail.img (the fixtures' tail-run.bin).
gtail_len() { stat -c %s "$GF/tail-run.bin"; }
# gdisk_sums_noud: PARAM, SYSTEM and CACHE's content checksums only (the
# scenarios whose USERDATA is expected to change).
gdisk_sums_noud() {
  sync
  echo "param=$(gpart_sum 2048 16384)"
  echo "system=$(gpart_sum 18432 16384)"
  echo "cache=$(gpart_sum 34816 409600)"
}
# gplant_reinstall: the request file linux/reinstall on the golden disk's
# USERDATA.
gplant_reinstall() { gwith_userdata touch "$W/gud/media/0/linux/reinstall"; }
# gfill_userdata: eat the golden disk's USERDATA's free space until under
# 1 MiB is left (the reinstall's space refusal, whatever the image's use).
gfill_userdata() { gwith_userdata sh "$W/gfill.sh" "$W/gud"; }
# gmarker_ok ROOT: the planted root's marker files are as gplant_root left
# them (used for the roots the reinstall keeps or puts back).
gmarker_ok() {  # ROOT (a path inside $W/gud)
  # shellcheck disable=SC2016  # expanded by the sh -c script
  gwith_userdata sh -c '
    [ -f "$1/.t715-golden" ] &&
    [ "$(cat "$1/.t715-golden")" = "Omarchy for the Galaxy Tab S2, 64 bits: installer 9.9.9-test" ] &&
    [ -f "$1/.t715-persist" ]
  ' sh "$W/gud/$1"
}

make_golden_fixtures() {
  # SYSTEM: the Wi-Fi NVRAM (a macaddr line and another one) and the
  # Bluetooth patch RAM.
  mkdir -p "$W/gsystem/etc/wifi" "$W/gsystem/vendor/firmware"
  printf 'macaddr=00:90:4c:00:00:01\nphycal=0\n' >"$W/gsystem/etc/wifi/nvram_net.txt"
  printf 'BCM4358A3 synthetic patch RAM, from no tablet\n' >"$W/gsystem/vendor/firmware/bcm4358A3_V0086.0144.hcd"
  mkfs.ext4 -q -F -d "$W/gsystem" "$W/golden-system.img" 8M

  # CACHE as Android leaves it: one file system spanning the 200 MiB partition.
  truncate -s 200M "$W/golden-cache.img"
  mkfs.ext4 -q -F -b 4096 -L CACHE "$W/golden-cache.img"
  # CACHE already shrunk, with slot B of generation 5 (scenario 9): a 64 MiB
  # file system in front of the slots, written into the 200 MiB region.
  truncate -s 64M "$W/golden-cache64.img"
  mkfs.ext4 -q -F -b 4096 -L CACHE "$W/golden-cache64.img"
  truncate -s 200M "$W/golden-cache9.img"
  dd if="$W/golden-cache64.img" of="$W/golden-cache9.img" bs=1M conv=notrunc status=none
  dd if="$GF/kernel.slot.gen5" of="$W/golden-cache9.img" bs=512 seek=262144 conv=notrunc status=none

  # The root image's tree.  The checks of scenario 1 read all of it back from
  # USERDATA after the seed.
  local t="$W/gtree" long
  mkdir -p "$t/usr/bin" "$t/usr/lib/systemd" "$t/usr/lib/firmware/brcm" \
    "$t/usr/lib/t715-golden" "$t/mnt" "$t/etc" "$t/home/alarm" "$t/one" "$t/two"
  long="$t/usr/share/doc/$(printf 'a%.0s' $(seq 80))"   # a path over 100 characters
  mkdir -p "$long"
  # an ELF whose e_machine (byte 18) is 0xb7: AArch64
  { printf '\177ELF\002\001\001\000'; head -c 8 /dev/zero; printf '\002\000\267'; head -c 45 /dev/zero; } \
    >"$t/usr/lib/systemd/systemd"
  echo '#!/bin/sh' >"$t/usr/bin/setuid-helper"
  chmod 4755 "$t/usr/bin/setuid-helper"                 # setuid root
  ln -s ../lib/systemd/systemd "$t/usr/bin/init"
  echo 'hard-linked data' >"$t/one/data.bin"
  ln "$t/one/data.bin" "$t/two/data.bin"                 # one file, two top-level directories
  echo doc >"$long/file.txt"
  chown -R 1000:1000 "$t/home/alarm"
  cp "$GF/kernel.slot" "$t/usr/lib/t715-golden/kernel.slot"
  mkfs.ext4 -q -F -d "$t" "$W/omarchy-arm64.img" 8M
  # the same tree with a 32-bit systemd (scenario 8: refused)
  cp -a "$t" "$W/gtree-bad"
  printf '\050' | dd of="$W/gtree-bad/usr/lib/systemd/systemd" bs=1 seek=18 conv=notrunc status=none
  mkfs.ext4 -q -F -d "$W/gtree-bad" "$W/omarchy-arm64-bad.img" 8M

  # USERDATA: the image and its sha256sum sidecar in media/0/linux.
  mkdir -p "$W/gudata/media/0/linux"
  cp "$W/omarchy-arm64.img" "$W/gudata/media/0/linux/omarchy-arm64.img"
  (cd "$W/gudata/media/0/linux" && sha256sum omarchy-arm64.img >omarchy-arm64.img.sha256)
  mkfs.ext4 -q -F -d "$W/gudata" "$W/golden-userdata.img" 64M
  cp "$W/golden-userdata.img" "$W/golden-userdata-factory.img"
  # the variants the refusal scenarios need, built offline (no read-write
  # mount of USERDATA to set up): no sidecar, a wrong-hash sidecar, and the
  # not-aarch64 image with its own sidecar
  rm -rf "$W/gudata-noside" && cp -a "$W/gudata" "$W/gudata-noside"
  rm -f "$W/gudata-noside/media/0/linux/omarchy-arm64.img.sha256"
  mkfs.ext4 -q -F -d "$W/gudata-noside" "$W/golden-userdata-noside.img" 64M
  rm -rf "$W/gudata-badside" && cp -a "$W/gudata" "$W/gudata-badside"
  printf '%064d  omarchy-arm64.img\n' 0 >"$W/gudata-badside/media/0/linux/omarchy-arm64.img.sha256"
  mkfs.ext4 -q -F -d "$W/gudata-badside" "$W/golden-userdata-badside.img" 64M
  rm -rf "$W/gudata-badarch" && cp -a "$W/gudata" "$W/gudata-badarch"
  cp "$W/omarchy-arm64-bad.img" "$W/gudata-badarch/media/0/linux/omarchy-arm64.img"
  (cd "$W/gudata-badarch/media/0/linux" && sha256sum omarchy-arm64.img >omarchy-arm64.img.sha256)
  mkfs.ext4 -q -F -d "$W/gudata-badarch" "$W/golden-userdata-badarch.img" 64M
  # the same tree with a top-level name holding a blank (the rollback
  # scenario): the seed's archive list splits on blanks, so the copy fails
  cp -a "$t" "$W/gtree-blank"
  echo 'a name the seed cannot copy' >"$W/gtree-blank/a b"
  mkfs.ext4 -q -F -d "$W/gtree-blank" "$W/omarchy-arm64-blank.img" 8M
  rm -rf "$W/gudata-blank" && cp -a "$W/gudata" "$W/gudata-blank"
  cp "$W/omarchy-arm64-blank.img" "$W/gudata-blank/media/0/linux/omarchy-arm64.img"
  (cd "$W/gudata-blank/media/0/linux" && sha256sum omarchy-arm64.img >omarchy-arm64.img.sha256)
  mkfs.ext4 -q -F -d "$W/gudata-blank" "$W/golden-userdata-blank.img" 64M

  # PARAM holding neither the stock image nor the loader (scenarios 4 and 5):
  # the stock image with one byte changed inside the loader's part.
  cp "$GF/param-stock.img" "$W/param-golden-changed.img"
  printf '\x5a' | dd of="$W/param-golden-changed.img" bs=1 seek=4096 conv=notrunc status=none

  # The golden disk (all the partition starts are 1 MiB-aligned).
  truncate -s 295M "$W/disk-golden.img"
  sfdisk -q "$W/disk-golden.img" <<'EOF'
label: gpt
start=2048, size=16384, name=PARAM
start=18432, size=16384, name=SYSTEM
start=34816, size=409600, name=CACHE
start=444416, size=131072, name=USERDATA
EOF
  dd if="$GF/param-stock.img" of="$W/disk-golden.img" bs=1M seek=1 conv=notrunc status=none
  dd if="$W/golden-system.img" of="$W/disk-golden.img" bs=1M seek=9 conv=notrunc status=none
  dd if="$W/golden-cache.img" of="$W/disk-golden.img" bs=1M seek=17 conv=notrunc status=none
  dd if="$W/golden-userdata.img" of="$W/disk-golden.img" bs=1M seek=217 conv=notrunc status=none

  # The init's golden functions (fnv1a64, slot_gen, golden_forge), taken from
  # the same bytes the boot scenarios run, sourced without the last line
  # (main "$@"): $W/gslot.sh reads a slot's generation, $W/gfnv.sh forges.
  rm -rf "$W/root-gfns"
  mkdir -p "$W/root-gfns"
  (cd "$W/root-gfns" && gzip -dc "$GOLDEN_CPIO" | cpio -idm --quiet --no-absolute-filenames)
  sed -n '/^GOLDEN_DIR=/,$p' "$W/root-gfns/init" | sed '$d' >"$W/golden-fns.sh"
  cat >"$W/gslot.sh" <<'EOF'
. /work/golden-fns.sh
RUNDIR=/work/golden-run
mkdir -p "$RUNDIR"
slot_gen "$1" "$2"
EOF
  # what scenario 1 expects the installed root's tree to look like
  cat >"$W/gcheck-tree.sh" <<'EOF'
set -e
r=$1/omarchy-arm64
[ -f "$r/.t715-persist" ] && [ -f "$r/.t715-golden" ]
[ ! -e "$1/.omarchy-arm64.t715-seed" ]
grep -qx 'persistent root omarchy-arm64, installed from omarchy-arm64.img' "$r/.t715-persist"
[ "$(stat -c %u:%g "$r/home/alarm")" = 1000:1000 ]
[ "$(stat -c %a "$r/usr/bin/setuid-helper")" = 4755 ]
[ "$(readlink "$r/usr/bin/init")" = ../lib/systemd/systemd ]
[ "$(stat -c %i "$r/one/data.bin")" = "$(stat -c %i "$r/two/data.bin")" ]
[ "$(stat -c %h "$r/one/data.bin")" = 2 ]
[ -f "$r/usr/share/doc/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/file.txt" ]
grep -qx 'macaddr=<REDACTED>' "$r/usr/lib/firmware/brcm/samsung-gts28/nvram_net.txt"
grep -qx 'phycal=0' "$r/usr/lib/firmware/brcm/samsung-gts28/nvram_net.txt"
cmp -s "$r/usr/lib/firmware/brcm/BCM4358A3.hcd" /work/gsystem/vendor/firmware/bcm4358A3_V0086.0144.hcd
EOF
  # what the space-refusal scenario runs inside gwith_userdata: eat
  # USERDATA's free blocks until under 1 MiB is left (below the image's
  # use + the test's 1 MiB margin, whatever that use is)
  cat >"$W/gfill.sh" <<'EOF'
set -e
free=$(df -Pk "$1" | awk 'NR == 2 {print $4}')
want=$((free - 512))
if [ "$want" -gt 0 ]; then
  dd if=/dev/zero of="$1/t715-fill" bs=1024 count="$want" status=none
  sync
fi
[ "$(df -Pk "$1" | awk 'NR == 2 {print $4}')" -lt 1024 ]
EOF
}

# grun NAME [KNOB...]: prepare the golden initramfs as root-NAME and run it
# with GOLD_CMD plus the extra knobs; the exit status lands in GRC.
grun() {
  local name=$1
  shift
  prepare_golden_boot "$name"
  GRC=0
  run_init "$name" "$GOLD_CMD${1:+ $*}" || GRC=$?
}

# scenario 11 first: it needs no disk, only the golden initramfs' functions.
# gcheck_nothing_written BEFORE AFTER: the refusal wrote nothing.
gcheck_nothing_written() {
  if [ "$1" = "$2" ]; then
    ok "nothing written (PARAM, SYSTEM, CACHE, USERDATA byte-identical)"
  else
    ko "nothing written (PARAM, SYSTEM, CACHE, USERDATA byte-identical)"
    echo "        before: $1"
    echo "        after:  $2"
  fi
}

scenario_golden_forge_python() {
  echo "--- scenario: golden, the forge and fnv1a64 against Python (check-param.py's forge)"
  cat >"$W/gfnv.sh" <<'EOF'
log() { :; }; err() { echo "err: $*" >&2; return 0; }; warn() { :; }
. /work/golden-fns.sh
RUNDIR=/work/golden-run; mkdir -p "$RUNDIR"
GOLDEN_DIR=/work/root-gfns/lib/t715-golden
EXTENT=$(golden_val extent)
golden_forge /t/golden-fixtures/param-stock.img /work/forge-out.img || { echo "FORGE-FAILED"; exit 1; }
head -c "$EXTENT" /t/golden-fixtures/param-loader.img >/work/loader-head.img
echo "forge-sha $(sha256sum /work/forge-out.img | cut -d' ' -f1)"
echo "loader-sha $(golden_val loader.sha256)"
echo "python-sha $(sha256sum /work/loader-head.img | cut -d' ' -f1)"
cmp -s /work/forge-out.img /work/loader-head.img && echo "forge-bytes same" || echo "forge-bytes DIFFER"
while read -r n skip count low high; do
  got=$(fnv1a64 "/t/golden-fixtures/$n" "$skip" "$count")
  if [ "$got" = "$low $high" ]; then echo "fnv-ok $n $skip $count"; else echo "fnv-BAD $n $skip $count got=$got want=$low $high"; fi
done </t/golden-fixtures/fnv-expected.txt
EOF
  "$W/root-gfns/bin/busybox" sh "$W/gfnv.sh" >"$W/gfnv.out" 2>&1
  sed 's/^/        | /' "$W/gfnv.out"
  local want
  want=$(gparam_loader_sum)
  check "golden_forge's output hashes to loader.sha256" grep -qx "forge-sha $want" "$W/gfnv.out"
  check "Python's forge (param-loader.img) is loader.sha256 too" grep -qx "python-sha $want" "$W/gfnv.out"
  check "golden_forge's bytes are Python's forge's bytes" grep -qx "forge-bytes same" "$W/gfnv.out"
  check "fnv1a64 matches Python on every fixed input" \
    sh -c "[ \"\$(grep -c '^fnv-ok' '$W/gfnv.out')\" -eq \"\$(wc -l <'$GF/fnv-expected.txt')\" ] && ! grep -q 'fnv-BAD' '$W/gfnv.out'"
}

# scenario_golden_members_python: the init's golden_members and golden_archive
# against Python (check-param.py's members): the lines but "end" must be
# golden/stock.members byte for byte, the end line Python's members() gives,
# and on the tail PARAM GA_SUM must be stock.sha256 with GA_TAIL the run's
# length.  Needs no disk, only the golden initramfs' functions.
scenario_golden_members_python() {
  echo "--- scenario: golden, golden_members and golden_archive against Python (check-param.py's members)"
  cat >"$W/gmem.sh" <<'EOF'
log() { :; }; err() { echo "err: $*" >&2; return 0; }; warn() { :; }
. /work/golden-fns.sh
RUNDIR=/work/golden-run; mkdir -p "$RUNDIR"
GOLDEN_DIR=/work/root-gfns/lib/t715-golden
EXTENT=$(golden_val extent)
golden_members /t/golden-fixtures/param-stock.img >/work/gmembers-stock.out
golden_archive /t/golden-fixtures/param-golden-tail.img
echo "ga-sum $GA_SUM"
echo "ga-end $GA_END"
echo "ga-tail $GA_TAIL"
echo "stock-sum $(golden_val stock.sha256)"
EOF
  "$W/root-gfns/bin/busybox" sh "$W/gmem.sh" >"$W/gmem.out" 2>&1
  sed 's/^/        | /' "$W/gmem.out"
  local gend gtail
  gend=$(garchive_end)
  gtail=$(gtail_len)
  check "golden_members' lines but end are stock.members, byte for byte" \
    cmp -s <(grep -v '^end ' "$W/gmembers-stock.out") "$GF/golden/stock.members"
  check "golden_members' end line is Python members()'s end ($gend)" \
    grep -qx "end $gend" "$W/gmembers-stock.out"
  check "golden_archive on the tail PARAM: GA_SUM is stock.sha256" \
    grep -qx "ga-sum $(gparam_stock_sum)" "$W/gmem.out"
  check "golden_archive on the tail PARAM: GA_END is the archive's end ($gend)" \
    grep -qx "ga-end $gend" "$W/gmem.out"
  check "golden_archive on the tail PARAM: GA_TAIL is the run's length ($gtail)" \
    grep -qx "ga-tail $gtail" "$W/gmem.out"
}

scenario_golden_fresh() {
  echo "--- scenario: golden, fresh install (stock PARAM, image + sidecar, Android's CACHE)"
  greset_all
  grun gfresh
  local rc=$GRC
  check "restart after the install (exit 99, got $rc)" test "$rc" -eq 99
  check "logged: the stock image, installing" log_has gfresh "golden: PARAM is the stock image: installing"
  check "the image found in the internal storage" log_has gfresh "golden: the image is in the internal storage (media/0/linux/omarchy-arm64.img)"
  check "image checksum verified" log_has gfresh "image checksum verified (omarchy-arm64.img.sha256)"
  check "the image's tree copied" sh -c "grep -q 'entries copied in' '$W/gfresh.log'"
  check "Wi-Fi NVRAM copied from SYSTEM" log_has gfresh "device files: Wi-Fi NVRAM copied from SYSTEM"
  check "Bluetooth patch RAM copied from SYSTEM" log_has gfresh "device files: Bluetooth patch RAM copied from SYSTEM"
  check "CACHE's file system replaced by a 64 MiB one" log_has gfresh "golden: CACHE's file system covers the slots: a new one of 64 MiB"
  check "logged: slot A, generation 1" log_has gfresh "golden: the kernel's slot, generation 1, to sector 131072 of CACHE"
  check "the slot reads back as written" log_has gfresh "golden: the kernel's slot reads back as written"
  check "the stock PARAM saved" log_has gfresh "golden: the stock PARAM saved in media/0/linux/PARAM-stock-backup.img and the root's /var/lib/t715/PARAM-stock.img"
  check "the loader forged as expected" log_has gfresh "golden: the loader forged from the stock PARAM is the expected one"
  check "PARAM holds the loader" log_has gfresh "golden: PARAM holds the loader (sha256"
  check "said on screen: installing" log_has gfresh "t715-say: Installing Omarchy, this takes about ten minutes"
  check "said on screen: writing the loader" log_has gfresh "t715-say: Writing the loader..."
  check "said on screen: installed, restarting" log_has gfresh "t715-say: Omarchy is installed. Restarting into it..."
  check "reboot logged" log_has gfresh "rebooting (reboot -f)"
  # the disk state
  check "PARAM's first $GEXTENT bytes hash to loader.sha256" \
    test "$(gparam_loader_sum)" = "$(head -c "$GEXTENT" "$(g_param_dev)" | sha256sum | cut -d' ' -f1)"
  check "PARAM's bytes after the loader's part are unchanged" \
    cmp -s <(dd if="$(g_param_dev)" bs=512 skip=14336 count=2048 status=none) <(tail -c +7340033 "$GF/param-stock.img")
  check "CACHE's file system is now 16384 blocks of 4096 bytes" test "$(gcache_blocks)" = "16384 2"
  check "slot A (sector 131072) is a valid header of generation 1" test "$(gslot_gen "$(g_cache_dev)" 131072)" = 1
  check "slot A's bytes after the header are the image's kernel.slot's" \
    cmp -s <(dd if="$(g_cache_dev)" bs=512 skip=131072 count=$GSLOT_SECTORS status=none | tail -c +4097) <(tail -c +4097 "$GF/kernel.slot")
  check "slot B (sector 262144) is not a valid header" test -z "$(gslot_gen "$(g_cache_dev)" 262144)"
  check "the root's tree: owners, setuid, symlink, hard links, long path, NVRAM, markers" \
    gwith_userdata sh "$W/gcheck-tree.sh" "$W/gud"
  # shellcheck disable=SC2016  # expanded by the sh -c script
  check "PARAM-stock-backup.img is the whole stock PARAM, with its sidecar" gwith_userdata sh -c '
    cmp -s "$1/media/0/linux/PARAM-stock-backup.img" "$2/param-stock.img"
    [ "$(cat "$1/media/0/linux/PARAM-stock-backup.img.sha256")" = "$(sha256sum "$2/param-stock.img" | cut -d" " -f1)  PARAM-stock-backup.img" ]
  ' sh "$W/gud" "$GF"
  # shellcheck disable=SC2016  # expanded by the sh -c script
  check "the root's saved PARAM is the stock image, mode 0600" gwith_userdata sh -c '
    cmp -s "$1/omarchy-arm64/var/lib/t715/PARAM-stock.img" "$2/param-stock.img"
    [ "$(stat -c %a "$1/omarchy-arm64/var/lib/t715/PARAM-stock.img")" = 600 ]
  ' sh "$W/gud" "$GF"
  check "the install log is next to the image" gwith_userdata test -s "$W/gud/media/0/linux/omarchy-arm64-install.log"
  [[ $rc -eq 99 ]] || show_log gfresh
  detach_inner_loops
  ip link del usb0 2>/dev/null || true
}

scenario_golden_resume() {
  echo "--- scenario: golden, resume (the root is there already, PARAM stock)"
  greset_all
  gplant_root persist
  grun gresume
  local rc=$GRC
  check "restart after the install (exit 99, got $rc)" test "$rc" -eq 99
  check "logged: the root is there already" log_has gresume "golden: USERDATA/omarchy-arm64 is there already (an earlier start copied it)"
  check "the copy was skipped" sh -c "! grep -q 'entries copied in' '$W/gresume.log'"
  check "logged: slot A, generation 1" log_has gresume "golden: the kernel's slot, generation 1, to sector 131072 of CACHE"
  check "PARAM holds the loader" log_has gresume "golden: PARAM holds the loader (sha256"
  check "said on screen: installed, restarting" log_has gresume "t715-say: Omarchy is installed. Restarting into it..."
  check "slot A is a valid header of generation 1" test "$(gslot_gen "$(g_cache_dev)" 131072)" = 1
  check "CACHE's file system is now 16384 blocks of 4096 bytes" test "$(gcache_blocks)" = "16384 2"
  check "PARAM's first $GEXTENT bytes hash to loader.sha256" \
    test "$(gparam_loader_sum)" = "$(head -c "$GEXTENT" "$(g_param_dev)" | sha256sum | cut -d' ' -f1)"
  check "the .t715-golden marker was written" gwith_userdata test -f "$W/gud/omarchy-arm64/.t715-golden"
  [[ $rc -eq 99 ]] || show_log gresume
  detach_inner_loops
  ip link del usb0 2>/dev/null || true
}

scenario_golden_handback() {
  echo "--- scenario: golden, the loader handed the start back (loader in PARAM, root installed)"
  greset_all
  gplant_root golden
  gset_param "$GF/param-loader.img"
  local before after
  before=$(gdisk_sums)
  grun ghand
  local rc=$GRC
  after=$(gdisk_sums)
  check "restart after t715.failwait (exit 99, got $rc)" test "$rc" -eq 99
  check "logged: the loader handed this start back" log_has ghand "the loader is in PARAM and USERDATA/omarchy-arm64 is installed: the loader handed this start back"
  check "no reinstall asked (no request file)" sh -c "! grep -q 'asks for a reinstall' '$W/ghand.log'"
  check "said on screen: did not finish starting last time" log_has ghand "t715-say: Omarchy did not finish starting last time. The tablet restarts and tries again."
  check "rebooting-in-N said on screen" log_has ghand "t715-say: rebooting in 2 seconds"
  gcheck_nothing_written "$before" "$after"
  [[ $rc -eq 99 ]] || show_log ghand
  detach_inner_loops
  ip link del usb0 2>/dev/null || true
}

scenario_golden_rescue() {
  echo "--- scenario: golden, rescue (PARAM holds neither image, the root has the saved stock PARAM)"
  greset_all
  gplant_root golden
  gset_param "$W/param-golden-changed.img"
  grun gresc
  local rc=$GRC
  check "restart after the loader is back (exit 99, got $rc)" test "$rc" -eq 99
  check "logged: neither the stock image nor the loader" log_has gresc "neither the stock image nor the loader"
  check "said on screen: writing the loader back" log_has gresc "t715-say: Rescue: PARAM does not hold Omarchy's loader. Writing it back."
  check "the loader was forged from the saved stock PARAM" log_has gresc "golden: the loader forged from the stock PARAM is the expected one"
  check "said on screen: back in PARAM, restarting" log_has gresc "t715-say: Rescue: the loader is back in PARAM. Restarting."
  check "PARAM's first $GEXTENT bytes are the loader now" \
    test "$(gparam_loader_sum)" = "$(head -c "$GEXTENT" "$(g_param_dev)" | sha256sum | cut -d' ' -f1)"
  check "PARAM's bytes after the loader's part are unchanged" \
    cmp -s <(dd if="$(g_param_dev)" bs=512 skip=14336 count=2048 status=none) <(tail -c +7340033 "$W/param-golden-changed.img")
  [[ $rc -eq 99 ]] || show_log gresc
  detach_inner_loops
  ip link del usb0 2>/dev/null || true
}

scenario_golden_unknown_param() {
  echo "--- scenario: golden, PARAM holds neither and nothing is installed: the report, refused, exit 97"
  greset_all
  gset_param "$W/param-golden-changed.img"
  local before after
  before=$(gdisk_sums)
  grun gunknown
  local rc=$GRC
  after=$(gdisk_sums)
  # byte 4096 is inside download.jpg's data: its size comes from the
  # fixtures' stock.members, not from this script's arithmetic
  local dsize
  dsize=$(awk '$3 == "download.jpg" { print $2 }' "$GF/golden/stock.members")
  check "waited on screen (exit 97, got $rc)" test "$rc" -eq 97
  check "logged: neither the stock image nor the loader" log_has gunknown "neither the stock image nor the loader"
  check "said on screen: the changed member named" \
    log_has gunknown "t715-say: PARAM: download.jpg is not the stock one ($dsize bytes, stock: $dsize)."
  check "said on screen: the refusal text" \
    log_has gunknown "t715-say: PARAM does not hold the stock image of T715XXU2CRH1 that this installer knows. Nothing was written. Flash the stock T715XXU2CRH1 firmware with Odin (BL included), then this installer again. If it says this again, post a photo of this screen in the XDA thread."
  check "waiting line said on screen" log_has gunknown "t715-say: waiting: hold Power and Volume down to restart"
  gcheck_nothing_written "$before" "$after"
  [[ $rc -eq 97 ]] || show_log gunknown
  detach_inner_loops
  ip link del usb0 2>/dev/null || true
}

# scenario_golden_param_tail: PARAM's first EXTENT bytes are not the stock
# image, but its archive is the stock one once the bytes after its end are
# taken as zeros (an earlier write left a run of non-zero bytes there): the
# installer installs exactly as for a stock PARAM, and the loader it writes
# has zeros in place of those bytes.
scenario_golden_param_tail() {
  echo "--- scenario: golden, PARAM holds the stock archive with leftover bytes after its end: installed, exit 99"
  greset_all
  gset_param "$GF/param-golden-tail.img"
  grun gtail
  local rc=$GRC
  local gend gtail
  gend=$(garchive_end)
  gtail=$(gtail_len)
  check "restart after the install (exit 99, got $rc)" test "$rc" -eq 99
  check "logged: the stock archive with the leftover bytes, installing" \
    log_has gtail "golden: PARAM holds the stock archive, and $gtail bytes after its end (byte $gend) that are not zero, left by an earlier write: the stock image all the same, installing"
  check "said on screen: the leftover bytes, the loader puts zeros there" \
    log_has gtail "t715-say: PARAM holds the stock pictures, then $gtail bytes S-Boot does not read: the loader puts zeros there."
  check "logged: golden_forge_checked's tolerance for the copy of PARAM" \
    log_has gtail "holds the stock archive, and $gtail bytes after its end (byte $gend) that are not zero: the loader has zeros there"
  check "the loader forged as expected" log_has gtail "golden: the loader forged from the stock PARAM is the expected one"
  check "PARAM holds the loader" log_has gtail "golden: PARAM holds the loader (sha256"
  check "PARAM's first $GEXTENT bytes hash to loader.sha256" \
    test "$(gparam_loader_sum)" = "$(head -c "$GEXTENT" "$(g_param_dev)" | sha256sum | cut -d' ' -f1)"
  check "the loader has zeros where the leftover bytes were" \
    cmp -s <(dd if="$(g_param_dev)" bs=1 skip=1048576 count="$gtail" status=none) <(head -c "$gtail" /dev/zero)
  check "PARAM's bytes after the loader's part are unchanged" \
    cmp -s <(dd if="$(g_param_dev)" bs=512 skip=14336 count=2048 status=none) <(tail -c +7340033 "$GF/param-golden-tail.img")
  # shellcheck disable=SC2016  # expanded by the sh -c script
  check "PARAM-stock-backup.img is the raw PARAM, leftover bytes included, with its sidecar" gwith_userdata sh -c '
    cmp -s "$1/media/0/linux/PARAM-stock-backup.img" "$2/param-golden-tail.img"
    [ "$(cat "$1/media/0/linux/PARAM-stock-backup.img.sha256")" = "$(sha256sum "$2/param-golden-tail.img" | cut -d" " -f1)  PARAM-stock-backup.img" ]
  ' sh "$W/gud" "$GF"
  # shellcheck disable=SC2016  # expanded by the sh -c script
  check "the root's saved PARAM is the raw PARAM too, mode 0600" gwith_userdata sh -c '
    cmp -s "$1/omarchy-arm64/var/lib/t715/PARAM-stock.img" "$2/param-golden-tail.img"
    [ "$(stat -c %a "$1/omarchy-arm64/var/lib/t715/PARAM-stock.img")" = 600 ]
  ' sh "$W/gud" "$GF"
  [[ $rc -eq 99 ]] || show_log gtail
  detach_inner_loops
  ip link del usb0 2>/dev/null || true
}

# scenario_golden_param_other: PARAM's archive is not the stock one (no
# lpm.jpg, no warning.jpg, an extra custom.jpg) and nothing is installed:
# the on-screen report says what differs, then the refusal; nothing written.
scenario_golden_param_other() {
  echo "--- scenario: golden, PARAM's archive is not the stock one (missing and extra pictures): the report, refused, exit 97"
  greset_all
  gset_param "$GF/param-golden-other.img"
  local before after
  before=$(gdisk_sums)
  grun gother
  local rc=$GRC
  after=$(gdisk_sums)
  local lpm warning csize csum n m
  lpm=$(awk '$3 == "lpm.jpg" { print $2 }' "$GF/golden/stock.members")
  warning=$(awk '$3 == "warning.jpg" { print $2 }' "$GF/golden/stock.members")
  csize=$(stat -c %s "$GF/custom.jpg")
  csum=$(sha256sum "$GF/custom.jpg" | cut -d' ' -f1)
  n=$(grep -c . "$GF/param-other.members")
  m=$(grep -c . "$GF/golden/stock.members")
  check "waited on screen (exit 97, got $rc)" test "$rc" -eq 97
  check "logged: neither the stock image nor the loader" log_has gother "neither the stock image nor the loader"
  check "said on screen: lpm.jpg missing" log_has gother "t715-say: PARAM: lpm.jpg is missing (stock: $lpm bytes)."
  check "said on screen: warning.jpg missing" log_has gother "t715-say: PARAM: warning.jpg is missing (stock: $warning bytes)."
  check "said on screen: custom.jpg not in the stock archive" \
    log_has gother "t715-say: PARAM: custom.jpg ($csize bytes) is not in the stock archive."
  check "said on screen: the picture counts" log_has gother "t715-say: PARAM: $n pictures, stock: $m."
  check "logged: PARAM member custom.jpg, its size and sha256" \
    log_has gother "golden: PARAM member custom.jpg, $csize bytes, sha256 $csum"
  check "exactly one log line for custom.jpg" \
    sh -c "[ \"\$(grep -cF 'golden: PARAM member custom.jpg,' '$W/gother.log')\" -eq 1 ]"
  check "said on screen: the refusal text" \
    log_has gother "t715-say: PARAM does not hold the stock image of T715XXU2CRH1 that this installer knows. Nothing was written. Flash the stock T715XXU2CRH1 firmware with Odin (BL included), then this installer again. If it says this again, post a photo of this screen in the XDA thread."
  gcheck_nothing_written "$before" "$after"
  [[ $rc -eq 97 ]] || show_log gother
  detach_inner_loops
  ip link del usb0 2>/dev/null || true
}

# scenario_golden_rescue_tail: as the rescue, but the root's saved stock PARAM
# is one with leftover bytes after its archive's end: the tolerance of
# golden_forge_checked applies to it too, the loader goes back into PARAM.
scenario_golden_rescue_tail() {
  echo "--- scenario: golden, rescue with a saved stock PARAM that has leftover bytes after its archive (PARAM changed)"
  greset_all
  gplant_root golden "$GF/param-golden-tail.img"
  gset_param "$W/param-golden-changed.img"
  grun gresctail
  local rc=$GRC
  local gend gtail
  gend=$(garchive_end)
  gtail=$(gtail_len)
  check "restart after the loader is back (exit 99, got $rc)" test "$rc" -eq 99
  check "logged: neither the stock image nor the loader" log_has gresctail "neither the stock image nor the loader"
  check "said on screen: writing the loader back" log_has gresctail "t715-say: Rescue: PARAM does not hold Omarchy's loader. Writing it back."
  check "logged: golden_forge_checked's tolerance for the saved PARAM" \
    log_has gresctail "holds the stock archive, and $gtail bytes after its end (byte $gend) that are not zero: the loader has zeros there"
  check "the loader was forged from the saved stock PARAM" log_has gresctail "golden: the loader forged from the stock PARAM is the expected one"
  check "said on screen: back in PARAM, restarting" log_has gresctail "t715-say: Rescue: the loader is back in PARAM. Restarting."
  check "PARAM's first $GEXTENT bytes are the loader now" \
    test "$(gparam_loader_sum)" = "$(head -c "$GEXTENT" "$(g_param_dev)" | sha256sum | cut -d' ' -f1)"
  check "PARAM's bytes after the loader's part are unchanged" \
    cmp -s <(dd if="$(g_param_dev)" bs=512 skip=14336 count=2048 status=none) <(tail -c +7340033 "$W/param-golden-changed.img")
  [[ $rc -eq 99 ]] || show_log gresctail
  detach_inner_loops
  ip link del usb0 2>/dev/null || true
}

# --- the second stock PARAM of the firmware (the fixtures' line 2: the BL's
# --- param.bin as Odin flashes it, and the loader forged from it): every
# --- state the installer has must take it exactly as it takes line 1's.

# scenario_golden_stock_b: a fresh install from the second stock PARAM.  As
# scenario_golden_fresh, with line 2's pair: installed, PARAM's first EXTENT
# bytes are loader B's, the S-Boot data after them untouched.
scenario_golden_stock_b() {
  echo "--- scenario: golden, fresh install from the second stock PARAM (the one Odin flashes)"
  greset_all
  gset_param "$GF/param-stock-b.img"
  grun gfreshb
  local rc=$GRC
  check "restart after the install (exit 99, got $rc)" test "$rc" -eq 99
  check "logged: the stock image, by its line and label" \
    log_has gfreshb "golden: PARAM is a stock image this installer knows, line 2 (the stock PARAM flashed with Odin (param-stock-b.img))"
  check "logged: the stock image, installing" log_has gfreshb "golden: PARAM is the stock image: installing"
  check "the loader forged as expected, the one of the same line" \
    log_has gfreshb "golden: the loader forged from the stock PARAM is the expected one, line 2 (the loader forged from line 2 of stock.sha256)"
  check "PARAM holds loader B" log_has gfreshb "golden: PARAM holds the loader (sha256"
  check "and not loader A's" bash -c "! cmp -s <(head -c $GEXTENT '$(g_param_dev)') <(head -c $GEXTENT '$GF/param-loader.img')"
  check "said on screen: installed, restarting" log_has gfreshb "t715-say: Omarchy is installed. Restarting into it..."
  check "PARAM's first $GEXTENT bytes are loader B's (param-loader-b.img)" \
    gparam_head_is "$GF/param-loader-b.img"
  check "PARAM's first $GEXTENT bytes hash to loader.sha256 line 2" \
    test "$(gparam_line loader.sha256 2)" = "$(head -c "$GEXTENT" "$(g_param_dev)" | sha256sum | cut -d' ' -f1)"
  check "PARAM's bytes after the loader's part are unchanged" \
    cmp -s <(dd if="$(g_param_dev)" bs=512 skip=14336 count=2048 status=none) <(tail -c +7340033 "$GF/param-stock-b.img")
  check "slot A (sector 131072) is a valid header of generation 1" test "$(gslot_gen "$(g_cache_dev)" 131072)" = 1
  check "the root's tree: owners, setuid, symlink, hard links, long path, NVRAM, markers" \
    gwith_userdata sh "$W/gcheck-tree.sh" "$W/gud"
  # shellcheck disable=SC2016  # expanded by the sh -c script
  check "PARAM-stock-backup.img is the whole second stock PARAM, with its sidecar" gwith_userdata sh -c '
    cmp -s "$1/media/0/linux/PARAM-stock-backup.img" "$2/param-stock-b.img"
    [ "$(cat "$1/media/0/linux/PARAM-stock-backup.img.sha256")" = "$(sha256sum "$2/param-stock-b.img" | cut -d" " -f1)  PARAM-stock-backup.img" ]
  ' sh "$W/gud" "$GF"
  # shellcheck disable=SC2016  # expanded by the sh -c script
  check "the root's saved PARAM is the second stock image, mode 0600" gwith_userdata sh -c '
    cmp -s "$1/omarchy-arm64/var/lib/t715/PARAM-stock.img" "$2/param-stock-b.img"
    [ "$(stat -c %a "$1/omarchy-arm64/var/lib/t715/PARAM-stock.img")" = 600 ]
  ' sh "$W/gud" "$GF"
  [[ $rc -eq 99 ]] || show_log gfreshb
  detach_inner_loops
  ip link del usb0 2>/dev/null || true
}

# scenario_golden_handback_b: loader B in PARAM with an installed, marked
# root: the hand-back, as with loader A, not the rescue.
scenario_golden_handback_b() {
  echo "--- scenario: golden, loader B in PARAM, root installed: the hand-back"
  greset_all
  gplant_root golden "$GF/param-stock-b.img"
  gset_param "$GF/param-loader-b.img"
  local before after
  before=$(gdisk_sums)
  grun ghandb
  local rc=$GRC
  after=$(gdisk_sums)
  check "restart after t715.failwait (exit 99, got $rc)" test "$rc" -eq 99
  check "logged: PARAM holds a loader this installer knows, line 2's" \
    log_has ghandb "golden: PARAM's first $GEXTENT bytes are a loader this installer knows, line 2 (the loader forged from line 2 of stock.sha256)"
  check "logged: the loader handed this start back" log_has ghandb "the loader is in PARAM and USERDATA/omarchy-arm64 is installed: the loader handed this start back"
  check "not the rescue (nothing forged)" sh -c "! grep -q 'Rescue' '$W/ghandb.log'"
  check "said on screen: did not finish starting last time" log_has ghandb "t715-say: Omarchy did not finish starting last time. The tablet restarts and tries again."
  gcheck_nothing_written "$before" "$after"
  [[ $rc -eq 99 ]] || show_log ghandb
  detach_inner_loops
  ip link del usb0 2>/dev/null || true
}

# scenario_golden_rescue_b: the rescue with the second stock PARAM: PARAM
# holds neither stock image nor a loader, and the root's saved stock PARAM is
# param-stock-b.img: loader B is written back, not loader A.
scenario_golden_rescue_b() {
  echo "--- scenario: golden, rescue from the second stock PARAM (loader B written back)"
  greset_all
  gplant_root golden "$GF/param-stock-b.img"
  gset_param "$W/param-golden-changed.img"
  grun grescb
  local rc=$GRC
  check "restart after the loader is back (exit 99, got $rc)" test "$rc" -eq 99
  check "logged: neither the stock image nor the loader" log_has grescb "neither the stock image nor the loader"
  check "said on screen: writing the loader back" log_has grescb "t715-say: Rescue: PARAM does not hold Omarchy's loader. Writing it back."
  check "logged: the saved stock PARAM, by its line and label" \
    log_has grescb "PARAM-stock.img is a stock PARAM this installer knows, line 2 (the stock PARAM flashed with Odin (param-stock-b.img))"
  check "the loader forged as expected, the one of the same line" \
    log_has grescb "golden: the loader forged from the stock PARAM is the expected one, line 2 (the loader forged from line 2 of stock.sha256)"
  check "said on screen: back in PARAM, restarting" log_has grescb "t715-say: Rescue: the loader is back in PARAM. Restarting."
  check "PARAM's first $GEXTENT bytes are loader B's now" gparam_head_is "$GF/param-loader-b.img"
  check "not loader A" bash -c "! cmp -s <(head -c $GEXTENT '$(g_param_dev)') <(head -c $GEXTENT '$GF/param-loader.img')"
  check "PARAM's bytes after the loader's part are unchanged" \
    cmp -s <(dd if="$(g_param_dev)" bs=512 skip=14336 count=2048 status=none) <(tail -c +7340033 "$W/param-golden-changed.img")
  [[ $rc -eq 99 ]] || show_log grescb
  detach_inner_loops
  ip link del usb0 2>/dev/null || true
}

# scenario_golden_param_tail_b: as scenario_golden_param_tail, with the
# second stock PARAM: its archive followed by leftover bytes after its end is
# installed too.
scenario_golden_param_tail_b() {
  echo "--- scenario: golden, the second stock PARAM's archive with leftover bytes after its end: installed, exit 99"
  greset_all
  gset_param "$GF/param-golden-tail-b.img"
  grun gtailb
  local rc=$GRC
  local gend gtail
  gend=$(cat "$GF/stock-b.end")
  gtail=$(gtail_len)
  check "restart after the install (exit 99, got $rc)" test "$rc" -eq 99
  check "logged: a stock archive this installer knows, line 2's" \
    log_has gtailb "golden: PARAM holds a stock archive this installer knows, line 2 (the stock PARAM flashed with Odin (param-stock-b.img))"
  check "logged: the stock archive with the leftover bytes, installing" \
    log_has gtailb "golden: PARAM holds the stock archive, and $gtail bytes after its end (byte $gend) that are not zero, left by an earlier write: the stock image all the same, installing"
  check "said on screen: the leftover bytes, the loader puts zeros there" \
    log_has gtailb "t715-say: PARAM holds the stock pictures, then $gtail bytes S-Boot does not read: the loader puts zeros there."
  check "the loader forged as expected, the one of the same line" \
    log_has gtailb "golden: the loader forged from the stock PARAM is the expected one, line 2 (the loader forged from line 2 of stock.sha256)"
  check "PARAM's first $GEXTENT bytes are loader B's" gparam_head_is "$GF/param-loader-b.img"
  check "the loader has zeros where the leftover bytes were" \
    cmp -s <(dd if="$(g_param_dev)" bs=1 skip=1048576 count="$gtail" status=none) <(head -c "$gtail" /dev/zero)
  check "PARAM's bytes after the loader's part are unchanged" \
    cmp -s <(dd if="$(g_param_dev)" bs=512 skip=14336 count=2048 status=none) <(tail -c +7340033 "$GF/param-golden-tail-b.img")
  # shellcheck disable=SC2016  # expanded by the sh -c script
  check "PARAM-stock-backup.img is the raw PARAM, leftover bytes included, with its sidecar" gwith_userdata sh -c '
    cmp -s "$1/media/0/linux/PARAM-stock-backup.img" "$2/param-golden-tail-b.img"
    [ "$(cat "$1/media/0/linux/PARAM-stock-backup.img.sha256")" = "$(sha256sum "$2/param-golden-tail-b.img" | cut -d" " -f1)  PARAM-stock-backup.img" ]
  ' sh "$W/gud" "$GF"
  [[ $rc -eq 99 ]] || show_log gtailb
  detach_inner_loops
  ip link del usb0 2>/dev/null || true
}

# scenario_golden_cross_pair: golden directories whose loader.sha256 does not
# pair.  In golden-cross, its line 2 names the loader forged from line 1's
# stock PARAM, so the second stock PARAM's loader is named nowhere; in
# golden-swapped, the two loaders are on each other's line.  The init's own
# golden_forge_checked, sourced as scenario_golden_forge_python does, must
# refuse the second stock PARAM in both, each with its own message, and
# still forge the first pair's loader; with the fixtures' own directory, the
# second stock PARAM gives loader B.  Needs no disk, only the initramfs'
# functions: GOLDEN_DIR is pointed at each directory in turn.
scenario_golden_cross_pair() {
  echo "--- scenario: golden, loader.sha256 that does not pair (cross-paired, swapped): refused"
  cat >"$W/gcross.sh" <<'EOF'
log() { echo "log: $*"; }; err() { echo "err: $*" >&2; return 0; }; warn() { :; }
. /work/golden-fns.sh
RUNDIR=/work/golden-run; mkdir -p "$RUNDIR"
for g in golden golden-cross golden-swapped; do
  GOLDEN_DIR="/t/golden-fixtures/$g"
  EXTENT=$(golden_val extent)
  echo "sums $g $(golden_sums_ok && echo ok || echo bad)"
  for s in param-stock.img param-stock-b.img; do
    rm -f "$RUNDIR/param-loader.img"
    if golden_forge_checked "/t/golden-fixtures/$s" >"$RUNDIR/out.txt" 2>"$RUNDIR/err.txt"; then r=accepted; else r=refused; fi
    got=$(sha256sum "$RUNDIR/param-loader.img" 2>/dev/null | cut -d' ' -f1)
    a=$(sed -n 1p /t/golden-fixtures/golden/loader.sha256 | cut -d' ' -f1)
    b=$(sed -n 2p /t/golden-fixtures/golden/loader.sha256 | cut -d' ' -f1)
    case $got in "$a") which=loader-A ;; "$b") which=loader-B ;; ?*) which=other ;; *) which=none ;; esac
    echo "forge $g $s $r $which"
    sed "s|^|err $g $s |" "$RUNDIR/err.txt"
    sed "s|^|log $g $s |" "$RUNDIR/out.txt"
  done
done
EOF
  "$W/root-gfns/bin/busybox" sh "$W/gcross.sh" >"$W/gcross.out" 2>&1
  sed 's/^/        | /' "$W/gcross.out"
  local l1 l2 l1x l2x l1s l2s
  l1=$(gparam_line loader.sha256 1); l2=$(gparam_line loader.sha256 2)
  # what the two wrong directories name, on each line
  l1x=$(sed -n 1p "$GF/golden-cross/loader.sha256" | cut -d' ' -f1)
  l2x=$(sed -n 2p "$GF/golden-cross/loader.sha256" | cut -d' ' -f1)
  l1s=$(sed -n 1p "$GF/golden-swapped/loader.sha256" | cut -d' ' -f1)
  l2s=$(sed -n 2p "$GF/golden-swapped/loader.sha256" | cut -d' ' -f1)
  check "the wrong directories are lists of sums in pairs (well formed for the presence check)" \
    sh -c "grep -qx 'sums golden-cross ok' '$W/gcross.out' && grep -qx 'sums golden-swapped ok' '$W/gcross.out'"
  check "the presence check counts lines, so the pairing itself is checked when forging" \
    test "$l1x$l2x" = "$l1$l1" -a "$l1s$l2s" = "$l2$l1"
  # --- the right directory
  check "golden: the first stock PARAM gives loader A" grep -qx "forge golden param-stock.img accepted loader-A" "$W/gcross.out"
  check "golden: the second stock PARAM gives loader B" grep -qx "forge golden param-stock-b.img accepted loader-B" "$W/gcross.out"
  # --- golden-cross: loader A on both lines.  "forge ... refused loader-B":
  # the forge ran (its output, loader B, stays in RUNDIR), and was refused,
  # so nothing would be written.
  check "golden-cross: the first stock PARAM still gives loader A" grep -qx "forge golden-cross param-stock.img accepted loader-A" "$W/gcross.out"
  check "golden-cross: the second stock PARAM is refused" grep -qx "forge golden-cross param-stock-b.img refused loader-B" "$W/gcross.out"
  check "golden-cross: said so: not the loader this installer was built for" \
    grep -qF -- "err golden-cross param-stock-b.img err: golden: the loader forged from the stock PARAM is $l2, not the one this installer was built for: nothing written" "$W/gcross.out"
  check "golden-cross: the stock PARAM itself was known (line 2)" \
    grep -qF -- "log golden-cross param-stock-b.img log: golden: /t/golden-fixtures/param-stock-b.img is a stock PARAM this installer knows, line 2 (the stock PARAM flashed with Odin (param-stock-b.img))" "$W/gcross.out"
  # --- golden-swapped: the loaders on each other's line; each stock PARAM
  # forges its own loader, which the directory puts on the other line
  check "golden-swapped: the second stock PARAM is refused" grep -qx "forge golden-swapped param-stock-b.img refused loader-B" "$W/gcross.out"
  check "golden-swapped: said so: the loader of another stock PARAM" \
    grep -qF -- "err golden-swapped param-stock-b.img err: golden: the loader forged from the stock PARAM of line 2 (the stock PARAM flashed with Odin (param-stock-b.img)) is the loader of another stock PARAM ($l2): nothing written" "$W/gcross.out"
  check "golden-swapped: the first stock PARAM is refused too (loader B is not its loader)" \
    grep -qx "forge golden-swapped param-stock.img refused loader-A" "$W/gcross.out"
  check "golden-swapped: said so for the first" \
    grep -qF -- "err golden-swapped param-stock.img err: golden: the loader forged from the stock PARAM of line 1 (the stock PARAM reached over the air (param-stock.img)) is the loader of another stock PARAM ($l1): nothing written" "$W/gcross.out"
  # the expected-one line goes with an accepted forge, and only with one:
  # three of the six (golden's two, golden-cross's first)
  check "the expected-one line was logged once per accepted forge, never for a refused one" \
    sh -c "[ \"\$(grep -c 'the expected one' '$W/gcross.out')\" -eq 3 ]"
}

scenario_golden_wrong_bootloader() {
  echo "--- scenario: golden, wrong bootloader (T715XXU1ARB1) with a stock PARAM: refused, exit 97"
  greset_all
  local before after
  before=$(gdisk_sums)
  prepare_golden_boot gwrongbl
  local rc=0
  run_init gwrongbl "androidboot.bootloader=T715XXU1ARB1 t715.golden=1 t715.rootwait=30 t715.failwait=2" || rc=$?
  after=$(gdisk_sums)
  check "waited on screen (exit 97, got $rc)" test "$rc" -eq 97
  check "logged: the bootloader is wrong" log_has gwrongbl "ERROR: golden: the bootloader is 'T715XXU1ARB1', the loader is made for T715XXU2CRH1"
  check "said on screen: the bootloader is wrong" \
    log_has gwrongbl "t715-say: This tablet's bootloader is T715XXU1ARB1; Omarchy needs T715XXU2CRH1. Nothing was written."
  gcheck_nothing_written "$before" "$after"
  [[ $rc -eq 97 ]] || show_log gwrongbl
  detach_inner_loops
  ip link del usb0 2>/dev/null || true
}

scenario_golden_no_sidecar() {
  echo "--- scenario: golden, no .sha256 sidecar next to the image: refused, exit 97"
  greset_all "$W/golden-userdata-noside.img"
  local before after
  before=$(gdisk_sums)
  grun gnoside
  local rc=$GRC
  after=$(gdisk_sums)
  check "waited on screen (exit 97, got $rc)" test "$rc" -eq 97
  check "logged: no sidecar next to the image" log_has gnoside "ERROR: golden: no omarchy-arm64.img.sha256 next to the image"
  check "said on screen: the sidecar is missing" \
    log_has gnoside "t715-say: omarchy-arm64.img.sha256 is missing next to the image: copy it there too, then restart. Nothing was written."
  gcheck_nothing_written "$before" "$after"
  [[ $rc -eq 97 ]] || show_log gnoside
  detach_inner_loops
  ip link del usb0 2>/dev/null || true
}

scenario_golden_bad_sidecar() {
  echo "--- scenario: golden, a sidecar with a wrong hash: refused, exit 97"
  greset_all "$W/golden-userdata-badside.img"
  local before after
  before=$(gdisk_sums)
  grun gbadside
  local rc=$GRC
  after=$(gdisk_sums)
  check "waited on screen (exit 97, got $rc)" test "$rc" -eq 97
  check "logged: checksum mismatch" log_has gbadside "ERROR: image checksum check failed: checksum mismatch"
  check "said on screen: the image file is damaged" log_has gbadside "t715-say: The image file is damaged (bad checksum). Copy it to the tablet again."
  gcheck_nothing_written "$before" "$after"
  [[ $rc -eq 97 ]] || show_log gbadside
  detach_inner_loops
  ip link del usb0 2>/dev/null || true
}

scenario_golden_not_aarch64() {
  echo "--- scenario: golden, the image is not aarch64 (e_machine 0x28): refused, exit 97"
  greset_all "$W/golden-userdata-badarch.img"
  local before after
  before=$(gdisk_sums)
  dd if="$W/disk-golden.img" of="$W/gbadarch-ud-before.bin" bs=1M skip=217 count=64 status=none
  grun gbadarch
  local rc=$GRC
  after=$(gdisk_sums)
  dd if="$W/disk-golden.img" of="$W/gbadarch-ud-after.bin" bs=1M skip=217 count=64 status=none
  if [ "$before" != "$after" ]; then
    echo "        first differing bytes of USERDATA (offset in MiB-blocks):"
    cmp -l "$W/gbadarch-ud-before.bin" "$W/gbadarch-ud-after.bin" 2>/dev/null | head -5 | sed 's/^/        /' || true
  fi
  check "waited on screen (exit 97, got $rc)" test "$rc" -eq 97
  check "logged: not an aarch64 system" log_has gbadarch "ERROR: golden: the image is not an aarch64 system"
  gcheck_nothing_written "$before" "$after"
  [[ $rc -eq 97 ]] || show_log gbadarch
  detach_inner_loops
  ip link del usb0 2>/dev/null || true
}

scenario_golden_slots_there() {
  echo "--- scenario: golden, CACHE already shrunk with slot B of generation 5: slot A gets generation 6"
  greset_all
  gplant_root persist   # the seed is scenario 1's/2's concern; the slots are this one's
  dd if="$W/golden-cache9.img" of="$(g_cache_dev)" bs=1M conv=notrunc status=none
  local fs_before slotb_before
  fs_before=$(gpart_sum 34816 131072)            # the first 64 MiB: the file system
  slotb_before=$(gpart_sum $((34816 + 262144)) $GSLOT_SECTORS)
  grun gslots
  local rc=$GRC
  check "restart after the install (exit 99, got $rc)" test "$rc" -eq 99
  check "logged: the slots held A none, B 5" log_has gslots "the slots held: A none, B 5"
  check "logged: generation 6 to sector 131072" log_has gslots "golden: the kernel's slot, generation 6, to sector 131072 of CACHE"
  check "slot A is a valid header of generation 6" test "$(gslot_gen "$(g_cache_dev)" 131072)" = 6
  check "the file system stayed byte-identical" test "$(gpart_sum 34816 131072)" = "$fs_before"
  check "slot B stayed byte-identical" test "$(gpart_sum $((34816 + 262144)) $GSLOT_SECTORS)" = "$slotb_before"
  [[ $rc -eq 99 ]] || show_log gslots
  detach_inner_loops
  ip link del usb0 2>/dev/null || true
}

scenario_golden_foreign_root() {
  echo "--- scenario: golden, a foreign omarchy-arm64 (no marker): refused, exit 97"
  greset_all
  gwith_userdata mkdir -p "$W/gud/omarchy-arm64"
  local before after
  before=$(gdisk_sums)
  grun gforeign
  local rc=$GRC
  after=$(gdisk_sums)
  check "waited on screen (exit 97, got $rc)" test "$rc" -eq 97
  check "logged: the folder was not made by this installer" \
    log_has gforeign "ERROR: golden: USERDATA/omarchy-arm64 exists and was not made by this installer"
  check "said on screen: a folder this installer did not make" \
    log_has gforeign "t715-say: The internal storage already holds a folder omarchy-arm64 that this installer did not make. Nothing was written."
  gcheck_nothing_written "$before" "$after"
  [[ $rc -eq 97 ]] || show_log gforeign
  detach_inner_loops
  ip link del usb0 2>/dev/null || true
}

# --- the reinstall (linux/reinstall over an installed root, loader in
# --- PARAM): the happy path, the refusals, the rollback, the interrupted one.

# scenario_golden_reinstall: the happy path.  CACHE holds slot B of
# generation 5, as the old install left it: the reinstall's slot A gets
# generation 6, PARAM is left alone, the old root is kept as
# omarchy-arm64.previous, the request file goes, and the new root carries
# the saved stock PARAM over.
scenario_golden_reinstall() {
  echo "--- scenario: golden, the reinstall (loader in PARAM, root installed, linux/reinstall)"
  greset_all
  dd if="$W/golden-cache9.img" of="$(g_cache_dev)" bs=1M conv=notrunc status=none
  gplant_root golden
  gplant_reinstall
  gset_param "$GF/param-loader.img"
  local param_before fs_before slotb_before
  param_before=$(gpart_sum 2048 16384)
  fs_before=$(gpart_sum 34816 131072)
  slotb_before=$(gpart_sum $((34816 + 262144)) $GSLOT_SECTORS)
  grun greinst
  local rc=$GRC
  detach_inner_loops
  check "restart after the reinstall (exit 99, got $rc)" test "$rc" -eq 99
  check "logged: the reinstall is asked" log_has greinst "media/0/linux/reinstall asks for a reinstall"
  check "said on screen: a reinstall is asked" log_has greinst "t715-say: A reinstall is asked (linux/reinstall)."
  check "logged: the root set aside, the request file removed" \
    log_has greinst "golden: USERDATA/omarchy-arm64 set aside as omarchy-arm64.previous, media/0/linux/reinstall removed"
  check "said on screen: kept as omarchy-arm64.previous" \
    log_has greinst "t715-say: The installed system is kept as omarchy-arm64.previous. Installing the new one..."
  check "logged: the saved stock PARAM carried over" \
    log_has greinst "golden: the saved stock PARAM carried over from omarchy-arm64.previous"
  check "logged: the slots held A none, B 5" log_has greinst "the slots held: A none, B 5"
  check "logged: generation 6 to sector 131072" log_has greinst "golden: the kernel's slot, generation 6, to sector 131072 of CACHE"
  check "said on screen: installed, restarting" log_has greinst "t715-say: Omarchy is installed. Restarting into it..."
  check "reboot logged" log_has greinst "rebooting (reboot -f)"
  check "PARAM byte-identical to before (the loader left as it is)" test "$(gpart_sum 2048 16384)" = "$param_before"
  check "PARAM still holds the loader" \
    test "$(gparam_loader_sum)" = "$(head -c "$GEXTENT" "$(g_param_dev)" | sha256sum | cut -d' ' -f1)"
  check "slot A (sector 131072) is a valid header of generation 6" test "$(gslot_gen "$(g_cache_dev)" 131072)" = 6
  check "slot B (sector 262144) still generation 5" test "$(gslot_gen "$(g_cache_dev)" 262144)" = 5
  check "CACHE's file system stayed byte-identical" test "$(gpart_sum 34816 131072)" = "$fs_before"
  check "slot B stayed byte-identical" test "$(gpart_sum $((34816 + 262144)) $GSLOT_SECTORS)" = "$slotb_before"
  check "the old root is kept as omarchy-arm64.previous, its marker unchanged" gmarker_ok omarchy-arm64.previous
  check "the new root holds the image's tree and the markers" gwith_userdata sh "$W/gcheck-tree.sh" "$W/gud"
  check "linux/reinstall is gone" gwith_userdata test ! -e "$W/gud/media/0/linux/reinstall"
  # shellcheck disable=SC2016  # expanded by the sh -c script
  check "the new root's saved stock PARAM is byte-identical to the old one's, mode 600" gwith_userdata sh -c '
    cmp -s "$1/omarchy-arm64/var/lib/t715/PARAM-stock.img" "$1/omarchy-arm64.previous/var/lib/t715/PARAM-stock.img" &&
    [ "$(stat -c %a "$1/omarchy-arm64/var/lib/t715/PARAM-stock.img")" = 600 ]
  ' sh "$W/gud"
  check "the install log is next to the image" gwith_userdata test -s "$W/gud/media/0/linux/omarchy-arm64-install.log"
  [[ $rc -eq 99 ]] || show_log greinst
  ip link del usb0 2>/dev/null || true
}

# scenario_golden_reinstall_previous: a reinstall asked while
# omarchy-arm64.previous is still there: refused, nothing written.
scenario_golden_reinstall_previous() {
  echo "--- scenario: golden, reinstall refused: omarchy-arm64.previous is there already"
  greset_all
  gplant_root golden
  # shellcheck disable=SC2016  # expanded by the sh -c script
  gwith_userdata sh -c 'mkdir -p "$1/omarchy-arm64.previous" && echo kept >"$1/omarchy-arm64.previous/marker"' sh "$W/gud"
  gplant_reinstall
  gset_param "$GF/param-loader.img"
  local before after
  before=$(gdisk_sums)
  grun greinst-prev
  local rc=$GRC
  after=$(gdisk_sums)
  check "waited on screen (exit 97, got $rc)" test "$rc" -eq 97
  check "logged: omarchy-arm64.previous is there already" \
    log_has greinst-prev "ERROR: golden: USERDATA/omarchy-arm64.previous is there already"
  check "the on-screen reason names omarchy-arm64.previous" \
    log_has greinst-prev "t715-say: A reinstall is asked, but the system an earlier reinstall set aside, omarchy-arm64.previous, is still there."
  gcheck_nothing_written "$before" "$after"
  detach_inner_loops
  check "the root is as before" gmarker_ok omarchy-arm64
  check "the request file stays" gwith_userdata test -f "$W/gud/media/0/linux/reinstall"
  # shellcheck disable=SC2016  # expanded by the sh -c script
  check "omarchy-arm64.previous is as before" \
    gwith_userdata sh -c '[ "$(cat "$1/omarchy-arm64.previous/marker")" = kept ]' sh "$W/gud"
  [[ $rc -eq 97 ]] || show_log greinst-prev
  ip link del usb0 2>/dev/null || true
}

# scenario_golden_reinstall_noimg: a reinstall asked with no image in
# linux/: refused, nothing written, the request file stays.
scenario_golden_reinstall_noimg() {
  echo "--- scenario: golden, reinstall refused: no image found"
  greset_all
  gwith_userdata rm -f "$W/gud/media/0/linux/omarchy-arm64.img" "$W/gud/media/0/linux/omarchy-arm64.img.sha256"
  gplant_root golden
  gplant_reinstall
  gset_param "$GF/param-loader.img"
  local before after
  before=$(gdisk_sums)
  grun greinst-noimg
  local rc=$GRC
  after=$(gdisk_sums)
  check "waited on screen (exit 97, got $rc)" test "$rc" -eq 97
  check "logged: no image in linux/" \
    log_has greinst-noimg "ERROR: golden: no omarchy-arm64.img in the folder linux of the internal storage or of a microSD card"
  check "said on screen: the image was not found" \
    log_has greinst-noimg "t715-say: A reinstall is asked, but Omarchy's image was not found."
  gcheck_nothing_written "$before" "$after"
  detach_inner_loops
  check "the root is untouched" gmarker_ok omarchy-arm64
  check "the request file stays" gwith_userdata test -f "$W/gud/media/0/linux/reinstall"
  [[ $rc -eq 97 ]] || show_log greinst-noimg
  ip link del usb0 2>/dev/null || true
}

# scenario_golden_reinstall_badsum: a reinstall asked with a sidecar whose
# hash is wrong: refused, nothing written, the request file stays.
scenario_golden_reinstall_badsum() {
  echo "--- scenario: golden, reinstall refused: the image's sum is bad"
  greset_all "$W/golden-userdata-badside.img"
  gplant_root golden
  gplant_reinstall
  gset_param "$GF/param-loader.img"
  local before after
  before=$(gdisk_sums)
  grun greinst-badsum
  local rc=$GRC
  after=$(gdisk_sums)
  check "waited on screen (exit 97, got $rc)" test "$rc" -eq 97
  check "logged: checksum mismatch" log_has greinst-badsum "ERROR: image checksum check failed: checksum mismatch"
  check "said on screen: the image file is damaged" \
    log_has greinst-badsum "t715-say: The image file is damaged (bad checksum). Copy it again, then restart. Nothing was written."
  gcheck_nothing_written "$before" "$after"
  detach_inner_loops
  check "the root is untouched" gmarker_ok omarchy-arm64
  check "the request file stays" gwith_userdata test -f "$W/gud/media/0/linux/reinstall"
  [[ $rc -eq 97 ]] || show_log greinst-badsum
  ip link del usb0 2>/dev/null || true
}

# scenario_golden_reinstall_space: a reinstall asked with USERDATA nearly
# full (under 1 MiB free, below the image's use + the test's 1 MiB
# margin): refused before anything is set aside, nothing written.
scenario_golden_reinstall_space() {
  echo "--- scenario: golden, reinstall refused for space (USERDATA nearly full)"
  greset_all
  gplant_root golden
  gplant_reinstall
  gset_param "$GF/param-loader.img"
  if ! gfill_userdata; then ko "USERDATA filled"; return; fi
  local before after
  before=$(gdisk_sums)
  grun greinst-space
  local rc=$GRC
  after=$(gdisk_sums)
  check "waited on screen (exit 97, got $rc)" test "$rc" -eq 97
  check "logged: the free space against the image's use" \
    log_has greinst-space "MiB next to the system it keeps"
  check "the on-screen reason names the GB needed" \
    sh -c "grep -qE 't715-say: A reinstall needs [0-9]+ GB free in the internal storage, next to the installed system it keeps' '$W/greinst-space.log'"
  gcheck_nothing_written "$before" "$after"
  detach_inner_loops
  check "the root stays" gmarker_ok omarchy-arm64
  check "the request file stays" gwith_userdata test -f "$W/gud/media/0/linux/reinstall"
  [[ $rc -eq 97 ]] || show_log greinst-space
  ip link del usb0 2>/dev/null || true
}

# scenario_golden_reinstall_rollback: the image's tree cannot be copied
# (a top-level name holding a blank, which the seed's archive list splits
# on): after the rename the install fails, the kept root goes back as
# omarchy-arm64, and the run ends in the reboot path.
scenario_golden_reinstall_rollback() {
  echo "--- scenario: golden, the reinstall stops in the copy: omarchy-arm64.previous goes back, restart"
  greset_all "$W/golden-userdata-blank.img"
  gplant_root golden
  gplant_reinstall
  gset_param "$GF/param-loader.img"
  local before after
  before=$(gdisk_sums_noud)
  grun greinst-roll
  local rc=$GRC
  after=$(gdisk_sums_noud)
  detach_inner_loops
  check "restart after the rollback (exit 99, got $rc)" test "$rc" -eq 99
  check "logged: the root set aside, the request file removed" \
    log_has greinst-roll "golden: USERDATA/omarchy-arm64 set aside as omarchy-arm64.previous, media/0/linux/reinstall removed"
  check "logged: the copy failed" log_has greinst-roll "ERROR: golden: copying the image failed"
  check "logged: omarchy-arm64.previous put back as omarchy-arm64" \
    log_has greinst-roll "golden: the reinstall stopped before the new root was in place: omarchy-arm64.previous put back as omarchy-arm64"
  check "said on screen: the installed system was put back" \
    log_has greinst-roll "t715-say: The reinstall stopped (its log: linux/omarchy-arm64-install.log in the internal storage). The installed system was put back as it was; the tablet restarts into it."
  check "rebooting-in-N said on screen" log_has greinst-roll "t715-say: rebooting in 2 seconds"
  check "PARAM, SYSTEM, CACHE byte-identical" test "$before" = "$after"
  check "the kept root is back as omarchy-arm64, its marker unchanged" gmarker_ok omarchy-arm64
  check "omarchy-arm64.previous is gone" gwith_userdata test ! -e "$W/gud/omarchy-arm64.previous"
  check "linux/reinstall is gone (removed before the install)" gwith_userdata test ! -e "$W/gud/media/0/linux/reinstall"
  [[ $rc -eq 99 ]] || show_log greinst-roll
  ip link del usb0 2>/dev/null || true
}

# scenario_golden_interrupted: an interrupted reinstall's next start (the
# old root already at omarchy-arm64.previous, no omarchy-arm64, no request
# file, the loader in PARAM): a plain "loader in PARAM, not installed"
# install, carrying the saved stock PARAM over from .previous.
scenario_golden_interrupted() {
  echo "--- scenario: golden, an interrupted reinstall (old root at omarchy-arm64.previous, no request file)"
  greset_all
  gplant_root golden
  gwith_userdata mv "$W/gud/omarchy-arm64" "$W/gud/omarchy-arm64.previous"
  gset_param "$GF/param-loader.img"
  local param_before
  param_before=$(gpart_sum 2048 16384)
  grun greinst-int
  local rc=$GRC
  detach_inner_loops
  check "restart after the install (exit 99, got $rc)" test "$rc" -eq 99
  check "logged: the loader in PARAM, the system not installed" \
    log_has greinst-int "golden: the loader is in PARAM, the system is not installed: installing it"
  check "no reinstall asked (no request file)" sh -c "! grep -q 'asks for a reinstall' '$W/greinst-int.log'"
  check "logged: the saved stock PARAM carried over from omarchy-arm64.previous" \
    log_has greinst-int "golden: the saved stock PARAM carried over from omarchy-arm64.previous"
  check "logged: slot A, generation 1" log_has greinst-int "golden: the kernel's slot, generation 1, to sector 131072 of CACHE"
  check "said on screen: installed, restarting" log_has greinst-int "t715-say: Omarchy is installed. Restarting into it..."
  check "PARAM byte-identical to before (the loader left as it is)" test "$(gpart_sum 2048 16384)" = "$param_before"
  check "PARAM still holds the loader" \
    test "$(gparam_loader_sum)" = "$(head -c "$GEXTENT" "$(g_param_dev)" | sha256sum | cut -d' ' -f1)"
  check "slot A is a valid header of generation 1" test "$(gslot_gen "$(g_cache_dev)" 131072)" = 1
  check "the new root holds the image's tree and the markers" gwith_userdata sh "$W/gcheck-tree.sh" "$W/gud"
  # shellcheck disable=SC2016  # expanded by the sh -c script
  check "the new root's saved stock PARAM is the one from omarchy-arm64.previous, mode 600" gwith_userdata sh -c '
    cmp -s "$1/omarchy-arm64/var/lib/t715/PARAM-stock.img" "$1/omarchy-arm64.previous/var/lib/t715/PARAM-stock.img" &&
    cmp -s "$1/omarchy-arm64/var/lib/t715/PARAM-stock.img" "$2/param-stock.img" &&
    [ "$(stat -c %a "$1/omarchy-arm64/var/lib/t715/PARAM-stock.img")" = 600 ]
  ' sh "$W/gud" "$GF"
  check "omarchy-arm64.previous is still there, untouched" gmarker_ok omarchy-arm64.previous
  [[ $rc -eq 99 ]] || show_log greinst-int
  ip link del usb0 2>/dev/null || true
}

with_userdata() {
  mkdir -p "$W/ud"
  blockdev --setrw "$(node "$OUTER")p3" || return 1
  mount "$(node "$OUTER")p3" "$W/ud" || return 1
  local rc=0
  "$@" || rc=$?
  umount "$W/ud"
  return "$rc"
}
select_persist() { printf 'rootfs-alt.img\npersist=omarchy\n' >"$W/ud/media/0/linux/rootfs.select"; }
plant_partial_seed() { mkdir -p "$W/ud/.omarchy.t715-seed/half" && echo partial >"$W/ud/.omarchy.t715-seed/half/file"; }
# plant_sidecar KIND: a sha256sum sidecar for the selected image
# (rootfs-alt.img), written in one of the ways a host writes it.
#   good      sha256sum output: the right hash, two spaces, LF
#   bad       the same but a syntactically valid wrong hash
#   crlf      the right hash, two spaces, CR LF line ending
#   windows   Notepad plus Get-FileHash: a UTF-8 BOM, the right hash in
#             upper case, two spaces, CR LF, then one more empty CR LF line
#   crlf-bad  crlf with a wrong hash
#   two-lines the image's correct line, then a second valid-looking line
#             naming another file, LF endings (a whole SHA256SUMS in short)
plant_sidecar() {
  local kind=$1 h zeros
  h=$(sha256sum "$W/ud/media/0/linux/rootfs-alt.img" | cut -d' ' -f1)
  case "$kind" in
  bad | crlf-bad)
    zeros=$(printf '%063d' 0)
    h="${zeros}${h: -1}"
    ;;
  esac
  case "$kind" in
  good) printf '%s  rootfs-alt.img\n' "$h" ;;
  bad) printf '%s  rootfs-alt.img\n' "$h" ;;
  crlf) printf '%s  rootfs-alt.img\r\n' "$h" ;;
  crlf-bad) printf '%s  rootfs-alt.img\r\n' "$h" ;;
  windows) printf '\xef\xbb\xbf%s  rootfs-alt.img\r\n\r\n' "${h^^}" ;;
  two-lines) printf '%s  rootfs-alt.img\n%s  other.img\n' "$h" "$h" ;;
  *) echo "plant_sidecar: unknown kind $kind" >&2; return 1 ;;
  esac >"$W/ud/media/0/linux/rootfs-alt.img.sha256"
}
# fill_userdata: eat USERDATA's free space until the seed's check (the
# image's use, about 1.4 MiB, + the test's 1 MiB margin) fails: one file
# sized to leave well under 2 MiB free.
fill_userdata() {
  local free want
  free=$(df -Pk "$W/ud" | awk 'NR == 2 {print $4}')
  want=$((free - 1024))
  ((want > 0)) || return 0
  dd if=/dev/zero of="$W/ud/t715-fill" bs=1024 count=$want status=none || return 1
  sync
  [[ "$(df -Pk "$W/ud" | awk 'NR == 2 {print $4}')" -lt 2304 ]]
}
# userdata_sum: USERDATA's content checksum (its files, not the raw
# partition: a persistent-root boot remounts it read-write).  Runs inside
# with_userdata; see the sidecar scenario.
userdata_sum() {
  (cd "$W/ud" && find . -type f -print0 | sort -z | xargs -0 cat | sha256sum | cut -d' ' -f1)
}
persist_state() {
  echo "marker=$(head -n 1 "$W/ud/omarchy/.t715-persist" 2>/dev/null)"
  echo "boots=$(cat "$W/ud/omarchy/var/t715-boots" 2>/dev/null)"
  local n=0 d
  for d in "$W/ud"/.*.t715-seed; do [[ -e "$d" ]] && n=$((n + 1)); done
  echo "leftover=$n"
}
PERSIST_KNOBS="t715.rootwait=30 t715.modblacklist=pci_exynos,brcmfmac t715.autotest=1"

scenario_persist_seed() {
  echo "--- scenario: persistent root, first boot (seed over an interrupted one)"
  if ! with_userdata select_persist || ! with_userdata plant_partial_seed; then
    ko "rootfs.select line 2 and a partial seed written"; return
  fi
  prepare_boot pseed
  local rc=0
  run_init pseed "$PERSIST_KNOBS" || rc=$?
  check "switch_root reached the seeded /sbin/init (exit $rc)" test "$rc" -eq 0
  check "persistent root checks pass" log_has pseed "T715TEST RESULT: PASS"
  check "mode persist, first boot" log_has pseed "T715TEST boots=1"
  check "rootfs.select line 2 followed" log_has pseed "rootfs.select: persistent root omarchy"
  check "e2fsck ran clean" log_has pseed "e2fsck exit 0"
  check "interrupted seed removed" log_has pseed "removing an interrupted seed"
  check "seed logged" log_has pseed "seeding USERDATA/omarchy from media/0/linux/rootfs-alt.img"
  check "seed start said on screen" log_has pseed "t715-say: Setting up Omarchy (first boot), this takes a few minutes"
  check "seed progress said on screen (1-99%)" sh -c "grep -E 't715-say: Setting up Omarchy \(first boot\): [0-9]+%' '$W/pseed.log' >/dev/null"
  check "seed end said on screen" log_has pseed "t715-say: Setup finished. Starting Omarchy."
  check "rw mount logged" log_has pseed "USERDATA mounted rw,noatime,errors=remount-ro"
  local st
  st=$(with_userdata persist_state)
  check "marker names the root and its image" grep -qx "marker=persistent root omarchy, seeded from media/0/linux/rootfs-alt.img" <<<"$st"
  check "no seed directory left" grep -qx "leftover=0" <<<"$st"
  check "boot counter written to USERDATA" grep -qx "boots=1" <<<"$st"
  [[ $rc -eq 0 ]] || show_log pseed
  grep -E "T715TEST (ok|FAIL)" "$W/pseed.log" | sed 's/^/        /'
  ip link del usb0 2>/dev/null || true
}

scenario_persist_again() {
  echo "--- scenario: persistent root, second boot"
  prepare_boot pagain
  local rc=0
  run_init pagain "$PERSIST_KNOBS" || rc=$?
  check "switch_root reached /sbin/init (exit $rc)" test "$rc" -eq 0
  check "persistent root checks pass" log_has pagain "T715TEST RESULT: PASS"
  check "state kept: second boot counted" log_has pagain "T715TEST boots=2"
  check "no second seed" sh -c "! grep -q 'seeding USERDATA' '$W/pagain.log'"
  check "module tree kept (stamp matches)" log_has pagain "up to date in the persistent root"
  [[ $rc -eq 0 ]] || show_log pagain
  ip link del usb0 2>/dev/null || true
}

scenario_persist_rescue() {
  echo "--- scenario: t715.persist=0 (rescue: image mode despite rootfs.select)"
  prepare_boot prescue
  local rc=0
  run_init prescue "$PERSIST_KNOBS t715.persist=0" || rc=$?
  check "switch_root reached the image's /sbin/init (exit $rc)" test "$rc" -eq 0
  check "image mode checks pass" log_has prescue "T715TEST RESULT: PASS"
  check "mode image" log_has prescue "T715TEST mode=image"
  check "knob logged" log_has prescue "t715.persist=0: image mode, USERDATA read-only"
  [[ $rc -eq 0 ]] || show_log prescue
  detach_inner_loops
  ip link del usb0 2>/dev/null || true
}

scenario_persist_foreign() {
  echo "--- scenario: t715.persist=media (exists, no marker: refused)"
  prepare_boot pforeign
  local rc=0
  run_init pforeign "$PERSIST_KNOBS t715.persist=media" || rc=$?
  check "switch_root reached the image's /sbin/init (exit $rc)" test "$rc" -eq 0
  check "image mode checks pass" log_has pforeign "T715TEST RESULT: PASS"
  check "mode image" log_has pforeign "T715TEST mode=image"
  check "directory refused" log_has pforeign "USERDATA/media exists but is not a persistent root"
  check "fallback logged" log_has pforeign "booting the image read-only instead"
  [[ $rc -eq 0 ]] || show_log pforeign
  detach_inner_loops
  ip link del usb0 2>/dev/null || true
}

# scenario_persist_sidecar KIND: the .sha256 sidecar next to the selected
# image, verified before the seed.  good and crlf/windows are accepted
# (the seed runs); bad, crlf-bad and two-lines are refused (image mode,
# USERDATA untouched).  Runs after scenario_persist_seed/again/rescue/
# foreign, whose omarchy root must be removed first (that is the machine's
# state at the factory: image present, no root).
scenario_persist_sidecar() {
  local kind=$1
  echo "--- scenario: persistent root, first boot, $kind .sha256 sidecar"
  if ! with_userdata select_persist || ! with_userdata plant_sidecar "$kind" ||
    ! with_userdata rm -rf "$W/ud/omarchy"; then
    ko "rootfs.select line 2 and the sidecar written"; return
  fi
  # USERDATA's content checksum before the boot: a refused sidecar must
  # leave the partition byte-identical (the check runs while it is
  # read-only).
  local sum_before
  sum_before=$(with_userdata userdata_sum)
  prepare_boot "pside-$kind"
  local rc=0
  run_init "pside-$kind" "$PERSIST_KNOBS" || rc=$?
  # An image-mode fallback leaves the image's loop attached (the namespace
  # dies at the hand-over): detach it before mounting USERDATA again, or
  # the loop's open file keeps the mount busy.
  detach_inner_loops
  case "$kind" in
  good | crlf | windows)
    check "switch_root reached the seeded /sbin/init (exit $rc)" test "$rc" -eq 0
    check "checksum verified" log_has "pside-$kind" "image checksum verified"
    check "Checking-the-image said on screen" log_has "pside-$kind" "t715-say: Checking the image..."
    check "persistent root checks pass" log_has "pside-$kind" "T715TEST RESULT: PASS"
    local st
    st=$(with_userdata persist_state)
    check "seed did run (marker present)" grep -qx "marker=persistent root omarchy, seeded from media/0/linux/rootfs-alt.img" <<<"$st"
    ;;
  bad | crlf-bad)
    check "fell back to image mode (exit $rc)" test "$rc" -eq 0
    check "image mode checks pass" log_has "pside-$kind" "T715TEST RESULT: PASS"
    check "mode image" log_has "pside-$kind" "T715TEST mode=image"
    check "checksum refused" log_has "pside-$kind" "ERROR: image checksum check failed: checksum mismatch"
    check "damage said on screen" log_has "pside-$kind" "t715-say: The image file is damaged (bad checksum). Copy it to the tablet again."
    check "no seed directory created" sh -c "! grep -q 'seeding USERDATA' '$W/pside-$kind.log'"
    local st
    st=$(with_userdata persist_state)
    check "no persistent root created" grep -qx "marker=" <<<"$st"
    check "no seed directory left" grep -qx "leftover=0" <<<"$st"
    check "USERDATA's files untouched (checksum unchanged)" test "$sum_before" = "$(with_userdata userdata_sum)"
    ;;
  two-lines)
    check "fell back to image mode (exit $rc)" test "$rc" -eq 0
    check "image mode checks pass" log_has "pside-$kind" "T715TEST RESULT: PASS"
    check "mode image" log_has "pside-$kind" "T715TEST mode=image"
    check "sidecar refused as malformed" log_has "pside-$kind" "ERROR: malformed checksum file"
    check "damage said on screen" log_has "pside-$kind" "t715-say: The image file is damaged (bad checksum). Copy it to the tablet again."
    check "no seed directory created" sh -c "! grep -q 'seeding USERDATA' '$W/pside-$kind.log'"
    local st
    st=$(with_userdata persist_state)
    check "no persistent root created" grep -qx "marker=" <<<"$st"
    check "no seed directory left" grep -qx "leftover=0" <<<"$st"
    check "USERDATA's files untouched (checksum unchanged)" test "$sum_before" = "$(with_userdata userdata_sum)"
    ;;
  esac
  [[ $rc -eq 0 ]] || show_log "pside-$kind"
  detach_inner_loops
  ip link del usb0 2>/dev/null || true
}

scenario_persist_space() {
  echo "--- scenario: persistent root, first boot, not enough space on USERDATA"
  if ! with_userdata select_persist || ! with_userdata rm -rf "$W/ud/omarchy" ||
    ! with_userdata rm -f "$W/ud/media/0/linux/rootfs-alt.img.sha256"; then
    ko "rootfs.select line 2 written"; return
  fi
  if ! with_userdata fill_userdata; then
    ko "USERDATA filled"; return
  fi
  prepare_boot pspace
  local rc=0
  run_init pspace "$PERSIST_KNOBS" || rc=$?
  detach_inner_loops
  check "fell back to image mode (exit $rc)" test "$rc" -eq 0
  check "image mode checks pass" log_has pspace "T715TEST RESULT: PASS"
  check "mode image" log_has pspace "T715TEST mode=image"
  check "space refusal logged" log_has pspace "ERROR: USERDATA has"
  check "fallback logged" log_has pspace "booting the image read-only instead"
  check "not-enough-space said on screen" sh -c "grep -qE 't715-say: Not enough free space: running from the image; changes are lost at reboot\. Free about [0-9]+ GB and restart' '$W/pspace.log'"
  check "the fill file is still there (nothing removed)" with_userdata test -f "$W/ud/t715-fill"
  local st
  st=$(with_userdata persist_state)
  check "no seed directory left" grep -qx "leftover=0" <<<"$st"
  [[ $rc -eq 0 ]] || show_log pspace
  detach_inner_loops
  ip link del usb0 2>/dev/null || true
}

scenario_nouserdata() {
  echo "--- scenario: no USERDATA partition"
  prepare_boot nouserdata
  local rc=0
  run_init nouserdata "t715.rootwait=2 t715.failwait=1" || rc=$?
  check "rebooted (exit 99, got $rc)" test "$rc" -eq 99
  check "timeout logged" log_has nouserdata "ERROR: no partition named USERDATA after 2s"
  [[ $rc -eq 99 ]] || show_log nouserdata
  ip link del usb0 2>/dev/null || true
}

# A second disk also named USERDATA beside the first: the boot must refuse
# to guess (both are kept devices here: loop disks carry no mmc marks, so
# this is the "two USERDATA on the eMMC's side" case the eMMC-only lookup
# must not weaken).  The second disk is a small GPT with USERDATA alone.
scenario_two_userdata() {
  echo "--- scenario: two partitions named USERDATA (refused)"
  truncate -s 16M "$W/disk2.img"
  sfdisk -q "$W/disk2.img" <<'EOF2'
label: gpt
start=2048, size=4096, name=USERDATA
EOF2
  local n
  n=$(losetup -f)
  losetup -P "$(node "$n")" "$W/disk2.img"
  LOOPS+=("$n")
  local i
  for ((i = 0; i < 20; i++)); do
    grep -qx "PARTNAME=USERDATA" "/sys/class/block/${n#/dev/}p1/uevent" 2>/dev/null && break
    sleep 0.5
  done
  prepare_boot twoud
  local rc=0
  run_init twoud "t715.rootwait=2 t715.failwait=1" || rc=$?
  check "rebooted after failwait (exit 99, got $rc)" test "$rc" -eq 99
  check "refusal logged" log_has twoud "ERROR: several partitions are named USERDATA"
  [[ $rc -eq 99 ]] || show_log twoud
  losetup -d "$(node "$n")"
  LOOPS=("${LOOPS[@]:0:${#LOOPS[@]}-1}")
  ip link del usb0 2>/dev/null || true
}

# check_list_partnames: the eMMC-only partition lookup, against a fake
# /sys.  The function is extracted from the unpacked /init (the same bytes
# the boot scenarios run) and run by the cpio's busybox sh, with
# /sys/class/block pointed at a tree holding an eMMC (15540000.mmc,
# mmcblk0p*), a microSD card that looks like a clone of a tablet's eMMC
# (15560000.mmc, mmcblk1p*, USERDATA and SYSTEM among its names) and a
# plain loop disk (as the scenarios see their own).  The card's names must
# be ignored, the eMMC's and the loop disk's kept.
check_list_partnames() {
  local S="$W/fake-sys"
  rm -rf "$S" "$W/root-lp"
  mkdir -p "$S/class/block" "$W/root-lp"
  (cd "$W/root-lp" && gzip -dc "$CPIO" | cpio -idm --quiet --no-absolute-filenames)
  sed -n '/^list_partnames()/,/^}/p' "$W/root-lp/init" \
    | sed "s|/sys/class/block|$S/class/block|g" >"$W/lp.sh"
  local emmc="$S/devices/platform/soc@0/15540000.mmc/mmc_host/mmc0:0001/block/mmcblk0"
  local card="$S/devices/platform/soc@0/15560000.mmc/mmc_host/mmc1:0001/block/mmcblk1"
  # lp_mk HOSTDIR NAME PARTNAME: one block device of the fake tree.
  lp_mk() { # HOSTDIR NAME PARTNAME
    mkdir -p "$1/$2"
    printf 'MAJOR=179\nMINOR=8\nDEVNAME=%s\nPARTNAME=%s\n' "$2" "$3" >"$1/$2/uevent"
    ln -s "$1/$2" "$S/class/block/$2"
  }
  lp_mk "$emmc" mmcblk0p1 EFS
  lp_mk "$emmc" mmcblk0p3 USERDATA
  lp_mk "$emmc" mmcblk0p5 SYSTEM
  lp_mk "$card" mmcblk1p1 RADIO
  lp_mk "$card" mmcblk1p3 USERDATA
  lp_mk "$card" mmcblk1p4 SYSTEM
  lp_mk "$card" mmcblk1p6 BOOT
  mkdir -p "$S/devices/virtual/block/loop0/loop0p3"
  printf 'DEVNAME=loop0p3\nPARTNAME=USERDATA\n' >"$S/devices/virtual/block/loop0/loop0p3/uevent"
  ln -s "$S/devices/virtual/block/loop0/loop0p3" "$S/class/block/loop0p3"
  "$W/x/bin/busybox" sh -c ". '$W/lp.sh'; list_partnames" >"$W/lp.out" 2>/dev/null
  check "a cloned-eMMC card's USERDATA ignored (no mmcblk1p3)" \
    sh -c "! grep -q '^mmcblk1p3 ' '$W/lp.out'"
  check "the card's SYSTEM ignored (no mmcblk1p4)" \
    sh -c "! grep -q '^mmcblk1p4 ' '$W/lp.out'"
  check "the card's RADIO and BOOT ignored too" sh -c "! grep -q '^mmcblk1' '$W/lp.out'"
  check "the eMMC's USERDATA still found" grep -qx 'mmcblk0p3 USERDATA' "$W/lp.out"
  check "the eMMC's SYSTEM still found" grep -qx 'mmcblk0p5 SYSTEM' "$W/lp.out"
  check "a disk without an mmc host still listed (the scenarios' loop)" \
    grep -qx 'loop0p3 USERDATA' "$W/lp.out"
  rm -rf "$S" "$W/root-lp"
}

in_container() {
  CPIO=$1
  trap container_cleanup EXIT
  mkdir -p "$W"
  # 1g: the golden disk's CACHE alone is 200 MiB, and the resets write it
  # through the loop device (no holes left).
  mount -t tmpfs -o size=1g,mode=0755 t715-test "$W"
  mkdir -p "$W/dev"
  mount -t devtmpfs devtmpfs "$W/dev"
  # A plain file named like a partition, left by a run that wrote before the
  # node was there, hides the partition in every later run of this machine.
  local stale backing
  for stale in "$W"/dev/loop*p[0-9]*; do
    if [ -f "$stale" ]; then
      echo "        removed a stale file from devtmpfs: ${stale##*/}"
      rm -f "$stale"
    fi
  done
  # A loop device still attached to a test disk whose run was interrupted
  # (its image is gone) would bring a second USERDATA to every boot.
  for stale in $(losetup -a 2>/dev/null | awk -F: '{print $1}'); do
    backing=$(losetup -n "$(node "$stale")" 2>/dev/null) || continue
    case ${backing##*/} in
    disk*.img)
      if [ ! -e "$backing" ]; then
        echo "        detached a leftover loop device: $stale (${backing##*/} is gone)"
        losetup -d "$(node "$stale")" 2>/dev/null || true
      fi
      ;;
    esac
  done

  echo "--- fixtures"
  make_fixtures
  local before after l
  before=$(disk_sums)
  while read -r l; do echo "        sha256 before: $l"; done <<<"$before"
  if attach_disk; then ok "synthetic GPT disk on $OUTER, ${OUTER#/dev/}p3 named USERDATA"
  else ko "synthetic GPT disk attached"; return 1; fi

  scenario_shell
  scenario_direct
  scenario_missing
  scenario_failwait_screen
  scenario_badpath
  detach_inner_loops

  after=$(disk_sums)
  while read -r l; do echo "        sha256 after:  $l"; done <<<"$after"
  check "USERDATA and disk image byte-identical after the read-only boots" test "$before" = "$after"

  scenario_persist_seed
  scenario_persist_again
  scenario_persist_rescue
  scenario_persist_foreign
  scenario_persist_sidecar good
  scenario_persist_sidecar bad
  scenario_persist_sidecar crlf
  scenario_persist_sidecar windows
  scenario_persist_sidecar crlf-bad
  scenario_persist_sidecar two-lines
  scenario_persist_space
  detach_inner_loops
  # The loader's rescue: it writes PARAM only in its one case.
  scenario_param_off
  scenario_param_stock
  scenario_param_known
  scenario_param_unknown
  scenario_param_nofiles
  scenario_param_wrongimage
  scenario_param_ro
  scenario_param_roflag
  scenario_param_extent_loader
  scenario_param_extent_stock
  scenario_param_extent_unknown
  scenario_param_also
  scenario_param_extent_bad
  set_param /t/param-known.img
  # Two disks both carrying USERDATA, the outer one still attached: the
  # boot must refuse to guess (both are plain disks here, so this is the
  # refusal the eMMC-only lookup must keep once a card's names are out).
  scenario_two_userdata
  detach_disk
  check_list_partnames
  scenario_nouserdata
  scenario_param_nopart

  # --- the installer of the 64-bit system (t715.golden): its own disk ---
  make_golden_fixtures
  scenario_golden_forge_python
  scenario_golden_members_python
  scenario_golden_cross_pair
  if attach_disk "$W/disk-golden.img" 4; then
    ok "the golden synthetic disk on $OUTER, ${OUTER#/dev/}p4 named USERDATA"
  else
    ko "the golden synthetic disk attached"; return 1
  fi
  scenario_golden_fresh
  scenario_golden_resume
  scenario_golden_handback
  scenario_golden_rescue
  scenario_golden_unknown_param
  scenario_golden_param_tail
  scenario_golden_param_tail_b
  scenario_golden_param_other
  scenario_golden_rescue_tail
  scenario_golden_stock_b
  scenario_golden_handback_b
  scenario_golden_rescue_b
  scenario_golden_wrong_bootloader
  scenario_golden_no_sidecar
  scenario_golden_bad_sidecar
  scenario_golden_not_aarch64
  scenario_golden_slots_there
  scenario_golden_foreign_root
  scenario_golden_reinstall
  scenario_golden_reinstall_previous
  scenario_golden_reinstall_noimg
  scenario_golden_reinstall_badsum
  scenario_golden_reinstall_space
  scenario_golden_reinstall_rollback
  scenario_golden_interrupted
  detach_disk
  detach_inner_loops

  sync
  dd if="$W/disk.img" of="$W/ud-check.img" bs=512 skip=12288 count=131072 status=none
  check "USERDATA fsck clean after the persistent boots (e2fsck -fn)" e2fsck -fn "$W/ud-check.img"

  echo "--- container: $NPASS passed, $NFAIL failed"
  [[ $NFAIL -eq 0 ]]
}

if [[ "${T715_TEST_SOURCE_ONLY:-}" == 1 ]]; then
  # shellcheck disable=SC2317  # reached when the script is sourced
  return 0  # the functions only, for an ad hoc run inside the test container
elif [[ "${1:-}" == --in-container ]]; then
  in_container "$2"
  exit
fi

# ===========================================================================
# host side (macOS or Linux, Docker)
# ===========================================================================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/t715-initramfs-test.XXXXXX")"
# Optional: when other jobs use the Docker machine's loop devices too,
# T715_LOOP_LOCK names a directory they all take (mkdir) before attaching any:
# the suite waits for it, and gives it back as soon as the run ends.
LOCKDIR="${T715_LOOP_LOCK:-}"
if [[ -n "$LOCKDIR" ]]; then
  until mkdir "$LOCKDIR" 2>/dev/null; do sleep 20; done
fi
trap 'rm -rf "$TMP"; [[ -z "$LOCKDIR" ]] || rmdir "$LOCKDIR" 2>/dev/null || true' EXIT
HFAIL=0

echo "=== 1. reproducible build"
bash "$ROOT/boot/build-initramfs.sh" --out "$TMP/a" >"$TMP/build-a.log" 2>&1 \
  || { cat "$TMP/build-a.log"; exit 1; }
bash "$ROOT/boot/build-initramfs.sh" --out "$TMP/b" >"$TMP/build-b.log" 2>&1 \
  || { cat "$TMP/build-b.log"; exit 1; }
grep -E '^>>> (file|readelf|cpio):' "$TMP/build-a.log" | sed 's/^/        /'
if cmp -s "$TMP/a/initramfs.cpio.gz" "$TMP/b/initramfs.cpio.gz"; then
  echo "  PASS  two builds byte-identical ($(cut -d' ' -f1 "$TMP/a/SHA256SUMS"))"
else
  echo "  FAIL  two builds differ"; HFAIL=$((HFAIL + 1))
fi
SIZE=$(wc -c <"$TMP/a/initramfs.cpio.gz" | tr -d ' ')
echo "        initramfs.cpio.gz: $SIZE bytes ($((SIZE / 1024)) KiB)"

echo "=== 1b. build with --paramrescue (the loader the rescue puts back)"
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
# Two PARAM images of the tablet's size: the loader the rescue knows, and
# what the stock PARAM would be.
head -c 8388608 /dev/urandom >"$TMP/param-known.img"
head -c 8388608 /dev/urandom >"$TMP/param-stock.img"
STOCK_SHA=$(sha256_of "$TMP/param-stock.img")
for d in r s; do
  bash "$ROOT/boot/build-initramfs.sh" --out "$TMP/$d" --paramrescue "$TMP/param-known.img" \
    --paramrescue-stock "$STOCK_SHA" >"$TMP/build-$d.log" 2>&1 || { cat "$TMP/build-$d.log"; exit 1; }
done
if cmp -s "$TMP/r/initramfs.cpio.gz" "$TMP/s/initramfs.cpio.gz"; then
  echo "  PASS  two builds with --paramrescue byte-identical"
else
  echo "  FAIL  two builds with --paramrescue differ"; HFAIL=$((HFAIL + 1))
fi
for f in lib/t715-paramrescue/param.img.gz lib/t715-paramrescue/loader.sha256 lib/t715-paramrescue/stock.sha256; do
  if grep -q " $f\$" "$TMP/r/initramfs.manifest.txt"; then echo "  PASS  the archive has $f"
  else echo "  FAIL  the archive lacks $f"; HFAIL=$((HFAIL + 1)); fi
done
refused() {  # DESCRIPTION COMMAND...
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then echo "  FAIL  $d: built"; HFAIL=$((HFAIL + 1))
  else echo "  PASS  $d: refused"; fi
}
refused "--paramrescue without --paramrescue-stock" \
  bash "$ROOT/boot/build-initramfs.sh" --out "$TMP/x-none" --paramrescue "$TMP/param-known.img"
refused "--paramrescue with a malformed sha256" \
  bash "$ROOT/boot/build-initramfs.sh" --out "$TMP/x-short" --paramrescue "$TMP/param-known.img" --paramrescue-stock abc
refused "--paramrescue with no such image" \
  bash "$ROOT/boot/build-initramfs.sh" --out "$TMP/x-missing" --paramrescue "$TMP/no-such.param" \
  --paramrescue-stock "$STOCK_SHA"
# The loader as only the first half of the image: reproducible, and with its
# length.  The stock image's sha256 is of its first half too.
head -c 4194304 "$TMP/param-stock.img" >"$TMP/param-stock-head.img"
STOCK_HEAD_SHA=$(sha256_of "$TMP/param-stock-head.img")
head -c 8388608 /dev/urandom >"$TMP/param-third.img"      # a loader the rescue only leaves alone
for d in e f; do
  bash "$ROOT/boot/build-initramfs.sh" --out "$TMP/$d" --paramrescue "$TMP/param-known.img" \
    --paramrescue-stock "$STOCK_HEAD_SHA" --paramrescue-extent 4194304 --paramrescue-also "$TMP/param-third.img" \
    >"$TMP/build-$d.log" 2>&1 || { cat "$TMP/build-$d.log"; exit 1; }
done
if cmp -s "$TMP/e/initramfs.cpio.gz" "$TMP/f/initramfs.cpio.gz"; then
  echo "  PASS  two builds with --paramrescue-extent byte-identical"
else
  echo "  FAIL  two builds with --paramrescue-extent differ"; HFAIL=$((HFAIL + 1))
fi
for f in lib/t715-paramrescue/extent lib/t715-paramrescue/also.sha256; do
  if grep -q " $f\$" "$TMP/e/initramfs.manifest.txt"; then echo "  PASS  the archive has $f"
  else echo "  FAIL  the archive lacks $f"; HFAIL=$((HFAIL + 1)); fi
done
refused "--paramrescue-also with no such image" \
  bash "$ROOT/boot/build-initramfs.sh" --out "$TMP/x-also" --paramrescue "$TMP/param-known.img" \
  --paramrescue-stock "$STOCK_SHA" --paramrescue-extent 4194304 --paramrescue-also "$TMP/no-such.param"
refused "--paramrescue-extent 0" \
  bash "$ROOT/boot/build-initramfs.sh" --out "$TMP/x-zero" --paramrescue "$TMP/param-known.img" \
  --paramrescue-stock "$STOCK_SHA" --paramrescue-extent 0
refused "--paramrescue-extent beyond the image" \
  bash "$ROOT/boot/build-initramfs.sh" --out "$TMP/x-beyond" --paramrescue "$TMP/param-known.img" \
  --paramrescue-stock "$STOCK_SHA" --paramrescue-extent 99999999
refused "--paramrescue-extent not a number" \
  bash "$ROOT/boot/build-initramfs.sh" --out "$TMP/x-words" --paramrescue "$TMP/param-known.img" \
  --paramrescue-stock "$STOCK_SHA" --paramrescue-extent half

echo "=== 1c. the golden installer's fixtures (synthetic) and its build (--golden)"
# python3 builds them: a fake logo.jpg, a stock PARAM image whose first
# EXTENT bytes are a ustar tar of the pictures (Python's tarfile) followed by
# S-Boot's own marker data, the two sha256 (stock's, and loader's: what
# boot/golden/check-param.py's forge returns with the fake logo), extent,
# bootloader, release, the forged loader image, the kernel's slot of the root
# image (with the FNV-1a 64 of the image, the tree and the header) and the
# fixed inputs for the init's fnv1a64 with Python's answers.
command -v python3 >/dev/null 2>&1 || { echo "  FAIL  python3 is needed to build the golden fixtures"; exit 1; }
cat >"$TMP/gen_golden_fixtures.py" <<'PY'
#!/usr/bin/env python3
"""Build the synthetic fixtures of the golden installer's tests."""
import hashlib, importlib.util, io, os, shutil, sys, tarfile
from pathlib import Path

out = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("check_param", sys.argv[2])
cp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cp)

EXTENT = 7340032                 # the loader's part of PARAM
DISK = 8 * 1024 * 1024           # PARAM is 8 MiB

(out / "golden").mkdir(parents=True, exist_ok=True)
# logo.jpg: a fake JPEG of a few KiB, a size that is not a multiple of 512
logo = b"\xff\xd8" + bytes(((i * 7 + 3) & 0xFF) for i in range(3000))
(out / "golden" / "logo.jpg").write_bytes(logo)

# the stock PARAM: a ustar archive of the pictures S-Boot shows, zero-padded
# to EXTENT, then S-Boot's own data (never touched by the installer)
pictures = [
    ("adv-env.img", bytes(range(256)) * 4),
    ("download.jpg", b"\xff\xd8\xff\xe0" + bytes((i * 13) & 0xFF for i in range(2048))),
    ("logo.jpg", b"\xff\xd8" + bytes((i * 11 + 5) & 0xFF for i in range(4096))),
    ("lpm.jpg", b"\xff\xd8" + bytes((i * 3 + 1) & 0xFF for i in range(1024))),
    ("warning.jpg", b"\xff\xd8" + bytes((i * 5 + 2) & 0xFF for i in range(1536))),
]
def ustar(members, mtime=0):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.USTAR_FORMAT) as tf:
        for name, data in members:
            ti = tarfile.TarInfo(name)
            ti.size = len(data)
            ti.mtime = mtime            # 0 (TarInfo's default) for the first stock PARAM: its bytes stay as they were
            tf.addfile(ti, io.BytesIO(data))
    return buf.getvalue()
stock = ustar(pictures)
assert len(stock) <= EXTENT, len(stock)
stock = stock + bytes(EXTENT - len(stock))
m = b"S-Boot data after the loader's part, kept as it is. "
marker = (m * (DISK // len(m) + 1))[:DISK - EXTENT]
assert len(marker) == DISK - EXTENT and marker.strip(b"\0")
stock_full = stock + marker
(out / "param-stock.img").write_bytes(stock_full)

# The second stock PARAM of the firmware (T715XXU2CRH1 as Odin flashes it: the
# BL's param.bin), the way the two differ on a tablet: the same members in the
# same order and the same data, but another logo.jpg (other data, another
# size, not a multiple of 512 either) and another date in every header.  Only
# the dates differ here in the headers; the forged loaders differ in the same
# fields (logo.jpg's data, size and checksum, and the mtime of each header).
logo_b = b"\xff\xd8" + bytes(((i * 29 + 17) & 0xFF) for i in range(5113))
pictures_b = [(name, logo_b if name == "logo.jpg" else data) for name, data in pictures]
stock_b = ustar(pictures_b, mtime=1533235200)        # 2018-08-03, a date of the firmware's own
assert len(stock_b) <= EXTENT, len(stock_b)
assert len(logo_b) % 512 != 0 and logo_b != pictures[2][1]
stock_b = stock_b + bytes(EXTENT - len(stock_b))
stock_b_full = stock_b + marker
(out / "param-stock-b.img").write_bytes(stock_b_full)

# the stock archive's members, as the build's --golden wants them (what
# check-param.py --members prints), and where the archive ends: the tests
# read both, instead of trusting this script's arithmetic
stock_members, archive_end = cp.members(stock, EXTENT)
(out / "golden" / "stock.members").write_text(
    "".join(f"{digest} {size} {name}\n" for name, size, digest in stock_members))
(out / "stock.end").write_text(f"{archive_end}\n")
_, archive_end_b = cp.members(stock_b, EXTENT)
(out / "stock-b.end").write_text(f"{archive_end_b}\n")

# a PARAM whose archive is the stock one, but with a run of non-zero bytes
# after the archive's end (an earlier write left them there; S-Boot reads
# the archive only)
tail_run = b"leftover bytes of an older PARAM"
assert b"\0" not in tail_run and archive_end <= 1048576 and 1048576 + len(tail_run) <= EXTENT
tail = bytearray(stock_full)
tail[1048576:1048576 + len(tail_run)] = tail_run
(out / "param-golden-tail.img").write_bytes(bytes(tail))
(out / "tail-run.bin").write_bytes(tail_run)
# the same for the second stock PARAM
tail_b = bytearray(stock_b_full)
tail_b[1048576:1048576 + len(tail_run)] = tail_run
(out / "param-golden-tail-b.img").write_bytes(bytes(tail_b))

# a PARAM whose archive is not the stock one: no lpm.jpg, no warning.jpg,
# one extra custom.jpg
custom = b"\xff\xd8" + bytes((i * 17 + 9) & 0xFF for i in range(400))
other_pictures = [p for p in pictures if p[0] not in ("lpm.jpg", "warning.jpg")] + [("custom.jpg", custom)]
other = ustar(other_pictures)
assert len(other) <= EXTENT, len(other)
other = other + bytes(EXTENT - len(other))
(out / "param-golden-other.img").write_bytes(other + marker)
(out / "custom.jpg").write_bytes(custom)
other_members, _ = cp.members(other, EXTENT)
(out / "param-other.members").write_text(
    "".join(f"{digest} {size} {name}\n" for name, size, digest in other_members))

(out / "golden" / "extent").write_text(f"{EXTENT}\n")
# stock.sha256 and loader.sha256: one line per stock PARAM, paired by line
# number.  Line 1 is the pair there has always been; line 2 is the firmware's
# own param.bin and the loader forged from it.
stock_a_sum = hashlib.sha256(stock_full[:EXTENT]).hexdigest()
stock_b_sum = hashlib.sha256(stock_b_full[:EXTENT]).hexdigest()
forged = cp.forge(stock_full[:EXTENT], logo, EXTENT)
forged_b = cp.forge(stock_b_full[:EXTENT], logo, EXTENT)
loader_a_sum = hashlib.sha256(forged).hexdigest()
loader_b_sum = hashlib.sha256(forged_b).hexdigest()
assert stock_a_sum != stock_b_sum and loader_a_sum != loader_b_sum
(out / "golden" / "stock.sha256").write_text(
    f"{stock_a_sum}  the stock PARAM reached over the air (param-stock.img)\n"
    f"{stock_b_sum}  the stock PARAM flashed with Odin (param-stock-b.img)\n")
(out / "golden" / "loader.sha256").write_text(
    f"{loader_a_sum}  the loader forged from line 1 of stock.sha256\n"
    f"{loader_b_sum}  the loader forged from line 2 of stock.sha256\n")
(out / "golden" / "bootloader").write_text("T715XXU2CRH1\n")
(out / "golden" / "release").write_text("9.9.9-test\n")
(out / "param-loader.img").write_bytes(forged + marker)
(out / "param-loader-b.img").write_bytes(forged_b + marker)

# Two golden directories whose pairing is wrong, for the tests of the refusal
# (the init's own golden_forge_checked, and check-param.py's command line):
#   golden-cross:  line 2 of loader.sha256 names the loader forged from line
#                  1's stock PARAM, so the loader of line 2 is named nowhere.
#   golden-swapped: the two loaders are on each other's line, so the loader
#                  forged from each stock PARAM is the one of another line.
for name, l1, l2 in (
        ("golden-cross", loader_a_sum, loader_a_sum),
        ("golden-swapped", loader_b_sum, loader_a_sum)):
    wrong = out / name
    wrong.mkdir()
    for f in os.listdir(out / "golden"):
        shutil.copy2(out / "golden" / f, wrong / f)
    (wrong / "loader.sha256").write_text(
        f"{l1}  line 1 of a loader.sha256 that does not pair\n"
        f"{l2}  line 2 of a loader.sha256 that does not pair\n")

# the kernel's slot carried by the root image
def fnv1a64(b):
    h = 0xCBF29CE484222325
    for x in b:
        h = ((h ^ x) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h

img = bytearray(65536)                       # a fake arm64 Image
img[0x38:0x3C] = (0x644D5241).to_bytes(4, "little")
dtb = bytearray(b"\xd0\x0d\xfe\xed" + bytes((i * 9 + 7) & 0xFF for i in range(2044)))

def slot(gen):
    le32 = lambda n: n.to_bytes(4, "little")
    fi, fd = fnv1a64(img), fnv1a64(dtb)
    hdr = bytearray(4096)
    hdr[0:4] = le32(0x314B3754); hdr[4:8] = le32(1); hdr[8:12] = le32(gen); hdr[12:16] = le32(0)
    hdr[16:20] = le32(len(img)); hdr[20:24] = le32(0x42000000)
    hdr[24:28] = le32(len(dtb)); hdr[28:32] = le32(0x5F000000)
    hdr[32:36] = le32(fi & 0xFFFFFFFF); hdr[36:40] = le32(fi >> 32)
    hdr[40:44] = le32(fd & 0xFFFFFFFF); hdr[44:48] = le32(fd >> 32)
    fh = fnv1a64(hdr[:0x30])
    hdr[48:52] = le32(fh & 0xFFFFFFFF); hdr[52:56] = le32(fh >> 32)
    pad = lambda b: b + bytes((-len(b)) % 512)
    return bytes(hdr) + pad(bytes(img)) + pad(bytes(dtb))

(out / "kernel.slot").write_bytes(slot(0))
(out / "kernel.slot.gen5").write_bytes(slot(5))
(out / "kernel-image.bin").write_bytes(img)
(out / "kernel-dtb.bin").write_bytes(dtb)

# fixed inputs for the init's fnv1a64, with Python's answers
(out / "fnv-logo.jpg").write_bytes(logo)
(out / "fnv-256.bin").write_bytes(bytes(range(256)))
lines = []
for name, data in [("fnv-logo.jpg", logo), ("fnv-256.bin", bytes(range(256))), ("kernel-image.bin", bytes(img))]:
    for skip, count in [(0, len(data)), (100, 500), (7, 1)]:
        if skip + count <= len(data):
            h = fnv1a64(data[skip:skip + count])
            lines.append(f"{name} {skip} {count} {h & 0xFFFFFFFF} {h >> 32}")
(out / "fnv-expected.txt").write_text("\n".join(lines) + "\n")
print("        golden fixtures in", out)
PY
python3 "$TMP/gen_golden_fixtures.py" "$TMP/golden-fixtures" "$ROOT/boot/golden/check-param.py" \
  || { echo "  FAIL  the golden fixtures could not be generated"; exit 1; }
for d in g g2; do
  bash "$ROOT/boot/build-initramfs.sh" --out "$TMP/$d" --golden "$TMP/golden-fixtures/golden" \
    >"$TMP/build-$d.log" 2>&1 || { cat "$TMP/build-$d.log"; exit 1; }
done
if cmp -s "$TMP/g/initramfs.cpio.gz" "$TMP/g2/initramfs.cpio.gz"; then
  echo "  PASS  two builds with --golden byte-identical"
else
  echo "  FAIL  two builds with --golden differ"; HFAIL=$((HFAIL + 1))
fi
if grep -q "golden: installer 9.9.9-test for T715XXU2CRH1" "$TMP/build-g.log"; then
  echo "  PASS  the build log names the golden installer"
else
  echo "  FAIL  the build log lacks the golden note"; HFAIL=$((HFAIL + 1))
fi
for f in lib/t715-golden/logo.jpg lib/t715-golden/stock.sha256 lib/t715-golden/loader.sha256 \
  lib/t715-golden/stock.members lib/t715-golden/extent lib/t715-golden/bootloader lib/t715-golden/release; do
  if grep -q " $f\$" "$TMP/g/initramfs.manifest.txt"; then echo "  PASS  the archive has $f"
  else echo "  FAIL  the archive lacks $f"; HFAIL=$((HFAIL + 1)); fi
done
# Both sha256 files go in whole: line 2 is the second stock PARAM's pair.
# (The build unpacks its cpio in Docker; the archive is read here.)
mkdir -p "$TMP/g-cpio"
gzip -dc "$TMP/g/initramfs.cpio.gz" >"$TMP/g-cpio/initramfs.cpio"
for f in stock.sha256 loader.sha256; do
  if python3 -I "$ROOT/boot/cpio_newc.py" extract-file "$TMP/g-cpio/initramfs.cpio" "lib/t715-golden/$f" 2>/dev/null | cmp -s - "$TMP/golden-fixtures/golden/$f"; then
    echo "  PASS  the archive's $f is the fixture's, both its lines"
  else echo "  FAIL  the archive's $f is not the fixture's whole"; HFAIL=$((HFAIL + 1)); fi
done

echo "=== 1d. build refusals: --golden with sha256 files that do not pair"
# Copies of the fixtures' golden directory, one file changed each.  A refusal
# must be the check's own: the build's message is looked at, so that a build
# that fails for another reason does not pass for this one.
grefused() {  # DESCRIPTION FILE CONTENT EXPECTED_MESSAGE
  local d="$TMP/golden-bad" rc=0 out
  rm -rf "$d" && cp -R "$TMP/golden-fixtures/golden" "$d"
  printf '%b' "$3" >"$d/$2"
  out=$(bash "$ROOT/boot/build-initramfs.sh" --out "$TMP/x-golden" --golden "$d" 2>&1) || rc=$?
  if [[ $rc -eq 0 ]]; then echo "  FAIL  $1: built"; HFAIL=$((HFAIL + 1))
  elif grep -qF -- "error: $4" <<<"$out"; then echo "  PASS  $1: refused"
  else echo "  FAIL  $1: refused for another reason:"; echo "        ${out//$'\n'/$'\n'        }"; HFAIL=$((HFAIL + 1)); fi
}
A=$(sed -n 1p "$TMP/golden-fixtures/golden/stock.sha256" | cut -d' ' -f1)
B=$(sed -n 2p "$TMP/golden-fixtures/golden/stock.sha256" | cut -d' ' -f1)
C=$(sed -n 1p "$TMP/golden-fixtures/golden/loader.sha256" | cut -d' ' -f1)
grefused "--golden: two stock lines, one loader line" loader.sha256 "$C  one loader only\n" \
  "--golden: stock.sha256 has 2 stock PARAM(s) and loader.sha256 1: one loader per stock PARAM, on the same line"
grefused "--golden: one stock line, two loader lines" stock.sha256 "$A  one stock PARAM only\n" \
  "--golden: stock.sha256 has 1 stock PARAM(s) and loader.sha256 2: one loader per stock PARAM, on the same line"
grefused "--golden: stock.sha256 with a line that is not a sha256" stock.sha256 "$A  line 1\nnot-a-sum  line 2\n" \
  "--golden: stock.sha256: line 2 does not start with a lower-case sha256"
grefused "--golden: loader.sha256 with a line that is not a sha256" loader.sha256 "$C  line 1\nnot-a-sum  line 2\n" \
  "--golden: loader.sha256: line 2 does not start with a lower-case sha256"
grefused "--golden: a sum of 63 characters" loader.sha256 "$C  line 1\n${C:1}  line 2\n" \
  "--golden: loader.sha256: line 2 does not start with a lower-case sha256"
grefused "--golden: an upper-case sha256" stock.sha256 "$A  line 1\n$(printf '%s' "$B" | tr 'a-f' 'A-F')  line 2\n" \
  "--golden: stock.sha256: line 2 does not start with a lower-case sha256"
grefused "--golden: no stock PARAM at all" stock.sha256 "" \
  "--golden: $TMP/golden-bad/stock.sha256 is missing or empty"
echo "=== 1e. check-param.py: both stock PARAMs, and the directories that do not pair"
# The checker reads the golden files of its own directory: a copy of it is put
# in each one.  What it says is compared with the fixtures' own sums.
gcheck() {  # DESCRIPTION GOLDEN_DIR PARAM_IMG EXPECTED_EXIT [-loader IMG] EXPECTED_TEXT...
  local d=$1 g=$2 img=$3 xrc=$4 rc=0 out loader=()
  shift 4
  if [[ ${1:-} == -loader ]]; then loader=("$2"); shift 2; fi
  cp "$ROOT/boot/golden/check-param.py" "$g/check-param.py"
  out=$(python3 -I "$g/check-param.py" "$img" ${loader[@]+"${loader[@]}"} 2>&1) || rc=$?
  # its output, indented under the failure line
  if [[ $rc -ne $xrc ]]; then echo "  FAIL  $d: exit $rc, wanted $xrc"; echo "        ${out//$'\n'/$'\n'        }"; HFAIL=$((HFAIL + 1)); return; fi
  local t
  for t in "$@"; do
    if ! grep -qF -- "$t" <<<"$out"; then
      echo "  FAIL  $d: its output lacks: $t"; echo "        ${out//$'\n'/$'\n'        }"; HFAIL=$((HFAIL + 1)); return
    fi
  done
  echo "  PASS  $d"
}
GFXT="$TMP/golden-fixtures"
A=$(sed -n 1p "$GFXT/golden/stock.sha256" | cut -d' ' -f1)
B=$(sed -n 2p "$GFXT/golden/stock.sha256" | cut -d' ' -f1)
LA=$(sed -n 1p "$GFXT/golden/loader.sha256" | cut -d' ' -f1)
LB=$(sed -n 2p "$GFXT/golden/loader.sha256" | cut -d' ' -f1)
# the four sums the CLI prints are cut to 16 characters: the tests give them the same cut
gcheck "check-param.py: the first stock PARAM is stock line 1, and gives its loader" \
  "$GFXT/golden" "$GFXT/param-stock.img" 0 \
  "stock part: ${A:0:16}...: one this installer knows, stock line 1 (the stock PARAM reached over the air (param-stock.img))" \
  "forged:     ${LA:0:16}...: the loader of stock line 1"
gcheck "check-param.py: the second stock PARAM is stock line 2, and gives its own loader" \
  "$GFXT/golden" "$GFXT/param-stock-b.img" 0 \
  "stock part: ${B:0:16}...: one this installer knows, stock line 2 (the stock PARAM flashed with Odin (param-stock-b.img))" \
  "forged:     ${LB:0:16}...: the loader of stock line 2"
gcheck "check-param.py: the second stock PARAM with leftover bytes is known by its archive" \
  "$GFXT/golden" "$GFXT/param-golden-tail-b.img" 0 \
  "its archive: ${B:0:16}... (ends at byte $(cat "$GFXT/stock-b.end"), $(wc -c <"$GFXT/tail-run.bin" | tr -d ' ') bytes after it not zero): one this installer knows, stock line 2"
gcheck "check-param.py: a cross-paired loader.sha256 refuses the second stock PARAM" \
  "$GFXT/golden-cross" "$GFXT/param-stock-b.img" 1 \
  "forged:     ${LB:0:16}...: NOT the loader this installer was built for" "the installer would write nothing"
gcheck "check-param.py: a cross-paired loader.sha256 still takes the first pair" \
  "$GFXT/golden-cross" "$GFXT/param-stock.img" 0 "the installer would write the loader"
gcheck "check-param.py: a swapped loader.sha256 refuses the second stock PARAM as another line's loader" \
  "$GFXT/golden-swapped" "$GFXT/param-stock-b.img" 1 \
  "NOT the loader of stock line 2" "but the loader of stock line 1: cross-paired"
gcheck "check-param.py: a swapped loader.sha256 refuses the first stock PARAM too" \
  "$GFXT/golden-swapped" "$GFXT/param-stock.img" 1 \
  "NOT the loader of stock line 1" "but the loader of stock line 2: cross-paired"
# the loader's own image, as when this directory's files were checked
gcheck "check-param.py: with the loader's own image of the second pair: the same bytes" \
  "$GFXT/golden" "$GFXT/param-stock-b.img" 0 -loader "$GFXT/param-loader-b.img" \
  "the loader's own image: the same bytes" "the installer would write the loader"
gcheck "check-param.py: with the first pair's loader image for the second stock PARAM: different" \
  "$GFXT/golden" "$GFXT/param-stock-b.img" 1 -loader "$GFXT/param-loader.img" \
  "the loader's own image: DIFFERENT bytes" "the installer would write nothing"
# --members, the way stock.members was made
if diff <(python3 -I "$ROOT/boot/golden/check-param.py" --members "$GFXT/param-stock.img") "$GFXT/golden/stock.members" >/dev/null; then
  echo "  PASS  check-param.py --members lists the stock members (stock.members)"
else echo "  FAIL  check-param.py --members differs from stock.members"; HFAIL=$((HFAIL + 1)); fi

echo "=== 2. shellcheck"
if docker run --rm --platform linux/arm64 \
    -v "$ROOT/boot/initramfs/init:/c/init:ro" \
    -v "$ROOT/boot/build-initramfs.sh:/c/build-initramfs.sh:ro" \
    -v "$ROOT/boot/pack-test-recovery.sh:/c/pack-test-recovery.sh:ro" \
    -v "$ROOT/boot/tests/test_initramfs.sh:/c/test_initramfs.sh:ro" \
    "$TOOLS_IMAGE" sh -c 'cd /c && shellcheck --version | sed -n 2p &&
      shellcheck -s sh init && shellcheck build-initramfs.sh pack-test-recovery.sh test_initramfs.sh'; then
  echo "  PASS  shellcheck (init as sh, scripts as bash)"
else
  echo "  FAIL  shellcheck"; HFAIL=$((HFAIL + 1))
fi

echo "=== 3. boot test (Docker linux/arm/v7, privileged)"
if ! docker image inspect "$TEST_IMAGE" >/dev/null 2>&1; then
  docker build --platform linux/arm/v7 -t "$TEST_IMAGE" - >"$TMP/test-image.log" 2>&1 <<EOF || { cat "$TMP/test-image.log"; exit 1; }
FROM $BASE_IMAGE
RUN apt-get update \\
 && apt-get install -y --no-install-recommends e2fsprogs fdisk cpio iproute2 \\
 && rm -rf /var/lib/apt/lists/*
EOF
fi
if docker run --rm --privileged --platform linux/arm/v7 --network none \
    -v "$ROOT/boot/tests/test_initramfs.sh:/t/test_initramfs.sh:ro" \
    -v "$TMP/a/initramfs.cpio.gz:/t/initramfs.cpio.gz:ro" \
    -v "$TMP/r/initramfs.cpio.gz:/t/initramfs-rescue.cpio.gz:ro" \
    -v "$TMP/e/initramfs.cpio.gz:/t/initramfs-rescue-extent.cpio.gz:ro" \
    -v "$TMP/param-known.img:/t/param-known.img:ro" \
    -v "$TMP/param-stock.img:/t/param-stock.img:ro" \
    -v "$TMP/param-third.img:/t/param-third.img:ro" \
    -v "$TMP/g/initramfs.cpio.gz:/t/initramfs-golden.cpio.gz:ro" \
    -v "$TMP/golden-fixtures:/t/golden-fixtures:ro" \
    "$TEST_IMAGE" bash /t/test_initramfs.sh --in-container /t/initramfs.cpio.gz; then
  :
else
  HFAIL=$((HFAIL + 1))
fi

if [[ $HFAIL -eq 0 ]]; then echo "=== ALL PASS"; else echo "=== $HFAIL group(s) FAILED"; exit 1; fi
