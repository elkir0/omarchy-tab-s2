# Golden: the turnkey 64-bit release, and what comes after it

"Golden" is the release where someone with a Galaxy Tab S2 8.0 LTE (SM-T715) downloads it, flashes
it once, and the tablet boots Omarchy 4.5 in 64 bits with every AI integration Omarchy and Omarchy
Mobile offer. **2.0.0 is that release** ([the install guide](../../docs/INSTALL-ARM64.md)). This
page says what it holds and what is left, in order. The boot side has its own roadmap in the fork:
[t715/docs/ROADMAP.md](https://github.com/elkir0/bnuuyloader/blob/main/t715/docs/ROADMAP.md).

## Done (2026-11-23 to 2026-11-26)

- **A 64-bit boot of our own**: the loader in PARAM, a 64-bit kernel from a slot of CACHE, its
  hashes checked, the eight cores started without PSCI.
- **The full kernel and a root image**: Linux 6.12.114 for arm64 from the 32-bit release's
  configuration, cpufreq and thermal on the board's tables, the boot mark and the watchdog keeper.
- **Omarchy 4.5 on arm64 as the daily system** of the reference tablet, and a soak of three hours
  with eight busy cores.
- **Up to date with Omarchy Mobile's head**, the LTE modem's processor online, its interface in
  the shell.
- **The AI layer**: dictation rebuilt for ARMv8.0 and the voice bar in the user's language, Claude
  Code, Claude Desktop, ChatGPT Desktop, mise, Ollama; a CPU audit for the packages Omarchy builds
  for newer CPUs (`arm64/tools/t715-isa-audit`).
- **The first-run setup**: name, a real PIN or password in place of the image's placeholder, the AI
  apps, voice input's language, the default coding agent.
- **The boot screen and the rescue** (the boot side): the bootloader draws the boot screen; a
  minimal rescue in BOOT and RECOVERY puts a known loader back when PARAM holds none.
- **The installer and the release (2.0.0)**: `boot.img` and `recovery.img`, flashed once,
  install the system from the image on a microSD card or the internal storage, forge the loader
  in PARAM from the tablet's own stock image, and stay as the system's rescue
  (`boot/initramfs/init`, `t715.golden`; `arm64/release/make-release.sh`).

## Done in 2.1.0 (2026-11-26)

- **Suspend to RAM on arm64**: the fork's patch 0010 in the boot loader
  (elkir0/bnuuyloader) gives the kernel CPU hot-unplug and suspend without PSCI — the secondary
  cores go down through the secure monitor's shutdown call, the SoC sleeps through its sleep
  call, and the wake comes back in 32-bit mode, where an AArch32 stub switches the boot CPU to
  64 bits again. The policy is the 32-bit release 1.0.5's, ported unchanged (`t715-sleep`): a
  minute after the screen goes dark on battery, the modem's processor and the Wi-Fi/Bluetooth
  chip powered down around the sleep; wake on Power, Home, the cover, a cable or the RTC alarm.
  Five real sleeps, five clean wakes on the reference tablet on 2026-11-26. The standby drain is
  not measured yet.
- **Android apps (Waydroid)**: Waydroid 1.6.3 with the `waydroid_arm64` images (LineageOS 20, the
  VANILLA system and the MAINLINE vendor), downloaded on the tablet by
  `sudo t715-android-setup all`; both 64-bit (arm64-v8a) and 32-bit (armeabi-v7a) apps install
  (the kernel has COMPAT); an Android tile in quick settings.
- **The reinstall from 2.0.0** in the installer: a `reinstall` file in the internal storage's
  `linux` folder makes it rename the installed system `omarchy-arm64.previous` and install the
  new image ([the guide](../../docs/INSTALL-ARM64.md), "From 2.0.0: the reinstall").

## Left after 2.0.0

| # | Work | Side | Why |
|---|---|---|---|
| 1 | **The chip check** before the CPU frequency tables (ASV group): the installer reads and logs the fuse word and says when it is not the reference chip's; the tables do not follow it yet | kernel, installer | another chip's voltages could differ (the 32-bit releases since 1.0.1 used the same tables) |
| 2 | **An install from a tablet still on Android**, by someone other than the reference tablet's owner | both | the reference tablet was put back in a stock state for the test, but it had no Android left |
| 3 | Wall charging currents and the cameras' user space in 64 bits | system | daily use |
| 4 | The **ARMv8.0 check** of every program in the image and of each app the AI menu offers, run on the tablet | system | an app that dies on the user's tablet |
| 5 | **File capabilities**: the kernel is built without `CONFIG_EXT4_FS_SECURITY` (as the 32-bit one), so ext4 keeps no file capability; `t715-golden-caps.service` gives newuidmap and newgidmap the setuid bit instead, and btop, gst-ptp-helper, gvfsd-nfs, rcp, rlogin, rsh go without. The option in the next kernel | kernel | `security.*` attributes on the root |
| 6 | The kernel's Image rebuilt byte for byte from the public sources (the source tree is: omarchy-tab-s2 1.0.5's series plus the fork's ten patches give the daily kernel's tree) | both | a release anyone can rebuild |

## Later

The standby drain while asleep (not measured in 64 bits yet), the cameras' user space, the A57
cores above 1.2 GHz, the modem with a SIM tested end to end (registration, data, SMS, calls),
hardware video decoding, and an update path that keeps the user's files (the reinstall keeps the
old system aside; it does not carry settings and files over). File capabilities
(`EXT4_FS_SECURITY`) and the kernel Image's byte-for-byte rebuild stay on the list above.
