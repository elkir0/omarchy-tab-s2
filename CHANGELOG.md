# Changelog

## Unreleased

- **The 64-bit system is the project's main line.** The README presents Omarchy 4.5 on arm64,
  Golden in progress: what works, the AI layer, the two install routes, a new demo GIF and
  screenshots taken on the reference tablet (`assets/arm64/`). Golden's roadmap:
  [arm64/docs/ROADMAP.md](arm64/docs/ROADMAP.md). The 32-bit release (1.0.x) is legacy, no
  longer developed, kept downloadable and documented: [docs/LEGACY-ARM32.md](docs/LEGACY-ARM32.md).
- **The loader's rescue (`t715.paramrescue`).** For a tablet whose only system is started by a
  loader in PARAM, as the 64-bit port needs: an initramfs built with
  `boot/build-initramfs.sh --paramrescue` looks at PARAM at each boot and, when the loader it
  finds there is not one known to work, writes the one that is and restarts. Off by default;
  the release's images do not have it ([boot/README.md](boot/README.md), "The loader's rescue").
- **The 64-bit Omarchy image, here.** [arm64/](arm64/README.md): the sources of the Omarchy 4.5
  image for arm64 that the reference tablet runs, moved from the fork elkir0/bnuuyloader and
  brought to its state of 2026-11-25: omarchy-mobile's head with the modem's interface, Voxtype
  rebuilt for the tablet's ARMv8.0 CPU, the voice bar in the user's language, a first-run
  onboarding with the AI apps, the CPU audit (`arm64/tools/t715-isa-audit`). Not released.
- **The 64-bit port, a page.** [docs/ARM64.md](docs/ARM64.md): where it stands, for whoever
  wants it without reading more (nothing to download yet) and for power users. The 64-bit
  port itself is not released; its boot brick has a first pre-release, bnuuyloader's 0.9.0
  (the sources).

## 1.0.5, pre-release

Everything since 1.0.4: Android apps beside Linux apps through Waydroid (LineageOS 20, Android 13,
on the GPU, with Google Play opt-in), and the fix for Android after a start with a cable in.

- **Android apps.** Android apps open beside Linux apps, each in its own window, from the app
  drawer: LineageOS 20 (Android 13) in a Waydroid container, drawn by the GPU through
  Panfrost, with an Android tile in quick settings. With Waydroid's `GAPPS` image the Play
  Store signs in and installs apps; WhatsApp runs. Only 32-bit apps (`armeabi-v7a`) or apps
  without native code install. It is opt-in: the root image ships Waydroid dormant and no
  Android image; `sudo t715-android-setup all` (or `all --gapps`) downloads Waydroid's
  official images (about 760 MB without Google apps, 1.2 GB with) and sets everything up.
  Inside Android there are no cameras, no sensors and no telephony; the sleep with Android
  running and the rotation are not tested. On the reference tablet on 2026-11-21, `GAPPS`
  image, low-RAM mode: Android boots in 40 s
  ([docs/image/ANDROID.md](docs/image/ANDROID.md), with the images' download links and
  hashes).
- **Android after a start with a cable in.** The bootloader then marks the boot as a charger
  boot and Android stopped right after its first processes, so no app opened; an init file in
  Waydroid's overlay starts it anyway.
- **Kernel.** Linux 6.12.114 with one new series on top of 1.0.4's sixteen, `t715-waydroid`
  (binder, NAT, the policy routing Android's network daemon needs, and a 3G/1G memory split),
  which is no longer optional. Seventeen in all, in this order: `bringup modem parity gps
  charger camera-af cpufreq power camera-mc power-gpu turbo sdcard bluetooth wifi-recovery
  sleep radio-fixes waydroid`. Built from the published patches with the fixed identity
  ([kernel/README.md](kernel/README.md)); the release tree is the daily kernel `#20`'s tree.
  The 3G/1G memory split applies to everyone, Android used or not, and lowers the kernel's low
  memory from about 1.6 GiB to about 590 MiB (the rest is high memory); no ill effect seen on
  the reference tablet, in daily use since 2026-11-20. The optional `t715-linkpm` series is
  still not in it.
- **Software.** A fresh package sync: Mesa 26.3.1 (26.2.6 in 1.0.4), systemd 262.2,
  omamobile-shell 0.2.94-6 (the Android tile), hyprgraphics 0.6.0-2.1 (rebuilt for libjxl
  0.13), Waydroid 1.6.3 with LXC and python-pyclip 0.7.0; unchanged: Omarchy 4.0.6 (pinned),
  Hyprland 0.57.2, Quickshell 0.3.2, Qt 6.12.0, Firefox 157.0, Chromium 150. The root image
  is 5.3 GiB raw (5704253440 bytes); the published `rootfs-omarchy.img.xz` is 1241391564
  bytes.
- **From 1.0.4.** There is no update path yet, the same rule as 1.0.4 from 1.0.3: the first
  boot copies the image only into a persistent root that does not exist yet. Flashing only
  1.0.5's `boot.img` over a 1.0.4 install gives that system the new kernel and its modules
  (the initramfs installs them into the root), including `t715-waydroid`, but not Waydroid,
  `t715-android-setup`, `t715-android`, the launcher daemon or the Android tile, which live in
  the root image.

Tested on one tablet, the reference one, on 2026-11-21, booted from RECOVERY next to its owner's
system with test boot images carrying the release's kernel and initramfs (the release's
`boot.img` differs only by the knobs that name the image and the root; the test images also
had `t715.autotest=1`, whose script gave the test system the daily system's Wi-Fi network and
its SSH rule). The published `rootfs-omarchy.img.xz` was sent to the tablet over Wi-Fi and
unpacked there, and the image's checksum matched its line in `SHA256SUMS`; it then got a
persistent root of its own: the first boot copied it in 211 s (1.0.4: 205 s) and Omarchy's
session came up by itself. On that boot: the release kernel (`#1`), not tainted, no oops; the
three binder devices, policy routing accepted, 589 MiB of low memory (the 3G/1G split); the
GPU scaling from 160 to 700 MHz and the A57 cores up to 1.5 GHz; `t715-sleep` and
`t715-wifi-guard` active, the kernel able to suspend to RAM (`deep`),
`pci_exynos.wifi_power_cycle` at Y; the Wi-Fi on the network, Bluetooth powered, the microSD
card mounted by itself (exFAT); Waydroid installed with its container service disabled and no
Android image in the root. **Android:** `waydroid init`, run by hand, downloaded Waydroid's
official `VANILLA` system and `MAINLINE` vendor images, so `t715-android-setup all` skipped its
own init step and did the rest: the Mesa fix applied, the configuration, the charger init
file, the firewall rules, the container enabled. `image/tests/ondevice/android-smoke.sh`: the
first Android boot completed in 125 s, drawn by Panfrost (OpenGL ES 3.1, the vendor image's
Mesa 26.0.8), no native crash, a cold app launch in 2.8 s and a warm one in 0.24 s, and one
panfrost job fault, which makes the script's verdict a fail (the known fault below). On the
second boot Android's Settings opened in its own window beside the terminal, Chromium, Phone
and Messages. **The rest:** the modem's switch (22 checks); a recovery asked by hand, good at
the third try, 31 s in all; three suspends on the cable, each a dry run through `t715-sleep`'s
prepare and restore (the CP off, the chip powered down and back), the Wi-Fi on the network
19.6 s (after one failed try), 11.8 s and 11.9 s after the suspend's exit, the kernel still
untainted; the Battery saver through power-profiles-daemon, power-saver taking the A53 cores
to 1 GHz and the GPU to 266 MHz, balanced giving both back. A second boot copied nothing and
kept the data (a marker file, Android's setup); the rescue's test image booted the image
read-only, with no modem module, the session and the Wi-Fi up.
`image/tests/verify-rootfs.sh` passes its 388 checks on the image, and two builds of the kernel
from the published patches, in two trees, were identical byte for byte.

Not tested: a call, an SMS or mobile data (no SIM in the tablet), the GPS, a real sleep on the
release image itself (on the cable a suspend stays a dry run; the daily system slept for real
about 80 times on 2026-11-10), the power drawn asleep and the power draw on this build, sleep
with Android running, screen rotation with Android windows, clipboard from Linux to Android,
Waydroid's `GAPPS` image and the Play Store on the release image itself (they run on the daily
system, which has the same kernel tree and tools), `t715-android-setup`'s own download step,
Bluetooth's return after a suspend (not timed), the animations under the Battery saver,
the Bluetooth devices on the release image itself (a keyboard, a mouse and a speaker were
tested with 1.0.2), the SD card tile and the pointer by eye, the Camera app, the Stay awake
tile by hand, the heat guard's caps, and the Odin, Heimdall and TWRP installs.

