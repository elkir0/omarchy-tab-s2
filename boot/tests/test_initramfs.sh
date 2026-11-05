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
#     USERDATA untouched), a too-small USERDATA (fallback to image mode
#     with the "Not enough free space" line).  Also the end-user defaults:
#     no telnet on the default boot (port closed, log says so), and
#     t715.failreboot=0 turning a failure into exit 97 with the on-screen
#     failure line.  USERDATA must stay fsck-clean.
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
  # The init attached media/0/linux/rootfs.img from its own namespace.
  for dev in $(losetup -a 2>/dev/null | awk -F: '/media\/0\/linux\/rootfs[^\/]*\.img/ {print $1}'); do
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
  truncate -s 80M "$W/disk.img"
  sfdisk -q "$W/disk.img" <<'EOF'
label: gpt
start=2048, size=2048, name=EFS
start=4096, size=8192, name=SYSTEM
start=12288, size=131072, name=USERDATA
EOF
  dd if="$W/userdata.img" of="$W/disk.img" bs=512 seek=12288 conv=notrunc status=none
}

disk_sums() {
  sync
  echo "disk=$(sha256sum <"$W/disk.img" | cut -d' ' -f1)"
  echo "userdata=$(dd if="$W/disk.img" bs=512 skip=12288 count=131072 status=none | sha256sum | cut -d' ' -f1)"
}

attach_disk() {
  local n
  n=$(losetup -f)
  losetup -P "$(node "$n")" "$W/disk.img"
  LOOPS+=("$n")
  OUTER=$n
  local i
  for ((i = 0; i < 20; i++)); do
    grep -qx "PARTNAME=USERDATA" "/sys/class/block/${n#/dev/}p3/uevent" 2>/dev/null && return 0
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
# plant_sidecar [bad]: a one-line sha256sum sidecar for the selected image
# (rootfs-alt.img); with "bad", a syntactically valid but wrong hash.
plant_sidecar() {
  local h zeros
  h=$(sha256sum "$W/ud/media/0/linux/rootfs-alt.img" | cut -d' ' -f1)
  if [[ "${1:-}" == bad ]]; then
    zeros=$(printf '%063d' 0)
    h="${zeros}${h: -1}"
  fi
  printf '%s  rootfs-alt.img\n' "$h" >"$W/ud/media/0/linux/rootfs-alt.img.sha256"
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

# scenario_persist_sidecar GOOD|BAD: the .sha256 sidecar next to the
# selected image, verified before the seed.  Runs after scenario_persist_
# seed/again/rescue/foreign, whose omarchy root must be removed first
# (that is the machine's state at the factory: image present, no root).
scenario_persist_sidecar() {
  local good=$1
  echo "--- scenario: persistent root, first boot, $good .sha256 sidecar"
  if ! with_userdata select_persist || ! with_userdata plant_sidecar "$good" ||
    ! with_userdata rm -rf "$W/ud/omarchy"; then
    ko "rootfs.select line 2 and the sidecar written"; return
  fi
  # USERDATA's content checksum before the boot: a bad sidecar must leave
  # the partition byte-identical (the check runs while it is read-only).
  local sum_before
  sum_before=$(with_userdata userdata_sum)
  prepare_boot "pside-$good"
  local rc=0
  run_init "pside-$good" "$PERSIST_KNOBS" || rc=$?
  # An image-mode fallback leaves the image's loop attached (the namespace
  # dies at the hand-over): detach it before mounting USERDATA again, or
  # the loop's open file keeps the mount busy.
  detach_inner_loops
  if [[ "$good" == good ]]; then
    check "switch_root reached the seeded /sbin/init (exit $rc)" test "$rc" -eq 0
    check "checksum verified" log_has "pside-$good" "image checksum verified"
    check "Checking-the-image said on screen" log_has "pside-$good" "t715-say: Checking the image..."
    check "persistent root checks pass" log_has "pside-$good" "T715TEST RESULT: PASS"
    local st
    st=$(with_userdata persist_state)
    check "seed did run (marker present)" grep -qx "marker=persistent root omarchy, seeded from media/0/linux/rootfs-alt.img" <<<"$st"
  else
    check "fell back to image mode (exit $rc)" test "$rc" -eq 0
    check "image mode checks pass" log_has "pside-$good" "T715TEST RESULT: PASS"
    check "mode image" log_has "pside-$good" "T715TEST mode=image"
    check "checksum refused" log_has "pside-$good" "ERROR: image checksum check failed: checksum mismatch"
    check "damage said on screen" log_has "pside-$good" "t715-say: The image file is damaged (bad checksum). Copy it to the tablet again."
    check "no seed directory created" sh -c "! grep -q 'seeding USERDATA' '$W/pside-$good.log'"
    local st
    st=$(with_userdata persist_state)
    check "no persistent root created" grep -qx "marker=" <<<"$st"
    check "no seed directory left" grep -qx "leftover=0" <<<"$st"
    check "USERDATA's files untouched (checksum unchanged)" test "$sum_before" = "$(with_userdata userdata_sum)"
  fi
  [[ $rc -eq 0 ]] || show_log "pside-$good"
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

in_container() {
  CPIO=$1
  trap container_cleanup EXIT
  mkdir -p "$W"
  mount -t tmpfs -o size=512m,mode=0755 t715-test "$W"
  mkdir -p "$W/dev"
  mount -t devtmpfs devtmpfs "$W/dev"

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
  scenario_persist_space
  detach_inner_loops
  detach_disk
  scenario_nouserdata

  sync
  dd if="$W/disk.img" of="$W/ud-check.img" bs=512 skip=12288 count=131072 status=none
  check "USERDATA fsck clean after the persistent boots (e2fsck -fn)" e2fsck -fn "$W/ud-check.img"

  echo "--- container: $NPASS passed, $NFAIL failed"
  [[ $NFAIL -eq 0 ]]
}

if [[ "${1:-}" == --in-container ]]; then
  in_container "$2"
  exit
fi

# ===========================================================================
# host side (macOS or Linux, Docker)
# ===========================================================================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/t715-initramfs-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
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
    "$TEST_IMAGE" bash /t/test_initramfs.sh --in-container /t/initramfs.cpio.gz; then
  :
else
  HFAIL=$((HFAIL + 1))
fi

if [[ $HFAIL -eq 0 ]]; then echo "=== ALL PASS"; else echo "=== $HFAIL group(s) FAILED"; exit 1; fi
