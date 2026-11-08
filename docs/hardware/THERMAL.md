# Thermal protection — SM-T715 (Exynos 5433), mainline 6.12 arm32

Build-tested only (no device interaction). Until now the mainline kernel
ran with no thermal management at all: no TMU driver bound, no thermal
zone, no cooling. This adds the minimum safety net before the 8 cores
are loaded:

* the five TMU instances the stock kernel uses are enabled;
* each of the five SoC thermal zones gets a **critical** trip at the stock
  hardware-trip temperature (115 °C) and a **hot** trip at the stock
  software-trip temperature (110 °C; 86 °C on the A53 sensor, as stock);
* zones are polled at the stock interval in addition to the TMU
  interrupts.

**No throttling.** CPU frequency scaling (cpufreq-dt cooling) is left out:
the mainline OPP voltages are below the stock voltages of the slowest ASV
groups and the chip's ASV group is unknown (section 8.1). The CPUs keep
running at whatever frequency sboot left them.

Artifacts: `out/mainline-thermaltest/` (fragment
`gts28ltexx_thermaltest.config`, board `exynos5433-gts28ltexx-thermaltest.dts`).

Path abbreviations used below:

* `stock-dts` = `src/kernel_universal5433/arch/arm/boot/dts/exynos5433.dtsi`
* `stock-thermal` = `src/kernel_universal5433/drivers/thermal/exynos_thermal.c`
* `cal_tmu.c`, `cal_tmu.h` = `src/kernel_universal5433/drivers/thermal/`
* `mach/tmu.h`, `mach/asv-exynos5433.h` = `src/kernel_universal5433/arch/arm/mach-exynos/include/mach/`
* `live_fdt` = `dumps/live_fdt.dts` (the running stock tree; its TMU
  node is identical to `stock-dts:1985-2086`, and the gts28 board files
  do not override it)
* `soc-dtsi` = `src/linux-6.12/arch/arm64/boot/dts/exynos/exynos5433.dtsi`
* `tmu-dtsi` = `src/linux-6.12/arch/arm64/boot/dts/exynos/exynos5433-tmu.dtsi`
* `exynos_tmu.c` = `src/linux-6.12/drivers/thermal/samsung/exynos_tmu.c`
* `thermal_core.c` = `src/linux-6.12/drivers/thermal/thermal_core.c`

---

## 1. Files

| file | what |
|---|---|
| `arch/arm/boot/dts/samsung/exynos5433-gts28ltexx-thermal.dtsi` | enables `tmu_atlas0/atlas1/g3d/apollo/isp`; adds hot + critical trips and stock polling to the five SoC zones |
| `arch/arm/configs/gts28ltexx_thermal.config` | `CONFIG_THERMAL_EMULATION=y` (test only); everything else is already on |
| `arch/arm/boot/dts/samsung/exynos5433-gts28ltexx-thermaltest.dts` | build test: `-boot3.dts` + the thermal dtsi |
| `arch/arm/configs/gts28ltexx_thermaltest.config` | build test: verbatim copy of `gts28ltexx_boot3.config` + the thermal symbol |

All under `src/linux-6.12/`. No existing file was modified. The
thermal dtsi only touches labels from the SoC dtsi, so it can be included
from the consolidated `exynos5433-gts28ltexx.dts` as is.

## 2. Values and their sources

### 2.1 TMU instances (mapped by register address)

Stock: a single node `tmu@10060000` with five register windows
(`live_fdt:4235-4335`). Mainline: five nodes, all `status = "disabled"`
in `soc-dtsi`. The stock driver names the sensors
"0: EAGLE0, 1: EAGLE1, 2: G3D, 3: KFC, 4: ISP" (`stock-thermal:1750-1751`;
EAGLE = A57 = mainline "atlas", KFC = A53 = mainline "apollo").

