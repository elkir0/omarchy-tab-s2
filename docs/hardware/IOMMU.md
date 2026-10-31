# DECON System MMU — SM-T715 (Exynos 5433), mainline 6.12 arm32

Build-tested only; no device was touched. Goal: let exynos-drm import the
non-contiguous dma-bufs that panfrost allocates (today rejected with "buffer
chunks must be mapped contiguously", which kills every GL client under
Hyprland unless the `LD_PRELOAD` shim
`image/rootfs/shim/t715-dmabuf-check-shim.c` is loaded), and
scan them out directly.

Verdict: **safe to test with the two new files below and no driver change.**
The one hazard found (section 5) needs the bootloader's DECON to still be
fetching when DECON probes; by the code it has been powered off long before,
and the on-device behaviour agrees. If that reading is wrong, the result is
a kernel panic and a software reset to Android, not a hang.

Path abbreviations:

* `soc` = `src/linux-6.12/arch/arm64/boot/dts/exynos/exynos5433.dtsi`
* `board` = `src/linux-6.12/arch/arm/boot/dts/samsung/exynos5433-gts28ltexx.dts`
* `iommu.c` = `drivers/iommu/exynos-iommu.c`; `core.c` (IOMMU) = `drivers/iommu/iommu.c`
* `dma-mapping.c` = `arch/arm/mm/dma-mapping.c`
* `decon.c` = `drivers/gpu/drm/exynos/exynos5433_drm_decon.c`;
  `drm_dma.c`, `drm_gem.c` = `drivers/gpu/drm/exynos/exynos_drm_{dma,gem}.c`
* `genpd.c` = `drivers/pmdomain/core.c`; `pd.c` = `drivers/pmdomain/samsung/exynos-pm-domains.c`
* `live_fdt` = `dumps/live_fdt.dts` (the running stock tree)

Kernel paths are relative to `src/linux-6.12/`.

## 1. Files

| file | what |
|---|---|
| `arch/arm/boot/dts/samsung/exynos5433-gts28ltexx-iommu.dtsi` | `sysmmu_decon0x/1x` okay; the ten other System MMUs and their seven masters disabled |
| `arch/arm/configs/gts28ltexx_iommu.config` | `IOMMU_SUPPORT`, `EXYNOS_IOMMU`, `EXYNOS_IOMMU_DEBUG` (first test only) |
| `docs/hardware/IOMMU.md` | this document |

Nothing includes them yet. To test: append
`#include "exynos5433-gts28ltexx-iommu.dtsi"` to the board file (after
section 10, display) and build with
`bash kernel/kbuild-mainline.sh --fragment gts28ltexx_iommu.config`.
No driver patch is needed (section 5.5 explains why none is proposed).

## 2. Why imports fail today

Hyprland imports each client buffer into the exynos-drm render node.
`exynos_drm_gem_prime_import()` attaches the dma-buf to `priv->dma_dev`,
the DECON device (`drm_gem.c:399-403`, `exynos_drm_drv.h:211-216`,
`drm_dma.c:100-104`). panfrost exports through the shmem helper
(`panfrost_gem.c:233`), so `drm_gem_map_dma_buf()` maps the page list with
`dma_map_sgtable(attach->dev, …)` for DECON (`drm_prime.c:651-677`, line 668).
Without an IOMMU, DECON uses dma-direct: every segment keeps its physical
address, `drm_prime_get_contiguous_size()` stops at the first gap
(`drm_prime.c:872-890`) and the import is refused at `drm_gem.c:436-438`.

## 3. Device tree state (question 1)

### 3.1 System MMU nodes (`soc`)

None of them has a `status`, so all twelve are enabled once
`CONFIG_EXYNOS_IOMMU=y`. All have `#iommu-cells = <0>`, clock names
`aclk`/`pclk`.

| node | reg | IRQ (SPI) | clocks | power domain | lines |
|---|---|---|---|---|---|
| `sysmmu_decon0x` | 0x13a00000 | 192 | `cmu_disp` ACLK/PCLK_SMMU_DECON0X | `pd_disp` | 1287-1296 |
| `sysmmu_decon1x` | 0x13a10000 | 194 | `cmu_disp` ACLK/PCLK_SMMU_DECON1X | `pd_disp` | 1298-1307 |
| `sysmmu_tv0x` | 0x13a20000 | 214 | `cmu_disp` ACLK/PCLK_SMMU_TV0X | `pd_disp` | 1309-1318 |
| `sysmmu_tv1x` | 0x13a30000 | 216 | `cmu_disp` ACLK/PCLK_SMMU_TV1X | `pd_disp` | 1320-1329 |
| `sysmmu_gscl0` | 0x13c80000 | 288 | `cmu_gscl` ACLK/PCLK_SMMU_GSCL0 | `pd_gscl` | 1331-1340 |
| `sysmmu_gscl1` | 0x13c90000 | 290 | `cmu_gscl` …GSCL1 | `pd_gscl` | 1342-1351 |
| `sysmmu_gscl2` | 0x13ca0000 | 292 | `cmu_gscl` …GSCL2 | `pd_gscl` | 1353-1362 |
| `sysmmu_scaler_0` | 0x15040000 | 404 | `cmu_mscl` …M2MSCALER0 | `pd_mscl` | 1364-1373 |
| `sysmmu_scaler_1` | 0x15050000 | 406 | `cmu_mscl` …M2MSCALER1 | `pd_mscl` | 1375-1384 |
| `sysmmu_jpeg` | 0x15060000 | 408 | `cmu_mscl` …JPEG | `pd_mscl` | 1386-1395 |
| `sysmmu_mfc_0` | 0x15200000 | 352 | `cmu_mfc` …MFC_0 | `pd_mfc` | 1397-1406 |
| `sysmmu_mfc_1` | 0x15210000 | 354 | `cmu_mfc` …MFC_1 | `pd_mfc` | 1408-1417 |

