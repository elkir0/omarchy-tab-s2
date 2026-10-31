# Headless Hyprland test: not possible on this Mac

Goal (2026-10-28): start Hyprland 0.56 and the Omarchy shell in an armv7h
container, with an aarch64 run as the control, to catch 32-bit crashes
before using the tablet.

Outcome: **Hyprland cannot start in a container under Docker Desktop on
this Mac**, whatever the settings:

- The Docker Desktop VM (linuxkit) has no DRM device: `/sys/class/drm`
  contains only `version`, there is no `/dev/dri`, and no virtio-gpu device.
- aquamarine 0.15.1 (current release and `main`) builds its buffer
  allocator only from a DRM file descriptor. Its headless backend reports
  `drmFD() == -1`, so with no DRM device `CBackend::start()` fails and
  Hyprland aborts (`CBackend::create() failed!`, SIGABRT).
- `HYPRLAND_HEADLESS_ONLY=1` is not read by the Hyprland binary: it is only
  a marker that Hyprland's own test runner (`hyprtester`) sets. Upstream CI
  works because its runners expose `/dev/dri`.

The aarch64 side did confirm that Omarchy's repository bootstrap works
(keyring package, `pacman-key --populate`, signatures verified) and that
omarchy 4.0.6 installs in an ALARM container.

`image/tests/test_omarchy_headless.sh` is the unfinished script of that attempt:
**unverified, do not rely on it**. The 32-bit question is answered on the
tablet instead (see `docs/journal/COORDINATION.md` for the time-slot protocol).
Ways to revive an off-device test later: a Linux host with `vkms` or a
render node passed to the container, or a VM with virtio-gpu.
