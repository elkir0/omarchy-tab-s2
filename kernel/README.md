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
| `patches/t715-power-gpu/` (3 patches) | `t715-power` (`630bec1c7`) | the daily kernel from 2026-11-07 (`#7`, in BOOT at 10:28) to 2026-11-08, when `t715-turbo` replaced it: the G3D body bias driver of `docs/hardware/GPU.md` §10.12, checked on the tablet; `mout_aclk_g3d_400` gets `CLK_SET_RATE_NO_REPARENT`, so the GPU stays on the bus clock while devfreq scales it; GPU devfreq on that bus clock — `aclk_g3d_400` at its nominal 400 MHz divided in CMU_G3D, OPPs 100/133/200/400 MHz at this chip's stock G3D voltages + 37.5 mV, the A53 sensor's 86 °C trip at 100 MHz (`docs/hardware/GPU.md` §10.13; glmark2 about +50 % against the former fixed 266 MHz, no hang in 25 minutes). Built with `--fragment gts28ltexx_cpufreq.config` and `KBUILD_BUILD_VERSION=7`. The series applies unchanged on top of `t715-camera-mc` in the 1.0.1 release kernel |
| `patches/t715-turbo/` (8 patches) | `t715-power-gpu` (`363385ef3`) | the daily kernel on 2026-11-08 (`#8`, in BOOT from 01:15 to 16:43, when `#9` with `t715-sdcard` replaced it), qualified on the tablet on 2026-11-07: the GPU back on the G3D PLL at the vendor's eight Mali levels, 160 to 700 MHz at this chip's stock voltages + 37.5 mV, behind a parking mux (`mout_g3d_pll` on OSCCLK whenever the PLL is off or relocking, the vendor's own P/M/S); the A57s in the vendor kernel's body bias (level 8) and EMA 3 by a new built-in driver (`exynos5433-atlas-asv`), A57 scaling from 800 MHz to 1.5 GHz at this chip's stock voltages (+ 37.5 mV above 1.2 GHz), BUCK2 bounded 987.5 mV to 1.175 V, A57 cooling maps on both zones (`docs/hardware/GPU.md` §10.14, `docs/hardware/CPUFREQ.md` §9 stage 2); and a fix in `arch_topology`, whose capacity product overflowed 32 bits on ARM32 once the A57s reached 1.5 GHz (the A53s became the big cores for the scheduler); and the G3D body bias driver's routine transitions logged at debug level, since pd_g3d powers off several times a second while the GPU works (9800 times in the soak). Built with `--fragment gts28ltexx_turbo_test.config` (test, image mode, userspace governor); `gts28ltexx_turbo_soak.config` builds the daily candidate (release `6.12.114-turbo`), which soaked 2 hours on 2026-11-07 and passed (`docs/hardware/CPUFREQ.md` §9); BOOT's `#8` is the same tree built with `--fragment gts28ltexx_cpufreq.config` and `KBUILD_BUILD_VERSION=8` (release `6.12.114 #8`). The series applies unchanged on top of `t715-camera-mc` in the 1.0.1 release kernel |
| `patches/t715-camera-mc/` (4 patches) | `t715-power` (`630bec1c7`) | the cameras through the media controller, for libcamera: `t715-sensor.ko`, the S5K4H5 and S5K6B2 as V4L2 subdevices (their rails, reset, MCLK, the `<firmware-name>-m<N>.seq` mode tables, exposure, gain, blanking, flips and orientation, the DW9807 as a lens subdevice); `t715-camera.ko` reduced to the capture side, one media device per camera with the sensor found through the device tree graph; the board's sensor nodes and endpoints; `VIDEO_T715_SENSOR` and the dma-buf heaps of libcamera's software ISP. Tested on the device over `t715-cpufreq` (`out/boot-camera-mc`). Over `t715-power` it is the 1.0 Beta 1 release kernel (`#1`, the fixed identity below), booted on the reference tablet from RECOVERY on 2026-11-05: both cameras, the modem's switch, Wi-Fi and Bluetooth. Built with `--fragment gts28ltexx_cpufreq.config` |
| `patches/t715-linkpm/` (2 patches) | `t715-camera-mc` | **optional, not in the 1.0 Beta 1 kernel**: the SS333's link power management of the 3.10 kernel, behind `sec_modem_v1`'s `pm_mode` parameter (`lockon`, the default, unchanged; `fsm`, the stock state machine, which lets the CP release the MIPI-LLI link and sleep), and the LLI driver's link PM callbacks (`research/modem/LINK-PM.md`, `docs/hardware/MODEM.md` §5.5). Written on `t715-power` and validated there without a SIM (20 of 20 AP wakes, 30 minutes of soak, 10 CP power-offs, no failure); it applies unchanged on `t715-camera-mc` and builds with `--fragment gts28ltexx_cpufreq.config` and the release's fixed identity into the release's zImage and DTB, byte for byte: only `sec_modem_v1.ko` and `exynos5433-mipi-lli.ko` differ (same vermagic). The power saved is not measured, calls and SMS are untested |
| `patches/t715-sdcard/` (2 patches) | the 1.0.1 release tree (`t715-release-1.0.1`, that is `t715-turbo` applied after `t715-camera-mc`) | the microSD slot on `mshc_2` — the node, its pins and pads, the two slot rails renamed so the eMMC's host stops taking them, the `mmc1` alias (`docs/hardware/SDCARD.md`) — and vfat, exFAT and their code pages built in. **In the 1.0.2, 1.0.3 and 1.0.4 release kernels**; **the daily kernel on 2026-11-08** (`#9`, in BOOT from 16:43 to 19:27, when `#10` with `t715-bluetooth` replaced it: the 1.0.1 release tree plus this series, so the daily line has the cameras' media controller again). Built with `--fragment gts28ltexx_cpufreq.config` and `KBUILD_BUILD_VERSION=9` |
| `patches/t715-bluetooth/` (2 patches) | `t715-sdcard` | the Bluetooth UART at 3 Mbaud — `&cmu_aud` moves `mout_aud_pll_user` to the audio PLL as TM2 does (`exynos5433-tm2-common.dtsi`), `sclk_aud_uart` gets the PLL undivided and the block's other dividers go to /8, `max-speed = <3000000>` (`docs/hardware/WIFI_BT_M5.md` §7.8) — and `CONFIG_UHID` built in, which BlueZ needs to create the input device of any Bluetooth keyboard or mouse (no kernel up to here had it). **In the 1.0.2, 1.0.3 and 1.0.4 release kernels**; **the daily kernel on 2026-11-08 and 2026-11-09** (`#10`: the `#9` tree plus this series, tested from RECOVERY, in BOOT until `#11` with `t715-wifi-recovery` replaced it). Built with `--fragment gts28ltexx_cpufreq.config` and `KBUILD_BUILD_VERSION=10` |
| `patches/t715-wifi-recovery/` (4 patches) | `t715-bluetooth` | a failed Wi-Fi start brought back without a reboot (`docs/hardware/WIFI_BT_M5.md` §7.9): the 5433's PCIe PHY powered down in its exit and up in its init as the vendor kernel does (bit 3 of PHY register 0x55, bit 4 of 0x21, 100 µs apart), without which a failed start left the link unusable until the SoC reset; `wlan_reg_on` (WLAN_EN) no longer always-on, so unbinding the PCIe host cuts it and binding it powers the chip up again; PERST# and the LTSSM off before the power goes and the vendor's gpr3-6 pulse before PERST# is released, with a read-only `pci_exynos.wifi_power_cycle` (`Y`) that `t715-wifi-guard` checks before it power-cycles the chip; brcmfmac guarded against a chip that stops answering (a ring write index past the ring's depth, which made it oops, a mailbox status of all ones, the console's write index). **The daily kernel since 2026-11-09** (`#11`: the `#10` tree plus this series, tested from RECOVERY, with `t715-wifi-guard` in the root). **In the 1.0.3 and 1.0.4 release kernels.** Built with `--fragment gts28ltexx_cpufreq.config` and `KBUILD_BUILD_VERSION=11` |
| `patches/t715-sleep/` (7 patches) | `t715-wifi-recovery` | **the daily kernel on 2026-11-10 and 2026-11-11** (`#16`, the `#11` tree plus this series, tested from RECOVERY, in BOOT until `#17` with `t715-radio-fixes` replaced it; **in the 1.0.4 release kernel**): the Exynos5433's suspend to RAM, registered only when the command line asks (`exynos5433_sleep=on`, or `dryrun`: the whole sleep path but the secure call); GPIO_FINGER left to the secure world and the AUD pin controller's bus clock; the AUD trace bus out of the LPI handshake; the AUD clock gates opened before the domain powers off; the arm switch (`/sys/module/exynos5433_sleep/parameters/arm`: a kernel booted with `exynos5433_sleep=dryrun` sleeps for real only when armed, one sleep at a time) and the power-down state of eight PMIC and power-control pins and the PCIe link's gpr3 pins (WRSTBI among them: sboot leaves every pin's power-down state at 0, which would drive WRSTBI low in sleep and reset the PMIC's bucks); the defconfig's built-in command line gets `exynos5433_sleep=dryrun`; and samsung-dsim's DSI interrupt handled in hard interrupt context, a transfer whose interrupt is late finished by polling `DSIM_INTSRC` — the black screen at a key wake fixed (the panel's first command timed out and the screen stayed black until the display was switched off and on). The private branch is `t715-sleep-daily`; the tree of `t715-wifi-recovery` is the 1.0.3 release kernel's, so the series applies on either, and applied it gives the tree of the daily `#16` exactly (checked). Built with `--fragment gts28ltexx_cpufreq.config`, the daily `#16` with `KBUILD_BUILD_VERSION=16` |
| `patches/t715-radio-fixes/` (2 patches) | `t715-sleep` | **the daily kernel since 2026-11-11** (`#17`, the `#16` tree plus this series, tested from RECOVERY; **in the 1.0.4 release kernel**): upstream's fix of a use-after-free in `hci_uart_unregister_device()` (commit 21139b3ac62a, not in 6.12.114, applied unchanged with its author's name and date), which freed the `hci_dev` before closing the serdev port, so that a Bluetooth unbind while the controller still talked oopsed the kernel; and brcmfmac's remove path cancelling `bus_reset` only once `brcmf_bus_started()` set it up, where 6.12.114 warned and tainted the kernel at every Wi-Fi start whose firmware halted during the setup (`docs/hardware/WIFI_BT_M5.md` §7.10). The private branch is `t715-radio-fixes`, on `t715-sleep-daily`; applied on `t715-sleep` the series gives the tree of the daily `#17` exactly (checked). Built with `--fragment gts28ltexx_cpufreq.config`, the daily `#17` with `KBUILD_BUILD_VERSION=17` |
| `patches/t715-camtest/` | `t715-parity` at `7d34675d8`, before the cameras | test only, in RECOVERY: the debugfs bring-up modules `t715-cam-probe` and `t715-cam-capture`, each camera step by hand; its copy of `t715-camera.c` is older than `t715-parity`'s. Built with `--fragment gts28ltexx_camtest.config` |