| # | address | stock IRQ (`live_fdt:4248`) | stock clock (`live_fdt:4243,4245`) | mainline node (`soc-dtsi`) | mainline IRQ / clocks | enabled |
|---|---|---|---|---|---|---|
| 0 | 0x10060000 | SPI 95 | `pclk_tmu0_apbif` | `tmu_atlas0` (750-759) | SPI 95, `CLK_PCLK_TMU0_APBIF` + `CLK_SCLK_TMU0` | yes |
| 1 | 0x10068000 | SPI 96 | `pclk_tmu0_apbif` | `tmu_atlas1` (761-770) | SPI 96, TMU0 clocks | yes |
| 2 | 0x10070000 | SPI 99 | `pclk_tmu1_apbif` | `tmu_g3d` (772-781) | SPI 99, TMU1 clocks | yes |
| 3 | 0x10078000 | SPI 115 | `pclk_tmu1_apbif` | `tmu_apollo` (783-792) | SPI 115, TMU1 clocks | yes |
| 4 | 0x1007c000 | SPI 94 | `pclk_tmu1_apbif` | `tmu_isp` (794-803) | SPI 94, TMU1 clocks | yes |

Stock register windows are 0x100 long (`live_fdt:4237`), mainline 0x200;
the highest register mainline touches is `PD_DET_EN` at 0x130
(`exynos_tmu.c:91`), above 0x100 but inside the instance spacing (0x4000
or more). TM2 (mainline's reference board) enables only atlas0, apollo
and g3d (`exynos5433-tm2-common.dtsi:1340-1353`); the stock kernel uses all
five, so all five are enabled here.

### 2.2 Calibration (driver-internal in mainline, not DT)

| parameter | stock (`live_fdt` / `stock-dts`) | mainline driver (`exynos_tmu.c:911-930`) |
|---|---|---|
| gain | 8 (4247 / 2007) | 8 |
| reference voltage | 16 (4240 / 2008); 23 for G3D only with two-point trim (`cal_tmu.c:46-54`, `cal_tmu.h:193`) | 16; **23 for 0x10070000 (G3D) always** |
| noise-cancel (trip) mode | 4 (4251 / 2009) | `EXYNOS_NOISE_CANCEL_MODE` 4 |
| default efuse (trim fallback) | 75 (4244 / 2011) | 75 (min 40, max 150) |
| `cal_type` | 1 = one-point (4239 / 2010), overridden at run time by the trim data (`stock-thermal:928-931`) | read from TRIMINFO bit 23 (`exynos_tmu.c:520-536`) |
| trim source | OTP bank first (`otp_tmu_read()`, `asv-exynos5433_cal.c:146`; `cal_tmu.c:237-266`; used at `stock-thermal:2113-2120`), TRIMINFO register only if the OTP is blank | TRIMINFO register of each instance (`exynos_tmu.c:506-537`) |

The G3D reference voltage and the trim source differ from stock: see
section 9 (risks 1-3).

### 2.3 Trips, hysteresis, polling

| value | used for | source |
|---|---|---|
| **115 °C** | `critical`, all zones | stock `trigger_level_7` "H/W Tripping temp" = 115, enabled (`stock-dts:2048-2051`, `live_fdt:4266-4269`), written as level 7 of `THD_TEMP_RISE7_4` in each instance (`stock-thermal:855-885`) with `THERM_TRIP_EN` (`cal_tmu.c:116`). Mainline writes its critical trip to that same field and bit (`exynos_tmu.c:286-300`, `497-504`). Also the stock GPU "tripping" level `GPU_TH_TEMP5` = 115 (`mach/tmu.h:45`). |
| **110 °C** | `hot`: atlas0, atlas1, g3d, isp | stock `SWTRIP_TEMP` 110 (`stock-thermal:74-76`; `CONFIG_EXYNOS_SWTRIP=y`, `kernel_universal5433/arch/arm/configs/lineage_gts28ltexx_defconfig:2425`; trip handled at `stock-thermal:1003-1025`), = `HOT_CRITICAL_TEMP` (`mach/tmu.h:24`), = `trigger_level_5` (`stock-dts:2040-2043`, `live_fdt:4276-4279`), = last GPU throttle step `GPU_TH_TEMP4` (`mach/tmu.h:44`) |
| **86 °C** | `hot`: apollo (A53, stock sensor 3 "KFC") | the stock driver substitutes 112 °C for the maximum as soon as `alltemp[3]` (KFC) > 85 (`stock-thermal:991-1000`), which raises its software trip (≥ 110) and its last throttle step: the stock emergency level for this sensor is KFC > 85 °C. Readings are whole degrees, so "> 85" = "≥ 86". |
| 2 °C | hysteresis of every added trip | stock `threshold_falling = 2` (`live_fdt:4246`, `stock-dts:2006`), applied to every level (`stock-thermal:866-876`) |
| 500 ms | `polling-delay`, all zones | stock `IDLE_INTERVAL` 500 (`cal_tmu.h:133`), the stock zone's polling delay (`stock-thermal:740-742`) |
| 100 ms | `polling-delay-passive`, all zones | stock `PASSIVE_INTERVAL` 100 (`cal_tmu.h:131`, same call). No passive trip exists, so it is never used. |

The SoC zones in `tmu-dtsi` are interrupt-only (`polling-delay = 0`).
Polling at the stock interval is added so that a lost TMU interrupt (new
code path on arm32) cannot hide a critical temperature; the interrupts
still work as before (`set_trips`, `exynos_tmu.c:977-997`).

### 2.4 `vtmu-supply`: left out

Neither the stock tree (no supply property in the TMU node,
`live_fdt:4235-4335`) nor the stock driver/board code (no regulator call in
`stock-thermal` or `cal_tmu.c`, no TMU reference in
`arch/arm/mach-exynos/*.c` other than OTP/ASV and power-domain code) names
a TMU rail. TM2 feeds its TMUs from its LDO3 (`exynos5433-tm2-common.dtsi:1340-1353`),
but that is another board's wiring. The mainline driver treats the supply
as optional (`exynos_tmu.c:1023-1033`). For the record, this board's LDO3
(`VDD1_E_1.8V_AP`) is `regulator-always-on` (`exynos5433-gts28ltexx-m2.dtsi:188-193`),
so if it is the TMU rail it is on.

### 2.5 Kernel configuration

| symbol | state in `gts28ltexx_defconfig` + `gts28ltexx_boot3.config` | why |
|---|---|---|
| `THERMAL`, `THERMAL_OF`, `EXYNOS_THERMAL` | already `=y` | selected by `ARCH_EXYNOS` (`arch/arm/mach-exynos/Kconfig:15,28,29`) |
| `THERMAL_GOV_STEP_WISE`, `THERMAL_DEFAULT_GOV_STEP_WISE`, `THERMAL_HWMON` | already `=y` | Kconfig defaults |
| `THERMAL_EMERGENCY_POWEROFF_DELAY_MS` | 0 (default), kept | section 8.3 |
| **`THERMAL_EMULATION`** | **added** (`gts28ltexx_thermal.config`) | `emul_temp` node for section 7; drop it after validation (Kconfig help: root can mask real temperatures with it) |
| `CPU_THERMAL`, `CPU_FREQ`, `CPUFREQ_DT` | not set, not added | no cooling device (section 8.1) |

## 3. Resulting zones and trips

The zones come from `tmu-dtsi` (sensor binding, the seven `active` trips
and the cooling maps are mainline/TM2 values, untouched); this board adds
the last two trips of each zone and the polling.

| zone (`type` in sysfs) | sensor | inherited `active` trips (`tmu-dtsi`) | **hot** | **critical** | polling |
|---|---|---|---|---|---|
| `atlas0-thermal` | 0x10060000, A57 | 65 … 95 °C (17-51) | 110 °C | 115 °C | 500 ms |
| `atlas1-thermal` | 0x10068000, A57 | 65 … 95 °C (105-139) | 110 °C | 115 °C | 500 ms |
| `g3d-thermal` | 0x10070000, GPU | 70 … 100 °C (148-182) | 110 °C | 115 °C | 500 ms |
| `apollo-thermal` | 0x10078000, A53 | 65 … 95 °C (191-225) | 86 °C | 115 °C | 500 ms |
| `isp-thermal` | 0x1007c000, ISP | 80 … 110 °C (267-301) | 110 °C | 115 °C | 500 ms |

All added trips have 2 °C hysteresis. The inherited `active` trips and
the cooling maps of atlas0 and apollo reference CPU cooling devices that
do not exist (no cpufreq), so they bind nothing and do nothing.

## 4. What happens at each trip on this board

* **hot**: nothing in the kernel. `thermal_core.c:417-426` calls the zone's
  `.hot` op, which DT zones do not have (`thermal_of.c` only ever sets
  `.critical`, for `critical-action = "reboot"`, 426-429; the default
  `.critical` comes from `thermal_core.c:1462-1463`). With `THERMAL_NETLINK` off, no userspace
  notification either. It is a marker (visible as a trip point and in
  trace events), matching what stock did at 110 °C: a uevent to userspace
  only (`stock-thermal:1016-1021`).
* **critical**: two things, armed at the same temperature:
  1. the **hardware trip**: mainline sets `THERM_TRIP_EN` and the level-7
     threshold in every instance (`exynos_tmu.c:497-504`), exactly as stock
     did. Above it the TMU signals the PMU, which drops the power without
     software. This is the effective protection;
  2. the **software critical**: `thermal_zone_device_critical()` →
     `hw_protection_shutdown()` → `orderly_poweroff(true)`
     (`thermal_core.c:389-410`, `kernel/reboot.c:992-1010`), i.e. `/sbin/poweroff`.
     Mainline ties both to one temperature, so an orderly power-off cannot
     run before the hardware cut; it only matters if the hardware trip
     does not act.
* **power-off ends in a halt**: there is no power-off handler on this
  board (no `syscon-poweroff` node in the SoC dtsi, only `syscon-reboot`;
  no PSCI). `reboot(POWER_OFF)` becomes a halt when `!kernel_can_power_off()`
  (`kernel/reboot.c:748-750`): "Power off not available: System halted
  instead", then `machine_halt()` (`arch/arm/kernel/reboot.c:103-108`) stops
  the secondary CPUs and spins the boot CPU with interrupts off; the PMIC
  stays on. The stock kernel powers off by clearing bit 8 of
  `PS_HOLD_CONTROL` (PMU + 0x330C, `kernel_universal5433/drivers/staging/samsung/sec_reboot.c:89-95`).
  The hardware trip stays armed while halted.

## 5. Expected first boot

Kernel log, once per instance (`10060000.tmu`, `10068000.tmu`,
`10070000.tmu`, `10078000.tmu`, `1007c000.tmu`):

```
exynos-tmu 10060000.tmu: Temperature sensor ID: 0x<n>
exynos-tmu 10060000.tmu: Calibration type is 1-point calibration     (or 2-point)
```

(`exynos_tmu.c:518`, `535`). No "Failed to ..." line from `exynos-tmu`,
no "Couldn't get polling-delay" or "Failed to find thermal zone" from
`thermal_sys`. **Note the calibration type**: it decides how much risks 2
and 3 (section 9) matter.

Checks (as root):

```sh
for z in /sys/class/thermal/thermal_zone*; do
  echo "$z $(cat $z/type) $(cat $z/temp) $(cat $z/policy)"
done
# five zones: atlas0-, atlas1-, g3d-, apollo-, isp-thermal; policy step_wise
grep . /sys/class/thermal/thermal_zone*/trip_point_*_type | grep -v active
# per zone: trip_point_7_type hot, trip_point_8_type critical
grep . /sys/class/thermal/thermal_zone*/trip_point_[78]_temp
# 110000/115000 (apollo: 86000/115000)
```

Plausibility of `temp` (millidegrees):

* idle: roughly 25 000 - 50 000 on every CPU/ISP sensor, within a few
  degrees of each other. Reference: the stock kernel's idle maximum over
  the CPU/ISP sensors was 32-37 °C (`dumps/dmesg.txt:380,617,806,993,
  1170,1297,1474,1810,2016,2162,2414`, "cur_temp", printed by
  `stock-thermal:421`).
* G3D: may be meaningless while the GPU is unpowered (no GPU driver
  runs); stock replaced it by 20 °C in that state (`stock-thermal:977-980`).
  Do not use it as a reference.
* load test of one cluster (e.g. `taskset -c 0 sh -c 'while :; do :; done'`
  for a minute): the matching sensor (apollo for cpu0-3, atlas0/atlas1 for
  cpu4-7) must rise, then fall back when stopped.

Stop and disable the instance (`status = "disabled"` in a later
override) before any load test if a sensor reads ≥ 85 °C or < 15 °C at
idle, or does not move with load: its calibration is wrong (a high misread
can fire the hardware trip, a low one protects nothing). If the board
powers off by itself about when `exynos-tmu` probes, a sensor misread
fired the hardware trip: go back to the boot3 DTB.

While loading the cores without throttling, watch `apollo-thermal`: stock
treated an A53 reading above 85 °C as an emergency (section 2.3).

## 6. Hardware/software paths not checkable at build time

* whether the PMU honours `THERM_TRIP_EN` on this board (stock relied on it
  too);
* whether the emulated temperature (section 7) also feeds the hardware
  trip comparator (the emulation doc only says the TMU reads the user
  value, `Documentation/driver-api/thermal/exynos_thermal_emulation.rst`).

## 7. Testing the trips (`emul_temp`)

Needs `CONFIG_THERMAL_EMULATION=y` (in the fragment). The TMU's own
emulation mode is used (`exynos_tmu.c:694-733`, register `EMUL_CON` 0x110):
the instance reports the written value instead of its sensor.

Preparation: idle system, `sync`; preferably remount the root read-only
(or test from the initramfs shell), because the critical test may end in
a power cut. Pick a zone, e.g. `Z=/sys/class/thermal/thermal_zone0` after
checking `cat $Z/type`.

1. **Emulation works**: `echo 50000 > $Z/emul_temp; sleep 1; cat $Z/temp`
   → `50000`. `echo 0 > $Z/emul_temp` → real value again.
2. **Hot, no action**: `echo 111000 > $Z/emul_temp` (apollo: `87000`);
   `sleep 1; cat $Z/temp` → the value; the board keeps running. This also
   shows the hardware trip is not programmed below the hot level.
   `echo 0 > $Z/emul_temp`.
3. **Critical**: `sync; echo 116000 > $Z/emul_temp`. Within ≤ 1 s
   (TMU interrupt or the 500 ms poll), one of:
   * the board loses power at once → the hardware trip acted on the
     emulated value;
   * the console shows `thermal thermal_zoneN: atlas0-thermal: critical
     temperature reached` and `reboot: HARDWARE PROTECTION shutdown
     (Temperature too high)`, systemd shuts down and the kernel ends with
     `reboot: Power off not available: System halted instead` (board stays
     powered; hold the power key) → the software path works; the
     hardware trip did not see the emulated value;
   * nothing within a few seconds → the critical path is broken: do **not**
     load the cores; report the log.

   With USB connected the board may come back up (charger present) after
   a power cut; that is the bootloader's choice, not this kernel's.
4. Optional: repeat 3 on each zone (each instance has its own trim and
   threshold register).

**Done on 2026-11-07**, during CPUFREQ.md's stage 2 (owner present):
emulated 117 °C on atlas0, read back as 116 °C (the emulation reads
1 °C low), gave the software path of case 3 — an orderly "hardware
protection" shutdown and a full power-off; the next power-key boot went
to RECOVERY. Before it, 111 °C on atlas0 kept the board running with
the A57s throttled to 0.9 GHz and the GPU to 160 MHz.

**A sustained load, the same day** (the turbo candidate's soak,
`CPUFREQ.md` section 9): an 8-core stress for about 45 minutes with the
cooling maps of that kernel. They held atlas1 at 91-97 °C for the whole
stress — about 40 minutes at or above 90 °C, 4 at or above 95 °C — and
it never reached 100 °C. Stock would have throttled at these
temperatures too (its steps start at 80 °C) but kept the A57s online:
its hotplug takes them offline only at 100 °C and back at 95 °C
(`hotplug_out_threshold` / `hotplug_in_threshold`, `stock-dts:2016-2017`,
section 8.1), which the soak never reached. The battery reached
44.2 °C at most.

## 8. Left out, and why

### 8.1 cpufreq-dt cooling (throttling)

The rule was: only voltage/frequency pairs that are either the mainline
SoC OPP table *valid without ASV for this chip* or stock values, on
certain bucks. The bucks would be certain: BUCK2 `vdd_eagle` = A57, BUCK3
`vdd_kfc` = A53 (stock names, `exynos5433-gts28ltexx-m2.dtsi:54-70`), the
same mapping as TM2 (`exynos5433-tm2-common.dtsi:318-324`). The voltages
are not:

| OPP | mainline (`soc-dtsi`) | stock ASV0 (slowest group) table v0 / v1 / v2 / v3 (`mach/asv-exynos5433.h`) |
|---|---|---|
| A57 1.9 GHz | 1 262 500 µV (344-346) | 1 275 000 (388) / 1 300 000 (493) / 1 300 000 (597) / 1 300 000 (703) |
| A57 1.8 GHz | 1 212 500 µV (340-342) | 1 225 000 (389) / 1 262 500 (494) / 1 262 500 (598) / 1 275 000 (704) |
| A57 1.3 GHz | 1 062 500 µV (320-322) | 1 075 000 (394) / 1 100 000 (499) / 1 100 000 (603) / 1 100 000 (709) |
| A53 1.3 GHz | 1 150 000 µV (278-280) | 1 162 500 (417) / 1 225 000 (522) / 1 225 000 (626) / 1 225 000 (732) |

* The mainline table sits *inside* the stock per-group spread (it is one
  group's voltages, TM2's), below what stock gives the slowest silicon in
  every table version: it is not valid without ASV.
* This chip's ASV group and table version are read at boot from CHIPID
  fuses (`cal_get_table_ver()`, `cal_get_ids()`,
  `kernel_universal5433/arch/arm/mach-exynos/asv-exynos5433_cal.c:103-127`)
  and are not known: the stock log available here starts at 686 s
  (`dumps/dmesg.txt:1`) and has no ASV or cpufreq lines. Mainline has no
  Exynos5433 ASV support (`drivers/soc/samsung/exynos-asv.c` only carries
  Exynos5422 tables).
* A stock-sourced table would need that group. An envelope (maximum over
  all groups and versions) would be built from stock numbers but is not a
  stock table, and stock also programs adaptive body bias per level
  (`abb_table_*`, `use_dynimic_abb`, `asv-exynos5433_cal.c:136-141`), which
  mainline does not.

When in doubt, leave it out: no `cpu-supply`, no cpufreq. Consequence: the
stock throttle steps (80 °C → A57 1.7 GHz … 110 °C → A57 0.8 GHz / A53
0.4 GHz, `live_fdt:4297-4334`, `stock-dts:2054-2085`) and the stock A57
hotplug at 100/95 °C (`stock-dts:2016-2017`) have no mainline equivalent.
A sustained 8-core load can run into the 115 °C hardware trip (a power cut,
not damage). Unblocking this needs the chip's ASV group (one stock boot
log from t = 0, or reading the CHIPID ASV fuses) plus a mainline 5433 ASV
table or a board OPP table built from the matching stock column.

