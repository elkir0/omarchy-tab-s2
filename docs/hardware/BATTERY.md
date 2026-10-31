# Battery — SM5703 fuel gauge (read-only power_supply driver)

SM-T715 (gts28ltexx), mainline 6.12 arm32. Goal: show the battery level
in userspace (UPower, Phosh, Hyprland bars read
`/sys/class/power_supply`). **Build-tested only; not yet run on the
device.**

Deliverables (kernel tree `src/linux-6.12`):

| File | What |
|---|---|
| `drivers/power/supply/sm5703_fuel_gauge.c` | i2c driver, regmap, polling, power_supply `sm5703-fuelgauge` |
| `drivers/power/supply/Kconfig`, `Makefile` | `CONFIG_BATTERY_SM5703` (tristate, `depends on I2C`, `select REGMAP_I2C`) |
| `Documentation/devicetree/bindings/power/supply/siliconmitus,sm5703-fuel-gauge.yaml` | binding, compatible `siliconmitus,sm5703-fuel-gauge` only |
| `arch/arm/boot/dts/samsung/exynos5433-gts28ltexx-battery.dtsi` | `&hsi2c_7 { fuel-gauge@71 }` — **not yet included** from the board file |
| `arch/arm/configs/gts28ltexx_battery.config` | `CONFIG_POWER_SUPPLY=y` (unset in the defconfig) + `CONFIG_BATTERY_SM5703=m` |

Sources: `src/kernel_universal5433/drivers/battery/sm5703_fuelgauge.c`
(cited below as `fg.c:N`), `include/linux/battery/fuelgauge/sm5703_fuelgauge_impl.h`
(`impl.h:N`), `drivers/battery/sec_battery.c`, `include/linux/battery/sec_charging_common.h`,
and the device's stock tree `dumps/live_fdt.dts`.

---

## 1. Hardware and device tree

- `live_fdt.dts:1617-1643`: `hsi2c@14EF0000` (mainline `hsi2c_7`,
  `i2c@14ef0000` in `arm64/exynos/exynos5433.dtsi`), pins `gpd2-7`/`gpd2-6`
  function 4 (`live_fdt.dts:6084-6091`, identical to mainline
  `hs_i2c7_bus`), no `clock-frequency` (100 kHz). Child
  `sm5703-fuelgauge@71`, compatible `samsung,sm5703-fuelgauge`.
- `live_fdt.dts:1638`: `fuelgauge,fuel_int = <&gpa1 4 0>` (pin config
  `fuel-irq`, `live_fdt.dts:350-357`). Described as optional
  `interrupts` in the binding, not wired in the dtsi: the driver polls.
- `live_fdt.dts:1636-1641`: `capacity_calculation_type = 0x0c`,
  `capacity_max = 990`, `capacity_max_margin = 60`, `capacity_min = 0`.
  `0x0c` = `DYNAMIC_SCALE (4) | ATOMIC (8)` (`sec_charging_common.h:326-341`).
- The gauge is a separate I2C device; the SM5703 charger/MFD at 0x49 is
  out of scope.

## 2. Read-only policy

The gauge runs from the battery across reboots. The stock driver loads
the battery model and calibration at its own boot (`fg.c:758-950`,
`sm5703_fg_reg_init`) and keeps tuning it at runtime. The mainline driver
writes **nothing**:

- the regmap's `writeable_reg` returns false for every register;
- `readable_reg` lists only the 8 registers used (0x00, 0x01, 0x05-0x09,
  0x10), so a regmap debugfs dump cannot read `INTFG` (0x02), which the
  stock IRQ handler reads to clear the interrupt (`fg.c:1311-1312`);
- no IRQ, no alarms, no calibration, no model load, no reset.

Probe reads `FG_OP_STATUS` (0x10): the stock driver treats
`(val & 0xff) == 0x07` (`DISABLE_RE_INIT`, `impl.h:110`) as "model loaded"
(`fg.c:410-423`). Otherwise the driver warns that readings are unreliable
(the gauge lost its model, e.g. after a full drain or battery disconnect),
but still registers.