Known issues:
- **Android apps (Waydroid):** only 32-bit apps (`armeabi-v7a`) or apps without native code
  install; inside Android there are no cameras, no sensors and no telephony; Android apps
  cannot draw while the screen is off or locked; sleep with Android running and screen rotation
  with Android windows are not tested; Android posts a "Configure physical keyboard"
  notification at every session start ([docs/image/ANDROID.md](docs/image/ANDROID.md) section
  11).
- **The Wi-Fi can still fail to start**, now and then, after a boot or a wake: the service
  brings it back by itself — about 8 s after a wake in 36 restores of 40 on the reference
  tablet, 23 to 40 s in the other four; the chip's own failure as its radio starts is not
  fixed, and it fails more often with the A57 cores offline, which is why a recovery brings
  them online ([docs/hardware/WIFI_BT_M5.md](docs/hardware/WIFI_BT_M5.md) section 7.10).
- **While the tablet sleeps** there is no Wi-Fi, no Bluetooth, no call, no SMS and no
  notification (the CP is off), and the Wi-Fi cannot wake it; after a wake the Wi-Fi is back
  in about 8 s, Bluetooth in about 19 s, the CP in about 13 s. The power drawn asleep is not
  measured yet. The black screen at a key wake was fixed in the kernel, but it came in runs,
  so the count that says so does not prove it.
- **A Bluetooth mouse crashed the touch shell once, at its first pairing** (Quickshell 0.3.2,
  SIGSEGV): the screen stayed black about 40 s while the crash was written, then the shell
  came back by itself. Not seen again when the mouse reconnected.
- **Omarchy's keyboard shortcuts did not answer** with the Bluetooth keyboard tried; not
  investigated yet.
- **The Camera app and the GPU.** While the Camera app runs, the kernel logs panfrost job
  faults (`DATA_INVALID_FAULT`, `TILE_RANGE_FAULT`, `INSTR_TYPE_MISMATCH`, `JOB_BUS_FAULT`),
  GPU page faults and now and then a `gpu sched timeout`, the GPU reset after a stuck job:
  from none to a few dozen in a 45-second use, and once a burst of about 300. 1.0 Beta 1's
  kernel, its GPU fixed at 266 MHz, does the same on this image (404 in one use, then 2, 0, 9
  and 1), and so does this kernel with the GPU pinned at 266 MHz: it comes with the Camera
  app's use of the GPU, not with the new frequencies. The app and the session kept running.
- Outside the Camera app, `panfrost: js fault ... DATA_INVALID_FAULT` once or twice a boot,
  when a new window appears (two in the 1.0.5 test, with Android running).
- Dozens of `exynos_drm_gem_prime_import_sg_table ... buffer chunks must be mapped
  contiguously` lines per boot: the display rejects GPU buffers for direct scanout and the
  compositor draws them instead.
- Android's leftover data on USERDATA is readable by the desktop user, who has Android's
  `system` UID (1000): wipe Android's data first if that matters (`docs/INSTALL.md`).
- The USB gadget borrows Apple's vendor ID, and its link is CDC-ECM, which Windows does not
  drive. On 2026-11-09 the reference tablet's USB link to a Mac stopped receiving after a few
  frames and stayed so, through cable changes and replugs, until the end of the session (the
  Mac was not restarted); the 1.0.3, 1.0.4 and 1.0.5 tests went over Wi-Fi instead.

## 1.0.4, pre-release

