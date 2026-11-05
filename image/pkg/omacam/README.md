# omacam

[omacam](https://github.com/derekross/omacam) 0.3.3 is Omarchy Mobile's
camera app, shown as **Camera** (Rust, GTK 4 and libadwaita, on libcamera
directly): a full-screen viewfinder, tap to focus, full-resolution photos,
video with sound, lens switching by zoom. This package makes it the
finger-friendly camera of the SM-T715 image, next to `t715-camera`'s
one-shot Photo and Selfie entries.

## Differences from upstream's package

[Upstream's PKGBUILD](https://github.com/derekross/omacam-mobile/blob/master/packages/omacam/PKGBUILD)
(omarchy-mobile `packages/omacam`) is kept as is, with:

- **`arch=(armv7h)`** instead of `aarch64`: the tablet's arch. Everything
  it needs builds for it in ALARM (rust 1.99, gtk4, libadwaita, clang,
  libcamera 0.7.2), so nothing else changes.
- **One patch, `0001-tablet-lens-table.patch`** (pkgrel 2), which teaches
  omacam three things this tablet needs: a system-wide lens table read from
  `/etc/omacam/lenses.toml` (after `--lens-table` and the user's
  `~/.config/omacam/lenses.toml`, before the built-in Pixel 7 Pro table),
  an optional per-lens `preview_fps` that caps the preview's frame rate,
  and an optional table-level `merge_threads` that caps the Night/HDR
  burst merge's thread pool. The SM-T715 debayers its camera image on the
  CPU, which costs about 1.2 cores at 15 fps for a 1640x1228 preview — at
  the default 30 fps the tablet heats for nothing the eye can see — and a
  7-thread merge (8 cores less one) took the CPU to 82 °C in 17 s. The
  tablet's own table (`t715-camera`'s `/etc/omacam/lenses.toml`) sets
  `preview_fps = 15` and `merge_threads = 2`; without the keys the
  behaviour is exactly upstream's.

  The sources otherwise carry no 32-bit assumption: casts only widen
  (`u32 as u64`), there is no `AtomicU64`, no pointer-width `repr`, and
  libcamera-rs's C API is `size_t`-based with `static_assert` layout
  checks (`libcamera-sys` 0.7.0's `c_api/`).

## Runtime needs

- **libcamera** for the Galaxy Tab S2's cameras: the version constraint
  (`libcamera>=0.7, libcamera<0.8`) is satisfied by ALARM's official
  0.7.2-4, which this build uses. This repository also carries its own
  `libcamera 0.7.2-4.2` package for the Tab S2 (the sensor support the
  stock one lacks); once it is built into `[t715-omarchy]`, which the
  image declares before ALARM's repositories, it takes precedence for
  omacam too.
- **PipeWire** for video sound: `gst-plugin-pipewire` is a runtime depend
  (the microphone), served by ALARM.
- Optional: `loupe` (open the last photo from the gallery button),
  `geoclue` (location tags; the package installs
  `/etc/geoclue/conf.d/91-omacam.conf`).

## Rebuilding

```bash
image/tools/build-pkg omacam          # hours under qemu; see below
ls image/out/repo/armv7h/ | grep omacam
```

Upstream measures about 18 min under qemu-user on their laptop for
aarch64 (their `tools/build-packages`, 0.1.6); armv7h under qemu on an
arm64 host is slower — expect several hours for the whole dependency closure
(171 crates, gtk4-rs included). The build log is
`image/cache/build-pkg/omacam/build.log`. `check()` runs `omacam-core`'s
tests (the camera logic) under qemu too.