## The release kernel

The 1.0.4 release runs `v6.12.114` plus sixteen series in this order, built with the cpufreq
fragment and a fixed identity, so that anyone can rebuild the release's kernel from this
repository:

```bash
git clone --branch v6.12.114 --depth 1 https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git src/linux-6.12
```

```bash
git -C src/linux-6.12 switch -c t715-release-1.0.4
```

```bash
for s in bringup modem parity gps charger camera-af cpufreq power camera-mc power-gpu turbo sdcard bluetooth wifi-recovery sleep radio-fixes; do git -C src/linux-6.12 am "$PWD"/kernel/patches/t715-$s/*.patch; done
```

```bash
KBUILD_SKIP_ARM64=1 KBUILD_BUILD_TIMESTAMP="Wed Nov 11 12:00:00 UTC 2026" KBUILD_BUILD_USER=omarchy-tab-s2 KBUILD_BUILD_HOST=release KBUILD_BUILD_VERSION=1 bash kernel/kbuild-mainline.sh --fragment gts28ltexx_cpufreq.config
```

For 1.0.4 this gives a zImage with sha256 `e4e105daf3c4f97e...`, the DTB `d7830adc83e0d169...`
and 95 module files: two builds from these patches, in two trees, were identical byte for
byte, and the release tree is the daily kernel `#17`'s tree.

