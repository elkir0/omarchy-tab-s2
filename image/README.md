# image/: the Omarchy root image

Builds `image/out/rootfs-omarchy.img` (raw ext4, `armv7h`) in Docker; the
Mac only moves whole files. Steps and commands: `docs/DEPLOY.md` section 8;
what the image contains and why: `docs/image/ROOTFS.md`.

| Path | What |
|---|---|
| `rootfs/` | the image build (`Dockerfile`, build steps, `overlay/`, the Hyprland dmabuf shim, `smoke-check.sh`) |
| `pkg/<name>/` | PKGBUILDs rebuilt or patched for `armv7h` (`tools/build-pkg`, `docs/image/PACKAGES.md`) |
| `tools/` | repack, package and image builds (`repack-omarchy`, `build-pkg`, `build-rootfs`) |
| `lib/` | Arch Linux ARM container helpers |
| `tests/` | `verify-rootfs.sh` (the image, read-only), off-device tests, `ondevice/` probes run over SSH (`omarchy-probe.sh`, `perf-ab.sh`, `uibench.sh`, `gpufreq.sh`, `drm-hang-watch.sh`) |
| `cache/`, `out/` | downloads, built packages and the local pacman repository, the image (git-ignored) |

The tablet's Wi-Fi NVRAM and Bluetooth patch RAM come from its dumps
(`dumps/` at the repository's root, or `$T715_DUMPS_DIR`); they go into the
image only, never into git.
