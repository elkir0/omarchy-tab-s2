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

## hyprgraphics 0.5.1-4.1

- **Why:** Hyprland 0.56.2 froze on the tablet as soon as it drew text
  (`debug:overlay`; also the error bar, `hyprctl notify`, group bars), see
  `docs/journal/ONDEVICE-2026-10-28.md`, blocker 2. In hyprgraphics 0.5.1,
  `CAsyncResourceGatherer::await()` installs its condition variable after
  `enqueue()` has woken the gather thread, and that thread only flags
  `awaitingEvent` when a condition variable already exists: if it finishes
  the resource first, the wakeup is lost and the main thread waits forever.
  Upstream: [hyprwm/hyprgraphics#53](https://github.com/hyprwm/hyprgraphics/issues/53)
  (PR #52), not fixed in 0.5.1.
- **Package:** `image/pkg/hyprgraphics/`, Arch's 0.5.1-4 PKGBUILD (which ALARM
  builds unchanged) with `pkgrel=4.1`, `armv7h` in `arch=()`, and
  `hyprgraphics-0.5.1-fix-await-lost-wakeup.patch`: `awaitingEvent` is set
  and checked under `awaitingMtx`, `await()` returns at once when the
  resource is already done, and `needsToProcess`/`exit` are set under
  `requestMutex`. Only `src/resource/AsyncResourceGatherer.cpp` changes:
  same SONAME (`libhyprgraphics.so.4`) and ABI, so ALARM's Hyprland uses it
  without a rebuild.
- **Test:** `image/tests/test_hyprgraphics.sh` checks that pacman takes
  hyprgraphics 0.5.1-4.1 from `[t715-omarchy]`, including for
  `pacman -Sp hyprland`, installs it and runs the reproducer
  `image/tests/hyprgraphics-repro/repro.cpp` (Hyprland's `renderText` pattern:
  `enqueue()` then `await()` on the same thread, 20000 rounds, a watchdog
  reports a hang after 12 s) against the installed library, unpinned and
  pinned to one CPU. As a negative control it installs ALARM's stock
  0.5.1-4 and expects the pinned run to hang.

## omarchy-mobile at 5f7ba48: the touch shell (touch layer P2)

Both packages come from [omarchy-mobile](https://github.com/derekross/omarchy-mobile)
(MIT) at commit `5f7ba487cec6ca66ee04606be9d71d1aad855ea0`, the version
pinned for Omarchy 4.0.6 and Hyprland 0.56.2.

- **Source**: GitHub's tarball of that commit, checked by sha256
  (`3009362b…2029d`; the same file name in both PKGBUILDs, so it is
  downloaded once into the `t715-omarchy-pkg-src` volume); `prepare()`
  extracts only the package's own directory (`noextract`, then `bsdtar` of
  one path). Not vendored: the package directories hold hundreds of
  upstream files that would duplicate upstream here, while the tarball keeps
  the pin explicit and checked; our changes are files next to the PKGBUILD
  (a patch, two JSON profiles, the scriptlets), each with a real sha256.
  The tarball's two package directories were compared with a clone at
  5f7ba48: identical.
- **Version**: upstream's `version` file (checked in `prepare()`) and
  upstream's pkgrel 1 plus `.N`: `0.1.12-1.4`, `0.2.32-1.13`.
- **`arch = any`**, no compiled file (checked by `image/tools/build-pkg`).
- **Build order**: `omamobile-omarchy` first: `omamobile-shell` depends on
  it, and `image/tools/build-pkg` checks that every runtime depend resolves.
- **In the image**: `image/rootfs/packages.mobile`, installed by
  `image/rootfs/install-mobile.sh` from `[t715-omarchy]` only (`docs/image/ROOTFS.md`,
  "Touch layer P2").

### omamobile-omarchy 0.1.12-1.4

- **What**: omarchy-mobile's patches to Omarchy's own files (lock, idle,
  polkit, notifications, menu, image picker, screensaver) and
  `omamobile-omarchy-patches`, which applies them from Omarchy's pristine
  files (recognised by the mtree sha256s pacman keeps for the omarchy
  package, which the retagged package keeps too: `docs/image/REPACK.md`), checks
  that they reverse cleanly, swaps the files in and keeps them applied
  across Omarchy upgrades through its pacman hook. `status` and `verify`
  report on it; `restore` puts Omarchy's files back (`pre_remove`).
- **Dropped**: patches 0012 and 0016 (they hand `omarchy update`, the
  channel switch and the pacman refresh to `omamobile-update`, which assumes
  an `[omamobile]` repository), `omamobile-update` and its stand-ins
  (`lib/update-bin` in omarchy-mobile). Upstream's
  scriptlet is replaced by `omamobile-omarchy.install` (the same `lock-pam`
  and `restore` calls, without the notes about `omamobile-update`).
- **Ours**: `t715-update-without-kernel-package.patch` and
  `t715-pacman-keeps-alarm.patch`, which does 0016's job here: `omarchy-refresh-pacman`
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
  and the count of 17 patches. On the real package: the image build applies
  and verifies the series (19 applied with ours, none found upstream).

### omamobile-shell 0.2.32-1.13

- **What**: Omarchy shell plugins (QML) for a touch screen: `omamobile.bar`
  (replaces `omarchy.bar`), `.quicksettings`, `.launcher` (dock, drawer, home
  pill), `.switcher`, `.home`, `.keyboard`, `.back`; their helpers
  `omamobile-setup-user`, `-launch`, `-osk-watch`, `-bt-agent`,
  `-screenrecord`, `-widget`; `omamobile-setup-user.service` (masked in the
  image); the polkit rule that asks a wheel member for their own password.
- **Changed for the tablet**: `0001-tablet-quick-settings-tiles.patch`
  (`TilesModel.js`: no mobile data, hotspot, torch, location, NFC,
  fingerprint or rotation-lock tile; the tablet's default layout;
  `0013-tablet-location-tile.patch` puts location back),
  `0002-wifi-wpa2-without-sae.patch` (1.2: WPA2-PSK profiles for SAE
  networks, the radio has no SAE), `0003-tablet-drawer-opens-light.patch`
  (1.3: no icon rescan or keyboard when the drawer opens),
  `0004-tablet-quiet-pollers.patch` (1.4: the home toggles watch the
  notification service's settings file instead of a `qs ipc` call every
  30 s; the bar's modem and call watchers only with `cellWatch` /
  `callWatch`), `0005` to `0007` (mobile data, rotation, Réseau mobile),
  `0008-tablet-tiles-that-work.patch` (1.13: Airplane mode reaches the modem and holds across a reboot through
  NetworkManager, the radio states are read with `LC_ALL=C`, the Hotspot tile is back under "Add
  tiles" and shows its password, no Speaker on the call card),
  `0009-upstream-bottom-strip-keyboard-on-pill.patch` and
  `0010-upstream-app-names-in-recents.patch` (1.10: upstream's 0.2.40 to 0.2.43,
  the launcher, keyboard and switcher plugins only, taken from commit 1154721 rather
  than moving to 0.2.45, whose home changes bring a `bl_power` read every 2 s),
  `0011-tablet-set-pin.patch` (1.12: `omamobile-set-pin` ships, says tablet, and sudo
  asks for the password once one is chosen), `0012-tablet-back-gesture.patch` (1.14: the edge swipe
  goes through `t715-keys`, its Escape by name finds no key here), `tablet-shell.json` as `profile/shell.json` (the eight
  plugins, the watchers on, the drawer at 6 columns, Omarchy's idle values, and since 1.4
  Omarchy's 18 bar-widget-only plugins in `disabledPlugins`, so the shell
  stops compiling widgets no bar shows) and `tablet-home.json` as
  `profile/home.json` (a 6x8 home grid with the image's apps; a new file,
  seeded by the image build).
- **Dropped**: the fingerprint, update and permission-sheet plugins;
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

## t715-camera

`t715-photo`, a C program with no library but libm, and `t715-camera`, its front end for
the drawer entries Photo and Selfie: `docs/hardware/CAMERA.md`. It needs `t715-camera.ko` from
the daily kernel and the sensor tables in `/usr/lib/firmware/t715/`, which are not packaged:
they are Samsung's, and `research/parity/camera/t715-cam-seq.py` makes them from the owner's own
firmware. In `image/rootfs/packages.mobile`.

## t715-gps

Location, through GeoClue: `docs/hardware/GPS.md`. The package holds no Samsung file:
`t715-gps-prepare` copies `gpsd` and its libraries from the tablet's SYSTEM partition the first
time Location goes on, into `/var/lib/t715-gps/root`. Units: `t715-gps-nmea.socket`, started by
GeoClue connecting, `t715-gpsd.service`, with no network, no capability and its own user, and
`t715-gps-power.service` for the power line. A drop-in gives `geoclue.service` no network either.
`omamobile-gnss on|off|status|forget` is the switch, under the name the shell's tile calls;
`t715-position` is the drawer's Position; `t715-gps-capture` records one trip outside. Needs
`CONFIG_GPIO_SYSFS` (`kernel/patches/t715-gps`). In `image/rootfs/packages.mobile`.
