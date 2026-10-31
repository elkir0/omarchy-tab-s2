# The Omarchy rootfs image

`image/tools/build-rootfs` builds `image/out/rootfs-omarchy.img`: Arch Linux ARM
`armv7h` with Omarchy 4.0.6 (Hyprland 0.57 and the Quickshell-based Omarchy
shell) for the Samsung Galaxy Tab S2 8.0 LTE (SM-T715). Its only purpose is
a first on-device test: does Omarchy's Hyprland session and shell start on
a 32-bit userland, and how fast. It is not a daily-driver image: of the
omarchy-mobile touch layer its first two phases are in (the on-screen
keyboard, the hardware keys and the cover, "Touch layer P1"; the touch
shell, "Touch layer P2"), Bluetooth with Bluetooth audio ("Bluetooth") and
Wi-Fi ("Wi-Fi"); rotation, the lock, wired audio and sensors come later.

The kernel and the initramfs are built from `kernel/` and `boot/`; this
part (`image/`) produces the image file, which is copied to USERDATA and
booted (`docs/DEPLOY.md`).

## Build and verify

```bash
image/tools/repack-omarchy                                    # once: image/out/repo/armv7h
image/tools/build-rootfs --ssh-pubkey ~/.ssh/id_ed25519.pub   # 1-2 h from scratch
image/tests/verify-rootfs.sh image/out/rootfs-omarchy.img ~/.ssh/id_ed25519.pub
(cd out && shasum -a 256 -c rootfs-omarchy.img.sha256)
cat image/out/rootfs-omarchy.MANIFEST
```

| Output | What |
|---|---|
| `image/out/rootfs-omarchy.img` | raw ext4 (not Android sparse), label `ALARM`, sized to its content + 20 % (2026-10-29 build with Wi-Fi and Bluetooth audio: 4032 MiB, 729 MiB free, 710 packages) |
| `image/out/rootfs-omarchy.img.sha256` | `shasum -a 256` line |
| `image/out/rootfs-omarchy.MANIFEST` | image figures, versions, Omarchy's package list (installed / skipped / unavailable), setup leaves, smoke check |

Options: `--size MiB` (fixed size instead of content + 20 %),
`--keep-image` (keep the Docker image `t715-omarchy:rootfs`), `--no-cache`
(rebuild every layer with a fresh package sync), `-h`.

How it works, all in Docker (the Mac only sees the finished image file):

