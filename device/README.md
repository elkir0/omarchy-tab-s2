# Device scripts (SM-T715)

Scripts that drive the tablet from the Mac. They were written during the
2026-10-28/29 sessions, and every one ran on the tablet. They assume:

* the tablet on USB, which they find by its ADB model, `SM_T715` (other
  Android devices may be plugged in; scripts never pick them);
* Linux reachable over the USB gadget at `172.16.42.1` (`tssh`);
* heimdall built in `src/heimdall/build/bin/`;
* raw logs go to `$T715_PRIVATE/boottests` (default
  `$T715_PRIVATE/boottests`), never into the repo.

Safety rules they follow (see `docs/`):

* heimdall writes **RECOVERY only**. Never BOOTLOADER, EFS, RADIO or PARAM.
* USERDATA is changed from Android only (`/sdcard/linux`), followed by
  `sync; sleep 45; sync`. Linux mounts it read-only.
* Leave Linux with `systemctl reboot` (a software reset), never a watchdog.
* No serial number, MAC address or Wi-Fi password in a script, a log in the
  repo or a message.

| Script | What it does |
|---|---|
| `tssh` | SSH to Linux on the tablet as root (no host-key pinning: the RAM overlay changes keys) |
| `flash-boot.sh IMG` | Android → download mode → flash RECOVERY → boot Linux, wait for SSH |
| `flash-daily.sh` | Same with `out/test-recovery-daily/recovery.img`. It first sets `rootfs.select` to `rootfs-omarchy.img` and removes the test files from `/sdcard/linux` |
| `push-rootfs-image.sh [--select] IMAGE NAME MD5` | Replace a root image in `/sdcard/linux` over Wi-Fi ADB: gzip -1 on the Mac, md5 checked on Android before the rename. Then boot RECOVERY |
| `autotest-run.sh [IMG]` | Tests with no network or unlocked Mac. Pushes `$SCRIPT` as `/sdcard/linux/t715-autotest.sh` and boots an image built with `t715.autotest=1`. The script runs as root and the board reboots to Android, where the log is read back from `/proc/last_kmsg` |
| `t715-autotest.sh` | Full hardware check for `autotest-run.sh`: display, audio loopback, battery, sensors, Wi-Fi, Bluetooth |
| `autotest-probe.sh`, `autotest-iommu.sh` | Autotest rounds: display clocks and frame rate, DECON System MMU import |
| `final-interactive.sh` | The full hardware check over SSH (no reboot at the end) |
| `gpu-flow.sh` + `gpu-ssh.sh` | GPU devfreq test (`docs/hardware/GPU.md` §10): test image booting Phosh through `t715.rootimg`, stepping over SSH, then the daily image back |
| `leak-test.sh`, `leak-test2.sh`, `anim-test.sh` | dma-buf leak measurements under Omarchy (`docs/hardware/IOMMU.md` §12): buffers attached to DECON, Shmem, around panel open/close cycles |
| `dmabuf-test/` | `dmabuf-import-test.c` (allocates a panfrost buffer, imports it into exynos-drm) and `vblank-wait.c` (counts vblanks for 6 s). libc-free, built with the command below |

`t715.autotest=1` is for **test images only**: any Android app that can
write `/sdcard` could plant the script, which runs as root. Never put it
in the daily image.

Build the two test binaries (t715-kbuild Docker image, raw ARM EABI
syscalls, no libc):

```bash
docker run --rm --platform linux/arm64 -v "$PWD/device/dmabuf-test:/w" -w /w t715-kbuild \
  sh -c 'for f in dmabuf-import-test vblank-wait; do arm-linux-gnueabihf-gcc -O2 -marm -static -nostdlib -ffreestanding -fno-stack-protector -o $f $f.c; done'
```

Daily image recipe (kernel from `kernel/kbuild-mainline.sh`):

```bash
bash boot/build-initramfs.sh --out out/initramfs-daily --knobs "t715.usbfn=ecm t715.failwait=300" --modules out/mainline/modules.tar.xz
```

```bash
bash boot/pack-test-recovery.sh --initramfs out/initramfs-daily/initramfs.cpio.gz --out out/test-recovery-daily
```

The image in RECOVERY since 2026-10-29 is the same kernel (`00021`,
saved in `out/mainline-daily-00021/`) with the persistent-root
initramfs (`boot/README.md`, "Persistent root"):

```bash
bash boot/build-initramfs.sh --out out/initramfs-daily-persist --knobs "t715.usbfn=ecm t715.failwait=300" --modules out/mainline-daily-00021/modules.tar.xz
```

```bash
bash boot/pack-test-recovery.sh --initramfs out/initramfs-daily-persist/initramfs.cpio.gz --out out/test-recovery-daily-persist out/mainline-daily-00021
```

`recovery.img` sha256 `3fc017fe…34296`. `flash-daily.sh` still flashes
`test-recovery-daily` and writes a one-line `rootfs.select`, which turns
the persistent root off: do not use it on a tablet that runs one.

Since that day the reference tablet keeps no Android. BOOT and
RECOVERY hold these two images, written from Linux with `write-part.sh`
(`docs/DEPLOY.md` 11.7 has the build commands):

| partition | image | knobs |
|---|---|---|
| BOOT | `out/boot-omarchy/boot.img` (`pack-test-recovery.sh --boot`), kernel `00024-ged71dc803f16` from `out/mainline-daily-00024/`, sha256 `43d05bb5…` | `t715.usbfn=ecm t715.failwait=300 t715.rootimg=media/0/linux/rootfs-omarchy.img t715.persist=omarchy t715.quiet=1` |
| RECOVERY | `out/recovery-rescue/recovery.img`, kernel `00021` from `out/mainline-daily-00021/`, sha256 `fe94a7c3…` | `t715.usbfn=ecm t715.failwait=300 t715.rootimg=media/0/linux/rootfs-omarchy.img t715.persist=0 t715.wdtguard=0` |

```bash
bash device/write-part.sh BOOT out/boot-omarchy/boot.img
```

It copies the image over SSH, checks its sha256 and size against the
partition, writes it with `dd` and reads it back. The scripts that go
through Android (`flash-boot.sh`, `flash-daily.sh`,
`push-rootfs-image.sh`) do not work on such a tablet.

Notes learned the hard way:

* When the Mac screen is locked, macOS does not name new USB network
  interfaces: no DHCP, no SSH, although the tablet is fine. Use
  `autotest-run.sh` then.
* Wait 60 s after Android finishes booting before a long Wi-Fi ADB push.
* Count kernel warnings with `WARNING: CPU`: sshd logs its own
  "WARNING: connection ... post-quantum" lines.