Everything since 1.0.3: the tablet suspends to RAM once its screen has been dark for a minute
on battery, a Wi-Fi that fails to start comes back in seconds instead of a minute or more, and
the kernel no longer crashes at a Bluetooth unbind. Also new, for developers: the on-device
tests of the sleep.

- **Sleep.** The tablet suspends to RAM. The root image's new service `t715-sleep` suspends it
  once the screen has been dark for a minute on battery, unless a reason holds — external
  power, audio playing, a call, the hotspot, a remote login, Omarchy's stay-awake, a pacman
  transaction, a Wi-Fi recovery, a sleep inhibitor, the CP between states — and at 5 % of
  battery or less it powers the tablet off instead of sleeping it. Power, Home, the cover and
  a 12-hour battery check wake it. While it sleeps there is no Wi-Fi, no Bluetooth, no calls,
  no SMS and no notifications (the CP is off), and the Wi-Fi cannot wake it; on external power
  the radios still go down but the suspend stays a dry run, and the tablet does not really
  sleep. `t715-sleep off` / `on` / `status` (root) switch it. The kernel series `t715-sleep`
  (7 patches) registers the Exynos 5433's system sleep, and a suspend sleeps for real only
  when `t715-sleep` armed it; the same series fixes a black screen at a key wake
  (samsung-dsim's interrupt handled in hard interrupt context, a late transfer finished by
  polling). On the reference tablet on 2026-11-10: about 80 real sleeps woke clean (the RTC,
  Power, Home, the cover); the CP came back in about 13 s. The power drawn asleep is not
  measured yet ([docs/image/ROOTFS.md](docs/image/ROOTFS.md), "Sleep").
- **Wi-Fi.** The guard's recovery, which could take more than a minute, now judges each try
  every second from the bind (a failure signature ends it at once), binds Bluetooth once at
  the end instead of once per try, makes up to ten tries (six before), and brings the A57
  cores online on `performance` for the length of a recovery: the chip started 41 times in 45
  that way, against 26 in 45 in the screen-off state, where those cores sit offline; the cause
  is not known. In 40 dry-run restores on the reference tablet (RTC wakes, the screen dark, on
  the cable) the Wi-Fi was up 7.1 to 7.7 s after the wake in 36 of them, and in 23 to 40 s in
  the other four, against 8 to 82 s with 1.0.3's recovery; Bluetooth comes back about 19 s
  after the wake (13 s before). Also in the guard since 1.0.3: `off`, the whole chip powered
  down for each sleep; the replay of a recovery's kernel lines after it ended, fixed; and a
  blind spot of the checks, which counted over the whole kernel log while its ring buffer
  turns over, fixed — they judge only the lines after the last good check
  ([docs/hardware/WIFI_BT_M5.md](docs/hardware/WIFI_BT_M5.md) section 7.10).
- **Two kernel fixes.** The series `t715-radio-fixes` (2 patches): upstream's commit
  21139b3ac62a, unchanged — a use-after-free in `hci_uart_unregister_device()` that oopsed
  the kernel at a Bluetooth unbind while the controller still talked (once, in a bench); every
  sleep and every Wi-Fi recovery unbinds Bluetooth — and brcmfmac's remove path no longer
  warning and tainting the kernel after a start whose firmware halted during the setup. The
  daily kernel of the reference tablet since 2026-11-11 (`#17`,
  [docs/hardware/WIFI_BT_M5.md](docs/hardware/WIFI_BT_M5.md) section 7.10).
- **For developers.** The on-device tests `image/tests/ondevice/sleep-soak.sh` (real sleeps
  woken by the RTC, each timed and checked) and `image/tests/ondevice/sleep-display.sh` (the
  display at a key wake).
- **Kernel.** Linux 6.12.114 with two new series on top of 1.0.3's fourteen, `t715-sleep` and
  `t715-radio-fixes`. Sixteen in all, in this order: `bringup modem parity gps charger
  camera-af cpufreq power camera-mc power-gpu turbo sdcard bluetooth wifi-recovery sleep
  radio-fixes`. Built from the published patches with the fixed identity
  ([kernel/README.md](kernel/README.md)). The optional `t715-linkpm` series is still not in
  it.
- **Software.** The packages are 1.0.3's, from the same package layers of its build: omamobile-shell 0.2.94-5, Omarchy 4.0.6 (pinned), Hyprland 0.57.2, Mesa 26.2.6, Qt 6.12.0, Quickshell 0.3.2, systemd 262.1, Firefox 157.0, Chromium 150. The image adds `t715-sleep` and its three units
  (`t715-sleep.service`, `t715-sleep-prepare.service`, `t715-sleep-restore.service`), and it
  masks only the three hibernation targets now: 1.0.3 masked `sleep.target` and
  `suspend.target` too, and `t715-sleep` masks those two until the next boot on a kernel
  without the Exynos 5433's system sleep. The root image is 5.3 GiB raw (5704253440
  bytes); the published `rootfs-omarchy.img.xz` is 1237682648 bytes.
- **From 1.0.3.** There is no update path yet, the same rule as 1.0.3 from 1.0.2: the first
  boot copies the image only into a persistent root that does not exist yet. Flashing only
  1.0.4's `boot.img` over a 1.0.3 install gives that system the new kernel and its modules
  (the initramfs installs them into the root): the system sleep and the display fix, the two
  radio fixes. It does not give the sleep itself or the new recovery, which live in the root
  image (1.0.3's root keeps `sleep.target` and `suspend.target` masked, so it never
  suspends); they can be added by hand, as the reference tablet's daily system got them, from
  this repository's `image/rootfs/overlay/usr/local/sbin/` (`t715-sleep`, `t715-wifi-guard`)
  and `image/rootfs/overlay/etc/systemd/system/` (the three `t715-sleep*.service` units):

  ```bash
  sudo install -m 755 t715-sleep t715-wifi-guard /usr/local/sbin/
  sudo install -m 644 t715-sleep.service t715-sleep-prepare.service t715-sleep-restore.service /etc/systemd/system/
  sudo systemctl daemon-reload
  sudo systemctl unmask sleep.target suspend.target
  sudo systemctl enable --now t715-sleep.service
  sudo systemctl enable t715-sleep-prepare.service
  sudo systemctl restart t715-wifi-guard.service
  ```

  On 1.0.3's kernel `t715-sleep` masks the two targets again until the next boot, so the
  service is harmless there.

