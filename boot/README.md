# boot/: what boots the tablet

| Path | What |
|---|---|
| `initramfs/init` | the initramfs's `/init` (busybox sh, PID 1): image mode, persistent root, knobs, debug shell |
| `build-initramfs.sh` | builds the initramfs (busybox, static e2fsck, the kernel's modules, knobs), reproducibly, in Docker |
| `pack-test-recovery.sh` | packs kernel, DTB and initramfs into a RECOVERY image, or a BOOT image with `--boot` |
| `samsung_bootimg.py` | Samsung boot image and DTBH reader/writer |
| `cpio_newc.py`, `zimage_extract.py`, `seclog_decode.py` | cpio writer, zImage/ikconfig extractor, sboot `sec_log` decoder |
| `patch-stock-boot.sh` | the two ramdisk changes to the stock BOOT that stop Android rewriting RECOVERY (`docs/DEPLOY.md` 6.) |
| `build-dtbhtool-ref.sh`, `docker/` | the LineageOS `dtbhtool` built as a reference for the DTBH format |
| `tests/` | host-side tests: `python3 -m unittest discover -s boot/tests`, `bash boot/tests/test_initramfs.sh` (Docker) |

The kernel itself is built from `kernel/` (`kernel/README.md`); outputs go
to `out/`. Which images are on the reference tablet: `device/README.md`.

## Booting the image from USERDATA (initramfs)

Instead of flashing `SYSTEM`, the image can be kept as a file on Android's
internal storage and booted by a small initramfs
(`boot/initramfs/init`, busybox, PID 1). It finds the GPT
partition named `USERDATA`, sets the block device read-only (BLKROSET),
mounts it `ro,noload,nosuid,nodev,noexec`, attaches the image with
`losetup -r`, and boots it under an overlayfs whose upper layer is a tmpfs.
All changes made in Arch live in RAM and are lost at reboot. **In this
image mode nothing is ever written to USERDATA.** A tablet that keeps no
Android can instead boot a persistent root, a directory of USERDATA
mounted read-write (see "Persistent root" below).

### Build and pack

```bash
bash boot/build-initramfs.sh            # -> out/initramfs/initramfs.cpio.gz (busybox + static e2fsck)
bash boot/build-initramfs.sh --knobs "t715.shell=1 t715.failwait=900"   # bake knob defaults
bash boot/tests/test_initramfs.sh       # host-side tests (Docker), never touch the tablet
bash boot/pack-test-recovery.sh --initramfs out/initramfs/initramfs.cpio.gz \
     [--out DIR] BUILD_DIR DTB_NAME        # RECOVERY image, 16 MiB limit
```

The kernel needs `arch/arm/configs/gts28ltexx_initramfs.config` (INET,
PACKET, UNIX, BLK_DEV_LOOP, OVERLAY_FS) on top of `gts28ltexx_defconfig`
**and** `gts28ltexx_m2.config` (eMMC, DWC3 + configfs RNDIS built in).

### Copying the image to the tablet (through Android)

USERDATA's `media/0/` is Android's `/sdcard` (`/data/media/0`). Wi-Fi ADB
is the reliable link for a 2.9 GiB transfer (USB ADB stalls):

```bash
adb -s <tablet-ip>:5555 shell mkdir -p /sdcard/linux
adb -s <tablet-ip>:5555 push out/rootfs.img /sdcard/linux/rootfs.img
adb -s <tablet-ip>:5555 shell sha256sum /sdcard/linux/rootfs.img   # compare: shasum -a 256 out/rootfs.img
adb -s <tablet-ip>:5555 shell sync
```

Then reboot cleanly (`adb reboot recovery`). USERDATA is mounted without
journal replay, so after an unclean Android shutdown a freshly copied
file can look stale. The initramfs logs a warning in that case.

### Knobs (kernel command line, or `--knobs` at build time; the command line wins)

| Knob | Default | Effect |
|------|---------|--------|
| `t715.rootimg=PATH` | `media/0/linux/rootfs.img` | image path inside USERDATA (no `..`) |
| `t715.shell=1` | `0` | prepare `/newroot`, then wait in the debug shell; `touch /tmp/t715-continue` there to boot Arch |
| `t715.failwait=SECS` | `300` | on failure, keep the debug shell up this long, then `reboot -f` (back to Android); `touch /tmp/t715-stay` cancels the timer |
| `t715.rootwait=SECS` | `20` | how long to wait for USERDATA |
| `t715.usbfn=rndis\|ecm` | `rndis` | USB function of the debug link (`ecm` = CDC-ECM) |
| `t715.modules=0` | `1` | do not insert `/lib/t715-modules/*.ko` (the GPU modules packed with `--modules`; the module tree is still copied into the root) |
| `t715.modblacklist=a,b` | (none) | write `blacklist a` / `blacklist b` into `/run/modprobe.d` (for this boot only): udev no longer autoloads them, `modprobe` by hand still works (bring-up tests) |
| `t715.autotest=1` | `0` | **test images only**: once Arch is up, run `t715-autotest.sh` from the root image's directory (Android `/sdcard/linux/`) as root through a runtime `t715-autotest.service` in `/run/systemd/system`, journal forwarded to the kernel log (read back from Android in `/proc/last_kmsg`). Any Android app that can write `/sdcard` can plant that script: never bake it into a daily image |
| `t715.persist=NAME` | (none) | persistent root `USERDATA/NAME` (wins over `rootfs.select`'s line 2) |
| `t715.persist=0` | | image mode even if `rootfs.select` asks for a persistent root (rescue boot) |
| `t715.quiet=1` | `0` | a quiet screen until the Plymouth splash: console loglevel 3 from the initramfs on (`CONFIG_CMDLINE`'s `loglevel=8` comes after anything sboot or a boot image header could add; sboot drops the header's command line anyway), the VT cleared and its cursor hidden |
| `t715.wdtguard=0` | `1` | boot even when the previous reset was the watchdog (default: restart to Android at once) |
| `t715.returnafter=SECS` | `0` | unattended boot: SECS seconds after the hand-over, restart to Android through sysrq `b` (PMU SWRESET) and forward the journal to the kernel log |

On the command line, add knobs to the end of `CONFIG_CMDLINE`. sboot's
own line is about 986 of the kernel's 1023 bytes, so there is almost no
room left: prefer `--knobs`, which needs no kernel rebuild.

### Choosing another image: `rootfs.select`

Several root images can sit next to `rootfs.img` (Android:
`/sdcard/linux/`). To boot another one without rebuilding anything, write
its file name on the first line of `rootfs.select` in that directory:

```bash
adb shell 'echo rootfs-omarchy.img > /sdcard/linux/rootfs.select'   # next boots use it
adb shell 'rm /sdcard/linux/rootfs.select'                          # back to rootfs.img
```

Wait before rebooting: `adb shell 'sync; sleep 45; sync'`, then
`adb reboot recovery`. USERDATA is mounted without journal replay, so a
change Android has only written to the ext4 journal is invisible to the
initramfs. Seen on 2026-10-28: `rootfs.select` deleted and rebooted at
once was still read. Check the result in the log: `rootfs.select: booting
NAME` or `root image media/0/linux/NAME`.

The name must be a bare file name (letters, digits, `.`, `_`, `-`, not
starting with `.`) ending in `.img`; CR, spaces and tabs are stripped.
An invalid name or a missing image only logs a warning, and the default
image boots. `t715.rootimg=` (command line or `--knobs`) wins over the
file. Any image must be raw ext4 with systemd at `/sbin/init`, and it
needs `usb-rndis.service` and the `/etc/usb-rndis/dnsmasq.conf` above to
be reachable over USB.

### Persistent root: `persist=NAME`

For a tablet that keeps no Android. A second line in `rootfs.select`
(or the knob `t715.persist=NAME`) asks for the persistent root `NAME`, a
directory at the top of USERDATA:

```bash
adb shell 'printf "rootfs-omarchy.img\npersist=omarchy\n" > /sdcard/linux/rootfs.select'
```

At each boot the initramfs then runs `e2fsck -p` on USERDATA (Debian's
static e2fsck in the initramfs; exit 4 or more stops the read-write
mount), mounts it `rw,noatime,errors=remount-ro` (the superblock of
Android's USERDATA says "panic" on errors), bind-mounts `USERDATA/NAME` on
`/newroot` and hands over. Everything changed in Arch survives reboots:
Wi-Fi networks, pairings, settings, installed packages.

On the first boot `NAME` does not exist yet. The image of the first line
is attached read-only and copied into `USERDATA/.NAME.t715-seed` by the
image's own `cp -a` (chrooted into the image, so GNU cp keeps owners,
modes, hard links, xattrs and file capabilities; `lost+found` is
skipped). The marker `.t715-persist` (seed image, kernel, initramfs build,
date) goes in last, then the directory is renamed `NAME`. The copy of the
3.2 GiB Omarchy image takes a few minutes with a dark screen; the debug
shell is up meanwhile (`tail /run/t715/initramfs.log`). An interrupted
seed leaves only the hidden directory, removed by the next attempt. The
seed refuses to start with less than the image's use + 512 MiB free.

Safety rules: a `NAME` that exists without the marker is never touched
(the boot falls back to the image), and so is any failure (e2fsck,
space, copy): image mode, USERDATA read-only again. The module tree is
copied into the root with a stamp (`.t715-initramfs`, the initramfs build
id, which names the modules' tarball) and replaced when another build
boots. USERDATA's own view at `/run/t715/userdata` is remounted
`nosuid,nodev,noexec`; the root keeps them.

After the seed, the image file is only a rescue: `t715.persist=0` boots it
read-only as before. Delete `rootfs.select`'s second line to go back to
image mode for good (the directory stays until removed).

### Debug shell from macOS

The initramfs brings up the same link as `usb-rndis.service`. It is a
configfs gadget `05ac:0a14` with `172.16.42.1/24` on `usb0`, and DHCP
hands out `172.16.42.2–10`. It is torn down just before `switch_root`,
and Arch's service then recreates it. Plug the USB cable in, find the new
interface (`networksetup -listallhardwareports`, or `ifconfig` shows an
`enX` with 172.16.42.x), then connect:

```bash
nc 172.16.42.1 23            # macOS has no telnet since 10.13 (or: brew install telnet; telnet 172.16.42.1)
sudo ifconfig enX inet 172.16.42.2/24   # only if DHCP did not configure it
```

telnetd listens on 172.16.42.1:23 only, and the shell has no password.
macOS has no built-in RNDIS driver. If no interface appears, rebuild with
`--knobs "t715.usbfn=ecm"` (CDC-ECM is native on macOS).

### Logs and layout

- Every step goes to the kernel log as `t715-initramfs: ...`. After the
  reboot to Android, read it with
  `adb -s <tablet-ip>:5555 shell cat /proc/last_kmsg | grep t715-initramfs`.
  In Arch it is also in `/run/t715/initramfs.log`.
- In Arch (image mode): `/` is the overlay. `/run/t715/lower` is the image (ro),
  `/run/t715/rw` is the tmpfs upper layer, and `/run/t715/userdata` is
  USERDATA (ro, and the block device stays read-only until reboot).
- In Arch (persistent root): `/` is `USERDATA/NAME` (ext4, rw), and
  `/run/t715/userdata` is USERDATA (rw, nosuid,nodev,noexec). The e2fsck
  output is in `/run/t715/e2fsck.log`.
