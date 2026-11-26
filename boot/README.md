# boot/: what boots the tablet

| Path | What |
|---|---|
| `initramfs/init` | the initramfs's `/init` (busybox sh, PID 1): image mode, persistent root, knobs, debug shell; the installer of the 64-bit system and its rescue (`t715.golden`) |
| `golden/` | what the installer writes into PARAM: the loader's logo (`logo.jpg`), the sha256 of PARAM's first `extent` bytes before (`stock.sha256`) and after (`loader.sha256`), the one `bootloader` it is made for, the `release`; `check-param.py` checks a PARAM dump against them on a computer |
| `build-initramfs.sh` | builds the initramfs (busybox, static e2fsck, the kernel's modules, knobs; with `--paramrescue`, the loader the rescue puts back), reproducibly, in Docker |
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
| `t715.shell=1` | `0` | prepare `/newroot`, then wait in the debug shell; `touch /tmp/t715-continue` there to boot Arch (needs `t715.telnet=1`) |
| `t715.failwait=SECS` | `300` | on failure, keep the debug shell up this long, then `reboot -f` (back to Android); `touch /tmp/t715-stay` cancels the timer |
| `t715.failreboot=0` | `1` | on failure, show the error on screen and wait (hold Power + Volume down to restart) instead of rebooting after `t715.failwait` |
| `t715.rootwait=SECS` | `20` | how long to wait for USERDATA |
| `t715.usbfn=rndis\|ecm` | `rndis` | USB function of the debug link (`ecm` = CDC-ECM) |
| `t715.telnet=1` | `0` | the root telnet shell on the USB debug link (no password); off by default, the link and DHCP still come up |
| `t715.modules=0` | `1` | do not insert `/lib/t715-modules/*.ko` (the GPU modules packed with `--modules`; the module tree is still copied into the root) |
| `t715.modblacklist=a,b` | (none) | write `blacklist a` / `blacklist b` into `/run/modprobe.d` (for this boot only): udev no longer autoloads them, `modprobe` by hand still works (bring-up tests) |
| `t715.autotest=1` | `0` | **test images only**: once Arch is up, run `t715-autotest.sh` from the root image's directory (Android `/sdcard/linux/`) as root through a runtime `t715-autotest.service` in `/run/systemd/system`, journal forwarded to the kernel log (read back from Android in `/proc/last_kmsg`). Any Android app that can write `/sdcard` can plant that script: never bake it into a daily image |
| `t715.persist=NAME` | (none) | persistent root `USERDATA/NAME` (wins over `rootfs.select`'s line 2) |
| `t715.persist=0` | | image mode even if `rootfs.select` asks for a persistent root (rescue boot) |
| `t715.quiet=1` | `0` | a quiet screen until the Plymouth splash: console loglevel 3 from the initramfs on (`CONFIG_CMDLINE`'s `loglevel=8` comes after anything sboot or a boot image header could add; sboot drops the header's command line anyway), the VT cleared and its cursor hidden |
| `t715.paramrescue=1` | `0` | a tablet whose only system is started by a loader in PARAM: unless PARAM holds the stock image or the loader known to work (`/lib/t715-paramrescue`, from `--paramrescue`), write that loader back and restart (see "The loader's rescue" below) |
| `t715.wdtguard=0` | `1` | boot even when the previous reset was the watchdog (default: restart to Android at once) |
| `t715.crashlog=1` | `0` | **test images only**: after a watchdog reset, just before the guard's restart, save the previous boot's pstore records (its console, a panic dump) to `media/0/linux/t715-crash/` on USERDATA, without the kernel command line, init's environment and MAC addresses; USERDATA gets `e2fsck -p` and a read-write mount for that copy only. Without it the guard's own short boot overwrites the console of the boot that hung |
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

On the first boot `NAME` does not exist yet. If a checksum sidecar
`<image>.sha256` (one `sha256sum`-format line naming the image's own file
name) sits next to the selected image, it is verified first ("Checking
the image..." on screen). A sidecar written on Windows is accepted:
`sha256sum`-format text with CR LF line endings, a leading UTF-8 byte
order mark (Notepad) or an upper-case hash (PowerShell's `Get-FileHash`)
reads the same. A mismatch or a malformed sidecar refuses the
seed without touching USERDATA (still read-only at that point) and falls
back to image mode. Without a sidecar the seed runs unchecked, as before.

The image is then attached read-only and copied into
`USERDATA/.NAME.t715-seed` by the image's own `cp -a` (chrooted into the
image, so GNU cp keeps owners, modes, hard links, xattrs and file
capabilities; `lost+found` is skipped). The marker `.t715-persist` (seed
image, kernel, initramfs build, date) goes in last, then the directory is
renamed `NAME`. The screen shows the start, a percentage about every
10 s and the end: the copy of the 3.2 GiB Omarchy image takes a few
minutes. An interrupted seed leaves only the hidden directory, removed by
the next attempt. The seed refuses to start with less than the image's
use + 512 MiB free — then the tablet says so on screen ("Not enough free
space: running from the image; changes are lost at reboot. Free about N
GB and restart") and boots the image read-only instead.

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

The root telnet shell is **off by default** (`t715.telnet=0`: the link
still comes up, DHCP still answers, but nothing listens on port 23 — the
default for a tablet handed to an end user). Bake
`--knobs "t715.telnet=1"` (or pass it on the kernel command line) to get
it back; telnetd then listens on 172.16.42.1:23 only, and the shell has
no password. macOS has no built-in RNDIS driver. If no interface appears,
rebuild with `--knobs "t715.usbfn=ecm"` (CDC-ECM is native on macOS).

### The loader's rescue (`t715.paramrescue`)

For a tablet that keeps no 32-bit system: S-Boot starts the arm64 kernel
through a loader placed in PARAM ([bnuuyloader](https://github.com/meowybnuuy/bnuuyloader)),
and boots BOOT only when that loader hands the boot back (the arm64 system
did not come up) or when no loader runs at all. A loader that fails to fire
is never reached again, and with nothing behind BOOT the tablet restarts in
a loop that nothing can reach.

With the knob on, `/init` looks at PARAM first, once the USB debug link is up:

| The loader's part of PARAM holds | What happens |
|---|---|
| the loader known to work | nothing: the boot goes on |
| the stock image (no loader) | nothing: the boot goes on |
| anything else | the known loader is written over it, read back, and the board restarts: the arm64 system comes back by itself |

The boot then goes on to the root image, and as there is none, to the
failure path: the reason on screen, the debug link (and with
`t715.telnet=1` its root shell) for `t715.failwait` seconds, then a restart.
PARAM flagged read-only (as the system of every day leaves it, by a rule of
its own) is made writable first; a disk that cannot be written is not forced.
With the knob off, a file of the directory missing, an image that is not the
one its sha256 announces, no single partition named PARAM, or a write that
does not read back, nothing is written and the boot goes on the same way.

`--paramrescue-also IMAGE` (more than once) names other PARAM images whose
loaders work: the rescue leaves them alone too and never writes them, so
the loader the owner put in PARAM is respected.

**Only the loader's part of PARAM is compared and written.** The loader is
the start of PARAM, the archive S-Boot reads its logo from; what follows is
data of S-Boot's own, and S-Boot writes it whenever it boots a kernel itself
(a fallback boot, included): on 2026-11-25 the first rescue took a good loader
for none, twice, because of it. `--paramrescue-extent BYTES` keeps the rescue
to the first BYTES; without it, the whole image is the loader.

The files come from the build; the option turns the knob on by default:

```bash
bash boot/build-initramfs.sh --out out/initramfs-rescue \
     --knobs "t715.usbfn=ecm t715.telnet=1 t715.failwait=120 t715.quiet=1" \
     --paramrescue LOADER.param --paramrescue-extent LOADER_BYTES --paramrescue-stock SHA256_OF_THE_STOCK_PARAM \
     [--paramrescue-also OTHER_LOADER.param ...]
bash boot/tests/test_initramfs.sh       # builds its own images, never touches the tablet
bash boot/pack-test-recovery.sh --initramfs out/initramfs-rescue/initramfs.cpio.gz \
     --out out/rescue/recovery BUILD_DIR      # RECOVERY image
bash boot/pack-test-recovery.sh --initramfs out/initramfs-rescue/initramfs.cpio.gz \
     --boot --out out/rescue/boot BUILD_DIR   # the same for BOOT
```

Both sha256 are of the loader's part (`head -c LOADER_BYTES IMAGE | sha256sum`).

Rules:

- **Such an image is one tablet's own PARAM with a loader in it: never publish it.**
  The stock PARAM's sha256 is required: without it the rescue would take the
  stock image for a loader that did not run.
- **The known loaders must follow the loaders in use.** BOOT is booted also
  when a working loader hands the boot back, and the rescue then replaces a
  loader it knows of neither way (a newer one, with a failure of the arm64
  system behind it) by the one it writes back. Rebuild the image with each
  new loader: the last proven one as `--paramrescue`, the others as
  `--paramrescue-also`.
- **BOOT first, while the loader works.** S-Boot never boots BOOT then, so a
  broken image costs nothing. To see the rescue for real, make one boot that
  the ledger will not count as up (`systemctl disable t715-kboot-mark.service`,
  restart, `systemctl enable` it, restart): the loader hands the next two
  boots to the rescue. RECOVERY after: it cannot be tried by keys while the
  loader is in PARAM, the loader running in every S-Boot boot, a recovery
  one included.
- The system of every day's tools that name PARAM by the sha256 of the whole
  partition find no name for it after a fallback boot, since S-Boot's data
  has changed: they must look at the loader's part, as the rescue does.

### The installer of the 64-bit system (`t715.golden`)

Built with `--golden boot/golden` (which turns the knob on), this initramfs is the 2.1.0
release's installer (2.0.0's, plus the reinstall below), in BOOT and RECOVERY:
[docs/INSTALL-ARM64.md](../docs/INSTALL-ARM64.md) is
the user's guide, and its section 7 the short account. The code is the part of `initramfs/init`
headed "Golden"; in order:

| Step | Function | What |
|---|---|---|
| state | `golden_main` | PARAM's first `extent` bytes: the stock image (`stock.sha256`) → install; the loader (`loader.sha256`) and the root marked `.t715-golden` → the loader handed this start back: say so, restart after `t715.failwait`; the loader without the root → install it (PARAM is left alone); the loader with the root and a `reinstall` file in `linux/` → the reinstall (below); anything else with the root's saved stock PARAM → forge and write the loader again (the rescue); anything else → refuse |
| checks | `golden_install` | `androidboot.bootloader` from S-Boot's command line is `bootloader`; the image `omarchy-arm64.img` in `linux/` of the internal storage (`media/0/linux`) or of a microSD card, its sidecar `.sha256` (required); the battery (30 %); the image is aarch64 and carries `usr/lib/t715-golden/kernel.slot`; the chip's ASV fuse word is logged |
| root | `golden_seed` | the image's tree into `USERDATA/.omarchy-arm64.t715-seed` with busybox `tar` (the arm64 image's `cp` cannot run on this 32-bit kernel; tar carries no extended attribute: the release lists the image's file capabilities, which the image's `t715-golden-caps.service` sets again at the first boot, and checks it holds no other but the ACLs systemd-tmpfiles sets), the entries counted on both sides, `import_device_files`, the `.t715-persist` marker, renamed `omarchy-arm64` |
| kernel | `golden_slot`, `golden_cache_fs` | with no slot of ours in CACHE, a 64 MiB file system (`mke2fs`) in front of the slots; the slot written to the one not in use with the next generation (its header's generation and FNV-1a 64 made here, `slot_gen` reads them back), the whole slot read back |
| loader | `golden_param`, `golden_forge`, `golden_write_param` | PARAM copied whole to `media/0/linux/PARAM-stock-backup.img` and the root's `var/lib/t715/PARAM-stock.img`, EFS (read only) to `media/0/linux/EFS-backup.img`; the loader forged from the copy (Samsung's `logo.jpg` replaced by `golden/logo.jpg`, the members after it moved, zeros to `extent`), refused unless its sha256 is `loader.sha256`; written over the first `extent` bytes only, read back |
| end | `golden_finish` | the root's `.t715-golden`, the log to `media/0/linux/omarchy-arm64-install.log`, restart |

Each step done already is skipped at the next start; PARAM is the last write. Every refusal
writes nothing and waits on screen (`t715.failreboot` is 0 in this mode), except the loader's
hand-back, which restarts. The host tests: the `golden` scenarios of `tests/test_initramfs.sh`.
The release builds the installer itself (`arm64/release/make-release.sh`), on the 1.0.5 release's
32-bit kernel, with `t715.failwait=30 t715.quiet=1`.

**The reinstall (since 2.1.0).** A tablet on 2.0.0 already has the loader in PARAM and an
installed root, so there the installer only acts as the rescue. A file named `reinstall` in
`linux/` of the internal storage asks the 2.1.0 installer for a reinstall, once the loader hands
it a start (a kernel log line `KBOOT: try` that no `KBOOT: up` follows makes the loader give the
next two starts to BOOT; RECOVERY with the keys does not help, the loader runs there too): the checks run
first, as for a first install; then the installed root `omarchy-arm64` is renamed
`omarchy-arm64.previous` (kept, never deleted), the `reinstall` file is deleted, and the new
image is installed as usual. The loader stays in PARAM, and the rescue's saved stock PARAM
(`var/lib/t715/PARAM-stock.img`) is carried over. A second reinstall refuses while
`omarchy-arm64.previous` exists, and says how to delete it. The free space for the new root next
to the kept one is checked before anything is renamed; if the copy then stops before the new root
is in place, `omarchy-arm64.previous` is renamed back and the tablet restarts into it.
[docs/INSTALL-ARM64.md](../docs/INSTALL-ARM64.md), "From 2.0.0: the reinstall".

`golden/logo.jpg` is the logo of the loader `kboot7-cas3` (elkir0/bnuuyloader: its `t715/loader`
builds it, `t715/docs/SPLASH.md` tells that image; `check-param.py STOCK kboot7-cas3.param` says
the same bytes): the loader's code and its boot screen, our bytes only (no metadata; its only runs in common with Samsung's partitions are the JPEG
standard's Huffman tables and AArch64 no-op padding). `stock.sha256` is that of the archive part
of `T715XXU2CRH1`'s PARAM, Samsung's pictures and two default settings, the same on every tablet
of that firmware as far as known; a tablet whose PARAM differs is refused, not guessed at.

### On-screen messages

`t715.quiet=1` keeps the screen black until the splash, which also hid
first-boot progress and errors. What the owner must see now goes to the
VT whatever the console loglevel: a first boot says "Setting up Omarchy
(first boot), this takes a few minutes" and a percentage about every
10 s; every failure shows its reason and what happens next (rebooting in
N seconds, or waiting with `t715.failreboot=0`: hold Power and Volume
down to restart); a persistent root that falls back to the image for lack
of space says how much to free. These lines are in the kernel log too,
prefixed `t715-initramfs:`.

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