## 3. Register decoding

All registers are 16-bit words read LSB first: the stock driver does a
2-byte `i2c_smbus_read_i2c_block_data()` into a `u16` on little-endian
ARM (`fg.c:57-89`, "not use big endian" at `fg.c:87-88`). Mainline uses
`regmap` with `val_bits = 16`, `REGMAP_ENDIAN_LITTLE`; on the Exynos
HSI2C (`I2C_FUNC_I2C`) it is the same write-reg / repeated-start / read-2
transfer.

| Reg | Name (`impl.h`) | Stock decode | Mainline property |
|---|---|---|---|
| 0x00 | DEVICE_ID (`:20`) | logged only, no value checked (`fg.c:399-408`); `< 3` selects an older top-off mapping (`fg.c:891`) | printed at probe, not checked |
| 0x01 | CNTL (`:21`) | bit 14 `ENABLE_TEMP_MEASURE` (`impl.h:98`) set at init (`fg.c:903-905`) | gates `TEMP` |
| 0x05 | SOC (`:25`) | `[15:8]` integer %, `[7:0]` /256 %, result in 0.1 % with truncation (`fg.c:257-266`) | `CAPACITY` (scaled, §4) |
| 0x06 | OCV (`:26`) | `[10:8]` integer V, `[7:0]` /256 V, unsigned, mV (`fg.c:174-183`) | `VOLTAGE_OCV` = `(raw & 0x7ff) * 15625 / 4` µV |
| 0x07 | VOLTAGE (`:27`) | same format as OCV (`fg.c:281-290`) | `VOLTAGE_NOW`, same formula |
| 0x08 | CURRENT (`:28`) | `[10:8]` integer A, `[7:0]` /256 A, **bit 15 = sign** (sign-magnitude, bits 14:11 ignored), mA (`fg.c:343-355`) | `CURRENT_NOW` µA, same sign |
| 0x09 | TEMPERATURE (`:29`) | `[14:8]` integer °C, `[7:0]` /256 °C, bit 15 = sign, 0.1 °C (`fg.c:149-161`) | `TEMP` (0.1 °C) |
| 0x10 | FG_OP_STATUS (`:30`) | `[7:0] == 7` = initialised (`fg.c:216-217`, `:414-416`) | probe warning only |

Voltage/current LSB is 1/256 V (A) = 3.90625 mV (mA). Mainline keeps
µV/µA resolution; the stock mV value is exactly `floor(µV / 1000)`.

Cross-check against the stock kernel log (`dumps/dmesg.txt`):

| Line | Stock print | Mainline decoding of the same raw word |
|---|---|---|
| 6 | `temperature: read = 0x20a0, temperature = 326` | 32×10 + 160×10/256 = 326 (32.6 °C) |
| 7 | `ocv: read = 0x444, ocv = 4265` | 0x444 × 15625 / 4 = 4 265 625 µV |
| 9 | `soc: read = 0x5a60, soc = 903` | 903 ‰ → 903×1000/990 = 912 → **91 %** |

**Current sign.** Stock: magnitude negated when bit 15 is set, and a
positive value means charging (`ta_exist = is_charging && batt_current >= 0`,
`fg.c:205`; also `fg.c:1113-1114`). The stock log agrees:
`Inow(207mA)` on the charger at `dmesg.txt:53`, `Inow(-246mA)` after
unplugging at `dmesg.txt:1669`. The power_supply ABI also uses
positive = charging, so the sign is passed through unchanged.

**Temperature.** It is the gauge's own sensor, decoded from its register
with no thermistor table, so it is exposed as `TEMP` (the stock driver
reports the same value for `TEMP` and `TEMP_AMBIENT`, `fg.c:1153-1157`).
It is *not* Android's `Tbat`, which comes from a battery thermistor read by
`sec_battery` through the AP ADC. If `CNTL` bit 14 is clear the gauge does
not measure temperature, and `TEMP` returns `-ENODATA`.