Tested on one tablet, the reference one, on 2026-11-11, booted from RECOVERY next to its owner's
system with test boot images carrying the release's kernel and initramfs (the release's
`boot.img` differs only by the knobs that name the image and the root; the test images also
had `t715.autotest=1`, whose script gave the test system the daily system's Wi-Fi network and
its SSH rule). The published `rootfs-omarchy.img.xz` was sent to the tablet over Wi-Fi,
unpacked there (`xz -dk`, 141 s) and checked against `SHA256SUMS`, both lines OK, then got a
persistent root of its own: the first boot copied it in 205 s (3 min 25 s; 1.0.3: 3 min 31 s),
took the Wi-Fi and Bluetooth files from SYSTEM, made the cameras' seven tables, bound the
sensors, and Omarchy's session came up by itself. On that boot: the release kernel (`#1`), not
tainted, no oops and no GPU job fault, the GPU scaling from 160 to 700 MHz and the A57 cores up
to 1.5 GHz, the Bluetooth driver with upstream's fix; `t715-sleep` active, the kernel able to
suspend to RAM (`deep`), `sleep.target` and `suspend.target` no longer masked; `t715-wifi-guard`
active, its boot check finding the Wi-Fi up, `pci_exynos.wifi_power_cycle` at Y, no failure
signature in the kernel log; the Wi-Fi on the network (7 networks in a scan); a recovery asked
by hand, the A57 cores brought online for it and the first try good after 5 s, 13 s in all;
three suspends on the cable, woken by the RTC, each a dry run through `t715-sleep`'s prepare
and restore (the CP off, the chip powered down and back): the Wi-Fi back 7.8, 22.7 (after one
failed try) and 7.7 s after the wake, Bluetooth's patch loaded after 19.2, 28.1 and 19.2 s, the
kernel still untainted; the microSD card mounted by itself (exFAT), no partition label from the
card under `/dev/disk/by-partlabel`, no MMC error; Bluetooth powered with its generated
address, `/dev/uhid` present; the pointer settings in place; the Battery saver switched through
power-profiles-daemon, power-saver taking the A57 cores offline, the A53 cores to 1 GHz, the GPU
to 266 MHz and the animations off within 3 s, balanced giving it all back within 4 s; the
modem's switch (22 checks); Chromium, Phone, Messages, Réseau mobile and the terminal starting;
the speaker and microphone devices. A second boot copied nothing and kept the data (a marker
file), the cameras present from the start and the Wi-Fi up at once; the rescue's test image
booted the image read-only, with no modem module, the session and the Wi-Fi up.
`image/tests/verify-rootfs.sh` passes its 379 checks on the image, and two builds of the kernel
from the published patches, in two trees, were identical byte for byte.

Not tested: a call, an SMS or mobile data (no SIM in the tablet), the GPS, a real sleep on the
release image itself (on the cable a suspend stays a dry run; the daily system, with the
`t715-sleep` series and service, slept for real about 80 times on 2026-11-10), the power drawn
asleep and the power draw on this build, the Bluetooth devices on the release image itself (a
keyboard, a mouse and a speaker were tested with 1.0.2), the SD card tile and the pointer by
eye, the Camera app, the Stay awake tile by hand, the heat guard's caps, and the Odin, Heimdall
and TWRP installs.

Known issues:
- **The Wi-Fi can still fail to start**, now and then, after a boot or a wake: the service
  brings it back by itself — about 8 s after a wake in 36 restores of 40 on the reference
  tablet, 23 to 40 s in the other four; the chip's own failure as its radio starts is not
  fixed, and it fails more often with the A57 cores offline, which is why a recovery brings
  them online ([docs/hardware/WIFI_BT_M5.md](docs/hardware/WIFI_BT_M5.md) section 7.10).
- **While the tablet sleeps** there is no Wi-Fi, no Bluetooth, no call, no SMS and no
  notification (the CP is off), and the Wi-Fi cannot wake it; after a wake the Wi-Fi is back
  in about 8 s, Bluetooth in about 19 s, the CP in about 13 s. The power drawn asleep is not
  measured yet. The black screen at a key wake was fixed in the kernel, but it came in runs,
  so the count that says so does not prove it.
- **A Bluetooth mouse crashed the touch shell once, at its first pairing** (Quickshell 0.3.2,
  SIGSEGV): the screen stayed black about 40 s while the crash was written, then the shell
  came back by itself. Not seen again when the mouse reconnected.
- **Omarchy's keyboard shortcuts did not answer** with the Bluetooth keyboard tried; not
  investigated yet.
- **The Camera app and the GPU.** While the Camera app runs, the kernel logs panfrost job
  faults (`DATA_INVALID_FAULT`, `TILE_RANGE_FAULT`, `INSTR_TYPE_MISMATCH`, `JOB_BUS_FAULT`),
  GPU page faults and now and then a `gpu sched timeout`, the GPU reset after a stuck job:
  from none to a few dozen in a 45-second use, and once a burst of about 300. 1.0 Beta 1's
  kernel, its GPU fixed at 266 MHz, does the same on this image (404 in one use, then 2, 0, 9
  and 1), and so does this kernel with the GPU pinned at 266 MHz: it comes with the Camera
  app's use of the GPU, not with the new frequencies. The app and the session kept running.
- Outside the Camera app, `panfrost: js fault ... DATA_INVALID_FAULT` once or twice a boot,
  when a new window appears (none in the 1.0.4 test).
- Dozens of `exynos_drm_gem_prime_import_sg_table ... buffer chunks must be mapped
  contiguously` lines per boot (62 at the check): the display rejects GPU buffers for direct
  scanout and the compositor draws them instead.
- Android's leftover data on USERDATA is readable by the desktop user, who has Android's
  `system` UID (1000): wipe Android's data first if that matters (`docs/INSTALL.md`).
- The USB gadget borrows Apple's vendor ID, and its link is CDC-ECM, which Windows does not
  drive. On 2026-11-09 the reference tablet's USB link to a Mac stopped receiving after a
  few frames and stayed so, through cable changes and replugs, until the end of the session
  (the Mac was not restarted); the 1.0.3 and 1.0.4 tests went over Wi-Fi instead.

