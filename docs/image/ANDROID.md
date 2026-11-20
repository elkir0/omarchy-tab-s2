# Android apps (Waydroid) — SM-T715

Status: working on the reference tablet on 2026-11-20; **not in a release yet**.
The root image ships Waydroid and the tools below but not Android itself: the
Android images are downloaded when the owner asks for them (section 3).

## 1. What you get and its limits

Waydroid 1.6.3 (Arch Linux ARM `[extra]`, `armv7h`) runs LineageOS 20
(Android 13) inside an LXC container beside Linux apps, using the official
`waydroid_arm` images: system `VANILLA` (2026-09-27) and vendor `MAINLINE`
(2026-10-22), about 760 MB to download and 1.6 GB unpacked.

Android renders on the GPU through Panfrost, not llvmpipe:
`GLES: Mesa, Mali-T760 MC6 (Panfrost), OpenGL ES 3.1 Mesa 26.0.8` (the vendor
image's own Mesa, separate from the host's).

The tablet's CPU runs in AArch32, so only `armeabi-v7a` apps or apps without
native code install. 64-bit-only Android builds such as Denial/Droidloom
(Android 17) cannot run on this tablet.

## 2. Requirements

- **Optional kernel series `kernel/patches/t715-waydroid/`**: one defconfig
  patch on top of the 1.0.4 release tree (built as `#19` on the reference
  tablet; see [kernel/README.md](../../kernel/README.md)). The series is
  optional — systems without Android stay on the standard 1.0.4 kernel.
  It enables:
  - `ANDROID_BINDER_IPC` with static devices `binder,hwbinder,vndbinder`
    (no binderfs; Linux 6.12's C binder is used because upstream's Rust binder
    is 64-bit only);
  - `IP_NF_NAT`, `IP_NF_TARGET_MASQUERADE`, `IP_NF_MANGLE`,
    `NETFILTER_XT_TARGET_CHECKSUM`, `SQUASHFS` (xattr, xz), `TUN`,
    `VLAN_8021Q`, and `BRIDGE_VLAN_FILTERING`;
  - `VMSPLIT_3G` instead of `VMSPLIT_2G`.