### 8.2 `vtmu-supply`

Section 2.4.

### 8.3 `THERMAL_EMERGENCY_POWEROFF_DELAY_MS`

Kept at 0 (Kconfig default, "In doubt, leave as 0", `drivers/thermal/Kconfig:52-66`).
A forced fallback calls `kernel_power_off()`, which has no handler here,
and then `emergency_restart()` (`kernel/reboot.c:937-955`): it would reboot
a hot board rather than switch it off. Revisit once a power-off handler
exists and the orderly shutdown time has been measured on the device.

### 8.4 Power-off handler (`syscon-poweroff` on `PS_HOLD_CONTROL`)

Not in scope ("enable nothing else"); section 4. The stock method is known
(`sec_reboot.c:89-95`: clear bit 8 of PMU + 0x330C) and
`CONFIG_POWER_RESET_SYSCON_POWEROFF` is already `=y` (selected by
`ARCH_EXYNOS`, `arch/arm/mach-exynos/Kconfig:35`), so a separate task could
add the node; until then a critical trip that the hardware does not cut
ends in a halt.

### 8.5 Mainline `active` trips and cooling maps

Kept as `tmu-dtsi` has them: they are mainline (TM2) policy, not stock,
but they are inert without CPU cooling devices. Review them against the
stock throttle table before ever enabling cpufreq.

