# Hardware video decoding (MFC): feasibility

2026-10-29, read-only study, no device touched. `linux` = `src/linux-6.12`
(t715-bringup), `mfc/` = `linux/drivers/media/platform/samsung/s5p-mfc/`, `stock` =
`src/kernel_universal5433`. Firefox read on `mozilla-firefox/firefox` main, FFmpeg on master.

## Verdict

**No-go for YouTube in Firefox.** The 5433 MFC is a v8 block: H.264, VP8, MPEG-1/2/4, H.263, VC-1.
It cannot decode VP9 or AV1. HEVC sits in a separate block that mainline has no driver for. YouTube
could reach the MFC only with H.264 forced by an extension, and Firefox's V4L2 path would still
refuse this device (three blockers, §2). Forcing H.264 without the MFC moves CPU decode from VP9
(128 fps at 1080p) to H.264 (116 fps), which gains nothing.

**Optional (S): H.264 offload for mpv/GStreamer.** The kernel side is cheap. It saves CPU and
battery; smoothness is already fine (58-62 fps).

## 1. Kernel

- **Variant**: `mfc/s5p_mfc.c:1709` matches `samsung,exynos5433-mfc` to `mfc_drvdata_v8_5433`
  (`:1634`): MFC v8, one port, clocks pclk/aclk/aclk_xiu, firmware `s5p-mfc-v8.fw`. The stock kernel
  agrees: `ip_ver = <10>` (stock `arch/arm/boot/dts/exynos5433.dtsi:2181`) is `IP_VER_MFC_7A_0`,
  version 0x80 (stock `.../exynos/mfc/s5p_mfc_common.h:978-979`), `CONFIG_EXYNOS_MFC_V8=y`.
- **Codecs** (`mfc/s5p_mfc_dec.c:74-172`): H.264 (+MVC), H.263, MPEG-1/2/4, XviD, VC-1 and VP8 are
  enabled for v6 and later. HEVC (`:159`) and VP9 (`:168`) are `MFC_V10PLUS_BITS` only (v10/v12).
  The stock kernel has no VP9 anywhere in `drivers/media/platform/exynos/`. Its HEVC is a separate
  driver (`hevc/`, `hevc_fw.bin`); mainline only has `cmu_hevc` and `pd_hevc`. The decoder outputs
  NV12M/NV21M, two planes (`s5p_mfc_dec.c:46,53`). It also encodes H.264, MPEG-4, H.263 and VP8.
- **DT**: the node is already in `arm64/exynos/exynos5433.dtsi:1274-1285`: reg `0x152e0000`, SPI
  358, three `cmu_mfc` clocks, `iommus` = sysmmu_mfc_0/1, `pd_mfc`. It has no status, so it is
  enabled on our board. Compared with TM2, the board lacks
  `&cmu_mfc { assigned-clocks = <&cmu_mfc CLK_MOUT_ACLK_MFC_400_USER>; assigned-clock-parents = <&cmu_top CLK_ACLK_MFC_400>; };`
  (`exynos5433-tm2-common.dtsi:291-294`). Without it the mux can stay on oscclk
  (`clk-exynos5433.c:4177`).
- **No SysMMU and no reserved memory needed.** v8 is single-port (`regs-mfc-v8.h:124`). Without an
  IOMMU, `s5p_mfc_configure_common_memory()` (`s5p_mfc.c:1202`) preallocates 8 MiB from CMA for
  firmware and contexts, and frames come from vb2-dma-contig, i.e. the 256 MiB CMA. `IOMMU_API` is
  unset in our config (`EXYNOS_IOMMU` not set), so `iommus` is ignored. The DECON leak
  (`docs/hardware/IOMMU.md` §12) does not come into it. If EXYNOS_IOMMU returns, MFC
  attaches to its own SysMMUs, a path the driver supports (`:1263`). `memory-region` is optional in
  the binding.
- **Firmware**: linux-firmware ships `s5p-mfc-v8.fw` (WHENCE: `s5p-mfc.fw`, `-v6`, `-v6-v2`,
  `-v7`, `-v8`, `-v12`; no v10), the same file mainline uses for 5420 and 5433. It is loaded at
  first open (`s5p_mfc.c:840-850`), so a rootfs file is enough. The image ships no firmware
  package: extract the file as `image/rootfs/install-wifi.sh` does (probably `linux-firmware-other`;
  check with `pacman -F`).
- **Kconfig** (as in `arch/arm/configs/exynos_defconfig:191-208`): `MEDIA_SUPPORT=m`,
  `MEDIA_PLATFORM_SUPPORT=y`, `MEDIA_PLATFORM_DRIVERS=y`, `V4L_MEM2MEM_DRIVERS=y`,
  `VIDEO_SAMSUNG_S5P_MFC=m`. `MEDIA_SUPPORT` is unset today.

## 2. Userspace

