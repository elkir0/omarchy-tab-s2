# GPU (Mali-T760 MP6, panfrost) — SM-T715 (Exynos 5433), mainline 6.12 arm32

Build-tested only (no device interaction). This milestone turns on the
SoC's Mali-T760 with the mainline `panfrost` driver so that Mesa (panfrost +
kmsro on the Exynos display) can give phoc and the clients EGL/GLES instead
of the pixman/llvmpipe fallback.

**Power policy: Linux changes neither the GPU voltage nor the GPU clock.**
There is no OPP table, so no devfreq; the GPU runs at whatever rate the G3D
clock unit already has, on BUCK6 at whatever voltage the bootloader left.
Whether that pair is inside the stock envelope is checked on the first boot
with the table of section 3.3, before any GPU work is submitted.

Path abbreviations:

* `soc-dtsi` = `src/linux-6.12/arch/arm64/boot/dts/exynos/exynos5433.dtsi`
* `board` = `src/linux-6.12/arch/arm/boot/dts/samsung/exynos5433-gts28ltexx.dts`
* `pf/` = `src/linux-6.12/drivers/gpu/drm/panfrost/`
* `live_fdt` = `dumps/live_fdt.dts` (the running stock tree)
* `stock/` = `src/kernel_universal5433/`
* `mali/` = `stock/drivers/gpu/arm/t7xx/r22p0/platform/exynos/` (the Mali
  driver selected by the LineageOS defconfig: `CONFIG_MALI_R22P0=y`,
  `stock/arch/arm/configs/lineage_gts28ltexx_defconfig:2776`)
* `asv.h` = `stock/arch/arm/mach-exynos/include/mach/asv-exynos5433.h`

---

## 1. Files

| file (under `src/linux-6.12/`) | what |
|---|---|
| `arch/arm/boot/dts/samsung/exynos5433-gts28ltexx-gpu.dtsi` | `&gpu`: `mali-supply = <&buck6_reg>`, OPP table and `operating-points-v2` deleted, `status = "okay"` |
| `arch/arm/boot/dts/samsung/exynos5433-gts28ltexx-gpu.dts` | board file + the GPU dtsi |
| `arch/arm/configs/gts28ltexx_gpu.config` | `CONFIG_DRM_PANFROST=y` |
| `arch/arm/boot/dts/samsung/Makefile` | one line: `exynos5433-gts28ltexx-gpu.dtb` |

No other file is touched; in particular the thermal dtsi (where `tmu_g3d`
stays disabled) and the Phosh software-rendering drop-in are unchanged.

## 2. Values and sources

### 2.1 Device tree

| property | value in the GPU dtb | mainline source | stock source |
|---|---|---|---|
| compatible | `samsung,exynos5433-mali`, `arm,mali-t760` | `soc-dtsi:1187`; panfrost matches `arm,mali-t760` (`pf/panfrost_drv.c:812`, generic `default_data`, one supply `mali`, one optional power domain, `:733-739`) | `live_fdt:1832` (`arm,mali`, kbase) |
| reg | `0x14ac0000 0x5000` | `soc-dtsi:1188` | `live_fdt:1831`, identical |
| interrupts | SPI 282 job, 283 mmu, 281 gpu, level-high | `soc-dtsi:1189-1192` | `live_fdt:1836`: 0x11a, 0x11b, 0x119 = 282, 283, 281, same order |
| clocks | `<&cmu_g3d CLK_ACLK_G3D>` (`core`) | `soc-dtsi:1193-1194` | `live_fdt:1833-1834`: the GPU clock is `aclk_g3d` (stock id 1000), read and set through `fout_g3d_pll`/`mout_g3d_pll` by `mali/gpu_exynos5433.c:351-459` |
| power-domains | `<&pd_g3d>` (0x105c4060) | `soc-dtsi:1195`, `:693-698` | `live_fdt:1835` → `pd-g3d@105c4060` (`live_fdt:29-35`) |
| **mali-supply** | **`<&buck6_reg>`** (added) | binding allows it (`Documentation/devicetree/bindings/gpu/arm,mali-midgard.yaml`, `mali-supply: true`) | BUCK6 is `vdd_g3d` (`live_fdt:2399-2407`); the stock Mali code uses exactly that regulator (`mali/gpu_exynos5433.c:683`, `regulator_get(NULL, "vdd_g3d")`) |
| **operating-points-v2 / opp-table** | **deleted** | `soc-dtsi:1196`, `:1199-1234` | section 3.2 |
| status | `okay` | `disabled` in `soc-dtsi:1197` | — |

Not added: `assigned-clocks` (no clock is reprogrammed), `#cooling-cells`
(no devfreq, nothing to cool with), `dynamic-power-coefficient`, `resets`
(none exists for G3D in mainline), `dma-coherent` (the stock tree has no
coherency either). The BUCK6 node itself is unchanged (`board`, PMIC section:
600 000–1 500 000 µV window, always-on, boot-on).

### 2.2 Kernel configuration

| symbol | defconfig | with `gts28ltexx_gpu.config` | why |
|---|---|---|---|
| `DRM_PANFROST` | m | **y** | the rootfs installs no modules (`04_arch_rootfs` has no `/lib/modules` step) |
| `DRM_SCHED`, `DEVFREQ_GOV_SIMPLE_ONDEMAND` | m | y | selected by panfrost (`pf/Kconfig`) |
| `DRM_GEM_SHMEM_HELPER`, `IOMMU_IO_PGTABLE_LPAE`, `PM_DEVFREQ` | y | y | selected by panfrost, already on |
| `DRM`, `ARM_LPAE`, `PM_GENERIC_DOMAINS`, `EXYNOS_PM_DOMAINS`, `REGULATOR_S2MPS11` | y | y | already on |
| `DEVFREQ_THERMAL` | not set | not set | no devfreq, no GPU cooling device |

The `.config` of the GPU build differs from a plain `gts28ltexx_defconfig`
build only in those three m→y lines (checked by diffing both configs).

## 3. Voltage and frequency

### 3.1 What this tree does to the GPU clock and rail: nothing

**Voltage.** panfrost only touches its supply through the OPP core when the
device has an OPP table (`pf/panfrost_device.c:225-230`, "OPP will handle
regulators"). Without one:

1. `panfrost_devfreq_init()` attaches BUCK6 to an (empty) OPP table
   (`pf/panfrost_devfreq.c:140-148`); that only stores the regulator handle
   (`drivers/opp/core.c:2183-2236`), it sets no voltage;
2. `devm_pm_opp_of_add_table()` finds neither `operating-points-v2` nor
   `operating-points` and returns `-ENODEV` (`drivers/opp/of.c:1087-1090`),
   which panfrost treats as "no devfreq" and returns 0
   (`pf/panfrost_devfreq.c:151-157`);
3. `panfrost_regulator_init()` then gets BUCK6 and calls
   `regulator_bulk_enable()` (`pf/panfrost_device.c:86-117`). BUCK6 is
   always-on, so this only adds a use count; no consumer ever requests a
   voltage.

The regulator core itself only moves BUCK6 if its voltage is outside the
board window 600 000–1 500 000 µV at registration
(`drivers/regulator/core.c:1273-1325`); that is the validated board file's
behaviour, unchanged here.

**Frequency.** The GPU clock is `aclk_g3d` = `div_aclk_g3d` (DIV_G3D[2:0])
of `mout_aclk_g3d_400`, which selects `mout_g3d_pll` (OSCCLK 24 MHz or the
G3D PLL) or CMU_TOP's `aclk_g3d_400` (`drivers/clk/samsung/clk-exynos5433.c:3297-3340`).
Nothing in this tree sets any of them:

* no devfreq, so no `clk_set_rate()` from panfrost; `panfrost_clk_init()`
  only reads the rate, prints it and enables the clock
  (`pf/panfrost_device.c:44-51`);
* no `assigned-clocks` on `cmu_g3d` (`soc-dtsi:519-527`, `board`);
* `cmu_g3d` sits inside `pd_g3d`. At its probe the domain is powered on
  (`drivers/base/platform.c:1371`, `drivers/pmdomain/core.c:3008`), the
  clocks are registered from the registers as found; every runtime suspend
  saves the registers and every resume writes them back
  (`drivers/clk/samsung/clk-exynos-arm64.c:259-318`, register list
  `clk-exynos5433.c:3273-3290`). Since nothing changes them in between,
  they keep the values found at the first probe. The driver's only write of
  its own is `MUX_SEL_G3D = 0` (both muxes to their first parent) after the
  save, just before a power-down (`clk-exynos5433.c:3292-3294`), undone by
  the next restore.

So the GPU runs at the rate the G3D clock unit had when Linux first saw it:
the bootloader's setting, or the register reset values if the domain was
off. panfrost prints that rate at probe (section 5).

**Consequence.** Linux never raises the GPU voltage and never raises the GPU
clock. The worst case is a bootloader pair whose clock is too fast for its
voltage: timing failures (job faults, GPU hangs, at worst a bus hang and a
watchdog reset), not electrical overstress. Section 3.3 tells, on the first
boot, whether the pair is inside the stock envelope.

### 3.2 Why the SoC OPP table is removed

The `soc-dtsi` table is the stock Mali driver's **default** table
(`mali/gpu_exynos5433.c:46-55`, same frequencies and voltages; mainline lists
267 MHz where stock says 266). Stock does not run it as is: at boot it
replaces every voltage by the chip's ASV value (`get_match_volt(ID_G3D, …)`,
`mali/gpu_dvfs_governor.c:263-284`), adds 37 500 µV while the GPU is "cold"
(≤ 19 °C, `mali/gpu_notifier.c:113-116`, `mali/mali_kbase_platform.c:256-257`,
`stock/arch/arm/mach-exynos/include/mach/tmu.h:22`), and switches the adaptive
body bias per level on table versions 2 and 3 (`asv.h:258`, `:344`, value
0x8; bypass on versions 0-1, `asv.h:81`, `:170`).

Stock G3D voltages, highest over the 16 ASV groups (always the ASV0
column) for each table version (`cal_get_volt()`: version 0 → `_v0`, 1-4 →
`_v1`, 5 → `_v2`, 6-8 → `_v3`; `stock/arch/arm/mach-exynos/asv-exynos5433_cal.c:298-334`):

| MHz | v0 (`asv.h:433-442`) | v1 (`:538-546`) | v2 (`:642-651`) | v3 (`:748-757`) | **envelope** | mainline OPP / stock default |
|---|---|---|---|---|---|---|
| 160 | 1 000 000 | 887 500 | 887 500 | 887 500 | **1 000 000** | 1 000 000 |
| 266 | 1 000 000 | 912 500 | 900 000 | 900 000 | **1 000 000** | 1 000 000 (267 MHz) |
| 350 | 1 000 000 | 937 500 | 925 000 | 925 000 | **1 000 000** | 1 025 000 |
| 420 | 1 025 000 | 962 500 | 950 000 | 950 000 | **1 025 000** | 1 025 000 |
| 500 | 1 050 000 | 987 500 | 962 500 | 975 000 | **1 050 000** | 1 075 000 |
| 550 | 1 075 000 | 1 025 000 | 1 000 000 | 1 000 000 | **1 075 000** | 1 125 000 |
| 600 | 1 100 000 | 1 075 000 | 1 050 000 | 1 050 000 | **1 100 000** | 1 150 000 |
| 700 | 1 125 000 | 1 162 500 | 1 137 500 | 1 150 000 | **1 162 500** | **1 150 000 (below)** |

