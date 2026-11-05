# Roadmap

Where the port stands and what comes next. The dated working journals behind it are not
published (`docs/journal/README.md`); what they established is in `docs/hardware/`,
`docs/image/` and `docs/DEPLOY.md`.

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
4. **GPU frequency scaling** (`docs/hardware/GPU.md`).
5. **NetworkManager at shutdown**: read what the shutdown hooks catch, then fix the wait.
6. **Omarchy 4.5** once omarchy-mobile's touch patches follow it.