## 1.0.3, pre-release

Everything since 1.0.2: a Wi-Fi start that fails is brought back by itself, without a
reboot, and the kernel no longer crashes when the Wi-Fi's firmware halts. Also new, for
developers: the console of a hung boot kept after a watchdog reset, and the on-device
test scripts.

- **Wi-Fi.** On some boots the Wi-Fi never came up — the shell showed "no wifi radio" —
  and only a reboot brought it back: 1 boot in 14 on the reference tablet on 2026-11-09.
  Two causes, both fixed. Mainline never powered the Exynos 5433's PCIe PHY down, so
  after one failed start the link stayed unusable until a reboot; and the BCM4358's
  shared part stays powered while Bluetooth is on, so a failed start needs the whole
  chip power-cycled. The kernel series `t715-wifi-recovery` (4 patches) makes an unbind
  and a bind of the PCIe host power-cycle the Wi-Fi, and the new service
  `t715-wifi-guard` in the root image brings a failed start back by itself: it checks
  the Wi-Fi at boot and whenever the kernel logs a failure, and power-cycles the whole
  chip (Wi-Fi and Bluetooth) until a start succeeds — up to six tries, at most three
  recoveries in 30 minutes, and only on a kernel that can, which its read-only
  `pci_exynos.wifi_power_cycle` says. A failed start comes back in 18 to 60 s. The
  service's device test ran 20 simulated boots: 11 good at once, 8 brought back by the
  service, 1 not within the 4 tries allowed then (6 now). And brcmfmac no longer
  crashes the kernel on a halted firmware. The reference tablet's daily system has run
  that kernel (`#11`, built from the same source tree as the release kernel) and the
  service since 2026-11-09
  ([docs/hardware/WIFI_BT_M5.md](docs/hardware/WIFI_BT_M5.md) section 7.9,
  [docs/image/ROOTFS.md](docs/image/ROOTFS.md)).
- **For developers.** The initramfs knob `t715.crashlog=1` (test images only) keeps a
  hung boot's console: after a watchdog reset, the previous boot's pstore records go to
  `media/0/linux/t715-crash/` on USERDATA before the guard restarts the board
  ([boot/README.md](boot/README.md)). The on-device test scripts — the sleep steps, the
  Wi-Fi's unattended power cycles and the guard's simulated boots — live in
  `image/tests/ondevice/`. The plan after 1.0.2, thirteen items with sleep first:
  [docs/ROADMAP.md](docs/ROADMAP.md).
- **Kernel.** Linux 6.12.114 with one new series on top of 1.0.2's thirteen,
  `t715-wifi-recovery`. Fourteen in all, in this order: `bringup modem parity gps
  charger camera-af cpufreq power camera-mc power-gpu turbo sdcard bluetooth
  wifi-recovery`. Built from the published patches with the fixed identity
  ([kernel/README.md](kernel/README.md)). The optional `t715-linkpm` series is still not
  in it.
- **Software.** Hyprland 0.57.2, was 0.57.1, the only change among the 248 packages the image's manifest
  lists: the root image was built from a fresh package sync, and the main packages keep
  1.0.2's versions — omamobile-shell 0.2.94-5, Omarchy 4.0.6 (pinned), Mesa 26.2.6, Qt 6.12.0,
  Quickshell 0.3.2, systemd 262.1, Firefox 157.0, Chromium 150. The image adds the `t715-wifi-guard` service and its unit.
  The root image is 5.3 GiB raw (5704253440 bytes); the published
  `rootfs-omarchy.img.xz` is 1237599840 bytes.
- **From 1.0.2.** There is no update path yet, the same rule as 1.0.2 from 1.0.1: the
  first boot copies the image only into a persistent root that does not exist yet.
  Flashing only 1.0.3's `boot.img` over a 1.0.2 install gives that system the new
  kernel and its modules (the initramfs installs them into the root): the PHY's
  power-down, WLAN_EN switchable, brcmfmac's guards. It does not give the service,
  which lives in the root image; it can be added by hand, as the reference tablet's
  daily system got it, from this repository's
  `image/rootfs/overlay/usr/local/sbin/t715-wifi-guard` and
  `image/rootfs/overlay/etc/systemd/system/t715-wifi-guard.service`:

  ```bash
  sudo install -m 755 t715-wifi-guard /usr/local/sbin/
  sudo install -m 644 t715-wifi-guard.service /etc/systemd/system/
  sudo systemctl enable t715-wifi-guard.service
  ```

  The service does nothing on a kernel without the series (it checks the parameter
  first).

Tested on one tablet, the reference one, on 2026-11-10, booted from RECOVERY next to its owner's
system with test boot images carrying the release's kernel and initramfs (the release's
`boot.img` differs only by the knobs that name the image and the root; the test images also
had `t715.autotest=1`, whose script gave the test system the daily system's Wi-Fi network and
its SSH rule, since the USB link was down). The published `rootfs-omarchy.img.xz` was sent to
the tablet over Wi-Fi, unpacked there (`xz -dk`, 149 s) and checked against `SHA256SUMS`, both
lines OK, then got a persistent root of its own: the first boot copied it in 211 s (3 min 31 s;
1.0.2: 3 min 12 s), took the Wi-Fi and Bluetooth files from SYSTEM, made the cameras' seven
tables, bound the sensors, and Omarchy's session came up by itself. On that boot: the release
kernel (`#1`); `t715-wifi-guard` active, its boot check finding the Wi-Fi up,
`pci_exynos.wifi_power_cycle` at Y, no failure signature in the kernel log; the Wi-Fi on the
network (7 networks in a scan); a recovery asked by hand, which power-cycled the whole chip
until a start came good (75 s, after failed tries), while the service, which had seen those
failures, checked again once it held the lock and cycled nothing; the microSD card mounted by
itself (exFAT), no partition label from the card under `/dev/disk/by-partlabel`, no MMC error;
Bluetooth powered with its generated address, `/dev/uhid` present; the pointer settings in
place; the Battery saver switched through power-profiles-daemon, power-saver taking the A57
cores offline, the A53 cores to 1 GHz, the GPU to 266 MHz and the animations off within 3 s,
balanced giving it all back within 4 s; the modem's switch (22 checks); Chromium, Phone,
Messages, Réseau mobile and the terminal starting; the speaker and microphone devices. A
second boot copied nothing and kept the data (a marker file), the cameras present from the
start and the Wi-Fi up at once; the rescue's test image booted the image read-only, with no
modem module, the session and the Wi-Fi up. A first build of the image went through the same
test the evening before and showed the service's needless extra cycle, which the re-check
under the lock now prevents. `image/tests/verify-rootfs.sh` passes its 368 checks on the
image, and two builds of the kernel from the published patches, in two trees, were identical
byte for byte.