The DECON pair matches the stock tree: `sysmmu@0x13A00000` (IRQ 0xc0) and
`sysmmu@0x13A10000` (IRQ 0xc2), both with `mmu-masters` = the stock DECON
`decon_fb` (`live_fdt:1482-1491`, `1527-1536`, `990-1000`). So Android does
translate DECON's DMA through them. Port split from the stock `winmap`: M0
(0x13a00000) carries windows 0-2 (`0x07`, `live_fdt:1489`), M1 carries
windows 3-4 (`0x18`, `live_fdt:1534`). exynos-drm uses window 2 as the
primary plane and window 4 as the cursor (`decon.c:34-36`), so both are needed.

**DECON's System MMUs are in the DISP domain** (`soc:1294`, `1306`), like
DECON (`soc:968`) and `cmu_disp` (`soc:480`). While the display runs DECON
is runtime-active (`decon.c:520`), and the System MMUs, its runtime-PM
suppliers through the link that `exynos_iommu_probe_device()` creates
(`iommu.c:1412-1414`), are active too. So `pd_disp` is on whenever they
translate.

### 3.2 Masters with `iommus`, and what EXYNOS_IOMMU=y would do to each

| master | `iommus` | status on this board | driver in our .config | effect with EXYNOS_IOMMU=y and the plain SoC dtsi | with the new dtsi |
|---|---|---|---|---|---|
| `decon` 0x13800000 | decon0x, decon1x (`soc:975-976`) | okay (`-m3.dtsi`) | DRM_EXYNOS5433_DECON=y | attached; exynos-drm switches to an IOMMU mapping (the goal) | unchanged |
| `decon_tv` 0x13880000 | tv0x, tv1x (`soc:1018-1019`) | disabled (`soc:1017`) | — | never probed; its two System MMUs still probe (version read in `pd_disp`) | System MMUs disabled |
| `gsc_0..2` 0x13c00000-0x13c20000 | gscl0..2 (`soc:1152`, `1167`, `1182`) | **okay** (no status) | none (DRM_EXYNOS_GSC not set, MEDIA_SUPPORT not set) | masters not probed; three System MMUs probe in `pd_gscl` | masters and System MMUs disabled |
| `scaler_0/1` 0x15000000/0x15010000 | scaler_0/1 (`soc:1245`, `1257`) | **okay** | none (DRM_EXYNOS_SCALER not set) | two System MMUs probe in `pd_mscl` | disabled |
| `jpeg` 0x15020000 | jpeg (`soc:1270`) | **okay** | none (no MEDIA_SUPPORT) | System MMU probes in `pd_mscl` | disabled |
| `mfc` 0x152e0000 | mfc_0, mfc_1 (`soc:1282-1283`) | **okay** | none (no MEDIA_SUPPORT) | two System MMUs probe in `pd_mfc` | disabled |

Driver availability was read from a `gts28ltexx_defconfig` `.config` built
on 2026-10-29 (`MEDIA_SUPPORT`, `DRM_EXYNOS_GSC/SCALER/FIMC/ROTATOR/G2D`,
`DRM_EXYNOS_MIXER/HDMI` all not set). `hdmi`, `dsi`, `mic` and `gpu` have no
`iommus`.

A master is attached only when its own driver probes: the OF code builds its
fwspec in `of_dma_configure_id()` (`drivers/of/device.c:156`), called from
`really_probe()` (`drivers/base/dd.c:698-699`); `iommu_device_register()`'s
bus walk skips devices without a fwspec (`core.c:528-530`, `1648-1660`). So
today only DECON would be attached. The cost of leaving the other ten
System MMUs enabled is their own probe, which powers their domain, enables
two clocks and reads a register (section 4) in blocks where no System MMU
access has ever run on this board. **The new dtsi disables them** and, with
them, their masters: with its System MMU disabled a master falls back to no
IOMMU (`drivers/iommu/of_iommu.c:29-30`, `drivers/of/device.c:164-168`), and the
exynos-drm GSC and scaler drivers ignore `exynos_drm_register_dma()`'s
result (`exynos_drm_gsc.c:1178`, `exynos_drm_scaler.c:457`). Enabling one of
those drivers later with its System MMU off would make it DMA to DECON's
IO virtual addresses as if they were physical. Re-enable a master only
together with its System MMU. fw_devlink ignores unavailable suppliers
(`drivers/of/property.c:1150-1156`), so nothing is held back by the
disabled nodes.

## 4. What the System MMU driver touches (question 2)