1. `image/rootfs/Dockerfile` starts from `t715-omarchy:base-armv7h` (the ALARM
   tarball import of `image/lib/alarm.sh`) and runs under qemu
   (`linux/arm/v7`). The local repository `image/out/repo/armv7h` is a BuildKit
   named context, bind-mounted at `/repo` only while pacman runs
   (`[t715-omarchy]`, `SigLevel = Optional TrustAll`, before `[core]`); the
   downloaded packages live in a BuildKit cache mount
   (`t715-omarchy-pacman-armv7h`). Steps: `setup-pacman.sh` (the Phosh
   image's pacman adaptations, keyrings, no kernel, full upgrade), `omarchy`
   and `omarchy-settings`, `install-packages.sh` (Omarchy's own list minus
   `image/rootfs/packages.omarchy-skip`, plus `image/rootfs/packages.extra`),
   `install-mobile.sh` (touch layer P2: `image/rootfs/packages.mobile`, the
   Omarchy patch series checked), the Bluetooth patch RAM (staged by
   `image/tools/build-rootfs`, see "Bluetooth"), `install-wifi.sh` (the Wi-Fi
   firmware and NVRAM, "Wi-Fi"), `configure-system.sh` (with
   `omarchy-system-setup.sh` and `omarchy-user-setup.sh`), `finalize.sh`.
   Each step bind-mounts only the files it uses, so editing a later script
   reuses the cached package layers. Any change to `image/out/repo/armv7h`
   (a package built or repacked) invalidates the steps that mount it, from
   step 1 on: about 15 minutes with the warm pacman cache (2026-10-28).
2. `image/rootfs/smoke-check.sh` (installed as `/usr/lib/t715-omarchy/smoke-check`)
   runs in a container of the final armv7h image; the build stops if the
   session binaries do not load.
3. `docker export` streams the tree into `image/rootfs/mkimage.sh`, run by the
   `t715-omarchy-rootfs-helper` container (Debian trixie, arm64): it unpacks
   the tree there, removes `/.dockerenv`, writes `/etc/hostname`,
   `/etc/hosts` and the `/etc/resolv.conf` link (Docker bind mounts during
   the build), and runs `mkfs.ext4 -d` then `e2fsck -fn`.
4. `image/tools/build-rootfs` writes the checksum and the MANIFEST
   (`/usr/share/t715-omarchy/MANIFEST.image` from the image, plus the file
   system figures and the smoke check).

Docker objects: images `t715-omarchy:rootfs` (removed unless
`--keep-image`) and `t715-omarchy-rootfs-helper` (kept, shared with the
verify script); containers `t715-omarchy-rootfs-{smoke,export,mkfs,verify}`
(always removed). Build log: `image/cache/rootfs-omarchy-build.log`.
`docker builder prune` drops the cached layers and packages.

`image/tests/verify-rootfs.sh` reads the image with `debugfs`/`dumpe2fs` in the
helper container (read-only bind mount, never mounted) and checks every
point of the contract below, plus the identity, toggles and package
records; it prints `PASS`/`FAIL` per check and `RESULT: PASS|FAIL`.

## The image contract and how it is met

| # | Requirement (tablet owner) | How | Checked by `verify-rootfs.sh` |
|---|---|---|---|
| 1 | raw ext4, read-only under a tmpfs overlay, nothing writes to `/run/t715/userdata`, small | `mkfs.ext4 -d`, `-m 0`, content + 20 % (+ inode tables, 64 MiB journal), rounded to 64 MiB; journal on disk, capped at 64 MiB (`journald.conf.d/10-t715-journal.conf`: in the RAM overlay in image mode, kept across reboots on a persistent root); updatedb prunes `/run/t715`; udev hides the eMMC partitions from udisks (udiskie, Nautilus, GNOME Disks) | format, magic, size, `e2fsck`, prune path, udev rule |
| 2 | systemd as `/sbin/init`, no `/.dockerenv` | ALARM's systemd; `mkimage.sh` removes `/.dockerenv`; empty `/etc/machine-id` (transient ID, no first-boot prompts) | `/sbin/init` → `systemd`, no `/.dockerenv`, empty machine-id |
| 3 | USB networking and SSH | the five files byte-for-byte from `image/rootfs/overlay/` in `image/rootfs/overlay/`, `etc/usb-rndis/function` = `ecm`; `openssh`, `dnsmasq`; `usb-rndis.service`, `sshd.service` enabled; the key in `/root/.ssh/authorized_keys` (0700/0600, root) and alarm's; `dnsmasq.conf` untouched (`port=0`, empty `dhcp-option=3`/`6`) | `cmp` with the Phosh sources, dnsmasq options, packages, wants links, key and modes |
| 4 | `AQ_DRM_DEVICES=/dev/dri/card0`; no audio config; Bluetooth and Wi-Fi as the Phosh image ships them (owner's requests, 2026-10-28) | `/etc/environment`, `sddm.service.d/10-t715-aq-drm.conf`, `~alarm/.config/uwsm/env`; no firmware package; audio leaves skipped; the BCM4358 patch RAM and `t715-bt-addr` ("Bluetooth"); its brcmfmac firmware, NVRAM and `t715-wifi-addr` ("Wi-Fi") | the three places; the patch RAM's sha256 against the vendor dump, the link, the three Bluetooth files byte for byte; the Wi-Fi firmware's pinned sha256, the NVRAM's against its dump, the link, the three Wi-Fi files against the Phosh repository's HEAD; nothing else in `brcm/` |
| 5 | no kernel package, no modules, no linux-firmware | removed in step 1 (`pacman -Rdd linux-armv7 linux-firmware*`), `/usr/lib/modules` and `/boot/*` deleted; the Wi-Fi firmware is one file taken from `linux-firmware-broadcom`, which is not installed | no `linux*` package but `linux-api-headers`, no `/usr/lib/modules` |
| — | SDDM autologin into Omarchy, graphical target | `/etc/sddm.conf.d/autologin.conf` (`User=alarm`, `Session=omarchy.desktop`, `Relogin=true`), `/var/lib/sddm/state.conf`, `sddm.service` enabled, `graphical.target` default | all of these |
| — | Omarchy's first-boot provisioning never runs | no `/var/lib/omarchy/provisioning/pending`, `omarchy-provision-owner.service` masked | both |
| — | ufw enabled, only SSH and DHCP on `usb0` come in | `config/firewall.sh` skipped, the overlay's rules, `ENABLED=yes`, unit enabled | both |
| — | pristine pacman.conf | ALARM's file restored, commented `[t715-omarchy]` note before `[core]` | no active stanza, no `DisableSandbox`, `CheckSpace`/`DownloadUser` back |

## What the image contains

- **Arch Linux ARM armv7h**, fully upgraded at build time, without kernel,
  modules or firmware. Hostname `gts28lte-omarchy`, time zone
  UTC, locales en_US.UTF-8 and fr_FR.UTF-8, `LANG=en_US.UTF-8`. Documentation
  and translations other than English and French are removed, as in the
  Phosh image.
- **The RTC is Android's**: nothing in the image writes it (no `hwclock`
  unit or hook, no chrony or other NTP daemon, no `/etc/adjtime`, so no
  local-time RTC for `timedatectl set-timezone` to rewrite; checked by
  `verify-rootfs.sh`). systemd-timesyncd sets only the system clock, over
  Wi-Fi; the kernel side (`RTC_SYSTOHC`) is the Phosh session's.
- **Omarchy 4.0.6** from the local repository (`docs/image/REPACK.md`):
  `omarchy` and `omarchy-settings` (4.0.6-1.1, retagged `armv7h`, no ELF),
  the `any` packages (keyring, themes, fonts, Yaru icons). Everything
  compiled comes from the official ALARM `armv7h` repositories: Hyprland
  0.57 (0.57.0 since the 2026-10-29 build; slots 1 to 3 ran 0.56.2),
  Quickshell 0.3, uwsm, SDDM 0.21, Qt 6.12, Mesa (panfrost and the exynos
  kmsro loader), PipeWire/WirePlumber, xdg-desktop-portal-hyprland.
- **Omarchy's own package list** (`install/omarchy-base.packages`) minus
  `image/rootfs/packages.omarchy-skip`; names that pacman cannot resolve on
  armv7h are left out automatically. The MANIFEST lists each name as
  installed, skipped (with the reason from the skip list) or unavailable
  (with pacman's reason). Skipped on purpose: the heavy applications
  (LibreOffice, Kdenlive, OBS, Xournal++, Moonlight, gpu-screen-recorder),
  Docker and its tools (`docker*`, `lazydocker`, `ufw-docker`), toolchains
  and interpreters (`clang`, `llvm` — Mesa's `llvm-libs` stays — `ruby`
  and `tobi-try` which needs it, `luarocks`, `lua51`), database client
  libraries, Tesseract, printing (CUPS and friends), `noto-fonts-cjk`,
  `kernel-modules-hook`, `qemu-user-static-binfmt`. Not available for
  armv7h (2026-10-28): `chromium` (the image runs Debian's, section
  "Chromium"); Omarchy's own compiled tools `aether`,
  `cliamp`, `herdr`, `omacalc`, `omacut`, `omawrite`, `tensaku`, `ttfx`,
  `hyprland-preview-share-picker`; `asdcontrol`, `dotnet-runtime`,
  `localsend`, `mise-bin`, `obsidian`, `pinta`, `tzupdate`, `yay`; `nvim`
  and `omarchy-nvim` (ALARM's `neovim` 0.9.1 cannot be installed: its
  `libtermkey` dependency is gone).
- **Touch shell** (`image/rootfs/packages.mobile`, "Touch layer P2"):
  `omamobile-shell` and `omamobile-omarchy` from `image/pkg/` (`docs/image/PACKAGES.md`),
  with `python-dbus` and the rest of their dependencies from ALARM.
- **Extras** (`image/rootfs/packages.extra`): `openssh`, `dnsmasq`, `sudo`,
  `mesa`, `squeekboard` (the on-screen keyboard), `zram-generator`,
  `pipewire-audio` (PipeWire's BlueZ plugin: Bluetooth audio), `iw`,
  `wireless-regdb`, `usbutils`, `htop`, `vim`,
  `gnome-calculator`, `gnome-clocks`, `geoclue`, `wf-recorder` (the Screen record tile),
  `pipewire-alsa`, and `firefox` (best effort; installed beside Chromium, the default
  browser, with Omarchy's Firefox policy directory and Wayland
  setting). Not `gnome-maps`: `gjs` dies on an alignment fault in ALARM's `libmozjs` on
  this CPU, before any window, and the Google Maps web app takes its place.
- **Hyprland's dmabuf-check shim**: `/usr/local/lib/t715-dmabuf-check-shim.so`
  (`image/rootfs/shim/`, compiled in the Dockerfile's `shim` stage from the dev
  image, so the image carries no compiler), preloaded into Hyprland only by
  the `/usr/local/bin/Hyprland` wrapper (overlay), which `start-hyprland`
  finds first in `PATH`. Without it, Hyprland's linux-dmabuf check imports
  every client buffer into exynos-drm, which rejects panfrost's buffers,
  and kills every GPU client: black screen, shell relaunching in a loop
  (`docs/journal/ONDEVICE-2026-10-28.md`). It also wraps libdrm's `drmIoctl` for
  Mesa: kmsro imports each client buffer into Hyprland's exynos render node
  (`renderD128`) and releases it with `DRM_IOCTL_MODE_DESTROY_DUMB`, which
  the kernel refuses on a render node; when that fails with `EACCES` the
  shim closes the handle with `DRM_IOCTL_GEM_CLOSE` (same effect, allowed
  there). Without that, every successful import stayed held: about 13 MB
  per drawer opening, and with the DECON SysMMU a black screen within twenty
  minutes (`docs/journal/ONDEVICE-2026-10-29.md`). `image/tests/verify-rootfs.sh` and the
  smoke check test the wrapper, the binding and that children do not
  inherit `LD_PRELOAD`.
- **Accounts**: `alarm` (uid 1000) is Omarchy's user: groups `wheel video
  audio input network`, home created from Omarchy's `/etc/skel`, ALARM's
  documented default password `alarm`, passwordless sudo for `wheel`
  (`/etc/sudoers.d/10-wheel`, as the Phosh image). `root` is locked; SSH is
  key-only (`PermitRootLogin prohibit-password`, `PasswordAuthentication
  no`), for root and alarm.

## Omarchy's setup at build time

Omarchy's ISO runs `omarchy-apply-system` in the target chroot, then
`omarchy-provision-user` as the user. The build does the same in the image
tree (prior art: omarchy-mobile's `omamobile-firstboot`, MIT, adapted —
no code copied).

**System leaves** (`image/rootfs/omarchy-system-setup.sh`): every leaf of
`install/{config,hardware,login,post-install}/all.sh`, in Omarchy's order,
through Omarchy's own `run_logged` (log: `/var/log/omarchy-install.log`),
with `OMARCHY_INSTALL_USER=alarm`. A failing leaf is a warning in the
MANIFEST, not a build failure. Skipped, with the reason in the MANIFEST:

- `post-install/pacman.sh` (writes Omarchy's x86_64/aarch64 `pacman.conf`)
  and `hardware/pacman.sh` (Apple T2 repository);
- `config/firewall.sh`: ufw's default deny would block SSH and DHCP on
  `usb0`, the only way in, and it opens LocalSend and Docker. `configure-system.sh`
  turns ufw on with the rules of the overlay instead;
- `config/docker.sh` (Docker is left out), `config/snapper.sh` (btrfs
  snapshots on a read-only ext4 image), the limine drop-ins
  (`intel/fred.sh`, two ASUS display leaves);
- the x86 laptop quirks (Intel, ASUS, Apple, Dell, Framework, Lenovo,
  Surface, TUXEDO, NVIDIA, Vulkan for PCI GPUs, Broadcom PCI Wi-Fi, PS/2
  Synaptics touchpads, speaker tunings): they probe the PCI/DMI/ACPI/CPU
  data of the machine they run on — at build time, the build container —
  and the tablet has none of that hardware.

`config/enable-services.sh` runs from an adapted copy without the units
this image does not install (`cups.service`, `docker.socket`,
`linux-modules-cleanup.service`); it enables systemd-resolved,
NetworkManager (`usb0`/`rndis0` stay unmanaged), avahi,
power-profiles-daemon, SDDM and systemd-oomd, and masks
`NetworkManager-wait-online`. `hardware/network.sh` masks
`systemd-networkd-wait-online`: nothing waits for a network at boot.

**User setup** (`image/rootfs/omarchy-user-setup.sh`): `omarchy-provision-user
--force --first-install` as alarm, without a graphical session but with a
private D-Bus session bus so the theme's gsettings reach dconf. Its
`user/all.sh` comes from a build-time copy of `install/` (through
`OMARCHY_INSTALL`, which Omarchy honours) that runs the same leaves and
records each result instead of stopping at the first failure. Skipped:
`chromium.sh`, `mise-work.sh` and `mise.sh` (Chromium, mise and Node.js do
not exist for armv7h; `~/Work/tries` is still created) and the x86 audio,
text-size and nouveau quirks. `omarchy-provision-user` ends by making
`chromium.desktop` the default browser, which fails on armv7h (xdg-settings
exits 2: no such desktop file; the builder confirms that this is the step
that stopped it). The builder then runs the steps that follow it (mailto
handler, migration markers, `finalize-user` marker), each recorded in the
MANIFEST. Its `omarchy-refresh-applications` step also runs
`install/user/mise.sh`, so `~/.local/bin` holds Omarchy's mise wrappers for
AI and developer CLIs (`claude`, `codex`, `gh`, ...); they fail when run,
as mise does not exist for armv7h.

**Tablet settings for alarm**: `~/.config/hypr/monitors.lua` has
`local omarchy_monitor_scale = 2` (1536x2048 portrait panel, 768x1024
logical; Omarchy's `GDK_SCALE=2` is unchanged); `~/.config/uwsm/env`
exports `AQ_DRM_DEVICES`; Omarchy's documented toggles are set:
`omarchy-toggle-idle stay-awake` (no idle screensaver, no idle lock) and
`omarchy-toggle suspend-off on` (no Suspend in the system menu). The
systemd sleep targets are masked as well: resume is untested on this
kernel, and a hang that ends in a watchdog reset boot-loops the tablet
into RECOVERY (`COORDINATION.md`). The touch layer's per-user settings
follow (next section).

## Touch layer P1: on-screen keyboard, hardware keys, cover

The first phase of the omarchy-mobile touch layer (`docs/journal/PLAN.md` §3),
adapted from omarchy-mobile at commit 5f7ba48 (MIT; the squeekboard layout
is GPL-3.0-or-later) for an 8" tablet. No new
package: squeekboard, python3, brightnessctl and jq are already in the
image.

| Piece | How | Files |
|---|---|---|
| On-screen keyboard | squeekboard, started with the session by a user unit (`PartOf=`/`WantedBy=graphical-session.target`, `Restart=on-failure`, enabled with `systemctl --global enable`). Not Hyprland's start-up launch through `uwsm-app` (omarchy-mobile's way): at a slot-3 boot three `uwsm-app` launches came within 230 ms while the shell loaded, and squeekboard's never ran, with nothing logged. It shows itself when a text field takes focus: the app's text-input-v3, which Hyprland relays to squeekboard's input-method-v2. Its layer (`osk`) pops up without Hyprland's layer animation and stays usable above a session lock (`above_lock = 2`). | `/etc/systemd/user/t715-squeekboard.service`; the layer rules in `image/rootfs/t715-tablet.lua` |
| Input-method environment | `QT_IM_MODULE=wayland`, `GTK_IM_MODULE=wayland`, `INPUT_METHOD`, `XMODIFIERS` and `SDL_IM_MODULE` set to "none": this file sorts after Omarchy's `10-omarchy-fcitx.conf`, so it wins | `/etc/environment.d/20-t715-osk.conf` |
| fcitx5 kept off | a `ConditionPathExists=%h/.config/t715-omarchy/fcitx5` drop-in, not a mask: Omarchy's first run (every boot here) does `systemctl --user enable --now omarchy-fcitx5.service`, which fails on a masked unit. Touch that file to run fcitx5 again | `/etc/systemd/user/omarchy-fcitx5.service.d/10-t715-osk.conf` |
| Keyboard settings | `org.gnome.desktop.a11y.applications screen-keyboard-enabled true` (squeekboard stays hidden without it) and `org.gnome.desktop.input-sources sources [('xkb', 'fr'), ('xkb', 'us')]` (squeekboard follows the first source: French AZERTY; US QWERTY in its layout menu), written at build time into alarm's `~/.config/dconf/user` through the private D-Bus session the user setup already uses | `image/rootfs/omarchy-user-setup.sh` |
| Terminal layouts | squeekboard's terminal `us.yaml` with an Esc key, from omarchy-mobile, and its terminal `fr.yaml` (AZERTY, built into squeekboard 1.43.1) with the same Esc key added here, their license notice next to them; linked as `~/.local/share/squeekboard/keyboards/terminal/{us,fr}.yaml`: a terminal gets the terminal layout of the first input source | `/usr/share/t715-omarchy/squeekboard/keyboards/terminal/{us.yaml,fr.yaml,NOTICE}` |
| Hardware keys | `t715-keys`, a user service that reads the `gpio-keys` input device and any device that reports a lid switch (alarm is in `input`); gestures below | `/usr/local/bin/t715-keys`, `/etc/systemd/user/t715-keys.service` (enabled with `systemctl --global enable`) |
| The cover | its Hall sensor will report a lid switch (`SW_LID`) once the device tree has it. Omarchy's lid binds removed (`switch:on:Lid Switch` locks the session, `switch:off` and its clamshell script turn the internal panel off while an external monitor is driven): the tablet has no other display, and nothing could leave a lock. t715-keys turns the screen and touchscreen off when the cover closes, on when it opens. logind ignores the switch (`HandleLidSwitch`, `-ExternalPower`, `-Docked` = `ignore`, in a drop-in that sorts after Omarchy's `10-` and `20-`): suspend is not supported here | `image/rootfs/t715-tablet.lua`, `/etc/systemd/logind.conf.d/90-t715-lid.conf`, `t715-keys` |
| Hyprland and the keys | Omarchy's `XF86PowerOff` binding (its system menu) removed; `XF86PowerOff` and `XF86HomePage` bound to nothing, so neither Omarchy nor the focused app acts on them (Firefox opens its home page on `XF86HomePage`); `key_press_enables_dpms = false` and `mouse_move_enables_dpms = false`: only t715-keys wakes the screen. logind already ignores the Power key (Omarchy's `10-ignore-power-button.conf`) | `image/rootfs/t715-tablet.lua` |
| First-run notices | Omarchy's first run (every boot here) sends a critical "Setup Wi-Fi" notice that never expires and opens `omarchy.network`, which the tablet shell doesn't load, then an "Update System" one once a link is up. Replaced: a normal "Setup Wi-Fi" notice that expires and opens quick settings (the Wi-Fi tile), and no update notice there (`t715-update-check.timer` tells the owner when an update exists, once per version). Overwrites the `omarchy` package's file; no omamobile-omarchy patch touches it | `/usr/share/omarchy/install/user/first-run/wifi.sh` |
| Wi-Fi passwords | The BCM4358 firmware has no SAE (WPA3): the Wi-Fi panel joins an SSID that Quickshell reports as SAE (one served as WPA3 and WPA2) with a WPA2-PSK profile through nmcli, the password on stdin (`image/pkg/omamobile-shell/0002-wifi-wpa2-without-sae.patch`) | `omamobile-shell` 0.2.32-1.2 |
| Floating windows | Omarchy floats its terminals, btop and dialogs at 875x600 and About at 920x480, wider than the 768 px screen: sized to 94 % of the width instead | `image/rootfs/t715-tablet.lua` |
| System menu | a Lock row only once a PIN is set, a PIN row (`omamobile-set-pin`), no Update > Firmware or Update > Config > Plymouth: fwupd has nothing for this tablet, and the kernel lives in BOOT. Omarchy's menu extension file, as omarchy-mobile hides rows | `~/.config/omarchy/extensions/omarchy-menu.jsonc` |

The tablet block is appended to the end of alarm's `~/.config/hypr/hyprland.lua`
(after Omarchy's defaults, the user files and the toggles), between
`-- SM-T715 tablet begin` and `-- SM-T715 tablet end`. It uses only the Lua
forms Omarchy's own files use (`hl.unbind`, `o.bind` with a Lua function,
`hl.config`, `hl.layer_rule`, `o.window`). The smoke
check fails the build unless `Hyprland --verify-config` prints "config ok"
for the whole configuration: a config error would draw Hyprland's error bar,
whose text rendering can deadlock Hyprland here.

**The keys** (`t715-keys`, forked from omarchy-mobile's `omamobile-keys`):

| Key | Screen lit | Screen dark |
|---|---|---|
| Power, short | screen off (DPMS) and touchscreen off | screen and touchscreen on |
| Power, held 0.6 s | Omarchy's system menu (`omarchy-menu toggle system`), while the key is still down | lit at the press, then the system menu |
| Home, short | home, as the touch shell's own Home (P2): an open Omarchy menu, recent apps, app drawer or quick settings closes, an empty workspace takes the screen (`hl.dsp.focus({ workspace = "empty" })`; not when the current one is empty already), and the home screens go back to their home page (`omarchy-shell shell call omamobile.home goHome ''`) | screen on, nothing else (Samsung's Home key wakes the tablet) |
| Home, held 0.6 s | recent apps (`omarchy-shell shell toggle omamobile.switcher {}`: a second hold closes them), after closing an open Omarchy menu | screen on only |
| Volume up/down | Omarchy's bindings (volume and its OSD); t715-keys ignores them | the same, the screen stays dark |
| Cover closed | screen off (DPMS) and touchscreen off, as Power | nothing |
| Cover opened | nothing | screen and touchscreen on |

- Nothing waits for a key held longer than 0.6 s: a long hardware press
  risks a reset that ends in a boot loop (`COORDINATION.md`). There is no
  Power + Volume chord (omarchy-mobile's screenshot).
- A short Power press darkens the panel, and locks first once a PIN is set
  (below, "Screen lock"). The touchscreen goes
  off with it (`hl.config({ input = { touchdevice = { enabled = false } } })`):
  Hyprland keeps delivering touches to apps while the panel is off, and touch
  never wakes it. While dark, t715-keys checks the screen every 5 s and
  gives the touchscreen back if something else lit it.
- A screen lit from outside, by a call or by SIGUSR2 for a new message, stays lit
  for a glance of 20 s (`T715_KEYS_GLANCE`) and goes off again unless a touch, a key or
  logind's idle inhibitor says otherwise: hypridle has already fired and sees no input,
  so it would leave that screen on for good.
- The touch keys, Back and Recent (`tc300k.ko`, `sec_touchkey`, KEY_BACK and
  KEY_SCALE): back, and recent apps. Back closes an open menu or sheet, as Home; or else
  it is XF86Back in a browser, its previous page, since a browser ignores Escape; and
  Escape in any other app. Both keys go by key code: Hyprland looks a key's name up in
  the main keyboard's keymap, squeekboard's, which has neither. On a dark or locked
  screen they do nothing, and Hyprland binds both to nothing so that no app sees them.
- Home goes to the touch shell (P2) the way its own Home button does; until
  P2, Home held opened Omarchy's app launcher (Omarchy 4.0.6 has no window
  overview). The shell's sheets are found by their layer namespace
  (`omamobile-switcher`, `-launcher`, `-quicksettings`, mapped only while
  open), so a Home press costs one `hyprctl layers` and asks the shell to
  close only what is open; the shell calls are started without waiting.
- Every queued key event is handled before the hold timer is checked
  (since P2): a press whose screen check was slow (hyprctl under load) no
  longer reads as held when its release is already waiting; the off-device
  test failed that way under a loaded host, and has a case for it now.
- The screen's state comes from Hyprland (`dpmsStatus`) at each press; a
  Hyprland that does not answer reads as lit, so a press never wakes the
  screen blind (as omamobile-keys). A wake that finds a brightness of 0 sets
  40 %.
- Why a service reading evdev and not Hyprland binds, as omamobile-keys:
  one process times each press, so the long press fires while the key is
  down without state files and background timers per event, and the
  gestures are tested off the device with fake input.
- If the panel does not come back from DPMS off on the device,
  `T715_KEYS_SCREEN_OFF=backlight` uses brightness 0 instead (the panel's
  dimmest level, not black), with the touchscreen off all the same:
  `systemctl --user set-environment T715_KEYS_SCREEN_OFF=backlight && systemctl --user restart t715-keys`.

**Kept from `phone.lua`**: Power unbound from Omarchy and handled outside
Hyprland, `key_press_enables_dpms = false`, the `osk` layer above the lock,
squeekboard started with the session (here by a user unit) with the
gsetting on. **Left out**: maximizing every
window and dropping the floating tag (a 768 px wide portrait screen tiles
two windows at a usable size; only the oversized floats are resized),
gaps and borders at 0 (Omarchy's 5/10 px gaps and 2 px border cost 3 % of
the width here, not phone.lua's 5 %), `exit_window_retains_fullscreen`
(goes with maximize), the screensaver, modal, Nautilus and PiP rules
(Omarchy's PiP already fits; no screensaver: `ttfx` does not exist for
armv7h), the
volume-key and screenshot bindings, the fingerprint, call and onboarding
rules, and omarchy-mobile's file-picker environment.

**Checks off the device**: `image/tests/test_t715_keys.sh` runs t715-keys on the
build machine with python3 against a FIFO of fake `input_event` records and
stand-ins for `hyprctl`, `omarchy-menu`, `brightnessctl` and
`omarchy-hw-display` (every gesture above, the hold timing, an unanswered
Hyprland, a slow one, the touchscreen resync, the backlight mode; since P2
also `omarchy-shell` for the touch shell's home and recents; the cover's
switch events, and the device discovery on a fake sysfs tree). The smoke
check runs `t715-keys --check` in the armv7h image (16-byte events, its
commands present), reads alarm's two gsettings back, loads both terminal
layouts with `squeekboard-test-layout`, runs systemd's environment.d
generator for alarm (the Wayland input method wins) and verifies the Lua.
`image/tests/verify-rootfs.sh` checks the files, modes, the global wants links
(t715-keys, t715-squeekboard), that no Hyprland launch of squeekboard is
left, the fcitx5 condition and an unmasked unit, the dconf entries, the
layout links, the lid unbinds, the logind drop-in (and that it sorts last)
and the build records.

**On the tablet** (a slot; over SSH as root, `A='sudo -u alarm env
XDG_RUNTIME_DIR=/run/user/1000'`):

1. `$A systemctl --user status t715-keys t715-squeekboard omarchy-fcitx5`:
   t715-keys active and its log reads `reading /dev/input/event1 (screen
   off: dpms)`; t715-squeekboard active (`$A journalctl --user -u
   t715-squeekboard -b`, one start); fcitx5 inactive with "condition
   failed".
2. Power, short: the panel goes black, taps do nothing; `$A hyprctl -i 0
   monitors -j | jq '.[].dpmsStatus'` is `false`. Power again: the picture
   and touch come back. Five times in a row (DPMS off and on, with the
   panel's power-off and init sequence, has never run on this
   DECON/DSI path); then the same with Home as the wake key. If the panel
   stays black: the backlight mode above, over SSH.
3. Power held about 0.6 s (never longer than a second): the system menu
   appears while the key is still down, without Lock or Suspend; releasing
   changes nothing else.
4. Home in Firefox does not open Firefox's home page (Home's touch-shell
   gestures: "Touch layer P2", slot checklist).
5. Volume keys: Omarchy's volume OSD, lit or dark, and the screen state is
   unchanged.
6. The keyboard: tap a text field in Firefox (address bar), in a GTK app
   (Nautilus), in Omarchy's menu search and in a terminal (the AZERTY
   terminal layout with Echap); squeekboard shows AZERTY, types (é, à from
   its accents view) and hides; its layout menu offers English (US). Note
   whether it pops up uninvited (e.g. each time the system menu opens).
7. `$A journalctl --user -u t715-keys` after the tests: one line per
   gesture, no Python traceback; t715-keys' memory (`ps -o rss= -C
   t715-keys`; a python3 process, expect about 10 MiB).
8. The floating windows (Omarchy's About, btop from the menu) fit the
   screen.
9. The cover, once the device tree reports its Hall sensor: `libinput
   list-devices` shows a lid switch, `$A journalctl --user -u t715-keys`
   names its device; closing the cover darkens the panel, opening it lights
   it (touch back too); `journalctl -b -u systemd-logind` logs no lid
   action.

## Touch layer P2: the touch shell

The second phase of the omarchy-mobile touch layer (`docs/journal/PLAN.md` §3):
omarchy-mobile's `omamobile-shell` and `omamobile-omarchy` at commit 5f7ba48
(MIT), built from `image/pkg/` (`docs/image/PACKAGES.md`) and installed by
`image/rootfs/install-mobile.sh` from `image/rootfs/packages.mobile`. Both are `arch =
any`: QML, JavaScript, bash and Python, nothing compiled, no Hyprland
plugin. They are plugins of Omarchy's own shell, not a second shell:
`omamobile.bar` replaces Omarchy's bar, the other plugins are added, and
Omarchy's menus, OSD, notifications, polkit agent and lock stay.
`omarchy.bar` itself is not loaded (`bar.id` selects `omamobile.bar`), but
Omarchy compiles the component of every enabled first-party bar widget at
each shell start whether a bar shows it or not (`syncPluginWidgets` in
`shell.qml`: `Qt.createComponent` for each `bar-widget` plugin), and
`omamobile.bar` shows none. So the tablet profile lists Omarchy's 18
bar-widget-only plugins in `disabledPlugins` (`PluginRegistry.isEnabled`):
`omarchy.agents`, `.active-window`, `.indicators`, `.keyboard-layout`,
`.microphone`, `.spacer`, `.system-update`, `.tray`, `.workspaces`,
`.audio`, `.bluetooth`, `.clock`, `.dropbox`, `.monitor`, `.network`,
`.power`, `.tailscale`, `.weather` (43 QML and JavaScript files, about
16500 lines, no longer compiled at start). `omarchy.menu` and
`omarchy.media`, which are also bar widgets, and every service, overlay and
panel stay on. Nothing visible changes: those widgets' IPC targets
(`omarchy.indicators refresh`, `omarchy.clock refresh`, ...) only exist in
a widget a bar has instantiated, so they were already absent here, and
`omarchy-shell shell toggle omarchy.weather` and the like already failed
(`omamobile.bar` hosts no Omarchy widget).

| Surface | Plugin | On the tablet |
|---|---|---|
| Status bar | `omamobile.bar` | 44 px at the top: clock, Bluetooth, Wi-Fi, battery, unread count; a tap or a pull down opens quick settings |
| Quick settings | `omamobile.quicksettings` | a sheet from the top: Wi-Fi, Bluetooth, Do not disturb, Airplane mode in the collapsed row, then Battery saver, Dark theme, Night light, Keyboard, Clipboard, Screenshot (3 columns at 768 px); brightness and volume; the gear opens Omarchy's menu; the notification shade under it; the Wi-Fi picker and the Bluetooth panel (`omamobile-bt-agent`) |
| Home screens | `omamobile.home` | pages on the wallpaper, a 6x8 grid: clock, quick toggles and Phone, Messages, Chromium, Firefox, Files, foot, btop, Papers, mpv on page 1, media and battery on page 2 (`image/pkg/omamobile-shell/tablet-home.json`); long press for edit mode |
| Dock, drawer, home pill | `omamobile.launcher` | on an empty workspace the dock's search pill opens the drawer (6 columns); over an app the home pill: swipe up for home, swipe up and hold for recent apps; under the keyboard a 32 px strip does the same |
| Recent apps | `omamobile.switcher` | swipe up on the dock, or Home held; cards with live previews, flick up to close, Clear all |
| Back | `omamobile.back` | a swipe in from the left or right edge (14 px strips) does what the Back key does, through `t715-keys` (SIGHUP) |
| Keyboard hide button | `omamobile.keyboard` | a 44 px button above squeekboard folds it |
| One app per screen | `omamobile-launch` | an app started from the shell gets a new empty workspace, an open one is focused |

All gestures are layer-shell strips of the shell: Hyprland's
`gestures:workspace_swipe_touch` stays off (it would fight them), and
`image/rootfs/t715-tablet.lua` only adds the hide button's layer rule (above a
lock, like the keyboard).

**Omarchy's patches** (`omamobile-omarchy`): 16 of upstream's 19, applied to
`/usr/share/omarchy` by its pacman hook (`omamobile-omarchy-patches apply
--hook`) when the package is installed; `install-mobile.sh` runs the
applier again (a no-op), its `status` and `verify`, and stops the build
unless every patch is in place; `finalize.sh` runs `verify` again after
Omarchy's setup. The applier starts from Omarchy's own files, recognised by
the sha256s in the omarchy package's mtree, which the retagged package keeps
(`docs/image/REPACK.md`); on the armv7h 4.0.6-1.1 all 16 apply with `--fuzz=0`,
none found upstream.

| Kept | What it changes |
|---|---|
| 0001 | first run: no "Learn Keybindings" welcome once `welcome-keybindings-not-applicable` is marked (omamobile-setup-user does) |
| 0003, 0011, 0014 | the lock's number pad, PIN-or-password input and emergency button (a warning, never a dialpad): off without the `lock-keypad` toggle |
| 0005 | swipe through the image picker; hold the desktop for the Style menu |
| 0006, 0007, 0013 | screensaver and idle on a touch device (keyboard off while it runs, lock on return): dormant with stay-awake |
| 0008 | panels with `bl_power` follow DPMS (only where the user may write it) |
| 0009 | the lock's `wake` IPC for hardware keys |
| 0010 | the polkit prompt usable with the on-screen keyboard |
| 0015, 0017, 0019 | notifications: inline reply, swipe to dismiss and a 44 px close button on touch screens, forget one by IPC (the shade uses it) |
| 0018 | Omarchy's menu: a back button and a swipe right to go back |
| 0020 | notification wording for touch ("Tap to open", no "Super + ..."): switched on by `/etc/environment.d/30-t715-touch.conf` (`OMARCHY_NOTIFICATION_PHRASING=touch`), since the patch detects a phone by `omamobile-update`, which is not shipped |
| bridge-4.0.4-menu-first-frame | the menu card waits for its first sized frame (no flash at the top edge). Kept although the earlier analysis listed it as 4.0.4-only: its header targets 4.0.6, and upstream's own test applies it to the real 4.0.6 package after 0018 |

Dropped: 0012 and 0016 (hand Omarchy's update, channel switch and pacman
refresh to `omamobile-update`, which assumes an `[omamobile]` repository)
and 0014 (the lock's emergency-call button). `omamobile-update` is not
shipped.

Not added: a `sourceSize` for the wallpaper in Omarchy's
`plugins/background/Background.qml` (it has none, unlike `LockView.qml`).
`image/rootfs/t715-wallpapers.sh` already scales every theme background to a
2048 px short side at build time, which is the height the 1536x2048 portrait
panel needs, so Qt decodes the default wallpaper at 3641x2048 with or
without one. And with `PreserveAspectCrop`, Qt 6.12 scales a raster to the
requested size in both directions: measured in the aarch64 container,
`sourceSize` 1536x2048 decoded last-horizon's 3160x1776 bokeh at 3644x2048
and catppuccin-latte's 1536x1024 at 3072x2048: more memory for the 16
shipped backgrounds the build leaves alone (all under 2048 px tall). It would only help wallpapers added
after the build, and landscape; a version that never upscales (a
height-only `sourceSize` with `Image.Stretch`, which only scales down, and
the crop done by sizing the item) is for when rotation (P3) comes.

**Per-user setup** (`image/rootfs/omarchy-user-setup.sh`, step 5, after P1):
`omamobile-setup-user` runs as alarm. Each of its steps runs once, tracked by
an `omarchy-done` marker; the markers of the steps below are set first, so
it skips them (each recorded in the MANIFEST with its reason):

| Pre-marked | Why |
|---|---|
| `omamobile-monitor-scale`, `omamobile-gdk-scale` | scale 3 is the phone's 480x1040; the tablet keeps scale 2 (768x1024) and Omarchy's `GDK_SCALE=2` |
| `omamobile-osk` | P1 starts squeekboard (`t715-squeekboard.service`) and sets its gsettings |
| `omamobile-phone-rules` | `hypr/phone.lua` (maximize everything, no gaps, `omamobile-keys` bindings) is not shipped; `t715-tablet.lua` has the tablet's rules |
| `omamobile-suspend-off` | the build sets Omarchy's suspend-off toggle already |
| `omamobile-idle`, `omamobile-lock-keypad`, `omamobile-lock-after-screensaver`, `omamobile-credential-type`, `omamobile-menu-pin` | the phone's 60 s idle lock and PIN: `omamobile-set-pin` sets the toggles itself, the build adds the PIN row, t715-keys locks when the screen goes off, and stay-awake keeps Omarchy's idle off |
| `omamobile-fingerprint-plugin`, `omamobile-menu-fingerprint`, `omamobile-call-plugin`, `omamobile-access-plugin`, `omamobile-update-plugin`, `omamobile-menu-update` | plugins and menu rows for what is not shipped |
| `omamobile-chromium-*` (5) | the launcher, `pkg/t715-chromium`, sets Chromium's flags |

The steps that run: plugin links in `~/.config/omarchy/plugins`, the tablet
profile as `~/.config/omarchy/shell.json` (the package's
`profile/shell.json`: the seven plugins, the drawer at 6 columns, Omarchy's
idle values, Omarchy's bar widgets in `disabledPlugins`), the keyboard, home
and back plugins, no keybindings welcome,
dev and duplicate apps hidden from the drawer (Qt tools, Disks, Evince,
fcitx5's settings, foot's server and client entries), no pointer on screen
(`cursor:invisible`, `hide_on_touch`), foot with 6 px padding and a 300 ms
long press, the portrait screensaver wordmark, and menu rows that cannot
work here hidden (Update > Channel and the config resets, Logout, EFI and
drive rows, keybinding guides, bar positions, x86_64-only installers). Its
terminal-layout step finds P1's link and leaves it. Then the build copies
the tablet `home.json` (`~/.config/omamobile/home.json`) and hides
Omarchy's Docker entry, which needs lazydocker (`NoDisplay=true` in alarm's
copy). Its web apps stay in the drawer and open in Chromium.
`omamobile-setup-user.service` (every login, before the compositor) is
masked with `systemctl --global mask`, to keep the session's start short. On
the persistent root a new package's steps do not run by themselves: run
`omamobile-setup-user` once, as the user, after such an upgrade.

**P1 and P2: one mechanism per function**

| Function | Kept (P1 or image) | omarchy-mobile's, left out |
|---|---|---|
| Power and Home keys | `t715-keys` (Home now opens the shell's home and recents) | `omamobile-keys` and phone.lua's bindings; no Power+Volume chord |
| Sleep | none: the sleep targets are masked | `omamobile-sleepd` and its unit |
| Keyboard start and gsettings | `t715-squeekboard.service`, the dconf values written at build time | setup-user's `omamobile-osk` step (autostart.lua), phone.lua's gsettings at login, `omamobile-osk-guard` and its unit (it repairs the setting after the screensaver, which stay-awake keeps off) |
| Input-method environment | `/etc/environment.d/20-t715-osk.conf` | `/usr/lib/environment.d/20-omamobile-osk.conf` (also its portal file-picker variables) |
| fcitx5 off | the `ConditionPathExists` drop-in in `/etc/systemd/user` | the package's own drop-in: two conditions would both have to hold, and touching P1's flag would no longer bring fcitx5 back |
| Terminal layouts with Esc | `/usr/share/t715-omarchy/squeekboard/...` (US and French) and their links | the package's copy (US only) |
| Keyboard visibility, hide button | `omamobile-osk-watch` (launcher and hide button), `omamobile.keyboard` | n/a: new in P2 |
| Window rules | `t715-tablet.lua` (oversized floats fitted, tiling kept) | `phone.lua` (maximize everything, no gaps) |
| File chooser | Omarchy's (xdg-desktop-portal-gtk) | xdg-desktop-portal-gnome's chooser and portals.conf, the Access portal backend |

**Sizes for 768x1024**: scale 2, so the plugins' 44 px touch targets are
88 panel pixels, about 7 mm. The home grid is 6x8 (the plugin's largest;
upstream's default is 4x6 for 480 px), about 128x113 px a cell; the drawer
has 6 columns (`"columns": 6` on the launcher's entry in `shell.json`, the
plugin's maximum); quick settings and recent apps size themselves from the
screen (3 tile columns, cards in the screen's shape). Upstream's offscreen
harnesses drew the drawer, the quick-settings sheet and the seeded home at
768x1024 and 1024x768 without errors and with every item on screen.

**Cost** (Quickshell is the heaviest process on the tablet: up to 2 cores
when menus open, 7.7 s to "Configuration Loaded", `ONDEVICE-2026-10-28.md`):
- QML added: 7 plugins, 47 QML files (13245 lines) and 24 JavaScript files
  (7071 lines), of which the home screens are 11779 lines (5648 of them the
  OWL runtime, imported even with OWL off). Omarchy's shell is 130
  files, 39889 lines, much of it menus and panels loaded on demand.
- All six panels are `keepLoaded`, so they are compiled and built at shell
  start (Quickshell 0.3.2 keeps no QML disk cache). Measured off the device
  (aarch64, Omarchy 4.0.6 on a headless sway, same profiles): the shell
  used 1.3 to 2.3 s of CPU in its first 6 s with Omarchy's profile and 2.3
  to 4.0 s with the tablet's (about +1 to 1.7 s, +50 to 80 %), and 315 to
  326 MiB RSS against 520 to 534 MiB (64-bit, software rendering).
  "Configuration Loaded" itself comes as early (the panels load after it),
  so on the tablet expect the home, dock and bar some seconds after the
  7.7 s, not a later "Configuration Loaded"; to measure in a slot.
- Trimmed (`omamobile-shell` 0.2.32-1.4, not yet measured on the
  tablet): Omarchy's 18 bar-widget-only plugins are no longer compiled at
  start (`disabledPlugins`, above), and
  `image/pkg/omamobile-shell/0004-tablet-quiet-pollers.patch` stops two
  pollers. The home's quick toggles no longer run `qs ipc ... notifications
  dndState` every 30 s (a `qs` client process each time): they watch
  `~/.local/state/omarchy/notifications.json`, which Omarchy's notification
  service rewrites (atomically, 200 ms later) on every do-not-disturb
  change. The bar's call and modem watchers (`omamobile-call-watch`,
  `-cell-watch`) start only when the bar's `callWatch` / `cellWatch`
  setting is true: off by default, on in the tablet profile since the
  telephony packages ship them.
- New processes: two `omamobile-osk-watch` (python3, D-Bus; the launcher's
  and the hide button's), `inotifywait` on `~/.config/omamobile/widgets`;
  quick settings runs `tile-state.sh` each time it opens.
- Off: OWL widgets (`~/.config/omamobile/features.json` is absent, so the
  home's OWL runtime is idle) and the OWL built-ins (`omamobile-owl-widgets`
  is not shipped: if the user adds one from the Widgets sheet, its tile says
  the store package is missing); no blur or MultiEffect in the plugins.

**Checks off the device**: `image/tools/build-pkg` checks both packages (upstream's
applier tests against synthetic Omarchy trees in `omamobile-omarchy`'s
`check()`; in `omamobile-shell`'s, the profile's `disabledPlugins` holds
only bar-widget-only ids and none of `omarchy.menu`, `.media` or the
services, and patches 0002 to 0004 are in place); the build stops if the
series is not in place; the smoke check
runs the applier's `status` and `verify`, checks that every QML module the
plugins import is installed, parses their QML with `qmlformat` and their
helpers, checks that python3 has dbus and GLib, alarm's profile and plugin
links, and `Hyprland --verify-config` on the whole configuration (with
setup-user's additions); `image/tests/verify-rootfs.sh` checks the packages and
versions, the series and the applier's state against the files in the
image, the markers, the seeded files, the masked unit, the telephony
(tools, enabled units, no NV and no APN in the image), and that no other
phone-only helper, unit or duplicate mechanism is there;
`image/tests/test_t715_keys.sh` covers Home's new gestures. Upstream's own tests,
run on the package in an aarch64 container: the switcher's and the shade's
touch tests pass, as do the home, status, Wi-Fi, Bluetooth, notifications
and back model tests and `tile-scripts.sh`; the tiles-model test fails where
it expects the phone's tiles, and the launch and widget-tool tests where
they need the dropped agent entry.

**On the tablet** (a slot; as P1, `A='sudo -u alarm env
XDG_RUNTIME_DIR=/run/user/1000'`):

1. After boot: the touch shell's bar at the top, the home page (clock,
   toggles, six apps) and the dock; `$A omarchy-shell shell listPlugins |
   jq -r '.[] | select(.enabled) | .id' | grep omamobile` lists the seven
   plugins; `journalctl -b _UID=1000 | grep -i qml` has no error, and
   `journalctl -b _UID=1000 | grep 'failed to start'` nothing (no modem or
   call watcher); note the time from login to the home page
   (`omarchy-shell shell call omamobile.home state ''` answers
   `"loaded":true`).