## 4. CAPACITY and capacity_max

Stock pipeline for the value Android shows (`fg.c:1091-1151`):

1. raw SOC in 0.1 % (`fg.c:257-266`);
2. `scaled = (soc - capacity_min) * 1000 / (capacity_max - capacity_min)`
   (`fg.c:588-599`, applied because type 0x0c has `DYNAMIC_SCALE`);
3. clamp to 0..1000, keep integer % (`fg.c:1105-1111`);
4. `ATOMIC` smoothing: at most ±1 % per read from the previous value
   (`fg.c:602-628`), plus a low-voltage "cold mode" forcing 0 %.

`capacity_max` starts at the DT value 990 at every boot (`fg.c:1698`),
is recomputed at probe if raw SOC > 990 (`fg.c:1700-1702`), at every full
charge (`CHARGE_FULL`, `fg.c:1188-1205` -> `fg.c:656-698`, kept within
990 ± 60), and can be restored by Android userspace through
`batt_capacity_max` (`sec_battery.c:3606-3620`,
`CONFIG_DISABLE_SAVE_CAPACITY_MAX` unset).

Mainline does steps 1-3 with constants `capacity_max = 990` and
`capacity_min = 0`: pure arithmetic on the SOC register, the stock
boot-time value. Steps 4 and the dynamic `capacity_max` are left out:
they depend on state the stock driver holds in RAM or on events from the
charger. Consequence: mainline can differ from Android by a few percent
when Android has learnt a `capacity_max` other than 990 (at most
1000/930 ≈ +7.5 % or 1000/1050 ≈ −5 % relative), and it can step by more
than 1 % between reads.

## 5. STATUS, PRESENT, TECHNOLOGY

The stock gauge returns `-ENODATA` for `STATUS` (`fg.c:1064-1067`): the
charger driver owned it. Without a charger driver, mainline derives it
from `CURRENT_NOW` and `CAPACITY`:

| Condition | STATUS |
|---|---|
| current > +50 mA | Charging |
| current < −50 mA | Discharging |
| \|current\| ≤ 50 mA and capacity ≥ 100 | Full |
| \|current\| ≤ 50 mA and capacity < 100 | Not charging |

50 mA ≈ 13 LSB; the stock OCV tracking uses 60 mA as its own "low
current" threshold (`fg.c:502`). With the charger in its constant-voltage
phase at a displayed 100 % (`Inow` ≈ +200 mA at `dmesg.txt:53`) the
status is Charging until the current tapers below 50 mA.

`PRESENT` = 1 (built-in battery, no detection on the gauge),
`TECHNOLOGY` = Li-ion.

Polling: a freezable delayed work re-reads SOC and current every 30 s
and calls `power_supply_changed()` when the capacity or the status
changes, so UPower gets uevents without an IRQ.

Debounce (2026-10-29): on the Mac's USB port at 99 %, the current read
every 2 s swung between −109 and +113 mA (mean +72 mA). The status taken
from a single reading flipped between Charging, Not charging and
Discharging. The board has no line-power supply, so UPower derives
`OnBattery` from the battery state: it went yes/no twice in 3 minutes,
and gsd-power played its plug/unplug sound each time (heard under
Phosh as sounds with no action, in step with the charging icon). The
`STATUS` property now returns a debounced value: a reading that differs
from it is re-checked every 10 s, and only three readings in a row that
agree replace it. A real plug or unplug therefore shows after 20 to
50 s.

Still open: without the charger or VBUS detection, a battery idling
below 50 mA on its own reads Not charging, and UPower then reports it
on mains. The lasting fix is a line-power supply (charger or MUIC
driver).

## 6. Left out, and why

