# Packages rebuilt from PKGBUILDs (`image/pkg/`)

Some packages must be built here instead of being taken from ALARM or
repacked from Omarchy: a fix ALARM does not carry, a package ALARM does not
build (compiled for `armv7h`), or a package no repository serves to armv7h
(`arch = any`, such as omarchy-mobile's). Each one is a directory `image/pkg/<name>/` with a `PKGBUILD` and
its local sources (patches). `image/tools/build-pkg <name>` builds it and adds it to
the local repository `image/out/repo/armv7h/` (`[t715-omarchy]`, `t715-omarchy.db`),
which the image build declares before `[core]`: a package there wins over
ALARM's, whatever their versions.

## Running it

```bash
image/tools/build-pkg hyprgraphics           # build if needed, publish, index
image/tools/build-pkg hyprgraphics --force   # rebuild and republish this version
image/tests/test_hyprgraphics.sh             # its off-device test
image/tools/build-pkg omamobile-omarchy      # before omamobile-shell, which depends on it
image/tools/build-pkg omamobile-shell
column -t -s $'\t' image/out/repo/armv7h/MANIFEST-built.tsv
```

`image/tools/build-pkg` runs everything in `t715-omarchy:dev-armv7h` (qemu on the
Mac, so a C++ library takes minutes, a large program hours):

1. `makepkg --printsrcinfo` / `--packagelist` tell which files the PKGBUILD
   produces (`arch=()` must contain `armv7h` or `any`).
2. If `MANIFEST-built.tsv` already records exactly these files, with the same
   sha256, and `t715-omarchy.db` lists them, it stops there: a rerun is a
   no-op (no build, nothing written).
3. Otherwise, in a fresh container: `[t715-omarchy]` is declared before
   `[core]` (a PKGBUILD may depend on our own packages), `pacman -Syu`, the
   `depends`/`makedepends`/`checkdepends` are installed by root, and
   `makepkg` runs as the unprivileged user `builder` (so `check()` runs when
   the PKGBUILD has one). For an `arch = any` package only `makedepends`
   and `checkdepends` are installed and `makepkg` runs with `--nodeps`: its
   runtime `depends` matter where it is installed, and installing them here
   would pull the whole desktop (omarchy) into the container, under qemu,
   at every build. Each runtime depend must still resolve (`pacman -Sp`)
   from ALARM and `[t715-omarchy]`, or the build stops. Fixed settings: `PKGEXT=.pkg.tar.zst`,
   `PACKAGER="SM-T715 omarchy build-pkg <noreply@localhost>"`,
   `MAKEFLAGS=-j$(nproc)`; the rest is ALARM's `/etc/makepkg.conf` (armv7h
   CFLAGS, `!debug`, `!lto`). Sources are downloaded inside the container
   into the Docker volume `t715-omarchy-pkg-src` (makepkg verifies their
   checksums on every build); the build tree stays in the container.
4. Each package file is checked in the container before it leaves: it holds
   `.PKGINFO` and `.MTREE`, the name, version and arch in `.PKGINFO` match
   the file name, every ELF file is 32-bit little-endian ARM, and an
   `arch = any` package holds no ELF file at all.
5. The files land in `image/cache/pkg/armv7h/` (build log:
   `image/cache/build-pkg/<name>/build.log`) and `image/out/repo/armv7h/`; `repo-add`
   (in the container) indexes them; files of an earlier version of the same
   `image/pkg/<name>` are removed. The macOS host only copies whole package files.

The packages are unsigned, like the retagged Omarchy ones; the repository is
consumed with `SigLevel = Optional TrustAll` (see `docs/image/REPACK.md`,
"Signature model").

### `MANIFEST-built.tsv`