- **Why 3G/1G and what it costs**: on a 2G/2G kernel (2 GiB of user address
  space), ART could not map its boot image at `0x70000000`, `system_server`
  died with `pthread_create (1040KB stack) failed: Try again`, and zygote
  restarted every 80 s. `VMSPLIT_3G` reduces kernel low memory from about
  1.6 GiB to about 590 MiB (CMA's 256 MiB included); nothing bad was observed
  in a day of use.
- **Root image integration**: `/usr/local/sbin/t715-android-setup`,
  `/usr/local/bin/t715-android`, `t715-android.service`, the "Android" quick
  settings tile (`image/pkg/omamobile-shell/0013-tablet-android-tile.patch`),
  and `python-pyclip` 0.7.0 (`image/pkg/python-pyclip/PKGBUILD`, with
  `wl-clipboard`, see [PACKAGES.md](PACKAGES.md)).

## 3. Setup

Check what is present before starting (does not require root):

```bash
t715-android-setup status
```

Run the installer and configurator as root:

```bash
sudo t715-android-setup all
```

`t715-android-setup all` runs six steps in order (each is also a subcommand):

1. `packages`: copies `/var/lib/pacman/local` to a temporary `--dbpath`,
   refreshes only that copy, downloads `waydroid` and its dependencies into a
   temporary `--cachedir`, and installs them with `pacman -U --noconfirm --needed`.
   `/var/lib/pacman/sync` is never touched, so it avoids a partial upgrade.
2. `init`: checks `/dev/binder` (exits 3 if the running kernel lacks binder)
   and runs `waydroid init`. Pass `--gapps` to `all` or `init` for the GAPPS
   image (`waydroid init -s GAPPS`, not tested).
3. `mesa-fix`: applies the 4-byte Mesa workaround (section 6) into
   `/var/lib/waydroid/overlay/vendor/lib/libgallium_dri.so`. It verifies the
   vendor library's SHA-256 hash first and applies only to that exact library.
4. `configure`: finds the `panfrost` DRM render node under
   `/sys/class/drm/renderD*/device/driver`, writes `drm_device`,
   `ro.opengles.version = 196609` (OpenGL ES 3.1), and
   `persist.waydroid.multi_windows = false` (plus `ro.sf.lcd_density` when
   `T715_ANDROID_DENSITY` is set) to `/var/lib/waydroid/waydroid.cfg`, and
   runs `waydroid upgrade --offline` if anything changed.
5. `firewall`: when `ufw` is active, allows DNS (port 53), DHCP (`67/udp`),
   and routing (`route allow in/out`) on `waydroid0`. Without these rules
   Android gets no DHCP lease.
6. `enable`: enables and starts `waydroid-container.service`.

Start Android as the session user for its first boot:

```bash
t715-android start
```

Once Android has booted once, expose its shared storage to the session user
(`alarm` by default, or pass a username):

```bash
sudo t715-android-setup share
```

`t715-android-setup all` does not run `share` because
`~/.local/share/waydroid/data/media/0` only exists after Android's first boot.

## 4. Daily use

- **Launcher**: user-installed Android apps get `waydroid.<package>.desktop`
  entries in the app drawer (launched through `omamobile-launch`). Built-in
  Android system apps have no launcher entries of their own (Waydroid hides
  them).
- **Quick settings tile**: the "Android" tile (after the SD card tile) shows
  `On`, `Asleep` (while the container is frozen), or `Off`, and stays dimmed
  (`Not installed`) when Waydroid is not installed. A tap starts or stops the
  session (about 5 s to start the session, 2 s to stop, re-probed after 5 s);
  a long press opens Android Settings (`t715-android settings`).
- **`t715-android` and autostart**: as the session user, run
  `t715-android state|start|stop|toggle|settings`. `t715-android.service`
  starts automatically with `graphical-session.target` when `waydroid.cfg` and
  `/dev/binder` exist. `t715-android stop` creates
  `~/.local/state/t715-android/off` so the session stays off across logins
  until `t715-android start` (or the tile) clears it. Logs:
  `journalctl --user -u t715-android`.
- **Shared folder**: `~/Android` links to
  `~/.local/share/waydroid/data/media/0` (Android's `/sdcard`).
  `t715-android-setup share` grants POSIX ACLs (traverse down to `media/0`,
  recursive and default `rwX` while keeping Android's `g:1023:rwX` and
  `m::rwx`) on `Download`, `Pictures`, `Documents`, `DCIM`, `Movies`, and
  `Music`. Nothing is bind-mounted; files stay owned by Android and go both
  ways.
- **Notifications and clipboard**: Android notifications reach Omarchy's
  notification panel and lock screen. Clipboard sharing from Android to Linux
  works through `python-pyclip` (`wl-clipboard`); Linux to Android is not
  checked.
- **Idle freeze and network**: Waydroid freezes the container about 2 minutes
  after the last Android window closes (the tile reads `Asleep`). Android
  reaches the Internet through the host via NAT.

## 5. How it works

`waydroid-container.service` manages the LXC container as root while
`t715-android.service` runs `waydroid session start` inside the graphical
session, communicating over `/dev/binder`, `/dev/hwbinder`, and
`/dev/vndbinder` and bridging network traffic through `waydroid0`.

The SM-T715 exposes two DRM render nodes (`exynos-drm` and `panfrost`) whose
numbering can vary across boots. `t715-android-setup configure` detects the
`panfrost` node from sysfs and sets `ro.opengles.version = 196609` so Android
uses Panfrost at OpenGL ES 3.1.

**Window mode (`persist.waydroid.multi_windows = false`).** Multi-window mode
is intentionally off. Each app launched from the launcher still gets its own
full-screen Wayland window (Hyprland class `waydroid.<package>`), without
Android's caption bar, on its own screen, and Android's focus follows the
shown screen. With multi-window on, Android opened small freeform windows, a
task covered by another lost its window, and `surfaceflinger` crashed
(`HWComposer::presentAndGetReleaseFences`, `SurfaceFlinger::onComposerHalVsync`)
under the resizes needed to fill the screen. Do not turn it on.

## 6. The Mesa bug and binary workaround

Without a fix, `surfaceflinger` dies with `SIGSEGV` a few seconds after start,
always at `libgallium_dri.so+0xd508e8` (`_mesa_hash_table_u64_clear()` in
`src/util/hash_table.c`, Mesa 26.0.8).

- **Why only 32-bit Android**: on 32-bit targets (`sizeof(void *) != 8`),
  `_mesa_hash_table_u64_create()` registers a `ralloc` destructor on a
  `dummy_ctx` child to free heap-allocated 8-byte keys. Once a table outgrows
  its 16 inline entries — reached from Midgard's `mir_squeeze_index()` during
  shader compilation — `_mesa_hash_table_rehash()` allocates the new table
  array as a child of `ht`, prepending it ahead of `dummy_ctx` in `ralloc`'s
  LIFO child list. On `ralloc_free()`, `unsafe_free()` frees the rehashed table
  first and then runs `dummy_ctx`'s destructor, walking the just-freed buffer
  (use-after-free). glibc leaves the freed page readable; bionic unmaps it.
- **Binary workaround**: 4 bytes changed at file offset `0xd4f86a` in the
  vendor `libgallium_dri.so` (`bl ralloc_set_destructor` replaced by `nop.w`),
  placed in `/var/lib/waydroid/overlay/vendor/lib/libgallium_dri.so`.
  `t715-android-setup mesa-fix` (also run by `t715-android-setup all`) applies
  it only when the vendor library matches this exact SHA-256:
  - Stock vendor: `a7523a1a41b54d0362df00b4db8195e9a909fc3df1a4eb7e8edb43d93d5836e7`
  - Patched overlay: `57ffc8aff962f5feb08c3d25f662da052026f3c7199b7b456857c8c8d1d9112b`
- **Cost**: the tables' 8-byte keys leak instead of being freed.
- **Planned clean fix**: drop `dummy_ctx`, attach the destructor directly to
  `ht` with `ht->table.mem_ctx = NULL` on 32-bit, and free keys before freeing
  `ht->table.table`. A clean Android NDK rebuild of Mesa 26.0.8 (Panfrost only)
  with this source fix boots Android as well; its comparison with the patched
  vendor library is not finished, and the bug is not reported upstream yet.

## 7. Measurements

Reference tablet, 2026-11-20 (`android-smoke.sh`, fresh session, all 8 cores
online unless noted):

| Metric | Observed |
|---|---|
| Android boot (`sys.boot_completed`) | 33 s (61-63 s with A57 cluster offline) |
| Session start / stop from tile | 5 s to start, 2 s to stop |
| Settings launch: cold / after thaw / warm | 0.85 s / 1.5 s / 0.13 s |
| Container memory (cgroup, page cache included) | ~1.27 GB |
| Host `MemAvailable` drop | ~670 MB |
| Scrolling Settings (1 app) | 1.1 % janky frames, 13 ms median, 25 ms p90 |
| Scrolling Settings (3 apps open) | 3.4 % janky frames, 44 ms p90 |
| GPU driver and faults | Mali-T760 MC6 (Panfrost), GLES 3.1 Mesa 26.0.8; 0 GPU faults |
| Idle container freeze | ~2 minutes after the last Android window closes |

## 8. Troubleshooting

- **No DHCP lease / no Internet in Android**: `ufw` is blocking `waydroid0`.
  Run `sudo t715-android-setup firewall`.
- **`waydroid prop get/set` says "session is stopped"**: it was run as root.
  Run it as the session user (`alarm`), where Waydroid's session D-Bus service
  lives.
- **Zygote restarts every ~80 s** (`pthread_create (1040KB stack) failed: Try again`,
  ART cannot map its boot image at `0x70000000`): the running kernel uses
  `VMSPLIT_2G`. Boot a kernel built with `kernel/patches/t715-waydroid/`
  (`VMSPLIT_3G`).
- **`surfaceflinger` SIGSEGV seconds after start at `libgallium_dri.so+0xd508e8`**:
  the Mesa overlay is missing or the vendor image changed. Run
  `sudo t715-android-setup mesa-fix` and check the library SHA-256 against
  section 6.
- **Boot and launch times roughly double** (boot 61-63 s instead of 33 s): the
  A57 cluster was offline when that was measured
  (`cat /sys/devices/system/cpu/online` read `0-3`, power profile "balanced");
  why it was offline then was not looked into. Check the online cores before
  comparing timings.

## 9. Not working or not tested

- **No sensors in Android**: `waydroid-sensors` requires SensorFW.
- **No cameras in Android**: both cameras stay on the Linux side.
- **No Google Play services** in the `VANILLA` image (`t715-android-setup init --gapps`
  exists, not tested).
- **Suspend to RAM (`t715-sleep`)** with an active Android session: not tested.
- **Screen rotation** with Android windows: not tested.
- **Clipboard Linux to Android**: not checked (Android to Linux works).
- **Keyboard notification**: Android posts a "Configure physical keyboard"
  notification at every session start.

## 10. Smoke test

Run `image/tests/ondevice/android-smoke.sh` as root on the tablet:

```bash
sudo bash image/tests/ondevice/android-smoke.sh --report /tmp/android-smoke.txt
```

Options: `--app COMPONENT` (default `com.android.settings/.Settings`),
`--boot-timeout S` (default `180`), `--keep` (leave the session running when
the script started it; otherwise it stops on exit), `--report FILE`.

The script prints fixed-order `key=value` lines: `android_smoke=1`,
`session_was_running`, `boot_completed`, `boot_seconds`, `gles`, `gpu_driver`
(`panfrost`, `software`, or `unknown`), `launch_cold_ms`, `launch_thaw_ms`,
`launch_warm_ms`, `android_mem_mb`, `host_mem_available_before_mb`,
`host_mem_available_after_mb`, `crashes`, `crashed`, `gpu_faults`, and
`verdict`.

`verdict=pass` (exit 0) requires `boot_completed=yes` (or
`session_was_running=yes`), `gpu_driver=panfrost`, `crashes=0`, and
`gpu_faults=0`. Other exit codes: `1` fail, `2` bad arguments, `3` not root,
`4` Waydroid not installed.