| Item | Reason |
|---|---|
| Battery model / calibration load (`fg.c:758-950`) | writes; relies on Android having loaded it |
| `CURR_CAL` temperature compensation written before every SOC read (`fg.c:205-255`) | writes; `CURR_CAL` keeps the value Android last wrote (the log shows `0x8100`, `dmesg.txt:8`) |
| OCV tracking / RS manual mode switching (`fg.c:425-585`, `CONFIG_SM5703_OCV_TRACKING=y` in `lineage_gts28ltexx_defconfig:4096`) | writes `RS_MAN`, `CNTL`; the gauge stays in the mode Android left |
| SW reset + re-init when `FG_OP_STATUS` is wrong (`fg.c:216-229`) | writes; mainline only warns |
| Alarms and fuel-alert IRQ (`fg.c:700-738`, `:1285-1322`) | writes; polling instead |
| `VOLTAGE_AVG`, `CURRENT_AVG` (`fg.c:307-396`) | software averages of 5 reads, not chip values |
| `CHARGE_FULL`, `ENERGY_NOW`, `CAPACITY_LEVEL` | stock returns `-ENODATA` or has no decoding |
| Dynamic `capacity_max`, atomic smoothing (§4) | state held by the stock driver / Android |
| STATUS register 0x04 | the stock driver only masks alarm bits from it |
| Battery thermistor (`Tbat`) | read by `sec_battery` via the AP ADC, not by the gauge |

## 7. First test on the device

Prerequisites: include `exynos5433-gts28ltexx-battery.dtsi` from the board
file, build with `--fragment gts28ltexx_battery.config`, and boot Android
first so the gauge is initialised. Note Android's battery % and whether
the charger is plugged just before rebooting.

```sh
modprobe sm5703_fuel_gauge          # if not auto-loaded
dmesg | grep -i sm5703              # "device ID 0x...., CNTL 0x...., FG_OP_STATUS 0x...."
                                    # no "battery model not loaded" warning
                                    #   (FG_OP_STATUS low byte must be 0x07)
cat /sys/class/power_supply/sm5703-fuelgauge/uevent
cat /sys/kernel/debug/regmap/*-0071/registers   # raw words, if debugfs is mounted
upower -d                           # or the Phosh/Hyprland battery indicator
```

Expected:

| Property | Expected range |
|---|---|
| `POWER_SUPPLY_TYPE` | `Battery` |
| `POWER_SUPPLY_CAPACITY` | 0-100, within a few % of Android's last value |
| `POWER_SUPPLY_VOLTAGE_NOW` | 3 400 000-4 400 000 (µV); ~4.39 V when charging at full |
| `POWER_SUPPLY_VOLTAGE_OCV` | 3 400 000-4 350 000, close to `VOLTAGE_NOW` at low current |
| `POWER_SUPPLY_CURRENT_NOW` | negative on battery (−100 000 to −2 000 000 µA), positive on the charger (up to ~2 100 000) |
| `POWER_SUPPLY_TEMP` | ~150-450 (0.1 °C), room/device temperature |
| `POWER_SUPPLY_STATUS` | `Discharging` unplugged, `Charging` plugged |
| `POWER_SUPPLY_PRESENT` / `TECHNOLOGY` | `1` / `Li-ion` |

Checks:

1. Capacity vs Android: compare with the % shown before the reboot. A
   constant offset of a few % points to Android's learnt `capacity_max`
   (§4); a value stuck at 0 or garbage points to an uninitialised gauge.
2. Plug/unplug the charger: `CURRENT_NOW` and `STATUS` are read from the
   chip on every sysfs read, so `cat` shows the new sign at once; the
   change uevent (what UPower reacts to) follows within 30 s (poll
   interval).
3. Leave it discharging for 10 min: `CAPACITY` should drop slowly and
   monotonically; `udevadm monitor -s power_supply` should show a change
   event when it does.
4. Raw sanity: in the regmap dump, SOC/256 (in %), VOLTAGE & 0x7ff / 256
   (in V) must match the decoded sysfs values.