1.0.3 ran fourteen series, the same loop without `sleep radio-fixes`, built with the same fixed
identity (`KBUILD_BUILD_TIMESTAMP="Mon Nov  9 12:00:00 UTC 2026"`): its zImage has sha256
`6cf7b3e69a6bee00...`, its DTB `793c3e74e7d71eaf...` and its 95 module files; two builds from
these patches, in two trees, were identical byte for byte, and the release tree is the daily
kernel `#11`'s tree.

1.0.2 ran thirteen series, the same loop without `wifi-recovery sleep radio-fixes`, built with
the same fixed identity (`KBUILD_BUILD_TIMESTAMP="Sun Nov  8 12:00:00 UTC 2026"`): its zImage
has sha256 `76753352b37e7041...`, its DTB `aeb8db71e6da51c6...` and its 95 module files; two
builds from these patches, in two trees, were identical byte for byte.

1.0.1 ran eleven series, the same loop without `sdcard bluetooth wifi-recovery sleep
radio-fixes`, built with the same fixed identity (`KBUILD_BUILD_TIMESTAMP="Sun Nov  8 12:00:00 UTC 2026"`,
the same date as 1.0.2): its zImage has sha256 `c7f8b5095ec78d27...`, its DTB
`61ef5b69d15216ce...` and its 95 module files; two builds from these patches, in two trees,
were identical byte for byte.