(µV. Table version 0 always uses group 0, `asv-exynos5433_cal.c:204-205`.
Stock's declared G3D maximum, also its fallback for an unmatched frequency,
is 1 162 500 µV: `G3D_MAX_VOLT`, `stock/arch/arm/mach-exynos/asv-exynos5433.c:39`,
`asv-exynos.c:121-122`; only the cold margin goes beyond it.)

Reasons not to keep it:

* at 700 MHz it is below the slowest group of table version 1;
* everywhere else it is above the envelope, but it would make panfrost
  **set** BUCK6 and **reprogram the G3D PLL** through the clock framework
  (`pf/panfrost_devfreq.c:184`, `dev_pm_opp_set_opp()`), i.e. change the
  boot state — the opposite of the policy;
* mainline has no Exynos 5433 ASV support, and this chip's ASV group and
  table version are unknown (`docs/hardware/THERMAL.md` section 8.1), so no
  chip-specific table can be built either.

A single-OPP variant is the fallback if section 3.3 rules the boot pair
out or finds it unusably slow (OSCCLK). The candidate, not implemented
here: **266 MHz** — the stock start and minimum clock
(`mali/gpu_exynos5433.c:69-70`), a G3D PLL rate with the same P/M/S in both
kernels (stock `clk-exynos5433.c:3224`, mainline `clk-exynos5433.c:779`:
6/532/3) — at **1 000 000 µV**, the envelope at 266 MHz for every group and
table version and the stock default; 1 037 500 µV if cold operation
(≤ 19 °C) must be covered like stock. Both stay below the 1 162 500 µV
`G3D_MAX_VOLT`. That variant does change the boot state (panfrost
would set BUCK6 and the PLL at probe), so it needs its own review.

### 3.3 First-boot check of the boot pair

Two numbers, both available before any GPU job runs:

* **F**: `panfrost 14ac0000.gpu: clock rate = <F>` in `dmesg`;
* **V**: `cat $(dirname $(grep -lx vdd_g3d /sys/class/regulator/*/name))/microvolts`
  (BUCK6's B6OUT register; works on the current kernel too, before the
  GPU kernel is ever booted).

Find the first row of the table below whose frequency is ≥ F:

| F ≤ | V must be ≥ (envelope) |
|---|---|
| 160 MHz (includes OSCCLK, 24 MHz or a division of it) | 1 000 000 µV |
| 266 MHz | 1 000 000 µV |
| 350 MHz | 1 000 000 µV |
| 420 MHz | 1 025 000 µV |
| 500 MHz | 1 050 000 µV |
| 550 MHz | 1 075 000 µV |
| 600 MHz | 1 100 000 µV |
| 700 MHz | 1 162 500 µV |
| above 700 MHz | no stock data: do not run GPU work |

* V ≥ the row value and V ≤ 1 162 500 µV: the pair is valid for every ASV
  group; go on with section 6.
* V below the row value: it may still suit this chip (faster groups need
  less), but that is not proven. Do not run GPU work; keep the swrender
  drop-in; report F and V. Next step would be the single-OPP variant
  (section 3.2).
* V above 1 162 500 µV: unexpected (above `G3D_MAX_VOLT`); report.
* F at OSCCLK (24 000 000 or a division of it): first row; even when the
  pair passes, the GPU is slow, and the single-OPP variant is then the way
  to a usable GPU.

Lower clocks need no more voltage than higher ones, which is why a rate
between two stock levels takes the higher level's row. The cold margin is
ignored here: the die idles at 43-45 °C (`docs/hardware/THERMAL.md`, first boot).

### 3.4 Rail control that mainline does not replicate

* **G3D_EN pin.** Stock moves BUCK6's on/off control to the PMIC's G3D_EN
  input, wired to `gpf0-1` (`live_fdt:2321,2330`, pinctrl `pm-g3d-en`
  `live_fdt:5409-5414`, pull-up): at PMIC probe it drives the pin high, clears
  BUCK6's enable bits in B6CTRL1 and sets bit 1 of LDO_DVS3
  (`stock/drivers/regulator/s2mps13.c:849-855`), then switches the rail with
  the pin around every `pd_g3d` transition
  (`stock/arch/arm/mach-exynos/pm_domains-exynos5433.c:82,129`). Mainline's
  `s2mps11` driver has no such mode; BUCK6 is register-enabled and
  always-on. After a warm reboot from Android the PMIC may still be in pin
  mode, and nothing drives `gpf0-1`. Evidence that the rail is up under
  mainline anyway: `cmu_g3d`, inside the same domain and on the same rail,
  has its registers read at every boot of the validated kernel (clock
  registration and the runtime-suspend save, section 3.1) without a hang.
  It remains the most likely cause of a hang at panfrost probe.
* **DVS pin.** Stock writes a second BUCK6 level into B6CTRL3
  (`s2mps13.c:816`), keeps the DVS pin `gpr3-0` low in normal operation
  (`s2mps13.c:813`; pinctrl `pm-dvs-en`, no pull, `live_fdt:3828-3833`) and
  raises it on GPU power-off, after switching the GPU clock to OSCCLK, until
  the next power-on (`mali/gpu_control.c:247-255,279`, called from
  `mali/gpu_notifier.c:180,204`).
  Mainline does not drive the pin; the `microvolts` reading reflects B6OUT,
  which is the active level only while the pin is low.
* **NoC timeout.** After each G3D power-up stock writes 1 to SYSREG_G3D +
  0x700 (0x14A90700) "set noc-bus timeout"
  (`pm_domains-exynos5433.c:102`, `stock/arch/arm/mach-exynos/include/mach/map.h:327`).
  Not done in mainline; it is a bus-error-instead-of-hang setting, not needed
  for function.

## 4. Thermal

**Sensor.** `tmu_g3d` (0x10070000) stays disabled
(`exynos5433-gts28ltexx-thermal.dtsi:61-69`): on the first thermal boot it read
−60 °C. The G3D zone therefore does not exist, nothing measures the GPU
block, and the hardware trip of that TMU instance is not programmed by Linux.

**Likely cause of the −60 °C (hypothesis, to be tested):** the G3D power
domain was off when the sensor was read. Mainline powers `pd_g3d` down
right after `cmu_g3d` probes (section 3.1). Stock never trusts that sensor
while the GPU is off: it substitutes 20 °C (`stock/drivers/thermal/exynos_thermal.c:974-980`)
and turns the G3D TMU core off and on around every G3D power transition
(`pm_domains-exynos5433.c:87,99`). The ISP sensor (−155 °C) sits in another
domain that mainline also powers down. With this milestone the G3D domain
stays **on** once panfrost has probed: panfrost keeps `aclk_g3d` prepared
for its whole lifetime (`pf/panfrost_device.c:51`; runtime suspend only
powers the shader cores off, `:416-430`), and a prepared clock holds its CMU
runtime-active (`drivers/clk/clk.c:1112-1122`), hence the domain. That makes
a re-test of `tmu_g3d` on top of the GPU dtb meaningful (separate task).

**What protects the GPU now.**

* The three CPU zones keep their 115 °C critical trip, software
  (`orderly_poweroff`, ending in the PS_HOLD power-off of the board file)
  and hardware (TMU `THERM_TRIP_EN` on the atlas0/atlas1/apollo
  instances): `docs/hardware/THERMAL.md` sections 3-4. The GPU heats the same die,
  so a runaway reaches those sensors, but with a gradient: the G3D block
  can be hotter than they read.
* No GPU throttling: stock steps the GPU down at 95/100/105/110 °C on the G3D
  sensor (420/350/266/160 MHz) and trips at 115 °C
  (`stock/arch/arm/mach-exynos/include/mach/tmu.h:40-45`,
  `exynos_thermal.c:481-513`, `mali/gpu_exynos5433.c:92-96`); none of that
  exists here.
* The GPU power is bounded by the fixed boot pair: no higher clock or
  voltage than at boot, and inside the stock envelope once section 3.3 has
  passed.

**GPU-specific risk:** sustained full-load GPU work (benchmarks, games)
with no G3D sensor and no throttle. Compositing (phoc) is light. Until a
G3D sensor works: watch the CPU zones during GPU tests
(`watch -n1 cat /sys/class/thermal/thermal_zone*/temp`) and stop at 85 °C
on any of them (stock's emergency level on the A53 sensor is > 85 °C,
`docs/hardware/THERMAL.md` section 2.3); no long benchmark runs.

## 5. Expected first boot

Kernel log (`pf/panfrost_device.c:49`, `pf/panfrost_gpu.c:329-345`,
`drivers/gpu/drm/drm_drv.c:957`):

```
panfrost 14ac0000.gpu: clock rate = <F>
panfrost 14ac0000.gpu: mali-t760 id 0x750 major 0x<M> minor 0x<m> status 0x<s>
panfrost 14ac0000.gpu: features: <bitmap>, issues: <bitmap>
panfrost 14ac0000.gpu: Features: L2:0x… Shader:0x… Tiler:0x… Mem:0x… MMU:0x… AS:0x… JS:0x…
panfrost 14ac0000.gpu: shader_present=0x… l2_present=0x…
[drm] Initialized panfrost 1.2.0 for 14ac0000.gpu on minor <n>
```

* id **0x750** = T76x product id (`pf/panfrost_gpu.c:211`; stock kbase
  `GPU_ID_PI_T76X 0x0750`, `stock/drivers/gpu/arm/t7xx/r22p0/mali_kbase_gpu_id.h:38`).
  The revision is not known from the sources: stock kbase knows T760
  r0p0-r1p0 (`…/r22p0/mali_kbase_hw.c:318-333`); panfrost has issue lists for
  r0p0-r0p3 and applies the model-wide list to anything else
  (`pf/panfrost_gpu.c:211-214,303-322`). Note the revision.
* `shader_present`: six bits set for an MP6 (the exact mask is not in the
  sources); note the value.
* Not expected: `supply mali not found` (the supply is wired), any devfreq
  or OPP line, `gpu soft reset timed out`, `error powering up gpu …`,
  `… power transition timeout` (`pf/panfrost_gpu.c:75-81,419-457`). Any of
  these: do not use the GPU, report the log.

Checks (root):

```sh
dmesg | grep -i -e panfrost -e 'power domain'
ls -l /dev/dri/ /dev/dri/by-path/          # renderD128 = platform-14ac0000.gpu-render
cat /sys/class/regulator/*/name | grep -n vdd_g3d
cat $(dirname $(grep -lx vdd_g3d /sys/class/regulator/*/name))/microvolts   # V, section 3.3
cat /sys/bus/platform/devices/14ac0000.gpu/power/runtime_status
```

**Boot-loop risk.** panfrost is built in and probes before the initramfs
runs. If the probe hung the bus (section 3.4, G3D_EN), the watchdog would
reset the board 30 s later, sboot would start RECOVERY again (`docs/journal/PROGRESS.md`,
boot-loop incident) and the initramfs watchdog guard would never get to run.
Signs: the boot log stops at or right after the first `panfrost` line, then a
reset. Recovery: Download mode, then flash the previous RECOVERY image
(`heimdall flash --RECOVERY <validated image>`), as on 2026-10-28. ramoops
should hold the console of the hung boot.

## 6. Testing from Arch

### 6.1 Mesa side

