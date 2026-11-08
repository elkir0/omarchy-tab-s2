# Roadmap

Where the port stands and what comes next. The dated working journals behind it are not
published (`docs/journal/README.md`); what they established is in `docs/hardware/`,
`docs/image/` and `docs/DEPLOY.md`.

## State at 1.0.1 (2026-11-08)

Since 1.0 Beta 1, tested on the same tablet (`CHANGELOG.md` has the release's own test
notes):

- **The GPU and the A57 cores scale**: the GPU from 160 to 700 MHz at the vendor's eight Mali
  levels on the G3D PLL, the A57s from 800 MHz to 1.5 GHz in the vendor's body bias and EMA
  with their own cooling maps; the A53s still 400 MHz to 1.2 GHz (`kernel/patches/t715-power-gpu`,
  `kernel/patches/t715-turbo`, `docs/hardware/CPUFREQ.md` section 9,
  `docs/hardware/GPU.md` section 10.14).
- **Battery saver tile**: power-saver takes the A57s offline, caps the A53s at 1 GHz and the
  GPU at 266 MHz, and turns Hyprland's animations off; balanced gives everything back
  (`docs/hardware/BATTERY.md` section 13).
- **Heat and low-battery guard**: every 30 s, while balanced is active, a battery at 52.0 °C
  or more (cleared at 49.0 °C), or at 20 % or less off the charger, caps the A57s at 1.2 GHz
  and the GPU at 420 MHz (`docs/hardware/BATTERY.md` section 13).
- **Stay awake tile**: it keeps the screen on now, and starts off: the screen goes off after
  two minutes by default (omamobile-shell 0.2.94-4).
- **Animations on**: with the GPU scaling to 700 MHz they are smooth again; 1.0 Beta 1 had
  them off (a fixed 266 MHz GPU felt snappier without them), and the Battery saver still
  turns them off.
- **First boot on Windows**: a `rootfs-omarchy.img.sha256` sidecar written on Windows, with
  CR LF, a byte order mark and an upper-case hash, is accepted (1.0 Beta 1's images refuse it).

## State at 1.0 Beta 1 (2026-11-05)

Since 0.9.3, tested on one tablet (`CHANGELOG.md` has the release's own test notes):

- **Install for other people**: `docs/INSTALL.md`, Odin packages next to `boot.img` and
  `recovery.img` (`image/tools/make-release`, `image/tools/pack-odin`), a first boot that shows its
  progress and its errors on screen and checks the image against its `.sha256`, and no root shell
  on the USB cable by default.
- **Power with the screen off**: 754 mW, about 20 hours (`docs/hardware/BATTERY.md` sections 9-11):
  the A57 cores offline with the screen (`kernel/patches/t715-power`), the GPU's power domain off
  while it idles, the Wi-Fi link in ASPM L1.2 with a 100 ms power save timeout, the lock screen's
  blanking. The A53s scale from 400 MHz to 1.2 GHz under schedutil (`t715-cpufreq`).
- **Modem switch**: the Modem tile and Réseau mobile turn the CP off now and at boot, or only
  while the screen is off; a powered CP costs 155 mW of the standby draw
  (`docs/hardware/MODEM.md` 5.4, `docs/hardware/BATTERY.md` section 12).
- **Cameras**: libcamera's software ISP on the CPU and omarchy-mobile's Camera app on both
  cameras (`kernel/patches/t715-camera-mc`, `docs/image/PACKAGES.md`); the sensors' tables are
  made at the first boot from the tablet's own firmware.
- **Coding agents**: Pi preinstalled; Claude Code as an opt-in installer with a signed manifest.
- **Omarchy 4.0.6, pinned** (`docs/image/REPACK.md`): 4.5.0 breaks omarchy-mobile's touch patches.

## Next

1. **Suspend.** The 5433 sleep entry passes every `pm_test` level and a dry run in a test kernel,
   and a real suspend-to-idle wakes on the RTC (`docs/hardware/BATTERY.md` section 11); the Wi-Fi
   chip's D3 and the modem still stand in the way, and the real `SMC_CMD_SLEEP` was never sent.
2. **A modem that sleeps**: the CP-led link power management of stock (decision D2's fallback F2,
   `research/modem/research/SYNTHESIS.md`), so that a modem kept on stops costing 155 mW.
3. **Installs on other tablets**: the Odin, Heimdall and TWRP paths of `docs/INSTALL.md` were
   never run end to end; a first-boot wizard; a TWRP zip; a USB link Windows can use (RNDIS or
   NCM) and a USB vendor ID of our own instead of the one the gadget borrows.
4. **The Camera app's GPU faults**: job faults, page faults and GPU resets while it runs, with
   1.0 Beta 1's kernel and 1.0.1's alike (`CHANGELOG.md`, 1.0.1's known issues); find whether
   Mesa's Midgard driver, the preview's buffers or the kernel's import path makes them
   (`docs/hardware/GPU.md` section 10.10).
5. **NetworkManager at shutdown**: read what the shutdown hooks catch, then fix the wait.
6. **Omarchy 4.5** once omarchy-mobile's touch patches follow it.
