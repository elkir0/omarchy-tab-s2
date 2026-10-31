# Hardware watchdog — SM-T715 (Exynos 5433), mainline 6.12 arm32

Build-tested only. The mainline `exynos5433.dtsi` has no watchdog node,
so a hung kernel never reset the board. This milestone describes the SoC
watchdog (`0x10020000`) so the mainline `s3c2410_wdt` driver probes it,
starts it at boot and keeps it pinged from the kernel; if the kernel
hangs, the watchdog resets the SoC via the PMU.

Artifacts: `out/mainline-wdt/` (fragment
`gts28ltexx_wdt.config`, board `exynos5433-gts28ltexx-wdt.dts`).

---

## 1. Why a new driver variant was needed

The stock kernel lets the watchdog reset the SoC by programming two PMU
registers, chosen by the DT property `pmu_wdt_reset_type` (stock value
`3`). On `pmu_wdt_reset_type = 3` (PMU_WDT_RESET_TYPE3) the stock kernel
clears the **KFC** (little cluster, where an arm32 kernel runs) bits:

| stock register (offset in PMU) | stock bit(s) | stock source (file:line) |
|---|---|---|
| `AUTOMATIC_WDT_RESET_DISABLE` (0x0408) | bit 24 **and** bit 23 cleared (KFC + EGL) | `kernel_universal5433/arch/arm/mach-exynos/pmu-exynos5433.c:359-399` (`exynos_pmu_wdt_control`, TYPE3 branch at 380-382), offset `mach/regs-pmu.h:50`, bits `mach/regs-pmu-exynos5433.h:266-267` |
| `MASK_WDT_RESET_REQUEST` (0x040c) | bit 24 cleared (KFC only) | same function (`pmu-exynos5433.c:382,390-399`), offset `mach/regs-pmu.h:51` |
| `RST_STAT` (0x0404) | read to detect a WDT reset | `mach/regs-pmu.h:49`; stock never reads it for 5433 (no consumer found) |

Mainline models exactly this pair of registers, but keyed on a single
`mask_bit` per variant (`disable_reg`/`mask_reset_reg` + `mask_bit`):

* `samsung,exynos5250-wdt`: `mask_bit = 20`
* `samsung,exynos5420-wdt`: `mask_bit = 0`
* `samsung,exynos7-wdt`: `mask_bit = 23` ("A57 WDTRESET")
* `samsung,exynos850-wdt` / `exynosautov9-wdt` / `gs101-wdt`: different
  register layout (`CLUSTERx_NONCPU_INT_EN`, inverted meaning,
  `mask_reset_inv = true`) — not this SoC's.

The stock kernel's TYPE3 writes bit **24** in `MASK_WDT_RESET_REQUEST`
(and clears both 23+24 in `AUTOMATIC_WDT_RESET_DISABLE`, but that
register is a "disable" mask: clearing both bits is simply permissive,
the decisive mask bit is the KFC one, 24). `exynos7-wdt` uses bit 23 in
both registers — for the big (A57/EGL) cluster. Since the SM-T715 boots
an **arm32** kernel, which Samsung runs on the little (KFC/A53) cluster,
bit 23 alone would not unmask the reset request for the running cluster.

Hence a new variant, `samsung,exynos5433-wdt`, bit 24 (KFC) everywhere —
the mainline driver writes the same `mask_bit` in both `disable_reg` and
`mask_reset_reg`, which matches the stock TYPE3 behaviour (bit 24
cleared in both) and additionally clears bit 23 in the disable register
only... which the mainline driver does not do. That difference is
harmless: bit 23 in `AUTOMATIC_WDT_RESET_DISABLE` only matters if the
EGL cluster is the one being reset, and on this device the arm32 kernel
never runs there. (Both bits are handled by the two-register write in
stock; mainline's single-bit model cannot express "bit 24 in mask, bits
23+24 in disable", and bit 24 in both is the subset that gates a KFC
watchdog reset.)

### Evidence table (stock → mainline variant field)