1.0 Beta 1 ran nine series, the same loop without `power-gpu turbo sdcard bluetooth
wifi-recovery sleep radio-fixes`, built with `KBUILD_BUILD_TIMESTAMP="Thu Nov  5 12:00:00 UTC 2026"`: its zImage has sha256
`f6156169f13c98a3...`, its DTB `13aaf64b7e1c8b2c...` and its 96 module files; two builds, one
from these patches and one from the development tree, were identical byte for byte.

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

and the modem's link PM on top of it, optional (`t715-linkpm`, from `t715-camera-mc`):

```bash
rm -f kernel/patches/t715-linkpm/*.patch && git -C src/linux-6.12 format-patch -q --zero-commit -o "$PWD/kernel/patches/t715-linkpm" t715-camera-mc..t715-linkpm
```

and the microSD slot on the 1.0.1 release tree (`t715-sdcard`, from `t715-release-1.0.1`):

```bash
rm -f kernel/patches/t715-sdcard/*.patch && git -C src/linux-6.12 format-patch -q --zero-commit -o "$PWD/kernel/patches/t715-sdcard" t715-release-1.0.1..t715-sdcard
```

and the Bluetooth UART at 3 Mbaud on top of it (`t715-bluetooth`, from `t715-sdcard`):

```bash
rm -f kernel/patches/t715-bluetooth/*.patch && git -C src/linux-6.12 format-patch -q --zero-commit -o "$PWD/kernel/patches/t715-bluetooth" t715-sdcard..t715-bluetooth
```

and the Wi-Fi's power cycle on top of it (`t715-wifi-recovery`, from `t715-bluetooth`):

```bash
rm -f kernel/patches/t715-wifi-recovery/*.patch && git -C src/linux-6.12 format-patch -q --zero-commit -o "$PWD/kernel/patches/t715-wifi-recovery" t715-bluetooth..t715-wifi-recovery
```

and the suspend to RAM on top of it (`t715-sleep`, from `t715-wifi-recovery`):

```bash
rm -f kernel/patches/t715-sleep/*.patch && git -C src/linux-6.12 format-patch -q --zero-commit -o "$PWD/kernel/patches/t715-sleep" t715-wifi-recovery..t715-sleep-daily
```

and the two radio fixes on top of it (`t715-radio-fixes`, from `t715-sleep-daily`):

```bash
rm -f kernel/patches/t715-radio-fixes/*.patch && git -C src/linux-6.12 format-patch -q --zero-commit -o "$PWD/kernel/patches/t715-radio-fixes" t715-sleep-daily..t715-radio-fixes
```

Then give each patch the published identity and a noon date (`docs/PRIVACY.md`), except
an upstream patch carried unchanged (`t715-radio-fixes`' first), which keeps its author's
name and date.

The modem series (`t715-modem`, from `t715-bringup`):

```bash
rm -f kernel/patches/t715-modem/*.patch && git -C src/linux-6.12 format-patch -q --no-signature -o "$PWD/kernel/patches/t715-modem" t715-bringup..t715-modem
```