2. Pull-down: a tap or a pull down on the bar opens quick settings; the
   tablet's tiles only; Wi-Fi and Bluetooth tiles toggle; the brightness
   slider moves the backlight; a swipe up or a tap on the scrim closes it.
   The Bluetooth chevron opens the Bluetooth panel (scan, pair).
3. Drawer: a tap on the dock's search pill opens the drawer (6 columns, no
   web apps); typing with squeekboard filters; an app starts on its own
   workspace; a pull down on the header closes the drawer.
4. Home pill over an app: swipe up from it for home; swipe up and hold for
   recent apps; with the keyboard up, the same from the strip under it.
5. Recent apps: cards for open apps, a tap switches, a flick up closes,
   Clear all closes all (two taps); Home in recents goes home.
6. Back: a swipe in from the left and from the right edge closes a dialog or
   Omarchy's menu (Escape); a short drag does nothing.
7. Home key: short on an app goes home (menu, recents, drawer and quick
   settings close if open); held about 0.6 s (never longer than a second)
   opens recent apps, held again closes them; on a dark screen only wakes.
8. Home screens: long press for edit mode, move an app, Done; a swipe
   sideways to page 2 and Home brings page 1 back.
9. The keyboard's hide button folds squeekboard.
10. Cost: `top -b -n1 | head -20` at rest and while opening quick settings
    and the drawer (quickshell CPU, its RSS against slot 2's), and
    `pgrep -af omamobile-osk-watch` (two, not restarting). The home's
    Silence toggle follows do-not-disturb set elsewhere (quick settings,
    `omarchy-toggle-notification-silencing`) within a second, with no
    `qs ipc` process at rest.

## Bluetooth

From the Phosh session (2026-10-28, commits 8e1c3e9 and
bd3536d): the kernel drives the BCM4358 over its UART (serdev, 460800 baud,
no `btattach`); the initramfs copies the module tree into the root, so the
image still ships no `/lib/modules`.

| Piece | Where | From |
|---|---|---|
| Patch RAM | `/usr/lib/firmware/brcm/BCM4358A3.hcd` and the same file under its original name `bcm4358A3_V0086.0144.hcd` (0644), and `BCM.samsung,gts28ltexx.hcd` -> `BCM4358A3.hcd`: btbcm finds no chip name for this LMP subversion and asks for `brcm/BCM.<board compatible>.hcd` | the vendor dump `$T715_LINUX_DIR/dumps/vendor_firmware/bcm4358A3_V0086.0144.hcd` (53841 bytes, git-ignored there, never copied into this repository): `image/tools/build-rootfs` checks it in preflight, stages it read-only into its temporary build context (`firmware/bt/`, deleted with it), and the Dockerfile step after the package steps installs it as the Phosh Dockerfile does; its sha256 is in the MANIFEST |
| Stable address | `/usr/local/sbin/t715-bt-addr`, `t715-bt-addr@.service`, `90-t715-bt-addr.rules`: the controller gets a locally administered address derived from the eMMC CID (never logged) | byte for byte from `image/rootfs/overlay/` |
| Daemon | `bluez`, `bluez-utils` (`btmgmt`, which the script needs), from Omarchy's list; `bluetooth.service` enabled (Omarchy's `hardware/bluetooth.sh` leaf, made sure of in `configure-system.sh`) | ALARM |
| Pairing agent | the quick settings' own, `omamobile-bt-agent` (KeyboardDisplay: it asks), registered only while the Bluetooth panel is open. Omarchy's `bt-agent.service` (`bt-agent -c NoInputNoOutput`, which accepts every request) never starts: a drop-in adds a condition that cannot hold | `/etc/systemd/user/bt-agent.service.d/10-t715-no-auto-accept.conf` |
| Audio | `pipewire-audio` (PipeWire's BlueZ SPA plugin, for Bluetooth audio), `pipewire-pulse` (the PulseAudio server Firefox needs), `rtkit` (realtime priority for PipeWire), and the wm1814 card's UCM profile (`/usr/share/alsa/ucm2/conf.d/wm1814/`, from commit `159d3e9`): speaker and microphone | `image/rootfs/packages.extra`, `image/rootfs/overlay/` |

Why the auto-accept agent goes: its unit's comment assumes the adapter is
pairable only while Omarchy's Bluetooth panel scans, but slot 3 found
`Pairable: yes` with the tablet idle, so a nearby device could have paired
without a prompt. Not a mask: Omarchy's first run (every boot on this RAM
overlay) enables it with five other units in one `systemctl --user enable
--now`, which fails for all six on a masked unit (the reason the fcitx5
unit has a condition too). Enabled, it is skipped at each start.

