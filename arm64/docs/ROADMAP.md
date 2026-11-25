# Golden: the road to a turnkey 64-bit release

"Golden" is the release this repository works toward: someone with a Galaxy Tab S2 8.0 LTE
(SM-T715) downloads it, flashes it once, and the tablet boots Omarchy 4.5 in 64 bits with every AI
integration Omarchy and Omarchy Mobile offer. This page says what is done and what is left, in
order. The boot side has its own roadmap in the fork:
[t715/docs/ROADMAP.md](https://github.com/elkir0/bnuuyloader/blob/main/t715/docs/ROADMAP.md).

## Done (2026-11-23 to 2026-11-25)

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

## Left before Golden

| # | Work | Side | Why it blocks |
|---|---|---|---|
| 1 | **The installer**: an image for BOOT and RECOVERY that checks the tablet (model, bootloader, chip), backs up PARAM, writes the root and the kernel's slots, builds the loader from the tablet's own PARAM, and restarts into Omarchy | boot (the installer), system (what it installs) | without it, the install is the long route |
| 2 | **The release's payload**: the root image, the kernel's slot, their checksums and a manifest the installer checks, published as a release of this repository | system | what a user downloads |
| 3 | **Suspend to RAM** on arm64 | system, kernel | a tablet that cannot sleep drains in a day |
| 4 | **The chip check** before the CPU frequency tables (ASV group) | kernel, installer | another chip's voltages could differ |
| 5 | **A full install** on a tablet as a user has it, from the release | both | the install must be proven where users start |
| 6 | Wall charging currents and the cameras' user space in 64 bits | system | daily use |
| 7 | The **ARMv8.0 check** of every program in the image and of each app the AI menu offers | system | an app that dies on the user's tablet |
| 8 | The release itself: reproducible kernel and image, the privacy check, the guide, the changelog, the XDA thread | both | publication |

## Later

Android apps in 64 bits (Waydroid), the A57 cores above 1.2 GHz, the modem with a SIM tested end
to end (registration, data, SMS, calls), hardware video decoding.
