# Deploying Omarchy on a new SM-T715

This guide takes a fresh Samsung Galaxy Tab S2 8.0 LTE (SM-T715,
`gts28lte`) to Omarchy (Hyprland and the Omarchy shell with the
omarchy-mobile touch layer) on a mainline 6.12 kernel. Two setups: Android
kept as the normal boot with Omarchy one `adb reboot recovery` away
(sections 1-11.5), or Omarchy as the tablet's only system, read-write, with
a rescue in RECOVERY (11.6-11.7, the reference tablet since 2026-10-29).

Everything is in this repository; run the commands from its root:

| Folder | What it holds |
|---|---|
| `kernel/` | the kernel as patches on `v6.12.114`, its build (`kernel/README.md`) |
| `boot/` | the initramfs, the BOOT/RECOVERY image packer, sboot tools (`boot/README.md`) |
| `image/` | the Omarchy root image: package repack and rebuilds, image builder, offline checks |
| `device/` | scripts that drive the tablet (SSH, flashing, pushing images) |
| `src/`, `dumps/`, `out/` | git-ignored: kernel tree and Heimdall, your tablet's dumps, build outputs |

The commands come from the scripts and docs of this repository, which are
cited; the few that do not (Heimdall's build, the `hdiutil` volume, an
`nmcli` fix) say where they come from. Where nothing documents a step, the
guide says so; the list of those gaps is in section 14. Status: 0.9.0,
2026-10-31. Every step ran on one tablet, the reference, and nobody has yet
followed this guide from a clean clone. The Android side was last run on
2026-10-29. Dated reports and the history of the work are not published (`docs/journal/README.md`).

## 1. What you end up with

| Partition | Content | Who writes it |
|---|---|---|
| BOOT (p9, 14 MiB) | the stock Samsung boot image with two ramdisk changes (6.) | heimdall, once |
| RECOVERY (p10, 16 MiB) | mainline Linux 6.12 (arm32, LPAE), its board DTB, the initramfs | heimdall, at each kernel update |
| USERDATA (p22) | Android's data; Linux images as plain files in `/sdcard/linux/` | Android only |
| everything else | untouched (BOOTLOADER, EFS, RADIO, PARAM, m9kefs, BOTA, ...) | nobody |

The boot flow (`boot/initramfs/init`, header; `docs/journal/PROGRESS.md`):

1. Power on: sboot boots BOOT, that is Android, as before.
2. `adb reboot recovery`: sboot boots RECOVERY. The kernel sets the PMU's
   INFORM3 back to "normal" early, so the next software reset returns to
   Android.
3. The initramfs (busybox, PID 1): watchdog guard (if the last reset was
   the watchdog, restart to Android at once), loads `gpu-sched` and
   `panfrost`, brings up a USB debug link (`172.16.42.1`, telnet, DHCP),
   finds the GPT partition named USERDATA, makes the block device read-only
   (BLKROSET), mounts it `ro,noload`, reads `rootfs.select`, attaches the
   image with `losetup -r`, stacks an overlayfs with a tmpfs upper layer,
   copies the kernel's module tree into that layer, and `switch_root`s to
   systemd.
4. The image (`rootfs-omarchy.img`, raw ext4, Arch Linux ARM `armv7h`:
   sboot starts the CPU in AArch32) boots to SDDM, which logs `alarm` into
   Omarchy without a greeter. SSH answers on `172.16.42.1` over USB.
5. `systemctl reboot` returns to Android. Everything done in Linux was in
   RAM and is gone.

On any initramfs failure it logs the reason, keeps the telnet debug shell
up for `t715.failwait` seconds (300 in the daily image), then `reboot -f`
back to Android.

`/sdcard/linux/rootfs.select` (one line, an image name ending in `.img`)
picks the image; without it, or with a name that does not exist, the
initramfs boots the default `rootfs.img` (the legacy Phosh image,
not published, optional). The knob `t715.rootimg=` wins over the file.

## 2. Rules that protect the tablet

From `docs/journal/HANDOVER.md` and `device/README.md`. The scripts
follow them; follow them by hand too.

- heimdall writes **RECOVERY only** during normal work. BOOT is written
  once, in section 6, and again only when the owner gives Android up
  (11.7, then with `write-part.sh` from Linux). **Never** BOOTLOADER, EFS
  (the IMEI), m9kefs1-3, RADIO, CDMA-RADIO, PARAM or BOTA
  (`docs/journal/PROGRESS.md`, partition table).
- While Android is kept, USERDATA is changed **from Android only**
  (`/sdcard/linux`), followed by `sync; sleep 45; sync` before any
  reboot. Linux mounts it read-only and without journal replay, so a
  change still in the ext4 journal is invisible to it. A persistent root
  (11.6) mounts it read-write, after `e2fsck`: only on a tablet whose
  owner gave Android up.
- Leave Linux with `systemctl reboot` (a software reset), **never** through
  the watchdog. A watchdog reset clears INFORM3 and sboot boots RECOVERY
  again: a kernel that hangs loops forever.
- `panfrost` stays a module (`=m`): built in, its probe ran before the
  initramfs guard and the tablet boot-looped (`docs/journal/PROGRESS.md`,
  2026-10-28).
- `t715.autotest=1` goes into test images only, never into the daily one:
  any Android app that can write `/sdcard` could plant the script it runs
  as root.
- No serial number, MAC address or Wi-Fi password in a repository, a
  committed log or a message. Raw logs and dumps go to
  `$T715_PRIVATE/` (`$T715_PRIVATE`, `$PRIVATE_DIR`).
- Expect the first image Samsung did not sign (TWRP, the patched BOOT,
  the Linux RECOVERY) to blow the Knox warranty bit for good: the
  reference tablet's went from 0 to 1 with the TWRP flash on 2026-10-27.

## 3. Host prerequisites

### 3.1 Machine and tools

