# Screen rotation (P3)

Status: implemented 2026-10-30 and validated by the owner by hand, image and touch
in all four positions, see section 9. It ships **off by default**: the Rotation tile
turns it on. The rest of this document is the design it follows.

## 1. What exists

- **Sensors**: the LSM6DS3 and YAS537 have been in the board since
  `12380c451` (`docs/journal/HANDOVER.md`), and Phosh ran
  iio-sensor-proxy on them. The accelerometer's mount matrix (x'=y, y'=x,
  z'=-z) comes from stock (`docs/hardware/SENSORS_M7.md` §2.1) and has **never been
  checked by tilting**.
- **Package**: `extra/iio-sensor-proxy 3.9-1` exists for armv7h (checked
  in `t715-omarchy:base-armv7h`). Its libssc dependency pulls libqmi,
  protobuf and abseil-cpp: up to 12 packages, 7.7 MiB.
- **Upstream** (omarchy-mobile 5f7ba48): `omamobile-sensors/lib/autorotate.py`
  (MIT) is a SensorProxy client with a lock file,
  `~/.local/state/omamobile/rotation-lock`. Its package also ships a
  Pixel-only proxy, so we take the client only. Our patch 0001 removed the
  rotation-lock tile from the catalogue, but its QML (upstream
  `QuickSettings.qml:955-1000`, which no patch of ours touches) is still in
  our build. The shell has had
  landscape layouts since 0.2.30, checked on a Pixel only.

## 2. Hyprland 0.57 at run time

```
hyprctl eval 'hl.monitor({ output = "DSI-1", mode = "preferred", position = "auto", scale = 2, transform = 1 }); hl.config({ input = { touchdevice = { transform = 1, output = "DSI-1" } } })'
```

What the v0.57.0 source (`0aa6745`) shows:

- **Monitor**: a rule replaces any earlier rule with the same name
  (`src/config/shared/monitor/MonitorRuleManager.cpp:36-41`). The last
  matching rule wins, here over Omarchy's `output = ""` rule (`:95-98`).
  `hl.monitor` copies defaults only from a rule with the same name
  (`src/config/lua/bindings/LuaBindingsConfigRules.cpp:1098`), so the call
  gives mode, position and scale itself.
- **Touch**: a touch lands at `m_position + pos * m_size`
  (`src/managers/input/Touch.cpp:58`), which ignores the monitor's
  transform. So the touch transform must be set to match it
  (`src/config/values/ConfigValues.cpp:431`,
  `src/managers/input/InputManager.cpp:2041-2043`).
- **No `keyword`**: the server registers no `keyword` command
  (`src/ipc/s1/Commands.cpp:2084-2126`), so upstream's keyword fallback
  never works.
- **Errors**: an eval error goes back to the caller, not to an on-screen
  notification (`src/config/lua/ConfigManager.cpp:835-838`). That matters
  because rendering text can deadlock Hyprland here.
- **Reload**: `hyprctl reload` clears the monitor rules
  (`ConfigManager.cpp:677`), so both transforms go back to 0, and posts
  `configreloaded` (`:826`).