### 4.1 Boot order

* `exynos_iommu_init()` is a `core_initcall` (`iommu.c:1488-1527`); the
  devices appear at `arch_initcall_sync` (`drivers/of/platform.c:600`) and
  probe as their suppliers (power domain, clocks) are ready.
* fw_devlink tracks `iommus` (`drivers/of/property.c:1293`): DECON cannot
  probe before both DECON System MMUs are bound (`dd.c:678`).
* Everything here is built in, so it all runs before the initramfs
  watchdog guard.

### 4.2 Probe (`exynos_sysmmu_probe()`, `iommu.c:726-824`)

| step | lines | hardware access |
|---|---|---|
| ioremap, `devm_request_irq()` | 737-751 | none |
| `devm_clk_get_optional()` sysmmu/aclk/pclk/master | 753-772 | none (`-EPROBE_DEFER` if `cmu_disp` is not there) |
| `__sysmmu_get_version()` | 777, 515-546 | `clk_prepare_enable()` of pclk and aclk (`clk`/`clk_master` are NULL here), **one `readl(REG_MMU_VERSION)`** at 0x34 (521), clocks off again (545). v7 only: two more reads (501-513, 537-538), not reached on 5433 (v5, see below) |
| `iommu_device_sysfs_add()`, `dma_set_mask(36 bit)` for v5+ | 779-804 | none |
| `pm_runtime_enable()` | 813 | none |
| `iommu_device_register()` | 815, `core.c:250-273` | none: walks the buses, but no device has a fwspec yet |

Conditions during the version read:

* **Power:** `platform_probe()` attaches the device to `pd_disp` with
  power-on before calling the driver (`drivers/base/platform.c:1371`;
  `genpd.c:3006-3008`; a failed power-on returns `-EPROBE_DEFER`,
  `genpd.c:3020`, so the driver is not even called). Until line 813 the
  device's runtime PM is disabled, which genpd counts as "not suspended"
  (`include/linux/pm_runtime.h:150-154`, `genpd.c:894-901`): the domain
  cannot be switched off under the read.
* **Clocks:** the two gates are in `cmu_disp` (`clk-exynos5433.c:2748-2755`,
  `2805-2812`); `clk_prepare()` runtime-resumes `cmu_disp` first
  (`drivers/clk/clk.c:1112-1122`), and `cmu_disp` sits in the same, powered
  domain. The DISP SFR bus bridges (`aclk_ahb2apb_dispsfr0p/1p/2p`,
  `aclk_ahb_disph`) are `CLK_IGNORE_UNUSED` (`clk-exynos5433.c:2773-2783`)
  and never gated by Linux; DECON, DSIM and MIC registers are reached the
  same way today.
* `__sysmmu_enable_clocks()` uses `BUG_ON()` on a clock-enable failure
  (`iommu.c:485-491`): an oops, hence a panic (`oops=panic`), not a hang.

Version: mainline handles v1-v3, v5 and v7 (`iommu.c:532-543`). The stock
LineageOS kernel drives these blocks with `EXYNOS7_IOMMU`
(`kernel_universal5433/arch/arm/configs/lineage_gts28ltexx_defconfig:3906-3911`),
whose code is written for v5.x (`kernel_universal5433/drivers/iommu/exynos7-iommu.c:104`).
The actual value is printed at boot with `EXYNOS_IOMMU_DEBUG` (`iommu.c:529-530`).

### 4.3 After probe: attach, runtime PM, TLB, IRQ

| path | lines | when it touches registers |
|---|---|---|
| identity attach | 983-1023 | `__sysmmu_disable()` only if `pm_runtime_active(sysmmu)` (1000-1005) |
| paging attach | 1034-1074 | `__sysmmu_enable()` only if `pm_runtime_active(sysmmu)` (1061-1066) |
| runtime suspend / resume | 826-860 | `__sysmmu_disable()` / `__sysmmu_enable()` when a master and a domain are set. genpd calls the resume callback only after powering the domain on (`genpd.c:1221` then `1236`) and powers it off only after the suspend callback (`genpd.c:1151`, `1180-1181`) |
| TLB invalidation | 671-722 | only while `data->active`, which is true between `__sysmmu_enable()` and `__sysmmu_disable()` (659, 613); clocks stay on in between (651, 616). `sysmmu_block()` polls at most 120 times (432-446) |
| fault IRQ | 566-602 | only raised by an enabled, therefore powered, System MMU |

`pm_runtime_active()` is also true while runtime PM is disabled
(`pm_runtime.h:168-172`). Outside the probe (before line 813, where no
attach can happen) that is only the case during system sleep
(`pm_runtime_force_suspend`, `iommu.c:864-865`). System suspend is out of
scope for this port.

**Conclusion:** on the boot path no System MMU register is accessed with its
domain off or its clocks gated. The paths that can go wrong end in an oops or
a panic: the `BUG_ON`s above, and an interrupt already pending when
`devm_request_irq()` runs (746): the handler would dereference
`data->variant`, still NULL until line 777, at line 578, before any MMIO.
That one needs a System MMU still asserting a fault left by the previous OS;
not observed and not expected after a reset, but not provable from sources.

## 5. Bootloader handoff (question 3)