**Firefox** compiles V4L2 in for `arm`, armv7h included (`toolkit/moz.configure:762-771`). It
would try `{h264,vp8,vp9,hevc,av1}_v4l2m2m` (`FFmpegVideoDecoder.cpp:3408-3425`; VP8/VP9 go
through bundled ffvpx unless `media.ffvpx.enabled=false`). Three separate blockers:

1. Its probe requires capture format `NV12` or `YV12` (`widget/gtk/GfxInfo.cpp:969-972`). MFC
   offers `NM12`/`NM21`, so Firefox treats V4L2 as unsupported.
2. It takes only `AV_PIX_FMT_DRM_PRIME` frames (`FFmpegVideoDecoder.cpp:238-251`), and only
   single-object NV12 (`FFmpegVideoFramePool.cpp:485-489`). Upstream FFmpeg's v4l2m2m decoders give
   plain system-memory frames (`libavcodec/v4l2_m2m_dec.c:66`, no hw_configs); DRM-PRIME output is
   a Raspberry Pi fork patch. NV12M is also two buffers per frame.
3. Hardware decoding requires EGL and DMABUF (`gfx/thebes/gfxPlatformGtk.cpp:233-249`). DMABUF is
   turned off when WebGL is not on hardware (`:208-216`). The whole path is EGL zero-copy, which is
   untested under SWGL.

**mpv** `--hwdec=v4l2m2m-copy` uses FFmpeg's `h264_v4l2m2m`, which maps NV12M to NV12
(`v4l2_fmt.c:65-66`). Frames are copied to RAM and then drawn by mpv's GPU VO, independent of
Firefox and SWGL. Each frame copies about 3 MiB out of an uncached CMA mapping. Check that Arch's
ffmpeg has the wrappers (`ffmpeg -decoders | grep v4l2m2m`).

**GStreamer** (`gst-plugins-good` v4l2): `v4l2h264dec`/`v4l2vp8dec` with dmabuf output. MFC
buffers are CMA-contiguous, so the exynos-drm import should pass without the SysMMU. Panfrost's
NV12 import is unverified.

## 3. Gain for YouTube

The 5433 MFC does not decode VP9, and VP9 is what YouTube serves with AV1 off. **Firefox gains
nothing.** A forcing extension (h264ify) gets `avc1` up to 1080p, but Firefox still decodes it on
the CPU, slightly slower than VP9. The only real win is mpv + yt-dlp on `avc1`: VP9 1080p30
decode costs about 1.3 cores today (benchmark), which would move off the CPU, minus the copy
cost.

## 4. Recommendation

- **Firefox/YouTube: no-go.** Effort L+: patch FFmpeg (DRM-PRIME), the Firefox probe and frame
  pool (NV12M), and move off SWGL. Even then it would be H.264 only.
- **mpv/GStreamer H.264: optional, S, after the GPU work.**
  1. Add the Kconfig fragment (module) and the board's `&cmu_mfc` clock parent.
  2. Put `s5p-mfc-v8.fw` in `/usr/lib/firmware/`, sha256-pinned.
  3. Check on the device: `dmesg | grep -i mfc` ("preallocated 8 MiB"), the `s5p-mfc-dec`/`-enc`
     nodes, `v4l2-ctl --list-formats-out`. Compare `ffmpeg -c:v h264_v4l2m2m -i 1080p.mp4 -f null -`
     with software decode: fps and CPU.
  4. mpv: `hwdec=v4l2m2m-copy`, `hwdec-codecs=h264,vp8,mpeg2video,mpeg4`,
     `ytdl-format=bestvideo[vcodec^=avc1][height<=1080]+bestaudio`. Measure CPU, panel fps and
     `CmaFree`.
  5. Optionally try GStreamer zero-copy to `waylandsink`.

**Risks**:

- CMA pressure. FFmpeg's defaults of 20 capture and 16 output buffers take about 60-110 MiB at
  1080p, out of 256 MiB shared with scanout. Cap them with `num_capture_buffers` and
  `num_output_buffers`.
- The MFC has never run on this board (pd_mfc, clocks, firmware timeouts). As a module it can be
  blacklisted.
- The driver is old: a 2025 Samsung series calls it outdated.
- The copy cost in `-copy` mode.

## Sources

- linux-firmware WHENCE: https://gitlab.com/kernel-firmware/linux-firmware/-/raw/main/WHENCE
- 5433 MFC patch: https://spinics.net/lists/linux-samsung-soc/msg56184.html
- Firefox V4L2 (bug 1833354): https://bugzilla.mozilla.org/show_bug.cgi?id=1833354
- Exynos MFC codec list (LibreELEC): https://libreelec.wiki/hardware/samsung-exynos
- New Exynos-MFC driver series (2025): https://patchew.org/linux/20250930040348.3702923-1-h.dewangan@samsung.com
