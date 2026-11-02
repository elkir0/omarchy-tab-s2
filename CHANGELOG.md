# Changelog

## 0.9.3, pre-release

Charging.

- The tablet charges at stock Android's rates. Before, the charger kept the input limit near
  500 mA that the bootloader leaves, so a fast charger gave the battery about +300 mA, not enough
  for the screen on. Now a fast charger gets 1750 mA in and 2100 mA of charge, about +1 A into
  the battery with the screen off; a computer's port gets 450 mA.
- Stock's thermal rules, on the battery's own thermistor: no charge above 55 °C or below -5 °C,
  a gentler charge above 45 °C or below 10 °C. One change from stock: the warm step ends at
  43 °C, not 40 °C. The battery idles at 41-42 °C under this kernel, and with stock's exit the
  charge stayed at about 83 % for good.
- The battery's temperature in UPower and in the modem's start gate is the thermistor's now, not
  the gauge chip's, which runs 15-20 °C hotter on a charger.
- USB, for a tablet that the computer stopped seeing: the cable detector's interrupt could freeze
  after boot or lose an event for good, and after a boot with no cable USB stayed off until the
  next boot.
- Charging starts a fifth of a second after the plug, not up to 10 s later.
- `device/mac-usb-reenum.c`: after an unplug of more than a minute, macOS can keep a dead USB
  session and ignore the tablet plugged back in. This makes the Mac enumerate it again.
- Kernel: `kernel/patches/t715-charger`, five patches. The kernel carries a fixed build date.

Tested on one tablet: on a fast charger, 70 to 85 % in 49 min with the screen on, past the 83 %
where it used to stop, the warm step entered at 45 °C and left at 43 °C; three replugs on a Mac,
a boot with no cable, a fast charger plugged after boot. The fix for a boot with no cable is
proven only by a fault injected on the device: the real boot with no cable did not hit the fault.
The system image is the one of 0.9.2, only `boot.img` and `recovery.img` change. `boot.img` runs
on the reference tablet, where a boot on the fast charger charged from 10 s in; `recovery.img`
was not booted.

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
