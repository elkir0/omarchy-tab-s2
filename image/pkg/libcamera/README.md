# libcamera

[libcamera](https://libcamera.org/) 0.7.2 for the SM-T715, armv7h: Arch's
`0.7.2-4` (which ALARM builds unchanged) rebuilt with
[omarchy-mobile](https://github.com/derekross/omarchy-mobile)'s software-ISP
patch series and three patches of our own for the Galaxy Tab S2's cameras.
`pkgrel=4.2` sorts above ALARM's `0.7.2-4` in `[t715-omarchy]`, which the
image declares before `[core]`.

The tablet's cameras have no ISP: the `t715-camera` kernel driver captures
raw Bayer through CSIS and FIMC-LITE straight to memory, which the simple
pipeline handler with the software ISP turns into pictures. Stock libcamera
ignores the receiver — the simple handler matches only a fixed table of
media-device driver names — and has never heard of the two Samsung sensors.
Hence this package (`docs/hardware/CAMERA.md`; `docs/image/PACKAGES.md`).

## The patches

- **0001–0056, unchanged from omarchy-mobile** at commit
  `0f43776a2662272cf8569559fc91ec356dfa97dd` (2026-11-03, MIT; the series
  is their `packages/libcamera/`). Written for a Pixel 7 Pro's `gs201-csis`
  receiver, they give the software ISP, on GLES 2/3 through EGL: contrast
  autofocus with a lens, lens shading, denoise, sharpening and
  defective-pixel correction, a better AGC/AWB, and manual controls. Their
  README documents each patch, the tuning-file keys (`Af` with
  `coarseSteps`, `fineSteps`, `range: [min, max]`; `Detail`; contrast and
  saturation defaults) and how sensors are added (0004, 0013).
- **`0057-pipeline-simple-Add-the-Galaxy-Tab-S2-camera-receive.patch`** —
  one entry, `{ "t715-camera", {}, true }`, in `supportedDevices`, in
  alphabetical position. Ours: the driver is this repository's own, so the
  patch will not be sent upstream.
- **`0058-libcamera-Add-the-Samsung-S5K4H5-and-S5K6B2-sensors.patch`** —
  the two sensors as omarchy-mobile adds its Samsung ones: sensor helpers
  (`CameraSensorHelper`, black level 64 at 10 bits, linear gain
  `AnalogueGainLinear{ 1, 0, 0, 32 }` — both measured on the tablet and
  declared by the sensors' SMIA limit registers)
  and sensor properties (unit cell 1120 nm for the S5K4H5 from Samsung's
  specification, an estimated 1400 nm for the S5K6B2; the SMIA test pattern
  modes 0–4; two-frame control delays). The sensors' entity names
  (`s5k4h5 21-0037`, `s5k6b2 22-0035`) carry an I2C address, so libcamera
  derives the model `s5k4h5` / `s5k6b2` and finds the helper and the tuning
  file by it.
- **`0059-ipa-simple-Tuning-files-for-the-S5K4H5-and-S5K6B2.patch`** —
  `s5k4h5.yaml` and `s5k6b2.yaml` in `src/ipa/simple/data/`, on the meson
  install list: a contrast 1.2 default and omarchy-mobile's `Detail` (noise
  reduction and sharpening) values. No colour matrix and no saturation
  default: the tablet runs the software ISP on the CPU, where a matrix,
  even the identity, sends the debayer down its per-pixel path (60 frames
  at 1640×1228: 5.0 s of CPU with one, 3.1 s without; contrast costs
  nothing, it goes through the gamma table). The rear's `Af` scans only the DW9807's useful travel —
  `range: [ 400, 700 ]` of its 0–1023 — with their main camera's step
  counts (8 coarse, 32 fine). The front is fixed focus: no `Af`.
- **`libcamera-fix-python3.14-macro-redefinition.patch`** — Arch's own,
  unchanged (sha256 `2eb9407d…`).

## What differs from omarchy-mobile's aarch64 build

- `arch=(armv7h)`, `pkgrel=4.2` (theirs is aarch64, 4.22): ours sorts above
  ALARM's `0.7.2-4`, the one this replaces on the tablet.
- No `libpisp` anywhere: the trimmed build's pipelines (`simple`,
  `uvcvideo`) and IPA (`simple`) link none — ALARM's armv7h `libcamera`
  depends on it only for the `rpi/pisp` pipeline it builds and we do not.
- `sdl2` resolves through `sdl2-compat`'s `Provides: sdl2` (ALARM armv7h
  ships no `sdl2` package of its own), as a makedep and in
  `libcamera-tools`.
- Same trimmed build otherwise: pipelines `simple,uvcvideo`, IPA `simple`,
  `softisp-gpu=enabled` (Mesa Panfrost gives it EGL and GLES 2/3), no
  docs, no tests, `werror=false`.

## Rebuilding

```bash
image/tools/build-pkg libcamera       # an hour or two under qemu
ls image/out/repo/armv7h/ | grep -E '^libcamera'
```

Build log: `image/cache/build-pkg/libcamera/build.log`. Five packages come
out (`libcamera`, `libcamera-ipa`, `libcamera-tools`, `gst-plugin-libcamera`,
`python-libcamera`); on the tablet `pacman -Syu` picks `libcamera*` from
`[t715-omarchy]`. To check the series applies to a clean `v0.7.2`:

```bash
git clone --depth 1 --branch v0.7.2 https://git.libcamera.org/libcamera/libcamera.git /tmp/lc
cd /tmp/lc && for p in <this directory>/00*.patch; do patch -Np1 -s < "$p"; done
```

Rebase 0057–0059 on each new ALARM libcamera release, and drop omarchy-mobile's
patches they have absorbed (their README tracks the upstream state).