### 8.6 `THERMAL_NETLINK`

Would deliver the hot-trip notification to userspace; no consumer exists.

## 9. Open risks

1. **Trim source**: stock calibrates from the OTP bank and falls back to
   TRIMINFO only if the OTP is blank (section 2.2); mainline reads
   TRIMINFO only. Whether both hold the same values on this chip is not
   established. Check: section 5 plausibility.
2. **G3D reference voltage**: mainline always uses 23 for 0x10070000
   (`exynos_tmu.c:923-926`); stock uses 16 unless the chip is two-point
   trimmed (`cal_tmu.c:46-54`). On a one-point chip the G3D reading may be
   scaled/offset. Check: section 5 (and treat G3D as suspect).
3. **Two-point trim details**: stock programs the VPTAT mux of each CPU/ISP
   sensor and the G3D mux address (`cal_tmu.c:58-64`) and sets a 0xE10
   sampling interval ("W/A for WTSR", `stock-thermal:889-891`); mainline
   leaves those CONTROL bits as found (`get_con_reg()`,
   `exynos_tmu.c:308-324`) and does not touch the interval.
4. **G3D/ISP domain transitions**: stock turns the G3D and ISP TMU cores
   off while their power domains power up
   (`kernel_universal5433/arch/arm/mach-exynos/pm_domains-exynos5433.c:87,99,586,606`);
   mainline does not. `pd_g3d`/`pd_isp` are switched by the runtime PM of
   `cmu_g3d`/`cmu_isp` (`soc-dtsi:526,606`) and would be by a future GPU
   (panfrost) or ISP driver. A glitch during a transition could reach the
   hot/critical path or the hardware trip. If unexplained power cuts show
   up around GPU activity, disable `tmu_g3d`/`tmu_isp` first.