sboot programs DECON to show the boot logo from 0x67000000 (`board:116-136`,
kept out of the allocator by `fb_reserved`, `board:156-159`; the
`simple-framebuffer` is disabled since exynos-drm drives the panel,
`board:799-801`). Translation through an empty page table while DECON still
fetches that address would fault, and `exynos_sysmmu_irq()` panics when no
fault handler takes it (`iommu.c:586-591`; exynos-drm installs none).

### 5.1 Order of events for DECON

1. `__driver_probe_device()` runtime-resumes every supplier linked with
   `DL_FLAG_PM_RUNTIME` (`dd.c:870`, `drivers/base/power/runtime.c:1894-1909`).
   fw_devlink links carry that flag by default (`drivers/base/core.c:1714-1721`),
   so **both DECON System MMUs are runtime-active from here until
   `pm_runtime_put_suppliers()` (`dd.c:884`)**, i.e. for DECON's whole probe.
   Their resume callback does nothing yet: no master is set (`iommu.c:849`).
2. `really_probe()` → `platform_dma_configure()` (`dd.c:698-699`,
   `platform.c:1413-1434`) → `of_iommu_configure()` (`of/device.c:156`):
   `exynos_iommu_of_xlate()` records DECON as master (`iommu.c:1435-1469`),
   `iommu_probe_device()` (`of_iommu.c:160-161`) adds the device link
   (`iommu.c:1412-1414`) and attaches the default domain, which on arm32 is
   the identity domain (`core.c:1736-1745`, `iommu.c:1472`): no register
   access (`iommu.c:992-993`).
3. Still in `of_dma_configure_id()`: `arch_setup_dma_ops()`
   (`of/device.c:168`, `dma-mapping.c:1761-1785`) sees an IOMMU group and calls
   `arm_setup_iommu_dma_ops()` (`dma-mapping.c:1714-1738`), which creates a
   private 4 GiB mapping and attaches DECON to it (`dma-mapping.c:1650`).
   `exynos_iommu_attach_device()` finds the System MMUs active (step 1) and
   calls `__sysmmu_enable()` (`iommu.c:1061-1066`): **translation is on, with
   an empty page table, before DECON's driver has run a single line.**
4. `platform_probe()` → `exynos5433_decon_probe()` (`decon.c:789-857`): no
   DECON register access; `pm_runtime_enable()` (851), `component_add()` (853).
5. When the last component of exynos-drm is added (DECON, MIC or DSI,
   whichever probes last), `decon_bind()` runs `decon_clear_channels()`
   (`decon.c:652`, `566-589`: DECON clocks on, all five windows disabled, a
   standalone update, 50 ms) **and only then** `exynos_drm_register_dma()`
   (`decon.c:654`). That detaches the private mapping and attaches DECON to the
   exynos-drm mapping (IOVA 0x20000000-0x5fffffff, `drm_dma.c:30-31`,
   `62-66`, `112-114`).
6. First modeset: `decon_atomic_enable()` resumes DECON (System MMUs first,
   as suppliers, `iommu.c:844-860`), soft-resets DECON (`decon.c:528`,
   `484-513`) and programs the new buffer.

So there is a window, from step 3 until `decon_clear_channels()` (step 5, or
until the end of the probe if the bind happens later), where DECON's System
MMUs translate with no mapping. `decon_clear_channels()` is the driver's own
handoff measure, and it is correctly placed before the exynos-drm attach,
but on this path it comes after the first attach.

### 5.2 Why DECON is not fetching in that window

`cmu_disp` is a supplier of everything else in the DISP domain (clocks of
DECON, DSIM, MIC and the System MMUs), so it probes first. Its probe ends
with `pm_runtime_put_sync()` (`clk-exynos-arm64.c:267-273`), whose genpd
callback tries to power the domain off (`genpd.c:1180-1181`). At that point
the only device attached to `pd_disp` is `cmu_disp` itself (devices join the
domain at their own probe, `platform.c:1371`), so `genpd_power_off()` finds
nothing awake (`genpd.c:856-925`) and switches DISP off: DECON loses its
bootloader programming before any DISP device other than `cmu_disp` has
probed. Nothing holds `cmu_disp` active after its probe: no CMU_DISP clock
is `CLK_IS_CRITICAL` (`clk-exynos5433.c:2494-2908`), and the other DISP
devices (`soc:968`, `1012`, `1038`, `1062`, `1294-1328`) all take
`cmu_disp` clocks, so fw_devlink keeps them from probing until it is bound. `pd_ignore_unused` (in `CONFIG_CMDLINE`) does not prevent this: it
only skips the late "power off unused domains" pass (`genpd.c:1267-1296`).
The 6.12 domain driver keeps the state it finds and has no boot-time reset
(`pd.c:131-133`).

On-device evidence consistent with this: with simpledrm on 0x67000000 (boot3
image) "le logo Samsung reste figé … simpledrm ne lui pousse pas les
nouvelles" (`docs/journal/PROGRESS.md:248`): writes to the splash buffer never reached
the panel, so DECON was not refreshing from it under Linux.