| stock (file:line) | value | mainline variant field (`drivers/watchdog/s3c2410_wdt.c`) |
|---|---|---|
| `pmu-exynos5433.c:359` `exynos_pmu_wdt_control(1, 3)` | enable WDT reset | `quirks = QUIRK_HAS_PMU_MASK_RESET \| QUIRK_HAS_PMU_AUTO_DISABLE \| QUIRK_HAS_PMU_RST_STAT \| QUIRK_HAS_WTCLRINT_REG` (`drv_data_exynos5433`) |
| `mach/regs-pmu.h:50` `EXYNOS_AUTOMATIC_WDT_RESET_DISABLE = 0x0408` | PMU 0x0408 | `disable_reg = EXYNOS5_WDT_DISABLE_REG_OFFSET` (0x0408, `s3c2410_wdt.c:55`) |
| `mach/regs-pmu-exynos5433.h:267` `EXYNOS5433_SYS_WDTRESET_KFC = 1 << 24` | bit 24 | `mask_bit = 24` |
| `mach/regs-pmu.h:51` `EXYNOS_MASK_WDT_RESET_REQUEST = 0x040c` | PMU 0x040c | `mask_reset_reg = EXYNOS5_WDT_MASK_RESET_REG_OFFSET` (0x040c, `s3c2410_wdt.c:56`) |
| `mach/regs-pmu-exynos5433.h:267` (KFC bit, same bit number) | bit 24 | `mask_bit = 24` (same field drives both registers) |
| `mach/regs-pmu.h:49` `EXYNOS_RST_STAT = 0x0404` | reset status | `rst_stat_reg = EXYNOS5_RST_STAT_REG_OFFSET` (0x0404), `rst_stat_bit = 24` |
| `plat/regs-watchdog.h:19-22` WTCON/WTDAT/WTCNT/WTCLRINT 0x00/0x04/0x08/0x0c | register map | identical mainline `S3C2410_WTCON/WTDAT/WTCNT/WTCLRINT` (`s3c2410_wdt.c:23-26`) → `QUIRK_HAS_WTCLRINT_REG` |

### Clock mapping

| stock (live_fdt.dts ~L1678) | downstream clock driver | mainline equivalent |
|---|---|---|
| `<0x10 0x366>` (870) `rate_watchdog` | `pclk_wdt_kfc`, GATE on `ENABLE_PCLK_PERIS` bit 17 (`clk-exynos5433.c:184, 2248`) | `&cmu_peris CLK_PCLK_WDT_APOLLO` (7) — same `ENABLE_PCLK_PERIS` bit 17 (`include/dt-bindings/clock/exynos5433.h:472`, `drivers/clk/samsung/clk-exynos5433.c:1850-1851`) |
| `<0x10 0x9b0>` (2480) `gate_watchdog` | `gate_wdt_kfc`, CGTE on `ENABLE_IP_PERIS0` bit 5 (`clk-exynos5433.c:439, 2883`) | **no mainline equivalent**: mainline does not model the `ENABLE_IP_PERIS0` IP gates; the binding's `else` clause allows a single `watchdog` clock, so one clock is listed |

The watchdog counter runs from the PCLK (mainline `s3c2410wdt_get_freq`
uses `src_clk` if present, else `bus_clk`, `s3c2410_wdt.c:336-338`), so
the single `pclk_wdt_apollo` clock is both bus and source clock — same
layout as `exynos5250.dtsi:309-316`.

### Interrupt

Stock `interrupts = <0x00 0x65 0x00>` (GIC SPI, number 0x65 = 101,
level). Mainline format with the shared macros:
`interrupts = <GIC_SPI 101 IRQ_TYPE_LEVEL_HIGH>`. Numbering is
identical in both trees (cross-checked on the MCT node: stock
`mct_map` maps local 0 → `&gic 0 102 0`, mainline `timer@101c0000`
uses `GIC_SPI 102`; the watchdog at 101 sits directly below MCT).

---

## 2. Files

| file | role |
|---|---|
| `drivers/watchdog/s3c2410_wdt.c` | new `drv_data_exynos5433` + `samsung,exynos5433-wdt` of_match entry |
| `Documentation/devicetree/bindings/watchdog/samsung-wdt.yaml` | `samsung,exynos5433-wdt` enum + syscon-required list |
| `arch/arm/boot/dts/samsung/exynos5433-gts28ltexx-wdt.dtsi` | the `watchdog@10020000` node under `&soc` |
| `arch/arm/boot/dts/samsung/exynos5433-gts28ltexx-wdt.dts` | board file: m1 board + wdt dtsi |
| `arch/arm/boot/dts/samsung/Makefile` | one `dtb-` line |
| `arch/arm/configs/gts28ltexx_wdt.config` | Kconfig fragment |

---

## 3. Kernel command-line parameter (required)

```
s3c2410_wdt.tmr_atboot=1
```

