# Board device tree and defconfig — SM-T715 (gts28ltexx)

The validated base of the mainline 6.12 arm32 port is two files in
`src/linux-6.12`:

- `arch/arm/boot/dts/samsung/exynos5433-gts28ltexx.dts` (board file,
  includes `<arm64/exynos/exynos5433.dtsi>`);
- `arch/arm/configs/gts28ltexx_defconfig` (regenerated with
  `make savedefconfig`).

`bash kernel/kbuild-mainline.sh` builds them into `out/mainline/`.
They reproduce the "boot3" test image that booted Arch Linux on the tablet
on 2026-10-28 (8 cores, PMIC, eMMC HS200, USB ECM, watchdog, sec_log
console, ramoops; `docs/journal/PROGRESS.md`, "Arch Linux ARM tourne sur la SM-T715").
They replace the bring-up chain `-boot1/-boot2/-boot3.dts` + `-m2.dtsi`
+ `-usb.dtsi` + `-wdt.dtsi` + `-smp.dts` and the matching config
fragments.

Equivalence with the validated build (checked with `dtc -s` and the
sorted `.config`):

- DTB: identical except `/chosen/bootargs`, which no longer contains
  `nosmp`. sboot overwrites that property at boot, and the validated
  kernel ran 8 cores, so the value was never used. Two nodes
  (`firmware@207b000`, `smp-sram@207b000`) are in a different position
  in the unsorted tree. Phandles are unchanged.
- `.config`: identical plus `CGROUP_PIDS=y` and `CRYPTO_USER=y` (added
  for systemd after the validated build). `SEC_LOG_RAMCONSOLE` is gone
  because the duplicate driver it belonged to was removed. The console
  in use is `SAMSUNG_SEC_LOG_CONSOLE`
  (`drivers/soc/samsung/sec-log-console.c`).

## Board file sections → sources

| Section of `exynos5433-gts28ltexx.dts` | Content | Source |
|---|---|---|
| 1. Bootloader interface and memory | one-cell root and `&soc` ranges, DTBH `model_info-*` keys, `memory` node, pinctrl/mmc0/i2c20 aliases, `/chosen` (bootargs, simple-framebuffer and its panel supplies) | `docs/journal/PROGRESS.md` "Préparation du premier démarrage mainline" (table), the bring-up notes (boot1 conversion), "Premier démarrage de Linux mainline" (pinctrl aliases); framebuffer supplies: `docs/hardware/DT_M2.md` "Supervisor review changes" |
| 2. Reserved memory | framebuffer, sec_log ring, ramoops in the stock layout, sboot TIMA/AVC logs, ION carveouts | `docs/journal/PROGRESS.md` "Préparation du premier démarrage mainline" (table), the bring-up notes, "Premier démarrage de Linux mainline" (sec_log console, ramoops) |
| 3. Clocks and timers | XXTI 24 MHz, arch timer disabled (MCT) | `docs/journal/PROGRESS.md` "Préparation du premier démarrage mainline" (xxti row) |
| 4. CPUs and SMP | no PSCI and no `enable-method`, secure-firmware page, `sysram-ns` page | `docs/hardware/SMP_BRINGUP.md` §3.3, §5.1, §8; `docs/journal/PROGRESS.md` the bring-up notes |
| 5. Watchdog | `samsung,exynos5433-wdt` node, `CLK_PCLK_WDT_APOLLO` clock | `docs/hardware/WATCHDOG.md` |
| 6. PMIC (S2MPS13) | `&hsi2c_0`, `pmic@66`, clocks, BUCK/LDO regulators | `docs/hardware/DT_M2.md` "hsi2c bus + PMIC", "PMIC regulator mapping" |
| 7. eMMC | `&mshc_0` (HS200, no vmmc/vqmmc, CIU 800 MHz, sdr timing `<0 3>`), `sd0_*` pad drive and pull | `docs/hardware/DT_M2.md` "eMMC"; `docs/journal/PROGRESS.md` the bring-up notes (DRTO diagnosis), "Arch Linux ARM tourne sur la SM-T715" (the three causes) |
| 8. USB device port | DWC3 peripheral, USB DRD PHY clock muxes (`&cmu_fsys`), SM5703 MUIC on bit-banged I2C | `docs/hardware/DT_M2.md` "USB"; `docs/journal/PROGRESS.md` "Arch Linux ARM tourne sur la SM-T715" (USB device OK) |

Board support outside the device tree:

- `drivers/mmc/host/dw_mmc-exynos.c`: `exynos5433_drv_data` (maximum
  data timeout) and the reset of the DQS/delay-line registers that sboot
  leaves behind.
- `drivers/watchdog/s3c2410_wdt.c`: the 5433 variant.
- `arch/arm/mach-exynos/platsmp.c`, `exynos.c`, `common.h`: SMP and
  INFORM2/INFORM3.
- `drivers/soc/samsung/sec-log-console.c`: the sec_log console.

The `gts28ltexx_defconfig` header explains its non-obvious values:
`CMDLINE` + `CMDLINE_EXTEND`, `s3c2410_wdt.tmr_atboot=1`, SysRq and the
initramfs symbols.

## Milestone fragments still under test

Each milestone DTS includes the board file and its own `.dtsi`. Its
config fragment holds only that milestone's symbols and is merged on
top of the defconfig with
`bash kernel/kbuild-mainline.sh --fragment gts28ltexx_mN.config`.

| Milestone | DTS / fragment | Doc |
|---|---|---|
| M3 native display (DECON, MIC, DSI, S6E3HA2) | `exynos5433-gts28ltexx-m3.dts` + `-m3.dtsi`, `gts28ltexx_m3.config` | `docs/hardware/DISPLAY_M3.md` |
| M4 input (RMI4 touchscreen, GPIO keys) | `-m4.dts` + `-m4.dtsi`, `gts28ltexx_m4.config` | `docs/hardware/INPUT_M4.md` |
| M5 Wi-Fi / Bluetooth (BCM4358 on PCIe and UART3) | merged into the board file: `-bt.dtsi` (section 13) and `-wifi.dtsi` (section 14); drivers as modules in the defconfig | `docs/hardware/WIFI_BT_M5.md` |
| M6a audio hardware (WM1814 on hsi2c_3, I2S0; no sound card) | `-m6.dts` + `-m6.dtsi`, `gts28ltexx_m6.config` | `docs/hardware/AUDIO_M6.md` |
| M7 sensors (LSM6DS3, YAS537, Hall switch) | `-m7.dts` + `-m7.dtsi`, `gts28ltexx_m7.config` | `docs/hardware/SENSORS_M7.md` |

Thermal support (`-thermal*` files, `gts28ltexx_thermal*.config`) is
being written separately.

The bring-up files `exynos5433-gts28ltexx-boot1/-boot2/-boot3.dts`,
`-m2.dtsi`, `-usb.dtsi`, `-wdt.dtsi` and `gts28ltexx_boot3.config`
duplicate the board file. They are kept only until a parallel build
that includes `-boot3.dts` has finished.
