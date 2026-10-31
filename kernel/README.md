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
| `patches/t715-gps/` (2 patches) | `t715-parity` (`5f46affb9`) | UART0 for the BCM4752 and `CONFIG_GPIO_SYSFS` for its power line, a prompt freed from `EXPERT` (docs/hardware/GPS.md); **the daily kernel since 2026-10-31** |
| `patches/t715-camtest/` | `t715-parity` at `7d34675d8`, before the cameras | test only, in RECOVERY: the debugfs bring-up modules `t715-cam-probe` and `t715-cam-capture`, each camera step by hand; its copy of `t715-camera.c` is older than `t715-parity`'s. Built with `--fragment gts28ltexx_camtest.config` |

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

The modem series (`t715-modem`, from `t715-bringup`):

```bash
rm -f kernel/patches/t715-modem/*.patch && git -C src/linux-6.12 format-patch -q --no-signature -o "$PWD/kernel/patches/t715-modem" t715-bringup..t715-modem
```
