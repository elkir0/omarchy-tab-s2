# The 64-bit port: arm64 Omarchy on the Galaxy Tab S2

The tablet's SoC, the Exynos 5433, is a 64-bit one that Samsung's signed bootloader starts in
32 bits. Since 2.0.0 this repository's main line is the 64-bit Omarchy, with its eight cores; the
32-bit Omarchy (1.0.x) is [legacy](LEGACY-ARM32.md). The 64-bit system is the daily system of the
reference tablet since 2026-11-25.

It comes as two bricks, in two repositories. This page says where each part is, for two kinds of
readers.

| Brick | Where | What it holds |
|---|---|---|
| **The boot** | [elkir0/bnuuyloader](https://github.com/elkir0/bnuuyloader), a fork of [bnuuyloader](https://github.com/meowybnuuy/bnuuyloader) | what makes the tablet start a 64-bit kernel: a loader placed in PARAM through the boot logo vulnerability CVE-2026-21155; the kernel patches for 64 bits; what was found about this tablet's bootloader |
| **The system** | this repository: [arm64/](../arm64/README.md), the installer in [boot/](../boot/README.md), and the releases | Omarchy 4.5 for 64 bits: the build, the packages patched for the tablet, the AI integrations, the tools and the tests; the installer, which is also the rescue |

## 1. For whoever wants arm64 and nothing else

**Open since 2.0.0**: [the install guide](INSTALL-ARM64.md).

| Step | What you do |
|---|---|
| 1 | Download the image and the installer from [the release](https://github.com/elkir0/omarchy-tab-s2/releases); check the checksums |
| 2 | Copy the image and its checksum file into a folder `linux` on a microSD card (or the internal storage) |
| 3 | Flash the installer to BOOT and RECOVERY in download mode, with Odin or Heimdall. The tablet installs itself and starts Omarchy's first-run setup |

Why there has to be an installer, and why the loader cannot be shipped as a file: it lives in
PARAM, and a PARAM image is Samsung's firmware holding the data of one tablet. The forged boot
logo must be built from each tablet's **own** PARAM. So the installer reads the tablet's PARAM,
builds the loader there, checks it against the one sha256 it was made for, and writes it: the
one exception, decided by the owner on 2026-11-24, to this repository's rule "never write PARAM".
What it does, step by step: [INSTALL-ARM64.md](INSTALL-ARM64.md), section 7.

## 2. For power users: the long route

Every step by hand, from a computer: it is how the reference tablet got there first. It takes the
tablet running the 32-bit Omarchy (1.0.5), a computer with Docker, the USB cable, and the
readiness to recover a tablet from download mode.

The whole route, in order, with a way back at every step, is in the fork:
[Passing a Galaxy Tab S2 to arm64 Omarchy: the two routes](https://github.com/elkir0/bnuuyloader/blob/main/t715/docs/GO-ARM64.md).
In short:

| # | Step |
|---|---|
| 1 | Install the 32-bit Omarchy 1.0.5: it is what the dumps of the tablet are read from, and what BOOT boots whenever the loader does not start the 64-bit kernel |
| 2 | Read the two dumps of your own tablet: its bootloader and its stock PARAM. Keep the PARAM copy safe |
| 3 | Build the loader's tools; calibrate the forged block against the bootloader's own JPEG decoder; build the loader; rehearse |
| 4 | Build the 64-bit kernel (the fork) and the Omarchy image ([arm64/](../arm64/README.md)) |
| 5 | CACHE: back it up, shrink it, write a kernel to a slot |
| 6 | USERDATA: the 64-bit root and its modules |
| 7 | The loader into PARAM: the tablet boots arm64 |
| 8 | The rescue into BOOT, then RECOVERY |
| 9 | Only then, if room is wanted: the 32-bit root may go |

The same warnings as the 32-bit install, and one more: the 64-bit port writes **PARAM**,
**CACHE**, **BOOT** and **RECOVERY**, where the 32-bit install writes BOOT and RECOVERY only.
The Knox warranty bit is blown for good; back up EFS first. Everything was tried on one tablet:
SM-T715, bootloader `T715XXU2CRH1`, hardware revision 9. Another firmware needs the whole method
made again.

The research behind it, for whoever wants to understand: [what was found about this tablet's
bootloader and about arm64 Linux on it](https://github.com/elkir0/bnuuyloader/blob/main/t715/docs/FINDINGS.md),
[the boot screen](https://github.com/elkir0/bnuuyloader/blob/main/t715/docs/SPLASH.md) and
[the rescue](https://github.com/elkir0/bnuuyloader/blob/main/t715/docs/RESCUE.md), in the fork.

## 3. What this repository holds for the 64-bit port

- **The 64-bit Omarchy image**, [arm64/](../arm64/README.md): its build (`arm64/rootfs/build.sh`,
  in arm64 containers), the packages patched for the tablet, the health check and the CPU audit
  of the tablet, their tests, and [everything about the image](../arm64/docs/ROOTFS.md). It is
  the image the reference tablet runs; no build of it is released yet.
- **The loader's rescue (`t715.paramrescue`).** The initramfs of this repository boots with one
  more knob, off by default: with it, a boot looks at PARAM first and, when the loader it finds
  there is not one known to work, writes the one that is and restarts. It is what makes BOOT and
  RECOVERY a way back for a tablet whose only system is started by a loader in PARAM: a loader
  that is lost is put back, and the tablet goes back to 64 bits by itself. An initramfs is built
  with it by `boot/build-initramfs.sh --paramrescue`; the release's own images do not have it.
  [boot/README.md](../boot/README.md), "The loader's rescue".
- **The starting point and the first way back**: the 32-bit system itself, and its tools
  (`device/tssh`, `device/write-part.sh`), which reach the tablet over the USB cable and write
  BOOT and RECOVERY.
- **The kernel sources**: the 64-bit kernel is this repository's kernel with the fork's nine
  patches.

## 4. What the 64-bit system does, and does not do

On 2026-11-25, on the reference tablet.

**Works**: Omarchy 4.5 on arm64 as a daily system, user space in about 13 s, a soak of three
hours with eight busy cores; a boot screen drawn by the bootloader itself; display, touch, GPU,
Wi-Fi, Bluetooth, sound, sensors, battery and the microSD card as far as the health check sees;
the LTE modem's processor online. **AI**: dictation and Omarchy Mobile's voice bar, in the
user's language (Voxtype rebuilt for the tablet's ARMv8.0 CPU); a first-run onboarding that
offers Claude Desktop, ChatGPT Desktop and a default coding agent; Claude Desktop, ChatGPT
Desktop, Claude Code, mise, Ollama, OpenCode and Grok start on the tablet.

**Not yet**, where the 32-bit release has it: **suspend to RAM**, **Android apps** (the 32-bit
Waydroid image cannot run there), **the A57 cores above 1.2 GHz** and their hot-unplug, **the
modem with a SIM** (registration, mobile data, SMS, calls), the camera's user space. The 64-bit
port's roadmaps: toward the
turnkey release, [arm64/docs/ROADMAP.md](../arm64/docs/ROADMAP.md); the boot side's,
[ROADMAP.md](https://github.com/elkir0/bnuuyloader/blob/main/t715/docs/ROADMAP.md) in the fork.
