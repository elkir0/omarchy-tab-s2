# Kernel patches (SM-T715 mainline bring-up)

The kernel tree itself lives in `src/linux-6.12` (git-ignored: a
full Linux checkout, on a case-sensitive volume on macOS). Its commits are
kept here as patch series, so that the repository alone is enough to
rebuild the kernel:

| Series | Base | What |
|---|---|---|
| `patches/t715-bringup/` (24 patches) | `v6.12.114` (linux-stable) | **the daily kernel**: SoC and board support, display, input, Wi-Fi and Bluetooth, audio, sensors, battery, timer and scheduler tuning, CPU capacities; the DECON System MMU applied then reverted (`docs/hardware/IOMMU.md` §12); the GPU devfreq design (dtsi and config fragment, not included in the board); the DECON's hardware trigger unmasked only at the first flush (the "flip_done timed out" black screens) |
| `patches/t715-gpufreq-test/` (1 patch) | `t715-bringup` (`dc1fc95fb`) | test only: includes the GPU devfreq dtsi in the board with all 8 OPPs, for the validation in `docs/hardware/GPU.md` §10 |
| `patches/t715-gpu420/` (1 patch) | `t715-bringup` (`dc1fc95fb`) | candidate, **not validated**: devfreq in the board capped at 420 MHz (`docs/hardware/GPU.md` §10.11); its validation was aborted on 2026-10-29 |
| `patches/t715-g3d-abb/` (1 patch) | `t715-gpu420` (`9510f7e46`) | G3D adaptive body bias: a built-in driver whose pd_g3d notifier writes stock's no-bias level (0x80000088) to PMU BB_CON4 before the GPU domain powers on, and stock's idle value (0x8000008d) once it is off (`docs/hardware/GPU.md` §10.12); not yet checked on the device |
| `patches/t715-modem/` (16 patches) | `t715-bringup` (`ed71dc803`) | **the modem, test kernel** (`docs/hardware/MODEM.md`): CMU_CPIF clocks, the Exynos5433 MIPI-LLI driver, the Samsung 3.10 `modem_v1` import and its 6.12 port (`sec_modem_v1`), the SS333 and SPI4 device tree, the s3c64xx DMA timeout for auto chip select, and the call audio link (wm8998 ASRC2 controls, `gts28_wm1814` baseband DAI). Built with `--fragment gts28ltexx_modem.config`; the modules stay inert until `allow_hw=1` |
| `patches/t715-parity/` (6 patches) | `t715-modem` (`eb1ea00e2`) | the daily kernel before `t715-gps`: `tc300k.ko` for the Back and Recent touch keys, with no firmware path; `pwm-vibra` learns a motor driver that rests at half the period (ISA1000A); `t715-camera.ko`, both sensors through V4L2 with no ISP (`docs/hardware/CAMERA.md`), and a typo fixed in `clk-exynos5433.c` for the rear CSIS; the board's nodes. Built with `--fragment gts28ltexx_modem.config` |
| `patches/t715-gps/` (2 patches) | `t715-parity` (`5f46affb9`) | UART0 for the BCM4752 and `CONFIG_GPIO_SYSFS` for its power line, a prompt freed from `EXPERT` (docs/hardware/GPS.md); the daily kernel from 2026-10-31 to 2026-11-01 |
| `patches/t715-charger/` (5 patches) | `t715-gps` (`846440af3`) | the charger driver and the battery thermistor, the MUIC's interrupt (no pull, level trigger), an attach read again while the MUIC has not identified the cable, the charger looking again while VBUS lags the cable, and the UDC core's `connected` flag after a failed stop (docs/hardware/BATTERY.md §8); the daily kernel from 2026-11-01 to 2026-11-02 (0.9.3). Built with `--fragment gts28ltexx_modem.config` |
| `patches/t715-camera-af/` (2 patches) | `t715-charger` (`d24304ac1`) | the rear camera's DW9807 focus motor in `t715-camera.c`, ramped like `dw9807-vcm.c` and exposed as `V4L2_CID_FOCUS_ABSOLUTE` (default 500), and its bit-banged bus on `gpc2-2/3` under alias `i2c19`, which leaves the other bus numbers alone; **the daily kernel since 2026-11-02** (`out/boot-camaf/boot.img`). Built with `--fragment gts28ltexx_modem.config` and `KBUILD_OUT_DIR` given as an absolute path |
| `patches/t715-cpufreq/` (3 patches) | `t715-camera-af` (`04df00007`) | in BOOT since 2026-11-03 (`out/boot-cpufreq-daily`, `69b4e6c8bc8b`): A53 frequency scaling from 400 MHz to 1.2 GHz at this chip's voltages under schedutil, the A57s held at 1.2 GHz by a single level, BUCK2 held and BUCK3 bounded, A53 cooling at stock's thresholds. Stage 1 and the 2-hour soak passed (`docs/hardware/CPUFREQ.md` §9). The daily kernel is built with `--fragment gts28ltexx_cpufreq.config` (the modem drivers in, `cpufreq-dt` a module that udev loads); the test kernels with `--fragment gts28ltexx_cpufreq_test.config` (no modem drivers, `cpufreq-dt` blacklisted and loaded by hand) |
| `patches/t715-power/` (4 patches) | `t715-cpufreq` (`12d27cc6a`) | **the daily kernel since 2026-11-05** (`#6`, `out/boot-power6/boot.img`): the Exynos5433 hot-unplug of the A57 cores (the vendor kernel's handshake: HOTPLUG flag, local power off, `SMC_CMD_SHUTDOWN`), which `t715-keys` uses with the screen off; the G3D block clocked from `aclk_g3d_400` with a `SYSREG_G3D` syscon; panfrost's `GPU_PM_RT_CLK_OFF` for the 5433, so that pd_g3d powers off while the GPU idles, with the NoC timeout set again at each power-on (`rt_clk_off`, on by default); brcmfmac's `ps_timeout`, `ps_mode` and `bcn_li_dtim` parameters, whose defaults change nothing (the root sets `ps_timeout=100`). Measured with the screen off: 856 to 754 mW (`docs/hardware/BATTERY.md` sections 10 and 11). Built with `--fragment gts28ltexx_cpufreq.config` |
| `patches/t715-camera-mc/` (4 patches) | `t715-power` (`630bec1c7`) | the cameras through the media controller, for libcamera: `t715-sensor.ko`, the S5K4H5 and S5K6B2 as V4L2 subdevices (their rails, reset, MCLK, the `<firmware-name>-m<N>.seq` mode tables, exposure, gain, blanking, flips and orientation, the DW9807 as a lens subdevice); `t715-camera.ko` reduced to the capture side, one media device per camera with the sensor found through the device tree graph; the board's sensor nodes and endpoints; `VIDEO_T715_SENSOR` and the dma-buf heaps of libcamera's software ISP. Tested on the device over `t715-cpufreq` (`out/boot-camera-mc`); over `t715-power` it is `#7`, built but not booted yet. Built with `--fragment gts28ltexx_cpufreq.config` |
| `patches/t715-camtest/` | `t715-parity` at `7d34675d8`, before the cameras | test only, in RECOVERY: the debugfs bring-up modules `t715-cam-probe` and `t715-cam-capture`, each camera step by hand; its copy of `t715-camera.c` is older than `t715-parity`'s. Built with `--fragment gts28ltexx_camtest.config` |

## The release kernel

The 1.0 releases run `v6.12.114` plus nine series in this order, built with the cpufreq
fragment and a fixed identity, so that anyone can rebuild the release's kernel from this
repository:

```bash
git clone --branch v6.12.114 --depth 1 https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git src/linux-6.12
```

```bash
git -C src/linux-6.12 switch -c t715-camera-mc
```

```bash
for s in bringup modem parity gps charger camera-af cpufreq power camera-mc; do git -C src/linux-6.12 am "$PWD"/kernel/patches/t715-$s/*.patch; done
```

```bash
KBUILD_SKIP_ARM64=1 KBUILD_BUILD_TIMESTAMP="Thu Nov  5 12:00:00 UTC 2026" KBUILD_BUILD_USER=omarchy-tab-s2 KBUILD_BUILD_HOST=release KBUILD_BUILD_VERSION=1 bash kernel/kbuild-mainline.sh --fragment gts28ltexx_cpufreq.config
```

For 1.0 Beta 1 this gives a zImage with sha256 `f6156169f13c98a3...`, the DTB `13aaf64b7e1c8b2c...`
and the same 96 module files as the release: two builds, one from these patches and one from
the development tree, were identical byte for byte.

Recreate the tree (the `t715-bringup` branch is what `kernel/kbuild-mainline.sh`
builds):

```bash
git clone --branch v6.12.114 --depth 1 https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git src/linux-6.12
```

```bash
git -C src/linux-6.12 switch -c t715-bringup
```

```bash
git -C src/linux-6.12 am "$PWD"/kernel/patches/t715-bringup/*.patch
```

The side branches start from a commit of that branch, for example:

```bash
git -C src/linux-6.12 switch -c t715-g3d-abb t715-bringup
```

```bash
git -C src/linux-6.12 am "$PWD"/kernel/patches/t715-g3d-abb/*.patch
```

The tree must sit on a case-sensitive file system: on macOS, `src/` is
the mount point of a case-sensitive APFS volume, or a link to one
(`docs/DEPLOY.md` 3.2; `T715_KERNEL_DIR` overrides the path). Build in
Docker:

```bash
bash kernel/kbuild-mainline.sh            # -> out/mainline/{zImage,*.dtb,modules.tar.xz}
```

Then the initramfs and the boot images (`boot/README.md`, `docs/DEPLOY.md`
7. and 11.7), and see `docs/journal/HANDOVER.md` for what each commit is.

Refresh the series after new kernel commits (from the repository root):

```bash
rm -f kernel/patches/t715-bringup/*.patch && git -C src/linux-6.12 format-patch -q --no-signature -o "$PWD/kernel/patches/t715-bringup" v6.12.114..t715-bringup
```

and a side branch against its base, for example:

```bash
rm -f kernel/patches/t715-g3d-abb/*.patch && git -C src/linux-6.12 format-patch -q --no-signature -o "$PWD/kernel/patches/t715-g3d-abb" t715-bringup..t715-g3d-abb
```

The daily line's tip (`t715-power`, from `t715-cpufreq`):

```bash
rm -f kernel/patches/t715-power/*.patch && git -C src/linux-6.12 format-patch -q --zero-commit -o "$PWD/kernel/patches/t715-power" t715-cpufreq..t715-power
```

and the cameras on top of it (`t715-camera-mc`, from `t715-power`):

```bash
rm -f kernel/patches/t715-camera-mc/*.patch && git -C src/linux-6.12 format-patch -q --zero-commit -o "$PWD/kernel/patches/t715-camera-mc" t715-power..t715-camera-mc
```

Then give each patch the published identity and a noon date (`docs/PRIVACY.md`).

The modem series (`t715-modem`, from `t715-bringup`):

```bash
rm -f kernel/patches/t715-modem/*.patch && git -C src/linux-6.12 format-patch -q --no-signature -o "$PWD/kernel/patches/t715-modem" t715-bringup..t715-modem
```