Not tested: a call, an SMS or mobile data (no SIM in the tablet), the GPS, the power draw on
this build, the Bluetooth devices on the release image itself (a keyboard, a mouse and a speaker
were tested with 1.0.2; the Wi-Fi's recovery cycles Bluetooth too, and it came back powered
each time), the SD card tile and the pointer by eye, the Camera app, the Stay awake tile by
hand, the heat guard's caps, and the Odin, Heimdall and TWRP installs.

Known issues:
- **The Wi-Fi can still fail to start**, now and then: the service brings it back by
  itself, which can take up to about a minute after the session comes up; the chip's
  own failure as its radio starts (the firmware's 37.4 MHz path a suspect) is not
  fixed.
- **A Bluetooth mouse crashed the touch shell once, at its first pairing** (Quickshell 0.3.2,
  SIGSEGV): the screen stayed black about 40 s while the crash was written, then the shell
  came back by itself. Not seen again when the mouse reconnected.
- **Omarchy's keyboard shortcuts did not answer** with the Bluetooth keyboard tried; not
  investigated yet.
- **The Camera app and the GPU.** While the Camera app runs, the kernel logs panfrost job
  faults (`DATA_INVALID_FAULT`, `TILE_RANGE_FAULT`, `INSTR_TYPE_MISMATCH`, `JOB_BUS_FAULT`),
  GPU page faults and now and then a `gpu sched timeout`, the GPU reset after a stuck job:
  from none to a few dozen in a 45-second use, and once a burst of about 300. 1.0 Beta 1's
  kernel, its GPU fixed at 266 MHz, does the same on this image (404 in one use, then 2, 0, 9
  and 1), and so does this kernel with the GPU pinned at 266 MHz: it comes with the Camera
  app's use of the GPU, not with the new frequencies. The app and the session kept running.
- Outside the Camera app, `panfrost: js fault ... DATA_INVALID_FAULT` once or twice a boot,
  when a new window appears (once during the app test).
- Dozens of `exynos_drm_gem_prime_import_sg_table ... buffer chunks must be mapped
  contiguously` lines per boot (70 at the check): the display rejects GPU buffers for direct
  scanout and the compositor draws them instead.
- Android's leftover data on USERDATA is readable by the desktop user, who has Android's
  `system` UID (1000): wipe Android's data first if that matters (`docs/INSTALL.md`).
- The USB gadget borrows Apple's vendor ID, and its link is CDC-ECM, which Windows does not
  drive. On 2026-11-09 the reference tablet's USB link to a Mac stopped receiving after a
  few frames and stayed so, through cable changes and replugs, until the end of the session
  (the Mac was not restarted); the 1.0.3 test went over Wi-Fi instead.

## 1.0.2, pre-release

Everything since 1.0.1: the microSD slot at work, Bluetooth at 3 Mbaud with keyboards and mice,
a pointer for the mouse, and a Bluetooth adapter that is there at every boot.

- **microSD card.** The slot works: cards are read and written in FAT32 and exFAT, at up to
  UHS-I SDR104 on a 100 MHz bus (34 MB/s read from files on the test card, a 16 GB SDHC). A
  card is mounted by itself on insertion, with notifications and an "SD card" tile in quick
  settings (omamobile-shell 0.2.94-5). Two safety changes come with it:
  `/dev/disk/by-partlabel/*` stays on the eMMC (a udev rule in the root image), and the
  initramfs reads partition names from the eMMC only (in `boot.img`):
  [docs/hardware/SDCARD.md](docs/hardware/SDCARD.md) and
  [docs/image/ROOTFS.md](docs/image/ROOTFS.md), section "microSD card".
- **Bluetooth.** The UART link to the chip runs at 3 Mbaud, where 1.0.1 ran it at 460800 baud:
  room for high-quality Bluetooth audio. A speaker played cleanly in SBC while the link
  carried 46 kB/s, which is all 460800 baud could carry and 15 % of the new link. And
  Bluetooth keyboards and mice can connect now — before, none could: the kernel lacked UHID,
  which BlueZ 5.87 uses to create the input device of every Bluetooth keyboard and mouse. A
  mouse shows a pointer, hidden on touch and after 3 s without movement, where the touch shell
  hid it for good. The adapter no longer goes missing on some boots: it was one boot in five,
  the address script racing the kernel's auto-off window. Tested on the owner's daily system
  on 2026-11-08 with kernel `#10`, built from exactly the same source tree as the release
  kernel: a Bluetooth LE keyboard, which types and reconnects after sleeping; a Logitech MX
  Master 3S mouse (Bluetooth LE), which clicks, scrolls and reconnects; a BeoPlay A1 speaker
  (A2DP, SBC), which plays cleanly, its volume keys moving it
  ([docs/hardware/WIFI_BT_M5.md](docs/hardware/WIFI_BT_M5.md) section 7.8,
  [docs/image/ROOTFS.md](docs/image/ROOTFS.md), section "Bluetooth").
- **Kernel.** Linux 6.12.114 with two new series on top of 1.0.1's eleven, `t715-sdcard` and
  `t715-bluetooth`. Thirteen in all, in this order: `bringup modem parity gps charger
  camera-af cpufreq power camera-mc power-gpu turbo sdcard bluetooth`. Built from the
  published patches with the fixed identity ([kernel/README.md](kernel/README.md)). The
  optional `t715-linkpm` series is still not in it.
- **Software.** omamobile-shell 0.2.94-5, was 0.2.94-4. Omarchy stays on 4.0.6, pinned. The
  main packages keep 1.0.1's versions: Hyprland 0.57.1, Mesa 26.2.6, Qt 6.12.0, Quickshell
  0.3.2, systemd 262.1, Firefox 157.0, Chromium 150. The root image is 5.3 GiB raw (5704253440
  bytes); the published `rootfs-omarchy.img.xz` is 1237739200 bytes.
- **From 1.0.1.** There is no update path yet, the same rule as 1.0.1 from 1.0 Beta 1: the
  first boot copies the image only into a persistent root that does not exist yet. Flashing
  only 1.0.2's `boot.img` over a 1.0.1 install gives that system the new kernel: the microSD
  slot, Bluetooth at 3 Mbaud, keyboards and mice, and the initramfs's eMMC-only partition
  names. It does not give what lives in the root image: the SD card notifications and tile,
  the address fix, the pointer, and the udev rule that keeps `/dev/disk/by-partlabel` on the
  eMMC. So on such a mixed system, do not insert a card whose partitions carry the tablet's
  partition names (RADIO, EFS, SYSTEM and the like); a card formatted by a PC or a camera is
  fine.

Tested on one tablet, the reference one, on 2026-11-08, booted from RECOVERY next to its owner's
system with test boot images carrying the release's kernel and initramfs (the release's
`boot.img` differs only by the knobs that name the image and the root). The published
`rootfs-omarchy.img.xz` was sent to the tablet, unpacked there (`xz -dk`, 152 s) and checked
against `SHA256SUMS`, both lines OK, then got a persistent root of its own: the first boot
copied it in 192 s (3 min 12 s; 1.0.1: 3 min 16 s), took the Wi-Fi and Bluetooth files from
SYSTEM, made the cameras' seven tables, bound the sensors, and Omarchy's session came up by
itself. On that boot: the release kernel (`#1`, 2026-11-08); the microSD card mounted by itself (exFAT),
its "SD card" tile showing it (checked by eye), no partition label from the card under
`/dev/disk/by-partlabel`, no MMC error; Bluetooth powered with its generated address,
`/dev/uhid` present, no UART error; no pointer on screen without a mouse (checked by eye), and
the pointer settings in place; the Battery saver switched through power-profiles-daemon,
power-saver taking the A57 cores offline, the A53 cores to 1 GHz, the GPU to 266 MHz and the
animations off within 3 s, balanced giving it all back within 4 s; the modem's switch (22
checks); Chromium, Phone, Messages, Réseau mobile and the terminal starting; Wi-Fi scanning,
the speaker and microphone devices. Just after the first boot's copy, thermal cooling held the
A57 cores at 1.2 GHz for about a minute, the zones near 56 °C after, then 1.5 GHz again. A
second boot copied nothing and kept the data (a marker file), the cameras present from the
start and Bluetooth with its address again; the rescue's test image booted the image
read-only, with no modem module. `image/tests/verify-rootfs.sh` passes its 362 checks on the
image, and two builds of the kernel from the published patches, in two trees, were identical
byte for byte.