The case that would break this is a DISP power-off that fails: the domain
driver then prints `Power domain DISP disable failed` (`pd.c:52-57`), DECON
may keep running, and step 3 would fault. Section 10.1 checks for it on the
current kernel before the IOMMU kernel is flashed.

### 5.3 TM2 / TM2e

Nothing in the tree shows how the TM2 bootloader leaves DECON: the TM2 dtsi
has no framebuffer or reserved splash memory (`exynos5433-tm2-common.dtsi:47-53`)
and only enables `&decon` (`:326-328`). The driver-side handoff measure is
`decon_clear_channels()` in `decon_bind()` (`decon.c:652`), the same idea as
`fimd_clear_channels()` for Exynos 4. Also note that the arm64 defconfig does
not enable `EXYNOS_IOMMU` (`arch/arm64/configs/defconfig:1380-1385` list
other IOMMUs only), so a stock arm64 TM2 build does not use these System MMUs
at all. The step-3 window is not arm32-specific: on arm64 the default DMA
domain is attached in the same `of_dma_configure_id()` call, with the System
MMUs equally preactivated. Whether TM2 avoids it by its bootloader or by the
same DISP power-off as in 5.2 cannot be determined from the sources.

### 5.4 Is there a window during normal operation?

* DPMS off: `decon_atomic_disable()` disables every window and soft-resets
  DECON before `pm_runtime_put_sync()` (`decon.c:533-555`); DECON (consumer)
  suspends before its System MMUs (suppliers), so translation is switched off
  after DECON stopped. DPMS on: System MMUs resume first (with the page
  table), then DECON is reset and programmed (`decon.c:515-531`).
* Scanout of a buffer: `exynos_drm_fb` checks that the GEM object covers
  `height × pitch + offset` (`exynos_drm_fb.c:105-124`), which is what DECON
  is programmed to read (`decon.c:438-441`).

### 5.5 Mitigations considered, and why no driver patch

* **DT only.** No property can move the attach of step 3 or keep DECON
  quiet. `iommu-addresses`/direct mappings are not usable: exynos-iommu has
  no `get_resv_regions` (`iommu.c:1471-1486`), and arm32's private mapping is
  not the default domain. Disabling the unused System MMUs (done) removes the
  other probes but not this window.
* **Stop DECON in its driver before the attach:** impossible, the attach
  (step 3) happens in `really_probe()` before the driver's probe.
* **Skip `__sysmmu_enable()` in attach while the master is still probing:**
  rejected. If exynos-drm binds inside DECON's probe, the fbdev modeset
  resumes DECON while the System MMUs are still preactivated, their resume
  callback never runs, and DECON would scan out IOVAs as physical addresses.
* **Power DISP off at domain probe (old Exynos 4 "reset at boot"):**
  rejected: `cmu_disp` would then read reset values instead of sboot's clock
  setup, changing the clock state the display was validated with.
* **Turn the fault into a warning:** rejected: it changes a panic + reset
  into silent wrong DMA, and the unblock path re-enables translation
  (`iommu.c:427-430`, `594-597`).
* **`fw_devlink=on`** (no `DL_FLAG_PM_RUNTIME`, `drivers/base/core.c:1716-1734`) would
  remove the preactivation of step 1, but for every device of the board; not
  proposed.