5. **Hardware cut before orderly power-off**: both act at 115 °C
   (section 4); unflushed writes can be lost. Keep the root filesystem
   quiet during load tests.
6. **Power-off is a halt** (section 4 / 8.4).
7. **No throttling** (section 8.1).
8. **Apollo 86 °C**: taken from a stock code path (`stock-thermal:991-1000`)
   whose origin (Samsung or LineageOS) cannot be established from the
   shallow clone; it only sets a hot marker.
9. **IRQ trigger**: the driver requests rising-edge (`exynos_tmu.c:1100-1104`)
   on SPIs the DT declares level-high, as on TM2; the 500 ms polling covers
   a lost interrupt.

## 10. Build verification

Build-tested only, 2026-10-28:

* `bash kernel/kbuild-mainline.sh --fragment gts28ltexx_thermaltest.config`
  → exit 0 (own volume `t715-kbuild-out-gts28ltexx_thermaltest`). zImage
  3 494 832 bytes; kernel + DTBs 3 762 KiB of the 14 336 KiB boot budget.
  The ARM64 non-regression phase also passed.
* `.config`: `THERMAL`, `THERMAL_OF`, `EXYNOS_THERMAL`,
  `THERMAL_GOV_STEP_WISE`, `THERMAL_DEFAULT_GOV_STEP_WISE`,
  `THERMAL_HWMON`, `THERMAL_EMULATION` = y; `CPU_THERMAL`, `CPU_FREQ`,
  `THERMAL_NETLINK` not set; `THERMAL_EMERGENCY_POWEROFF_DELAY_MS=0`.
  Compared with the last boot3 build, the only thermal change is
  `THERMAL_EMULATION`.
