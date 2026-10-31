# Changelog

## 0.9.2, pre-release

The GPS.

- The BCM4752 works. The chip only measures: the position comes from Samsung's `gpsd`, which the
  tablet copies from its own SYSTEM partition the first time Location goes on. No file of Samsung's
  is in this repository or in the image.
- `gpsd` runs with no network, no capability and its own user. GeoClue has no network either: its
  GeoIP lookup survives `[wifi] enable=false`, so that alone would still ask a server.
- A Location tile, off by default. The receiver runs only while an app asks, and goes off within a
  second or two of the app leaving, a crash included.
- Position in the drawer shows what GeoClue gives.
- Kernel: UART0 and `CONFIG_GPIO_SYSFS` (`kernel/patches/t715-gps`).

Tested on one tablet: a cold 3D fix in 39 to 76 s under a clear sky. No assistance server: every
start is cold, and there is no position indoors. Behind a display's USB hub the SSH link does not
work, use a port of the computer. The first boot of this ROM was tested from RECOVERY; the Android
steps and the Heimdall flash were never run.

## 0.9.1, pre-release

A ROM to flash.

- `boot.img`, `recovery.img` and `rootfs-omarchy.img.xz` in the release.
- The image holds no SSH key and no Samsung file. At boot the initramfs copies the Wi-Fi NVRAM and
  the Bluetooth patch RAM from the tablet's own SYSTEM partition, and installs
  `media/0/linux/authorized_keys` if you put one there.
- `image/tools/build-rootfs --public` builds it.
- English and QWERTY by default, AZERTY one tap away, UTC.

The first boot was tested on the reference tablet from RECOVERY. The Android steps and the Heimdall
flash of this ROM were never run: that tablet has no Android left.

## 0.9.0, pre-release

The first public version. Omarchy runs daily on one SM-T715, on Linux 6.12 with a 32-bit userland.

**Kernel**
- The Exynos 5433 in 32-bit mode on mainline: boot, SMP, clocks, IOMMU, watchdog.
- Display, GPU through Panfrost, touch, audio, Wi-Fi, Bluetooth, sensors, battery.
- The modem: MIPI LLI, and Samsung's `modem_v1` driver ported from 3.10.
- Touch keys, vibration motor, and both cameras through V4L2 with no ISP.

**Modem**
- `shannon-loader` boots the Shannon SS333 and supervises it.
- `shannond` speaks its IPC and offers ModemManager's D-Bus API: LTE, calls, SMS, mobile data,
  airplane mode, hotspot.
- The Phone and Messages apps, a ringing screen over the lock, an SMS sound and a glance at the
  screen.

**Desktop**
- Omarchy's packages for `armv7h`, and the omarchy-mobile touch shell patched for a tablet.
- A persistent root, a rescue in RECOVERY, and a firewall that only opens SSH on the USB cable.
- A screen lock you turn on by choosing a password.

**Known limits**
- One tablet tested. Nobody has followed the install guide from a clean clone yet.
- No emergency calls, suspend, hardware video decoding, frequency scaling or fingerprint reader.
- The rear camera wants the screen lit, and neither camera has a preview or autofocus.