`gts28ltexx_defconfig` cannot carry it (no Kconfig symbol exists for
`tmr_atboot`), and without it the driver **stops** a running watchdog at
probe instead of starting one (`s3c2410_wdt.c:782-794`: `tmr_atboot` is
0 by default → `s3c2410wdt_stop()`). With the parameter the probe path
starts the timer and sets `WDOG_HW_RUNNING`, which is what makes the
watchdog core ping it (below). Add it to `bootargs` next to the existing
`panic=5 oops=panic` (the m1 board file's `chosen` node).

---

## 4. Config fragment

```
CONFIG_WATCHDOG=y
CONFIG_WATCHDOG_CORE=y
CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=y   # default y, explicit
CONFIG_WATCHDOG_OPEN_TIMEOUT=0           # default 0 (infinite), explicit
CONFIG_S3C2410_WATCHDOG=y
```

* `WATCHDOG_HANDLE_BOOT_ENABLED` (default y): a `WDOG_HW_RUNNING`
  watchdog is pinged by a kernel kthread worker until userspace opens
  `/dev/watchdog` (`watchdog_dev.c:1099-1108`, ping decision at
  `watchdog_worker_should_ping`, `watchdog_dev.c:204-215`).
* `WATCHDOG_OPEN_TIMEOUT=0` means the deadline is `KTIME_MAX`
  (`watchdog_set_open_deadline`, `watchdog_dev.c:70-74`): the kernel
  keeps pinging forever if userspace never takes over — right for a
  device whose userspace may not run a watchdog daemon.
* `CONFIG_PANIC_TIMEOUT=5` is already in `gts28ltexx_defconfig`: a panic
  reboots the board within 5 s (orderly reboot, via the watchdog
  `restart` handler or PMU), and `oops=panic` in `bootargs` escalates
  oopses to panics. Nothing pings the watchdog on purpose during a
  panic, so if the orderly reboot hangs, the 30 s timeout still fires.

## 5. Expected behaviour

* **Boot:** driver probes `watchdog@10020000`, unmaps the PMU reset
  (clears bit 24 in 0x0408 and 0x040c), sets the 30 s heartbeat
  (`timeout-sec` → `watchdog_init_timeout`), starts the timer
  (`tmr_atboot=1`) and registers `/dev/watchdog0`. From then on a kernel
  kthread re-writes `WTCNT` every ~15 s (`keepalive_interval =
  hw_heartbeat_ms / 2`, `watchdog_dev.c:116`, worker armed at
  `watchdog_dev.c:1099-1108`).
* **Userspace takeover:** opening `/dev/watchdog0` stops the kernel
  ping (`watchdog_active()` becomes true); closing it restarts the
  kernel ping (`open_deadline = KTIME_MAX` after first open,
  `watchdog_dev.c:903-910`), so the board is never unwatched.
* **Hang:** the kthread cannot run → `WTCNT` reaches 0 → PMU issues the
  reset (bits unmasked above) → board reboots after ~30 s.
* **Panic:** `panic=5` → orderly reboot after 5 s; if that path hangs,
  the unpinged watchdog resets the board at 30 s.
* **Suspend/resume:** the driver masks the reset and stops the timer on
  suspend, restores on resume (`s3c2410wdt_suspend/resume`), matching
  the stock suspend path (`pmu_wdt_control(0/1, ...)`).
* **`/dev/watchdog` flags:** `WDIOF_CARDRESET` is reported in
  `bootstatus` when `RST_STAT` bit 24 is set at probe (i.e. the previous
  reset was a watchdog reset).

## 6. Verification performed

* Build: `bash kernel/kbuild-mainline.sh --fragment gts28ltexx_wdt.config`
  → `out/mainline-wdt/{zImage, exynos5433-gts28ltexx-wdt.dtb,
  .config}` (+ ARM64 non-regression phase). Result: see final report.
* `dtc -I dtb -O dts` shows the `watchdog@10020000` node.
* `make CHECK_DTBS=y samsung/exynos5433-gts28ltexx-wdt.dtb` (dtschema in
  the build container). Result: see final report.

## 7. Not established / assumptions

* `RST_STAT` bit 24 as "KFC watchdog reset" for 5433 is **inferred**:
  the downstream header defines `EXYNOS_KFC_WDTRESET (1 << 24)` next to
  the RST_STAT register (`mach/regs-pmu.h:49-54`) but no downstream code
  on this SoC reads it; no downstream/stock document states the 5433
  RST_STAT bit layout. The driver only uses it for `WDIOF_CARDRESET`
  reporting, never for the reset path, so a wrong bit would not stop a
  hang from resetting the board.
* The stock kernel clears bits 23+24 in `AUTOMATIC_WDT_RESET_DISABLE`
  but mainline's single `mask_bit` model writes bit 24 in both
  registers. Argued harmless above (bit 23 only gates the EGL cluster,
  unused by the arm32 kernel); if a future arm64 milestone runs on the
  big cluster, an `exynos5433` cluster-aware variant (like exynos850's
  `samsung,cluster-index`) would be needed.
* `EXYNOS5433_CPU_RESET_DISABLE_FROM_WDTRESET` (PMU 0x0414,
  `mach/regs-pmu-exynos5433.h:21`) has **no downstream consumer** (grep
  found none), so it is left unprogrammed; presumably a bootloader/EL3
  concern.
* Mainline has no clock for the stock `gate_watchdog` (ENABLE_IP_PERIS0
  bit 5) IP gate; only the PCLK gate is described. The IP gate is left
  as the bootloader set it (stock DT marks it `CLK_IGNORE_UNUSED`, so
  the stock kernel left it enabled too).