* `make … samsung/exynos5433-gts28ltexx-thermaltest.dtb` → exit 0, copied to
  `out/mainline-thermaltest/` (59 417 bytes). Decompiled: the five
  `tmu@…` nodes `okay`, no `vtmu-supply` or `cpu-supply`; in each zone
  `polling-delay = 500`, `polling-delay-passive = 100`, trip points 0-6 the
  inherited `active` ones, 7 = hot, 8 = critical, with the temperatures of
  section 3.
* `make CHECK_DTBS=y samsung/exynos5433-gts28ltexx-thermaltest.dtb`
  (dtschema 2026.9, `pip3 install --break-system-packages dtschema` in the
  build container, as for earlier milestones) → exit 0, **no finding in a
  TMU, thermal-zone or trip node**. All findings are already present in
  earlier milestones: root `compatible` not in the board bindings, the
  sboot `model_info-*` properties, the sboot `memory` node name, the PCIe
  `#interrupt-cells` warning from the SoC dtsi, and the USB DRD
  `vdd10-supply`/`vdd33-supply` left out on purpose
  (`exynos5433-gts28ltexx-m2.dtsi:300-305`).

## First boot on the tablet (2026-10-28)

- All five TMUs probe ("Calibration type is 2-point calibration").
- Idle readings: atlas0 45 °C, atlas1 45 °C, apollo 43 °C (plausible; stock idle 32-37 °C), **g3d -60 °C, isp -155 °C (nonsense)**.
- `tmu_g3d` and `tmu_isp` are disabled until their calibration is fixed; the CPU zones (atlas0/1, apollo) keep their hot/critical trips.
- Critical-trip test with `emul_temp` not run yet: it powers the board off (PS_HOLD), so it needs someone at the tablet to switch it back on.
