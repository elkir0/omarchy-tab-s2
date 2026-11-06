# Changelog

## 1.0 Beta 1, pre-release

The first release meant for someone other than its developer: everything since 0.9.3, and an
install guide, [docs/INSTALL.md](docs/INSTALL.md).

- **Install.** `docs/INSTALL.md` covers stock Android (Odin or Heimdall) and TWRP. The release
  adds two Odin packages: `omarchy-tab-s2-1.0.0-beta.1-AP.tar.md5` (BOOT and RECOVERY) and
  `omarchy-tab-s2-1.0.0-beta.1-boot.tar.md5` (BOOT only, to keep TWRP).
- **First boot.** The screen shows the progress while the system copies itself into internal
  storage, and says why if something fails instead of rebooting. The copy is checked first
  against `rootfs-omarchy.img.sha256` when it sits next to the image. No root shell on the USB
  cable any more (`t715.telnet=1` brings it back for development).
- **Power.** 754 mW with the screen off, about 20 hours, from 2.26 W in 0.9.3: the A57 cores go
  offline with the screen, the GPU's power domain turns off while it idles, the Wi-Fi link sleeps
  (ASPM L1.2, a 100 ms power save timeout). The A53 cores scale from 400 MHz to 1.2 GHz. There is
  still no suspend.
- **Modem.** A Modem tile and a switch in Réseau mobile turn the modem off, now and at boot, or
  only while the screen is off. A powered modem costs 155 mW of the standby draw, SIM or not:
  without a SIM, turn it off.
- **Cameras.** omarchy-mobile's Camera app (omacam) on both cameras, through libcamera's software
  ISP on the CPU: preview, tap to focus, photos and video. The first boot makes the sensors' mode
  tables from your tablet's own camera firmware (`t715-camera-tables`): they are Samsung's, so the
  image cannot carry them. Loupe opens photos and screenshots.
- **Coding agents.** Pi 1.5.0 is preinstalled: sign in with `/login` or an API key, never a Claude
  subscription. Claude Code is an opt-in installer in the app drawer: it downloads Anthropic's
  build only after you say yes, refuses a manifest whose signature does not verify, and stops at
  2.1.270: from 2.1.271 its interface stays blank without Anthropic's own runtime.
- **omarchy-mobile**: shell 0.2.94, omaphone 0.2.3, omamessages 0.2.2, omamobile-omarchy 0.1.32.
  **Omarchy** stays on 4.0.6, pinned file by file: 4.5.0 breaks omarchy-mobile's touch patches.
- **Kernel.** Linux 6.12.114 with three new series, `t715-cpufreq`, `t715-power` and
  `t715-camera-mc`. Built from the published patches with a fixed date, user and host, it is
  byte for byte the release's kernel (`kernel/README.md`).
- **Build.** Fixes for a fresh build: glibc 2.43's `locale.gen`, and local packages never taken
  from the shared pacman cache. The Wi-Fi firmware's licence ships in the image.

Tested on one tablet, the reference one, booted from RECOVERY next to its owner's system, with a
test boot image carrying the release's kernel and initramfs (the release's `boot.img` differs
only by the knobs that name the image and the root). A first build of the root image, which had
omaphone 0.2.2, omamessages 0.2.1, omamobile-omarchy 0.1.27 and an earlier build of the same
libcamera, got its own persistent root: the first boot checked the image against its `.sha256`,
copied it in 3 min 17 s, took the Wi-Fi and Bluetooth files from SYSTEM, made the cameras' seven
tables and bound the sensors, and Omarchy's session came up by itself. A second boot kept the
data and copied nothing, the cameras present from the start; the rescue booted the image
read-only. On that build: both cameras through `t715-photo`, the Camera app opening them with its
software ISP at about two cores, Pi, the Claude Code installer answering No and changing nothing,
Wi-Fi scanning, Bluetooth, the speaker and microphone devices, the A57 cores offline and ASPM L1.2
with the screen off, and the modem's switch (22 checks: off, on, the standby cut and polkit's
refusal from SSH). The final image, this release's, booted read-only from the rescue's boot image
(which carries no modem module) and was checked again: the cameras' tables and both cameras,
Chromium, Phone, Messages, Réseau mobile and the terminal starting, Pi, the Claude Code installer,
Wi-Fi scanning, Bluetooth and the sound devices. `image/tests/verify-rootfs.sh` passes its 340 checks
on it.

Not tested: a call, an SMS or mobile data (no SIM in the tablet), joining a Wi-Fi network, the
GPS, the screen-off power draw on this build (its kernel is `#6` plus the cameras, measured in
`docs/hardware/BATTERY.md`), the Camera app's preview by eye (the test ran at night, in the
dark), the on-screen progress by eye, and the Odin, Heimdall and TWRP installs.

Known issues:
- `panfrost: js fault ... DATA_INVALID_FAULT` in the kernel log, once or twice a boot, when a new
  window appears (the session's start, Chromium, a terminal). Nothing visible came of it. The
  owner's daily system, on Hyprland 0.57.0, shows none in 13 boots; this image has 0.57.1.
- Dozens of `exynos_drm_gem_prime_import_sg_table ... buffer chunks must be mapped contiguously`
  per boot: the display rejects GPU buffers for direct scanout and the compositor draws them
  instead. The daily system logs them too.
- Android's leftover data on USERDATA is readable by the desktop user, who has Android's
  `system` UID (1000): wipe Android's data first if that matters (`docs/INSTALL.md`).
- The USB gadget borrows Apple's vendor ID, and its link is CDC-ECM, which Windows does not
  drive.

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