* The rootfs installs `mesa` (`legacy/phosh/packages.txt:48`). Arch Linux
  ARM builds it from the Arch PKGBUILD with `-D gallium-drivers=all`
  (<https://github.com/archlinuxarm/PKGBUILDs/blob/master/extra/mesa/PKGBUILD>,
  pkgver 26.2.5 when checked on 2026-10-28),
  which includes panfrost. kmsro is no longer a separate option: Mesa builds
  it automatically with any render-only driver (panfrost, lima, etnaviv…)
  since the commit "meson: Remove kmsro from gallium-drivers" (Mesa 21.1,
  <https://lists.freedesktop.org/archives/mesa-commit/2021-March/116293.html>),
  and its list of display drivers includes `exynos`. Check on the device:
  `ls /usr/lib/dri/ | grep -e exynos -e panfrost` (both names must exist).
* No Vulkan: panvk does not cover Midgard. GTK must use GL or cairo.
* Tools (not in the image): `pacman -S mesa-utils` (eglinfo) and, if the
  repository has it, `kmscube`.

### 6.2 Order of tests

1. **First boot with the swrender drop-in still in place.** phoc and the
   Phosh shell keep `WLR_RENDERER=pixman` and `LIBGL_ALWAYS_SOFTWARE=1`, so
   the session submits no GPU jobs. Do sections 5 and 3.3 over SSH. To be
   strict (a process started outside `phosh.service` does not get those
   variables), `systemctl stop phosh` first and check that nothing holds the
   render node: `ls -l /proc/[0-9]*/fd 2>/dev/null | grep renderD128` prints
   nothing.
2. **eglinfo** (no rendering): `eglinfo -B`. In the GBM platform section,
   expect `Mali-T760 (Panfrost)` as the OpenGL ES renderer and an OpenGL ES
   3.x version string. llvmpipe there means Mesa did not pick panfrost.
3. **kmscube** (first real GPU work, short): stop the session
   (`systemctl stop phosh`), find the Exynos card (`ls -l /dev/dri/by-path/`,
   `platform-exynos-drm-card`), run `kmscube -D /dev/dri/cardN` for a minute
   while watching the thermal zones (section 4) and `dmesg -w` for
   `panfrost … job timeout`, `GPU Fault` or `MMU fault`.
4. **phoc on GLES** (describe only, the file is not edited here):
   `legacy/phosh/overlay/etc/systemd/system/phosh.service.d/10-t715-swrender.conf`
   sets four variables. For phoc to render on the GPU, remove
   `Environment=WLR_RENDERER=pixman` **and** `Environment=LIBGL_ALWAYS_SOFTWARE=1`
   (the latter forces Mesa's software rasteriser for EGL/GBM as well, so
   phoc would get a GLES renderer on llvmpipe). Keep `GSK_RENDERER=cairo` for
   a first run (GTK clients stay on cairo, only the compositor uses the GPU)
   and keep `WLR_LIBINPUT_NO_DEVICES=1` while no input device is guaranteed.
   Check: `journalctl -b -u phosh` should not mention pixman, and
   `grep -h '^drm-driver' /proc/$(pidof phoc)/fdinfo/* | sort -u` should list
   `panfrost` next to `exynos`. Later, drop `GSK_RENDERER=cairo` to let GTK
   use GL.
5. Rollback: restore the drop-in, or boot the previous kernel/DTB.

Known limitation: client buffers allocated by panfrost are not physically
contiguous and the Exynos display has no IOMMU in use here, so they cannot
be scanned out directly; phoc composites them instead (normal path).

## 7. Left out

| item | stock | why left out |
|---|---|---|
| devfreq / OPP table / ASV voltages | 8 levels, per-chip ASV voltages (`mali/gpu_exynos5433.c:46-55`, `asv.h`) | section 3.2: ASV group unknown, no 5433 ASV in mainline |
| GPU thermal throttling, devfreq cooling | 95-115 °C steps on the G3D sensor | no devfreq, no working G3D sensor (section 4) |
| `tmu_g3d` re-enable | sensor ignored while the GPU is off | needs its own test on top of this dtb (section 4) |
| G3D_EN pin control of BUCK6, DVS level | `s2mps13.c:813-855`, `mali/gpu_control.c:247-279` | PMIC behaviour change, not GPU enablement; mainline has no driver support (section 3.4) |
| Powering `pd_g3d` and BUCK6 off when idle | rail and domain off between frames | panfrost keeps the clock prepared, so the domain stays on; BUCK6 is always-on. Costs idle power, avoids domain transitions |
| Adaptive body bias for G3D | per level on table versions 2-3 (`asv.h:258`, `:344`) | no mainline support; it belongs to the ASV work. Since then: branch `t715-g3d-abb`, section 10.12 |
| MIF/INT bus frequency requests per GPU level, BTS | `mali/gpu_exynos5433.c:46-55` (last four columns), `:461-493` | no bus devfreq in mainline: memory runs at the bootloader rate, which limits GPU performance, not safety |
| NoC bus timeout write | `pm_domains-exynos5433.c:102` | section 3.4 |
| G3D TMU core off/on around domain transitions | `pm_domains-exynos5433.c:87,99` | `tmu_g3d` is not bound; the domain no longer toggles once panfrost has probed |

## 8. Open risks

1. **Boot pair unknown until the first boot**: F and V may fall outside the
   envelope (section 3.3) or F may be OSCCLK (slow). Neither can damage the
   chip (no voltage or clock is raised); the first means no GPU work yet.
2. **Hang at panfrost probe** if BUCK6 follows the undriven G3D_EN pin after
   a warm reboot (section 3.4); would be a boot loop (section 5).
3. **No GPU temperature** and no throttle (section 4).
4. **Clock restore order**: on each `pd_g3d` power-up mainline restores the
   mux before the divider (`clk-exynos5433.c:3273-3290`), where stock restores
   DIV → PLL → MUX → gates "to prevent possible timing violation"
   (`stock/arch/arm/mach-exynos/pm_domains-exynos5433.h:86-89`). The GPU is
   idle at that moment and, with panfrost bound, the domain powers up once.
5. **DVS pin state** not controlled; the BUCK6 reading assumes it is low
   (section 3.4).
6. **T760 revision**: if it is r1p0, panfrost uses only the model-wide issue
   list (`pf/panfrost_issues.h`); stock kbase has a specific r1p0 list. Most
   of those entries are handled by the Mesa compiler, not the kernel.

## 9. Build verification

Build-tested only, 2026-10-28, on the tree as it stood then (board file with
M3 display and M4 input merged by parallel work):

* `bash kernel/kbuild-mainline.sh --fragment gts28ltexx_gpu.config` →
  exit 0 (volume `t715-kbuild-out-gts28ltexx_gpu`, output
  `out/mainline-gpu/`). zImage 3 575 496 bytes (script limit
  9 MiB), `exynos5433-gts28ltexx-gpu.dtb` 60 779 bytes. ARM64
  non-regression phase passed.
* `.config`: `DRM_PANFROST`, `DRM_SCHED`, `DEVFREQ_GOV_SIMPLE_ONDEMAND` = y
  (the only differences from a plain defconfig build);
  `IOMMU_IO_PGTABLE_LPAE`, `DRM_GEM_SHMEM_HELPER`, `PM_DEVFREQ` = y;
  `DEVFREQ_THERMAL` not set.
* Decompiled `exynos5433-gts28ltexx-gpu.dtb` vs `exynos5433-gts28ltexx.dtb`:
  the only differences are in the gpu node (`operating-points-v2` and the
  `opp-table` subnode gone, `mali-supply` → BUCK6, `status = "okay"`) and the
  new phandle on BUCK6.
* `make W=1` on both DTBs: identical warning sets, all pre-existing
  (`/memory` unit name, PCIe `#interrupt-cells`, DECON/DSI single-port
  graphs). `make W=1 drivers/gpu/drm/panfrost/`: no warning.
* `make CHECK_DTBS=y` (dtschema 2026.9, `apt-get install python3-pip` +
  `pip3 install --break-system-packages dtschema` in the build container):
  exit 0; same 12 findings for both DTBs, none in the gpu node (root
  compatible and sboot `model_info-*`, `/memory`, DSI `vddcore-supply`, USB DRD
  `vdd10/vdd33-supply`, PCIe interrupt-map prerequisite).

## First boot on the tablet (2026-10-28)

- panfrost loaded by hand as a module (no loop risk if the probe had hung).
- `clock rate = 266000000`, `mali-t760 id 0x750 major 0x0 minor 0x1`, `shader_present=0x77` (6 cores), `l2_present=0x1`.
- `vdd_g3d` (BUCK6) = 937 500 µV: above the stock voltage at 266 MHz for table versions 1-3 (900 000-912 500 µV), below table version 0 (1 000 000 µV); this chip's table version is unknown.
- Mesa 26.2.5: `exynos_dri.so` + `panfrost_dri.so` present; phoc with `WLR_RENDERER=gles2` gets EGL 1.5 (driver `exynos`, kmsro) and **"GL renderer: Mali-T760 MC6 (Panfrost)", OpenGL ES 3.1**.
- No GPU faults or job timeouts; CPU zones 44-45 °C.
- Folded into the board file and defconfig (`DRM_PANFROST=y`).

## 10. Frequency scaling (devfreq)

Designed and build-checked on 2026-10-29. **Not in the daily kernel:**
the candidate that includes the dtsi with a 420 MHz cap (section 10.11) is
kernel commit `9510f7e46` on branch `t715-gpu420`; its validation was
aborted on 2026-10-29 (the 266 MHz baseline under glmark2 hung the tablet,
Omarchy repo `docs/journal/ONDEVICE-2026-10-29.md`), so `t715-bringup` stops at
the design commit `dc1fc95fb` and the daily GPU stays at its boot clock. Sections 1-9 above describe the kernel
before that commit (no OPP table, Linux set neither the GPU voltage nor
its clock).

Extra path abbreviations for this section:

* `clk` = `src/linux-6.12/drivers/clk/samsung/clk-exynos5433.c`;
  `stock-clk` = `stock/drivers/clk/samsung/clk-exynos5433.c`
* `stock-thermal` = `stock/drivers/thermal/exynos_thermal.c`;
  `tmu.h` = `stock/arch/arm/mach-exynos/include/mach/tmu.h`
* `cal.c` = `stock/arch/arm/mach-exynos/asv-exynos5433_cal.c`
* `s2mps13.c` = `stock/drivers/regulator/s2mps13.c`
* `boot-log` = a private stock boot log
  (stock Android boot of this tablet, from t = 0; the same ASV lines
  appear in 17 other stock boots in that directory)

### 10.1 Files and how to enable them

| file (under `src/linux-6.12/`) | what |
|---|---|
| `arch/arm/boot/dts/samsung/exynos5433-gts28ltexx-gpufreq.dtsi` (new) | root node `opp-table-gpu` (8 OPPs), `&gpu { operating-points-v2; #cooling-cells = <2>; }`, 4 passive trips + cooling-maps on `g3d-thermal`, 2 on `apollo-thermal` |
| `arch/arm/configs/gts28ltexx_gpufreq.config` (new) | `DRM_PANFROST=m`, `PM_DEVFREQ=y`, `DEVFREQ_GOV_SIMPLE_ONDEMAND=y`, `DEVFREQ_THERMAL=y` |

As designed, no existing file was changed. The daily board has included
the dtsi since `9510f7e46`, which also deletes the four fastest OPPs and
renumbers the GPU cooling-maps (section 10.11) and folds the fragment into
`gts28ltexx_defconfig`. The steps as first written:

* board `exynos5433-gts28ltexx.dts`: add
  `#include "exynos5433-gts28ltexx-gpufreq.dtsi"` **after** line 823
  (`exynos5433-gts28ltexx-gpu.dtsi`, which deletes `operating-points-v2`;
  the new file sets it again, so the order matters), and update the
  section 12 comment ("No OPP table ...");
* kernel: build with `--fragment gts28ltexx_gpufreq.config`, or fold its
  two new lines (`DEVFREQ_GOV_SIMPLE_ONDEMAND=y`, `DEVFREQ_THERMAL=y`)
  into `gts28ltexx_defconfig` once validated;
* afterwards, sections 2.1 ("Not added: `#cooling-cells`"), 2.2
  (`DEVFREQ_THERMAL` not set), 3.1, 4 ("No GPU throttling") and 7 of this
  document become outdated.

**What changes at run time.** panfrost now drives BUCK6 and the G3D PLL
through the OPP core: at probe it reads the clock (266 MHz on this board,
section "First boot"), takes the OPP at or above it (266 MHz) and applies
it with `dev_pm_opp_set_opp()`, i.e. BUCK6 goes from the boot 937 500 µV
to **1 037 500 µV** (`pf/panfrost_devfreq.c:164-189`). Then
simple_ondemand re-evaluates every 50 ms (`:86-87`, upthreshold 45 %,
downdifferential 5, `:203-204`). The OPP core raises the voltage before
a frequency increase and lowers it after a decrease.

### 10.2 Frequencies and the clock path

panfrost calls `clk_set_rate()` on its `core` clock, `aclk_g3d`
(`pf/panfrost_devfreq.c:41`, `dev_pm_opp_set_rate()`; `soc-dtsi:1193-1194`).
Every element of the chain forwards the request to its parent:

`aclk_g3d` (gate, `CLK_SET_RATE_PARENT`, `clk:3339`) → `div_aclk_g3d`
(DIV_G3D[2:0], ÷1…8, `CLK_SET_RATE_PARENT`, `clk:3319`) →
`mout_aclk_g3d_400` (parents `mout_g3d_pll` | `aclk_g3d_400`,
`CLK_SET_RATE_PARENT`, `clk:3297,3307`) → `mout_g3d_pll` (parents
`oscclk` | `fout_g3d_pll`, `CLK_SET_RATE_PARENT`, `clk:3298,3309`) →
`fout_g3d_pll` (PLL35xx, rate table `exynos5433_pll_rates`, `clk:3301-3302`;
24 MHz input, board `&xxti`, `exynos5433-gts28ltexx.dts:234-236`).

How the framework settles each rate: the PLL only accepts exact table
rates (`clk-pll.c:38-50`, round-down `:52-67`); a mux keeps the first
parent that gives the exact rate (`clk.c:632-638`), i.e. `mout_g3d_pll`
then `fout_g3d_pll` (oscclk gives only 24 MHz); the divider keeps ÷1 when
÷1 is exact (`clk-divider.c:267-274,318-336`) **except** when the current
PLL rate already is an exact multiple of the request
(`clk-divider.c:320-328`): from 700 MHz, a request for 350 MHz gives
PLL 700 MHz ÷ 2 (same 350 000 000 Hz). FOUT = M × 24 MHz / (P × 2^S).

| OPP | mainline P / M / S (line) | divider | stock G3D PLL P / M / S (`stock-clk`) | stock Mali level (`mali/gpu_exynos5433.c`) |
|---|---|---|---|---|
| 700 000 000 | **3 / 175 / 1** (`clk:763`) | 1 | **6 / 350 / 1** (`:3218`) | `:47` |
| 600 000 000 | 5 / 500 / 2 (`clk:766`) | 1 | 5 / 500 / 2 (`:3219`) | `:48` |
| 550 000 000 | 6 / 550 / 2 (`clk:768`) | 1 | same (`:3220`) | `:49` |
| 500 000 000 | 6 / 500 / 2 (`clk:771`) | 1 | same (`:3221`) | `:50` |
| 420 000 000 | 5 / 350 / 2 (`clk:773`) | 1 | same (`:3222`) | `:51` |
| 350 000 000 | 6 / 350 / 2 (`clk:775`), or PLL 700 MHz ÷ 2 when coming down from 700 | 1 or 2 | same (`:3223`) | `:52` |
| 266 000 000 | 6 / 532 / 3 (`clk:779`) | 1 | same (`:3224`) | `:53` |
| 160 000 000 | 6 / 320 / 3 (`clk:783`) | 1 | same (`:3225`) | `:54` |

All eight stock levels are exact on mainline, so none is left out. 266
MHz is written as 266 000 000 Hz (the SoC table's 267 MHz is not a PLL
rate). Not added: 730 and 650 MHz (rows of the ASV tables and, for 730,
of the stock PLL table, but not Mali DVFS levels, `mali/gpu_exynos5433.c:46-55`).

**700 MHz differs from stock in its PLL setting**: same VCO (1 400 MHz)
and S, but P = 3 (8 MHz phase-detector input) where stock uses P = 6 on
every PLL at 700 MHz (G3D `stock-clk:3218`, CPU clusters
`stock/drivers/cpufreq/exynos5433-kfc-cpufreq.c:90`,
`exynos5433-eagle-cpufreq.c:121`). Mainline programs the same P = 3
entry into the CPU PLLs of the TM2 board at its 700 MHz cpufreq OPPs
(`soc-dtsi:254,296`, cpufreq on TM2 via `cpu-supply`,
`exynos5433-tm2-common.dtsi:319,323`), which is the only evidence that
setting works on this SoC.

**PLL change without parking.** Stock moves `mout_g3d_pll` to the 24 MHz
oscillator, reprograms the PLL and moves it back
(`mali/gpu_exynos5433.c:381-404`, "for future stable clock changing").
Mainline writes the new P/M/S and waits for lock with the PLL still
feeding the GPU (`clk-pll.c:249-296`; lock time P × 270 input cycles,
`:208,280`, i.e. 34-68 µs). Every level change except 700 ↔ 350 changes
P or M. Mainline TM2 runs this same path (it enables `&gpu` with the SoC
OPP table, `exynos5433-tm2-common.dtsi:357-360`). Risk 3 below.

### 10.3 Voltages

**Envelope.** The chip's ASV group and table version are treated as
unknown (but see "This chip" below): each OPP takes the highest stock G3D
voltage at that frequency over the 16 groups and the four tables. The
maximum is always the ASV0 column (checked row by row: every row is
non-increasing from ASV0 to ASV15). Table selection by version:
`cal.c:298-334`; group 0 forced on version 0, `cal.c:204-205`; fused
per-level groups, `cal.c:270-283`.

| MHz | v0 (`asv.h`) | v1 | v2 | v3 | **envelope** | + cold margin = **OPP µV** | BUCK6 selector (`B6OUT`) |
|---|---|---|---|---|---|---|---|
| 160 | 1 000 000 (442) | 887 500 (546) | 887 500 (651) | 887 500 (757) | 1 000 000 | **1 037 500** | 0x66 |
| 266 | 1 000 000 (441) | 912 500 (545) | 900 000 (650) | 900 000 (756) | 1 000 000 | **1 037 500** | 0x66 |
| 350 | 1 000 000 (440) | 937 500 (544) | 925 000 (649) | 925 000 (755) | 1 000 000 | **1 037 500** | 0x66 |
| 420 | 1 025 000 (439) | 962 500 (543) | 950 000 (648) | 950 000 (754) | 1 025 000 | **1 062 500** | 0x6a |
| 500 | 1 050 000 (438) | 987 500 (542) | 962 500 (647) | 975 000 (753) | 1 050 000 | **1 087 500** | 0x6e |
| 550 | 1 075 000 (437) | 1 025 000 (541) | 1 000 000 (646) | 1 000 000 (752) | 1 075 000 | **1 112 500** | 0x72 |
| 600 | 1 100 000 (436) | 1 075 000 (540) | 1 050 000 (645) | 1 050 000 (751) | 1 100 000 | **1 137 500** | 0x76 |
| 700 | 1 125 000 (434) | 1 162 500 (539) | 1 137 500 (643) | 1 150 000 (749) | 1 162 500 | **1 200 000** | 0x80 |

Nothing else in stock raises these values: the ASV lock voltage is at most
70 000 + 15 × 25 000 = 445 000 µV for G3D (`cal.c:255-268`, applied at
`:341-344`), below every table entry; `CONFIG_ASV_MARGIN_TEST` is off
(`stock/arch/arm/configs/lineage_gts28ltexx_defconfig:385`); the Mali
code only adds the cold margin (`mali/gpu_dvfs_api.c:161`,
`GPU_COLD_MINIMUM_VOL` = 0, `mali/gpu_exynos5433.c:89`).

**Cold margin: 37 500 µV, while the GPU state is `GPU_COLD`.**
`GPU_VOLTAGE_OFFSET_MARGIN` = 37 500 (`mali/gpu_exynos5433.c:90`, default
also 37 500, `mali/mali_kbase_platform.c:256-257`); the TMU notifier
clears the margin on every event and sets it only on `GPU_COLD`
(`mali/gpu_notifier.c:113-116`); the target is table voltage + margin
(`mali/gpu_dvfs_api.c:161,206`). `GPU_COLD` is sent when the GPU
temperature is ≤ `COLD_TEMP` = 19 °C (`stock-thermal:499-502`,
`tmu.h:22`; the GPU temperature is the G3D sensor, or 20 °C while the GPU
is off, `stock-thermal:977-980`), and also at every suspend
(`stock-thermal:433-434,1142-1146`; the stock logs show the state 0 → 1
→ 0 toggling around suspends, `dumps/dmesg.txt:260,381`). Mainline has
no working G3D sensor and no such notifier, so the margin is added to
every OPP.

**Ceiling: 1 200 000 µV.** The highest voltage stock ever writes to
`vdd_g3d` is `G3D_MAX_VOLT` 1 162 500 (`stock/arch/arm/mach-exynos/asv-exynos5433.c:39`,
= the 700 MHz value of table v1) + 37 500 = 1 200 000 µV: 700 MHz on a
table-version 2-4 chip while cold or suspending
(`regulator_set_voltage(vol, vol)`, `mali/gpu_exynos5433.c:581`; stock
BUCK6 window 600 000-1 500 000 µV, `live_fdt:2400,2405`, so the regulator
core lets it through). The 700 MHz OPP sits exactly on that ceiling, no
OPP exceeds it, so no level is dropped.

**BUCK6.** Board node `exynos5433-gts28ltexx.dts:430-437`: 600 000-1 500 000
µV, ramp 12 000 µV/µs, = stock (`live_fdt:2399-2407`). The OPP range
1 037 500-1 200 000 µV is inside: **no change needed**. PMIC grid:
mainline BUCK6 = 500 000 µV at selector 0x10, 6 250 µV steps, 256
selectors (`drivers/regulator/s2mps11.c:514-529,611`,
`include/linux/mfd/samsung/s2mps14.h:124,132`, `core.h:25,34`), i.e.
selector × 6 250 + 400 000, up to 1 993 750 µV; stock: 400 000 µV base,
6 250 µV steps for PMIC revision ≥ 1 (`s2mps13.c:447-461,650,783`;
`stock/include/linux/mfd/samsung/s2mps13.h:190,195,201,221`). Both write
the same register (stock B6CTRL2 = mainline B6OUT = 0x24). For a
revision-0 PMIC stock would use a 600 000 µV base
(`s2mps13.h:189`, `s2mps13.c:595,783`) and mainline's selectors would be
200 mV off; this PMIC is not revision 0: the same register reads 937 mV
in the stock kernel (`boot-log:829`, "vdd_g3d: 600 <--> 1500 mV at 937 mV")
and 937 500 µV in mainline (section "First boot"), which only holds if
both use the 400 000 µV base. Test plan step P1 checks it directly.

**This chip (found after the design rule was fixed).** The stock boot
logs of this tablet print its ASV data: table version **8** (v3 table,
`cal.c:325`), fused speed groups, **G3D group 1** at every level, ABB 8,
not a max-limit sample (no "ATL max frequency limited" line,
`asv-exynos5433.c:422-423`) (`boot-log:138-143,694-696,766-776,1118-1133`).
Stock therefore programs on this chip (v3 ASV1, `asv.h:749-757`, as
logged):

| MHz | this chip, stock | stock cold (+37 500) | OPP here | OPP − stock | dynamic power vs stock (V² ratio) |
|---|---|---|---|---|---|
| 160 | 875 000 | 912 500 | 1 037 500 | +162 500 | ×1.41 |
| 266 | 887 500 | 925 000 | 1 037 500 | +150 000 | ×1.37 |
| 350 | 912 500 | 950 000 | 1 037 500 | +125 000 | ×1.29 |
| 420 | 937 500 | 975 000 | 1 062 500 | +125 000 | ×1.28 |
| 500 | 962 500 | 1 000 000 | 1 087 500 | +125 000 | ×1.28 |
| 550 | 987 500 | 1 025 000 | 1 112 500 | +125 000 | ×1.27 |
| 600 | 1 037 500 | 1 075 000 | 1 137 500 | +100 000 | ×1.20 |
| 700 | 1 137 500 | 1 175 000 | 1 200 000 | +62 500 | ×1.11 |

The envelope table is kept as specified (safe for any chip). A
chip-specific table (the "stock cold" column, what stock itself programs
on this chip at ≤ 19 °C) would cut GPU dynamic power by 10-30 % at the
same clock; it is a separate decision, not implemented. Table version 8
also means stock allows 700 MHz on this chip (section 10.4).

### 10.4 Which levels stock actually uses

* Minimum 266 MHz (`GPU_MIN_CLOCK`, `mali/gpu_exynos5433.c:69`); 160 MHz
  only as a thermal cap (`:95-96`).
* Normal ceiling 600 MHz: `GPU_MAX_CLOCK_LIMIT` (`:68`); the governors
  clamp to it unless the hardware-counter boost is on
  (`mali/gpu_dvfs_governor.c:93-97,135-139`), sysfs locks are clamped to
  it (`mali/gpu_custom_interface.c:604-605,1655-1656`), compute boost goes
  to it (`mali/gpu_dvfs_governor.c:252`).
* 700 MHz only under the hardware-counter boost: at ≥ 600 MHz with an
  arithmetic-heavy counter profile (`mali/gpu_hwcnt_sec.c:257-264`), and
  only on table version ≥ 2 (`available_max_clock`, `:64,141-151`;
  versions 0-1 stop at 550 MHz) that is not a max-limit sample (500 MHz,
  `:153-154`). This chip: version 8, not limited.
* Stock also requests minimum bus/CPU levels per GPU level and caps the
  A57 cluster at 1.3 GHz at 600/700 MHz (last four columns,
  `mali/gpu_exynos5433.c:45-55`). Mainline has no bus devfreq and no
  cpufreq here; the A57s already run at 1.2 GHz (`docs/journal/PROGRESS.md:429`).

simple_ondemand has no notion of a boost level: it will use 700 MHz
whenever the GPU is busy. Suggested for daily use until the G3D sensor
works: cap at stock's normal ceiling with a udev rule,
`ACTION=="add", SUBSYSTEM=="devfreq", KERNEL=="14ac0000.gpu", ATTR{max_freq}="600000000"`.
Superseded: the daily kernel caps at 420 MHz in the device tree
(section 10.11), which needs no rule in either root image.

### 10.5 Thermal throttling

**Stock.**

1. G3D sensor (TMU 2): GPU state from the GPU temperature
   (`stock-thermal:481-502`, thresholds `GPU_TH_TEMP1-5`, `tmu.h:40-45`),
   each state a max clock lock (`mali/gpu_notifier.c:61-87`, values
   `mali/gpu_exynos5433.c:92-96`, read at `mali/mali_kbase_platform.c:232-241`):
   ≥ 95 °C 420 MHz, ≥ 100 °C 350 MHz, ≥ 105 °C 266 MHz, ≥ 110 °C 160 MHz,
   ≥ 115 °C 160 MHz. No hysteresis: the state is recomputed at every
   reading.
2. A53 sensor (TMU 3, "KFC", mainline apollo): KFC 81-85 °C (with the
   CPU/ISP maximum < 101 °C and G3D < 96 °C) forces GPU temperature 98 °C
   = state ≥ THROTTLING1 (420 MHz); KFC ≥ 86 °C forces 112 °C =
   THROTTLING4 (160 MHz) (`stock-thermal:992-1000`, used at `:1029`).
3. DRAM MR4 temperature (via the bus devfreq driver,
   `CONFIG_ARM_EXYNOS5433_BUS_DEVFREQ=y`, lineage defconfig:3938): MR4
   state ≥ 4 ("85 °C~") on one channel → THROTTLING4, on both → TRIPPING
   (`stock-thermal:151-153,505-526,1291-1308`). **Not mirrored**: mainline
   has no Exynos5433 DRAM-controller driver (`drivers/memory/samsung/`
   only has exynos5422-dmc).
4. IPA power allocator (`CONFIG_CPU_THERMAL_IPA=y`, defconfig:2426;
   control 81 °C, TDP 3 500 mW, GPU max 3 110 mW, `live_fdt:1790-1813`)
   with a GPU max lock (`stock/drivers/thermal/ipa.c:256-263`,
   `mali/gpu_ipa.c:228-239`). **Not mirrored**: it needs power models of
   the CPUs (no cpufreq here) and of the GPU (stock's coefficient 46,
   `mali/gpu_exynos5433.c:99`, has no mainline unit mapping).

**Mainline (new dtsi).** devfreq cooling states count from the fastest
OPP (`drivers/thermal/devfreq_cooling.c:348-375,110`): 0 = 700, 1 = 600,
2 = 550, 3 = 500, 4 = 420, 5 = 350, 6 = 266, 7 = 160 MHz. Each passive
trip maps to one fixed state (`cooling-device = <&gpu N N>`), so
step_wise applies exactly that cap when the trip is crossed and clears it
when the temperature falls back (`gov_step_wise.c:31-75`); the device
takes the deepest cap requested by any trip (`thermal_helpers.c:178-188`).
The cap is a PM QoS max-frequency request (`devfreq_cooling.c:84-117`),
which wins over a user `min_freq` (`devfreq.c:120-160`).

| zone | trip | temp | hyst. | state → cap | stock source |
|---|---|---|---|---|---|
| g3d-thermal | g3d-gpu-throttle1 | 95 °C | 2 °C | 4 → 420 MHz | tmu.h:41, gpu_exynos5433.c:92 |
| g3d-thermal | g3d-gpu-throttle2 | 100 °C | 2 °C | 5 → 350 MHz | tmu.h:42, :93 |
| g3d-thermal | g3d-gpu-throttle3 | 105 °C | 2 °C | 6 → 266 MHz | tmu.h:43, :94 |
| g3d-thermal | g3d-gpu-throttle4 | 110 °C | 2 °C | 7 → 160 MHz | tmu.h:44, :95 |
| apollo-thermal | apollo-gpu-throttle1 | 81 °C | 2 °C | 4 → 420 MHz | stock-thermal:992-995 |
| apollo-thermal | apollo-gpu-throttle4 | 86 °C | 2 °C | 7 → 160 MHz | stock-thermal:997-1000 |

* ≥ 115 °C (`GPU_TH_TEMP5`, TRIPPING = 160 MHz) needs no passive trip:
  160 MHz is already the 110 °C cap, and the existing **critical** trip
  at 115 °C (and **hot** at 110 °C, apollo 86 °C) of
  `exynos5433-gts28ltexx-thermal.dtsi` are untouched.
* Hysteresis 2 °C is stock's TMU `threshold_falling` (`live_fdt:4246`);
  it only delays the release. Polling is the zones' existing 100 ms
  passive / 500 ms idle (thermal dtsi).
* The apollo mirror ignores stock's "maximum < 101 °C" condition: it can
  throttle where stock would not, never the reverse.
* **The four g3d trips are inert today**: `tmu_g3d` is disabled
  (bad readings, `docs/hardware/THERMAL.md` first boot), so `g3d-thermal` is never
  registered. The only GPU throttle that works is the apollo mirror, plus
  the CPU zones' hot/critical trips. Re-testing `tmu_g3d` with panfrost
  bound (domain kept on, section 4) is the next thermal step.
* Readings: mainline apollo idles at 43-45 °C (`docs/hardware/THERMAL.md` first
  boot), stock's CPU sensors at 32-37 °C; the thresholds are stock's, the
  readings are mainline's.

### 10.6 Kernel configuration (`gts28ltexx_gpufreq.config`)

| symbol | defconfig build (`out/mainline/.config`) | fragment | why |
|---|---|---|---|
| `DRM_PANFROST` | m | **m** | stays a module (built-in boot loop, `gts28ltexx_defconfig:170-174`); repeated so the fragment cannot flip it |
| `PM_DEVFREQ` | y | y | core framework, already selected by panfrost |
| `DEVFREQ_GOV_SIMPLE_ONDEMAND` | m | **y** | panfrost's hard-coded governor (`pf/panfrost_devfreq.c:206-208`); built in, no `request_module("governor_simpleondemand")` at panfrost load (`drivers/devfreq/devfreq.c:310`) |
| `DEVFREQ_THERMAL` | not set | **y** | devfreq cooling device; without it `devfreq_cooling_em_register()` is a stub returning `-EINVAL` (`include/linux/devfreq_cooling.h:76-81`) and no cooling-map binds |

Since `9510f7e46` the defconfig itself has `PM_DEVFREQ=y`,
`DEVFREQ_GOV_SIMPLE_ONDEMAND=y` and `DEVFREQ_THERMAL=y`, so the daily build
needs no fragment; the fragment is kept and changes nothing on top.

Not added: `ENERGY_MODEL` and `dynamic-power-coefficient` (step_wise does
not use power; the cooling device falls back to its frequency table,
`devfreq_cooling.c:419-438`); `DEVFREQ_GOV_USERSPACE` (pinning works with
`min_freq`/`max_freq`).

### 10.7 Risks

1. **Higher power than stock on this chip** (section 10.3 table): +62.5 to
   +162.5 mV, roughly 1.1-1.4 × the dynamic power at a given clock, with
   less thermal protection than stock (next item).
2. **No G3D sensor**: stock's main GPU throttle (G3D ≥ 95 °C) is inert;
   the GPU block can be hotter than the A53 sensor that now does the
   throttling.
3. **PLL relock while the GPU runs on it** (section 10.2): a glitch would
   show as job faults or a hang right after a level change. Fix if seen:
   a clock notifier that parks `mout_g3d_pll` on oscclk around G3D PLL
   rate changes, as stock does (code change in `clk-exynos5433.c`).
4. **700 MHz**: PLL P = 3 never used by stock; 1 200 000 µV continuously,
   where stock reaches that voltage only cold, and 700 MHz only as a
   boost.
5. **BUCK6 ramp rate**: mainline waits ΔV / 12 000 µV/µs after a rise
   (board ramp-delay) but never programs the PMIC ramp (no
   `set_ramp_delay` in `s2mps14_reg_ops`, `s2mps11.c:618-628`); stock set
   12 mV/µs (`s2mps13.c:108-121,129-131,153-155`, register BUCK_RAMP1
   bits 1:0, value 1). If the PMIC is slower, the clock rises before the
   voltage settles. Step P2.
6. **DVS pin** (`gpr3-0`) not driven by mainline (section 3.4): if it is
   high, BUCK6 outputs the B6CTRL3 level (stock writes 0x30 = 700 000 µV,
   `s2mps13.c:816`, read path `:207-210`) and the OPP voltages have no
   effect: under-voltage, i.e. faults, not damage. The stepping test would
   expose it.
7. **ABB** (adaptive body bias) not programmed by mainline: stock uses 8
   (`ABB_X100`) at every G3D level on this chip (`boot-log:1118-1133`,
   written by `cal_set_abb()`, `cal.c:484-495`, register PMU + 0x0790,
   `cal.c:26`, `stock/arch/arm/mach-exynos/include/mach/regs-pmu.h:806`)
   and 0x8d while the GPU is off with DVS (`mali/gpu_exynos5433.c:41,647-652`).
   Whatever value is left there applies at every level. Step P4 reads it.
   Read on the tablet: **0x8000008d**, the idle reverse bias; hence the
   daily 420 MHz cap (section 10.11). Branch `t715-g3d-abb` makes the
   kernel write it (section 10.12); not yet checked on the tablet.
8. **No bus scaling**: stock raises the MIF minimum to 825 MHz at ≥ 500
   MHz (`mali/gpu_exynos5433.c:47-50`); mainline leaves the memory clocks
   as booted, so the gain above ~420-500 MHz may be small.
9. **Cooling state numbering** depends on the OPP count: removing or
   disabling an OPP shifts the states; renumber the maps. The daily board
   does, for its 4 OPPs (section 10.11).
10. Unchanged from section 3.4/8: G3D_EN pin mode, NoC timeout, clock
    restore order.

### 10.8 Device test plan

Boot the kernel with the fragment and the board including the dtsi, with
**`t715.modblacklist=panfrost`** on the command line
(`boot/initramfs/init:42`) so panfrost is loaded by hand and a
hang cannot repeat on the next boot. Stop the compositor (or keep it on
pixman) so no GPU job runs before step L3. As root:

```sh
D=/sys/class/devfreq/14ac0000.gpu
R=$(dirname $(grep -lx vdd_g3d /sys/class/regulator/*/name))
PM=$(ls -d /sys/kernel/debug/regmap/*-0066)      # S2MPS13 regmap
reg() { dd if=$PM/registers bs=7 skip=$(($1)) count=1 2>/dev/null; } # reads that one register only
clk() { grep -E ' (fout_g3d_pll|mout_g3d_pll|mout_aclk_g3d_400|div_aclk_g3d|aclk_g3d) ' /sys/kernel/debug/clk/clk_summary; }
st()  { echo "cur=$(cat $D/cur_freq) min=$(cat $D/min_freq) max=$(cat $D/max_freq) uV=$(cat $R/microvolts)"; clk; }
pin() { echo $1 > $D/max_freq; echo $1 > $D/min_freq; sleep 1; st; }   # max first, then min
```

(The regmap `registers` file has 7-byte lines, "rr: vv\n", for this
8-bit PMIC, `drivers/base/regmap/regmap-debugfs.c:185-189`; reading one
line reads only that register, `:239-267`. Do not `cat` the whole file:
it would also read, and clear, the PMIC interrupt registers.)

**Pre-checks (panfrost not loaded)**

* **P1 PMIC revision**: `reg 0x00` (REG_ID). Must not be `00`: a
  revision-0 PMIC uses another BUCK6 base (section 10.3). If `00`: stop.
* **P2 ramp**: `reg 0x30` (BUCK_RAMP1); BUCK6 is bits 1:0, stock value 1
  = 12 mV/µs (encoding 6 × 2^n mV/µs, from `s2mps13.c:108-121`). If 0
  (6 mV/µs): report; the fix is `regulator-ramp-delay = <6000>` in the
  BUCK6 node.
* **P3 boot pair**: `cat $R/microvolts` → 937500 expected; `reg 0x24`
  (B6OUT) → 0x56; `clk` → aclk_g3d 266 000 000; note the
  parents/dividers (which of `fout_g3d_pll` ÷ 1 or another path).
* **P4 optional, read-only** (`busybox devmem`, from the initramfs or
  `pacman -S busybox`; `/dev/mem` is enabled, `STRICT_DEVMEM` off in the
  build): `busybox devmem 0x105C0790 32` (G3D ABB: `0x80000088` = stock's
  value 8, 0 = bypass, `cal.c:489-494`); `busybox devmem 0x1000400C 32`
  (bits 3:0 = ASV table version, expect 8; bit 16 = fused groups; CHIPID
  ASV base 0x10004000, `stock/arch/arm/mach-exynos/include/mach/map.h:76`,
  `cal.c:103-108,136`), `busybox devmem 0x10004004 32` (G3D fused groups
  in bits 3:0/7:4/11:8, expect 1/1/1, `cal.c:33,275`). Only these
  always-on blocks; never read CMU_G3D/GPU registers this way (bus hang
  when the domain is off).

**Load**

* **L1** `modprobe panfrost`; `dmesg | grep -i -e panfrost -e opp -e devfreq`:
  expect `clock rate = 266000000`; **not** expected: "Couldn't set OPP
  regulators", "Couldn't set recommended OPP", "Couldn't initialize GPU
  devfreq", "Failed to register cooling device"
  (`pf/panfrost_devfreq.c:146,187,210,217`), any `_opp_` error. Any of
  them: `rmmod panfrost`, report.
* **L2** `st`: microvolts **1037500**, cur 266000000 (or 160000000 if the
  governor already stepped down, idle); `cat $D/available_frequencies`
  (the 8 rates), `cat $D/governor` (simple_ondemand);
  `grep -A3 vdd_g3d /sys/kernel/debug/regulator/regulator_summary`
  (consumer `14ac0000.gpu-mali`); cooling device:
  `grep -l devfreq-14ac0000.gpu /sys/class/thermal/cooling_device*/type`,
  `cur_state` 0, `max_state` 7; bound to apollo: in the apollo zone
  directory, a `cdevN` link to it and `cdevN_trip_point` naming the 81/86
  °C trips (`trip_point_*_temp`).
* **L3** `pin 266000000` before starting any GPU client.

**Stepping** (one level at a time: 266 → 350 → 420 → 500 → 550 → 600 →
700). At each level F:

1. `pin F`; check `cur_freq` = F, `microvolts` = the OPP value
   (266/350: 1037500, 420: 1062500, 500: 1087500, 550: 1112500,
   600: 1137500, 700: 1200000), `aclk_g3d` = F in `clk` and
   `fout_g3d_pll` = F (÷ 1; going down 700 → 350 gives 700 ÷ 2).
2. Load the GPU for at least 5 minutes (the compositor on GLES plus
   Firefox scrolling, `kmscube`, or `glmark2` if installed), with
   `dmesg -w` and
   `watch -n1 'cat /sys/class/thermal/thermal_zone*/temp; cat /sys/class/thermal/cooling_device*/cur_state'`
   in other terminals. Confirm the GPU is busy at F: `$D/trans_stat`
   (time at F grows), `grep -h drm-curfreq /proc/<client pid>/fdinfo/*`
   (`pf/panfrost_drv.c:561-564`).
3. Pass: no message below, no corruption, temperatures stable, GPU
   cooling `cur_state` 0.

**Abort** (go back with `pin 266000000`, or `rmmod panfrost`, and report
F, the message and the temperatures) on any of:

* `gpu sched timeout`, `js fault`, `GPU Fault`, `Unhandled Page fault`,
  `gpu soft reset timed out` / `hard reset timed out`, `AS_ACTIVE bit
  stuck`, `error powering up gpu`, `... power transition timeout`
  (`pf/panfrost_job.c:440,770`, `pf/panfrost_gpu.c:39,75,81,419-457`,
  `pf/panfrost_mmu.c:42,724`);
* rendering corruption, a frozen or crashed compositor;
* `microvolts` or the `aclk_g3d` rate not equal to the expected value;
* any thermal zone ≥ 85 °C (section 4), or the GPU cooling state leaving
  0 during a pinned step (a trip is active: the step no longer tests F;
  let it cool and repeat);
* a reset (watchdog): the next boot comes back without panfrost
  (blacklisted); read the hung boot's console from ramoops (pstore).

The highest level that passes becomes the daily maximum (`max_freq`,
udev rule of section 10.4); soak it for 30 minutes before relying on it.
Release the pin with `echo 0 > $D/min_freq; echo 0 > $D/max_freq`
(0 = no limit, `devfreq.c:1645-1652`).

**Throttle test** (no heat needed; `CONFIG_THERMAL_EMULATION=y`,
`gts28ltexx_defconfig:134`): with the governor free and the GPU loaded,
`Z=` the apollo zone (`type` = apollo-thermal), `C=` the GPU cooling device.

* `echo 82000 > $Z/emul_temp` → within ~1 s `cat $C/cur_state` = 4 and
  `cur_freq` ≤ 420000000;
* `echo 87000 > $Z/emul_temp` → state 7, 160000000 (the apollo hot trip
  at 86 °C only logs);
* `echo 0 > $Z/emul_temp` → back to state 0 once the reading falls
  (step_wise releases on a falling trend). Do not emulate ≥ 110 °C
  (hot/critical trips; 115 °C powers the board off).

**Rollback**: boot the previous DTB/kernel, or at run time pin 266 MHz
(BUCK6 then stays at 1 037 500 µV, not the boot 937 500).

### 10.9 Build check (2026-10-29)

Own Docker volume `t715-kbuild-out-gpufreq`, source mounted read-only, the
tree as it stood (with the uncommitted board/defconfig work of others):

* `gts28ltexx_defconfig` + `gts28ltexx_gpufreq.config` + `olddefconfig`:
  `.config` has `DRM_PANFROST=m`, `PM_DEVFREQ=y`,
  `DEVFREQ_GOV_SIMPLE_ONDEMAND=y`, `DEVFREQ_THERMAL=y`, `PM_OPP=y`,
  `THERMAL_OF=y`, `THERMAL_GOV_STEP_WISE=y`.
* Test wrapper outside the repo (board `.dts` + the new dtsi), compiled
  with the kernel's cpp + dtc command line: exit 0, no dtc warning, also
  with `-Wnode_name_chars_strict -Wproperty_name_chars_strict
  -Wunique_unit_address_if_enabled` (same warnings as the plain board).
  The plain board DTB built this way is byte-identical to kbuild's.
* Symbolic diff of the two merged trees (`dtc -I dts -O dts`): only the
  new `opp-table-gpu` (8 OPPs, values as section 10.3), `gpu@14ac0000`
  gaining `operating-points-v2 = <&gpu_opp_table_gts28>` and
  `#cooling-cells = <2>` (no `opp-table` child), the six passive trips
  and their cooling-maps (`<&gpu 4 4>`, `5 5`, `6 6`, `7 7` on g3d;
  `4 4`, `7 7` on apollo), phandle renumbering. BUCK6 unchanged
  (600 000-1 500 000 µV, ramp 12 000, always-on). Decompiled DTB checked
  for the same nodes.
* `dt-validate` (dtschema 2026.9, `processed-schema.json` from
  `make CHECK_DTBS=y`): the same 72 lines of findings for the plain board
  and the gpufreq DTB, none in the gpu, OPP, thermal-zone or BUCK6 nodes.

### 10.10 First run on the tablet (2026-10-29)

Kernel `6.12.114-00020-g8e16c2ef410c-dirty`, built from the daily tree
with the gpufreq fragment and a test wrapper. The wrapper is not committed:
`exynos5433-gts28ltexx-gpufreqtest.dts` is `/dts-v1/;` plus
`#include "exynos5433-gts28ltexx.dts"` and
`#include "exynos5433-gts28ltexx-gpufreq.dtsi"`, with one line in the
samsung Makefile after `exynos5433-gts28ltexx.dtb`. The tablet booted Phosh
through `t715.rootimg` and the test ran over SSH
(`device/gpu-flow.sh` and `gpu-ssh.sh`; raw logs are kept privately).

What works:

* `/sys/class/devfreq/14ac0000.gpu`, governor `simple_ondemand`, the
  8 OPPs 160-700 MHz listed; cooling device `devfreq-14ac0000.gpu`,
  `max_state` 7.
* The clock and the voltage follow the OPP. `aclk_g3d` reads exactly the
  requested rate, and `vdd_g3d` reads 1 037 500 µV at 266 and 350 MHz and
  1 137 500 µV at 600 MHz. The governor goes up to 600 MHz under load
  (41 transitions, every level visited, 1.3 s at 700 MHz).
* No kernel warning (the 4 counted were sshd's post-quantum notices: the
  counter must match `WARNING: CPU`), Phosh still active, temperatures
  54-59 °C.

What the run could not show: stability per level. The load,
GStreamer `gltestsrc pattern=mandelbrot` rendered surfaceless (EGL) at
1536x2048, faults on every job from its first frame at the boot clock
(266 MHz, the daily kernel's rate). The kernel logs "Unhandled Page fault
in AS0 at VA 0x000000000B6C0000" (always that VA), `JOB_BUS_FAULT` on
js 0, then "gpu sched timeout". That is about 57 faults per 10 s during
every load, at any frequency, and none between loads. The 3.8-3.9 frames/s
measured at every level is the job timeout rate, not the GPU's
throughput. The script stopped at its first level (350 MHz) because the
fault count grew, which was the load's own fault, not the clock.

phoc renders on panfrost without faults, so the fault comes from this
client. Next steps: find out whether it is the surfaceless platform, the
shader, or Mesa's Midgard compiler (try another `gltestsrc` pattern, or
kmscube/glmark2 on KMS), then repeat the stepping with a load that runs
clean at 266 MHz. Until then the daily kernel keeps panfrost at its boot
clock (no devfreq). A 420 MHz candidate exists (section 10.11), not yet
validated.

### 10.11 Candidate daily kernel: devfreq capped at 420 MHz (2026-10-29)

Kernel commit `9510f7e46`, branch **`t715-gpu420`** (moved off
`t715-bringup` after the aborted validation; merge it back only once the
levels pass on the device). The board includes
`exynos5433-gts28ltexx-gpufreq.dtsi`, deletes its 500, 550, 600 and
700 MHz OPPs (`/delete-node/` after the include) and overrides every GPU
cooling-map. The defconfig has the devfreq options (section 10.6).

**Why 420 MHz.** Mainline never programs the G3D adaptive body bias:
on the tablet, PMU + 0x0790 reads `0x8000008d`, stock's idle reverse-bias
value (`ABB_X125`), where stock runs the GPU at `0x80000088` (`ABB_X100`,
no bias; risk 7). The GPU therefore runs with less timing margin than
under stock, by an amount the sources do not give. The of
2026-10-29 chose 420 MHz for the daily kernel until the kernel writes
`ABB_X100` at G3D power-on (Omarchy repo `docs/journal/ONDEVICE-2026-10-29.md`,
"GPU frequency:" and the second that follows).
That write is on branch `t715-g3d-abb` (section 10.12), which keeps
this cap until the tablet has confirmed it.
This kernel is shared by the Phosh and the Omarchy root images, so the
cap is in the device tree, not in a udev rule (section 10.4).

**Why in the board.** The dtsi stays the full design (8 OPPs, voltages
of section 10.3, states numbered for 8), so test builds can use every
level, and raising the cap later means removing `/delete-node/` lines and
renumbering the maps.

Remaining OPPs: 160, 266, 350 MHz at 1 037 500 µV, 420 MHz at
1 062 500 µV. Cooling states (risk 9): 0 = 420, 1 = 350, 2 = 266,
3 = 160 MHz, `max_state` 3. A cap at state 0 would do nothing, so each
trip caps one step below the dtsi's level, down to 160 MHz:

| zone | trip | dtsi state (8 OPPs) | daily state (4 OPPs) |
|---|---|---|---|
| apollo-thermal | 81 °C | 4 → 420 MHz | **1 → 350 MHz** |
| apollo-thermal | 86 °C | 7 → 160 MHz | **3 → 160 MHz** |
| g3d-thermal (inert) | 95 °C | 4 → 420 MHz | **1 → 350 MHz** |
| g3d-thermal (inert) | 100 °C | 5 → 350 MHz | **2 → 266 MHz** |
| g3d-thermal (inert) | 105 °C | 6 → 266 MHz | **3 → 160 MHz** |
| g3d-thermal (inert) | 110 °C | 7 → 160 MHz | **3 → 160 MHz** |

Hot and critical trips unchanged. The throttle test of section 10.8 with
this kernel: `emul_temp` 82000 gives state 1 (350 MHz), 87000 state 3
(160 MHz). The cooling device should report `max_state` 3.

**Image (built 2026-10-29, not flashed).** Kernel
`6.12.114-00024-g9510f7e46ce7`, default `kernel/kbuild-mainline.sh` build
(no fragment; its `.config` is identical to the gpufreq test build's).
The decompiled DTB differs from the test kernel's (`c756b027c`) only by
the four deleted OPP nodes and the six `cooling-device` values. Daily
initramfs recipe of `device/README.md` (knobs
`t715.usbfn=ecm t715.failwait=300`, modules of this build) in
`out/initramfs-daily-gpu420/`, image
`out/test-recovery-daily-gpu420/recovery.img`, sha256
`926b7a70537dd8d5515cf9bd37850b4155a5604599b0b0390af40faa07afb102`.
`flash-daily.sh` still flashes `test-recovery-daily/` (the 00021 image,
the rollback); its kernel output is kept in
`out/mainline-daily-00021/`. To check after flashing:
`available_frequencies` lists 160-420 MHz only, the GPU cooling device
has `max_state` 3 and is bound to apollo's 81/86 °C trips.

### 10.12 G3D adaptive body bias (branch `t715-g3d-abb`, 2026-10-29)

Kernel commit `094007a9b` on branch `t715-g3d-abb`, one commit on top of
`t715-bringup` `9510f7e46` (patch series `kernel/patches/t715-g3d-abb/`).
Built, not flashed. The 420 MHz cap of section 10.11 is unchanged: raising
it is a separate decision, after the checks below.

Extra path abbreviations: `abb.c` =
`src/linux-6.12/drivers/soc/samsung/exynos5433-g3d-abb.c`;
`gpd.c` = `src/linux-6.12/drivers/pmdomain/core.c`;
`cal.h` = `stock/arch/arm/mach-exynos/include/mach/asv-exynos5_cal.h`;
`notif.c` = `mali/gpu_notifier.c`.

| file (under `src/linux-6.12/`) | what |
|---|---|
| `drivers/soc/samsung/exynos5433-g3d-abb.c` (new) | platform driver, built in: genpd power notifier on `pd_g3d` that writes PMU BB_CON4 through the PMU syscon regmap; debugfs file |
| `drivers/soc/samsung/Kconfig`, `Makefile` | `EXYNOS5433_G3D_ABB` (bool; `PM_GENERIC_DOMAINS`, `OF`; selects `MFD_SYSCON`) |
| `arch/arm/configs/gts28ltexx_defconfig` | `CONFIG_EXYNOS5433_G3D_ABB=y` |
| `arch/arm/boot/dts/samsung/exynos5433-gts28ltexx.dts` | section 12: node `gpu-abb` under `&pmu_system_controller` (`compatible = "samsung,exynos5433-g3d-abb"`, `power-domains = <&pd_g3d>`, `samsung,abb-on-level = <8>`, `samsung,abb-off-level = <13>`); the cap comment updated |

**Register and values.**

| item | value | stock source |
|---|---|---|
| register | PMU + 0x0790 = 0x105C0790, BB_CON4 | `abb_base_arr[SYSC_DVFS_G3D] = CHIPID_ABBG_BASE + 0x0790` (`cal.c:26`); `CHIPID_ABBG_BASE` = `S5P_VA_CHIPID5` (`cal.h:42`), mapped from `EXYNOS_PA_CHIPID5` 0x105C0000 (`stock/arch/arm/mach-exynos/include/mach/map.h:79`, `stock/arch/arm/mach-exynos/common.c:885-889`) = `EXYNOS5430_PA_PMU` (`map.h:87`); named `EXYNOS5433_BB_CON4` (`stock/arch/arm/mach-exynos/include/mach/regs-pmu-exynos5433.h:46`), `EXYNOS5430_BB_CON4` (`regs-pmu.h:806`, saved around system suspend by `stock/arch/arm/mach-exynos/asv-exynos5433.c:365`) |
| encoding | `(1 << 31) \| (1 << 7) \| (level & 0x1f)`; 0 for `ABB_BYPASS` (255) | `cal_set_abb()`, `cal.c:484-495`; `BIT(31) \| BIT(7)` = `EXYNOS_ABB_INIT` 0x80000080 (`regs-pmu.h:104`) |
| on: level 8, **0x80000088** | `ABB_X100` | `cal.h:108`; this chip's table: ASV table version 8 → `abb_table_g3d_v3` (`cal.c:443-449`), 8 at every frequency and group (`asv.h:344-355`); logged by stock at all eight levels, "[G3D] DEVFREQ: ...Khz, ABB 8" (`boot-log:1118-1132`, printed by `mali/gpu_dvfs_governor.c:275`) |
| off: level 13, **0x8000008d** | `ABB_X125` | `cal.h:113`; `G3D_RBB_VALUE` 0x8d (`mali/gpu_exynos5433.c:41`), masked by `cal_set_abb()` to 13 |
| table path, not fused ABB | `cal_get_fs_abb()` = CHIPID + 0x4010 bit 20 (`cal.c:110-115`) is 0 on this chip | inferred: fused ABB gives one 4-bit value per rail at every level (`cal.c:456-470`), but the stock logs show ARM at 255 for LV0-5 and 8 below (`boot-log:699-722`, `asv.h:295-302`), which only the tables give. Read-only check T0 below |

Table versions 0-4 would select `ABB_BYPASS` for G3D (`asv.h:81`, `:170`,
`cal.c:422-435`), hence the levels in the board file rather than in the
driver.

**What stock does.** `GPU_DYNAMIC_ABB` and `GPU_DVS` are on
(`mali/gpu_exynos5433.c:103,105`, read at `mali/mali_kbase_platform.c:262,266`).

* GPU needed (kbase `power_on_callback`): `gpu_disable_dvs()` writes the
  level of the current DVFS step, 8 here, then lowers the DVS pin
  (`mali/gpu_exynos5433.c:658-679`), **before** `pm_runtime_resume()`
  powers the domain up (`notif.c:180-182`).
* GPU idle (`power_off_callback`, `power_suspend_callback`):
  `gpu_enable_dvs()` raises the DVS pin (BUCK6 to its DVS level) and
  writes `G3D_RBB_VALUE` (`mali/gpu_exynos5433.c:635-656`), before the
  runtime suspend that powers the domain down (`notif.c:204-206,219-221`).
* Every DVFS step rewrites the step's level, 8 again
  (`mali/gpu_exynos5433.c:594-614`).
* System suspend: all BB_CON registers saved, set to bypass, restored on
  resume (`asv-exynos5433.c:360-389`). Mainline has no suspend here.

So under stock the register is 8 whenever the GPU runs and 0x8d whenever
the domain is off (and while it idles in DVS at the DVS voltage, a state
mainline does not have).

**Design.** `abb.c` binds to the `gpu-abb` node, a child of the PMU
system controller placed in `pd_g3d`, and adds a genpd power notifier
(`dev_pm_genpd_add_notifier()`, `gpd.c:1959`):

* `GENPD_NOTIFY_PRE_ON` → on level. Sent before the PMU powers the
  block (`gpd.c:739-741`) and, on a runtime resume, before any driver
  callback of the domain's devices (`genpd_runtime_resume()` powers the
  domain at `gpd.c:1221`, the driver's `runtime_resume` runs at `:1236`).
  This is stock's order (level written before `pm_runtime_resume()`), and
  the block is never powered with the off level. If the write fails the
  notifier returns the error and genpd aborts the power-on.
* `GENPD_NOTIFY_OFF` → off level, once the block is gated
  (`gpd.c:824`). Writing at `PRE_OFF` would leave the block powered with
  0x8d for a moment; writing at `OFF` keeps "8 whenever powered" strict.
* Error paths are covered by genpd's own events: a failed power-on is
  followed by `OFF` (`gpd.c:777`, off level back), a failed power-off by
  `ON` (`gpd.c:828`), with the on level never removed.

**Restore 0x8d, or leave 8?** Restored. Leaving 8 would be functionally
fine (the bias of a gated block does not matter), but restoring gives,
at every moment, the value stock has in the same power state: 8 while
the domain is powered, 0x8d while it is off, which is also the value
the bootloader leaves for the next kernel. It costs two PMU writes per
domain cycle, and genpd sends `PRE_ON` on every power-up, so the
switch cannot be skipped.

**Probe and ordering.** The platform bus attaches the node to `pd_g3d`
and powers the domain on before `probe()` (`drivers/base/platform.c:1371`,
`gpd.c:3006-3010`). While the device's runtime PM is still disabled,
genpd counts it as active (`pm_runtime_suspended()` false,
`gpd.c:899-902`), so the domain cannot go off during probe: the driver
adds the notifier, writes the on level, then enables runtime PM in its
initial suspended state, after which the node never holds the domain.
The driver core then syncs the domain (`drivers/base/dd.c:763-764`, `genpd_dev_pm_sync()`,
`gpd.c:2949-2958`), which powers it off if nothing else needs it (off
level). The driver is built in (device initcall), panfrost is a module
loaded by the initramfs after its watchdog guard, so the notifier is
always in place before panfrost's attach powers the domain up, and
before panfrost sets its first OPP (`pf/panfrost_device.c:218`) or
submits a job. The only moments the domain is powered with 0x8d are at
boot, before this driver's probe (bootloader, `cmu_g3d`'s probe, this
node's own attach), when no GPU job can run.

**When the domain actually switches.** Once panfrost is bound, `pd_g3d`
stays on: panfrost keeps `aclk_g3d` prepared, which keeps `cmu_g3d`
runtime-active (section 4). panfrost's runtime suspend (50 ms
autosuspend) therefore does **not** power the domain off and the
register stays at 0x80000088 while the GPU idles. The expected sequence
per boot is: probe (domain on, 0x8d → 0x88), off after the sync
(0x88 → 0x8d) if `cmu_g3d` is suspended, then on again at panfrost's
attach (0x8d → 0x88) for the rest of the session. 0x8d comes back only
when panfrost is removed.

**Observability.**

* dmesg, device `105c0000.system-controller:gpu-abb`: at probe
  `G3D ABB 0x80000088 while pd_g3d is on, 0x8000008d while off; BB_CON4
  was 0x........, now 0x80000088`; per transition (rate-limited)
  `pd_g3d power-on: BB_CON4 0x8000008d -> 0x80000088` and
  `pd_g3d power-off: BB_CON4 0x80000088 -> 0x8000008d`. dev_info, not
  dev_dbg: `CONFIG_DYNAMIC_DEBUG` is off in this build.
* `/sys/kernel/debug/exynos5433-g3d-abb`: `bb_con4` (read from the
  register at each read, through the regmap; the PMU is always on), `on`,
  `off`, `power_on_count`, `power_off_count`.
* The register itself, read-only through `/dev/mem` (below).

**Build (2026-10-29).** `W=1` compile of `abb.c`: no warning;
`checkpatch.pl --strict`: clean. `kernel/kbuild-mainline.sh` with
`KBUILD_VOLUME=t715-kbuild-out-g3d-abb` (a copy of the default volume)
and `KBUILD_OUT_DIR=out/mainline-g3d-abb`: kernel
`6.12.114-00025-g094007a9b5f4`, zImage 4 045 592 bytes, arm64
non-regression OK. Against the 420 MHz daily build
(`out/mainline/`, untouched), the `.config` differs by
`CONFIG_EXYNOS5433_G3D_ABB=y` only, and the decompiled board DTB by the
`gpu-abb` node only; `System.map` has `g3d_abb_probe` and
`g3d_abb_notify`. Daily initramfs (knobs `t715.usbfn=ecm
t715.failwait=300`, this build's modules) in
`out/initramfs-g3d-abb/`, identical to the gpu420 one except the
module tree; image `out/test-recovery-g3d-abb/recovery.img`,
sha256 `8d3f2f94e65673abc32647bf4707aba6852eacb496ab44738d86d1f4bd95f412`
(unpacked and checked: kernel = zImage, ramdisk = initramfs, the DTBH
blob has the `gpu-abb` node, "Linux version 6.12.114-00025-g094007a9b5f4").
`test-recovery-daily/` and `test-recovery-daily-gpu420/` are unchanged.
The kernel tree is left on `t715-bringup`: switch to `t715-g3d-abb`
before rebuilding this image (same two variables; the build reuses the
`t715-kbuild-out-g3d-abb` volume).

**Device test plan.** Flash `test-recovery-g3d-abb/recovery.img` with
`device/flash-boot.sh` (RECOVERY only). As root, with debugfs
mounted (`gpufreq.sh` mounts it). Read-only PMU/CHIPID reader, the
`abb()` helper of the Omarchy repo's `tests/ondevice/gpufreq.sh`
widened to any offset (the PMU and CHIPID blocks are always on; never
read CMU_G3D or GPU registers this way). `g3d` reads the domain's
status register, `pd_g3d` base 0x105C4060 + 4, which the domain driver
polls for 0xf (on) or 0 (off)
(`drivers/pmdomain/samsung/exynos-pm-domains.c:52,81`):

```sh
rd() { python3 -c 'import mmap,os,struct,sys
b,o=int(sys.argv[1],0),int(sys.argv[2],0)
fd=os.open("/dev/mem",os.O_RDONLY|os.O_SYNC); m=mmap.mmap(fd,0x5000,mmap.MAP_SHARED,mmap.PROT_READ,offset=b)
print("0x%08x" % struct.unpack("<I",m[o:o+4])[0])' "$1" "$2"; }
abb()  { rd 0x105C0000 0x0790; }   # BB_CON4
g3d()  { rd 0x105C0000 0x4064; }   # pd_g3d status: low nibble f = on, 0 = off
dbg()  { cat /sys/kernel/debug/exynos5433-g3d-abb; }
```

* **T0 pre-check (read-only).** With 32-bit reads as in step P4 of
  section 10.8 (`busybox devmem`; the python reader above is only proven
  on the PMU): `busybox devmem 0x1000400C 32`, bits 3:0 = 8 (ASV table
  version, `cal.c:103-108`); `busybox devmem 0x10004010 32`, bit 20 = 0
  (no fused ABB, `cal.c:110-115`). If the version is below 5, or bit 20 is
  1, stop: the board levels are wrong for this chip (version 0-4:
  `samsung,abb-on-level = <255>`, bypass; fused: stock writes the fused
  value of bits 11:8 and never 0x8d).
* **T1 boot.** `dmesg | grep -e gpu-abb -e panfrost -e 'Power domain'`:
  the probe line with `was 0x8000008d` (the bootloader's value, as read
  before) and `now 0x80000088`; then usually `pd_g3d power-off:
  0x80000088 -> 0x8000008d`; then `pd_g3d power-on: 0x8000008d ->
  0x80000088` **before** panfrost's `clock rate = ...` line (ordering
  check). Not expected: `cannot write BB_CON4`, `cannot add a pd_g3d
  notifier`, `missing samsung,abb-...`, `no PMU regmap`, `Power domain
  G3D enable failed` / `disable failed`, or panfrost failing to probe.
* **T2 GPU in use** (session up, GPU busy, e.g. opening shell panels):
  `abb` = 0x80000088, `g3d` low nibble f, `dbg` shows `bb_con4:
  0x80000088` and `power_on_count` ≥ 1. With `gpufreq.sh`, every `st`
  line (panfrost loaded) prints `abb=0x80000088` at every pinned level.
  Its P4 pre-check runs before panfrost is loaded: there 0x8000008d with
  `g3d` low nibble 0 (domain off) is the expected value, 0x80000088 with
  the domain on as well.
* **T3 GPU idle.** After 1 s without GPU work,
  `cat /sys/bus/platform/devices/14ac0000.gpu/power/runtime_status` is
  `suspended`, and `abb` still 0x80000088 with `g3d` on: expected (the
  domain stays on while panfrost is bound, see above), not a failure.
* **T4 domain off (optional, needs the session stopped).**
  `systemctl isolate multi-user.target`, then `rmmod panfrost`: dmesg
  `pd_g3d power-off: BB_CON4 0x80000088 -> 0x8000008d`, `abb` =
  0x8000008d, `g3d` low nibble 0, `power_off_count` + 1. `modprobe
  panfrost`: `pd_g3d power-on: ... -> 0x80000088` before panfrost's
  probe lines, `abb` 0x80000088, `power_on_count` + 1. If the domain
  stays on after `rmmod` (`g3d` still f, no line), something else holds
  it (`cat /sys/kernel/debug/pm_genpd/G3D/devices` names the devices):
  report, not a failure of the bias. If `rmmod` hangs: `systemctl
  reboot`.
* **T5 no regression**: the same GPU faults as before or fewer
  (`grep -c -e 'js fault' -e 'Unhandled Page fault' -e 'sched timeout'`),
  no new message type. Removing the reverse bias only adds timing margin
  at a given clock; stock ran the GPU at this level all along.

Pass = T0-T3 (T4 if run). Then the's condition for revisiting
the cap ("until mainline writes level 8 at G3D power-on") is met:
merge the commit into `t715-bringup`, and re-run the gpufreq stepping
with ABB at 0x80000088 before raising the daily cap to 500 MHz.

**Risks and unknowns.**

1. The meaning of bits 31 and 7 is not in the sources: the driver copies
   stock's encoding (`EXYNOS_ABB_INIT` plus the level) bit for bit.
2. Idle leakage: with the domain kept on by panfrost, the idle GPU now
   sits at 8 instead of the 0x8d it had by accident, at the OPP voltage
   (no DVS pin, risk 6). A small idle-power cost compared with the
   current daily kernel, none compared with a GPU that is running.
3. The levels are this chip's (table version 8, not fused); T0 checks
   that. Another SM-T715 unit could have a different table version.
4. Domain powered with 0x8d at boot before the probe (bootloader,
   `cmu_g3d` probe, the node's attach): no GPU job runs then.
5. Not checked on the tablet. T4 relies on `rmmod panfrost`, which has
   not been exercised on this board.