What is left is a probability argument (5.2) plus an acceptable failure mode:
a fault in that window panics, `panic=5` reboots through SWRESET, and sboot
starts Android (`docs/journal/PROGRESS.md:373`: "oops → panique → reset logiciel, sans
boucle", the same chain).

## 6. arm32 DMA path and the import (question 4)

* `EXYNOS_IOMMU` selects `ARM_DMA_USE_IOMMU` (`drivers/iommu/Kconfig:256-262`,
  `arch/arm/Kconfig:177-186`). arm32 Exynos boards run this combination
  upstream (`arch/arm/configs/exynos_defconfig:308`,
  `multi_v7_defconfig:1094`).
* `exynos_drm_register_dma()` (`drm_dma.c:95-124`): first caller (DECON, the
  only exynos-drm subdriver with DMA in our build) becomes `priv->dma_dev`;
  `arm_iommu_create_mapping(dev, 0x20000000, 0x40000000)` (112-114,
  `dma-mapping.c:1546-1597`, paging domain from `exynos_iommu_domain_alloc_paging()`,
  `iommu.c:892-941`); `drm_iommu_attach_device()` checks DECON and
  `priv->dma_dev` share dma_ops (48-52), sets a 4 GiB maximum segment (54),
  replaces the private mapping (62-66). `arm_iommu_attach_device()` installs
  the arm32 `iommu_ops` (`dma-mapping.c:1674-1685`, ops at 1513-1530).
* `is_drm_iommu_supported()` is now true (`exynos_drm_drv.h:218-223`): dumb
  and GEM buffers become non-contiguous (`drm_gem.c:207-213`, `342-345`,
  `36-56`); CMA is only used for explicit `EXYNOS_BO_CONTIG` requests.
* **Import:** the exporter maps for DECON with `dma_map_sgtable(attach->dev)`
  (`drm_prime.c:668`), which is now `arm_iommu_map_sg()`
  (`dma-mapping.c:1240-1283`). It starts a new IOVA chunk only when an entry
  has an offset, the running size is not page-aligned, or the 4 GiB segment
  limit is reached (`dma-mapping.c:1249-1268`); panfrost's shmem pages are
  whole pages, so the whole buffer becomes **one** IOVA-contiguous chunk
  (`dma-mapping.c:1185-1225`). `drm_prime_get_contiguous_size()` then
  returns the full size, the check at `drm_gem.c:436-438` passes, and the
  buffer is flagged `EXYNOS_BO_NONCONTIG` with its IOVA as `dma_addr`
  (`drm_gem.c:450-456`).
* **Export to panfrost** (kmsro scanout buffers allocated on exynos):
  `dma_get_sgtable_attrs()` on DECON returns the page list
  (`drm_gem.c:405-426`); panfrost imports any sg table through the shmem
  helper and its own MMU (`panfrost_drv.c:605`, `panfrost_gem.c:289-296`).
* Page tables: v5 entries hold `phys >> 4` (36-bit, `iommu.c:56-66`,
  `786-796`); page tables come from lowmem and are flushed with
  `dma_sync_*` on the first System MMU (`iommu.c:883-890`, `917-920`). The
  `BUG_ON(handle != virt_to_phys())` at 920 holds: no `dma-ranges` offset, and
  the 36-bit mask set at 798-803 covers all RAM (below 4 GiB, `board:93-101`),
  so swiotlb never bounces.

## 7. panfrost (question 5)

Nothing to change. The `gpu` node has no `iommus` (`soc:1186-1235`); panfrost
translates through the Mali MMU it programs itself, with its own io-pgtable,
and keeps dma-direct for its pages. The GPU node, its supply and the
no-OPP policy (`docs/hardware/GPU.md`) are untouched.

## 8. Config fragment

| symbol | value | why |
|---|---|---|
| `IOMMU_SUPPORT` | y | menu containing `EXYNOS_IOMMU` (`drivers/iommu/Kconfig:14-24`); already y |
| `EXYNOS_IOMMU` | y | the driver; bool, selects `IOMMU_API`, `ARM_DMA_USE_IOMMU` |
| `EXYNOS_IOMMU_DEBUG` | y | first test only: defines `DEBUG` for the driver (`iommu.c:7-9`), so version, attach and save/restore lines are printed |

`ARM_DMA_IOMMU_ALIGNMENT` stays at its default (8, `arch/arm/Kconfig:183-186`).
The 256 MB CMA area of the defconfig is no longer needed for scanout; it is
left alone (the defconfig is not part of this work).

## 9. Risks that remain

1. **Step-3 window** (5.1): a fault only if DISP did not power off between
   sboot and DECON's probe. Outcome: panic, SWRESET, Android. Pre-checked in
   10.1.
2. **Any real IOMMU fault later** (driver bug, use after unmap) panics too,
   by design of `exynos_sysmmu_irq()`. Same outcome.
3. **Pending fault at `devm_request_irq()`** (4.3): NULL dereference in the
   handler, panic. Not expected after a reset.
4. **IOVA space**: one 1 GiB window shared by all exynos-drm buffers and every
   imported client buffer (`drm_dma.c:30-31`); a 1536×2048 XRGB buffer is
   12 MiB, so about 80 live full-screen buffers. When full, imports fail
   (`arm_iommu_map_sg()` returns an error): the same symptom as today, not a
   crash.
5. **Direct scanout needs linear buffers**: exynos-drm has no AFBC support;
   AFBC client buffers import fine but are composited.
6. **System suspend**: not analysed (4.3).

## 10. Test plan

Use the timed slot image (`t715.returnafter=…`) as for other first boots.

### 10.1 Before flashing, on the current kernel

```sh
dmesg | grep -i 'power domain'                 # must NOT show "DISP disable failed"
cat /sys/kernel/debug/pm_genpd/DISP/idle_states # "Usage" ≥ 1 even with no DPMS off since boot
cat /sys/kernel/debug/pm_genpd/pm_genpd_summary
```

A failed DISP power-off, or a usage count of 0 before any blanking, means
section 5.2 does not hold on this tablet: report before going further.

Optional baseline for 10.3: run the import test below now; it must fail
with `Invalid argument` and add one "buffer chunks must be mapped
contiguously" line to `dmesg`.

### 10.2 First boot

```sh
dmesg | grep -i -e sysmmu -e iommu -e 'exynos-drm' -e decon
ls /sys/class/iommu/                            # 13a00000.sysmmu 13a10000.sysmmu, nothing else
ls /sys/class/iommu/13a00000.sysmmu/devices/    # 13800000.decon
ls /sys/kernel/iommu_groups/*/devices/          # one group: 13800000.decon
cat /sys/kernel/iommu_groups/*/type             # "identity" is normal on arm32 (5.1 step 2)
grep -A12 DISP /sys/kernel/debug/pm_genpd/pm_genpd_summary
```

Expected lines (from `EXYNOS_IOMMU_DEBUG`):

* `exynos-sysmmu 13a00000.sysmmu: hardware version: 5.x`, same for 13a10000
  (`iommu.c:529-530`); no line for any other System MMU address;
* `exynos5433-decon 13800000.decon: exynos_iommu_attach_device: Attached
  IOMMU with pgtable …` twice, with a `Restored IOMMU to IDENTITY` in between
  (`iommu.c:1070-1071`, `1020-1021`: private mapping, then exynos-drm's);
* `[drm] Exynos DRM: using 13800000.decon device for DMA mapping operations`
  (`drm_dma.c:102-103`);
* `restoring state` / `saving state` at each DECON resume/suspend
  (`iommu.c:854`, `836`);
* the kernel console on the panel, as before.

Must not appear: `Unrecoverable System MMU Fault`, `… FAULT occurred at`,
`Unable to set DMA mask`, `Failed to get device clock(s)!`,
`lacks support for IOMMU`, `Failed to create … IOMMU mapping`,
`buffer chunks must be mapped contiguously`.

### 10.3 Non-contiguous import

Exact check, equivalent to Hyprland's `commence()`: a panfrost buffer
imported into the exynos-drm render node.

```c
/* dmabuf-import-test.c — gcc -O2 dmabuf-import-test.c -o dmabuf-import-test \
 *     $(pkg-config --cflags --libs gbm libdrm)          (on the tablet) */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <gbm.h>
#include <xf86drm.h>

int main(void)
{
	int gpu = open("/dev/dri/by-path/platform-14ac0000.gpu-render", O_RDWR | O_CLOEXEC);
	int kms = open("/dev/dri/by-path/platform-exynos-drm-render", O_RDWR | O_CLOEXEC);
	struct gbm_device *gbm;
	struct gbm_bo *bo;
	uint32_t handle;
	int ret;

	if (gpu < 0 || kms < 0) {
		perror("open");
		return 2;
	}
	gbm = gbm_create_device(gpu);
	bo = gbm ? gbm_bo_create(gbm, 1536, 2048, GBM_FORMAT_XRGB8888,
				 GBM_BO_USE_RENDERING | GBM_BO_USE_LINEAR) : NULL;
	if (!bo) {
		fprintf(stderr, "gbm_bo_create on panfrost failed\n");
		return 2;
	}
	ret = drmPrimeFDToHandle(kms, gbm_bo_get_fd(bo), &handle);
	printf("panfrost 12 MiB buffer -> exynos-drm: %s\n",
	       ret ? strerror(errno) : "imported");
	return ret ? 1 : 0;
}
```

Current kernel: `Invalid argument`. IOMMU kernel: `imported`, no new
`dmesg` line. (Check the two by-path names with `ls -l /dev/dri/by-path/`.)

Then the real case: start Hyprland **without** the shim (bypass the
`/usr/local/bin/Hyprland` wrapper of the Omarchy image) and open GL clients
(quickshell, Firefox, `eglgears_wayland` or `glmark2-es2-wayland` if
installed). Expected: no client killed, `dmesg | grep -c contiguously` = 0.
Also run `kmscube -D /dev/dri/card<N>` with the session stopped (scanout
buffers now non-contiguous, rendered by panfrost), and a few DPMS off/on
cycles (`saving state` / `restoring state` pairs, no fault).

### 10.4 Failure signatures

| what you see | meaning | what happens |
|---|---|---|
| `… sysmmu …: 13800000.decon: [READ] PAGE FAULT occurred at 0x…` then `Unrecoverable System MMU Fault!` | translation fault (5.1 window if at boot, 9.2 otherwise) | panic → 5 s → SWRESET → Android. Keep `/proc/last_kmsg` and the pstore console under Android; the address tells which buffer (0x67000000 = splash) |
| `Unable to handle kernel NULL pointer dereference` in `exynos_sysmmu_irq` right at System MMU probe | 9.3 | panic → SWRESET |
| display only after ~10 s, or never, with deferred-probe messages | a DECON System MMU did not probe; DECON waits for it, then runs without IOMMU after the deferred-probe timeout (`dd.c:260`, `308`) | no hang; report the log |
| boot log stops right after an `exynos-sysmmu` line, then a reset ~30 s later | bus hang during the version read (not expected, section 4.2) | **watchdog reset → sboot starts RECOVERY again (boot loop)**: Download mode, reflash the previous RECOVERY image (`docs/hardware/GPU.md` section 5 procedure); ramoops holds the console |

The last row is the one that must never happen; nothing in section 4 leads
to it, but it is the one to watch for on the first boot.

## 11. Build verification (2026-10-29)

On the kernel tree as it stood (board file and several fragments carry other
people's uncommitted changes; they were built as found):

* **DT:** wrapper `.dts` outside the repo (`#include` of the board file + the
  new dtsi), compiled with the kernel's pipeline (`gcc -E -nostdinc -I
  scripts/dtc/include-prefixes -undef -D__DTS__ -x assembler-with-cpp`, then
  the kernel's own `scripts/dtc/dtc` 1.7.0-gbcd02b52 with the kbuild
  `DTC_FLAGS`) in the `t715-kbuild` container, source mounted read-only.
  Board alone 62 875 bytes, board + dtsi 63 323 bytes; default flags: no
  warning for either; `W=1` flags: the same three pre-existing warnings for
  both (`/memory` unit name, DECON and DSI single-port graphs). Decompiled
  diff (`dtc -I dtb -O dts -s`): exactly 19 added `status` properties, `okay`
  on 13a00000/13a10000, `disabled` on the ten other System MMUs and on
  13c00000/13c10000/13c20000 (GSC), 15000000/15010000 (scalers), 15020000
  (JPEG) and 152e0000 (MFC); DECON keeps `iommus = <&13a00000 &13a10000>`
  and `power-domains` = DISP.
* **Kernel:** separate volume `t715-kbuild-out-iommu`, source read-only:
  `gts28ltexx_defconfig`, then `make gts28ltexx_iommu.config` (kbuild's
  `merge_config.sh` + `olddefconfig`), then `zImage`: exit 0, zImage
  4 068 720 bytes (9 MiB budget). `EXYNOS_IOMMU=y` and
  `EXYNOS_IOMMU_DEBUG=y` survive `olddefconfig`. Against a plain defconfig
  `.config`, the only additions are `EXYNOS_IOMMU`, `EXYNOS_IOMMU_DEBUG`,
  `IOMMU_API`, `ARM_DMA_USE_IOMMU`, `ARM_DMA_IOMMU_ALIGNMENT=8`,
  `NEED_SG_DMA_LENGTH`, `OF_IOMMU`, `IOMMU_DEFAULT_DMA_STRICT` (no effect on
  arm32, which has no `IOMMU_DMA`). `System.map` has
  `exynos_iommu_init` (core initcall), `exynos_sysmmu_probe`,
  `arm_iommu_create_mapping`. `make W=1` of `drivers/iommu/exynos-iommu.o`
  and `drivers/gpu/drm/exynos/exynos_drm_dma.o`: no warning.
* Not run: `make CHECK_DTBS=y` (dtschema is not in the image), the arm64
  non-regression phase of `kbuild-mainline.sh`, modules and DTBs through
  kbuild (the board Makefile has no entry for the new dtsi, by design).

## 12. On the tablet, then reverted (2026-10-29)

Enabled in the board on the morning of 2026-10-29 (`c7dbdcf2f`), reverted
the same day (`9f6393b0e`).

What worked: System MMU v5.1 on both DECON ports, iommu group 0, a
12 MiB non-contiguous panfrost dma-buf imported into exynos-drm with no
page fault, display and runtime PM unchanged. Hyprland 0.57 ran without
the dmabuf-check shim.

Why it was reverted: every import now succeeds, and the imports of
client buffers stayed held after their surfaces were gone. Measured from
`/sys/kernel/debug/dma_buf/bufinfo`, counting the buffers attached to
`13800000.decon`:

| Step | Attached to DECON | dma-buf total |
|---|---|---|
| Session up about 20 min | 197 | 1.04 GB |
| Firefox closed | 197 | 1.04 GB |
| sddm restarted | 29 | 182 MB |
| + 5 quick-settings openings | 63 | 518 MB |
| + 5 recent-apps openings | 83 | 725 MB |
| + 5 drawer openings | 161 | 1.07 GB |

The holder outlives the shell process and goes away with the session: it
is the Hyprland process. On arm32 exynos-drm maps all imports into one IOVA window
of exactly 1 GiB (`drivers/gpu/drm/exynos/exynos_drm_dma.c:30-31`,
`EXYNOS_DEV_ADDR_START` 0x20000000, `EXYNOS_DEV_ADDR_SIZE` 0x40000000).
Both black screens came at 1.04-1.07 GB attached. Once the window is
full, new imports fail, Hyprland rejects the shell's buffer ("unknown
object ... message attach"), and the shell crash-loops.

Without the System MMU only physically contiguous buffers import. The
same cycles then add +32, -4 and +67 MB of Shmem, and the shell keeps
running. The drawer still leaks about 13-15 MB per opening, with
animations on or off. The held buffer is 1536 x 1976 x 4, the drawer's
layer surface under the 36 px bar.

Root cause, found by the Omarchy session the same day: Mesa's renderonly.
Hyprland's kmsro instance runs on the exynos render node (renderD128).
For every imported dma-buf, `panfrost_resource_from_handle()` calls
`renderonly_create_gpu_import_for_resource()`, which imports it into that
fd with `drmPrimeFDToHandle()`. That is allowed on a render node:
`DRM_IOCTL_PRIME_FD_TO_HANDLE` has `DRM_RENDER_ALLOW`
(`drivers/gpu/drm/drm_ioctl.c:611`). On destroy,
`renderonly_scanout_destroy()` releases the handle with
`DRM_IOCTL_MODE_DESTROY_DUMB`, which has no `DRM_RENDER_ALLOW` (`:638`),
so the kernel refuses it on a render node and every import stays held.
`DRM_IOCTL_GEM_CLOSE` is allowed there (`:604`). A `drmIoctl()` fallback
in the Omarchy shim (refused `DESTROY_DUMB` on a render node retried as
`GEM_CLOSE`) brought the DECON attachments from 11-16 down to 0 over
10 drawer cycles, on the kernel without the System MMU.

To enable the System MMU again: ship that fallback, or a Mesa fix (release
imported handles with `GEM_CLOSE`). Check that the decon-attached count
returns to its baseline after 20 panel cycles, then re-apply `c7dbdcf2f`.
A larger IOVA window would only delay the failure.
