# The 64-bit Omarchy for the Galaxy Tab S2: the system

This directory is the **system brick** of the 64-bit port: the sources of the Omarchy 4.5 image
for arm64 that the reference tablet (SM-T715) runs daily since 2026-11-25. Omarchy 4.5 on Arch
Linux ARM aarch64, with Omarchy Mobile's touch layer, the tablet's own parts (modem, keys, cover,
rotation, microSD, power, Android apps through Waydroid — dormant until `sudo t715-android-setup all`)
and the AI integrations Omarchy and Omarchy Mobile offer.

The other brick, **the boot**, is in the fork
[elkir0/bnuuyloader](https://github.com/elkir0/bnuuyloader): the loader that starts a 64-bit kernel
from PARAM, the kernel's patches and configuration, the rescue, and what was found about the
tablet's bootloader. The two bricks are told together in [docs/ARM64.md](../docs/ARM64.md).

## Which route is yours

| You want | Read |
|---|---|
| a 64-bit tablet, without reading more: download, flash, it installs | [the install guide](../docs/INSTALL-ARM64.md), with the release 2.0.0 |
| to do it yourself today, or to understand it | the whole route, in order, in the fork: [GO-ARM64.md](https://github.com/elkir0/bnuuyloader/blob/main/t715/docs/GO-ARM64.md); this directory is its step 4 (the image) and 6 (the root) |
| to build the image, change it, or check what is in it | this page, then [docs/ROOTFS.md](docs/ROOTFS.md) |

## What is here

| Path | What |
|---|---|
| `rootfs/` | the image's build: `build.sh` (the one command), the Dockerfile and its steps, the overlays, the package lists, the pins of every package downloaded, the smoke checks |
| `rootfs/pkg/` | the packages built for the tablet: `omamobile-omarchy`, `omamobile-shell`, `omamobile-settings`, `omamobile-remote`, `omamobile-voice`, `omaphone`, `omamessages`, `omatel-agent` (Omarchy Mobile, with the tablet's patches), `t715-modem` (the modem stack of this repository's `modem/`), `voxtype-bin` (dictation, rebuilt for the tablet's CPU), `hyprgraphics` |
| `rootfs/initramfs/` | the initramfs built into the 64-bit kernel: it finds the root in USERDATA |
| `rootfs/overlay/usr/local/sbin/t715-sleep`, `t715-wifi-guard` | the sleep of the 32-bit image: suspend to RAM a minute after the screen goes dark on battery, the CP and the Wi-Fi/Bluetooth chip powered down around it ([docs/image/ROOTFS.md](../docs/image/ROOTFS.md), "Sleep"); in the image build, the kernel side tested on the tablet, the user space not yet |
| `tools/t715-arm64-health` | the health check of a running tablet: what passes, warns and fails |
| `tools/t715-isa-audit` | finds the programs that may not run on the tablet's CPU (below) |
| `tools/claude-code` | installs Anthropic's signed arm64 build of Claude Code, checked against Anthropic's release key |
| `tests/` | the off-device suites of the two tools and of the sleep |
| `release/make-release.sh` | the release: the image with the kernel's modules and slot, checked; the installer (`../boot/`, `t715.golden`); the Odin package, the sums, a manifest |
| `docs/ROADMAP.md` | Golden: what 2.0.0 holds, and what is left |
| `docs/ROOTFS.md` | everything about the image: what it contains and why, the boot mark and the watchdog keeper, what the kernel must provide, the boot arguments, writing the image to the tablet, the risks |

## Building the image

You need a computer that runs **arm64 containers natively** (a Mac with Apple silicon, or an
aarch64 Linux machine) with Docker, about 20 GB free, and the network: the build downloads Arch
Linux ARM's tarball and the pinned packages of Arch Linux ARM, Omarchy and Omarchy Mobile, and
checks every file against its pin and its signature.

```bash
cd arm64/rootfs
bash build.sh --target omarchy --ssh-pubkey ~/.ssh/id_ed25519.pub
```

It writes `out/rootfs-aarch64-omarchy45.img` (a raw ext4 image), its `.sha256` and its
`.MANIFEST` (versions, packages, the build's records, the smoke check). Your own settings are
options of the build, never files of the repository ([docs/PRIVACY.md](../docs/PRIVACY.md)):
`--ssh-pubkey`, `--user`, `--password` (a crypt hash; without it the user's password is the
documented placeholder `changeme`, which the first-run onboarding asks to replace), `--locale`,
`--timezone`. `bash build.sh -h` lists them all.

The kernel is not built here: it is this repository's kernel with the fork's patches
([t715/kernel/](https://github.com/elkir0/bnuuyloader/tree/main/t715/kernel)). The image carries
no firmware of Samsung's: the Wi-Fi NVRAM and the Bluetooth patch are taken from the tablet's own
SYSTEM partition, by the installer or at the first boot.

## Making a release

```bash
bash arm64/rootfs/build.sh --target omarchy            # no --ssh-pubkey: a release has no key
bash arm64/release/make-release.sh --version 2.0.0 \
     --image arm64/rootfs/out/rootfs-aarch64-omarchy45.img --kernel-dir KERNEL_OUT --out out/release
```

`KERNEL_OUT` holds the arm64 kernel's `Image`, `modules.tar.xz` and `gts28ltexx-daily.dtb` (the
fork's `t715/build-arm64.sh`, with the daily boot arguments). The script copies the image, adds the
modules and the kernel's slot (`usr/lib/t715-golden/`), lists the file capabilities that the
installer's copy cannot carry (`t715-golden-caps.service` sets them again at the first boot),
checks what a public image must not hold (SSH host keys, a machine-id, keys, saved networks), builds the installer on the
1.0.5 release's 32-bit kernel and packs it for Odin, then writes `SHA256SUMS` and `MANIFEST.txt`.
A test build adds `--installer-knobs "t715.telnet=1 t715.usbfn=ecm"` (a root shell over the USB
cable, and its MANIFEST says so); `--image-from DIR` then makes the release around the very image
that test installed. What the installer does: [boot/README.md](../boot/README.md), "The installer
of the 64-bit system".

## The tablet's CPU, and the AI apps

The tablet's Cortex-A53 and A57 are **ARMv8.0**. Omarchy's aarch64 packages are built for newer
CPUs (ARMv8.1 and later), and a few of them die on the tablet with an illegal instruction: Voxtype,
Omarchy's dictation, did. The image therefore rebuilds Voxtype from source for ARMv8.0
(`rootfs/pkg/voxtype-bin`) and holds it back from updates (IgnorePkg).

`tools/t715-isa-audit` looks for the instructions an ARMv8.0 CPU lacks. Its static scan, on the
computer, is a triage: programs that pick their code at run time (glibc, OpenSSL, Go, Chromium and
Electron apps) are flagged although they run. `--run`, on the tablet, starts each program once and
decides. Claude Desktop, ChatGPT Desktop, mise, Ollama, OpenCode and Grok start on the tablet;
Claude Desktop and ChatGPT Desktop are not in the image (their licences forbid it) and are
installed on the tablet from Omarchy's own channel, by the first-run onboarding or by Omarchy's
Install > AI menu.

## Tests

```bash
bash arm64/tests/health/run.sh
bash arm64/tests/isa-audit/run.sh
bash arm64/tests/android/run.sh
bash arm64/tests/sleep/run.sh
```

The packages run their own tests (`check()`) whenever `build.sh` builds them, and the image is
smoke-checked in its own container before it is written (`rootfs/smoke-check-omarchy`).

## On the tablet

`tools/t715-arm64-health` reads the state of a running tablet:

```bash
scp arm64/tools/t715-arm64-health root@172.16.42.1:/tmp/
ssh root@172.16.42.1 bash /tmp/t715-arm64-health
```

The same rules as the rest of this repository hold: no clock and no voltage outside the board's
own tables ([docs/hardware/CPUFREQ.md](../docs/hardware/CPUFREQ.md)), and nothing that identifies
a tablet or its owner is ever committed.