The reference host is a Mac on Apple silicon with Docker Desktop. All
builds run in containers: `linux/arm64` natively, `linux/arm/v7` (the
tablet's userland) under Docker's qemu. A Linux host is untested (14.).

| Tool | Used by |
|---|---|
| Docker with BuildKit (`docker build --build-context`, `RUN --mount`) and arm/v7 emulation | every build script |
| `adb` | device scripts, dump script |
| heimdall 2.2.2 in `src/heimdall/build/bin/` (3.4) | `flash-boot.sh`, `flash-daily.sh`, `autotest-run.sh` |
| `dtc` and `fdtget` | `pack-test-recovery.sh`, `phase1_extract_noroot.sh` |
| `python3` | `pack-test-recovery.sh`, `patch-stock-boot.sh` |
| `perl`, `rsync` | `phase1_extract_noroot.sh` |
| `git`, `curl`, `gzip`, `shasum`, `md5` | builders, `push-rootfs-image.sh` |
| `ssh` with an ed25519 (or RSA/ECDSA) key | `tssh`, the image's `authorized_keys` |
| `nc` | the initramfs telnet shell (macOS has no `telnet` since 10.13) |

`device/tssh` runs `ssh root@172.16.42.1` with your default
identity, `BatchMode=yes` and no host-key pinning (the RAM overlay makes
new host keys at each boot). If the key you give the image is not a
default identity, point ssh at it for `172.16.42.1` in `~/.ssh/config`.

### 3.2 macOS quirks

- **Screen locked, no USB network.** While the Mac's screen is locked,
  macOS does not name new USB network interfaces: no DHCP, no SSH,
  although the tablet is fine. Keep the Mac unlocked during a boot, or use
  `autotest-run.sh` (13.).
- **No RNDIS driver.** macOS speaks CDC-ECM only. The daily initramfs
  (`t715.usbfn=ecm`) and the image (`/etc/usb-rndis/function` = `ecm`) use
  ECM; do not build either for RNDIS.
- **Chrome takes the ADB interface.** `chrome://inspect` ("Discover USB
  devices") or a WebUSB page competes with `adb` and drops it. Close
  Chrome while working on the tablet (`docs/journal/PROGRESS.md`, 2026-10-27).
- **Case-sensitive source volume.** The kernel tree must live on a
  case-sensitive file system. On the reference Mac, `src/` is
  the mount point of a case-sensitive APFS sparse bundle
  `.src.sparsebundle` at the repository's root (volume `smt715src`, 80 GiB,
  git-ignored). The commands that created it are not recorded; these
  `hdiutil` calls give the same layout:

  ```bash
  hdiutil create -type SPARSEBUNDLE -fs "Case-sensitive APFS" -size 80g -volname smt715src .src.sparsebundle
  hdiutil attach -mountpoint src .src.sparsebundle
  ```

  `src` may also be a symbolic link to such a volume mounted elsewhere.

### 3.3 What git does not give you

Three things, all git-ignored:

| Path | What | How to get it |
|---|---|---|
| `src/linux-6.12` | the kernel tree: stable `v6.12.114` plus the 46 patches of `kernel/patches/`: `t715-bringup`, `t715-modem`, `t715-parity` | `kernel/README.md` |
| `src/heimdall` | Heimdall 2.2.2 | 3.4 |
| `dumps/` | vendor files and the stock BOOT dump of your tablet (or set `T715_DUMPS_DIR`); on the reference Mac a link to the private `$T715_PRIVATE/dumps` | sections 5.1 and 5.3 |

```bash
git clone --branch v6.12.114 --depth 1 https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git src/linux-6.12
git -C src/linux-6.12 switch -c t715-bringup
git -C src/linux-6.12 am "$PWD"/kernel/patches/t715-bringup/*.patch
git -C src/linux-6.12 am "$PWD"/kernel/patches/t715-modem/*.patch
git -C src/linux-6.12 am "$PWD"/kernel/patches/t715-parity/*.patch
```

Build outputs go to `out/` (kernel, boot images) and `image/out/` (root
images, packages), caches to `image/cache/`; all are git-ignored.

### 3.4 Heimdall

The flash scripts call `src/heimdall/build/bin/heimdall`. The
reference build is the `v2.2.2` tag of `https://git.sr.ht/~grimler/Heimdall`
(commit `d9554e7`), CLI only, Release, against Homebrew's libusb 1.0.30
(its `CMakeCache.txt`). The steps below are the ones of Heimdall's own
`README.md`; the repository does not record them.

```bash
git clone https://git.sr.ht/~grimler/Heimdall "src/heimdall"
cd "src/heimdall" && git checkout v2.2.2
mkdir build && cd build
cmake -DCMAKE_BUILD_TYPE=Release -DDISABLE_FRONTEND=true ..
make
./bin/heimdall version
```

It needs `cmake`, `pkg-config` and `libusb` (Homebrew on the Mac).

## 4. Tablet prerequisites

### 4.1 The reference tablet

From `docs/journal/PROGRESS.md` ("Vérité terrain") and its `getprop` dump:

| Property | Reference value | Why it matters |
|---|---|---|
| `ro.product.model`, `ro.product.device` | `SM-T715`, `gts28lte` | the dump script refuses anything else |
| `ro.boot.hw_rev` | `9` | the RECOVERY image's DTBH entry covers hw_rev 9 to 255 only |
| `ro.bootloader` | `T715XXU2CRH1` (Android 7.0, `NRD90M`, patch level 2018-06-01) | the only firmware tested |
| `ro.crypto.state` | `unencrypted` | the initramfs needs a plain ext4 USERDATA |
| `ro.oem_unlock_supported` | `1` | whether "OEM unlocking" was switched on is not recorded |
| Knox warranty bit | 0, blown on 2026-10-27 | see section 2 |

Check yours (with the tablet's serial from `adb devices -l` in `S`; the
property names are those of the reference's `getprop` dump):

```bash
S=<serial from adb devices -l>
for p in ro.product.model ro.product.device ro.boot.hw_rev ro.bootloader ro.crypto.state; do
    printf '%s: ' "$p"; adb -s "$S" shell getprop "$p"
done
```

A hw_rev below 9, another firmware or an encrypted USERDATA is outside
what was tested (14.). Do not encrypt the tablet: the initramfs stops
with "no ext4 superblock (encrypted or not ext4?)".

### 4.2 Android settings

- Developer options on, USB debugging on (the repository does not
  describe the Android menus). Accept the RSA prompt on the tablet the
  first time with "always allow".
- The tablet's Wi-Fi on the same network as the host: the image push runs
  over Wi-Fi ADB (`adb tcpip 5555`, then `adb connect IP:5555`); USB ADB
  stalls after a few tens of MiB of sustained transfer
  (`docs/journal/PROGRESS.md`, "Connexion stable"). Note the tablet's IP address.
- The device scripts pick the tablet by its ADB model, `SM_T715`, on USB;
  other Android devices may be plugged in.
- Optional, as on the reference tablet during long sessions
  (`docs/journal/PROGRESS.md`, "Mode caféine"; read your values first with
  `settings get` to restore them):

  ```bash
  adb -s "$S" shell settings put global stay_on_while_plugged_in 7
  adb -s "$S" shell settings put system screen_off_timeout 1800000
  adb -s "$S" shell dumpsys deviceidle disable      # until the next Android boot
  # back: stay_on_while_plugged_in 0, screen_off_timeout <your value>, dumpsys deviceidle enable
  ```

### 4.3 Download mode

The scripts enter it with `adb reboot download` and wait for
`heimdall detect`. You need the hardware keys only to get out of a boot
loop or a frozen Linux (13.): with the tablet off or restarting, hold
**Power + Volume down + Home** until the warning screen, then press
**Volume up** to continue to Download mode. The
combination for recovery is not recorded (14., gap 5).

### 4.4 What was done to the reference tablet, in order

1. 2026-10-27: vendor files dumped without root (5.1); Heimdall built; PIT
   read; TWRP 3.7.0_9-0 flashed to RECOVERY (sha256 and TeamWin
   signature checked), Knox bit blown; TWRP backup of Boot, EFS,
   m9kefs1-3, Modem, Modem-CDMA and System to internal storage, pulled
   under Android into `$T715_PRIVATE/backups/twrp-20261027/` (5.3).
2. 2026-10-27: the patched stock BOOT flashed, first with
   `flash_recovery` disabled, then also with ADB on TCP 5555 (section 6).
3. From 2026-10-28: mainline kernels and initramfs in RECOVERY, images in
   `/sdcard/linux`; since 2026-10-29 the daily RECOVERY (7.3) boots
   `rootfs-omarchy.img` through `rootfs.select`.

## 5. Device-specific data

### 5.1 Wi-Fi NVRAM and Bluetooth patch RAM (no root)

The image build needs two vendor files from the tablet's `/system`
(`image/tools/build-rootfs`, preflight; `docs/image/ROOTFS.md`, "Bluetooth" and
"Wi-Fi"):

| Build input (`dumps/...`) | On the tablet | Size the build requires | In the image |
|---|---|---|---|
| `dumps/vendor_firmware/bcm4358A3_V0086.0144.hcd` | `/system/vendor/firmware/` | 53841 bytes | `/usr/lib/firmware/brcm/BCM4358A3.hcd`, its original name, and the link `BCM.samsung,gts28ltexx.hcd` |
| `dumps/etc_wifi/nvram_net.txt` | `/system/etc/wifi/` | 6053 bytes | `/usr/lib/firmware/brcm/samsung-gts28/nvram_net.txt`, linked as `brcmfmac4358-pcie.txt` |

Get them with the extraction script, which never writes to the tablet. It
puts a raw copy (with identifiers) in `$PRIVATE_DIR/raw_<date>/` (default
`$T715_PRIVATE`) and a redacted copy in `dumps/`:

```bash
adb devices -l
ANDROID_SERIAL="$S" bash "device/android/phase1_extract_noroot.sh"
wc -c "dumps/vendor_firmware/bcm4358A3_V0086.0144.hcd" "dumps/etc_wifi/nvram_net.txt"
shasum -a 256 "dumps/vendor_firmware/bcm4358A3_V0086.0144.hcd" "dumps/etc_wifi/nvram_net.txt"
```

Use the script, not a plain `adb pull`: its redaction replaces the
NVRAM's `macaddr` value with `<REDACTED>`, which turns the 6060-byte file
into the 6053 bytes `image/tools/build-rootfs` insists on. A raw pull fails the
build's size check. The reference's checksums, from its image MANIFEST
(equal values mean your files are the reference's):

| File | sha256 |
|---|---|
| `bcm4358A3_V0086.0144.hcd` | `3a5b074790869baefa27eb22b16b4671484499930d6f5745ca87acc84cf2c181` |
| `nvram_net.txt` (redacted) | `b7432c5dd2b15cc986076f5abd43edeb058f6a7c2a6c1b5e0dc1ba476a6193a5` |

The dumps never enter git: `dumps/` is git-ignored,
and `image/tools/build-rootfs` copies both files read-only into a temporary
build context (`firmware/bt/`, `firmware/wifi/`) that it deletes, printing
only their sha256 (build log, MANIFEST). `image/tests/verify-rootfs.sh` compares
the copies in the image with the dumps.

The Wi-Fi firmware itself is not a dump: `image/rootfs/install-wifi.sh` takes
`brcm/brcmfmac4358-pcie.bin` (7.112.300.14) from ALARM's signed
`linux-firmware-broadcom` package and checks it against a pinned sha256.

### 5.2 MAC addresses: nothing to configure per tablet

The NVRAM's `macaddr` is the same on every SM-T715 (Android injects the
real one from EFS through bcmdhd), and the BCM4358 comes up with
Broadcom's default Bluetooth address. Linux never reads or writes EFS.
Instead `t715-wifi-addr` (udev) and `t715-bt-addr` (a template unit) derive
a stable, locally administered address from the eMMC CID, hashed with a
fixed label, and log neither (`image/rootfs/overlay/usr/local/sbin/`, copied
byte for byte from `image/rootfs/overlay/`). NetworkManager keeps
the Wi-Fi one (`wifi.cloned-mac-address=preserve`). So one image serves
every tablet: each gets its own addresses, and the only per-image input
is the SSH key.

### 5.3 The stock BOOT image (TWRP)

Section 6 patches your tablet's own BOOT image, which `patch-stock-boot.sh`
reads from `dumps/stock/boot.img`. Android is not rooted
(`ro.debuggable=0`, no `su`), so the reference got it through TWRP. What
the repositories record:

- TWRP images for `gts28ltexx` were kept with their `.asc` signatures and
  TeamWin's key in `$T715_PRIVATE/twrp/`; 3.7.0_9-0 was flashed,
  3.5.2_9-0 is the one later used to restore RECOVERY:

  ```bash
  adb -s "$S" reboot download
  "src/heimdall/build/bin/heimdall" flash --RECOVERY $T715_PRIVATE/twrp/twrp-3.7.0_9-0-gts28ltexx.img
  ```

- **USB does not work under TWRP on this tablet** (no ADB, MTP or
  sideload, every official version from 3.2.1 to 3.7.0). So
  `device/android/phase1_backup_twrp.sh`, which reads partitions over ADB in
  TWRP, could not run. The backup was made in TWRP's touch interface to
  internal storage (Boot, EFS, m9kefs1-3, Modem, Modem-CDMA, System), then
  copied under Android with ADB. System (2.7 GB) stayed on the tablet:
  Android 7's adbd drops 1.6 GB files over USB.
- `dumps/stock/boot.img` is TWRP's `boot.emmc.win` from that backup
  (14680064 bytes, same sha256), copied by hand. The reference's sha256 is
  `69adbee3d5b9fca6434937e36290a706400851f46614e36e790bf6359bda1de6`.

Not recorded: how TWRP was started after the flash (Android's
`flash_recovery` would have replaced it at the next Android boot), the
exact `adb pull` and copy commands, and the TWRP backup's path on the
tablet. Keep the TWRP backup, EFS included, in
`$T715_PRIVATE/backups/`: it is the only way back if EFS is ever
damaged, and `dumps/stock/boot.img` is the only copy of the
unpatched BOOT.

## 6. One-time change: keep Android from rewriting RECOVERY

The stock ramdisk's `init.rc` starts `flash_recovery`
(`/system/bin/install-recovery.sh`), which rewrites RECOVERY with the
stock recovery at every Android boot. The flash scripts boot Android
between the heimdall flash and `adb reboot recovery`, so without this
change the Linux RECOVERY is gone before it ever runs.

`boot/patch-stock-boot.sh` changes exactly two ramdisk files and
keeps everything else bit for bit (kernel, DTBH, header fields but
`ramdisk_size` and `id`, the `SEANDROIDENFORCE` footer and signature
block):

- `init.rc`: `class main` of `service flash_recovery` becomes `disabled`;
- `default.prop`: `service.adb.tcp.port=5555` is appended, so adbd also
  listens on TCP 5555 from boot (Wi-Fi ADB). RSA authentication
  (`ro.adb.secure=1`) is unchanged, but adbd is now reachable from your
  network.

```bash
python3 -m unittest discover -s boot/tests -v
bash boot/patch-stock-boot.sh          # -> out/stock-patched/{boot.img,*.diff,SHA256SUMS}
cat out/stock-patched/init.rc.diff out/stock-patched/default.prop.diff
adb -s "$S" reboot download
src/heimdall/build/bin/heimdall flash --BOOT out/stock-patched/boot.img
# once Android is back:
adb -s "$S" shell getprop init.svc.flash_recovery    # empty: the service never started
```

The reference's patched image has sha256 `15781c88798ecf4a...`. To go back
to stock Android:

```bash
src/heimdall/build/bin/heimdall flash --BOOT dumps/stock/boot.img
```

With the stock BOOT back, `flash_recovery` runs again and, by the patch
script's own notes, rewrites RECOVERY with the stock recovery at the next
Android boot (not tried on the reference). The documentation of this step
(`out/stock-patched/README.md`, written by the build) is
git-ignored; only `docs/journal/PROGRESS.md` and the script header record it.

## 7. Build the boot side (`kernel/`, `boot/`)

The recipe of `device/README.md` ("Daily image recipe").

### 7.1 Kernel and modules

```bash
bash kernel/kbuild-mainline.sh
```

It builds the Docker image `t715-kbuild` if missing
(`kernel/docker/kbuild.Dockerfile`, Debian trixie arm64 with the
`arm-linux-gnueabihf` cross compiler), configures `gts28ltexx_defconfig`,
builds `zImage`, the `exynos5433-gts28ltexx*` DTBs and the modules out of
tree in the Docker volume `t715-kbuild-out`, and copies `zImage`, the
DTBs, `.config`, `System.map` and `modules.tar.xz` to
`out/mainline/`. It fails if `zImage` exceeds 9 MiB, then runs an
arm64 non-regression build. `--clean` rebuilds from scratch.

Which commit: the daily kernel on 2026-10-29 is
`6.12.114-00021-g9497112f2f9b-dirty`, whose content equals `9f6393b0e`
(revert of the DECON System MMUs). The branch HEAD `dc1fc95fb` only adds a
GPU devfreq design that the board does not include (`docs/journal/HANDOVER.md`).
The fragments that `boot/README.md` still names
(`gts28ltexx_initramfs.config`, `gts28ltexx_m2.config`) no longer exist:
`gts28ltexx_defconfig` holds what the initramfs needs (loop, overlayfs,
configfs ECM).

### 7.2 Daily initramfs

```bash
bash boot/build-initramfs.sh --out out/initramfs-daily --knobs "t715.usbfn=ecm t715.failwait=300" --modules out/mainline/modules.tar.xz
```

`--modules` must be the `modules.tar.xz` of the kernel you pack: the
initramfs inserts its `gpu-sched` and `panfrost` and copies its whole
`lib/modules/<release>` into the root (the image has no modules).
`--knobs` bakes knob defaults into `/etc/t715-knobs`; the kernel command
line is nearly full (sboot's line takes about 986 of 1023 bytes), so
knobs go here. The daily image has no `returnafter` and no `autotest`.
Since commit `435265c` the initramfs also carries a static e2fsck and can
boot a persistent root (11.6); the same image boots read-only images as
before. Host-side tests, which never touch the tablet:
`bash boot/tests/test_initramfs.sh`.

### 7.3 RECOVERY image

```bash
bash boot/pack-test-recovery.sh --initramfs out/initramfs-daily/initramfs.cpio.gz --out out/test-recovery-daily
cat out/test-recovery-daily/SHA256SUMS
```

It packs `out/mainline/zImage`, the board DTB (with 8 KiB of
room for sboot's edits, in a DTBH entry for hw_rev 9-255) and the
initramfs into a boot image with the official TWRP header layout
(`SYSMAGIC000RU`, same addresses, `SEANDROIDENFORCE` footer), and refuses
anything over the 16 MiB partition. `flash-daily.sh` flashes exactly
`out/test-recovery-daily/recovery.img`. Keep the previous
`recovery.img` that booted: it is your way out of a boot loop (13.).

## 8. Build the Omarchy image (`image/`)

`docs/image/REPACK.md`, `docs/image/PACKAGES.md`, `docs/image/ROOTFS.md`.
Everything runs in Docker; the Mac only moves whole files.

```bash
image/tools/repack-omarchy                    # Omarchy's packages for armv7h -> image/out/repo/armv7h
image/tools/build-pkg hyprgraphics            # the Hyprland text-drawing deadlock fix
image/tools/build-pkg omamobile-omarchy       # before omamobile-shell, which depends on it
image/tools/build-pkg omatel-agent            # telephony: the agent, then its apps
image/tools/build-pkg omaphone
image/tools/build-pkg omamessages
image/tools/build-pkg omamobile-shell
image/tools/build-pkg t715-camera
image/tools/build-pkg t715-chromium
make -C modem/loader docker-cross             # the modem stack
image/tools/stage-t715-modem
image/tools/build-pkg t715-modem
image/tools/build-rootfs --ssh-pubkey ~/.ssh/id_ed25519.pub     # 1-2 h from scratch
image/tests/verify-rootfs.sh image/out/rootfs-omarchy.img ~/.ssh/id_ed25519.pub
(cd out && shasum -a 256 -c rootfs-omarchy.img.sha256)
md5 -q image/out/rootfs-omarchy.img          # needed by the push script
```

- `image/tools/repack-omarchy` downloads the `image/tools/repack.list` packages from
  `https://pkgs.omarchy.org/stable/aarch64`, checks the upstream signatures
  with the keyring pinned in `image/tools/omarchy-trusted.fpr`, copies the
  `any` ones, retags `omarchy` and `omarchy-settings` as `armv7h` (after
  checking they hold no ELF file) and indexes `image/out/repo/armv7h`
  (`t715-omarchy.db`). It stops with `UNPINNED KEY` if Omarchy rotates
  its key (`docs/image/REPACK.md` says what to check).
- `image/tools/build-pkg NAME` builds `image/pkg/NAME/PKGBUILD` with makepkg in
  `t715-omarchy:dev-armv7h` (qemu: a C++ library takes minutes) and adds
  it to the same repository, which the image build puts before `[core]`.
  `verify-rootfs.sh` fails if hyprgraphics is not the `.1` rebuild.
- `image/tools/build-rootfs` needs `image/out/repo/armv7h/t715-omarchy.db`, the two
  dumps of 5.1 in `dumps/` or `$T715_DUMPS_DIR` (exact sizes) and an OpenSSH
  public key (root and alarm get it; SSH is key-only). It imports the
  ALARM `armv7` tarball (MD5-checked; reused read-only from
  `legacy/phosh/cache` if present), builds
  `image/rootfs/Dockerfile` under qemu, runs the smoke check in the final image
  and writes `image/out/rootfs-omarchy.img` (raw ext4, label `ALARM`, content +
  20 %, 4032 MiB on 2026-10-29), its `.sha256` and
  `image/out/rootfs-omarchy.MANIFEST`. Log: `image/cache/rootfs-omarchy-build.log`.
  Options: `--size MiB`, `--keep-image`, `--no-cache`.
- `image/tools/build-rootfs --public` builds the image for a release: no SSH key
  and neither vendor file. At boot the initramfs copies the NVRAM and the patch
  RAM from the tablet's SYSTEM partition, read-only, and installs
  `media/0/linux/authorized_keys` if the root has no key. Check it with
  `image/tests/verify-rootfs.sh IMAGE none`.
- `image/tests/verify-rootfs.sh` reads the image read-only in a helper container
  and prints `PASS`/`FAIL` per check and `RESULT: PASS|FAIL` (247 checks
  on 2026-10-29). It also compares the USB link, Bluetooth and Wi-Fi files
  with `image/rootfs/overlay`, and the firmware copies with the dumps: a
  failure there after those files change means the image must be
  rebuilt.
- Optional off-device tests: `image/tests/test_repack.sh`,
  `image/tests/test_hyprgraphics.sh`, `image/tests/test_t715_keys.sh`.

The build needs network access (ALARM mirrors, `os.archlinuxarm.org`,
`pkgs.omarchy.org`, the PKGBUILDs' sources). Docker objects it leaves:
images `t715-omarchy:base-*`, `t715-omarchy:dev-*`,
`t715-omarchy-rootfs-helper`, volumes `t715-omarchy-*`, BuildKit cache
(`docker builder prune` drops it).

The image has fixed settings: hostname `gts28lte-omarchy`, `LANG=en_US.UTF-8`,
time zone UTC, US QWERTY first on the on-screen keyboard, French AZERTY second.
No build option changes them; they are set in
`image/rootfs/configure-system.sh` and `image/rootfs/omarchy-user-setup.sh` and
asserted by `image/rootfs/smoke-check.sh` and `image/tests/verify-rootfs.sh`.

## 9. First deployment

The device scripts (`device/`, every one ran on the tablet)
expect the tablet on USB, in Android or in Linux; each first sends a
running Linux back to Android with `systemctl reboot`. Each wait for
Android also
waits up to 60 s for the Phosh image `/sdcard/linux/rootfs.img`; without
it the scripts simply wait that minute.

The scripts assume `/sdcard/linux` exists, and the order for a new tablet
is not documented. This one is fully scripted: flash RECOVERY first (its
first Linux boot finds no image and returns to Android by itself), then
push the image, which boots it.

### 9.1 Create the image directory (Android)

```bash
adb -s "$S" shell mkdir -p /sdcard/linux
```

### 9.2 Flash RECOVERY

```bash
bash device/flash-daily.sh
```

What it does: waits for Android, removes the test files from
`/sdcard/linux` and writes `rootfs-omarchy.img` into `rootfs.select`
(`sync; sleep 45; sync`), `adb reboot download`, waits for
`heimdall detect`, runs `heimdall flash --RECOVERY
out/test-recovery-daily/recovery.img`, waits for Android again,
`adb reboot recovery`, waits up to 400 s for SSH and prints the kernel
release, the initramfs's `rootfs.select` line and `systemctl
is-system-running`.

On this first run there is no image yet, so the initramfs logs
"rootfs.select: rootfs-omarchy.img not found", then "root image ... not
found", keeps its debug shell up for 300 s and restarts to Android, and
the script ends without SSH. Use that window to check the new kernel:

```bash
nc 172.16.42.1 23      # the initramfs shell, root, no password, USB only
# then, back in Android:
adb -s "$S" shell cat /proc/last_kmsg | grep t715-initramfs
```

For any other RECOVERY image (a test build), use
`bash device/flash-boot.sh IMG`: the same sequence without the
`/sdcard/linux` changes. `flash-boot.sh /dev/null` only reboots into the
current RECOVERY.

### 9.3 Push the image

```bash
T715_ADB_WIFI=<tablet-ip>:5555 bash "device/push-rootfs-image.sh" --select image/out/rootfs-omarchy.img rootfs-omarchy.img "$(md5 -q image/out/rootfs-omarchy.img)"
```

`push-rootfs-image.sh [--select] IMAGE NAME MD5`:

1. checks the image's md5 against the one given, compresses it with
   `gzip -1` into `$T715_GZ_DIR` (default `$TMPDIR`) as
   `NAME-MD5.gz`, kept and reused on a later run;
2. waits for Android on USB, then 60 more seconds (post-boot load), runs
   `adb tcpip 5555` and `adb connect $T715_ADB_WIFI` (required), shows
   `df -h /sdcard`;
3. pushes `NAME.new.gz` over Wi-Fi ADB, up to three times until the size
   matches, decompresses it on the tablet, compares `md5sum` with the one
   given, renames it over `NAME`; with `--select`, writes `NAME` into
   `rootfs.select`; then `sync; sleep 45; sync`;
4. `adb reboot recovery` over USB, waits up to 400 s for SSH and prints the
   kernel, `os-release`, the `rootfs.select` line, `systemctl
   is-system-running` and the time zone link.

It writes nothing but `/sdcard/linux`. Free space on `/sdcard` must hold
the old image (when replacing), the `.gz` and the new image at once; the
script does not check it. Keep the USB cable in: the reboots go over USB.
On the reference link, Wi-Fi ADB moved 256 MiB in 85 s.

Updates later: a new image is 8. then 9.3 again; a new kernel is 7. then
`flash-daily.sh` (the image stays).

## 10. Booting, switching images, leaving Linux

| To | Do |
|---|---|
| boot Linux from Android | `adb -s "$S" reboot recovery` (USB or Wi-Fi ADB), or `bash device/flash-boot.sh /dev/null` |
| check what booted | `device/tssh 'uname -r; grep rootfs.select /run/t715/initramfs.log; systemctl is-system-running'` |
| go back to Android | `device/tssh 'systemctl reboot'` |
| power off | `systemctl poweroff`: the kernel powers off through PS_HOLD (`docs/journal/PROGRESS.md`, 2026-10-28); not described for Omarchy |

Never leave Linux through a hang, a watchdog or a long hardware key press:
`t715-keys` acts on a press held 0.6 s, and nothing should hold a key
longer than a second (`docs/image/ROOTFS.md`).

Switching images, from Android (`boot/README.md`, "Choosing
another image"):

```bash
adb -s "$S" shell 'echo rootfs-omarchy.img > /sdcard/linux/rootfs.select'   # next boots use it
adb -s "$S" shell 'rm /sdcard/linux/rootfs.select'                          # back to rootfs.img
adb -s "$S" shell 'sync; sleep 45; sync'
adb -s "$S" reboot recovery
```

The name must be a bare file name (letters, digits, `.`, `_`, `-`, not
starting with `.`) ending in `.img`, in the same directory. The log says
`rootfs.select: booting NAME`, or a WARNING and the default image.

**`t715.returnafter=SECS`** is for unattended test boots: SECS seconds
after the hand-over, the initramfs's timer restarts the board to Android
through SysRq `b` (a software reset) and forwards the journal to the
kernel log, readable afterwards in `/proc/last_kmsg`. The Omarchy slots 2
and 3 ran with `returnafter=5400`. Build such an image apart from the
daily one, flash it with `flash-boot.sh`, and put the daily one back with
`flash-daily.sh`:

```bash
bash boot/build-initramfs.sh --out out/initramfs-slot --knobs "t715.usbfn=ecm t715.failwait=300 t715.returnafter=5400" --modules out/mainline/modules.tar.xz
bash boot/pack-test-recovery.sh --initramfs out/initramfs-slot/initramfs.cpio.gz --out out/test-recovery-slot
bash device/flash-boot.sh out/test-recovery-slot/recovery.img
```

The other knobs (`t715.shell`, `t715.rootwait`, `t715.modules`,
`t715.modblacklist`, `t715.wdtguard`, `t715.autotest`, `t715.rootimg`) are
listed in the header of `boot/initramfs/init` and in
`boot/README.md`.

## 11. First boot on Omarchy

### 11.1 What happens

`docs/image/ROOTFS.md`, "Expected first boot". Slot 2 measured 7.4 s of
kernel and 9.8 s of userspace; the shell's home and dock appear some
seconds after the shell starts (9.3 s for a cold shell restart).

1. `usb-rndis.service` brings up the ECM gadget, `172.16.42.1/24` on
   `usb0`, with its own dnsmasq (DHCP `.2` to `.10`, no router, no DNS: your
   host's internet stays as it is). sshd answers with your key.
2. NetworkManager (Wi-Fi through wpa_supplicant on brcmfmac),
   systemd-resolved, avahi, bluetoothd, power-profiles-daemon and
   systemd-oomd start; nothing waits for a network.
3. SDDM logs `alarm` in without a greeter into `omarchy.desktop`
   (Hyprland at scale 2 on the 1536x2048 panel, 768x1024 logical, then the
   Omarchy shell with the touch shell's bar, home screens and dock);
   `t715-keys` and `t715-squeekboard` start with the session.
4. In image mode every boot is Omarchy's first login: the overlay forgot
   the last one. A "Setup Wi-Fi" notice opens quick settings and expires.
   On a persistent root (11.6) only the first boot is.
5. Nothing locks or suspends; the screen goes off after two minutes idle
   (`t715-idle.service`), and the power key wakes it.

On screen, with the BOOT image of 11.7 (kernel `00024`, `t715.quiet=1`):
the Samsung logo, the Omarchy splash from about 11 to 14 s (Plymouth),
then the session, about 25 s after power-on. sboot builds the kernel
command line itself and drops the boot image header's (checked with
`pack-test-recovery.sh --cmdline`), so `quiet` and `splash` cannot be
added there; instead the initramfs lowers the console loglevel
(`t715.quiet=1`), a drop-in gives `plymouthd --kernel-command-line="quiet
splash"`, and systemd runs with `ShowStatus=auto`. The rescue in RECOVERY
keeps the scrolling text. The orange kernel lines that scrolled before
(dummy regulators, brcmfmac's board-specific firmware names it tries
first, PCIe MSI) were warnings, not errors. The splash needs the kernel
fix of 13., "A black screen": with kernel `00021` it made those black
screens more frequent.

### 11.2 Getting in

```bash
"device/tssh"                 # root@172.16.42.1, key only
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null alarm@172.16.42.1
```

`alarm` (uid 1000) is Omarchy's user: groups `wheel video audio input
network`, ALARM's default password `alarm`, passwordless sudo for
`wheel`. `root` is locked; SSH takes keys only, for both users. To run
commands in alarm's session from root:

```bash
A='sudo -u alarm env XDG_RUNTIME_DIR=/run/user/1000'
$A systemctl --user status t715-keys t715-squeekboard omarchy-fcitx5
```

On the screen: a tap or a pull down on the top bar opens quick settings;
on an app, swipe up from the home pill for home, up and hold for recent
apps; a swipe in from the left or right edge is Back. Power short: screen
and touch off and on; Power held 0.6 s: Omarchy's system menu; Home: home,
held 0.6 s: recent apps (`docs/image/ROOTFS.md`, touch layers P1 and P2).

### 11.3 Wi-Fi

Quick settings, Wi-Fi tile, pick the network, type the password with the
on-screen keyboard. The BCM4358 firmware has **no SAE (WPA3)**: an SSID
served as WPA3 and WPA2 joins as WPA2-PSK (the panel creates WPA2-PSK
profiles, `omamobile-shell` 0.2.32-1.2); a WPA3-only network cannot be
joined. The profile and its password live in the RAM overlay: **re-enter
them after every reboot**. Once connected, systemd-timesyncd sets the
clock; nothing writes the RTC, which stays Android's.

### 11.4 Sound and Bluetooth

The WM1814 codec plays through the speaker with the image's `wm1814` UCM
profile and `pipewire-pulse` (Firefox needs the latter); the headphone
path is in the profile but was never checked on the device
(`docs/journal/ONDEVICE-2026-10-29.md`; `docs/image/ROOTFS.md`'s "Known gaps" predates
this). `$A wpctl status` lists the sinks. Bluetooth pairs from the quick
settings' Bluetooth panel, and only while it is open (no auto-accept
agent); headsets and speakers play through PipeWire's BlueZ plugin.

### 11.5 What to check

From the host, with the probe fed over SSH (read-only apart from `/tmp`;
it masks addresses):

```bash
"device/tssh" 'bash -s' -- image < image/tests/ondevice/omarchy-probe.sh   # kernel, Hyprland, shim mapped, keys, keyboard, bt-agent, IOMMU
"device/tssh" 'bash -s' -- wifi  < image/tests/ondevice/omarchy-probe.sh   # t715-wifi-addr, brcmfmac, NetworkManager, scan counts, NTP, RTC
"device/tssh" 'bash -s' -- bt    < image/tests/ondevice/omarchy-probe.sh   # t715-bt-addr, firmware, controller, 10 s scan count
```

Its other modes (`report`, `sample N`, `p2`, `shot`, `overlay`, `noshim`)
are described in its header; `noshim` is only for kernels with the DECON
System MMU, which the daily kernel does not have.

On the tablet, as root (`docs/image/ROOTFS.md`, "Bluetooth", "Wi-Fi" and
"Useful on the tablet"):

```bash
systemctl --failed; systemd-analyze
/usr/lib/t715-omarchy/smoke-check
dmesg | grep brcmfmac          # firmware 7.112.300.14, no NVRAM error
nmcli device                   # wlp1s0 managed, usb0 unmanaged
nmcli device wifi list         # 2.4 and 5 GHz networks
dmesg | grep -i bluetooth      # patch RAM loaded
systemctl status t715-bt-addr@hci0
bluetoothctl show              # hci0 powered, not 43:58:A3:...
journalctl -b -u sddm; journalctl -b _UID=1000
```

The interface addresses must be locally administered (second hex digit 2,
6, A or E). Keep command output with addresses, CIDs or network names out
of git and messages.

### 11.6 Making it permanent: the persistent root

For a tablet that keeps no Android (the reference tablet's owner decided
so on 2026-10-29). Everything changed in Omarchy then survives reboots:
Wi-Fi networks, pairings, settings, Firefox's profile, the journal. How it
works: `boot/README.md`, "Persistent root". This is phase 1
of 3; phases 2 (Linux in BOOT) and 3 (removing Android's data) are in
11.7. The reference tablet went through all three on 2026-10-29.

1. A RECOVERY image whose initramfs knows `persist=` (commit `435265c` or
   later; 7.2, 7.3), flashed as in 9.2. The reference tablet runs
   `out/test-recovery-daily-persist/recovery.img`: kernel
   `00021` from `out/mainline-daily-00021/`, knobs
   `t715.usbfn=ecm t715.failwait=300`.
2. The image pushed as in 9.3. Free space on USERDATA must hold its use
   (3.2 GiB for Omarchy) plus 512 MiB: the seed checks it.
3. From Android, add the second line to `rootfs.select`, then sync:

   ```bash
   adb -s "$S" shell 'printf "rootfs-omarchy.img\npersist=omarchy\n" > /sdcard/linux/rootfs.select'
   adb -s "$S" shell 'sync; sleep 30; sync'
   adb -s "$S" reboot recovery
   ```

4. The first boot copies the image into `USERDATA/omarchy` with a dark
   screen: 150 s on the reference tablet (3200 MiB, 2026-10-29), then
   Omarchy starts as usual. The log says `USERDATA/omarchy seeded in
   150s` and `persistent root on /newroot`.
5. Check: `findmnt /` shows `/dev/mmcblk0p22[/omarchy] ext4 rw`, and
   `/.t715-persist` names the seed image.

Then each boot runs `e2fsck -p` on USERDATA (under a second when clean)
and mounts the same directory. Leaving Linux is still `systemctl reboot`
(back to Android until phase 2). Rescue: a RECOVERY image with
`t715.persist=0` boots the image file read-only, as before; the image file
on `/sdcard/linux` stays for that. Updating the image file does not update
the persistent root: it was seeded once.

What the reference tablet showed (`docs/journal/ONDEVICE-2026-10-29.md`,
"Persistent root"): the copy kept the image's 18 setuid files and 2879
multiply-linked files; machine ID, SSH host keys, a saved Wi-Fi network
and a test file survived a reboot through Android.

A persistent root keeps the owner's data, so a new image never reaches it. Packages
go on with `pacman -U`, and the rest of what a new image has with:

```bash
bash device/parity-sync.sh
```

### 11.7 Without Android: Linux in BOOT, Android's data removed

Once the persistent root runs (11.6), Linux can take BOOT, so the tablet
starts Omarchy at power-on and on every reboot, and RECOVERY becomes a
rescue system. Each step needs the owner's yes: Android stops booting
after step 3, and step 5 cannot be undone.

1. **Two boot images** (same kernel and modules for both). BOOT:
   the persistent root, with the image path and the root's name baked in
   so that nothing depends on `rootfs.select` any more. RECOVERY: the
   rescue, which boots the image file read-only and also boots after a
   watchdog reset (sboot then starts RECOVERY) instead of restarting:

   ```bash
   M=out/mainline-daily-00024; R=media/0/linux/rootfs-omarchy.img
   bash boot/build-initramfs.sh --out out/initramfs-boot-omarchy --knobs "t715.usbfn=ecm t715.failwait=300 t715.rootimg=$R t715.persist=omarchy t715.quiet=1" --modules $M/modules.tar.xz
   bash boot/build-initramfs.sh --out out/initramfs-rescue --knobs "t715.usbfn=ecm t715.failwait=300 t715.rootimg=$R t715.persist=0 t715.wdtguard=0" --modules $M/modules.tar.xz
   bash boot/pack-test-recovery.sh --boot --initramfs out/initramfs-boot-omarchy/initramfs.cpio.gz --out out/boot-omarchy $M
   bash boot/pack-test-recovery.sh --initramfs out/initramfs-rescue/initramfs.cpio.gz --out out/recovery-rescue $M
   ```

   `--boot` gives the image the stock BOOT header's name
   (`SYSMAGIC000KU`) and BOOT's 14 MiB limit; it differs from the
   RECOVERY image by that one byte. `t715.quiet=1` gives the quiet boot
   (11.1); the rescue keeps the text console. Reference tablet: `boot.img`
   sha256 `43d05bb5…` (kernel `00024-ged71dc803f16`), rescue
   `recovery.img` `fe94a7c3…` (kernel `00021`).
2. **Keep the current BOOT** (Android's, with the ramdisk changes of 6.)
   in your private backups, from Linux:
   `device/tssh 'cat /dev/mmcblk0p9' > boot-p9-before-linux.img`.
3. **Write both partitions from Linux** (no Download mode needed):

   ```bash
   bash "device/write-part.sh" BOOT "out/boot-omarchy/boot.img"
   bash "device/write-part.sh" RECOVERY "out/recovery-rescue/recovery.img"
   ```

   Each is checked (sha256, size against the partition), written with
   `dd`, and read back after dropping the page cache.
4. **Reboot and check**: `systemctl reboot` now comes back on Linux in
   about 35 s; `/proc/cmdline` has no `bootmode=2` (a RECOVERY boot has
   it) and `findmnt /` shows the persistent root. The rescue:
   `t715-reboot-to recovery` (below) boots the image read-only under its
   RAM overlay; `systemctl reboot` from there goes back to BOOT.
5. **Remove Android's data**, from Linux, once the owner's files are
   copied off and the TWRP backup on the Mac is complete (compare every
   file's sha256 with the tablet's copy): everything at the top of
   USERDATA but `omarchy`, `media` and `lost+found`; everything in
   `media` but `media/0/linux`; there, the old images, keeping
   `rootfs-omarchy.img` (the rescue's image) and `rootfs.select`. Then
   `fstrim -v /run/t715/userdata`. macOS's `tar` drops files whose names start with `._` (AppleDouble).

**`t715-reboot-to recovery|download|normal`** (`/usr/local/sbin`, in the
image from this commit on; copied by hand onto the reference tablet's
persistent root) writes sboot's boot selector, INFORM3 in the PMU, the
way Samsung's kernel does for `reboot recovery` / `reboot download`, reads
it back and reboots with systemctl. Without Android it is the way to
Download mode without the keys: `t715-reboot-to download`, then
`heimdall flash` from the Mac. `--no-reboot` only sets it (`normal
--no-reboot` undoes that).

Updates without Android: a new kernel or initramfs goes through
`write-part.sh` (BOOT first; RECOVERY only once the new one has booted,
so the rescue stays known-good). A new image file goes to
`/run/t715/userdata/media/0/linux/` over `scp` (its checksum compared);
it is the rescue's image and the seed of a new persistent root, it does
not change the running one.

Restoring Android: `heimdall flash --BOOT` with the saved BOOT, then a
factory reset from Android's recovery (its data is gone), or the full
TWRP restore (TWRP flashed to RECOVERY first).

Charger: powered off with `systemctl poweroff` while plugged into the
Mac, the reference tablet stayed off (no Linux, no USB device for 20
minutes). The power key then started it from BOOT with
`androidboot.mode=charger` on the command line, sboot's request for
Android's charging screen; the initramfs ignores it and Omarchy starts as
usual (cold boot checked on 2026-10-29: e2fsck clean, persistent root,
Wi-Fi connected on its own). Not recorded yet: what the screen shows while
off on USB, whether it charges while off, and what plugging a charger
into a tablet that is off does.

### 11.8 With the modem

`docs/hardware/MODEM.md` describes the stack. The daily kernel with the modem
is the branch `t715-modem` (`t715-bringup` + `kernel/patches/t715-modem/`), in
its own output directory. Then the same BOOT as in 11.7, with the modem
modules kept off the automatic load:

```bash
KBUILD_OUT_DIR=$PWD/out/mainline-modem KBUILD_SKIP_ARM64=1 bash kernel/kbuild-mainline.sh --fragment gts28ltexx_modem.config
```

```bash
M=out/mainline-modem; R=media/0/linux/rootfs-omarchy.img; bash boot/build-initramfs.sh --out out/initramfs-boot-modem-persist --knobs "t715.usbfn=ecm t715.failwait=300 t715.rootimg=$R t715.persist=omarchy t715.quiet=1 t715.modblacklist=exynos5433_mipi_lli,sec_modem_v1,spi_s3c64xx" --modules $M/modules.tar.xz
```

```bash
bash boot/pack-test-recovery.sh --boot --initramfs out/initramfs-boot-modem-persist/initramfs.cpio.gz --out out/boot-modem-persist out/mainline-modem
```

```bash
bash device/write-part.sh BOOT out/boot-modem-persist/boot.img
```

The daily kernel is now `t715-parity`, the same commands with
`T715_KERNEL_DIR=$PWD/src/linux-modem-lli KBUILD_OUT_DIR=$PWD/out/mainline-parity`: the touch
keys and the vibration motor load by themselves. Check that a kernel for BOOT holds the DECON
fix `ed71dc803`, and write the rescue back to RECOVERY first when a test kernel took it.

The packages (`docs/image/PACKAGES.md`): the loader first
(`make -C modem/loader docker-cross`), then:

```bash
image/tools/stage-t715-modem
```

```bash
image/tools/build-pkg t715-modem
```

An existing persistent root takes them with `pacman -U`; a new image has them
through `image/rootfs/packages.mobile`. The first boot on a kernel with the
modem makes the NV copy from EFS, read only (`shannon-nv-provision.service`);
the NV never goes into the image, it holds the device's identity.

### 11.9 With the GPS

The GPS needs the kernel of `kernel/patches/t715-gps` in BOOT (UART0, `CONFIG_GPIO_SYSFS`) and
`t715-gps` with `omamobile-shell` 1.15 or later, which a persistent root takes with `pacman -U`.
Nothing else: the first `omamobile-gnss on`, from the Location tile, copies `gpsd` from SYSTEM. Check
with `image/tests/ondevice/t715-gps.sh`, as root on the tablet, Wi-Fi or LTE connected.

## 12. Known limitations

From `docs/journal/HANDOVER.md`, `docs/image/ROOTFS.md` and the `ONDEVICE` reports.

- **Persistence needs the persistent root (11.6).** In image mode the root
  is a RAM overlay over a read-only image: settings, Wi-Fi profiles, logs,
  installed packages and files are gone at each reboot, and the overlay's
  contents take RAM (3 GB in all). The persistent root keeps them, on a
  tablet without Android. The screen lock is ready and off until the owner sets a
  PIN (`docs/image/ROOTFS.md`, "Screen lock").
- **No cpufreq**: both clusters stay at 1.2 GHz. **No GPU frequency
  scaling**: the Mali-T760 stays at its 266 MHz boot clock (a design
  exists, not in the board).
- **No suspend**: the sleep targets are masked, the cover only darkens the
  screen.
- **Modem**: calls, SMS and mobile data need the modem BOOT (11.8); the
  BOOT of 11.7 does not carry the modem series. `docs/hardware/MODEM.md`
  lists the gaps.
- **Battery**: read-only fuel gauge; the charger driver sets stock's limits
  and thermal rules (`docs/hardware/BATTERY.md` §8), with a real input near
  1.5 A. A tablet that stays warm charges by steps above 80 %.
- **Wi-Fi**: WPA2 only; regulatory country 99 without `clm_blob`, so
  channels 149-165 are off. A saved network connects about 3.5 s after
  wpa_supplicant starts (eleven boots out of twelve on 2026-10-29, first
  attempt). The one exception, the first boot after the network was
  saved, saw two 4-way handshake timeouts (reason 15, logged as "psk
  mismatch") before connecting with the same key a minute later; most
  likely the access point holding off a station that had just sent a
  wrong key, not proven.
- **DECON System MMU off** in the daily kernel, so Hyprland needs the
  image's dmabuf-check shim (`/usr/local/lib/t715-dmabuf-check-shim.so`).
  Its `GEM_CLOSE` fallback stopped the buffer leak that blacked the screen
  out after about 20 minutes; a long session has not been measured yet.
- **Applications**: Chromium is Debian's, in a root of its own, and opens Omarchy's
  web apps; Firefox stays beside it, rendering on the CPU (SWGL);
  no Ghostty, Walker, mise, LocalSend,
  Obsidian, Neovim (vim instead); several of Omarchy's own compiled tools
  do not exist for armv7h. `pacman -S` works, updates go through `omarchy
  update`, and Hyprland's family is held back: `docs/image/ROOTFS.md`,
  "Installing software". Do not bypass the guard. In image mode anything
  installed is lost at reboot.
- **Touch**: rotation off by default (`docs/image/ROTATION.md`); apps and some of Omarchy's
  windows still assume a keyboard. The OWL home widgets are off.
- **Sensors** work in the kernel but are not used by the image.
- Hyprland's debug overlay (`debug:overlay`) once deadlocked Hyprland;
  the hyprgraphics rebuild fixed it, but leave it off.

## 13. Troubleshooting (learned the hard way)

- **No SSH, the tablet looks fine.** The Mac's screen is locked (3.2), or
  the cable is out. To test without the network or an unlocked Mac,
  `autotest-run.sh` boots a **test** image built with `t715.autotest=1` and
  reads the result back from Android (`device/README.md`; its
  check script waits for Phosh and was not written for Omarchy).
- **ADB disappears.** Chrome holds the interface (3.2). During `adb reboot`
  ADB drops for a few seconds while Android reconfigures USB; the scripts
  retry three times.
- **A large `adb push` stalls.** USB ADB does that; use Wi-Fi ADB, and wait
  60 s after Android finishes booting before a long push (the push script
  does both).
- **The new image or `rootfs.select` is ignored.** USERDATA is mounted with
  `noload`: run `sync; sleep 45; sync` in Android before rebooting. Check
  `/run/t715/initramfs.log` (Linux) or `last_kmsg` (Android).
- **Linux never answers.** The initramfs failed: within 300 s,
  `nc 172.16.42.1 23`; afterwards in Android, `adb -s "$S" shell cat
  /proc/last_kmsg | grep t715-initramfs`. It names the first missing path
  of a missing image, an encrypted or non-ext4 USERDATA, or several
  partitions named USERDATA.
- **"USERDATA journal was not replayed"**: Android did not unmount it
  cleanly; recently written files may look stale. Reboot to Android, sync,
  wait, retry.
- **Linux frozen: ping answers, sshd sends no banner.** The kernel pings
  its watchdog, so nothing resets the tablet. Hold Power + Volume down
  about 10 s. On 2026-10-29 that did not bring a system up; the owner
  entered Download mode, `heimdall flash --RECOVERY` of the daily image
  ran from there, and sboot then booted RECOVERY (Linux) directly, not
  Android. Read `/sys/fs/pstore/` before anything reboots Linux again:
  the next reboot replaces the hung boot's console
  (`docs/journal/ONDEVICE-2026-10-29.md`, "The hung boot's kernel log").
- **USB link: the Mac gets 169.254.x.x, no 172.16.42.x.** The tablet's
  DHCP server (dnsmasq, `usb-rndis.service`) ran out of leases: before
  commit `4d3de3a` ("usb-rndis dnsmasq: leases in /run"), a persistent root kept one
  12 h lease per boot (the host side of the gadget gets a new MAC address
  at each boot) and nine boots used up the range. The tablet still
  answers on IPv6 link-local: find it with `ping6 -c3 ff02::1%enX` and
  `ssh root@fe80::...%enX`, then `rm /var/lib/misc/dnsmasq.leases` and
  restart that dnsmasq (`dnsmasq --conf-file=/etc/usb-rndis/dnsmasq.conf`
  once the old one is gone; `pkill -f` with that pattern also kills the
  SSH shell running it).
- **A black screen: at boot, or a reboot that hangs** (about 110 s, or
  until a forced restart), with kernels before `00024`. exynos-drm logged
  "flip_done timed out" then "commit wait timed out" every 10 s: an
  atomic commit whose frame never ended, everything after it waiting
  behind it. On 2026-10-29 it came after display hand-overs (fbcon's first
  modeset when exynos-drm binds, fbcon taking the panel back when
  Plymouth's splash ended, Hyprland's exit at shutdown), in about one
  boot-and-reboot cycle in ten to fifteen, more with the splash. Cause, in
  the kernel commit `ed71dc803` ("drm/exynos: decon5433: unmask the hardware trigger
  only at flush"): with no "te" interrupt in the board's DT the DECON runs
  on the hardware trigger, and the driver unmasked TE first in
  atomic_enable, before the MIC, the DSI host and the panel were enabled,
  so a TE edge could start a frame that the pipe behind never drained; at
  bind it also gated the clocks with the bootloader's frames still
  running. The fix unmasks TE at the first flush and lets the frame in
  flight end before the clocks stop: 40 cycles in 40 clean with the
  splash, then the daily kernel `00024`. The kernel logs "no frame end 200
  ms after a flush" with the DECON's registers if a stall ever comes back.
  Userspace tries that did not help: `drm_kms_helper.fbdev_emulation=0`
  (exynos-drm sets its fbdev up through its own client) and masking
  Plymouth's shutdown screens (they stay masked: one hand-over less). A
  forced restart (Power + Volume down, about 10 s) recovers.
  `image/tests/ondevice/drm-hang-watch.sh` snapshots the display pipe's
  registers at the first timeout (installed on the reference tablet), and
  `t715-shutdown-log.service` keeps the last shutdown steps in pstore
  (`grep -E 'shutdown\[1\]|flip_done' /sys/fs/pstore/console-ramoops-0`).
- **Boot loop into RECOVERY.** A watchdog reset leaves INFORM3 cleared and
  sboot boots RECOVERY again. The initramfs guard restarts to Android
  after a watchdog reset, but a kernel that hangs before the initramfs
  (a built-in driver's probe) loops: enter Download mode with the keys
  (Power + Volume down + Home, then Volume up; 4.3) and flash the last
  RECOVERY that booted with
  `heimdall flash --RECOVERY <validated image>` (`docs/hardware/GPU.md` §5), or
  TWRP (`docs/journal/PROGRESS.md`). ramoops keeps the hung boot's console.
- **Kernel warnings.** Count them with `WARNING: CPU`: sshd prints its own
  "WARNING: connection ... post-quantum" lines.
- **Do not read `/sys/kernel/debug/pinctrl/*/pins`**: bus error, panic,
  back to Android.
- **Wi-Fi says "Network out of range" on a network in range.** A profile with
  `key-mgmt=sae` (made by an older panel or by hand). Slot 4 switched it to
  WPA2-PSK with `nmcli connection modify`, and it connected at once; the
  property is NetworkManager's, the docs do not give the command:
  `nmcli connection modify <name> wifi-sec.key-mgmt wpa-psk`.
- **pacman: "Landlock is not supported by the kernel".** A BOOT without the
  modem series' Landlock patch, such as the rescue or `out/boot-omarchy`.
- **`image/tools/build-rootfs`: "... is not 6053 bytes".** The NVRAM was pulled
  without the dump script's redaction (5.1).
- **`verify-rootfs.sh` fails on the Wi-Fi or USB files.** They changed in
  `image/rootfs/overlay` since the image was built: rebuild the image.
- **Black screen with the shell restarting in a loop.** Without the shim
  (or with an old one), Hyprland's linux-dmabuf check and Mesa's kmsro
  imports kill or leak GPU clients (`docs/journal/ONDEVICE-2026-10-28.md`,
  `docs/journal/ONDEVICE-2026-10-29.md`). Check that `omarchy-probe.sh image`
  reports the shim mapped.
- **The tablet stops answering on USB after the cable went in and out.** The Mac keeps listing
  `SM-T715 RNDIS` on a port with nothing on it (`ioreg -p IOUSB`), and more than one
  `AppleUserECM` driver runs for one tablet. Seen on both of the Mac's ports. Changing port helped
  once; restarting the Mac cleared it. Download mode still works, so it is not the connector.
- **Behind a display's USB hub there is no IP link.** The tablet enumerates at high speed and
  receives, but `usb0` sends nothing: TX 0, dropped 15. Why is not established. Use a port of the Mac.

## 14. Gaps: what no doc or script covers yet

Most important first.

1. *Closed in 0.9.0:* the 46 patches of `kernel/patches/` rebuild the daily
   kernel on `v6.12.114`.
2. **The stock BOOT dump needs TWRP, and its procedure is not recorded**:
   TWRP download and signature check, entering TWRP before Android
   overwrites it, the backup choices, the pull and copy commands.
   `phase1_backup_twrp.sh` cannot work (no USB under TWRP). Taking
   `boot.img` from Samsung's T715XXU2CRH1 firmware package instead, or
   reusing the reference's patched BOOT on another tablet with the same
   firmware, is untested.
3. **The patched BOOT is required but only half-documented.**
   `HANDOVER.md` and `device/README.md` say "RECOVERY only"; the
   step lives in `docs/journal/PROGRESS.md` (French) and a git-ignored README.
4. **Heimdall** is not in the repositories and its build is not recorded
   (section 3.4 follows its upstream README).
5. **Hardware key combination for recovery** is not recorded (Download
   mode: Power + Volume down + Home, then Volume up; 4.3).
6. **OEM unlocking, FRP and Google account state** of the reference tablet
   are not recorded; whether a tablet with OEM unlocking off accepts the
   flashes is unknown.
7. **One firmware and one board revision tested** (T715XXU2CRH1, hw_rev 9).
   `pack-test-recovery.sh` hard-codes the DTBH range `9:255`.
8. *Closed in 0.9.0:* the scripts find the tablet by its ADB model. That
   change was not run on a tablet: the reference has no Android any more.
9. **First-deployment order** is not documented: the scripts assume
   `/sdcard/linux` exists, and they wait for the Phosh `rootfs.img`.
   Section 9 is derived from the scripts.
10. **macOS-only commands**: `stat -f %z` in `kbuild-mainline.sh`,
    `push-rootfs-image.sh` and `patch-stock-boot.sh`. Linux hosts (and
    x86_64 hosts, which would emulate the arm64 containers too) are
    untested.
11. **`T715_ADB_WIFI`** is required: nothing finds the tablet's address.
12. **The case-sensitive volume** for `src/` and its creation are
    not documented.
13. **Fixed settings** (US English, QWERTY first, UTC, hostname) have no build option and are asserted by the
    checks.
14. **Docker resources** (disk, memory) for the Omarchy build are not
    measured; the Phosh builder notes about 10 GB inside Docker.
15. **Stale notes**: `docs/image/ROOTFS.md` "Known gaps" (no sound card, Wi-Fi and
    Bluetooth audio untried) and `README.md`'s "does not touch the tablet"
    predate 2026-10-29; `final-interactive.sh` and `t715-autotest.sh`
    target Phosh.
16. `push-rootfs-image.sh` does not check free space on `/sdcard`, and
    keeps its `.gz` in `$TMPDIR`.

## 15. Files

| Path | What |
|---|---|
| `device/README.md` | device scripts, daily recipe, hard-won notes |
| `device/flash-daily.sh`, `flash-boot.sh` | RECOVERY flash and Linux boot |
| `device/push-rootfs-image.sh`, `tssh` | image push over Wi-Fi ADB; SSH to Linux |
| `device/android/phase1_extract_noroot.sh` | vendor dumps without root, redacted |
| `boot/patch-stock-boot.sh` | the patched stock BOOT |
| `kernel/kbuild-mainline.sh`, `build-initramfs.sh`, `pack-test-recovery.sh` | kernel, initramfs, RECOVERY image |
| `boot/initramfs/init`, `boot/README.md` | the initramfs, its knobs, `rootfs.select` |
| `docs/image/ROOTFS.md` | what the image contains and how it is checked |
| `docs/image/REPACK.md`, `docs/image/PACKAGES.md` | Omarchy repack, `image/pkg/` rebuilds |
| `image/tools/repack-omarchy`, `image/tools/build-pkg`, `image/tools/build-rootfs` | the image's build |
| `image/tests/verify-rootfs.sh`, `image/tests/ondevice/omarchy-probe.sh` | offline and on-device checks |
