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

## Left after 2.0.0

| # | Work | Side | Why |
|---|---|---|---|
| 1 | **Suspend** on arm64: the kernel offers only suspend-to-idle (no PSCI); a sleep that the screen's going dark starts, as the 32-bit release had | system, kernel | a tablet that cannot sleep drains in a day |
| 2 | **The chip check** before the CPU frequency tables (ASV group): the installer reads and logs the fuse word and says when it is not the reference chip's; the tables do not follow it yet | kernel, installer | another chip's voltages could differ (the 32-bit releases since 1.0.1 used the same tables) |
| 3 | **An install from a tablet still on Android**, by someone other than the reference tablet's owner | both | the reference tablet was put back in a stock state for the test, but it had no Android left |
| 4 | Wall charging currents and the cameras' user space in 64 bits | system | daily use |
| 5 | The **ARMv8.0 check** of every program in the image and of each app the AI menu offers, run on the tablet | system | an app that dies on the user's tablet |
| 6 | **File capabilities**: the kernel is built without `CONFIG_EXT4_FS_SECURITY` (as the 32-bit one), so ext4 keeps no file capability; `t715-golden-caps.service` gives newuidmap and newgidmap the setuid bit instead, and btop, gst-ptp-helper, gvfsd-nfs, rcp, rlogin, rsh go without. The option in the next kernel | kernel | `security.*` attributes on the root |
| 7 | The kernel's Image rebuilt byte for byte from the public sources (the source tree is: omarchy-tab-s2 1.0.5's series plus the fork's nine patches give the daily kernel's tree) | both | a release anyone can rebuild |

## Later

Android apps in 64 bits (Waydroid), the A57 cores above 1.2 GHz, the modem with a SIM tested end
to end (registration, data, SMS, calls), hardware video decoding.