Not tested: a call, an SMS or mobile data (no SIM in the tablet), joining a Wi-Fi network on
the test system, the GPS, the power draw on this build, the Bluetooth devices on the release
image itself (they were tested on the daily system with kernel `#10`, the same tree, since
pairing them on the test system would have broken their pairing with the daily one), the Stay
awake tile by hand, the heat guard's caps, and the Odin, Heimdall and TWRP installs.

Known issues:
- **A Bluetooth mouse crashed the touch shell once, at its first pairing** (Quickshell 0.3.2,
  SIGSEGV): the screen stayed black about 40 s while the crash was written, then the shell
  came back by itself. Not seen again when the mouse reconnected.
- **Omarchy's keyboard shortcuts did not answer** with the Bluetooth keyboard tried; not
  investigated yet.
- **The Camera app and the GPU.** While the Camera app runs, the kernel logs panfrost job
  faults (`DATA_INVALID_FAULT`, `TILE_RANGE_FAULT`, `INSTR_TYPE_MISMATCH`, `JOB_BUS_FAULT`),
  GPU page faults and now and then a `gpu sched timeout`, the GPU reset after a stuck job:
  from none to a few dozen in a 45-second use, and once a burst of about 300. 1.0 Beta 1's
  kernel, its GPU fixed at 266 MHz, does the same on this image (404 in one use, then 2, 0, 9
  and 1), and so does this kernel with the GPU pinned at 266 MHz: it comes with the Camera
  app's use of the GPU, not with the new frequencies. The app and the session kept running.
- Outside the Camera app, `panfrost: js fault ... DATA_INVALID_FAULT` once or twice a boot,
  when a new window appears (twice during the app test).
- Dozens of `exynos_drm_gem_prime_import_sg_table ... buffer chunks must be mapped
  contiguously` lines per boot (37 at the check): the display rejects GPU buffers for direct
  scanout and the compositor draws them instead.
- Android's leftover data on USERDATA is readable by the desktop user, who has Android's
  `system` UID (1000): wipe Android's data first if that matters (`docs/INSTALL.md`).
- The USB gadget borrows Apple's vendor ID, and its link is CDC-ECM, which Windows does not
  drive. Once, on the reference tablet, the USB link to a Mac stopped receiving until the
  cable was plugged in again.

## 1.0.1, pre-release

Everything since 1.0 Beta 1: the GPU up to 700 MHz and the big cores up to 1.5 GHz, the Battery
saver and Stay awake tiles at work, the animations back, and a first boot that accepts a
checksum file written on Windows.

- **GPU and big cores.** The GPU scales from 160 to 700 MHz (1.0 Beta 1: a fixed 266 MHz), at
  the vendor's eight Mali levels on the G3D PLL; the A57 cores scale from 800 MHz to 1.5 GHz
  (Beta 1: held at 1.2 GHz), with the vendor's body bias and EMA, and their own cooling maps.
  The A53 cores still scale from 400 MHz to 1.2 GHz. Qualified on the reference tablet on
  2026-11-07, including a 2-hour soak: [docs/hardware/CPUFREQ.md](docs/hardware/CPUFREQ.md)
  section 9 and [docs/hardware/GPU.md](docs/hardware/GPU.md) section 10.14, where glmark2,
  each level pinned, scores 781 at 700 MHz against 328 at 266 MHz.