Mapping (upstream's; both panels are portrait-native): normal 0, left-up 1,
bottom-up 2, right-up 3.

## 3. Orientation events

iio-sensor-proxy is on the system bus. A client calls `ClaimAccelerometer`
or `ReleaseAccelerometer` and reads `AccelerometerOrientation` from
`PropertiesChanged`. The sensor is read only while claimed. `monitor-sensor`
shows the same events. If the matrix is wrong, a udev `ACCEL_MOUNT_MATRIX`
property can fix it in the image (iio-sensor-proxy tries it before sysfs;
to confirm on 3.9), and the device tree gets the final fix.

## 4. The daemon

`/usr/local/bin/t715-rotate` is a new user service, forked from
`autorotate.py`. It is not part of t715-keys, so a rotation bug cannot cost
the Power key. Its unit is named `omamobile-autorotate.service`, in
`/etc/systemd/user`, so the upstream tile works unchanged. Changes from
upstream:

- **Hyprland**: eval only, for `DSI-1`, at the scale that
  `hyprctl monitors -j` reports. It applies at start and on each
  `configreloaded`.
- **Debounce**: applies an orientation once it has held for 700 ms. It
  ignores `undefined` and allows bottom-up (`T715_ROTATE_UPSIDE_DOWN=0`
  disables it).
- **Screen off**: t715-keys creates `$XDG_RUNTIME_DIR/t715-keys/touch-off`
  at every screen-off (Power, cover, idle) and removes it when the screen
  comes back. The daemon watches that file: when it appears, it releases
  the sensor; when it goes, it claims the sensor and applies the current
  orientation. Nothing turns under a closed cover.
- **No polling**: upstream checks whether the session is locked every
  second while rotated (patch 0004 removed pollers like that). P4 adds a
  lock hook instead.
- **Manual**: `t715-rotate set 0|1|2|3`, or `turn` for a quarter turn
  clockwise. Both create the lock file first.
- **Camera hold**: omacam is written for a phone whose screen never turns:
  it rotates its preview and its photos itself from the accelerometer, so a
  screen that turns under it makes both wrong. While a window of the focused
  classes (`T715_ROTATE_PORTRAIT_CLASSES`, `omacam` by default, empty to
  disable) has focus — `activewindow>>` on the event socket, read once at
  start too — the daemon holds the panel at transform 0 and only remembers
  sensor changes. When focus leaves, the sensor's latest orientation comes
  back at once (no debounce) with a claim, or the transform in use when the
  hold began without one (lock, screen off, no sensor).
- **Fullscreen video**: no exception. Landscape is the point, and the lock
  covers watching while lying down.

## 5. Tiles and default

- **Rotation lock**: patch 0001 keeps `rotation-lock` in the catalogue, in
  fifth place. Locking holds the current orientation.
- **Rotate**: a new tile (patch 0005) that runs `t715-rotate turn`. It
  needs no sensor.
- **Default: on, since the owner validated it (2026-11-03).** The image
  enables the unit for alarm with a user link
  (`rootfs/omarchy-user-setup.sh`), not `--global`, so the tile can still
  turn it off and the choice survives a reboot. Until then the unit shipped
  disabled and the tile read Locked.

## 6. What assumes portrait

Logical sizes: 768x1024 in portrait, 1024x768 in landscape.

| Surface | In landscape | To do |
|---|---|---|
| Bar, back edges, hide button, dock | follow their anchored edges | none |
| Home (6x8 grid) | shown as 8x6 without saving it; cells go from 128x113 to about 128x108; editing is refused; upstream's batch-5 bugs (icon rows become columns) | check |
| Drawer (6 columns) | about 8 columns | none |
| Quick settings | the sheet at 58 % width, beside the notifications; 3 tile columns instead of 4 | check |
| squeekboard | Wide arrangement in both orientations (the screen's short side is 122 mm, not under 115 mm; v1.43.1 `src/state.rs`); its height goes from 23 % of the screen to 33 % | `scale-in-horizontal-screen-orientation` |
| Terminal layouts | in Wide, the built-in `terminal/fr_wide` comes before our `terminal/fr.yaml` (`src/data/loading.rs`), so our Esc layouts are probably shadowed in portrait already | ship them as `_wide` too |
| Floating windows | sized when they open, so a float opened in landscape overflows when turned back | accept |

## 7. Plan

Run hyprctl as alarm (`as_user` in `image/tests/ondevice/omarchy-probe.sh`;
add a `rotate N` mode). Announce each rotation to the owner. If anything
goes wrong, `rotate 0` over SSH puts it back.

1. **Probe**, read-only: IIO names, `in_accel_mount_matrix`, raw x/y/z.
   *Owner*: holds the tablet upright, then with each edge up.
2. **Rotate by hand**, no image change: `rotate 1`, then 3, 2, 0. Check
   `hyprctl monitors -j`, `getoption input:touchdevice:transform` and
   `omamobile.home state` (landscape, 8x6), and take a `shot` each time.
   *Owner*: taps the corners, dock, back swipe and pull-down; opens the
   drawer, quick settings, recents, and Firefox with the keyboard.
3. **Cost**: 10 rotations against slot 5's leak counters (DECON
   attachments, Shmem), with `sample 60` running; then `hyprctl reload` in
   landscape.
4. **Sensor**: install iio-sensor-proxy in the overlay and run
   `monitor-sensor`. *Owner* tilts it. Expected: upright (Home key down)
   reads normal, each edge up reads its own value, and flat keeps the last
   one. If any reading is wrong, add a udev rule and test again.
5. **Daemon**: `--dry-run` first, then live. *Owner*: quick flips, cover
   closed while tilted, Power off, turn, Power on, a fullscreen video.
6. **Tiles**: rebuild the shell with patches 0001 and 0005 after offline
   renders. *Owner*: locks in landscape, unlocks, uses Rotate.
7. **Image**: iio-sensor-proxy in `packages.extra`, the daemon and its
   unit, smoke checks (unit present, not enabled). Replay 4-6, then decide
   the default.

## 9. State on 2026-10-30

In the image: `iio-sensor-proxy`, `/usr/local/bin/t715-rotate`,
`/etc/systemd/user/omamobile-autorotate.service` (not enabled),
`/etc/udev/rules.d/61-t715-accelerometer.rules`, and in the shell
(`0006-tablet-rotation.patch`) the tiles Rotation, which reads Locked until it is
turned on, and Rotate, a quarter turn by hand, on the second page.

Checked on the tablet:

| Check | Result |
|---|---|
| By hand, transforms 1, 2, 3, 0 | screen and touch follow, about 150 ms a turn, home in its landscape layout |
| Memory over 74 turns | Shmem rises from about 310 MiB and settles near 480, RSS steady, no shell restart |
| Real sensor | iio-sensor-proxy reads the LSM6DS3: accelerometer present, `face-up` lying flat; the kernel's mount matrix is `0,1,0; 1,0,0; 0,0,-1` |
| `t715-rotate` driven by `image/tests/ondevice/rotate-fake-sensor.py`, real Hyprland | right-up 3, left-up 1, bottom-up 2, normal 0; a 300 ms flick ignored; `hyprctl reload` in landscape keeps it; the lock holds it; `turn` and `set` lock |

By the owner, by hand, with the real service turned on from the Rotation tile:

| Check | Result |
|---|---|
| First try | the image upside down in every position: held upright, the proxy read `bottom-up`. The stock matrix is 180 degrees off for iio-sensor-proxy, as section 8 feared |
| With `ACCEL_MOUNT_MATRIX` negating x and y, a udev rule | the image upright in all four positions, and touch lands where the finger is |

The kernel's mount matrix stays as it is, since the udev property wins for
iio-sensor-proxy. A device tree fix would need a new kernel for nothing else.

Not checked:

* **The screen-off behaviour** with the cover: no turn under a closed cover.
* **Apps in landscape**: Chromium, the keyboard, terminal layouts.

Left for the owner: whether the image should ship with rotation on.

## 8. Risks

1. **Mount matrix**: unverified, so rotation may go the wrong way or
   mirror. Step 4 catches it before auto-rotation is turned on, and the
   fix stays in the image.
2. **Screen and touch out of step**: their transforms are separate, and a
   reload resets both. On a touch-only tablet only SSH can recover. So one
   eval sets both, the daemon reapplies after a reload, and the default
   stays locked.
3. **Cost**: each turn reallocates every buffer of the shell and apps, and
   six plugins re-lay out on a Mali at the then fixed 266 MHz (the GPU has
   scaled since 1.0.1, `docs/hardware/GPU.md`). The GEM_CLOSE leak fix was
   only validated on drawer cycles; step 3 measures this.

Also: the landscape layouts were checked at Pixel sizes only.