`image/tests/verify-rootfs.sh` compares the patch RAM with the vendor dump, the
link, the three files with the Phosh overlay, the packages and the enabled
unit, the agent drop-in (the only one, Omarchy's unit unmasked and still
the auto-accept one) and the BlueZ plugin; the smoke check looks for the
patch RAM, the link, `btmgmt`, and the plugin with its libraries.

**On the tablet**: `dmesg | grep -i bluetooth` shows the patch RAM loaded;
`btmgmt info` and `bluetoothctl show` show `hci0` up with the generated
address (not `43:58:A3:...`), `systemctl status t715-bt-addr@hci0` succeeded;
`bluetoothctl power on; bluetoothctl scan on` finds devices; the quick
settings' Bluetooth tile and panel show the adapter. `$A systemctl --user
status bt-agent` is inactive with "condition failed"; with the panel
closed, a phone's pairing attempt must fail (no agent), with it open the
tablet asks.
Pair a headset from the panel: `$A wpctl status` lists a bluez5 sink, and
the volume keys move it; no "BlueZ SPA plugin" warning in `journalctl -b
_UID=1000 | grep -i wireplumber`.

## Wi-Fi

From the Phosh session (2026-10-28, commits 4a0ed52 and
f0278fd): brcmfmac drives the BCM4358 over PCIe with linux-firmware's build
for the chip's A3 ROM (7.112.300.14). Samsung's `bcmdhd_sta.bin` stops
answering under brcmfmac; its NVRAM is kept.

| Piece | Where | From |
|---|---|---|
| Firmware | `/usr/lib/firmware/brcm/brcmfmac4358-pcie.bin` (0644) | the one file from ALARM's signed `core/linux-firmware-broadcom` (20260916-1 at the 2026-10-29 build): `image/rootfs/install-wifi.sh` (Dockerfile step 3f) has pacman download the package into its cache mount, which checks the signature, extracts the file and stops the build unless its sha256 is `f04d8fdc…bee04337c`. The package is not installed (the image ships no firmware package); the Phosh image takes the same file from git.kernel.org. Its version and sha256 are in the MANIFEST |
| NVRAM | `/usr/lib/firmware/brcm/samsung-gts28/nvram_net.txt` (0644), and `brcmfmac4358-pcie.txt` -> `samsung-gts28/nvram_net.txt`, the name brcmfmac asks for | the vendor dump `$T715_LINUX_DIR/dumps/etc_wifi/nvram_net.txt` (6053 bytes; the tablet's MAC address and radio calibration; git-ignored there, never copied into this repository or `image/out/` other than inside the image): staged read-only into the temporary build context like the patch RAM; only its sha256 is printed (build log, MANIFEST header). Samsung's `bcmdhd_*` firmwares are not shipped |
| Stable address | `/usr/local/sbin/t715-wifi-addr` (0755), `90-t715-wifi-addr.rules`, `NetworkManager/conf.d/20-t715-wifi-mac.conf`: the NVRAM's address is the same on every SM-T715, so the interface gets a locally administered one derived from the eMMC CID (never logged), which NetworkManager keeps for connections (`wifi.cloned-mac-address=preserve`) | byte for byte from `image/rootfs/overlay/` at its committed HEAD (`git show`, not its working tree) |
| Network | NetworkManager (Omarchy's, enabled by its `enable-services.sh`) with wpa_supplicant, its default Wi-Fi backend, started over D-Bus. No iwd or connman; systemd-networkd (masked wait-online, disabled by Omarchy's `hardware/network.sh`) and ALARM's dhcpcd and netctl are not enabled. `usb0` and `rndis0` stay unmanaged (`10-usb-rndis-unmanaged.conf`, the only file that sets `unmanaged-devices`) | ALARM, Omarchy |

`image/tests/verify-rootfs.sh` checks the firmware against its pinned sha256, the
NVRAM against the dump, the link, modes and owners, the three files and
their git modes against the Phosh repository's HEAD (an upstream commit
shows up as a failure until they are copied again), that `brcm/` holds the
Bluetooth and Wi-Fi entries only, the build records, NetworkManager's
backend and that nothing else manages the network or the USB link. The
smoke check looks for the firmware, the NVRAM (presence and size only) and
the link, parses `t715-wifi-addr`, and reads NetworkManager's merged
configuration (`NetworkManager --print-config`: `wifi.backend`, the
unmanaged USB link, the MAC rule).

**On the tablet**: `dmesg | grep brcmfmac` shows firmware 7.112.300.14 and
no NVRAM error; `nmcli device` lists `wlp1s0` managed and `usb0` unmanaged;
`ip link show wlp1s0` has a locally administered address (second hex digit
2, 6, A or E), not the NVRAM's; `nmcli device wifi list` sees 2.4 and 5 GHz
networks; join one from the quick settings' Wi-Fi picker (its password with
squeekboard); `timedatectl` then shows the clock synchronized. Like
everything else, the saved connection is gone after a reboot (RAM overlay).

## Firewall

ufw is on: nothing comes in but SSH (22/tcp) and DHCP (67/udp) on `usb0`, the cable to
the Mac. Wi-Fi and LTE are closed, SSH included; ufw's default rules still answer ping
and let established traffic back. The rules in `/etc/ufw/user.rules` and `user6.rules`
come from the overlay, where they were written by ufw itself on the tablet;
`configure-system.sh` sets `ENABLED=yes` and enables `ufw.service`. Omarchy's
`config/firewall.sh` is skipped: it opens LocalSend and Docker, and it would leave `usb0`
closed, the only way in.

The Hotspot needs protected management frames off (`21-t715-wifi-no-pmf.conf`, for the
client link too): with NetworkManager's default a phone's password read as rejected.

The Hotspot tile needs more while it is on: DHCP and DNS on the Wi-Fi interface and
forwarding towards the modem, which `/etc/NetworkManager/dispatcher.d/50-t715-hotspot-firewall`
adds when the access point named Hotspot comes up and removes when it goes down, straight
into ufw's user chains: a rule added with the `ufw` command would stay in `user.rules` past a
crash, open on the next Wi-Fi network, and `ufw status` does not show these. SSH stays
closed there.

Changing the rules from a distance: arm a return first, then confirm.

```bash
systemd-run --unit=t715-fw-rollback --on-active=300 /usr/bin/ufw --force disable
```

```bash
systemctl stop t715-fw-rollback.timer
```

## Screen lock

Ready and off. Nothing locks until the owner sets a PIN, because a lock with no known
password could not be left. From the system menu (Power held), PIN runs
`omamobile-set-pin`, which asks for the current password (`alarm`) and the new PIN in
`passwd`, then sets the toggles `lock-keypad` and `lock-on-start`, and makes sudo ask for
the password (`t715-sudo-asks-password`). From there:

- the session locks at login (`t715-tablet.lua`, `omarchy-toggle-enabled lock-on-start`);
- everything that turns the screen off locks first: Power, the 2 minutes of idle, the
  cover (t715-keys);
- lighting the screen shows the PIN pad (`omarchy-shell lock wake`);
- the call card stays above the lock and takes touches, the ringing card and the
  in-call controls alike (`omamobile-call` layer, `above_lock = 2`);
- the Lock row appears in the system menu.

A lock that does not come up, the shell being down for instance, leaves the screen lit: a
dark screen would wake on the open session with nothing to say so.

SSH over USB stays open, with root's key. To undo everything from there, as root: remove
`~alarm/.local/state/omarchy/toggles/lock-on-start`, then `systemctl restart sddm` if the
session is locked. The lock has no IPC to open it, only a good password does, so the session
restarts, and comes back with no lock. The modem and its calls are not in the session.

## Cameras

Photo and Selfie in the drawer take one picture with the rear or front camera, into
`~/Images`, and a notification opens it. No preview, and the rear needs the screen lit:
`docs/hardware/CAMERA.md`. They need
the sensor tables in `/usr/lib/firmware/t715/`, which an image cannot carry (Samsung's):

```bash
python3 research/parity/camera/t715-cam-seq.py FIRMWARE SEQ6B2 OUTDIR
```

## Updates

`t715-update-check.timer` looks 10 minutes after login, then daily, with `checkupdates`,
which reads a copy of pacman's databases and changes nothing. A notification says so
once per set of updates and opens `omarchy-update` when tapped.

## Modem and telephony

The Shannon SS333 modem (`docs/hardware/MODEM.md`) needs a kernel with
`kernel/patches/t715-modem` (`docs/DEPLOY.md` 11.8); without it every modem
unit skips itself and the image behaves as before.

| Package | Role |
|---|---|
| `t715-modem` (`image/pkg/t715-modem`, from `modem/`) | loader and supervisor, `shannond` and its ModemManager facade, units, NV provisioning from EFS (read only, first boot), call audio hook, `t715-call-profile` (the "Voice Call" PipeWire profile, while WirePlumber is older than 0.5.15), `t715-sim-pin` (SIM PIN dialog), udev rules, modprobe blacklist |
| `t715-mobile-settings` (in `t715-modem`) | the APN, data, roaming, technologies and SIM state. omarchy-mobile's plan has a "Mobile network" sheet; its code at `5f7ba48` does not |
| `omatel-agent`, `omaphone`, `omamessages` | omarchy-mobile's telephony: the session service (ringing, call log, SMS store, notifications) and the Phone and Messages apps, over the ModemManager API; `configure-system.sh` enables the agent for every user |
| `omamobile-shell` | the bar's cellular icon and call chip, the call card (`omamobile.call`) and the mobile data tile, on NetworkManager's gsm connection (`0005-tablet-modem.patch`) |
| `modemmanager` | `mmcli` only; `ModemManager.service` is masked, shannond's facade owns the bus name |

`configure-system.sh` puts `alarm` in the `radio` group (`shannonctl`, the
call profile service). The image carries no NV and no APN: the NV comes from
the device's EFS at first boot, and the APN goes in **Réseau mobile**
(`t715-mobile-settings`, from the drawer, or a tap on the data tile while no
connection exists), which writes NetworkManager's connection `t715-mobile`. The
radio comes on at boot; with no APN known the modem stays on 3G/2G until the
first connection gives one. `shannond` then keeps that APN, and the technologies
chosen in the app, in `/var/lib/shannond/settings.json` (0600), so LTE comes from
boot on. `SHANNOND_OPTS="--lte-apn <APN>"` in `/etc/shannond.env` still works, and
the saved choice wins over it.

Phone and Messages are on the home screen; `t715-sim-pin` is in the app drawer.

Booted on the tablet in image mode on 2026-10-30, as a separate file, with the
modem BOOT built with `t715.rootimg=media/0/linux/rootfs-omarchy-test.img
t715.persist=0`: the NV copy made from EFS at first boot matched the verified
one, CP online in 9.9 s, registered on 3G with no APN, `omatel-agent` and
`t715-call-profile` running, first `nmcli connection up` in 21 s, ending on LTE
(ping, HTTPS). The build before it also sent an SMS to the own line from
Messages, and made a call through `omatel-agent` to voicemail, with the Voice
Call profile on and back. The image's first boot does not touch the persistent
root.

The final image of that day (`2d83ed51c9d3…`), with Chromium, rotation and Réseau
mobile, booted the same way on the Landlock kernel: first `nmcli connection up` in
16 s, ending on LTE, HTTPS, a link opened in Chromium. On the persistent root, LTE
then came up 39 s after power-on with no `/etc/shannond.env`. That image is the
rescue, `rootfs-omarchy.img`: `t715-reboot-to recovery` booted it on kernel `00021`,
modem units skipped, `omatel-agent` and the shell running, and `systemctl reboot`
came back to BOOT.

## Chromium

The default browser. ALARM has no Chromium for armv7h, so the image runs Debian's
armhf build in a root of its own, `/var/lib/t715-chromium/root` (about 790 MiB),
through `bwrap` and without privileges. It brings its own libraries and Mesa, so
the system's stay as they are, and it has the user's real home directory: the
profile is `~/.config/chromium`, downloads go to the usual place.

| Piece | Owner | Role |
|---|---|---|
| `/usr/bin/chromium`, `chromium.desktop`, `t715-chromium-update`, its daily timer | pacman, `pkg/t715-chromium` | what starts and updates it. Named as Omarchy's scripts and window rules expect |
| `/var/lib/t715-chromium/root` | apt, inside that root | Debian's packages. Stage `chromium-root` of `rootfs/Dockerfile`, copied in at step 3b. pacman must not own it, or its updates would collide |

Updates: `sudo t715-chromium-update`, or the daily timer, which runs only on Wi-Fi
to spare the mobile data. apt checks Debian's signatures. Chromium may stay open:
the new version starts with its next launch. An update needs the persistent root:
in image mode the tool does nothing, since the RAM overlay would lose it.

Why not Firefox: on the same local tests (`docs/hardware/CPUFREQ.md`, top, and
`docs/hardware/MODEM.md` section 6.8), Chromium on the GPU gave 55 frames/s against
40 on a scrolling page, 21 against 1.9 on a page with effects, 0-4 % of clip frames
dropped against 34-45 %, at 11 % CPU busy against 41 %. Its JavaScript was slower,
about 1.7 times on one loop. On real YouTube the owner found it far smoother,
without a measurement. Firefox stays installed.

The sandbox is on: no `--no-sandbox`, renderers under seccomp in their own PID
namespaces. The GPU process runs without seccomp.

## Installing software

`sudo pacman -S <package>` works on the persistent root, with pacman's download
sandbox on: the kernel has Landlock since `kernel/patches/t715-modem` 0016. Before
that, nothing could be downloaded. In image mode it works too, and is lost at reboot.

Arch does not support partial upgrades, so a package that needs newer libraries
means updating first, with `omarchy update`. Omarchy's guard refuses a direct
`pacman -Syu`, and that stays: Omarchy's path runs here, in about two minutes. It
wants 10 GiB free, so it refuses in image mode.

| Piece | Why |
|---|---|
| `IgnorePkg = hypr* aquamarine xdg-desktop-portal-hyprland` in `pacman.conf` | `hyprgraphics` is patched here and Hyprland was tested with the dmabuf shim: an upgrade of that family waits for a new image. If a library then moves past them, pacman stops rather than breaking the session |
| Quickshell is **not** held | it follows Qt's private API, so it must move with Qt |
| `t715-update-without-kernel-package.patch` in `omamobile-omarchy`'s series | no reboot question after every update, since no package owns the kernel here, and no attempt at `yay`. A patch and not a script in `/usr/local/bin`: the session's PATH puts `/usr/share/omarchy/bin` first |
| `mkinitcpio` marked as explicitly installed | otherwise an orphan, and a question at every update |

The packages of this image's local repository (`t715-modem`, `t715-chromium`,
`omamobile-*`, `omarchy*`) are not in ALARM's repositories: updates do not touch them.
They come with `pacman -U` or a new image.

## Expected first boot on the tablet

1. The initramfs mounts the image read-only under a tmpfs overlay and
   starts systemd (`graphical.target`).
2. `usb-rndis.service` brings up the ECM gadget, `172.16.42.1/24` on
   `usb0`, and its own dnsmasq (DHCP `.2`–`.10`, no router, no DNS);
   `sshd` answers on `root@172.16.42.1` with the build key. The host keys
   are generated at each boot (RAM overlay), and differ from the Phosh
   image's: use `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null`.
3. NetworkManager (Wi-Fi through wpa_supplicant on brcmfmac, with the
   generated address, "Wi-Fi"), systemd-resolved, avahi, bluetoothd (`hci0`
   with the patch RAM and its generated address, "Bluetooth"), power-profiles-daemon
   (no cpufreq: placeholder profile) and systemd-oomd start; no unit waits
   for a network.
4. SDDM logs alarm in without a greeter (`Relogin=true`: it logs in again
   if the session ends) into `omarchy.desktop`: `uwsm start ... Hyprland`
   runs Hyprland as a user unit on `card0` at scale 2, which loads
   `~/.config/hypr/hyprland.lua`, Omarchy's defaults, and autostarts
   `omarchy-launch-shell` (Quickshell with `/usr/share/omarchy/shell`, which
   loads the touch shell's plugins from alarm's profile: bar, home, dock);
   `graphical-session.target` starts `t715-keys` and `t715-squeekboard`.
5. Every boot is Omarchy's first login (the overlay forgets everything):
   `omarchy-provision-first-run` enables the user units (`bt-agent` among
   them, then skipped by its condition), applies the GNOME theme settings
   and shows its notifications (keybindings, "Set up Wi-Fi": `nm-online`
   finds no network until one is joined; the check runs in the background
   and blocks nothing).
6. Nothing locks, blanks or suspends the screen by itself; Power turns it
   off and on (t715-keys).

Useful on the tablet (over SSH): `systemd-analyze`, `systemctl --failed`,
`journalctl -b -u sddm`, `journalctl -b _UID=1000`,
`/usr/lib/t715-omarchy/smoke-check`, and as alarm
`XDG_RUNTIME_DIR=/run/user/1000 hyprctl -i 0 monitors` (or `clients`,
`version`). Hyprland logs to `/run/user/1000/hypr/*/hyprland.log`, t715-keys
to alarm's journal (`journalctl --user -u t715-keys` as alarm).

## Known gaps

- Ghostty, Walker, mise, bun, LocalSend, Obsidian, OBS, .NET and Pinta are
  missing too; Neovim cannot be installed (ALARM's 0.9.1 lacks its
  `libtermkey` dependency), so `omarchy-nvim` is absent and `vim` is there.
- **Sound**: the speaker and the microphone work through the wm1814 UCM
  profile and PipeWire's PulseAudio server (2026-10-29); the headphone jack
  is not detected yet, and the codec logs "Mixer dropped sample" / "ASRC
  underclocked" now and then. Sensors (rotation) are not set up. Wi-Fi
  works in WPA2 (the firmware has no WPA3); Bluetooth works, Bluetooth audio
  is untried.
- **RAM overlay**: every change (settings, logs, the journal) is lost at
  reboot, and every boot repeats Omarchy's first-login steps. Memory
  written to the overlay comes out of the 3 GB of RAM.
- **Scale 2** is a starting point for the 8" 1536x2048 panel; the shell
  may want another value (`omarchy_monitor_scale` in
  `~/.config/hypr/monitors.lua`, `hyprctl keyword` at runtime).
- **Touch, partly**: the on-screen keyboard, the keys, the cover (P1) and
  the touch shell (P2) are in, not all tried on the device (the cover waits
  for its device tree node), and apps and some of Omarchy's own windows (terminals, TUI
  menus) still assume a keyboard. The OWL home-screen widgets are off.
- **Hyprland's debug overlay** (`debug:overlay`) deadlocks Hyprland on this
  device (`docs/journal/ONDEVICE-2026-10-28.md`): do not turn it on.
- **Static checks only** off the device: Hyprland cannot start in Docker
  (no DRM device), so the build only proves, under qemu, that Hyprland,
  Quickshell, uwsm and SDDM run and find all their libraries, that every
  QML module the Omarchy shell imports is installed, that Hyprland
  accepts alarm's Lua configuration (`Hyprland --verify-config`, required)
  and that the touch layer is in place (`t715-keys --check`, the keyboard's
  gsetting and environment, the patch series, the touch shell's QML
  modules and profile). Nothing about the GPU, the panel, touch input, the
  keys on real hardware or speed; the touch shell's start-up cost was
  measured on aarch64 only ("Touch layer P2").
- `pacman -Syu` on the tablet is refused by Omarchy's guard hook unless
  `OMARCHY_ALLOW_DIRECT_PACMAN=1` is set, and the local
  `[t715-omarchy]` repository is not in the image.

## Files

| Path | What |
|---|---|
| `image/tools/build-rootfs` | the builder |
| `image/tests/verify-rootfs.sh` | offline checks of the image |
| `image/tests/test_t715_keys.sh` | off-device test of t715-keys' gestures (fake input, stand-ins) |
| `image/rootfs/Dockerfile` | the armv7h tree |
| `image/rootfs/setup-pacman.sh`, `install-packages.sh`, `install-mobile.sh`, `install-wifi.sh`, `configure-system.sh`, `omarchy-system-setup.sh`, `omarchy-user-setup.sh`, `finalize.sh` | its steps |
| `image/rootfs/smoke-check.sh` | binaries-load check (`/usr/lib/t715-omarchy/smoke-check` in the image) |
| `image/rootfs/mkimage.sh` | export to ext4, in the helper container |
| `image/rootfs/packages.omarchy-skip`, `image/rootfs/packages.extra`, `image/rootfs/packages.mobile` | package lists (`packages.mobile`: touch layer P2, from `image/pkg/`) |
| `image/pkg/omamobile-shell/`, `image/pkg/omamobile-omarchy/` | the touch shell and Omarchy's patches, built by `image/tools/build-pkg` (`docs/image/PACKAGES.md`); the tablet's `shell.json` and `home.json` |
| `image/rootfs/overlay/` | files installed as is (the USB link files and the three Bluetooth and three Wi-Fi files are copies of the Phosh image's; the `Hyprland` wrapper; the touch layer's `t715-keys`, its unit, the squeekboard unit, the OSK environment, the fcitx5 drop-in, squeekboard's terminal layouts, the logind lid drop-in and the touch wording switch `30-t715-touch.conf`; the `bt-agent` drop-in) |
| `image/rootfs/t715-looknfeel.lua`, `image/rootfs/t715-tablet.lua` | the blocks appended to alarm's `looknfeel.lua` (performance) and `hyprland.lua` (touch layers P1 and P2) |
| `image/rootfs/shim/` | Hyprland's dmabuf-check shim (LD_PRELOAD) |