- **Battery saver.** The tile does something now: power-saver takes the A57 cores offline,
  caps the A53 cores at 1 GHz and the GPU at 266 MHz, and turns Hyprland's animations off;
  balanced gives everything back: the A57 cores online again while the screen is lit, the GPU
  up to 700 MHz, the animations on. [docs/hardware/BATTERY.md](docs/hardware/BATTERY.md)
  section 13.
- **Heat and low battery.** Every 30 s, while balanced is active, a battery at 52.0 °C or
  more (cleared at 49.0 °C), or at 20 % or less while no charger is connected, caps the A57
  cores at 1.2 GHz and the GPU at 420 MHz, until neither holds.
  [docs/hardware/BATTERY.md](docs/hardware/BATTERY.md) section 13.
- **Stay awake.** The tile now keeps the screen on. It starts off: the screen goes off after
  two minutes by default (omamobile-shell 0.2.94-4 sets Omarchy's own idle timers to 0; the
  tablet's `t715-idle` turns the screen off).
- **Animations.** On, where 1.0 Beta 1 had them off: with the GPU at a fixed 266 MHz the
  desktop felt snappier without them. They go off under the Battery saver.
- **First boot.** A `rootfs-omarchy.img.sha256` sidecar written on Windows is accepted:
  Windows line endings, a byte order mark and an upper-case hash, as Notepad and PowerShell's
  `Get-FileHash` write them. 1.0 Beta 1's images still refuse such a file.
- **Kernel.** Linux 6.12.114 with two new series on top of 1.0 Beta 1's nine, `t715-power-gpu`
  and `t715-turbo`, written on `t715-power` and applied unchanged after `t715-camera-mc`. Built
  from the published patches with a fixed date, user and host
  ([kernel/README.md](kernel/README.md)). The optional `t715-linkpm` series is still not in it.
- **Software.** omamobile-shell 0.2.94-4, was 0.2.94-3. Omarchy stays on 4.0.6, pinned. The
  main packages keep 1.0 Beta 1's versions: Hyprland 0.57.1, Mesa 26.2.6, Qt 6.12.0,
  Quickshell 0.3.2, systemd 262.1, Firefox 157.0, Chromium 150.
- **From 1.0 Beta 1.** There is no update path yet. The first boot copies the image only into a
  persistent root that does not exist yet (`USERDATA/omarchy`), so flashing 1.0.1's `boot.img`
  over a Beta 1 install gives that system the new kernel and its modules, but not the tiles, the
  heat guard and the animations, which live in the root image.

Tested on one tablet, the reference one, on 2026-11-08, booted from RECOVERY next to its owner's
system with test boot images carrying the release's kernel and initramfs (the release's
`boot.img` differs only by the knobs that name the image and the root). The published
`rootfs-omarchy.img.xz` was unpacked on the tablet and checked against `SHA256SUMS`, then got a
persistent root of its own: the first boot, the `.sha256` sidecar next to the image, copied it
in 3 min 16 s, took the Wi-Fi and Bluetooth files from SYSTEM, made the cameras' seven tables
and bound the sensors, and Omarchy's session came up by itself. On that boot: the release
kernel (`#1`, 2026-11-08) with the GPU's eight levels from 160 to 700 MHz and the A57 cores from
800 MHz to 1.5 GHz; the balanced profile applied at boot; the Battery saver switched through
power-profiles-daemon, power-saver taking the A57 cores offline, the A53 cores to 1 GHz, the
GPU to 266 MHz and the animations off within 3 s, balanced giving all of it back; the guard's
timer running; the Stay awake tile off at first; both cameras through `t715-photo`, and the
Camera app at about two cores; Chromium, Phone, Messages, Réseau mobile and the terminal
starting; Pi; the Claude Code installer answering No and changing nothing; Wi-Fi scanning,
Bluetooth, the speaker and microphone devices, ASPM L1.2; the modem's switch (22 checks). A
second boot kept the data and copied nothing, the cameras present from the start, and the
rescue's test image booted the image read-only. `image/tests/verify-rootfs.sh` passes its 358
checks on the image, and two builds of the kernel from the published patches were identical
byte for byte.

Not tested: a call, an SMS or mobile data (no SIM in the tablet), joining a Wi-Fi network, the
GPS, the power draw on this build, the Stay awake tile by hand, the heat guard's caps on the
tablet (the battery stayed under 52 °C and above 20 %), the on-screen progress by eye, and the
Odin, Heimdall and TWRP installs.

Known issues:
- **The Camera app and the GPU.** While the Camera app runs, the kernel logs panfrost job faults
  (`DATA_INVALID_FAULT`, `TILE_RANGE_FAULT`, `INSTR_TYPE_MISMATCH`, `JOB_BUS_FAULT`), GPU page
  faults and now and then a `gpu sched timeout`, the GPU reset after a stuck job: from none to a
  few dozen in a 45-second use, and once a burst of about 300. 1.0 Beta 1's kernel, its GPU
  fixed at 266 MHz, does the same on this image (404 in one use, then 2, 0, 9 and 1), and so
  does this kernel with the GPU pinned at 266 MHz: it comes with the Camera app's use of the
  GPU, not with the new frequencies. The app and the session kept running.
- Outside the Camera app, `panfrost: js fault ... DATA_INVALID_FAULT` once or twice a boot,
  when a new window appears, as in 1.0 Beta 1.
- Dozens of `exynos_drm_gem_prime_import_sg_table ... buffer chunks must be mapped contiguously`
  per boot: the display rejects GPU buffers for direct scanout and the compositor draws them
  instead.
- Android's leftover data on USERDATA is readable by the desktop user, who has Android's
  `system` UID (1000): wipe Android's data first if that matters (`docs/INSTALL.md`).
- The USB gadget borrows Apple's vendor ID, and its link is CDC-ECM, which Windows does not
  drive. Once, on the reference tablet, the USB link to a Mac stopped receiving until the cable
  was plugged in again.

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