One row per package file built from `image/pkg/`, next to `MANIFEST.tsv` (which
stays `image/tools/repack-omarchy`'s):

| column | content |
|---|---|
| `name` | the `image/pkg/<name>` directory |
| `pkgname`, `version`, `arch` | from the package's `.PKGINFO` |
| `filename`, `sha256` | the file in `image/out/repo/armv7h/` |
| `recipe_sha256` | hash of everything in `image/pkg/<name>/` at build time |
| `built_utc` | build time |

If `image/pkg/<name>/` changes while its version does not, a rerun says so
(`WARNING: image/pkg/<name> changed ...`) and builds nothing: bump `pkgrel`, or use
`--force`. `--force` republishes the same file name with new contents; a
machine that already downloaded the old file keeps it in its pacman cache
and then fails the checksum, so prefer a `pkgrel` bump once a package has
left this Mac.

## Living with `image/tools/repack-omarchy`

Both tools write into `image/out/repo/armv7h/`; each owns its own files.

- `image/tools/repack-omarchy` owns the packages of `image/tools/repack.list` and
  `MANIFEST.tsv`. Its stale-file cleanup keeps every file listed in
  `MANIFEST-built.tsv`, and its database check expects them, so a rerun
  (`--force` or not) never drops a built package. When it rebuilds
  `t715-omarchy.db` from scratch, it indexes every `*.pkg.tar.zst` there,
  ours included.
- `image/tools/build-pkg` only adds, replaces or removes the files its manifest
  records for that `image/pkg/<name>`, and updates the database with an
  incremental `repo-add`.
- A package name comes from one tool only: `image/tools/build-pkg` refuses a name
  that `MANIFEST.tsv` lists (remove it from `image/tools/repack.list` and rerun
  `image/tools/repack-omarchy` first), and `image/tools/repack-omarchy` refuses a name of
  `image/tools/repack.list` that `MANIFEST-built.tsv` lists.
- Run order does not matter: built first, the repack adds its packages and
  rebuilds the database with ours; repacked first, `repo-add` adds ours.

## Adding a package

1. Start from the distribution's recipe: Arch's packaging repository
   `https://gitlab.archlinux.org/archlinux/packaging/packages/<name>`, at the
   tag of the version ALARM ships (`pacman -Si <name>` in the dev image), or
   ALARM's own `archlinuxarm/PKGBUILDs` when it overrides it. Keep its
   `depends`, `makedepends` and `check()`.
2. Version: the distribution's `pkgrel` plus `.1` (`4` → `4.1`), like the
   retagged packages: ours sorts above the package it replaces.
3. `arch=()`: add `armv7h` (or keep `any`).
4. Patches go next to the PKGBUILD, in `source=()` with a real sha256
   (`shasum -a 256 <file>`), applied in `prepare()` with `patch -Np1`.
5. A comment at the top of the PKGBUILD says why the package is rebuilt and
   links the upstream issue and our notes.
6. `image/tools/build-pkg <name>`, then a test under `image/tests/`, and a section below.

Removing a package by hand: `repo-remove` it from `t715-omarchy.db.tar.gz`
in the dev container, delete its files from `image/out/repo/armv7h/`, its rows from
`MANIFEST-built.tsv`, and `image/pkg/<name>/`.

When ALARM ships a newer version of a package we rebuild, ours still wins
(`[t715-omarchy]` comes first), so check whether the new version carries the
fix, then rebase the PKGBUILD on it or drop ours.

## hyprgraphics 0.6.0-1.1

- **Why:** Hyprland 0.56.2 froze on the tablet as soon as it drew text
  (`debug:overlay`; also the error bar, `hyprctl notify`, group bars), see
  `docs/journal/ONDEVICE-2026-10-28.md`, blocker 2. In hyprgraphics (0.5.1
  through 0.6.0), `CAsyncResourceGatherer::await()` installs its condition
  variable after `enqueue()` has woken the gather thread, and that thread only
  flags `awaitingEvent` when a condition variable already exists: if it
  finishes the resource first, the wakeup is lost and the main thread waits
  forever. Upstream: [hyprwm/hyprgraphics#53](https://github.com/hyprwm/hyprgraphics/issues/53)
  (PR #52, still open), not fixed in 0.6.0: its `AsyncResourceGatherer.cpp`
  is unchanged from 0.5.1.
- **Package:** `image/pkg/hyprgraphics/`, Arch's 0.6.0-1 PKGBUILD (which ALARM
  builds unchanged) with `pkgrel=1.1`, `armv7h` in `arch=()`, and
  `hyprgraphics-0.6.0-fix-await-lost-wakeup.patch`, the 0.5.1 patch with the
  same hunks: `awaitingEvent` is set and checked under `awaitingMtx`,
  `await()` returns at once when the resource is already done, and
  `needsToProcess`/`exit` are set under `requestMutex`. Only
  `src/resource/AsyncResourceGatherer.cpp` changes. The SONAME moved with the
  version to `libhyprgraphics.so.5`, which ALARM's Hyprland 0.57.0-3 requires
  (the 0.5.1 rebuild made the image's dependency gate fail from 2026-11-02).
- **Test:** `image/tests/test_hyprgraphics.sh` checks that pacman takes
  hyprgraphics 0.6.0-1.1 from `[t715-omarchy]`, including for
  `pacman -Sp hyprland`, installs it and runs the reproducer
  `image/tests/hyprgraphics-repro/repro.cpp` (Hyprland's `renderText` pattern:
  `enqueue()` then `await()` on the same thread, 20000 rounds, a watchdog
  reports a hang after 12 s) against the installed library, unpinned and
  pinned to one CPU. As a negative control it installs ALARM's stock
  0.6.0-1 and expects the pinned run to hang: it did on 2026-11-03.

## omarchy-mobile: the touch shell (touch layer P2)

Both packages come from [omarchy-mobile](https://github.com/derekross/omarchy-mobile)
(MIT): `omamobile-shell` at commit `87b839567ad77911e948a4549f84198549191a36`
(0.2.94, since 2026-11-03; before, `5f7ba48`, 0.2.32), for Omarchy 4.0.6 and
Hyprland 0.57.0, and `omamobile-omarchy` at
`3624ef3237b71abbe5c232f635208f564869f441` (2026-11-01), whose series still
targets Omarchy 4.0.6.

- **Source**: GitHub's tarball of each commit, checked by sha256
  (`e9b0f052…e1a73` for 87b8395, `254ba88e…75c60` for 3624ef3; kept in the
  `t715-omarchy-pkg-src` volume); `prepare()`
  extracts only the package's own directory (`noextract`, then `bsdtar` of
  one path). Not vendored: the package directories hold hundreds of
  upstream files that would duplicate upstream here, while the tarball keeps
  the pin explicit and checked; our changes are files next to the PKGBUILD
  (a patch, two JSON profiles, the scriptlets), each with a real sha256.
  The tarball's two package directories were compared with a clone at
  5f7ba48: identical.
- **Version**: upstream's `version` file (checked in `prepare()`) and
  upstream's pkgrel 1 plus `.N`: `0.1.27-1.2`; the shell is `0.2.94-2`.
- **`arch = any`**, no compiled file (checked by `image/tools/build-pkg`).
- **Build order**: `omamobile-omarchy` first: `omamobile-shell` depends on
  it, and `image/tools/build-pkg` checks that every runtime depend resolves.
- **In the image**: `image/rootfs/packages.mobile`, installed by
  `image/rootfs/install-mobile.sh` from `[t715-omarchy]` only (`docs/image/ROOTFS.md`,
  "Touch layer P2").

### omamobile-omarchy 0.1.27-1.2

- **What**: omarchy-mobile's patches to Omarchy's own files (lock, idle,
  polkit, notifications, menu, image picker, screensaver, app icons) and
  `omamobile-omarchy-patches`, which applies them from Omarchy's pristine
  files (recognised by the mtree sha256s pacman keeps for the omarchy
  package, which the retagged package keeps too: `docs/image/REPACK.md`), checks
  that they reverse cleanly, swaps the files in and keeps them applied
  across Omarchy upgrades through its pacman hook. `status` and `verify`
  report on it; `restore` puts Omarchy's files back (`pre_remove`).
- **Dropped**: patches 0012 and 0016 (they hand `omarchy update`, the
  channel switch and the pacman refresh to `omamobile-update`, which assumes
  an `[omamobile]` repository), `omamobile-update` and its stand-ins
  (`lib/update-bin` in omarchy-mobile); `lib/modules-cleanup` and `systemd/`
  (0.1.21: a Pixel's next kernel arrives as a module tree that a cleanup must
  spare; here the modules are the initramfs's, no push or package owns a tree,
  and the image has no `kernel-modules-hook`). Upstream's
  scriptlet is replaced by `omamobile-omarchy.install` (the same `lock-pam`
  and `restore` calls, without the notes about `omamobile-update`).
- **New since 0.1.12, all taken**: the lock's glance view (0023), the battery
  (0026, from the kernel's supplies: `sm5703-fuelgauge` and the Mains
  `sm5703-charger`) and media controls (0027, Quickshell's Mpris) on the lock;
  fingerprint only when a finger is enrolled (0022: no fprintd here, so
  never); the display off before a suspend (0021: suspend is masked here); the
  largest app icon (0024); no launch toast for shell surfaces (0025). The
  glance's weather is the shell's `~/.local/state/omamobile/weather.json`,
  which `omamobile-shell` 0.2.32 does not write, so none shows; the lock never
  asks the network. Upstream's devices run Quickshell 0.3.2, as this image.
- **Ours**: `t715-update-without-kernel-package.patch`,
  `t715-pacman-keeps-alarm.patch` and, since 1.2,
  `t715-lock-blank-through-keys.patch`: the lock's own blank, 5 s after a wake,
  went at the panel alone, so `t715-keys` never heard of it and the touchscreen
  and `t715-rotate`'s accelerometer stayed on under the dark panel (−67 mW
  measured once released); the blank now signals `t715-keys`, with Omarchy's as
  the fallback.
  `t715-pacman-keeps-alarm.patch` does 0016's job here: `omarchy-refresh-pacman`
  and `omarchy-channel-set` refuse when `/etc/pacman.conf` has `[alarm]`. They would
  copy Omarchy's x86_64 configuration over ALARM's, losing the armv7h repositories and
  `IgnorePkg`.
- **Kept although the first analysis listed it as for an older Omarchy**:
  `bridge-4.0.4-menu-first-frame.patch`. Its header targets 4.0.6 (whose
  menu is still a plain PanelWindow) and upstream's test applies it to the
  real 4.0.6 package after 0018: the menu card no longer flashes for a
  frame. Patch 0020 (touch wording of notifications) detects a phone by
  `/usr/bin/omamobile-update`; the image switches it on with
  `OMARCHY_NOTIFICATION_PHRASING=touch` instead.
- **Depends**: `omarchy>=4.0.6`, `bash`, `python`, `patch`, `libarchive`,
  `util-linux` (upstream's `sudo`, `pacman-contrib`, `fakeroot`, `gzip` and
  `systemd` served `omamobile-update`).
- **`check()`**: syntax of the scripts, the hook's command, upstream's
  applier tests against synthetic Omarchy trees (`test/patches.py`; its
  real-package part expects 0012 and 0016 and is skipped), `test/lock-pam.sh`,
  and the count of 24 patches. On the real package: the image build applies
  and verifies the series. On 2026-11-02 the applier ran on the tablet with
  `--root` on a scratch copy of the omarchy 4.0.6-1.1 package: 26 applied with
  ours, none found upstream, and the 19 patched QML and JS files parse
  (`qmlformat`).

### omamobile-shell 0.2.94-2

Moved from 0.2.32-1.15 on 2026-11-03 (the owner's yes); 0.2.94-2 (2026-11-05)
adds the Modem tile, 0.2.94-5 (2026-11-08) the SD card tile. What the tablet
gains from upstream: the drawer swiped up from anywhere and following the
finger, with no keyboard and no icon rescan; the home pill in a 44 px bottom
bar that apps no longer draw under; recents named by app; a media card in the
shade; home widgets that idle while nobody sees them; signal bars on the
mobile data tile. Upstream's `bl_power` read every 2 s now comes with it: it
is what lets the widgets idle while the panel is off.

- **What**: Omarchy shell plugins (QML) for a touch screen: `omamobile.bar`
  (replaces `omarchy.bar`), `.quicksettings`, `.launcher` (dock, drawer, home
  pill), `.switcher`, `.home`, `.keyboard`, `.back`; their helpers
  `omamobile-setup-user`, `-launch`, `-osk-watch`, `-bt-agent`,
  `-screenrecord`, `-widget`; `omamobile-setup-user.service` (masked in the
  image); the polkit rule that asks a wheel member for their own password.
- **Changed for the tablet**, twelve patches against 87b8395:
  `0001-tablet-quick-settings-tiles.patch`
  (`TilesModel.js`: no mobile data, hotspot, torch, location, NFC,
  fingerprint or rotation-lock tile; the tablet's default layout;
  `0010-tablet-location-tile.patch` puts location back),
  `0002-wifi-wpa2-without-sae.patch` (WPA2-PSK profiles for SAE
  networks, the radio has no SAE),
  `0003-tablet-quiet-pollers.patch` (the home toggles watch the
  notification service's settings file instead of a `qs ipc` call every
  30 s; the bar's modem and call watchers only with `cellWatch` /
  `callWatch`), `0004` to `0006` (mobile data on shannond's facade, rotation,
  Réseau mobile),
  `0007-tablet-tiles-that-work.patch` (Airplane mode reaches the modem and holds across a reboot through
  NetworkManager, the radio states are read with `LC_ALL=C`, the Hotspot tile is back under "Add
  tiles" and shows its password, no Speaker on the call card),
  `0008-tablet-set-pin.patch` (`omamobile-set-pin` ships, says tablet, and sudo
  asks for the password once one is chosen), `0009-tablet-back-gesture.patch` (the edge swipe
  goes through `t715-keys`, its Escape by name finds no key here),
  `0011-tablet-modem-tile.patch` (the Modem tile over `t715-modem-power`, from
  `t715-modem`: the CP off now and at boot, a long press for Réseau mobile and its
  standby setting; "Modem off" on the Mobile data tile meanwhile),
  `0012-tablet-sdcard-tile.patch` (the SD card tile over `t715-sdcard`: on
  while the card is mounted, a tap mounts or ejects, a long press opens the
  card in Files, dimmed without the command or the slot). Upstream
  now has what 0.2.32's 0003 (the light drawer), 0009 and 0010 (the bottom
  strip, app names in recents) did, so they are gone. `tablet-shell.json` as `profile/shell.json` (the eight
  plugins, the watchers on, the drawer at 6 columns, Omarchy's idle timers at 0,
  since t715-idle owns the screen-off and the stay-awake state is the Stay
  awake tile's; and since 1.4
  Omarchy's 18 bar-widget-only plugins in `disabledPlugins`, so the shell
  stops compiling widgets no bar shows) and `tablet-home.json` as
  `profile/home.json` (a 6x8 home grid with the image's apps; a new file,
  seeded by the image build).
- **Dropped**: the fingerprint, update, permission-sheet and (since 0.2.94)
  voice plugins, the voice, weather, keyboard-language, keyboard-theme and
  screenshot-viewer helpers;
  `omamobile-fp-enroll`, `-nfc-open` and its
  unit, `-keys` (`t715-keys` handles the keys), `-sleepd` and its unit,
  `-onboarding`, `-portal-access` and `portal/`,
  `-open-intent`; `hypr/phone.lua`; the pieces touch layer P1 already
  provides (input-method environment file, fcitx5 drop-in, squeekboard's
  terminal layout) and `omamobile-osk-guard` with its unit; the
  xdg-desktop-portal-gnome drop-in; the "AI Agent" desktop entry. Upstream
  installs with its own `./install`; this `package()` installs the kept
  files the same way, by name.
- **Depends** (trimmed; all in ALARM armv7h or `[t715-omarchy]`):
  `omarchy`, `omamobile-omarchy>=0.1.11`, `bash`, `python`, `python-dbus`,
  `python-gobject`, `qt6-declarative`, `squeekboard`, `jq`, `inotify-tools`,
  `bluez`, `bluez-utils`, `networkmanager`, `brightnessctl`, `curl`,
  `pipewire`, `wireplumber`. Left out: `omamobile-apps` (needs `neard`, not
  in ALARM armv7h), `omamobile-owl-widgets` (the OWL built-in widgets:
  optional, heavy, off), `xdg-desktop-portal-gnome`, `foot` and
  `xdg-terminal-exec` (the agent shortcut), `iproute2` (`omamobile-sleepd`);
  `khal` and `playerctl` are optional. `wf-recorder`, for the Screen record tile,
  comes from `packages.extra`, with the calculator and the clocks of `omamobile-apps`.
- **`check()`**: the helpers parse (python3, bash), the plugin manifests
  and the tablet profile (only shipped plugins, 6 columns, a 6x8 home;
  `disabledPlugins` only bar-widget-only ids, never `omarchy.menu`,
  `.media` or a service), no phone tile left, and the changes of 0002 to
  0004 in place. Upstream's `test/all` is not run: it checks the phone's
  files and plugins. Its relevant tests were run on the built package in an
  aarch64 container instead (`docs/image/ROOTFS.md`, "Touch layer P2").

## t715-chromium

The launcher, `chromium.desktop` and the update tool with its timer, for Debian's
Chromium in `/var/lib/t715-chromium/root` (`docs/image/ROOTFS.md`, section
"Chromium"). The root is not in the package: `rootfs/Dockerfile` builds it in the
stage `chromium-root` and copies it in. That stage runs apt under qemu, about an
hour the first time; Docker's cache then keeps that Chromium until `--no-cache`.
It does not matter for a running tablet, which updates itself. `finalize.sh`
records the version in the manifest.

A persistent root seeded before this package needs it once: `pacman -U`, then the
root copied from the image file, read-only, with `cp -a`, then
`/usr/lib/t715-chromium/prepare-root`, `xdg-settings set default-web-browser
chromium.desktop` as the user, and `chromium` added to `~/.config/omamobile/home.json`.

## t715-modem, omatel-agent, omaphone, omamessages

- **t715-modem** packages this repository's `modem/` (`docs/hardware/MODEM.md`).
  Its source is an archive made by `image/tools/stage-t715-modem` (git-ignored),
  because `build-pkg` only sees `pkg/<name>/`: build the loader
  (`make -C modem/loader docker-cross`), stage, then `build-pkg t715-modem`.
- **omatel-agent, omaphone, omamessages**: upstream PKGBUILDs of omarchy-mobile with
  `armv7h` added. They are Rust (GTK4 and libadwaita for the two apps), so `build-pkg`
  takes a long time under qemu. `omatel-agent` first: both apps depend on it, and
  `omamobile-shell` too. `omatel-agent` 0.2.4-1.1 and `omaphone` 0.2.2-1.1 follow
  upstream's commit `9332a78`; `omamessages` stays at 0.2.1 from `5f7ba48`.
  `omatel-agent` carries `0001-t715-message-alert.patch`: a new message plays
  feedbackd's `message-new-sms` and asks `t715-keys` for a glance at the screen, under
  the same rules as its notification, plus Do Not Disturb. `omaphone` carries
  `0001-t715-no-speaker-button.patch`: the tablet has no earpiece.

## The cameras: libcamera, omacam, t715-camera

The tablet's cameras have no ISP: the `t715-camera` kernel driver captures raw
Bayer through CSIS and FIMC-LITE straight to memory, and three packages turn that
into pictures (`docs/hardware/CAMERA.md` for the hardware):

| Package | Role |
|---|---|
| `libcamera` 0.7.2-4.2 (with `libcamera-ipa`, `libcamera-tools`, `gst-plugin-libcamera`, `python-libcamera`) | libcamera with the software ISP that knows this tablet's receiver and its two sensors |
| `omacam` 0.3.3-2 | omarchy-mobile's **Camera** app: preview, tap to focus, photos and video, lens switching by zoom |
| `t715-camera` 0.2.3-2 | the sensors' mode tables, made at the first boot from the tablet's own firmware; the system-wide camera settings; the drawer's Photo and Selfie: one shot at a time, raw Bayer developed in software |

### libcamera 0.7.2-4.2

Arch's `0.7.2-4` (which ALARM builds unchanged for armv7h) rebuilt on
[omarchy-mobile](https://github.com/derekross/omarchy-mobile)'s software-ISP patch
series plus three patches of our own; `pkgrel=4.2` sorts above ALARM's `0.7.2-4` in
`[t715-omarchy]`, which the image declares before `[core]` (`image/pkg/libcamera/`,
its `README.md` for the whole series).

- **0001-0056, unchanged from omarchy-mobile** at commit
  `0f43776a2662272cf8569559fc91ec356dfa97dd` (2026-11-03, MIT): written for a Pixel
  7 Pro's `gs201-csis` receiver, they give the software ISP, on GLES 2/3 through
  EGL, contrast autofocus with a lens, lens shading, denoise, sharpening and
  defective-pixel correction, a better AGC/AWB, and manual controls.
- **0057** adds this tablet's receiver to the simple pipeline handler's
  `supportedDevices` table (`{ "t715-camera", {}, true }`) — stock libcamera ignores
  it, because the handler matches only a fixed table of media-device driver names.
  Ours: the driver is this repository's own, so the patch will not be sent upstream.
- **0058** adds the two sensors, the rear Samsung S5K4H5 and the front S5K6B2, as
  omarchy-mobile adds its Samsung ones: sensor helpers (black level 64 at 10 bits,
  linear gain `AnalogueGainLinear{ 1, 0, 0, 32 }` — both measured on the tablet and
  declared by the sensors' SMIA limit registers) and sensor properties.
- **0059** their tuning files (`s5k4h5.yaml`, `s5k6b2.yaml`): a contrast 1.2 default
  and omarchy-mobile's `Detail` values. No colour matrix and no saturation default:
  the tablet runs the software ISP on the CPU, where a matrix, even the identity,
  sends the debayer down its per-pixel path (60 frames at 1640x1228: 5.0 s of CPU
  with one, 3.1 s without). The rear's `Af` scans only the DW9807 focus motor's
  useful travel, `range: [ 400, 700 ]` of its 0-1023; the front is fixed focus.
- **Differences from omarchy-mobile's aarch64 build**: `arch=(armv7h)`, `pkgrel=4.2`
  (theirs is aarch64, 4.22); no `libpisp` anywhere (the trimmed build builds no rpi
  pipeline that links it); `sdl2` resolved through `sdl2-compat`'s `Provides: sdl2`;
  same trimmed build otherwise — pipelines `simple,uvcvideo`, IPA `simple`,
  `softisp-gpu=enabled`, no docs, no tests, `werror=false`, plus Arch's own
  `libcamera-fix-python3.14-macro-redefinition.patch`.
- An hour or two under qemu; rebase 0057-0059 on each new ALARM libcamera release,
  and drop omarchy-mobile's patches they have absorbed.

### omacam 0.3.3-2

[omacam](https://github.com/derekross/omacam) 0.3.3, Omarchy Mobile's camera app,
shown as **Camera** (Rust, GTK 4 and libadwaita, on libcamera directly through
libcamera-rs): a full-screen viewfinder, tap to focus, full-resolution photos,
video with sound, lens switching by zoom. Upstream's PKGBUILD kept as is
(`image/pkg/omacam/`, its `README.md`), with:

- **`arch=(armv7h)`** instead of `aarch64`: everything it needs builds for it in
  ALARM (rust, gtk4, libadwaita, clang, libcamera 0.7.2). The sources carry no
  32-bit assumption: casts only widen, no `AtomicU64`, no pointer-width `repr`,
  and libcamera-rs's C API is `size_t`-based with `static_assert` layout checks.
- **One patch, `0001-tablet-lens-table.patch`** (pkgrel 2), which teaches omacam
  three things this tablet needs: a system-wide lens table read from
  `/etc/omacam/lenses.toml` (after `--lens-table` and the user's own
  `~/.config/omacam/lenses.toml`, before the built-in Pixel 7 Pro table), an
  optional per-lens `preview_fps` that caps the preview's frame rate, and an
  optional table-level `merge_threads` that caps the Night/HDR burst merge's
  thread pool. The tablet debayers on the CPU: at the default 30 fps a preview
  took 3.4 cores and 83 °C in a minute and a half, and a 7-thread merge took it
  from 62 to 82 °C in 17 s. `t715-camera`'s lens table sets `preview_fps = 15` and
  `merge_threads = 2`; without the keys the behaviour is exactly upstream's. The
  two keys need the patched omacam, so `t715-camera` carries
  `conflicts=('omacam<0.3.3-2')`: an older omacam would reject the table.
- Hours under qemu (171 crates, gtk4-rs included; the whole dependency
  closure); `check()` runs `omacam-core`'s tests, the camera logic, under qemu
  too. The version constraint (`libcamera>=0.7`, `<0.8`) is satisfied by ALARM's
  official 0.7.2-4; this repository's own libcamera, once built into
  `[t715-omarchy]`, takes precedence for it too.

### t715-camera 0.2.3-2

`t715-photo`, a C program with no library but libm, and `t715-camera`, its front end
for the drawer entries Photo and Selfie: `docs/hardware/CAMERA.md`. It needs
`t715-camera.ko` from the daily kernel and the sensor tables in
`/usr/lib/firmware/t715/`, which are not packaged: they are Samsung's.

Since 0.2.3-2 the tablet makes them itself. `t715-camera-tables.service` runs at boot while
`s5k4h5-m0.seq` or `s5k6b2-m0.seq` is missing (the install hook enables it):
`t715-camera-tables` mounts the SYSTEM partition read-only without replaying its journal,
reads `vendor/firmware/fimc_is_fw2_4h5.bin`, accepts it only if its sha256 is firmware
`T715XXU2CRH1`'s, writes the rear modes 0-3, 6 and 7 and the front mode 0, then binds the
sensors so that the cameras appear without a reboot. The script holds offsets only: where the
rear S5K4H5's mode array sits in that file, and the instructions whose immediates are the
front S5K6B2's register writes (`research/parity/camera/ex6b2b.py` found them). It never
rewrites an existing table; `--force` does, and `--fw FILE --out DIR` works on a copy.
On the reference tablet's firmware it reproduces the seven tables in use there, byte for byte.
Since the media-controller kernel it also carries the system-wide camera
configuration: `/etc/libcamera/configuration.yaml` puts libcamera's software ISP on
the CPU for every application (measured on the front camera when the
Mali-T760 ran at a fixed 266 MHz, before the GPU's frequency scaling of
1.0.1: the GPU path gave 3 to 6 frames per second, the CPU path 30;
`LIBCAMERA_SOFTISP_MODE=gpu` overrides it), the udev rule `71-t715-dma-heap.rules`
opens the dma-buf heaps the software ISP allocates from to the video group, and
`/etc/omacam/lenses.toml` is omacam's lens table for this tablet: the rear's 2x2
binned preview, the sensors' rotations (measured, until the device tree carries
them), `preview_fps = 15` and `merge_threads = 2`. In
`image/rootfs/packages.mobile`.

## t715-gps

Location, through GeoClue: `docs/hardware/GPS.md`. The package holds no Samsung file:
`t715-gps-prepare` copies `gpsd` and its libraries from the tablet's SYSTEM partition the first
time Location goes on, into `/var/lib/t715-gps/root`. Units: `t715-gps-nmea.socket`, started by
GeoClue connecting, `t715-gpsd.service`, with no network, no capability and its own user, and
`t715-gps-power.service` for the power line. A drop-in gives `geoclue.service` no network either.
`omamobile-gnss on|off|status|forget` is the switch, under the name the shell's tile calls;
`t715-position` is the drawer's Position; `t715-gps-capture` records one trip outside. Needs
`CONFIG_GPIO_SYSFS` (`kernel/patches/t715-gps`). In `image/rootfs/packages.mobile`.

## pi-coding-agent 1.5.0

**Pi, the terminal coding agent, preinstalled** — the image's other coding agent
beside the Claude Code installer. Upstream is
[earendil-works/pi](https://github.com/earendil-works/pi) (`@earendil-works/pi-coding-agent`
on npm, MIT): the package holds a **pinned npm tree**, because upstream publishes no armv7
build and its own installer would download x64/arm64 binaries. The npm packages it installs
are JavaScript and WebAssembly only, so `npm ci` from the release's own lockfile
(`pi-coding-agent-install-package{,-lock}.json`, what pi.dev's installer uses) gives a tree
that runs on 32-bit ARM under Node 22.

- **The lockfile's eight gaps**: upstream's lockfile ships without integrity for the eight
  first-party `@earendil-works/*` packages (it is written by pi.dev's installer, which knows
  them differently); `prepare()` writes those integrities in, each from
  `npm view @earendil-works/<name>@1.5.0 dist.integrity`, with jq keeping the rest
  byte-for-byte what npm wrote — `npm ci` refuses a lockfile whose entries lack integrity.
- **Two things do not run on armv7, both removed**: pi-tui's prebuilt clipboard helpers
  (`.node` files for x64/arm64 Linux, macOS and Windows — deleted; Pi falls back to
  `wl-paste`/`wl-copy`, the optional `wl-clipboard` package) and Pi's fd/ripgrep downloader
  (x64/arm64 releases only — `fd` and `ripgrep` are runtime depends instead).
- **What is installed**: the whole tree under `/opt/pi` (Pi resolves its first-party
  packages from `node_modules`, and extensions under `~/.pi` expect that layout;
  `cp -a` keeps npm's modes and the eight relative `.bin` symlinks), the wrapper
  `/usr/bin/pi` and the drawer entry `pi.desktop` (a terminal app, "Pi"). `arch = any`,
  `options=(!strip)`: no ELF file to strip, and makepkg's strip pass would `file(1)`-probe
  every one of the ~9000 files under qemu for nothing (`build-pkg` still checks the
  package holds no ELF).
- **The wrapper** turns telemetry off (`PI_TELEMETRY=0`) and update checks off
  (`PI_SKIP_VERSION_CHECK=1`), and points `pi update` at pacman
  (`PI_SELF_UPDATE_COMMAND=sudo pacman -Syu pi-coding-agent`); each can be overridden by
  the user (`PI_TELEMETRY=1 pi`, ...).
- **`check()`** runs the real entry point in the container with those same variables plus
  `PI_OFFLINE=1`, expects `pi --version` to print `1.5.0`, and fails if any `.node` file
  survived.
- **No credential, ever**: the owner signs in on the tablet (`/login`, or a provider API
  key), and Pi keeps it in `~/.pi/agent/auth.json`. A Claude Pro or Max subscription must
  not be used in Pi: Anthropic's terms forbid its credentials in third-party apps.
- **Depends**: `nodejs-lts-jod` (Node 22, ≥ 22.19: Pi's engine requirement), `fd`,
  `ripgrep`. Optional: `wl-clipboard`, `npm` (`pi install`/`pi update` for extension
  packages), `git` (git-backed extensions and repository tooling). In
  `image/rootfs/packages.mobile`.

## t715-claude-code

An **installer** for Claude Code, not the program: Anthropic publishes it as a Bun-compiled
binary for x64/arm64 only, and its licence forbids redistributing it, so the image cannot
carry it. The package holds Yumi Lab's MIT-licensed
[`claude-code-smartpi`](https://github.com/Yumi-Lab/claude-code-smartpi) (the armv7
installer: download the official binary, extract its JavaScript, rebundle it under Node 22),
pinned at commit `a9cac19982b922745c1ba33a4a3fe9ea2a94719b` and patched
(`0001-arch-linux-arm-sm-t715.patch`) for this tablet: no apt — the dependencies come from
pacman beforehand (`rg`, `xz`, `npm`; Node 22 is `nodejs-lts-jod`); the downloaded binary is
checked against the sha256 of Anthropic's `manifest.json` for that version; the launcher
`taskset`s all eight cores instead of a pad's four.

Since 0.1.0-2 the install starts from the app drawer: **"Claude Code installer"**
(`t715-claude-code.desktop`, a terminal entry like `t715-position`, the generic
utilities-terminal icon, no Anthropic branding) opens `t715-claude-guide`, which explains
what installing means (an unofficial build for 32-bit ARM, about 250 MB downloaded from
Anthropic, capped at `MAX_VERSION`, the owner's own sign-in), asks a y/N question whose
default is No, then runs `sudo t715-claude-install` itself and shows the sign-in steps. It
runs as the desktop user; the one root command goes through sudo with its own password
prompt.

- **What is installed**: `/usr/share/t715-claude-code/installer/` (the patched upstream
  tree, minus `bench/`) and `/usr/bin/t715-claude-install`, the wrapper the owner runs as
  root (`sudo t715-claude-install [VERSION]`, `docs/DEPLOY.md` 11.10). Nothing else: the
  package owns no file under `/opt`, `/usr/local` or `/home`, holds no ELF, and `arch = any`.
- **The manifest signature check** (0.1.0-2, fail closed): since 2.1.89 every Anthropic
  release publishes `manifest.json.sig` next to `manifest.json`, made with the release key
  `31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE`
  (`https://downloads.claude.ai/keys/claude-code.asc`, documented at
  code.claude.com/docs/en/setup). The package ships that key (`anth-release-key.gpg`,
  dearmored) and `lib/manifest-verify.sh`: a throwaway keyring holding only the shipped key,
  `gpg --verify` of the detached signature, then the imported key's **primary fingerprint**
  (gpg's `VALIDSIG` line) compared to the pinned constant — never read from the
  environment. The patched installer calls it before any use of the manifest, the sha256
  comparison included, and aborts on a missing `.sig`, a bad signature or a different key.
  `test-manifest-signature.sh` in the package directory exercises it with throwaway keys:
  a good signature passes; a tampered manifest, a foreign key, a missing signature and an
  environment substitution are all refused.
- **The npm tools are pinned** (0.1.0-2): the rebundle step (esbuild and the runtime deps
  ws, undici, js-yaml it gathers) installs from `npm-tools-package-lock.json` — every
  tarball URL and sha512 integrity frozen — with `npm ci --ignore-scripts` into a directory
  of the install run, never globally. esbuild's armv7 binary package (`@esbuild/linux-arm`)
  is part of the same lockfile, installed by name (`--force`: npm sees a darwin/arm64
  builder under qemu), and the bundle step points esbuild at it with `ESBUILD_BINARY_PATH`.
  Claude Code's self-update is off (`DISABLE_AUTOUPDATER`, `DISABLE_UPDATES`).
- **The wrapper**: root-only, runs the installer with `HOME` set to the target user's home
  (`$SUDO_USER`, `alarm` without sudo — never root), from a `mktemp -d` under `/var/tmp`
  removed on exit, then gives that user `~/.claude` and `settings.json` (600). The version
  defaults to the installer's `MAX_VERSION` (2.1.270: from 2.1.271 the full-screen interface
  stays blank under Node, its renderer needing a native cell engine only Anthropic's Bun
  has); anything above is refused without `--force`, compared as dotted numbers (no
  `sort -V`). It never reads, prints or copies `~/.claude/.oauth_token` or a token value.
- **Sign-in is the owner's**, on the tablet, after the install: `claude setup-token`, then
  `claude-token-save` (one of the installer's `bin/` helpers, installed to
  `/usr/local/bin` at first run). No token in the package, the image or this repository;
  `image/tests/verify-rootfs.sh` checks the image for one.
- **Depends**: `bash`, `nodejs-lts-jod` (Node 22, the engine Claude Code's guard allows),
  `npm` (esbuild, ws, undici, js-yaml for the bundle), `gnupg` (`gpg`: the manifest
  signature check), `ripgrep`, `xz`, `python` (the JavaScript extractor and the manifest
  check), `curl`, `util-linux` (`taskset`), `coreutils`, `gcc-libs` (`libatomic.so.1` for
  Node), `tar`, `diffutils`, `findutils`, `grep`. In `image/rootfs/packages.mobile`.
