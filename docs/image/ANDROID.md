# Android apps (Waydroid) — SM-T715

Status: working on the reference tablet on 2026-11-21; **not in a release yet**.
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

- **Optional kernel series `kernel/patches/t715-waydroid/`**: two defconfig
  patches on top of the 1.0.4 release tree (built as `#20` on the reference
  tablet since 2026-11-20; `#19` was the first patch alone; see
  [kernel/README.md](../../kernel/README.md)). The series is optional — systems
  without Android stay on the standard 1.0.4 kernel.
  - Patch 1 enables `ANDROID_BINDER_IPC` with static devices
    `binder,hwbinder,vndbinder` (no binderfs; Linux 6.12's C binder is used
    because upstream's Rust binder is 64-bit only), `IP_NF_NAT`,
    `IP_NF_TARGET_MASQUERADE`, `IP_NF_MANGLE`, `NETFILTER_XT_TARGET_CHECKSUM`,
    `SQUASHFS` (xattr, xz), `TUN`, `VLAN_8021Q`, `BRIDGE_VLAN_FILTERING`, and
    `VMSPLIT_3G` instead of `VMSPLIT_2G`.
  - Patch 2 (~65 options) adds the policy routing and fwmarks Android's `netd`
    needs for outside traffic and DNS: `IP_ADVANCED_ROUTER`,
    `IP_MULTIPLE_TABLES`, `IPV6_MULTIPLE_TABLES`, `NF_CONNTRACK_MARK`, the xt
    mark/connmark matches and targets, `IP_NF_RAW`, `IP_NF_SECURITY`,
    `IP6_NF_MANGLE`, `IP6_NF_RAW`, `IP6_NF_NAT`, `NF_CT_NETLINK`, netlink queue
    and log, `NET_SCHED` (HTB, ingress, u32 and BPF classifiers), `IFB`, ESP,
    and socket diag modules.
- **Why 3G/1G and what it costs**: on a 2G/2G kernel (2 GiB of user address
  space), ART could not map its boot image at `0x70000000`, `system_server`
  died with `pthread_create (1040KB stack) failed: Try again`, and zygote
  restarted every 80 s. `VMSPLIT_3G` reduces kernel low memory from about
  1.6 GiB to about 590 MiB (CMA's 256 MiB included); nothing bad was observed
  in a day of use.
- **Root image integration**: `/usr/local/sbin/t715-android-setup`,
  `/usr/local/bin/t715-android`, `t715-android.service`, the Android window
  rule in `image/rootfs/t715-tablet.lua`, the "Android" quick settings tile
  (`image/pkg/omamobile-shell/0013-tablet-android-tile.patch`), and
  `python-pyclip` 0.7.0 (`image/pkg/python-pyclip/PKGBUILD`, with
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
   image (`waydroid init -s GAPPS`; section 5). If SourceForge is very slow
   (25-190 KiB/s observed), download the image elsewhere, check it against the
   `id` (SHA-256) in Waydroid's OTA JSON, unzip into
   `/var/lib/waydroid/images/`, set `system_datetime` in `waydroid.cfg` to the
   JSON's `datetime`, and run `waydroid upgrade --offline`.
3. `mesa-fix`: applies the 4-byte Mesa workaround (section 7) into
   `/var/lib/waydroid/overlay/vendor/lib/libgallium_dri.so`. It verifies the
   vendor library's SHA-256 hash first and applies only to that exact library.
4. `configure`: finds the `panfrost` DRM render node under
   `/sys/class/drm/renderD*/device/driver`, writes `drm_device`,
   `ro.opengles.version = 196609` (OpenGL ES 3.1),
   `persist.waydroid.multi_windows = false`, and
   `ro.lmk.use_minfree_levels = false` (puts `lmkd` in pressure/PSI mode;
   section 9) — plus `ro.sf.lcd_density` when `T715_ANDROID_DENSITY` is set —
   to `/var/lib/waydroid/waydroid.cfg`, and runs `waydroid upgrade --offline` if
   anything changed.
5. `firewall`: when `ufw` is active, allows DNS (port 53), DHCP (`67/udp`),
   and routing (`route allow in/out`) on `waydroid0`. Without these rules
   Android gets no DHCP lease.
6. `enable`: enables and starts `waydroid-container.service`.

Start Android as the session user for its first boot:

```bash
t715-android start
```

Once Android has booted once, expose its shared storage to the session user
(`alarm` by default, or pass a username), and on the GAPPS image run `trim`
(section 5):

```bash
sudo t715-android-setup share
sudo t715-android-setup trim   # GAPPS only; reversible with trim --undo
```

`t715-android-setup all` runs neither `share` nor `trim` because Android must
have booted once first.

## 4. Daily use

- **Launcher**: Android apps appear as `waydroid.<package>.desktop` entries in
  the app drawer (launched through `omamobile-launch`). Waydroid hides its
  built-in apps by default; `t715-android start` and `t715-android apps`
  unhide the useful built-in apps (including Files and Browser) and hide
  camera and telephony apps that have no hardware inside Android (section 5).
- **Quick settings tile**: the "Android" tile (after the SD card tile) shows
  `On`, `Asleep` (while the container is frozen), or `Off`, and stays dimmed
  (`Not installed`) when Waydroid is not installed. A tap starts or stops the
  session (about 5 s to start the session, 2 s to stop, re-probed after 5 s);
  a long press opens Android Settings (`t715-android settings`).
- **`t715-android` and autostart**: as the session user, run
  `t715-android state|start|stop|toggle|settings|apps`. `t715-android.service`
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
  after the last Android window closes (the tile reads `Asleep`). On kernel
  `#20` (both patches of `t715-waydroid/`) with the `ufw` rules, Android
  routes outside traffic through the host's nftables masquerade
  (`LXC_USE_NFT="true"`) and resolves DNS through the host's `dnsmasq`. Check
  connectivity with `ping -c1 -I eth0 <an outside address>` and
  `dumpsys dnsresolver` inside Android plus the host's nftables masquerade
  packet counter for the Waydroid subnet — `dumpsys connectivity` reporting
  `VALIDATED` alone proves nothing (kernel `#19` reported `VALIDATED` while
  forwarding nothing and failing all DNS).
- **Screen off or locked**: Android apps cannot draw while the tablet's screen
  is off or locked (for example, Play Store shows "isn't responding").

## 5. Installing apps

Waydroid marks its built-in apps `NoDisplay=true` when it writes
`~/.local/share/applications/waydroid.<package>.desktop`, which left the
launcher without a file manager or a browser. `t715-android apps` (also run
silently by `t715-android start`) sets `NoDisplay=false` for the built-in apps
useful on this tablet — Files, Browser, Gallery, Settings, Calculator, Clock,
Contacts, Calendar, Music, and Recorder — and `NoDisplay=true` for camera,
dialer, and messaging apps (no cameras or telephony inside Android). Run
`t715-android apps list` to inspect the current state. Both lists can be
overridden with `/etc/t715-android/apps-show` and
`/etc/t715-android/apps-hide` (one package name per line, `#` comments).

To install additional apps, there are three ways:

1. **Direct APK install**: run `waydroid app install file.apk` as the session
   user. Because the tablet runs AArch32, only `armeabi-v7a` or
   architecture-independent APKs install.
2. **A store installed that way**: install a store (such as F-Droid or Aurora
   Store) via `waydroid app install`, then install and update apps from it.
3. **The Google-apps image (`GAPPS`)**: initialise with
   `sudo t715-android-setup all --gapps` (or `init --gapps`; official
   `lineage-20.0-20260926`, 1.1 GB download, 2.26 GB unpacked). With kernel
   `#20`, Google sign-in in the Play Store and installing apps from it worked
   on the reference tablet on 2026-11-20/21 (three user apps installed).
   Device registration (`sudo t715-android-setup google-id`, then registering
   at `https://www.google.com/android/uncertified` and restarting Android) was
   not needed for that sign-in, though Google may still require it.

The `GAPPS` image is heavy for 2.7 GB of RAM: first boot ran at load average 36
on four cores, and in use it held 930 MB of the 1.37 GB zram swap with 530 MB
available, making Android sluggish from memory pressure (not emulation or
software rendering: Panfrost ran up to 700 MHz with all eight cores online).
Once booted, run `sudo t715-android-setup trim` (reversible via `trim --undo`,
package list overridable via `/etc/t715-android/trim`): it disables for user 0
`com.google.android.googlequicksearchbox` (Google app, ~170 MB),
`com.google.android.apps.messaging`, `com.google.android.ims`,
`com.google.android.dialer`, and `com.google.android.as`, and sets
`activity_manager_constants` `max_cached_processes=6`. That lifted available
memory from 576 to 873 MB, cut swap in use from 932 to 671 MB, and brought
memory pressure back to 0 (largest remaining: Google Play services ~170 MB with
helper, Play Store ~150 MB open, `system_server` 100 MB, Android's launcher
95 MB — unused in this window mode but needed as `HOME`).

## 6. How it works

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

**Window rule (`image/rootfs/t715-tablet.lua`).** Two Android windows tiled on
one screen shrink Android's single display to the smaller window (1488x898, or
730x898 with three — e.g. Play Store opening a second window, or an app opened
from another). `o.window("^waydroid[.].*$", { workspace = "empty" })` puts
every Android window on its own empty workspace; checked with Play Store then
Settings (both 744x912, Android's display full size).

## 7. The Mesa bug and binary workaround

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

## 8. Measurements

Reference tablet: `VANILLA` (without Google apps) on 2026-11-20
(`android-smoke.sh`, fresh session, all 8 cores online unless noted) and
`GAPPS` / kernel `#20` on 2026-11-20/21:

| Metric | Observed |
|---|---|
| Android boot (`sys.boot_completed`), `VANILLA` | 33 s (61-63 s with A57 cluster offline) |
| Android boot (`sys.boot_completed`), `GAPPS` (`ro.lmk.use_minfree_levels = false`) | 73 s |
| Session start / stop from tile (`VANILLA`) | 5 s to start, 2 s to stop |
| Settings launch: cold / after thaw / warm (`VANILLA`) | 0.85 s / 1.5 s / 0.13 s |
| Container memory, cgroup + page cache (`VANILLA`) | ~1.27 GB |
| Host `MemAvailable` drop (`VANILLA`) | ~670 MB |
| `GAPPS` memory before `trim` | 530-576 MB available, 932 MB of the 1.37 GB zram swap in use |
| `GAPPS` memory after `trim` | 873 MB available, 671 MB swap in use, memory pressure 0 |
| Scrolling Settings, 1 app / 3 apps open (`VANILLA`) | 1.1 % jank (13 ms med, 25 ms p90) / 3.4 % jank (44 ms p90) |
| GPU driver and faults (`VANILLA`) | Mali-T760 MC6 (Panfrost), GLES 3.1 Mesa 26.0.8; 0 GPU faults |
| DNS via host `dnsmasq` (kernel `#20`) | 21 of 21 queries succeeded |
| Idle container freeze (`VANILLA`) | ~2 minutes after the last Android window closes |

## 9. Troubleshooting

- **No DHCP lease / no Internet in Android**: `ufw` is blocking `waydroid0`.
  Run `sudo t715-android-setup firewall`.
- **No Internet/DNS in Android although it says connected** (`dumpsys
  connectivity` reads `VALIDATED`, `ip rule` says "Operation not supported",
  logcat logs `Unable to resolve host`): the running kernel lacks the second
  patch of `kernel/patches/t715-waydroid/` (policy routing and fwmarks for
  `netd`, as in kernel `#19`). Boot kernel `#20` and verify with
  `ping -c1 -I eth0 <an outside address>`, `dumpsys dnsresolver`, and the
  host's nftables masquerade packet counter.
- **Android stuck on its boot animation, `lowmemorykiller` kills in logcat**
  (`cache(0kB) and free(...)-reserved(...) below min(...)`): Waydroid defaults
  to `ro.lmk.use_minfree_levels=true`, where `lmkd` subtracts both shmem and
  unevictable pages from file cache; GPU/Wayland buffers are both (950 MB seen),
  so `lmkd` reads 0 kB cache and kills apps in a loop. Run
  `sudo t715-android-setup configure` to set `ro.lmk.use_minfree_levels = false`
  (pressure/PSI mode).
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
  section 7.
- **Boot and launch times roughly double** (boot 61-63 s instead of 33 s): the
  A57 cluster was offline when that was measured
  (`cat /sys/devices/system/cpu/online` read `0-3`, power profile "balanced");
  why it was offline then was not looked into. Check the online cores before
  comparing timings.

## 10. Not working or not tested

- **No sensors in Android**: `waydroid-sensors` requires SensorFW.
- **No cameras in Android**: both cameras stay on the Linux side.
- **Drawing with screen off or locked**: Android apps cannot draw while the
  screen is off or locked (Play Store shows "isn't responding").
- **Suspend to RAM (`t715-sleep`)** with an active Android session: not tested.
- **Screen rotation** with Android windows: not tested.
- **Clipboard Linux to Android**: not checked (Android to Linux works).
- **Keyboard notification**: Android posts a "Configure physical keyboard"
  notification at every session start.

## 11. Smoke test

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
